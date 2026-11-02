#!/usr/bin/env python3
"""Fixed-operation privileged maintenance worker for the unprivileged owner API."""
import contextlib
import datetime
import fcntl
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import pwd
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
from types import SimpleNamespace
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
import core_artifacts
import core_install

STATE = Path('/var/lib/sky-ui-maintenance')
DATA = Path('/var/lib/sky-ui')
ETC = Path('/etc/sky-ui')
EDGE = Path('/var/lib/sky-ui-edge')
CORES = Path('/opt/sky-ui/cores')
CURRENT = Path('/opt/sky-ui/current')
UNITS = ['sky-ui.service', 'sky-ui-mihomo.service', 'sky-ui-sing-box.service', 'sky-ui-xray.service', 'sky-ui-amneziawg.service', 'sky-ui-edge.service']
ID = re.compile(r'^[a-f0-9]{32}$')
TAG = re.compile(r'^v\d+\.\d+\.\d+$')
MAX_ARCHIVE = 128 * 1024 * 1024
MAX_FILES = 2048


class MaintenanceError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise MaintenanceError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def assert_configuration_settled():
    """Run after stopping API writes; interrupted deployments recover in the API."""
    path = DATA / 'panel.sqlite'
    if not path.exists(): return
    read_regular(path)
    with contextlib.closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)) as db:
        require(db.execute('SELECT count(*) FROM deployment').fetchone()[0] == 0,
                'configuration_recovery_required')


def read_regular(path, limit=MAX_ARCHIVE):
    path = Path(path)
    require(path.is_absolute() and '..' not in path.parts, 'unsafe_file')
    directory = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:-1]:
            next_directory = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = next_directory
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    finally:
        os.close(directory)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= limit, 'unsafe_file')
        data = stream.read(limit + 1)
        require(len(data) <= limit, 'file_too_large')
        return data


def atomic(path, data, mode=0o640, uid=0, gid=None):
    path = Path(path)
    require(path.is_absolute() and '..' not in path.parts, 'unsafe_file')
    parent = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    temporary = '.sky-' + os.urandom(16).hex()
    try:
        for part in path.parts[1:-1]:
            following = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = following
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), mode)
            os.fchown(stream.fileno(), uid, os.getegid() if gid is None else gid)
        os.replace(temporary, path.name, src_dir_fd=parent, dst_dir_fd=parent)
        os.fsync(parent)
    finally:
        try:
            os.unlink(temporary, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)


def run(args, timeout=30, pass_fds=()):
    result = subprocess.run(args, capture_output=True, timeout=timeout, pass_fds=pass_fds, env={
        'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'HOME': '/root',
        'SAFE_PATHS': '/var/lib/sky-ui-certificates'})
    require(result.returncode == 0, 'command_failed')
    return result.stdout


def active(unit):
    return subprocess.run(['systemctl', 'is-active', '--quiet', unit]).returncode == 0


def environment():
    return dict(line.split('=', 1) for line in read_regular(ETC / 'server.env', 16384).decode().splitlines()
                if '=' in line)


def ready(env, timeout=20, version=None):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    secret = read_regular(Path(env['SKY_UI_CONTROLLER_SECRET_FILE']), 256).decode().strip()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            req = urllib.request.Request(env.get('SKY_UI_CONTROLLER_URL', 'http://127.0.0.1:19090') + '/version',
                                         headers={'Authorization': 'Bearer ' + secret})
            with opener.open(req, timeout=2) as response:
                found = json.load(response)['version'].removeprefix('v')
                if version is None or found == version.removeprefix('v'):
                    return
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(.25)
    raise MaintenanceError('controller_not_ready')


def valid_member(name):
    path = PurePosixPath(name)
    if path.is_absolute() or str(path) != name or any(p in ['..', '.'] for p in path.parts):
        return False
    if name in ['data/panel.sqlite', 'data/owner.sqlite', 'data/instances/primary.json',
                'data/cores/mihomo/config.yaml',
                *['data/instances/' + core + '.json' for core in ('sing-box', 'xray', 'amneziawg')],
                *['data/cores/' + core + '/config.json' for core in ('sing-box', 'xray', 'amneziawg')]]:
        return True
    if name.startswith('etc/') and len(path.parts) == 2:
        return path.name in ['server.env', 'owner.seed', 'admin.hash', 'gateway.secret', 'controller.secret',
                             'Caddyfile', 'access.conf', 'managed-by-sky-ui']
    return name.startswith('edge/data/') and all(re.fullmatch(r'[A-Za-z0-9_.@+-]+', p) for p in path.parts)


