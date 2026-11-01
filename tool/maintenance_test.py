#!/usr/bin/env python3
"""Maintenance boundary, snapshot and rollback regression tests (Linux)."""
import gzip
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import tarfile
import tempfile
import unittest
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1] / "deploy"))
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('maintenance', Path(__file__).resolve().parents[1] / 'deploy/maintenance.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.overrides = patch.multiple(m, STATE=self.root / 'state', DATA=self.root / 'data',
            ETC=self.root / 'etc', EDGE=self.root / 'edge', CORES=self.root / 'cores', CURRENT=self.root / 'release')
        self.overrides.start()
        for path in [m.STATE / 'work', m.STATE / 'inbox', m.STATE / 'backups', m.DATA / 'instances',
                     m.DATA / 'cores/mihomo', m.ETC, m.EDGE / 'data', m.CORES / 'mihomo', m.CURRENT]:
            path.mkdir(parents=True, exist_ok=True)
        (m.CURRENT / 'VERSION').write_text('fixture-panel')

    def tearDown(self):
        self.overrides.stop()
        self.temporary.cleanup()

    def elf(self):
        header=bytearray(64);header[:6]=b'\x7fELF\x02\x01';header[18:20]=(62).to_bytes(2,'little')
        return bytes(header)+b'fixture'

    def fixtures(self):
        files = {name: b'fixture' for name in ['data/panel.sqlite', 'data/owner.sqlite', 'etc/server.env',
             'etc/gateway.secret', 'etc/controller.secret', 'etc/Caddyfile', 'data/cores/mihomo/config.yaml']}
        return files

    def test_roundtrip_and_content_hashes(self):
        files = self.fixtures()
        archive, _ = m.pack_backup(files, {'version': 'fixture'})
        found, manifest = m.unpack_backup(archive)
        self.assertEqual(files, found)
        self.assertEqual(manifest['version'], 'fixture')

    def test_traversal_links_duplicate_and_unbounded_members_rejected(self):
        for name, kind, size in [('.. /root', tarfile.REGTYPE, 0), ('/etc/shadow', tarfile.REGTYPE, 0),
                ('etc/owner.seed', tarfile.SYMTYPE, 0), ('data/panel.sqlite', tarfile.REGTYPE, m.MAX_ARCHIVE + 1)]:
            data = io.BytesIO()
            with tarfile.open(fileobj=data, mode='w:gz') as archive:
                entry = tarfile.TarInfo(name)
                entry.type, entry.size, entry.linkname = kind, size, '/etc/shadow'
                archive.addfile(entry)
            with self.assertRaises(m.MaintenanceError):
                m.unpack_backup(data.getvalue())

    def test_checksum_mismatch_rejected(self):
        files = self.fixtures()
        _, manifest = m.pack_backup(files, {})
        files['data/panel.sqlite'] = b'corrupted'
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:gz') as archive:
            for name, value in [*files.items(), ('manifest.json', json.dumps(manifest).encode())]:
                entry = tarfile.TarInfo(name)
                entry.size = len(value)
                archive.addfile(entry, io.BytesIO(value))
        with self.assertRaisesRegex(m.MaintenanceError, 'checksum'):
            m.unpack_backup(data.getvalue())

    def test_symlink_and_hardlink_files_rejected(self):
        original = self.root / 'original'
        original.write_bytes(b'private')
        link = self.root / 'link'
        link.symlink_to(original)
        with self.assertRaises(OSError):
            m.read_regular(link)
        link.unlink()
        os.link(original, link)
        with self.assertRaises(m.MaintenanceError):
            m.read_regular(link)

    def test_parent_directory_symlink_rejected(self):
        actual = self.root / 'actual'
        actual.mkdir()
        (actual / 'private').write_bytes(b'fixture')
        alias = self.root / 'alias'
        alias.symlink_to(actual, target_is_directory=True)
        with self.assertRaises(OSError):
            m.read_regular(alias / 'private')

    def test_snapshot_copies_live_wal_and_removes_only_copied_sessions(self):
        databases = []
        try:
            for name in ['panel', 'owner']:
                db = sqlite3.connect(m.DATA / (name + '.sqlite'))
                databases.append(db)
                db.execute('PRAGMA journal_mode=WAL')
                db.execute('CREATE TABLE sessions(id TEXT)')
                db.execute("INSERT INTO sessions VALUES('fixture-session')")
                db.commit()
            files = m.snapshot_files()
            restored = self.root / 'owner-copy.sqlite'
            restored.write_bytes(files['data/owner.sqlite'])
            with sqlite3.connect(restored) as copy:
                self.assertEqual(copy.execute('SELECT count(*) FROM sessions').fetchone()[0], 0)
            self.assertEqual(databases[1].execute('SELECT count(*) FROM sessions').fetchone()[0], 1)
        finally:
            for db in databases:
                db.close()

    def test_request_rejects_arbitrary_commands_and_paths(self):
        request = m.STATE / 'inbox/request.json'
        for value in [{'id': 'a' * 32, 'action': 'shell', 'command': 'false'},
                      {'id': 'a' * 32, 'action': 'restore', 'backupId': '../../etc'},
                      {'id': 'a' * 32, 'action': 'update', 'core': 'mihomo', 'tag': 'v1.0.0', 'url': 'https://evil.test'}]:
            request.write_text(json.dumps(value))
            with self.assertRaises(m.MaintenanceError):
                m.consume_request(request, os.getuid())
        request.write_text(json.dumps({'id': 'b' * 32, 'action': 'backup'}))
        self.assertEqual(m.consume_request(request, os.getuid())['action'], 'backup')
        self.assertFalse(request.exists())

    def test_only_project_verified_release_for_this_panel_and_platform_is_allowed(self):
        (m.CURRENT / 'VERSION').write_text('fixture-panel')
        asset = {'verified': True, 'asset': 'mihomo-fixture.gz', 'sha256': 'a' * 64}
        release = {'version': 'v1.2.3', 'verified': True, 'panelVersions': ['fixture-panel'],
                   'platforms': {'linux-amd64': asset}}
        catalog = {'schemaVersion': 1, 'coreId': 'mihomo', 'releases': [release]}
        with patch.object(m, 'download', side_effect=lambda url, limit: json.dumps(catalog).encode()) as fetch, patch.object(m.platform, 'machine', return_value='x86_64'):
            self.assertEqual(m.latest_mihomo()[0], 'v1.2.3')
            self.assertEqual(fetch.call_args.args[0], m.CATALOG_BASE + '/mihomo.json')
            for target, key, value in [(release, 'verified', False), (release, 'panelVersions', ['other']),
                                       (asset, 'verified', False), (asset, 'sha256', 'bad')]:
                original = target[key]
                target[key] = value
                with self.assertRaises(m.MaintenanceError):
                    m.latest_mihomo('v1.2.3')
                target[key] = original
            catalog['releases'].append(dict(release))
            with self.assertRaisesRegex(m.MaintenanceError, 'catalog_unavailable'):
                m.latest_mihomo('v1.2.3')

    def test_catalog_unavailable_never_uses_upstream_latest(self):
        with patch.object(m, 'download', side_effect=OSError('offline')) as fetch:
            with self.assertRaisesRegex(m.MaintenanceError, 'catalog_unavailable'):
                m.latest_mihomo()
            self.assertEqual(fetch.call_count, 1)
            self.assertIn('/sky_ui/main/compatibility/', fetch.call_args.args[0])

    def test_cli_reports_pre_worker_service_failure_and_releases_its_request(self):
        owner = SimpleNamespace(pw_uid=os.getuid(),pw_gid=os.getgid())
        with patch.object(m,'run',return_value=b'failed\n'), patch.object(m,'active',return_value=False), \
             patch.object(m.time,'monotonic',side_effect=[0,1,7]):
            with self.assertRaisesRegex(m.MaintenanceError,'skyui logs all'):
                m.cli(['backup'],owner)
        self.assertFalse((m.STATE / 'inbox/request.json').exists())

    def removal_fixture(self):
        root=m.CORES/'mihomo';slot=root/('v1.2.3-'+'a'*16);slot.mkdir()
        for name in ['mihomo','LICENSE','artifact.json']:(slot/name).write_text('fixture')
        (root/'current').symlink_to(slot)
        (m.DATA/'instances/primary.json').write_text(json.dumps({'instanceId':'primary','coreId':'mihomo','desiredState':'running'}))
        (m.DATA/'cores/mihomo/config.yaml').write_text('preserve-native-config')
        return root,slot

    def removal_run(self,args):
        if args[0]=='runuser':
            path=Path(args[-2]);self.assertTrue(path.is_relative_to(self.root));path.write_text(args[-1])
        return b''

    def test_remove_stops_core_and_preserves_configuration(self):
        root,slot=self.removal_fixture()
        with patch.object(m,'run',side_effect=self.removal_run) as run,patch.object(m,'active',return_value=False):
            m.remove_core('mihomo',os.getgid(),os.getuid())
        self.assertEqual(run.call_args_list[0].args[0],['systemctl','stop','sky-ui-mihomo.service'])
        self.assertFalse(slot.exists());self.assertFalse((root/'current').exists())
        self.assertTrue((root/'removed.json').is_file())
        self.assertEqual((m.DATA/'cores/mihomo/config.yaml').read_text(),'preserve-native-config')
        self.assertEqual(json.loads((m.DATA/'instances/primary.json').read_text())['desiredState'],'stopped')
        self.assertFalse((m.STATE/'core-remove-intent.json').exists())

    def test_remove_refuses_foreign_slot_file_before_stopping_any_service(self):
        root,slot=self.removal_fixture()
        target=self.root/'unrelated';target.write_text('preserve')
        (slot/'LICENSE').unlink();(slot/'LICENSE').symlink_to(target)
        with patch.object(m,'run') as run:
            with self.assertRaises(Exception):m.remove_core('mihomo',os.getgid(),os.getuid())
            run.assert_not_called()
        self.assertEqual(target.read_text(),'preserve');self.assertTrue((root/'current').exists())

    def test_failed_stop_keeps_binary_and_durable_removal_intent(self):
        root,slot=self.removal_fixture()
        with patch.object(m,'run',return_value=b''),patch.object(m,'active',return_value=True):
            with self.assertRaisesRegex(m.MaintenanceError,'service_stop_timeout'):
                m.remove_core('mihomo',os.getgid(),os.getuid())
        self.assertTrue((slot/'mihomo').exists());self.assertTrue((root/'current').exists())
        self.assertTrue((m.STATE/'core-remove-intent.json').exists())
        with patch.object(m,'run',side_effect=self.removal_run),patch.object(m,'active',return_value=False), \
             patch.object(m.pwd,'getpwnam',return_value=SimpleNamespace(pw_uid=os.getuid())):
            m.recover(os.getgid())
        self.assertFalse(slot.exists());self.assertFalse((m.STATE/'core-remove-intent.json').exists())

    def test_update_rolls_back_link_on_readiness_failure(self):
        root = m.CORES / 'mihomo'
        previous = root / 'old'
        previous.mkdir()
        (root / 'current').symlink_to(previous)
        payload = gzip.compress(self.elf())
        calls = []
        def ready(*args, **kwargs):
            calls.append(kwargs.get('version'))
            if 'version' in kwargs:
                raise m.MaintenanceError('controller_not_ready')
        with patch.object(m, 'latest_mihomo', return_value=('v1.2.3', 'fixed', m.digest(payload))), \
                patch.object(m, 'download', side_effect=lambda url, limit: payload if url == 'fixed' else b'Fixture license'), patch.object(m, 'candidate_validate'), \
                patch.object(m, 'run', return_value=b'mihomo v1.2.3'), patch.object(m, 'active', return_value=True), \
                patch.object(m, 'ready', side_effect=ready), patch.object(m, 'environment', return_value={}):
            with self.assertRaisesRegex(m.MaintenanceError, 'update_rolled_back'):
                m.update_core('mihomo', 'v1.2.3', os.getgid())
        self.assertEqual((root / 'current').resolve(), previous)
        self.assertEqual(calls, ['v1.2.3', None])
        self.assertFalse((m.STATE / 'update-intent.json').exists())

    def test_candidate_directory_remains_executable_with_private_worker_umask(self):
        root = m.CORES / 'mihomo'
        old = root / 'old'
        old.mkdir()
        (root / 'current').symlink_to(old)
        binary = self.elf()
        payload = gzip.compress(binary)
        previous_mask = os.umask(0o077)
        try:
            with patch.object(m, 'latest_mihomo', return_value=('v1.2.3', 'fixed', m.digest(payload))), \
                    patch.object(m, 'download', side_effect=lambda url, limit: payload if url == 'fixed' else b'Fixture license'), patch.object(m, 'candidate_validate'), \
                    patch.object(m, 'run', return_value=b'mihomo v1.2.3'), patch.object(m, 'active', return_value=False):
                m.update_core('mihomo', 'v1.2.3', os.getgid())
            self.assertEqual((root / ('v1.2.3-' + m.digest(binary)[:16])).stat().st_mode & 0o777, 0o755)
        finally:
            os.umask(previous_mask)

    def test_bad_download_never_touches_binary_link(self):
        root = m.CORES / 'mihomo'
        old = root / 'old'
        old.mkdir()
        (root / 'current').symlink_to(old)
        with patch.object(m, 'latest_mihomo', return_value=('v1.2.3', 'fixed', 'a' * 64)), \
                patch.object(m, 'download', return_value=b'corrupt'), patch.object(m, 'run') as commands:
            with self.assertRaisesRegex(m.MaintenanceError, 'checksum_failed'):
                m.update_core('mihomo', 'v1.2.3', os.getgid())
            commands.assert_not_called()
        self.assertEqual((root / 'current').resolve(), old)

    def restore_fixture(self):
        files = self.fixtures()
        # This fixture represents a backup restored with mihomo installed.
        binary = m.CORES / 'mihomo/current/mihomo'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b'fixture native binary')
        for name in ['panel', 'owner']:
            path = self.root / (name + '.sqlite')
            with sqlite3.connect(path) as db:
                db.execute('CREATE TABLE sessions(id TEXT)')
                db.execute("INSERT INTO sessions VALUES('obsolete')")
                db.execute('PRAGMA user_version=1')
            files['data/' + path.name] = path.read_bytes()
        (m.CURRENT / 'VERSION').write_text('fixture')
        manifest = {'version': 'fixture', 'machine': m.digest(m.read_regular(Path('/etc/machine-id'), 256))}
        data, _ = m.pack_backup(files, manifest)
        identity = 'a' * 32
        (m.STATE / 'backups' / (identity + '.tar.gz')).write_bytes(data)
        return identity, files

    def test_restore_validates_before_applying_and_invalidates_sessions(self):
        identity, files = self.restore_fixture()
        applied = []
        with patch.object(m, 'run', return_value=b''), patch.object(m, 'candidate_validate') as validation, \
                patch.object(m, 'create_backup', return_value={'id': 'b' * 32}), \
                patch.object(m, 'snapshot_files', return_value={'previous': b'fixture'}), \
                patch.object(m, 'active', side_effect=lambda unit: unit in ('sky-ui.service','sky-ui-mihomo.service','sky-ui-edge.service','sky-ui-certificates.timer')), patch.object(m, 'ready'), \
                patch.object(m, 'environment', return_value={}), patch.object(m, 'api_ready'), \
                patch.object(m, 'apply_files', side_effect=lambda data, gid: applied.append(data)):
            result = m.restore_backup(identity, os.getgid())
            validation.assert_called_once()
        self.assertEqual(result['restored'], identity)
        self.assertEqual(len(applied), 1)
        path = self.root / 'restored-owner.sqlite'
        path.write_bytes(applied[0]['data/owner.sqlite'])
        with sqlite3.connect(path) as db:
            self.assertEqual(db.execute('SELECT count(*) FROM sessions').fetchone()[0], 0)
        self.assertFalse((m.STATE / 'restore-intent.json').exists())

    def test_restore_readiness_failure_restores_previous_files(self):
        identity, files = self.restore_fixture()
        previous = {'previous': b'fixture'}
        applied = []
        with patch.object(m, 'run', return_value=b''), patch.object(m, 'candidate_validate'), \
                patch.object(m, 'create_backup', return_value={'id': 'b' * 32}), \
                patch.object(m, 'snapshot_files', return_value=previous), patch.object(m, 'active', side_effect=lambda unit: unit in ('sky-ui.service','sky-ui-mihomo.service','sky-ui-edge.service','sky-ui-certificates.timer')), \
                patch.object(m, 'ready', side_effect=[m.MaintenanceError('not_ready'), None]), \
                patch.object(m, 'environment', return_value={}), patch.object(m, 'api_ready'), \
                patch.object(m, 'apply_files', side_effect=lambda data, gid: applied.append(data)):
            with self.assertRaisesRegex(m.MaintenanceError, 'restore_rolled_back'):
                m.restore_backup(identity, os.getgid())
        self.assertEqual(applied[-1], previous)
        self.assertFalse((m.STATE / 'restore-intent.json').exists())

    def test_boot_recovery_restores_previous_binary_link(self):
        root = m.CORES / 'mihomo'
        old, candidate = root / 'old', root / 'candidate'
        old.mkdir()
        candidate.mkdir()
        (root / 'current').symlink_to(candidate)
        (m.STATE / 'update-intent.json').write_text(json.dumps({'path': str(old)}))
        (m.STATE / 'result.json').write_text(json.dumps({'id': 'a' * 32, 'status': 'running'}))
        m.recover(os.getgid())
        self.assertEqual((root / 'current').resolve(), old)
        self.assertEqual(json.loads((m.STATE / 'result.json').read_text())['error'], 'maintenance_interrupted')


if __name__ == '__main__':
    unittest.main()
