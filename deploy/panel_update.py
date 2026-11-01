#!/usr/bin/env python3
"""Fixed-operation Sky UI updates with a private session-preserving rescue copy."""
import fcntl
import json
import os
from pathlib import Path
import pwd
import subprocess
import sys
import tempfile
import urllib.request

import core_artifacts
import core_install
import panel_releases

RELEASES = Path('/opt/sky-ui/releases')
SYSTEMD = Path('/etc/systemd/system')
POLKIT = Path('/etc/polkit-1/rules.d/49-sky-ui.rules')
COMMANDS = Path('/usr/local/bin')
UNITS = ('sky-ui.service', 'sky-ui-mihomo.service', 'sky-ui-edge.service',
         'sky-ui-sing-box.service', 'sky-ui-xray.service', 'sky-ui-amneziawg.service',
         'sky-ui-maintenance.service', 'sky-ui-maintenance-recovery.service',
         'sky-ui-update.service', 'sky-ui-update-recovery.service',
         'sky-ui-certificates.service', 'sky-ui-certificates.timer')


def runtime(m, path):
    env = m.environment()
    secret = m.read_regular(Path(env['SKY_UI_GATEWAY_SECRET_FILE']), 256).decode().strip()
    request = urllib.request.Request('http://127.0.0.1:' + env['SKY_UI_PORT'] + path,
        headers={'X-Sky-UI-Gateway': secret, 'Origin': env['SKY_UI_WEB_ORIGIN']})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=5) as response:
        return json.load(response)


def previous_release(m, value):
    path = Path(value)
    m.require(path.parent == RELEASES and panel_releases.version(path.name.rsplit('-', 1)[0]), 'unsafe_file')
    core_install.trusted(path, directory=True)
    return path


def rollback(m, intent, gid, *, start=True):
    previous = previous_release(m, intent['previous'])
    files, _ = m.unpack_backup(m.read_regular(m.STATE / 'panel-update-backup.tar.gz'), require_complete=False)
    for unit in ('sky-ui-edge.service', 'sky-ui.service', 'sky-ui-certificates.timer', 'sky-ui-certificates.service'):
        m.run(['systemctl', 'stop', unit])
    m.switch_link(m.CURRENT, previous)
    m.apply_files(files, gid)
    for unit in UNITS:
        source = previous / 'deploy/systemd' / unit
        if source.exists():
            m.atomic(SYSTEMD / unit, core_install.trusted(source).read_bytes(), 0o644)
        else:
            (SYSTEMD / unit).unlink(missing_ok=True)
    m.atomic(POLKIT, core_install.trusted(previous / 'deploy/polkit/49-sky-ui.rules').read_bytes(), 0o644)
    for name in ('skyui', 'sky-ui'):
        m.atomic(COMMANDS / name, core_install.trusted(previous / 'deploy' / name).read_bytes(), 0o755)
    m.run(['systemctl', 'daemon-reload'])
    if start:
        for unit, key in (('sky-ui.service', 'api'), ('sky-ui-edge.service', 'edge'),
                          ('sky-ui-certificates.timer', 'timer')):
            if intent[key]:
                m.run(['systemctl', 'reset-failed', unit])
                m.run(['systemctl', 'start', unit])
        if intent['api']:
            m.api_ready(m.environment())
    (m.STATE / 'panel-update-intent.json').unlink()
    (m.STATE / 'panel-update-backup.tar.gz').unlink(missing_ok=True)


def recover(m, gid, *, start=False):
    path = m.STATE / 'panel-update-intent.json'
    if not path.exists():
        return
    state = m.run(['systemctl', 'show', 'sky-ui-update.service', '--property=ActiveState', '--value']).decode().strip()
    if state in ('active', 'activating', 'deactivating'):
        return
    intent = json.loads(m.read_regular(path, 4096))
    m.require(m.ID.fullmatch(intent.get('id', '')) and panel_releases.version(intent.get('tag')), 'request_invalid')
    m.require(all(type(intent.get(key)) is bool for key in ('api', 'edge', 'timer')), 'request_invalid')
    rollback(m, intent, gid, start=start)
    m.atomic(m.STATE / 'result.json', json.dumps({'id': intent['id'], 'action': 'panel-update',
        'status': 'failed', 'error': 'panel_update_rolled_back'}).encode(), gid=gid)


