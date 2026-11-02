#!/usr/bin/env python3
"""Validate the AWG root boundary without invoking networking or a live service."""
import base64
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
import os
import io
import tarfile
import hashlib
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'deploy'))
import amnezia_network as awg
import engine_install as engine
import maintenance as maintenance


class EngineTests(unittest.TestCase):
    def test_low_disk_fails_before_toolchain_download_or_build(self):
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(engine.shutil,'disk_usage',return_value=SimpleNamespace(free=engine.AWG_BUILD_FREE_BYTES-1)), \
             patch.object(engine.artifacts,'download') as download:
            with self.assertRaisesRegex(maintenance.MaintenanceError,'^core_build_space_required$'):
                engine.build_awg(b'unused',Path(temporary),'v3.1.20260828',maintenance)
            download.assert_not_called()

    def test_root_sdk_directories_are_executable_under_private_worker_umask(self):
        def archive(files):
            output=io.BytesIO()
            with tarfile.open(fileobj=output,mode='w:gz') as tar:
                for name,data in files.items():
                    item=tarfile.TarInfo(name);item.size=len(data);item.mode=0o755 if '/bin/' in name else 0o644
                    tar.addfile(item,io.BytesIO(data))
            return output.getvalue()
        sdk=archive({'go/bin/go':b'fixture','go/pkg/tool/compile':b'fixture'})
        source=archive({'upstream/go.mod':b'module fixture\n'})
        account=SimpleNamespace(pw_uid=os.getuid(),pw_gid=os.getgid())
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            def compile_probe(args,**kwargs):
                self.assertEqual((root/'go').stat().st_mode & 0o777,0o755)
                self.assertEqual((root/'go/bin').stat().st_mode & 0o777,0o755)
                self.assertEqual((root/'go/pkg/tool').stat().st_mode & 0o777,0o755)
                self.assertIn('GOPATH='+str(root/'gopath'),args)
                self.assertIn('GOTMPDIR='+str(root/'tmp'),args)
                self.assertIn('TMPDIR='+str(root/'tmp'),args)
                self.assertEqual((root/'tmp').stat().st_mode & 0o777,0o700)
                (root/'amneziawg').write_bytes(b'compiled fixture')
            previous=os.umask(0o077)
            try:
                with patch.object(engine.shutil,'disk_usage',return_value=SimpleNamespace(free=engine.AWG_BUILD_FREE_BYTES)), \
                     patch.object(engine.pwd,'getpwnam',return_value=account),patch.object(engine.artifacts,'download',return_value=sdk), \
                     patch.dict(engine.GO_TOOLCHAINS,{'linux-amd64':('fixture.tar.gz',hashlib.sha256(sdk).hexdigest())}), \
                     patch.object(engine.artifacts,'target_platform',return_value='linux-amd64'):
                    result=engine.build_awg(source,root,'v3.1.20260828',SimpleNamespace(run=compile_probe,require=maintenance.require,read_regular=maintenance.read_regular))
                self.assertEqual(result,b'compiled fixture')
            finally:os.umask(previous)

    def test_engine_validation_uses_configuration_after_activation_freeze(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);cores=root/'cores';state=root/'state';data=root/'data'
            (cores/'sing-box').mkdir(parents=True);state.mkdir();data.mkdir()
            events=[]
            def artifacts(*args,**kwargs):
                events.append('download');return {'sing-box':b'fixture','LICENSE':b'fixture','artifact.json':b'{}'}
            with patch.multiple(maintenance,CORES=cores,STATE=state,DATA=data), \
                 patch.object(maintenance,'verified_release',return_value=('v1.14.4','fixture','hash')), \
                 patch.object(maintenance,'active',return_value=False),patch.object(engine.artifacts,'artifact_files',side_effect=artifacts), \
                 patch.object(engine,'validate',side_effect=lambda *args:events.append('validate')):
                engine.change('install','sing-box','v1.14.4',os.getgid(),os.getuid(),SimpleNamespace(**vars(maintenance)),before_activation=lambda:events.append('freeze'))
            self.assertEqual(events,['download','freeze','validate'])

    def setUp(self):
        key = base64.b64encode(bytes(range(32))).decode()
        options = {name: str(bounds[0]) for name, bounds in awg.BOUNDS.items()}
        options.update(Jmin='40', Jmax='70', RekeyAfterTime='120', RejectAfterTime='180',
                       ContentPaddingAddition='0-32', RandomTrailers='true', DisableCookies='true')
        self.value = {'version':'3.1', 'interfaces':[{'name':'skyawg1234abcd', 'address':'10.66.0.1/24',
            'port':35001,'mtu':1280,'privateKey':key,'headerProtectionKey':key,'options':options,
            'peers':[{'publicKey':key,'presharedKey':key,'address':'10.66.0.2/32'}]}]}

    def test_valid_payload_contains_only_native_uapi_fields(self):
        value = awg.validate(self.value)
        payload = awg.uapi_payload(value['interfaces'][0])
        self.assertIn(b'header_protection_key=', payload)
        self.assertIn(b'random_trailers=1\n', payload)
        self.assertIn(b'allowed_ip=10.66.0.2/32\n', payload)
        self.assertNotIn(b'PostUp', payload)

    def test_malformed_and_resource_unbounded_signature_packets_fail(self):
        for value in ['<r 9999>', '<b 0x123>', '<r -1>', '<r 20>\nlisten_port=80', 'shell']:
            with self.subTest(value=value), self.assertRaises(ValueError): awg.signature(value)
        awg.signature('<b 0x1234><r 24><rd 4><rc 8><t>')

    def test_net_and_key_invariants_are_checked_before_root_operations(self):
        for name, value in [('address','127.0.0.1/24'),('privateKey','bad'),('mtu',65535),('name','eth0')]:
            bad = copy.deepcopy(self.value); bad['interfaces'][0][name] = value
            with self.subTest(name=name), self.assertRaises((ValueError,TypeError)): awg.validate(bad)
        for name,value in [('S4','0'),('Jc','4294967295'),('RejectAfterTime','20')]:
            bad = copy.deepcopy(self.value); bad['interfaces'][0]['options'][name]=value
            with self.subTest(name=name), self.assertRaises(ValueError): awg.validate(bad)

    def test_peer_outside_subnet_duplicate_and_unknown_fields_fail(self):
        for mutation in ('outside','duplicate','hook'):
            bad = copy.deepcopy(self.value); interface = bad['interfaces'][0]
            if mutation == 'outside': interface['peers'][0]['address']='192.0.2.1/32'
            elif mutation == 'duplicate': interface['peers'].append(copy.deepcopy(interface['peers'][0]))
            else: interface['PostUp']='arbitrary command'
            with self.subTest(mutation=mutation), self.assertRaises(ValueError): awg.validate(bad)

    def test_symlinked_configuration_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); (root/'config.json').write_text(json.dumps(self.value))
            awg.load(root/'config.json')
            (root/'link.json').symlink_to(root/'config.json')
            with self.assertRaises(OSError): awg.load(root/'link.json')


if __name__ == '__main__': unittest.main()
