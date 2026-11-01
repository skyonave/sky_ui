#!/usr/bin/env python3
"""Validate the AWG root boundary without invoking networking or a live service."""
import base64
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'deploy'))
import amnezia_network as awg


class EngineTests(unittest.TestCase):
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