def pack_backup(files, metadata):
    require(len(files) <= MAX_FILES and sum(map(len, files.values())) <= MAX_ARCHIVE, 'backup_too_large')
    require(all(valid_member(name) for name in files), 'backup_path_invalid')
    manifest = dict(metadata, format=1, files={name: {'sha256': digest(data), 'size': len(data)}
                                             for name, data in files.items()})
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w:gz') as archive:
        for name, data in [*files.items(), ('manifest.json', json.dumps(manifest).encode())]:
            entry = tarfile.TarInfo(name)
            entry.size, entry.mode = len(data), 0o600
            archive.addfile(entry, io.BytesIO(data))
    return output.getvalue(), manifest


def unpack_backup(data, require_complete=True):
    require(len(data) <= MAX_ARCHIVE, 'backup_too_large')
    files = {}
    total = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        for entry in archive:
            require(entry.isfile() and entry.name not in files and len(files) < MAX_FILES,
                    'backup_path_invalid')
            require(entry.name == 'manifest.json' or valid_member(entry.name), 'backup_path_invalid')
            total += entry.size
            require(entry.size >= 0 and total <= MAX_ARCHIVE, 'backup_too_large')
            files[entry.name] = archive.extractfile(entry).read()
    manifest = json.loads(files.pop('manifest.json'))
    require(manifest['format'] == 1 and set(manifest['files']) == set(files), 'backup_invalid')
    for name, payload in files.items():
        expected = manifest['files'][name]
        require(expected == {'sha256': digest(payload), 'size': len(payload)}, 'backup_checksum_failed')
    require(not require_complete or {'data/panel.sqlite', 'data/owner.sqlite', 'etc/server.env', 'etc/gateway.secret',
             'etc/controller.secret', 'etc/Caddyfile', 'data/cores/mihomo/config.yaml'} <= files.keys(),
            'backup_incomplete')
    return files, manifest


def snapshot_files(preserve_sessions=False):
    files = {}
    with tempfile.TemporaryDirectory(dir=STATE / 'work') as temporary:
        for name in ['panel', 'owner']:
            source = DATA / (name + '.sqlite')
            read_regular(source)
            target = Path(temporary) / source.name
            with contextlib.closing(sqlite3.connect(source.as_uri() + '?mode=ro', uri=True)) as db:
                with contextlib.closing(sqlite3.connect(target)) as copy:
                    db.backup(copy)
                    if name == 'owner' and not preserve_sessions:
                        copy.execute('DELETE FROM sessions')
                        copy.commit()
                    require(copy.execute('PRAGMA integrity_check').fetchone()[0] == 'ok', 'database_invalid')
            files['data/' + source.name] = target.read_bytes()
    for name in ['instances/primary.json', 'cores/mihomo/config.yaml',
                 *['instances/' + core + '.json' for core in ('sing-box', 'xray', 'amneziawg')],
                 *['cores/' + core + '/config.json' for core in ('sing-box', 'xray', 'amneziawg')]]:
        path = DATA / name
        if path.exists():
            files['data/' + name] = read_regular(path)
    for path in ETC.iterdir():
        if valid_member('etc/' + path.name) and path.is_file():
            files['etc/' + path.name] = read_regular(path)
    storage = EDGE / 'data'
    if storage.exists():
        for parent, directories, names in os.walk(storage, followlinks=False):
            require(not any((Path(parent) / d).is_symlink() for d in directories), 'unsafe_file')
            for name in names:
                path = Path(parent) / name
                files['edge/' + str(path.relative_to(EDGE))] = read_regular(path)
                require(len(files) <= MAX_FILES and sum(map(len, files.values())) <= MAX_ARCHIVE,
                        'backup_too_large')
    return files


def create_backup(gid, purpose='manual'):
    identity = os.urandom(16).hex()
    metadata = {'id': identity, 'purpose':purpose, 'created': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'version': read_regular(CURRENT.resolve(strict=True) / 'VERSION', 128).decode().strip(),
                'machine': digest(read_regular(Path('/etc/machine-id'), 256)),
                'coreVersion': run(['runuser', '-u', 'sky-ui-core', '--',
                                    str(CORES / 'mihomo/current/mihomo'), '-v']).decode().splitlines()[0] if (CORES / 'mihomo/current/mihomo').is_file() else 'not installed'}
    data, manifest = pack_backup(snapshot_files(), metadata)
    atomic(STATE / 'backups' / (identity + '.tar.gz'), data, gid=gid)
    public = {key: metadata[key] for key in ['id', 'created', 'version', 'coreVersion']}
    public['purpose'] = purpose
    public.update(size=len(data), sha256=digest(data))
    atomic(STATE / 'backups' / (identity + '.json'), json.dumps(public).encode(), gid=gid)
    return public


