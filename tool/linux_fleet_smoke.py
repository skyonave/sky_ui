#!/usr/bin/env python3
"""Installed multi-engine acceptance, restricted to the disposable nspawn fixture."""
import hashlib
import json
import os
from pathlib import Path
import pwd
import socket
import subprocess
import time
import urllib.error
import urllib.request

assert os.geteuid() == 0
assert Path('/run/systemd/container').read_text().strip() == 'systemd-nspawn'
assert socket.gethostname() == 'sky-ui-install-test'
assert Path('/unrelated-fixture').read_text() == 'preserve me'
assert set(Path('/sys/class/net').iterdir()) == {Path('/sys/class/net/lo')}
SOURCE = Path('/source')
VERSION = (SOURCE/'VERSION').read_text().strip()
CORES = ('mihomo','sing-box','xray','amneziawg')
http = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def run(*args, input=None):
    result = subprocess.run(args, input=input, capture_output=True, text=True, timeout=180)
    if result.returncode:
        # Keep detailed output private, since CLI diagnostics may include paths
        # to sensitive rescue copies. Never print credentials or native profiles.
        Path('/test-fixtures/failed-command.log').write_text(result.stdout+'\n'+result.stderr)
        raise AssertionError('Fixture command failed: '+args[0]+' '+str(result.returncode))
    return result.stdout


def ready():
    for _ in range(150):
        try:
            with http.open('http://127.0.0.1:39241/api/v1/health', timeout=2) as response:
                if json.load(response)['version'] == VERSION: return
        except OSError: pass
        time.sleep(.2)
    raise AssertionError('API readiness timeout')


ready()
# A configured gateway belongs to a complete backup. Keep it stopped and
# listener-free in this offline fixture; public ACME is tested separately.
Path('/etc/sky-ui/Caddyfile').write_text('# Isolated offline gateway fixture.\n')
for unit in ('sky-ui-maintenance.service','sky-ui-maintenance-recovery.service'):
    directory = Path('/run/systemd/system')/(unit+'.d'); directory.mkdir(parents=True,exist_ok=True)
    (directory/'fixture.conf').write_text('[Service]\nEnvironment=PYTHONPATH=/test-fixtures\n')
run('systemctl','daemon-reload')
owner = pwd.getpwnam('sky-ui')
password = 'isolated-fleet-owner-fixture'
hashed = run('/opt/sky-ui/current/bin/caddy','hash-password','--algorithm','bcrypt','--bcrypt-cost','4',input=password+'\n').strip()
seed = Path('/etc/sky-ui/owner.seed'); seed.write_text('admin '+hashed+'\n'); seed.chmod(0o600); os.chown(seed,owner.pw_uid,owner.pw_gid)
run('skyui','restart'); ready()
environment = dict(line.split('=',1) for line in Path('/etc/sky-ui/server.env').read_text().splitlines() if '=' in line)
headers = {'X-Sky-UI-Gateway':Path('/etc/sky-ui/gateway.secret').read_text().strip(),'Origin':environment['SKY_UI_WEB_ORIGIN']}


def call(path, method='GET', value=None, expected=200):
    request = urllib.request.Request('http://127.0.0.1:39241/api/v1/'+path,method=method,headers=headers,data=json.dumps(value).encode() if value is not None else None)
    if value is not None: request.add_header('Content-Type','application/json')
    try: response = http.open(request,timeout=30)
    except urllib.error.HTTPError as error: response = error
    with response:
        body = json.load(response)
        assert response.status == expected, (path,response.status,body.get('error',{}))
        return body,response.headers


body,response = call('auth/login','POST',{'username':'admin','password':password})
headers.update(Cookie=response['Set-Cookie'].split(';',1)[0],**{'X-Sky-UI-CSRF':body['data']['csrf']})
initial = call('cores')[0]['data']
assert len(initial) == 4 and not any(c['binaryAvailable'] for c in initial)
print('PASS: fresh panel has four managed engine slots and no bundled engine.',flush=True)
for core in CORES:
    run('env','PYTHONPATH=/test-fixtures','skyui','install-core',core,input='INSTALL\n')
    ready(); assert call('auth/session')[0]['data']['authenticated']
    assert next(c for c in call('cores')[0]['data'] if c['coreId']==core)['binaryAvailable']
print('PASS: scoped installs, stopped state and owner session preservation.',flush=True)

def panel(): return call('panel')[0]['data']
def add(core, protocol, port, settings):
    body,_=call('connections','POST',{'revision':panel()['revision'],'connection':{'id':'','name':core,'coreId':core,'instanceId':'primary' if core=='mihomo' else core,'protocolId':protocol,'port':port,'enabled':True,'settings':settings}})
    return body['data']['connections'][-1]
cert=(SOURCE/'native/cert.pem').read_text(); key=(SOURCE/'native/key.pem').read_text()
connections=[
    add('xray','vless',35001,{'listen':'127.0.0.1','serverName':'www.kernel.org'}),
    add('sing-box','hysteria2',35002,{'listen':'127.0.0.1','serverName':'localhost','certificateSource':'custom','tlsCertificate':cert,'tlsPrivateKey':key,'obfs':'salamander'}),
    add('amneziawg','amneziawg',35003,{}),
    add('mihomo','mieru',35004,{'listen':'127.0.0.1'}),
]
body,_=call('recipients','POST',{'revision':panel()['revision'],'recipient':{'id':'','name':'all engines','enabled':True,'connectionIds':[c['id'] for c in connections]}})
recipient=body['data']['recipients'][0]
for core in CORES:
    identity='primary' if core=='mihomo' else core
    call('cores/'+identity+'/actions/start','POST',{})
