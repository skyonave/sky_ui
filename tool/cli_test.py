#!/usr/bin/env python3
"""CLI state and removal boundary tests. All destructive calls use a temporary tree."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'deploy'))
spec = importlib.util.spec_from_file_location('skyui_cli', Path(sys.path[0]) / 'cli.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
import panel_releases


class CliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.dirs = tuple(self.root / str(path).lstrip('/') for path in c.DIRECTORIES)
        self.mapping = {path: self.root / str(path).lstrip('/') for path in c.DIRECTORIES}
        self.patches = [patch.multiple(c, DIRECTORIES=self.dirs,
            COMMANDS=tuple(self.root / str(path).lstrip('/') for path in c.COMMANDS),
            SYSTEMD=self.root / 'etc/systemd/system', POLKIT=self.root / 'etc/polkit/rule',
            LOCKS=(self.root / 'lock-install', self.root / 'lock-setup')),
            patch.multiple(c.m, ETC=self.mapping[c.m.ETC], DATA=self.mapping[c.m.DATA],
                EDGE=self.mapping[c.m.EDGE], STATE=self.mapping[c.m.STATE])]
        for item in self.patches:
            item.start()
        for path in (*self.dirs, c.SYSTEMD):
            path.mkdir(parents=True, exist_ok=True)
        (c.m.ETC / 'managed-by-sky-ui').touch()
        binary=self.root/'fixture-core';binary.write_text('fixture')
        (c.m.ETC / 'server.env').write_text('SKY_UI_DATA_DIR=' + str(c.m.DATA)+'\nSKY_UI_CORE_BINARY='+str(binary))
        self.sentinel = self.root / 'unrelated-data'
        self.sentinel.write_text('keep')
        user = SimpleNamespace(pw_uid=10001,pw_gid=10001,pw_shell='/usr/sbin/nologin',pw_name='sky-ui')
        self.patches += [patch.object(c.pwd, 'getpwnam', return_value=user),
            patch.object(c.pwd,'getpwall',return_value=[]),
            patch.object(c.grp,'getgrnam',side_effect=KeyError)]
        for item in self.patches[2:]:
            item.start()
        # Fixtures are root-owned; emulate the dedicated installation owners for preflight only.
        self.real_trusted = c.trusted
        ownership = patch.object(c,'trusted',side_effect=lambda path, directory=False, uid=0:
                                self.real_trusted(path,directory,uid=os.getuid()))
        ownership.start()
        self.patches.append(ownership)

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.temp.cleanup()

    def test_cancel_changes_nothing(self):
        with patch.object(c,'run') as run:
            c.uninstall(confirm=lambda _: 'no')
            run.assert_not_called()
        self.assertTrue(c.m.ETC.exists())
        self.assertTrue(self.sentinel.exists())

    def test_symlinked_owned_root_is_rejected_before_commands(self):
        c.m.DATA.rmdir()
        c.m.DATA.symlink_to(self.root)
        with patch.object(c,'run') as run:
            with self.assertRaises(ValueError):
                c.uninstall(confirm=lambda _: 'DELETE')
            run.assert_not_called()
        self.assertEqual(self.sentinel.read_text(),'keep')

    def test_external_data_directory_is_not_deleted(self):
        (c.m.ETC / 'server.env').write_text('SKY_UI_DATA_DIR=' + str(self.root))
        with self.assertRaises(ValueError):
            c.removal_plan()
        self.assertTrue(self.sentinel.exists())

    def test_uninstall_removes_only_managed_tree_and_leaves_external_symlink_target(self):
        (c.m.DATA / 'external-link').symlink_to(self.sentinel)
        def fake_run(*args, **kwargs):
            return subprocess.CompletedProcess(args, 1 if args[0] == 'id' else 0, 'inactive\n')
        with patch.object(c,'run',side_effect=fake_run):
            c.uninstall(confirm=lambda _: 'DELETE')
        self.assertTrue(all(not path.exists() for path in self.dirs))
        self.assertEqual(self.sentinel.read_text(),'keep')

    def test_active_service_aborts_deletion(self):
        with patch.object(c,'run',return_value=subprocess.CompletedProcess([],0,'active\n')):
            with self.assertRaises(ValueError):
                c.uninstall(confirm=lambda _: 'DELETE')
        self.assertTrue(c.m.ETC.exists())

    def test_core_stop_persists_state_before_restart_of_api(self):
        (c.m.DATA / 'instances').mkdir()
        path = c.m.DATA / 'instances/primary.json'
        path.write_text(json.dumps({'instanceId':'primary','coreId':'mihomo','desiredState':'running'}))
        with patch.object(c.m,'active',return_value=True), patch.object(c.m,'atomic',side_effect=lambda p,b,**kw:p.write_bytes(b)), \
             patch.object(c.grp,'getgrnam',return_value=SimpleNamespace(gr_gid=10001)), patch.object(c,'status'), \
             patch.object(c,'run') as run:
            c.lifecycle('stop','core')
            self.assertEqual(json.loads(path.read_text())['desiredState'],'stopped')
            self.assertEqual([call.args for call in run.call_args_list], [
                ('systemctl','stop','sky-ui.service'), ('systemctl','stop','sky-ui-mihomo.service'),
                ('systemctl','reset-failed','sky-ui.service'),
                ('systemctl','start','sky-ui.service')])

    def test_first_core_start_creates_instance_directory(self):
        path = c.m.DATA / 'instances/primary.json'
        with patch.object(c.m,'active',return_value=False), patch.object(c.os,'chown'), \
             patch.object(c.m,'atomic',side_effect=lambda p,b,**kw:p.write_bytes(b)), \
             patch.object(c.grp,'getgrnam',return_value=SimpleNamespace(gr_gid=10001)), \
             patch.object(c,'status'), patch.object(c,'run'):
            c.lifecycle('start','core')
        self.assertEqual(json.loads(path.read_text()),{
            'instanceId':'primary','coreId':'mihomo','desiredState':'running'})

    def test_cancel_panel_update_does_not_queue_or_start_a_worker(self):
        current = self.root/'current'; current.mkdir(); (current/'VERSION').write_text('0.6.0-dev.4')
        with patch.object(c.m, 'CURRENT', current), patch.object(panel_releases, 'candidate', return_value={'tag':'v0.6.0-dev.5'}), \
                patch('builtins.input', return_value='no'), patch.object(c.m, 'run') as run:
            with self.assertRaisesRegex(c.m.MaintenanceError, 'cancelled'):
                c.m.cli(['update'], SimpleNamespace(pw_uid=os.getuid(), pw_gid=os.getgid()))
            run.assert_not_called()
        self.assertFalse((c.m.STATE/'inbox/request.json').exists())

    def test_panel_update_confirmation_queues_the_selected_tag_in_the_dedicated_worker(self):
        current = self.root/'current'; current.mkdir(); (current/'VERSION').write_text('0.6.0-dev.4')
        inbox = c.m.STATE/'inbox'; inbox.mkdir()
        queued = []
        def complete(args, **kwargs):
            if args[:2]==['systemctl','show']:return b'inactive\n'
            self.assertEqual(args, ['systemctl','start','--no-block','sky-ui-update.service'])
            payload = json.loads((inbox/'request.json').read_text()); queued.append(payload)
            (inbox/'request.json').unlink()
            (c.m.STATE/'result.json').write_text(json.dumps({**payload,'status':'completed'}))
            return b''
        with patch.object(c.m, 'CURRENT', current), patch.object(panel_releases, 'candidate', return_value={'tag':'v0.6.0-dev.5'}), \
                patch('builtins.input', return_value='UPDATE'), patch.object(c.m, 'active', return_value=False), \
                patch.object(c.m, 'run', side_effect=complete):
            c.m.cli(['update'], SimpleNamespace(pw_uid=os.getuid(), pw_gid=os.getgid()))
        self.assertEqual(queued[0]['action'], 'panel-update')
        self.assertEqual(queued[0]['tag'], 'v0.6.0-dev.5')
        self.assertRegex(queued[0]['id'], '^[a-f0-9]{32}$')

    def test_cleanup_command_starts_the_fixed_cleanup_unit(self):
        with patch.object(c,'run') as run:
            c.main(['cleanup'])
        run.assert_called_once_with('systemctl','start','sky-ui-cleanup.service')


if __name__ == '__main__':
    unittest.main()
