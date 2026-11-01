"""Telemetry remains bounded and private while installer failures retain context."""
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'deploy'))
import maintenance as m
from update_progress import Reporter, InstallerFailure, run_installer


class ProgressTests(unittest.TestCase):
    def test_failed_installer_retains_stage_exit_and_private_output_only(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(m,'STATE',Path(temporary)):
            result={'id':'a'*32,'action':'panel-update','status':'running'}
            reporter=Reporter(m,result,'0.7.0-dev.2','v0.7.0-dev.3',__import__('os').getgid())
            script="print('SKY_UI_STAGE=prepare');print('fixture-private-output');raise SystemExit(23)"
            with self.assertRaises(InstallerFailure) as failed:
                run_installer(m,[sys.executable,'-c',script],reporter)
            self.assertEqual(failed.exception.exit_code,23)
            self.assertEqual(result['progress']['stage'],'prepare')
            self.assertNotIn('fixture-private-output',json.dumps(result))
            log=m.STATE/'logs'/('update-'+'a'*32+'.log')
            self.assertIn('fixture-private-output',log.read_text())
            self.assertEqual(log.stat().st_mode & 0o777,0o600)
            self.assertEqual(log.parent.stat().st_mode & 0o777,0o700)

    def test_reporter_preserves_download_counts_and_original_failure(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(m,'STATE',Path(temporary)):
            result={'id':'b'*32,'action':'panel-update','status':'running'}
            reporter=Reporter(m,result,'0.7.0-dev.2','v0.7.0-dev.3',__import__('os').getgid())
            reporter.download(2048,4096,'install.sh')
            reporter.stage('rollback',failedStage='prepare')
            reporter.failed('installer_failed',exitCode=1,rolledBack=True)
            data=json.loads((m.STATE/'result.json').read_text())['progress']
            self.assertEqual((data['bytesReceived'],data['bytesTotal']),(2048,4096))
            self.assertEqual(data['failedStage'],'prepare')
            self.assertTrue(data['rolledBack'])
            self.assertIsNotNone(data['finishedAt'])


if __name__=='__main__':unittest.main()
