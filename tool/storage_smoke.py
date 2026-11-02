"""Native cleanup and journal acceptance, only in the disposable install guest."""
import json
import os
from pathlib import Path
import socket
import subprocess
import time

assert os.geteuid()==0
assert Path('/run/systemd/container').read_text().strip()=='systemd-nspawn'
assert socket.gethostname()=='sky-ui-install-test'
assert Path('/unrelated-fixture').read_text()=='preserve me'


def run(*args):
    result=subprocess.run(args,capture_output=True,text=True,timeout=90)
    assert result.returncode==0,(args[0],result.stderr[-500:])
    return result.stdout


def quiet():
    for _ in range(100):
        state=run('systemctl','show','sky-ui-cleanup.service','--property=ActiveState','--value').strip()
        if state not in ('active','activating','deactivating') and not Path('/var/lib/sky-ui-maintenance/cleanup-intent.json').exists():return
        time.sleep(.1)
    raise AssertionError('Cleanup did not settle')


def cleanup():
    quiet()
    run('systemctl','start','sky-ui-cleanup.service')
    assert not Path('/var/lib/sky-ui-maintenance/cleanup-intent.json').exists()


for index in range(2):
    unit='sky-ui-journal-probe-'+str(os.getpid())+'-'+str(index)
    if index:run('journalctl','--namespace=sky-ui','--rotate')
    run('systemd-run','--quiet','--wait','--unit='+unit,'--property=LogNamespace=sky-ui','/usr/bin/echo','skyui-journal-proof')
    for _ in range(30):
        output=run('runuser','-u','sky-ui','--','journalctl','--namespace=+sky-ui','--unit='+unit,'--no-pager','--output=cat')
        if 'skyui-journal-proof' in output:break
        time.sleep(.1)
    else:raise AssertionError('The panel account cannot read its namespaced journal')
print('PASS: panel journal access before and after rotation.',flush=True)

assert run('systemctl','is-active','sky-ui-cleanup.timer').strip()=='active'
quiet()
releases=Path('/opt/sky-ui/releases')
current=Path('/opt/sky-ui/current').resolve()
history=json.loads((releases/'retention.json').read_text())
protected={current}
if history['previous']:protected.add(Path(history['previous']))
fake=[]
for version in ['0.0.1','0.0.2','0.0.3']:
    p=releases/(version+'-amd64');assert not p.exists();p.mkdir();(p/'VERSION').write_text(version);fake.append(p)
child=subprocess.Popen(['sleep','60'],cwd=fake[2])
orphan=Path('/var/tmp/sky-ui-install.ZZZZZZZZ');assert not orphan.exists();orphan.mkdir();os.utime(orphan,(1,1))
before={p.name for p in Path('/var/lib/sky-ui-maintenance/backups').iterdir()}
try:
    cleanup()
    assert not fake[0].exists() and not fake[1].exists()
    assert fake[2].exists(),'A live working directory was deleted'
    assert not orphan.exists(),'Abandoned installer files were retained'
finally:
    child.terminate();child.wait()
cleanup()
assert not fake[2].exists()
assert all(p.exists() for p in protected)
assert {p.name for p in Path('/var/lib/sky-ui-maintenance/backups').iterdir()}==before
print('PASS: obsolete releases expire, live references and owner backups remain.',flush=True)
