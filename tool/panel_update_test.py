#!/usr/bin/env python3
"""Release selection, integrity and updater safety checks without production services."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch, Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'deploy'))
import core_artifacts as a
import panel_releases as r
import panel_update as u
import maintenance as m


class ReleaseTests(unittest.TestCase):
    def release(self, tag='v0.6.0-dev.10', platform='linux-amd64', **changes):
        files = {'install.sh': b'#!/bin/sh\nexit 0\n', 'sky-ui-'+platform+'.tar.gz': b'fixture-bundle'}
        for name, data in list(files.items()):
            files[name+'.sha256'] = (hashlib.sha256(data).hexdigest()+'  '+name+'\n').encode()
        self.files = files
        result = {'tag_name': tag, 'draft': False, 'prerelease': True, 'assets': [
            {'name': name, 'state': 'uploaded', 'size': len(data),
             'digest': 'sha256:'+hashlib.sha256(data).hexdigest(),
             'browser_download_url': f'{r.REPOSITORY}/releases/download/{tag}/{name}'}
            for name, data in files.items()]}
        return dict(result, **changes)

    def fetch(self, releases):
        return lambda url, limit: json.dumps(releases).encode()

    def test_semver_numeric_prereleases_and_stable_precedence(self):
        for left, right in [('v0.6.0-dev.10','0.6.0-dev.9'), ('1.0.0','1.0.0-rc.9'),
                            ('1.0.0-beta','1.0.0-alpha'), ('2.0.0','1.99.99')]:
            self.assertGreater(r.compare(left,right),0)
            self.assertLess(r.compare(right,left),0)
        for invalid in ['v01.0.0', 'v1.0.0-dev.01', '../v1.0.0', 'v1.0.0;id', 'v1.0.0-']:
            self.assertIsNone(r.version(invalid))

    def test_development_updates_select_complete_newer_releases_only(self):
        valid=self.release();draft=self.release('v0.7.0',draft=True)
        incomplete=self.release('v0.8.0');incomplete['assets'].pop()
        choice=r.candidate('0.6.0-dev.9','linux-amd64',fetch=self.fetch([incomplete,draft,valid]))
        self.assertEqual(choice['tag'],'v0.6.0-dev.10')
        self.assertIsNone(r.candidate('0.6.0-dev.10','linux-amd64',fetch=self.fetch([valid])))
        self.assertIsNone(r.candidate('0.6.0-dev.9','linux-arm64',fetch=self.fetch([valid])))

    def test_stable_installations_are_not_moved_to_prereleases(self):
        rows=[self.release('v1.1.0-dev.1'), self.release('v1.0.1',prerelease=False)]
        self.assertEqual(r.candidate('1.0.0','linux-amd64',fetch=self.fetch(rows))['tag'],'v1.0.1')

    def test_urls_and_github_digests_cannot_be_substituted(self):
        for field,value in [('browser_download_url','https://example.test/installer'),('digest',None)]:
            release=self.release();release['assets'][0][field]=value
            self.assertIsNone(r.candidate('0.6.0-dev.1','linux-amd64',fetch=self.fetch([release])))

    def test_checksum_failure_writes_no_installable_files(self):
        release=self.release();selected=r.candidate('0.6.0-dev.1','linux-amd64',fetch=self.fetch([release]))
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(a.ArtifactError,'checksum_failed'):
                r.prepare(selected,'linux-amd64',directory,fetch=lambda url,limit:b'corrupt')
            self.assertEqual(list(Path(directory).iterdir()),[])

    def test_checksum_files_must_match_asset_content_and_name(self):
        release=self.release();self.files['install.sh.sha256']=b'0'*64+b'  install.sh\n'
        for asset in release['assets']:
            if asset['name']=='install.sh.sha256':asset.update(size=len(self.files[asset['name']]),digest='sha256:'+hashlib.sha256(self.files[asset['name']]).hexdigest())
        selected=r.candidate('0.6.0-dev.1','linux-amd64',fetch=self.fetch([release]))
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(a.ArtifactError,'checksum_failed'):
                r.prepare(selected,'linux-amd64',directory,fetch=lambda url,limit:self.files[url.rsplit('/',1)[1]])

    def test_release_is_revalidated_in_privileged_worker_before_any_stop(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);current=root/'current';current.mkdir();(current/'VERSION').write_text('0.6.0-dev.4')
            with patch.object(m,'CURRENT',current),patch.object(r,'candidate',return_value=None),patch.object(m,'run') as run:
                with self.assertRaisesRegex(m.MaintenanceError,'panel_update_unavailable'):
                    u.update(m,Mock(),{'tag':'v0.6.0-dev.5'},Mock(),Mock())
                run.assert_not_called()

    def test_atomic_write_rejects_symlink_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);outside=root/'outside';outside.mkdir();(root/'link').symlink_to(outside)
            with self.assertRaises(OSError):m.atomic(root/'link/config',b'payload')
            self.assertFalse((outside/'config').exists())


if __name__=='__main__':unittest.main()
