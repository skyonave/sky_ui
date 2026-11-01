#!/usr/bin/env python3
"""Destructive acceptance ONLY inside the dedicated private-network install fixture."""
import hashlib
import json
import os
from pathlib import Path
import pwd
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request

assert os.geteuid() == 0
assert Path('/run/systemd/container').read_text().strip() == 'systemd-nspawn'
assert socket.gethostname() == 'sky-ui-install-test'
assert Path('/unrelated-fixture').read_text() == 'preserve me'
assert set(Path('/sys/class/net').iterdir()) == {Path('/sys/class/net/lo')}
INSTALLER = '/source/install.sh'
BUNDLE = '/source/build/releases/sky-ui-linux-amd64.tar.gz'


def run(*args, input=None):
    result = subprocess.run(args, input=input, text=True, capture_output=True, timeout=180)
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    return result.stdout


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def ready():
    for _ in range(100):
        try:
            with http.open('http://127.0.0.1:39241/api/v1/health', timeout=1) as response:
                if json.load(response)['version'] == '0.6.0-dev.1':
                    return
        except OSError:
            pass
        time.sleep(.2)
    raise AssertionError('API readiness failed')


http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
ready()
assert run('skyui', 'version').strip() == '0.6.0-dev.1'
run('skyui','status')
run('skyui','certificates','status')
owner = pwd.getpwnam('sky-ui')
fixture_password = 'isolated-cli-owner-fixture'
hashed = run('/opt/sky-ui/current/bin/caddy', 'hash-password', '--algorithm','bcrypt',
             '--bcrypt-cost','4',input=fixture_password+'\n').strip()
seed = Path('/etc/sky-ui/owner.seed')
seed.write_text('admin '+hashed+'\n')
seed.chmod(0o600)
os.chown(seed,owner.pw_uid,owner.pw_gid)
run('skyui','restart')
ready()
env = dict(line.split('=',1) for line in Path('/etc/sky-ui/server.env').read_text().splitlines() if '=' in line)
headers = {'X-Sky-UI-Gateway': Path('/etc/sky-ui/gateway.secret').read_text().strip(),
           'Origin': env['SKY_UI_WEB_ORIGIN']}


def call(path, method='GET', value=None, expected=200):
    request = urllib.request.Request('http://127.0.0.1:39241/api/v1/'+path,
        method=method,headers=headers,data=json.dumps(value).encode() if value is not None else None)
    if value is not None:
        request.add_header('Content-Type','application/json')
    try:
        response = http.open(request,timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        assert response.status == expected, (path,response.status)
        return json.load(response),response.headers


body,response_headers = call('auth/login','POST',{'username':'admin','password':fixture_password})
headers.update({'Cookie':response_headers['Set-Cookie'].split(';',1)[0],
                'X-Sky-UI-CSRF':body['data']['csrf']})
call('panel')
secret_files = ['/etc/sky-ui/gateway.secret','/etc/sky-ui/controller.secret','/etc/sky-ui/owner.seed']
before = [digest(path) for path in secret_files]
run('skyui','start','core')
ready()
assert run('systemctl','is-active','sky-ui-mihomo.service').strip() == 'active'
run('skyui','stop','core')
ready()
assert json.loads(Path('/var/lib/sky-ui/instances/primary.json').read_text())['desiredState'] == 'stopped'
run('skyui','restart')
ready()
assert subprocess.run(['systemctl','is-active','--quiet','sky-ui-mihomo.service']).returncode != 0
run('skyui','backup')
ready()
assert run('skyui','backups').strip()
run('bash',INSTALLER,'--bundle',BUNDLE)
ready()
assert before == [digest(path) for path in secret_files]
call('panel')
print('PASS: CLI lifecycle, stopped-state persistence, backup, repeated install, owner/session/secrets preserved.')
run('skyui','uninstall',input='no\n')
assert Path('/etc/sky-ui/managed-by-sky-ui').exists()
run('skyui','uninstall',input='DELETE\n')
for path in ['/etc/sky-ui','/var/lib/sky-ui','/var/lib/sky-ui-edge','/var/lib/sky-ui-certificates',
             '/var/lib/sky-ui-maintenance','/opt/sky-ui','/usr/local/bin/skyui','/usr/local/bin/sky-ui']:
    assert not Path(path).exists(),path
for name in ['sky-ui','sky-ui-core','sky-ui-edge']:
    try:
        pwd.getpwnam(name)
    except KeyError:
        continue
    raise AssertionError('Account remains: '+name)
assert Path('/unrelated-fixture').read_text() == 'preserve me'
run('bash',INSTALLER,'--bundle',BUNDLE)
ready()
run('skyui','uninstall',input='DELETE\n')
assert Path('/unrelated-fixture').read_text() == 'preserve me'
print('PASS: cancellation, complete uninstall, unrelated data preserved and clean reinstall/uninstall.')