def candidate_validate(binary, configuration, directory):
    # The core parser is never executed as root, even for root-owned candidates.
    try:
        run(['runuser', '-u', 'sky-ui-core', '--', str(binary), '-t', '-d', str(directory),
             '-f', str(configuration)])
    except MaintenanceError:
        raise MaintenanceError('configuration_invalid')


def restore_backup(identity, gid):
    import engine_install
    require(ID.fullmatch(identity), 'backup_invalid')
    data = read_regular(STATE / 'backups' / (identity + '.tar.gz'))
    files, manifest = unpack_backup(data)
    require(manifest['machine'] == digest(read_regular(Path('/etc/machine-id'), 256)), 'backup_wrong_host')
    require(manifest['version'] == read_regular(CURRENT.resolve(strict=True) / 'VERSION', 128).decode().strip(), 'backup_version_mismatch')
    with tempfile.TemporaryDirectory(dir=STATE / 'work') as temporary:
        for name in ['panel', 'owner']:
            path = Path(temporary) / (name + '.sqlite')
            path.write_bytes(files['data/' + path.name])
            with contextlib.closing(sqlite3.connect(path)) as db:
                require(db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok', 'database_invalid')
                require(db.execute('PRAGMA user_version').fetchone()[0] == 1, 'database_version_invalid')
                if name == 'owner':
                    db.execute('DELETE FROM sessions')
                    db.commit()
            if name == 'owner':
                files['data/owner.sqlite'] = path.read_bytes()
    # Validate the complete archive before touching live services. Native validation
    # happens against a core-readable, API-private staging file on the data volume.
    staging = STATE / 'validation'
    staging.mkdir(mode=0o750, exist_ok=True)
    require(not staging.is_symlink(), 'unsafe_file')
    core = pwd.getpwnam('sky-ui-core')
    os.chown(staging, 0, gid)
    atomic(staging / 'config.yaml', files['data/cores/mihomo/config.yaml'], gid=gid)
    if (CORES / 'mihomo/current/mihomo').is_file():
        candidate_validate(CORES / 'mihomo/current/mihomo', staging / 'config.yaml', DATA / 'cores/mihomo')
    for engine in ('sing-box', 'xray', 'amneziawg'):
        name = 'data/cores/' + engine + '/config.json'
        if name not in files: continue
        configuration = staging / (engine + '.json')
        atomic(configuration, files[name], gid=gid)
        if engine == 'amneziawg':
            import amnezia_network
            amnezia_network.load(configuration)
        elif (CORES / engine / 'current' / engine).is_file():
            args = ['run', '-test', '-config', str(configuration)] if engine == 'xray' else ['check', '-c', str(configuration)]
            run(['runuser', '-u', 'sky-ui-' + engine, '--', str(CORES / engine / 'current' / engine), *args])
    rescue = create_backup(gid, purpose='rescue')
    previous = snapshot_files()
    running = {unit: active(unit) for unit in UNITS}
    timer_running = active('sky-ui-certificates.timer')
    run(['systemctl', 'stop', 'sky-ui-certificates.timer', 'sky-ui-certificates.service'])
    atomic(STATE / 'restore-intent.json', json.dumps({'backupId': rescue['id']}).encode())
    try:
        for unit in reversed(UNITS):
            run(['systemctl', 'stop', unit])
        apply_files(files, gid)
        run(['python3', str(CURRENT / 'deploy/certificate_sync.py')])
        for unit in reversed(UNITS):
            if running[unit]:
                run(['systemctl', 'start', unit])
        if running['sky-ui-mihomo.service']:
            ready(environment())
        for engine in engine_install.ENGINES:
            if running['sky-ui-' + engine + '.service']: engine_install.await_ready(engine, SimpleNamespace(**globals()))
        if running['sky-ui.service']:
            api_ready(environment())
        (STATE / 'restore-intent.json').unlink()
        return {'restored': identity, 'rescueBackup': rescue['id']}
    except Exception:
        for unit in reversed(UNITS):
            run(['systemctl', 'stop', unit])
        apply_files(previous, gid)
        for unit in reversed(UNITS):
            if running[unit]:
                run(['systemctl', 'start', unit])
        if running['sky-ui-mihomo.service']:
            ready(environment())
        for engine in engine_install.ENGINES:
            if running['sky-ui-' + engine + '.service']: engine_install.await_ready(engine, SimpleNamespace(**globals()))
        (STATE / 'restore-intent.json').unlink(missing_ok=True)
        raise MaintenanceError('restore_rolled_back')
    finally:
        (staging / 'config.yaml').unlink(missing_ok=True)
        for engine in ('sing-box', 'xray', 'amneziawg'): (staging / (engine + '.json')).unlink(missing_ok=True)
        if timer_running:
            run(['systemctl', 'start', 'sky-ui-certificates.timer'])


def apply_files(files, gid):
    owner = pwd.getpwnam('sky-ui')
    edge = pwd.getpwnam('sky-ui-edge')
    core = pwd.getpwnam('sky-ui-core')
    # Remove SQLite sidecars only while the API is stopped; never revive old WAL.
    for name in ['panel.sqlite', 'owner.sqlite']:
        for suffix in ['-wal', '-shm']:
            (DATA / (name + suffix)).unlink(missing_ok=True)
    for name, payload in files.items():
        area, relative = name.split('/', 1)
        base = {'data': DATA, 'etc': ETC, 'edge': EDGE}[area]
        target = base / relative
        require(target.resolve().is_relative_to(base.resolve()), 'unsafe_file')
        if area == 'edge':
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            for parent in [target.parent, *target.parent.parents]:
                if parent == EDGE:
                    break
                os.chown(parent, edge.pw_uid, edge.pw_gid)
            atomic(target, payload, 0o600, edge.pw_uid, edge.pw_gid)
        elif name == 'etc/Caddyfile':
            atomic(target, payload, 0o640, 0, edge.pw_gid)
        elif name == 'etc/controller.secret':
            atomic(target, payload, 0o640, 0, gid)
        elif name == 'data/cores/mihomo/config.yaml':
            atomic(target, payload, 0o660, core.pw_uid, gid)
        elif name.startswith('data/cores/') and name.endswith('/config.json'):
            atomic(target, payload, 0o660, owner.pw_uid, gid)
        elif name in ['etc/server.env', 'etc/admin.hash', 'etc/access.conf', 'etc/managed-by-sky-ui']:
            atomic(target, payload, 0o600, 0, 0)
        else:
            atomic(target, payload, 0o600, owner.pw_uid, gid)


def api_ready(env):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for _ in range(60):
        try:
            with opener.open('http://127.0.0.1:' + env['SKY_UI_PORT'] + '/api/v1/health', timeout=2) as response:
                if json.load(response).get('status') == 'ok':
                    return
        except (OSError, ValueError):
            pass
        time.sleep(.25)
    raise MaintenanceError('api_not_ready')


def download(url, limit, **options):
    try:
        return core_artifacts.download(url, limit, **options)
    except core_artifacts.ArtifactError as error:
        raise MaintenanceError(str(error))


CATALOG_BASE = core_artifacts.CATALOG_BASE
CORE_REPOSITORIES = core_artifacts.REPOSITORIES


def verified_release(core, selected=None):
    panel = read_regular(CURRENT.resolve(strict=True) / 'VERSION', 128).decode().strip()
    try:
        return core_artifacts.verified_release(core, panel, core_artifacts.target_platform(), selected, fetch=download)
    except core_artifacts.ArtifactError as error:
        raise MaintenanceError(str(error))


def latest_mihomo(selected=None):
    return verified_release('mihomo', selected)


def switch_link(link, destination):
    temporary = link.with_name('.next-' + os.urandom(8).hex())
    temporary.symlink_to(destination)
    os.replace(temporary, link)


def remove_core(core, gid, uid):
    if core != 'mihomo':
        import engine_install
        return engine_install.change('remove', core, None, gid, uid, SimpleNamespace(**globals()))
    require(core == 'mihomo', 'core_unsupported')
    root = CORES / core
    core_install.trusted(root, directory=True)
    # Only root-owned independent slots are disposable. Historical panel bundles
    # remain immutable; unlinking current removes their installed association.
    slots = []
    for path in root.iterdir():
        if re.fullmatch(r'(?:v[0-9]+\.[0-9]+\.[0-9]+|imported)-[a-f0-9]{16}', path.name):
            core_install.trusted(path, directory=True)
            for entry in path.iterdir():
                require(entry.name in ('mihomo', 'LICENSE', 'artifact.json'), 'unsafe_file')
                core_install.trusted(entry)
            slots.append(path)
    core_install.existing_core(root, Path('/opt/sky-ui/releases'))
    for name in ('removed.json', 'previous.json'):
        if (root / name).exists():
            core_install.trusted(root / name)
    instance = DATA / 'instances/primary.json'
    value = json.loads(read_regular(instance, 65536)) if instance.exists() else {
        'instanceId': 'primary', 'coreId': core}
    require(value.get('instanceId') == 'primary' and value.get('coreId') == core, 'unsafe_file')
    intent = STATE / 'core-remove-intent.json'
    atomic(intent, json.dumps({'core': core}).encode(), 0o600)
    run(['systemctl', 'stop', 'sky-ui-mihomo.service'])
    require(not active('sky-ui-mihomo.service'), 'service_stop_timeout')
    value['desiredState'] = 'stopped'
    # Persist API-owned state without granting root writes through API-owned paths.
    script = "import json,os,pathlib,sys,tempfile; p=pathlib.Path(sys.argv[1]); p.parent.mkdir(mode=0o700,parents=True,exist_ok=True); fd,t=tempfile.mkstemp(dir=p.parent); f=os.fdopen(fd,'w'); f.write(sys.argv[2]); f.flush(); os.fsync(f.fileno()); f.close(); os.replace(t,p)"
    run(['runuser', '-u', 'sky-ui', '--', '/usr/bin/python3', '-I', '-c', script,
         str(instance), json.dumps(value)])
    require(json.loads(read_regular(instance, 65536)).get('desiredState') == 'stopped', 'unsafe_file')
    atomic(root / 'removed.json', json.dumps({'coreId': core, 'removed': True}).encode(), 0o644)
    (root / 'current').unlink(missing_ok=True)
    for slot in slots:
        for entry in slot.iterdir():
            entry.unlink()
        slot.rmdir()
    (root / 'previous.json').unlink(missing_ok=True)
    intent.unlink()
    return {'core': core, 'installed': False}


def install_core(core, tag, gid, *, reporter=None, before_activation=None):
    if core != 'mihomo':
        import engine_install
        return engine_install.change('install', core, tag, gid, pwd.getpwnam('sky-ui').pw_uid, SimpleNamespace(**globals()), reporter=reporter, before_activation=before_activation)
    require(core == 'mihomo', 'core_unsupported')
    root = CORES / core
    core_install.trusted(root, directory=True)
    require(core_install.existing_core(root) is None, 'core_already_installed')
    require(not active('sky-ui-mihomo.service'), 'maintenance_busy')
    panel_version = read_regular(CURRENT.resolve() / 'VERSION', 128).decode().strip()
    try:
        with tempfile.TemporaryDirectory(prefix='.install-', dir=root) as temporary:
            os.chmod(temporary, 0o755)
            prepared = Path(temporary) / 'payload'
            selected, url, sha = core_artifacts.verified_release(core, panel_version,
                core_artifacts.target_platform(), tag, fetch=download)
            files = core_artifacts.artifact_files(core, selected, url, sha,
                core_artifacts.target_platform(), fetch=progress_fetch(reporter))
            prepared.mkdir(mode=0o755)
            os.chmod(prepared, 0o755)
            for name, data in files.items():
                atomic(prepared / name, data, 0o755 if name == core else 0o644)
            if reporter: reporter.stage('validate',bytesReceived=None,bytesTotal=None,artifact=None)
            if before_activation: before_activation()
            core_install.validate(prepared / core, DATA / 'cores/mihomo/config.yaml', DATA / 'cores/mihomo')
            marker = root / 'removed.json'
            if marker.exists():
                core_install.trusted(marker)
                marker.unlink()
            try:
                if reporter: reporter.stage('activate')
                core_install.activate(prepared, root=root)
            except Exception:
                atomic(marker, json.dumps({'coreId': core, 'removed': True}).encode(), 0o644)
                raise
    except core_artifacts.ArtifactError as error:
        raise MaintenanceError(str(error))
    return {'core': core, 'version': tag, 'installed': True}


def progress_fetch(reporter):
    if reporter is None: return download
    def fetch(url,limit):
        name=url.rsplit('/',1)[-1]
        reporter.stage('download',bytesReceived=0,bytesTotal=None,artifact=name)
        return download(url,limit,on_progress=lambda received:reporter.transfer(received,None,name),
            on_size=lambda size:reporter.stage('download',bytesTotal=size))
    return fetch


def update_core(core, tag, gid, *, reporter=None, before_activation=None):
    if core != 'mihomo':
        import engine_install
        return engine_install.change('update', core, tag, gid, pwd.getpwnam('sky-ui').pw_uid, SimpleNamespace(**globals()),reporter=reporter,before_activation=before_activation)
    require(core == 'mihomo', 'core_unsupported')
    latest, url, expected = latest_mihomo(tag)
    require(tag == latest, 'release_changed')
    try:
        files = core_artifacts.artifact_files(core, tag, url, expected, core_artifacts.target_platform(), fetch=progress_fetch(reporter))
    except core_artifacts.ArtifactError as error:
        raise MaintenanceError(str(error))
    binary = files['mihomo']
    root = CORES / core
    slot = root / (tag + '-' + digest(binary)[:16])
    slot.mkdir(mode=0o755, exist_ok=True)
    os.chmod(slot, 0o755)
    for name, data in files.items():
        atomic(slot / name, data, 0o755 if name == 'mihomo' else 0o644, 0, 0)
    try:
        found = run(['runuser', '-u', 'sky-ui-core', '--', str(slot / 'mihomo'), '-v']).decode()
    except MaintenanceError:
        raise MaintenanceError('binary_probe_failed')
    require(re.search(r'\bv?' + re.escape(tag[1:]) + r'\b', found), 'binary_version_mismatch')
    if reporter: reporter.stage('validate',bytesReceived=None,bytesTotal=None,artifact=None)
    if before_activation: before_activation()
    candidate_validate(slot / 'mihomo', DATA / 'cores/mihomo/config.yaml', DATA / 'cores/mihomo')
    link = root / 'current'
    previous = link.resolve(strict=True)
    require(previous.is_relative_to(Path('/opt/sky-ui/releases')) or previous.is_relative_to(root), 'unsafe_file')
    running = active('sky-ui-mihomo.service')
    atomic(STATE / 'update-intent.json', json.dumps({'path': str(previous)}).encode())
    try:
        if reporter: reporter.stage('activate')
        switch_link(link, slot)
        if running:
            run(['systemctl', 'restart', 'sky-ui-mihomo.service'])
            ready(environment(), version=tag)
        atomic(root / 'previous.json', json.dumps({'path': str(previous)}).encode(), gid=gid)
        (STATE / 'update-intent.json').unlink()
        import storage
        storage.best_effort(SimpleNamespace(**globals()),'core',previous,core)
        return {'core': core, 'version': tag}
    except Exception:
        switch_link(link, previous)
        if running:
            run(['systemctl', 'reset-failed', 'sky-ui-mihomo.service'])
            run(['systemctl', 'restart', 'sky-ui-mihomo.service'])
            ready(environment())
        (STATE / 'update-intent.json').unlink(missing_ok=True)
        raise MaintenanceError('update_rolled_back')


def consume_request(path, owner_uid, remove=True):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == owner_uid and info.st_size <= 4096,
                'request_invalid')
        value = json.loads(stream.read(4097))
    require(isinstance(value, dict) and ID.fullmatch(value.get('id', '')), 'request_invalid')
    action = value.get('action')
    keys = {'backup': {'id', 'action'}, 'restore': {'id', 'action', 'backupId'},
            'update': {'id', 'action', 'core', 'tag'},
            'install': {'id', 'action', 'core', 'tag'}, 'remove': {'id', 'action', 'core'}, 'panel-update': {'id', 'action', 'tag'}}
    require(action in keys and set(value) == keys[action], 'request_invalid')
    if action == 'restore':
        require(ID.fullmatch(value['backupId']), 'request_invalid')
    if action in ('update', 'install'):
        require(value['core'] in CORE_REPOSITORIES and TAG.fullmatch(value['tag']), 'request_invalid')
    if action == 'panel-update':
        from panel_releases import version
        require(isinstance(value.get('tag'), str) and value['tag'].startswith('v') and version(value['tag']), 'request_invalid')
    if action == 'remove':
        require(value['core'] in CORE_REPOSITORIES, 'request_invalid')
    if remove:
        path.unlink()
    return value


