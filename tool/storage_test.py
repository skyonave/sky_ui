"""Retention policy and deletion boundaries use private temporary directories."""
import json
import os
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'deploy'))
import maintenance as m
from storage import Retention, DAY


class StorageTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name)
        self.releases=self.root/'releases';self.releases.mkdir()
        self.state=self.root/'state';self.state.mkdir()
        for name in ['work','inbox','backups','logs']:(self.state/name).mkdir()
        self.cores=self.root/'cores';self.cores.mkdir()
        self.current=self.root/'current'
        self.api=SimpleNamespace(STATE=self.state,CORES=self.cores,CURRENT=self.current,atomic=m.atomic,read_regular=m.read_regular)
        self.temporary=self.root/'temporary';self.temporary.mkdir()
        self.retention=Retention(self.api,self.releases,self.root/'missing-proc',self.temporary)
        self.a=self.release('1.0.1');self.b=self.release('1.0.2');self.c=self.release('1.0.3')
        self.current.symlink_to(self.c)

    def tearDown(self):self.temp.cleanup()

    def release(self,version):
        p=self.releases/(version+'-amd64');p.mkdir();(p/'VERSION').write_text(version)
        return p

    def test_repeat_install_retains_real_previous_not_a_newer_failed_candidate(self):
        failed=self.release('1.0.4')
        self.retention.record_panel(str(self.b))
        self.retention.record_panel(str(self.c))
        self.retention.clean()
        self.assertEqual(set(p.name for p in self.releases.iterdir()),{'1.0.2-amd64','1.0.3-amd64','retention.json'})
        self.assertFalse(failed.exists())
        self.assertFalse(self.a.exists())

    def test_pending_restore_or_queued_request_prevents_cleanup(self):
        for p in [self.state/'restore-intent.json',self.state/'inbox/request.json']:
            p.write_text('{}')
            self.assertEqual(self.retention.clean(),{'skipped':'busy'})
            self.assertTrue(self.a.exists());p.unlink()

    def test_running_process_reference_preserves_an_older_release(self):
        proc=self.root/'proc/123';(proc/'fd').mkdir(parents=True)
        (proc/'exe').symlink_to(self.a/'bin/server')
        (proc/'cwd').symlink_to('/')
        (proc/'cmdline').write_bytes(b'fixture\0')
        (proc/'maps').write_text('')
        retention=Retention(self.api,self.releases,proc.parent,self.temporary)
        retention.record_panel(str(self.b));retention.clean()
        self.assertTrue(self.a.exists())

    def test_symlink_candidate_and_unrecognized_directory_are_not_followed(self):
        outside=self.root/'unrelated';outside.mkdir();(outside/'sentinel').touch()
        (self.releases/'9.0.0-amd64').symlink_to(outside)
        (self.releases/'notes').mkdir()
        self.retention.record_panel(str(self.b));self.retention.clean()
        self.assertTrue((outside/'sentinel').exists())
        self.assertTrue((self.releases/'notes').is_dir())

    def test_manual_and_legacy_backups_survive_automatic_rescue_retention(self):
        backups=self.state/'backups'
        for n,purpose in [(1,'manual'),(2,None),(3,'rescue'),(4,'rescue')]:
            ident=f'{n:032x}';p=backups/(ident+'.json')
            p.write_text(json.dumps({} if purpose is None else {'purpose':purpose}))
            (backups/(ident+'.tar.gz')).write_bytes(b'fixture')
            os.utime(p,(n,n))
        self.retention.clean()
        self.assertTrue((backups/(f'{1:032x}'+'.tar.gz')).exists())
        self.assertTrue((backups/(f'{2:032x}'+'.tar.gz')).exists())
        self.assertFalse((backups/(f'{3:032x}'+'.tar.gz')).exists())
        self.assertTrue((backups/(f'{4:032x}'+'.tar.gz')).exists())

    def test_only_old_known_work_directories_are_removed(self):
        work=self.state/'work'
        for name in ['tmp-old','tmp-new','unrelated']:
            (work/name).mkdir()
        os.utime(work/'tmp-old',(1,1));os.utime(work/'unrelated',(1,1))
        self.retention.clean()
        self.assertFalse((work/'tmp-old').exists())
        self.assertTrue((work/'tmp-new').exists())
        self.assertTrue((work/'unrelated').exists())

    def test_only_recognized_abandoned_installer_work_is_removed(self):
        old=self.temporary/'sky-ui-install.AAAAAAAA';old.mkdir();os.utime(old,(1,1))
        fresh=self.temporary/'sky-ui-install.BBBBBBBB';fresh.mkdir()
        other=self.temporary/'other-app';other.mkdir();os.utime(other,(1,1))
        self.retention.clean()
        self.assertFalse(old.exists());self.assertTrue(fresh.exists());self.assertTrue(other.exists())

    def test_engine_current_and_previous_are_kept(self):
        root=self.cores/'xray';root.mkdir()
        slots=[]
        for n in range(3):
            slot=root/('v1.0.'+str(n)+'-'+str(n)*16);slot.mkdir();slots.append(slot)
        (root/'current').symlink_to(slots[2])
        self.retention.record_core('xray',slots[1]);self.retention.clean()
        self.assertFalse(slots[0].exists())
        self.assertTrue(slots[1].exists());self.assertTrue(slots[2].exists())

    def test_legacy_engine_rollback_keeps_its_panel_bundle_until_replaced(self):
        legacy=self.a/'bin';legacy.mkdir()
        root=self.cores/'mihomo';root.mkdir()
        slot=root/('v1.0.0-'+'a'*16);slot.mkdir()
        (root/'current').symlink_to(slot)
        self.retention.record_core('mihomo',legacy)
        self.retention.record_panel(str(self.b));self.retention.clean()
        self.assertTrue(legacy.exists())
        self.retention.record_core('mihomo',None)
        self.retention.clean()
        self.assertFalse(self.a.exists())

    def test_log_limit_keeps_last_failure_and_removes_expired_others(self):
        logs=self.state/'logs'
        for n in range(25):
            p=logs/('maintenance-'+f'{n:032x}'+'.log');p.write_text('fixture');os.utime(p,(n+1,n+1))
        (self.state/'result.json').write_text(json.dumps({'id':f'{0:032x}','status':'failed'}))
        self.retention.clean()
        self.assertEqual([p.name for p in logs.iterdir()],['maintenance-'+f'{0:032x}'+'.log'])


if __name__=='__main__':unittest.main()
