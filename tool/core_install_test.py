#!/usr/bin/env python3
"""Artifact approval, first install, preservation and legacy migration checks."""
import gzip
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1] / 'deploy'))
import core_artifacts as a
import core_install as c


def elf(machine=62):
    data=bytearray(64)
    data[:6]=b'\x7fELF\x02\x01'
    data[18:20]=machine.to_bytes(2,'little')
    return bytes(data)+b'fixture'


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.base=Path(self.temp.name)
        self.root=self.base/'cores/mihomo'
        self.releases=self.base/'releases'
        self.root.mkdir(parents=True)
        self.releases.mkdir()
        self.output=self.base/'prepared'
        self.binary=elf()
        self.compressed=gzip.compress(self.binary)
        self.catalog={'schemaVersion':1,'coreId':'mihomo','releases':[{
            'version':'v1.19.33','verified':True,'panelVersions':['fixture-panel'],
            'platforms':{'linux-amd64':{'verified':True,'asset':'mihomo.gz',
                'sha256':hashlib.sha256(self.compressed).hexdigest()}}}]}
        self.calls=[]

    def tearDown(self):
        self.temp.cleanup()

    def fetch(self,url,limit):
        self.calls.append(url)
        if url==a.CATALOG_BASE+'/mihomo.json':return json.dumps(self.catalog).encode()
        if url=='https://github.com/MetaCubeX/mihomo/releases/download/v1.19.33/mihomo.gz':return self.compressed
        if url=='https://raw.githubusercontent.com/MetaCubeX/mihomo/v1.19.33/LICENSE':return b'Fixture license'
        self.fail('Unexpected network destination: '+url)

    def prepare(self):
        return c.prepare('fixture-panel','linux-amd64',self.output,
                         root=self.root,releases=self.releases,fetch=self.fetch)

    def test_first_install_has_independent_binary_and_license(self):
        self.prepare()
        binary=c.activate(self.output,root=self.root,releases=self.releases)
        self.assertTrue(binary.is_relative_to(self.root))
        self.assertEqual(binary.read_bytes(),self.binary)
        self.assertEqual((binary.parent/'LICENSE').read_bytes(),b'Fixture license')
        self.assertEqual((self.root/'current').resolve(),binary.parent)
        self.assertEqual(len(self.calls),3)

    def test_intentionally_removed_core_is_not_reinstalled_by_panel_install(self):
        (self.root/'removed.json').write_text(json.dumps({'coreId':'mihomo','removed':True}))
        denied=Mock(side_effect=AssertionError('Removed core must stay removed'))
        result=c.prepare('fixture-panel','linux-amd64',self.output,root=self.root,releases=self.releases,fetch=denied)
        self.assertIsNone(result)
        denied.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_repeated_panel_install_does_not_download_or_replace_core(self):
        self.prepare()
        installed=c.activate(self.output,root=self.root,releases=self.releases)
        timestamp=installed.stat().st_mtime_ns
        denied=Mock(side_effect=AssertionError('Installed core must not need network access'))
        selected=c.prepare('new-panel','unsupported',self.base/'unused',
                           root=self.root,releases=self.releases,fetch=denied)
        self.assertEqual(selected,installed)
        self.assertEqual(c.activate(self.base/'unused',root=self.root,releases=self.releases),installed)
        self.assertEqual(installed.stat().st_mtime_ns,timestamp)
        denied.assert_not_called()

    def test_legacy_bundle_binary_migrates_unchanged_without_download(self):
        old=self.releases/'old/bin';old.mkdir(parents=True)
        (old/'mihomo').write_bytes(self.binary);(old/'mihomo').chmod(0o755)
        (old.parent/'licenses').mkdir();(old.parent/'licenses/mihomo.LICENSE').write_bytes(b'Original license')
        (self.root/'current').symlink_to(old)
        denied=Mock(side_effect=AssertionError('Legacy core must be retained'))
        c.prepare('new-panel','linux-amd64',self.output,root=self.root,releases=self.releases,fetch=denied)
        installed=c.activate(self.output,root=self.root,releases=self.releases)
        self.assertEqual(installed.read_bytes(),(old/'mihomo').read_bytes())
        self.assertEqual((installed.parent/'LICENSE').read_bytes(),b'Original license')
        self.assertTrue(installed.is_relative_to(self.root))
        denied.assert_not_called()

    def test_unverified_or_wrong_platform_never_downloads_binary(self):
        self.catalog['releases'][0]['verified']=False
        with self.assertRaises(a.ArtifactError):self.prepare()
        self.assertEqual(self.calls,[a.CATALOG_BASE+'/mihomo.json'])
        self.assertFalse(self.output.exists())
        self.catalog['releases'][0]['verified']=True
        with self.assertRaises(a.ArtifactError):
            a.prepare('mihomo','fixture-panel','linux-arm64',self.output,fetch=self.fetch)
        self.assertFalse(self.output.exists())

    def test_checksum_failure_leaves_no_prepared_binary_or_active_link(self):
        self.catalog['releases'][0]['platforms']['linux-amd64']['sha256']='0'*64
        with self.assertRaisesRegex(a.ArtifactError,'checksum_failed'):self.prepare()
        self.assertFalse(self.output.exists())
        self.assertFalse((self.root/'current').is_symlink())

    def test_wrong_elf_architecture_is_rejected_before_execution(self):
        self.compressed=gzip.compress(elf(183))
        self.catalog['releases'][0]['platforms']['linux-amd64']['sha256']=hashlib.sha256(self.compressed).hexdigest()
        with self.assertRaisesRegex(a.ArtifactError,'binary_invalid'):self.prepare()
        self.assertFalse(self.output.exists())

    def test_foreign_current_target_is_rejected_without_network(self):
        outside=self.base/'foreign';outside.mkdir();(outside/'mihomo').write_bytes(self.binary)
        (self.root/'current').symlink_to(outside)
        with self.assertRaisesRegex(a.ArtifactError,'unsafe_file'):self.prepare()
        self.assertEqual(self.calls,[])

    def test_version_mismatch_never_validates_configuration(self):
        binary=self.prepare()
        with patch.object(c.subprocess,'run',return_value=SimpleNamespace(stdout='Mihomo v0.0.1')) as run:
            with self.assertRaisesRegex(a.ArtifactError,'version_mismatch'):
                c.validate(binary,self.base/'config',self.base)
        self.assertEqual(run.call_count,1)
        self.assertEqual(run.call_args.args[0][:3],['runuser','-u','sky-ui-core'])


if __name__=='__main__':unittest.main()