def recover(gid):
    import engine_install
    engine_install.recover(gid, pwd.getpwnam('sky-ui').pw_uid, SimpleNamespace(**globals()))
    from panel_update import recover as recover_panel
    recover_panel(SimpleNamespace(**globals()), gid)
    removal = STATE / 'core-remove-intent.json'
    if removal.exists():
        require(json.loads(read_regular(removal, 4096)) == {'core': 'mihomo'}, 'request_invalid')
        remove_core('mihomo', gid, pwd.getpwnam('sky-ui').pw_uid)
    restore = STATE / 'restore-intent.json'
    update = STATE / 'update-intent.json'
    if restore.exists():
        identity = json.loads(read_regular(restore, 1024))['backupId']
        require(ID.fullmatch(identity), 'backup_invalid')
        files, _ = unpack_backup(read_regular(STATE / 'backups' / (identity + '.tar.gz')))
        apply_files(files, gid)
        restore.unlink()
    if update.exists():
        previous = Path(json.loads(read_regular(update, 4096))['path']).resolve(strict=True)
        require(previous.is_relative_to(Path('/opt/sky-ui/releases')) or
                previous.is_relative_to(CORES / 'mihomo'), 'unsafe_file')
        switch_link(CORES / 'mihomo/current', previous)
        update.unlink()
    result = STATE / 'result.json'
    if result.exists():
        value = json.loads(read_regular(result, 4096))
        if value.get('status') == 'running':
            value.update(status='failed', error='maintenance_interrupted')
            atomic(result, json.dumps(value).encode(), gid=gid)


