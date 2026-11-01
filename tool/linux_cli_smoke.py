#!/usr/bin/env python3
"""Destructive acceptance ONLY inside the dedicated private-network install fixture."""
import hashlib
import io
import json
import os
from pathlib import Path
import pwd
import socket
import sqlite3
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

assert os.geteuid() == 0
assert Path('/run/systemd/container').read_text().strip() == 'systemd-nspawn'
assert socket.gethostname() == 'sky-ui-install-test'
assert Path('/unrelated-fixture').read_text() == 'preserve me'
assert set(Path('/sys/class/net').iterdir()) == {Path('/sys/class/net/lo')}
VERSION = Path('/source/VERSION').read_text().strip()
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
                if json.load(response)['version'] == VERSION:
                    return
        except OSError:
            pass
        time.sleep(.2)
    raise AssertionError('API readiness failed')


http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
ready()
assert run('skyui', 'version').strip() == VERSION
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
binary = Path('/opt/sky-ui/cores/mihomo/current/mihomo')
binary_hash = digest(binary)
core_pid = run('systemctl','show','sky-ui-mihomo.service','--property=MainPID','--value').strip()
with tarfile.open(BUNDLE) as archive:
    names = {entry.name.removeprefix('./') for entry in archive}
assert 'bin/mihomo' not in names and 'licenses/mihomo.LICENSE' not in names
run('bash',INSTALLER,'--bundle',BUNDLE)
ready()
assert run('systemctl','show','sky-ui-mihomo.service','--property=MainPID','--value').strip() == core_pid
assert digest(binary) == binary_hash
assert binary.resolve().parent.parent == Path('/opt/sky-ui/cores/mihomo')
assert (binary.resolve().parent/'LICENSE').is_file()
assert (binary.resolve().parent/'artifact.json').is_file()
print('PASS: unbundled panel reinstall preserves the running core PID, binary and independent slot.')

# Recreate the old bundled layout, then fail panel activation after core migration.
legacy = Path('/opt/sky-ui/releases/legacy-fixture')
(legacy/'bin').mkdir(parents=True)
(legacy/'licenses').mkdir()
shutil.copy2(binary,legacy/'bin/mihomo')
shutil.copy2(binary.resolve().parent/'LICENSE',legacy/'licenses/mihomo.LICENSE')
link = binary.parent
candidate_link = link.parent/'.legacy-fixture'
candidate_link.symlink_to(legacy/'bin')
os.replace(candidate_link,link)
environment_file = Path('/etc/sky-ui/server.env')
old_environment = environment_file.read_text()
environment_file.write_text('\n'.join(
    'SKY_UI_CORE_BINARY='+str(legacy/'bin/mihomo') if line.startswith('SKY_UI_CORE_BINARY=') else line
    for line in old_environment.splitlines())+'\n')
with tempfile.TemporaryDirectory(prefix='sky-ui-rollback-fixture-') as temporary:
    broken = Path(temporary)/Path(BUNDLE).name
    with tarfile.open(BUNDLE,'r:gz') as source,tarfile.open(broken,'w:gz') as target:
        for entry in source:
            name = entry.name.removeprefix('./')
            if name == 'VERSION':
                data = b'0.6.0-dev.999\n'
            elif name == 'bin/sky-ui':
                data = b'#!/bin/sh\nif [ "$1" = "--version" ]; then echo "Sky UI 0.6.0-dev.999"; exit 0; fi\nexit 1\n'
            else:
                target.addfile(entry,source.extractfile(entry) if entry.isfile() else None)
                continue
            entry.size = len(data)
            target.addfile(entry,io.BytesIO(data))
    Path(str(broken)+'.sha256').write_text(digest(broken)+'  '+broken.name+'\n')
    failed = subprocess.run(['bash',INSTALLER,'--bundle',str(broken)],capture_output=True,text=True,timeout=120)
    assert failed.returncode != 0, 'Broken panel unexpectedly activated'
    ready()
assert link.resolve() == legacy/'bin'
assert digest(binary) == binary_hash
assert run('systemctl','show','sky-ui-mihomo.service','--property=MainPID','--value').strip() == core_pid
call('panel')
run('bash',INSTALLER,'--bundle',BUNDLE)
ready()
assert link.resolve().parent == Path('/opt/sky-ui/cores/mihomo')
assert digest(binary) == binary_hash
assert run('systemctl','show','sky-ui-mihomo.service','--property=MainPID','--value').strip() == core_pid
assert before == [digest(path) for path in secret_files]
call('panel')
print('PASS: failed activation rolls back legacy core migration; successful migration preserves traffic state and sessions.')
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

# Keep real connection/grant records through removal, panel restart and reinstall.
with socket.socket() as probe:
    probe.bind(('127.0.0.1',0));connection_port=probe.getsockname()[1]
body,_=call('panel');revision=body['data']['revision']
body,_=call('connections','POST',{'revision':revision,'connection':{'id':'','name':'Removal fixture','coreId':'mihomo','instanceId':'primary','protocolId':'vless','port':connection_port,'enabled':True,'settings':{}}})
connection=body['data']['connections'][0]
body,_=call('recipients','POST',{'revision':body['data']['revision'],'recipient':{'id':'','name':'Removal fixture','enabled':True,'connectionIds':[connection['id']]}})
records=body['data']
with sqlite3.connect('/var/lib/sky-ui/panel.sqlite') as db:
    preserved=hashlib.sha256(repr(list(db.iterdump())).encode()).hexdigest()
# Cancellation must leave the installed core in place.
cancelled=subprocess.run(['skyui','remove-core'],input='no\n',capture_output=True,text=True,timeout=30)
assert cancelled.returncode != 0 and binary.exists()
run('skyui','remove-core',input='REMOVE\n')
ready()
assert not binary.exists()
body,_=call('panel');assert body['data']['coreAvailability']=={'mihomo':False}
assert body['data']['deliveryReady'] is False
assert body['data']['connections']==records['connections']
assert body['data']['recipients']==records['recipients']
call('cores/primary/actions/start','POST',{},expected=409)
run('skyui','restart');ready()
run('bash',INSTALLER,'--bundle',BUNDLE);ready()
assert not binary.exists()
with sqlite3.connect('/var/lib/sky-ui/panel.sqlite') as db:
    assert hashlib.sha256(repr(list(db.iterdump())).encode()).hexdigest()==preserved
run('skyui','install-core',input='INSTALL\n');ready()
assert binary.exists()
assert not (binary.parent.parent/'removed.json').exists()
assert subprocess.run(['systemctl','is-active','--quiet','sky-ui-mihomo.service']).returncode != 0
body,_=call('panel');assert body['data']['coreAvailability']=={'mihomo':True}
assert body['data']['connections']==records['connections']
assert body['data']['recipients']==records['recipients']
run('skyui','start','core');ready()
body,_=call('panel');assert body['data']['deliveryReady'] is True
with sqlite3.connect('/var/lib/sky-ui/panel.sqlite') as db:
    assert hashlib.sha256(repr(list(db.iterdump())).encode()).hexdigest()==preserved
assert before==[digest(path) for path in secret_files]
print('PASS: core removal is visible to connections, blocks start, survives panel reinstall, and install restores the same grants/keys.')

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
