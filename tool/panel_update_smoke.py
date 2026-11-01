#!/usr/bin/env python3
"""Real updater acceptance, restricted to the disposable private-network fixture."""
import hashlib
import io
import json
import os
from pathlib import Path
import pwd
import socket
import sqlite3
import subprocess
import tarfile
import time
import urllib.error
import urllib.request

assert os.geteuid() == 0
assert Path('/run/systemd/container').read_text().strip() == 'systemd-nspawn'
assert socket.gethostname() == 'sky-ui-install-test'
assert Path('/unrelated-fixture').read_text() == 'preserve me'
assert set(Path('/sys/class/net').iterdir()) == {Path('/sys/class/net/lo')}
BASE = Path('/source/VERSION').read_text().strip()
GOOD, BAD = '0.6.0-dev.5', '0.6.0-dev.6'
FIXTURES = Path('/test-fixtures')
assert BASE == '0.6.0-dev.4'


def run(*args, input=None):
    result = subprocess.run(args, input=input, text=True, capture_output=True, timeout=180)
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    return result.stdout


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
env = dict(line.split('=', 1) for line in Path('/etc/sky-ui/server.env').read_text().splitlines() if '=' in line)
headers = {'X-Sky-UI-Gateway': Path('/etc/sky-ui/gateway.secret').read_text().strip(), 'Origin': env['SKY_UI_WEB_ORIGIN']}