def update(m, owner, job, lock, install_lock):
    current = m.read_regular(m.CURRENT.resolve() / 'VERSION', 128).decode().strip()
    selected = panel_releases.candidate(current, core_artifacts.target_platform(), job['tag'])
    m.require(selected is not None, 'panel_update_unavailable')
    # All downloads and digest checks complete before interrupting the panel.
    with tempfile.TemporaryDirectory(prefix='panel-update-', dir=m.STATE / 'work') as temporary:
        stage = Path(temporary)
        panel_releases.prepare(selected, core_artifacts.target_platform(), stage)
        previous = previous_release(m, str(m.CURRENT.resolve(strict=True)))
        intent = {'id': job['id'], 'tag': job['tag'], 'previous': str(previous),
                  'api': m.active('sky-ui.service'), 'edge': m.active('sky-ui-edge.service'),
                  'timer': m.active('sky-ui-certificates.timer')}
        configured = runtime(m, '/api/v1/auth/session')['data']['configured'] if intent['api'] else None
        for unit in ('sky-ui-certificates.timer', 'sky-ui-certificates.service', 'sky-ui-edge.service', 'sky-ui.service'):
            m.run(['systemctl', 'stop', unit])
        try:
            files = m.snapshot_files(preserve_sessions=True)
            archive, _ = m.pack_backup(files, {'version': current, 'purpose': 'panel-update'})
            m.atomic(m.STATE / 'panel-update-backup.tar.gz', archive, 0o600)
            m.atomic(m.STATE / 'panel-update-intent.json', json.dumps(intent).encode(), 0o600)
            # The installer owns the same worker lock during activation.
            fcntl.flock(lock, fcntl.LOCK_UN)
            m.run(['env', 'SKY_UI_DEFER_ROLLBACK_START=1', 'SKY_UI_TRANSACTION_LOCK_FD='+str(install_lock.fileno()), 'bash', str(stage / 'install.sh'),
                   '--bundle', str(stage / ('sky-ui-' + core_artifacts.target_platform() + '.tar.gz'))], timeout=480, pass_fds=(install_lock.fileno(),))
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            m.api_ready(m.environment())
            m.require(runtime(m, '/api/v1/health')['version'] == job['tag'][1:], 'panel_version_mismatch')
            if configured is not None:
                m.require(runtime(m, '/api/v1/auth/session')['data']['configured'] == configured, 'owner_state_mismatch')
            if intent['edge']:
                m.run(['systemctl', 'start', 'sky-ui-edge.service'])
            if not intent['api']:
                m.run(['systemctl', 'stop', 'sky-ui.service'])
            if not intent['timer']:
                m.run(['systemctl', 'stop', 'sky-ui-certificates.timer'])
            (m.STATE / 'panel-update-intent.json').unlink()
            (m.STATE / 'panel-update-backup.tar.gz').unlink()
            return {'version': job['tag'][1:]}
        except Exception:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if (m.STATE / 'panel-update-intent.json').exists():
                rollback(m, intent, owner.pw_gid)
            else:
                for unit, key in (('sky-ui.service', 'api'), ('sky-ui-edge.service', 'edge'),
                                  ('sky-ui-certificates.timer', 'timer')):
                    if intent[key]:
                        m.run(['systemctl', 'start', unit])
            raise m.MaintenanceError('panel_update_rolled_back')


def main():
    import maintenance as m
    m.require(os.geteuid() == 0, 'root_required')
    os.umask(0o077)
    core_install.trusted(m.ETC / 'managed-by-sky-ui')
    owner = pwd.getpwnam('sky-ui')
    with open('/run/lock/sky-ui-install.lock', 'a') as install_lock, (m.STATE / 'worker.lock').open('a') as lock:
        fcntl.flock(install_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if sys.argv[1:] == ['--recover']:
            recover(m, owner.pw_gid, start=True)
            return
        m.require(not any((m.STATE / name).exists() for name in
            ('restore-intent.json', 'update-intent.json', 'core-remove-intent.json', 'engine-intent.json', 'panel-update-intent.json')),
            'maintenance_recovery_required')
        job = m.consume_request(m.STATE / 'inbox/request.json', owner.pw_uid, remove=False)
        m.require(job['action'] == 'panel-update', 'request_invalid')
        result = {'id': job['id'], 'action': job['action'], 'status': 'running'}
        m.atomic(m.STATE / 'result.json', json.dumps(result).encode(), gid=owner.pw_gid)
        (m.STATE / 'inbox/request.json').unlink()
        try:
            result['data'] = update(m, owner, job, lock, install_lock)
            result['status'] = 'completed'
        except Exception as error:
            result.update(status='failed', error=str(error) if isinstance(error, (m.MaintenanceError, core_artifacts.ArtifactError)) else 'panel_update_failed')
        finally:
            m.atomic(m.STATE / 'result.json', json.dumps(result).encode(), gid=owner.pw_gid)
        if (m.STATE / 'panel-update-intent.json').exists():
            raise m.MaintenanceError('panel_update_recovery_required')


if __name__ == '__main__':
    try:
        main()
    except BlockingIOError:
        import maintenance as m
        owner = pwd.getpwnam('sky-ui')
        job = m.consume_request(m.STATE / 'inbox/request.json', owner.pw_uid, remove=False)
        m.require(job['action'] == 'panel-update', 'request_invalid')
        existing = json.loads(m.read_regular(m.STATE / 'result.json', 4096)) if (m.STATE / 'result.json').exists() else {}
        (m.STATE / 'inbox/request.json').unlink()
        if existing.get('status') not in ('queued', 'running'):
            m.atomic(m.STATE / 'result.json', json.dumps({'id':job['id'], 'action':'panel-update',
                'status':'failed', 'error':'maintenance_busy'}).encode(), gid=owner.pw_gid)
        sys.exit(1)
