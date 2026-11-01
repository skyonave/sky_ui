"""Bounded, credential-free update telemetry and root-only installer output."""
import datetime
import json
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import time

STAGES = ('discovery', 'download', 'verify', 'backup', 'prepare', 'toolchain', 'build', 'validate', 'install', 'activate', 'health', 'rollback', 'complete')


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


class Reporter:
    def __init__(self, m, result, current, target, gid):
        self.m, self.result, self.gid = m, result, gid
        self.progress = {'currentVersion': current, 'targetVersion': target.removeprefix('v'),
                         'stage': 'discovery', 'startedAt': now(), 'updatedAt': now()}
        self.last_write = 0
        result['progress'] = self.progress

    def save(self):
        self.progress['updatedAt'] = now()
        self.m.atomic(self.m.STATE / 'result.json', json.dumps(self.result).encode(), gid=self.gid)
        self.last_write = time.monotonic()

    def stage(self, stage, **values):
        assert stage in STAGES
        self.progress.update(stage=stage, **values)
        self.save()

    def download(self, received, total, artifact):
        self.transfer(received,total,artifact)

    def transfer(self,received,total,artifact,stage='download'):
        if total is None: total=self.progress.get('bytesTotal')
        self.progress.update(stage=stage, bytesReceived=received, bytesTotal=total, artifact=artifact)
        if time.monotonic() - self.last_write >= .25 or received == total: self.save()

    def failed(self, code, **values):
        # No raw stderr, request headers, paths, URLs or command arguments enter
        # the owner API. Detailed installer output is kept in a root-only file.
        if not re.fullmatch(r'[a-z][a-z0-9_]{0,95}', code): code = 'panel_update_failed'
        self.progress.update(errorCode=code, finishedAt=now(), **values)
        self.save()


class InstallerFailure(Exception):
    def __init__(self, exit_code):
        self.exit_code = exit_code
        super().__init__('installer_failed')


def run_installer(m, args, reporter, *, pass_fds=(), timeout=480):
    directory = m.STATE / 'logs'
    directory.mkdir(mode=0o700, exist_ok=True)
    m.core_install.trusted(directory, directory=True)
    os.chmod(directory, 0o700)
    prefix = 'update-' if reporter.result['action']=='panel-update' else 'maintenance-'
    log = directory / (prefix + reporter.result['id'] + '.log')
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        pass_fds=pass_fds, start_new_session=True, env={
            'PATH':'/usr/sbin:/usr/bin:/sbin:/bin', 'HOME':'/root', 'SAFE_PATHS':'/var/lib/sky-ui-certificates'})
    output, pending = bytearray(), b''
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + timeout
    try:
        while selector.get_map():
            if time.monotonic() >= deadline: raise InstallerFailure(124)
            for key, _ in selector.select(.2):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                output.extend(chunk)
                del output[:-262144]
                pending = (pending + chunk)[-65536:]
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    if line.startswith(b'SKY_UI_STAGE='):
                        stage = line[13:].decode('ascii', errors='ignore')
                        if stage in STAGES: reporter.stage(stage)
        code = process.wait(timeout=max(.1, deadline-time.monotonic()))
        if code: raise InstallerFailure(code)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        selector.close()
        process.stdout.close()
        m.atomic(log, bytes(output), 0o600)