def acquire_lock(descriptor, timeout=30):
    """Short housekeeping must not cause an already queued owner job to fail."""
    deadline=time.monotonic()+timeout
    while True:
        try:
            fcntl.flock(descriptor,fcntl.LOCK_EX|fcntl.LOCK_NB)
            return
        except BlockingIOError:
            if time.monotonic()>=deadline: raise
            time.sleep(.1)


def wait_cleanup(timeout=30):
    deadline=time.monotonic()+timeout
    while True:
        try:state=run(['systemctl','show','sky-ui-cleanup.service','--property=ActiveState','--value']).decode().strip()
        except MaintenanceError:
            if (STATE/'cleanup-intent.json').exists():raise
            return
        if not (STATE/'cleanup-intent.json').exists() and state not in ('active','activating','deactivating'):return
        require(time.monotonic()<deadline,'maintenance_busy')
        time.sleep(.1)


def main():
    require(os.geteuid() == 0, 'root_required')
    os.umask(0o077)
    owner = pwd.getpwnam('sky-ui')
    if sys.argv[1:2] == ['--cli']:
        cli(sys.argv[2:], owner)
        return
    lock = open(STATE / 'worker.lock', 'a')
    acquire_lock(lock)
    if sys.argv[1:] == ['--recover']:
        (STATE/'cleanup-intent.json').unlink(missing_ok=True)
        recover(owner.pw_gid)
        return
    require(not (STATE / 'restore-intent.json').exists() and not (STATE / 'update-intent.json').exists()
            and not (STATE / 'core-remove-intent.json').exists() and not (STATE / 'engine-intent.json').exists() and not (STATE / 'panel-update-intent.json').exists(),
            'maintenance_recovery_required')
    job = consume_request(STATE / 'inbox/request.json', owner.pw_uid, remove=False)
    require(job['action'] != 'panel-update', 'request_invalid')
    result = {key: job[key] for key in ['id', 'action']}
    for key in ('core','tag'):
        if key in job: result[key]=job[key]
    result['status'] = 'running'
    output = STATE / 'result.json'
    atomic(output, json.dumps(result).encode(), gid=owner.pw_gid)
    (STATE / 'inbox/request.json').unlink()
    api_running = active('sky-ui.service')
    api_stopped = False
    reporter = None
    if job['action'] in ('install','update'):
        from update_progress import Reporter
        reporter=Reporter(SimpleNamespace(**globals()),result,None,job['tag'],owner.pw_gid)
    def before_activation():
        nonlocal api_stopped
        if api_running and not api_stopped:
            run(['systemctl','stop','sky-ui.service'])
            api_stopped=True
        assert_configuration_settled()
    try:
        # Downloads/source compilation keep reads and progress polling available.
        # The durable running receipt gates API writes; stop and revalidate the
        # latest configuration only at the short activation boundary.
        if reporter is None and api_running:
            time.sleep(1)
            before_activation()
        if reporter is None: assert_configuration_settled()
        if job['action'] == 'backup':
            result['data'] = create_backup(owner.pw_gid)
        elif job['action'] == 'restore':
            result['data'] = restore_backup(job['backupId'], owner.pw_gid)
        elif job['action'] == 'remove':
            result['data'] = remove_core(job['core'], owner.pw_gid, owner.pw_uid)
        elif job['action'] == 'install':
            result['data'] = install_core(job['core'], job['tag'], owner.pw_gid,reporter=reporter,before_activation=before_activation)
        else:
            result['data'] = update_core(job['core'], job['tag'], owner.pw_gid,reporter=reporter,before_activation=before_activation)
        result['status'] = 'completed'
    except Exception as error:
        result.update(status='failed', error=str(error) if isinstance(error, (MaintenanceError,core_artifacts.ArtifactError)) else 'maintenance_failed')
        if reporter: reporter.failed(result['error'],failedStage=reporter.progress['stage'])
    finally:
        if api_stopped and not any((STATE / name).exists() for name in
                ('restore-intent.json', 'update-intent.json', 'core-remove-intent.json', 'engine-intent.json')):
            try:
                run(['systemctl', 'reset-failed', 'sky-ui.service'])
                run(['systemctl', 'start', 'sky-ui.service'])
                api_ready(environment())
            except Exception:
                result.update(status='failed', error='api_not_ready')
                if reporter: reporter.failed('api_not_ready',failedStage='health')
        if reporter and result['status']=='completed':
            from update_progress import now
            reporter.progress['finishedAt']=now()
            reporter.stage('complete')
        atomic(output, json.dumps(result).encode(), gid=owner.pw_gid)