data=panel(); assert all(data['instanceReadiness'].values())
pids={core:run('systemctl','show','sky-ui-'+core+'.service','--property=MainPID','--value').strip() for core in CORES}
assert all(int(pid)>1 for pid in pids.values())
print('PASS: real native validation, grants and concurrent systemd engine readiness.',flush=True)

# Editing a native listener restarts only its owning engine.
connection=dict(connections[1]);connection['port']=35012
call('connections/'+connection['id'],'PUT',{'revision':panel()['revision'],'connection':connection})
for core in ('mihomo','xray','amneziawg'):
    assert run('systemctl','show','sky-ui-'+core+'.service','--property=MainPID','--value').strip()==pids[core]
assert run('systemctl','show','sky-ui-sing-box.service','--property=MainPID','--value').strip()!=pids['sing-box']
assert panel()['instanceReadiness']['sing-box']
print('PASS: configuration activation is scoped to one engine.',flush=True)

for core in CORES:
    previous={c:run('systemctl','show','sky-ui-'+c+'.service','--property=MainPID','--value').strip() for c in CORES}
    run('env','PYTHONPATH=/test-fixtures','skyui','update-core',core,input='UPDATE\n');ready()
    current={c:run('systemctl','show','sky-ui-'+c+'.service','--property=MainPID','--value').strip() for c in CORES}
    assert current[core]!=previous[core]
    assert all(current[c]==previous[c] for c in CORES if c!=core)
    assert all(panel()['instanceReadiness'].values())
print('PASS: verified engine replacement restarts only the selected engine.',flush=True)

before={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in ['/etc/sky-ui/gateway.secret','/etc/sky-ui/controller.secret','/etc/sky-ui/owner.seed']}
run('env','PYTHONPATH=/test-fixtures','skyui','backup');ready()
backup=max(Path('/var/lib/sky-ui-maintenance/backups').glob('*.json'),key=lambda p:p.stat().st_mtime_ns).stem
run('env','PYTHONPATH=/test-fixtures','bash','/source/install.sh','--bundle','/source/build/releases/sky-ui-linux-amd64.tar.gz');ready()
assert call('auth/session')[0]['data']['authenticated']
assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==sha for p,sha in before.items())
assert len(panel()['connections'])==4
print('PASS: backup, repeated install, credentials, sessions and records preserved.',flush=True)

changed=dict(next(c for c in panel()['connections'] if c['coreId']=='sing-box'));changed['port']=35022
call('connections/'+changed['id'],'PUT',{'revision':panel()['revision'],'connection':changed})
run('env','PYTHONPATH=/test-fixtures','skyui','restore',backup,input='RESTORE\n');ready()
assert not call('auth/session')[0]['data']['authenticated']
body,response=call('auth/login','POST',{'username':'admin','password':password})
headers.update(Cookie=response['Set-Cookie'].split(';',1)[0],**{'X-Sky-UI-CSRF':body['data']['csrf']})
assert next(c for c in panel()['connections'] if c['coreId']=='sing-box')['port']==35012
assert all(panel()['instanceReadiness'].values())
print('PASS: native backup validation, all-engine restore and session revocation.',flush=True)

run('env','PYTHONPATH=/test-fixtures','skyui','remove-core','sing-box',input='REMOVE\n');ready()
data=panel();assert not data['coreAvailability']['sing-box'] and len(data['connections'])==4
assert all(data['instanceReadiness'][i] for i in ('primary','xray','amneziawg'))
call('recipients/'+recipient['id'],'PUT',{'revision':data['revision'],'recipient':{**recipient,'enabled':False}})
assert not panel()['recipients'][0]['enabled']
run('env','PYTHONPATH=/test-fixtures','skyui','install-core','sing-box',input='INSTALL\n');ready()
assert next(c for c in call('cores')[0]['data'] if c['coreId']=='sing-box')['desiredState']=='stopped'
assert not panel()['recipients'][0]['enabled']
print('PASS: removal is visible, unrelated engines stay ready, revocation and reinstall retain identity.',flush=True)

run('skyui','uninstall',input='DELETE\n')
for path in ['/opt/sky-ui','/etc/sky-ui','/var/lib/sky-ui','/var/lib/sky-ui-maintenance','/var/lib/sky-ui-amneziawg-network','/usr/local/bin/skyui']:
    assert not Path(path).exists(),path
assert not any(p.name.startswith('skyawg') for p in Path('/sys/class/net').iterdir())
assert subprocess.run(['nft','list','table','ip','sky_ui_awg'],capture_output=True).returncode!=0
assert Path('/unrelated-fixture').read_text()=='preserve me'
print('PASS: full uninstall removes managed services, data, interfaces and NAT without touching the sentinel.',flush=True)
