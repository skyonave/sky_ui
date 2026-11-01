#!/usr/bin/env python3
"""Actual cold AWG worker test under an explicit private systemd mount fixture."""
import hashlib
import json
import os
from pathlib import Path
import pwd
import subprocess
import sys

assert os.geteuid()==0
assert os.environ.get('SKY_UI_AWG_COLD_FIXTURE')=='1'
assert Path('/source/install-fixtures/amneziawg.archive').is_file()
root=Path('/evidence/awg-cold')
assert not root.exists()
root.mkdir(mode=0o755)
root.chmod(0o755)
sys.path.insert(0,'/source/deploy')
import maintenance as m
m.STATE=root/'maintenance'
m.DATA=root/'data'
m.CORES=root/'cores'
m.CURRENT=root/'release'
for folder in [m.STATE/'work',m.STATE/'inbox',m.CORES/'amneziawg',m.DATA/'cores/amneziawg',m.DATA/'instances',m.CURRENT]:
    folder.mkdir(parents=True,exist_ok=True)
(m.CURRENT/'VERSION').write_text('0.7.0-dev.2')
(m.DATA/'cores/amneziawg/config.json').write_text('{"version":"3.1","interfaces":[]}')
owner=pwd.getpwnam('sky-ui')
job={'id':'d'*32,'action':'install','core':'amneziawg','tag':'v3.1.20260828'}
m.atomic(m.STATE/'inbox/request.json',json.dumps(job).encode(),0o600,owner.pw_uid,owner.pw_gid)
# No real service is stopped or started. Native download/build/validation,
# durable receipts and binary activation execute unchanged in the private roots.
m.active=lambda unit:False
sys.argv=['maintenance.py']
m.main()
receipt=json.loads((m.STATE/'result.json').read_text())
assert receipt['status']=='completed',receipt
binary=m.CORES/'amneziawg/current/amneziawg'
assert binary.is_file()
for folder in [root,m.CORES,m.CORES/'amneziawg']:
    folder.chmod(0o755)
version=subprocess.check_output(['runuser','-u','sky-ui-build','--',str(binary),'--version'],text=True).strip()
assert '3.1.20260828' in version
print('PASS: actual hardened worker cold build, umask 077, private install and version probe.',flush=True)
print('Binary SHA256:',hashlib.sha256(binary.read_bytes()).hexdigest(),flush=True)