def cli(arguments, owner):
    require(arguments and arguments[0] in ['backup', 'backups', 'restore', 'update-core', 'install-core', 'remove-core', 'update'], 'request_invalid')
    if arguments == ['backups']:
        for path in sorted((STATE / 'backups').glob('*.json')):
            value = json.loads(read_regular(path, 4096))
            print(value['id'], value['created'], value['version'], value['size'])
        return
    if arguments == ['update']:
        import panel_releases
        current = read_regular(CURRENT.resolve() / 'VERSION', 128).decode().strip()
        release = panel_releases.candidate(current, core_artifacts.target_platform())
        if release is None:
            print('Обновлений Sky UI нет.')
            return
        print('Sky UI:', current, '→', release['tag'])
        require(input('Введите UPDATE для обновления: ') == 'UPDATE', 'cancelled')
        job = {'action': 'panel-update', 'tag': release['tag']}
    elif arguments == ['backup']:
        job = {'action': 'backup'}
    elif len(arguments) == 2 and arguments[0] == 'restore':
        require(ID.fullmatch(arguments[1]), 'request_invalid')
        print('Restore replaces settings, access and owner data. Services restart and sessions are revoked.')
        require(input('Type RESTORE to continue: ') == 'RESTORE', 'cancelled')
        job = {'action': 'restore', 'backupId': arguments[1]}
    elif len(arguments) == 2 and arguments[0] in ('install-core', 'update-core', 'remove-core') and arguments[1] in CORE_REPOSITORIES and arguments[1] != 'mihomo':
        action, core = arguments[0].removesuffix('-core'), arguments[1]
        tag = None if action == 'remove' else verified_release(core)[0]
        print(action.capitalize(), core, tag or '', '. Connections and recipient data are retained.')
        require(input('Type ' + action.upper() + ' to continue: ') == action.upper(), 'cancelled')
        job = {'action': action, 'core': core}
        if tag is not None: job['tag'] = tag
    elif arguments == ['remove-core']:
        print('Ядро будет остановлено и удалено. Подключения и ключи сохранятся, но работать не будут.')
        require(input('Введите REMOVE для удаления: ') == 'REMOVE', 'cancelled')
        job = {'action': 'remove', 'core': 'mihomo'}
    elif arguments in (['update-core'], ['install-core']):
        tag, _, _ = latest_mihomo()
        installing = arguments == ['install-core']
        confirmation = 'INSTALL' if installing else 'UPDATE'
        print('Install verified mihomo', tag, '(stopped)' if installing else 'and restart the running core after validation.')
        require(input('Type '+confirmation+' to continue: ') == confirmation, 'cancelled')
        job = {'action': 'install' if installing else 'update', 'core': 'mihomo', 'tag': tag}
    else:
        raise MaintenanceError('request_invalid')
    wait_cleanup()
    previous_job = json.loads(read_regular(STATE / 'result.json', 4096)) if (STATE / 'result.json').exists() else {}
    require(previous_job.get('status') not in ('running', 'queued'), 'maintenance_busy')
    require(not (STATE / 'inbox/request.json').exists() and not active('sky-ui-maintenance.service') and not (STATE / 'panel-update-intent.json').exists(), 'maintenance_busy')
    job['id'] = os.urandom(16).hex()
    atomic(STATE / 'inbox/request.json', json.dumps(job).encode(), 0o600, owner.pw_uid, owner.pw_gid)
    try:wait_cleanup()
    except Exception:
        pending=STATE/'inbox/request.json'
        if pending.exists() and json.loads(read_regular(pending,4096)).get('id')==job['id']:pending.unlink()
        raise
    service = 'sky-ui-update.service' if job['action'] == 'panel-update' else 'sky-ui-maintenance.service'
    run(['systemctl', 'start', '--no-block', service])
    print('Job:', job['id'])
    started = time.monotonic()
    deadline = started + 600
    while time.monotonic() < deadline:
        try:
            result = json.loads(read_regular(STATE / 'result.json', 4096))
            if result.get('id') == job['id'] and result.get('status') != 'running':
                print(json.dumps(result))
                require(result['status'] == 'completed', result.get('error', 'maintenance_failed'))
                return
        except FileNotFoundError:
            pass
        if time.monotonic() - started > 5:
            state = run(['systemctl', 'show', '-p', 'ActiveState', '--value',
                         service]).decode().strip()
            if state == 'failed':
                pending = STATE / 'inbox/request.json'
                if pending.exists() and json.loads(read_regular(pending, 4096)).get('id') == job['id']:
                    pending.unlink()
                raise MaintenanceError('Служба обслуживания не запустилась. Проверь skyui logs all.')
        time.sleep(.5)
    raise MaintenanceError('maintenance_timeout')


if __name__ == '__main__':
    main()