def call(path, method='GET', value=None, expected=200):
    request = urllib.request.Request('http://127.0.0.1:39241/api/v1/' + path,
        method=method, headers=headers, data=json.dumps(value).encode() if value is not None else None)
    if value is not None:
        request.add_header('Content-Type', 'application/json')
    try:
        response = http.open(request, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        body = json.load(response)
        assert response.status == expected, (path, response.status, body)
        return body, response.headers


def ready(version):
    for _ in range(150):
        try:
            body, _ = call('health')
            if body['version'] == version:
                return
        except (OSError, AssertionError):
            pass
        time.sleep(.2)
    raise AssertionError('API readiness failed: ' + version)


def job(tag):
    body, _ = call('maintenance', 'POST', {'action': 'panel-update', 'tag': tag, 'confirmed': True}, expected=202)
    identity = body['data']['id']
    for _ in range(500):
        try:
            result, _ = call('maintenance')
            status = result['data']['job']
            if status and status['id'] == identity and status['status'] in ('completed', 'failed'):
                return status
        except (OSError, AssertionError):
            pass
        time.sleep(.2)
    raise AssertionError('Updater did not finish')


ready(BASE)
owner = pwd.getpwnam('sky-ui')
password = 'isolated-panel-update-fixture'
hashed = run('/opt/sky-ui/current/bin/caddy', 'hash-password', '--algorithm', 'bcrypt', '--bcrypt-cost', '4', input=password+'\n').strip()
seed = Path('/etc/sky-ui/owner.seed')
seed.write_text('admin '+hashed+'\n'); seed.chmod(0o600); os.chown(seed, owner.pw_uid, owner.pw_gid)
run('skyui', 'restart'); ready(BASE)
body, response = call('auth/login', 'POST', {'username': 'admin', 'password': password})
headers.update(Cookie=response['Set-Cookie'].split(';', 1)[0], **{'X-Sky-UI-CSRF': body['data']['csrf']})
run('skyui', 'start', 'core')
pid = run('systemctl', 'show', 'sky-ui-mihomo.service', '--property=MainPID', '--value').strip()
assert int(pid) > 1
secret_paths = ['/etc/sky-ui/gateway.secret', '/etc/sky-ui/controller.secret', '/etc/sky-ui/owner.seed']
secrets = [sha(path) for path in secret_paths]
core_hash = sha('/opt/sky-ui/cores/mihomo/current/mihomo')

# Seed a disposable access record and verify rollback restores the actual SQLite data.
database = Path('/var/lib/sky-ui/panel.sqlite')
if not database.exists():
    database = next(Path('/var/lib/sky-ui').glob('*.sqlite*'))
with sqlite3.connect(database) as db:
    db.execute('CREATE TABLE IF NOT EXISTS updater_fixture(value TEXT NOT NULL)')
    db.execute('DELETE FROM updater_fixture')
    db.execute("INSERT INTO updater_fixture VALUES ('preserve-access-record')")

releases = []
for version in (GOOD, BAD):
    target = FIXTURES/version; target.mkdir(exist_ok=True)
    bundle = target/'sky-ui-linux-amd64.tar.gz'
    with tarfile.open('/source/build/releases/'+bundle.name) as source, tarfile.open(bundle, 'w:gz') as output:
        for entry in source:
            name = entry.name.removeprefix('./')
            data = None
            if name == 'VERSION':
                data = (version+'\n').encode()
            elif name == 'bin/sky-ui' and version == BAD:
                # Fail after a simulated schema migration; the installer alone cannot undo it.
                data = ("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'Sky UI "+version+"'; exit 0; fi\n"
                    "python3 -c \"import sqlite3; d=sqlite3.connect('"+str(database)+"'); d.execute('DROP TABLE updater_fixture'); d.commit()\"\nexit 1\n").encode()
            if data is None:
                output.addfile(entry, source.extractfile(entry) if entry.isfile() else None)
            else:
                entry.size = len(data); output.addfile(entry, io.BytesIO(data))
    (target/'install.sh').write_bytes(Path('/source/install.sh').read_bytes())
    for name in (bundle.name, 'install.sh'):
        (target/(name+'.sha256')).write_text(sha(target/name)+'  '+name+'\n')
    tag = 'v'+version
    releases.append({'tag_name': tag, 'draft': False, 'prerelease': True, 'assets': [
        {'name': path.name, 'size': path.stat().st_size, 'state': 'uploaded', 'digest': 'sha256:'+sha(path),
         'browser_download_url': 'https://github.com/skyonave/sky_ui/releases/download/'+tag+'/'+path.name}
        for path in target.iterdir()]})
    target.chmod(0o755)
    for path in target.iterdir(): path.chmod(0o644)

feed = FIXTURES/'panel-feed.json'
feed.write_text(json.dumps([releases[0]])); feed.chmod(0o644)
body, _ = call('panel-update')
assert body['data']['tag'] == 'v'+GOOD and body['data']['available']
result = job('v'+GOOD)
assert result['status'] == 'completed', result
ready(GOOD)
call('panel')  # The same session and CSRF survive activation.
assert run('systemctl', 'show', 'sky-ui-mihomo.service', '--property=MainPID', '--value').strip() == pid
assert [sha(path) for path in secret_paths] == secrets
assert sha('/opt/sky-ui/cores/mihomo/current/mihomo') == core_hash
print('PASS: authenticated update, retained session/credentials and unchanged running core.')

feed.write_text(json.dumps([releases[1]])); feed.chmod(0o644)
result = job('v'+BAD)
assert result['status'] == 'failed' and result['error'] == 'panel_update_rolled_back', result
ready(GOOD); call('panel')
with sqlite3.connect(database) as db:
    assert db.execute('SELECT value FROM updater_fixture').fetchone() == ('preserve-access-record',)
assert Path('/opt/sky-ui/current').resolve().name == GOOD+'-amd64'
assert [sha(path) for path in secret_paths] == secrets
assert run('systemctl', 'show', 'sky-ui-mihomo.service', '--property=MainPID', '--value').strip() == pid
assert not Path('/var/lib/sky-ui-maintenance/panel-update-intent.json').exists()
assert not Path('/var/lib/sky-ui-maintenance/panel-update-backup.tar.gz').exists()
print('PASS: failed migration restores previous release, SQLite data and the existing owner session.')

# Simulate a process interruption after a durable rescue copy was written.
import sys
sys.path.insert(0, '/opt/sky-ui/current/deploy')
import maintenance as m
run('systemctl', 'stop', 'sky-ui.service')
archive, _ = m.pack_backup(m.snapshot_files(preserve_sessions=True), {'version': GOOD, 'purpose': 'panel-update'})
m.atomic(m.STATE/'panel-update-backup.tar.gz', archive, 0o600)
intent = {'id': 'a'*32, 'tag': 'v'+BAD, 'previous': str(m.CURRENT.resolve()),
          'api': True, 'edge': False, 'timer': m.active('sky-ui-certificates.timer')}
m.atomic(m.STATE/'panel-update-intent.json', json.dumps(intent).encode(), 0o600)
with sqlite3.connect(database) as db:
    db.execute('DROP TABLE updater_fixture')
run('systemctl', 'start', 'sky-ui-update-recovery.service')
ready(GOOD); call('panel')
with sqlite3.connect(database) as db:
    assert db.execute('SELECT value FROM updater_fixture').fetchone() == ('preserve-access-record',)
assert not (m.STATE/'panel-update-intent.json').exists()
assert not (m.STATE/'panel-update-backup.tar.gz').exists()
assert run('systemctl', 'show', 'sky-ui-mihomo.service', '--property=MainPID', '--value').strip() == pid
print('PASS: interrupted update recovers data and owner session without restarting the core.')
