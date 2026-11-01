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
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request

STATE = Path('/var/lib/sky-ui-maintenance')
DATA = Path('/var/lib/sky-ui')
ETC = Path('/etc/sky-ui')
EDGE = Path('/var/lib/sky-ui-edge')
CORES = Path('/opt/sky-ui/cores')
CURRENT = Path('/opt/sky-ui/current')
UNITS = ['sky-ui.service', 'sky-ui-mihomo.service', 'sky-ui-edge.service']
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
    fd, temporary = tempfile.mkstemp(prefix='.sky-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), mode)
            os.fchown(stream.fileno(), uid, os.getegid() if gid is None else gid)
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def run(args, timeout=30):
    result = subprocess.run(args, capture_output=True, timeout=timeout, env={
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
                'data/cores/mihomo/config.yaml']:
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


def unpack_backup(data):
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
    require({'data/panel.sqlite', 'data/owner.sqlite', 'etc/server.env', 'etc/gateway.secret',
             'etc/controller.secret', 'etc/Caddyfile', 'data/cores/mihomo/config.yaml'} <= files.keys(),
            'backup_incomplete')
    return files, manifest


def snapshot_files():
    files = {}
    with tempfile.TemporaryDirectory(dir=STATE / 'work') as temporary:
        for name in ['panel', 'owner']:
            source = DATA / (name + '.sqlite')
            read_regular(source)
            target = Path(temporary) / source.name
            with contextlib.closing(sqlite3.connect(source.as_uri() + '?mode=ro', uri=True)) as db:
                with contextlib.closing(sqlite3.connect(target)) as copy:
                    db.backup(copy)
                    if name == 'owner':
                        copy.execute('DELETE FROM sessions')
                        copy.commit()
                    require(copy.execute('PRAGMA integrity_check').fetchone()[0] == 'ok', 'database_invalid')
            files['data/' + source.name] = target.read_bytes()
    for name in ['instances/primary.json', 'cores/mihomo/config.yaml']:
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


def create_backup(gid):
    identity = os.urandom(16).hex()
    metadata = {'id': identity, 'created': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'version': read_regular(CURRENT.resolve(strict=True) / 'VERSION', 128).decode().strip(),
                'machine': digest(read_regular(Path('/etc/machine-id'), 256)),
                'coreVersion': run(['runuser', '-u', 'sky-ui-core', '--',
                                    str(CORES / 'mihomo/current/mihomo'), '-v']).decode().splitlines()[0]}
    data, manifest = pack_backup(snapshot_files(), metadata)
    atomic(STATE / 'backups' / (identity + '.tar.gz'), data, gid=gid)
    public = {key: metadata[key] for key in ['id', 'created', 'version', 'coreVersion']}
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
    candidate_validate(CORES / 'mihomo/current/mihomo', staging / 'config.yaml', DATA / 'cores/mihomo')
    rescue = create_backup(gid)
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
        (STATE / 'restore-intent.json').unlink(missing_ok=True)
        raise MaintenanceError('restore_rolled_back')
    finally:
        (staging / 'config.yaml').unlink(missing_ok=True)
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


def download(url, limit):
    require(urllib.parse.urlparse(url).scheme == 'https', 'download_invalid')
    request = urllib.request.Request(url, headers={'User-Agent': 'Sky-UI', 'Accept': 'application/vnd.github+json'})
    class OfficialRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, request, fp, code, message, headers, target):
            parsed = urllib.parse.urlparse(target)
            require(parsed.scheme == 'https' and parsed.hostname in ['github.com',
                    'release-assets.githubusercontent.com', 'objects.githubusercontent.com'], 'download_invalid')
            return super().redirect_request(request, fp, code, message, headers, target)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), OfficialRedirect())
    with opener.open(request, timeout=30) as response:
        parsed = urllib.parse.urlparse(response.url)
        require(parsed.scheme == 'https' and (parsed.hostname in ['raw.githubusercontent.com', 'github.com',
                'release-assets.githubusercontent.com', 'objects.githubusercontent.com']), 'download_invalid')
        data = response.read(limit + 1)
        require(len(data) <= limit, 'download_too_large')
        return data


CATALOG_BASE = 'https://raw.githubusercontent.com/skyonave/sky_ui/main/compatibility/cores'
CORE_REPOSITORIES = {'mihomo': 'MetaCubeX/mihomo', 'sing-box': 'SagerNet/sing-box', 'xray': 'XTLS/Xray-core'}


def verified_release(core, selected=None):
    require(core in CORE_REPOSITORIES and (selected is None or TAG.fullmatch(selected)), 'core_release_unverified')
    try:
        catalog = json.loads(download(CATALOG_BASE + '/' + core + '.json', 262144))
        require(catalog['schemaVersion'] == 1 and catalog['coreId'] == core and
                isinstance(catalog['releases'], list) and len(catalog['releases']) <= 256, 'catalog_unavailable')
        panel = read_regular(CURRENT.resolve(strict=True) / 'VERSION', 128).decode().strip()
        platform_key = {'x86_64': 'linux-amd64', 'aarch64': 'linux-arm64'}.get(platform.machine())
        approved = []
        seen = set()
        for release in catalog['releases']:
            if release.get('verified') is not True:
                continue
            version = release['version']
            require(TAG.fullmatch(version) and version not in seen, 'catalog_unavailable')
            seen.add(version)
            require(isinstance(release['panelVersions'], list), 'catalog_unavailable')
            if panel not in release['panelVersions']:
                continue
            asset = release['platforms'].get(platform_key)
            if not isinstance(asset, dict) or asset.get('verified') is not True:
                continue
            require(re.fullmatch(r'[a-zA-Z0-9._-]+', asset['asset']) and
                    re.fullmatch(r'[a-f0-9]{64}', asset['sha256']), 'catalog_unavailable')
            approved.append((version, asset))
        approved.sort(key=lambda item: tuple(map(int, item[0][1:].split('.'))), reverse=True)
        chosen = next((item for item in approved if selected is None or item[0] == selected), None)
        require(chosen is not None, 'core_release_unverified')
        tag, asset = chosen
        url = f"https://github.com/{CORE_REPOSITORIES[core]}/releases/download/{tag}/{asset['asset']}"
        return tag, url, asset['sha256']
    except MaintenanceError:
        raise
    except Exception:
        raise MaintenanceError('catalog_unavailable')


def latest_mihomo(selected=None):
    return verified_release('mihomo', selected)


def switch_link(link, destination):
    temporary = link.with_name('.next-' + os.urandom(8).hex())
    temporary.symlink_to(destination)
    os.replace(temporary, link)


def update_core(core, tag, gid):
    require(core == 'mihomo', 'core_unsupported')
    latest, url, expected = latest_mihomo(tag)
    require(tag == latest, 'release_changed')
    compressed = download(url, 40 * 1024 * 1024)
    require(digest(compressed) == expected, 'release_checksum_failed')
    with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as archive:
        binary = archive.read(100 * 1024 * 1024 + 1)
    require(binary.startswith(b'\x7fELF') and len(binary) <= 100 * 1024 * 1024, 'binary_invalid')
    root = CORES / core
    slot = root / (tag + '-' + digest(binary)[:16])
    slot.mkdir(mode=0o755, exist_ok=True)
    os.chmod(slot, 0o755)
    atomic(slot / 'mihomo', binary, 0o755, 0, 0)
    try:
        found = run(['runuser', '-u', 'sky-ui-core', '--', str(slot / 'mihomo'), '-v']).decode()
    except MaintenanceError:
        raise MaintenanceError('binary_probe_failed')
    require(re.search(r'\bv?' + re.escape(tag[1:]) + r'\b', found), 'binary_version_mismatch')
    candidate_validate(slot / 'mihomo', DATA / 'cores/mihomo/config.yaml', DATA / 'cores/mihomo')
    link = root / 'current'
    previous = link.resolve(strict=True)
    require(previous.is_relative_to(Path('/opt/sky-ui/releases')) or previous.is_relative_to(root), 'unsafe_file')
    running = active('sky-ui-mihomo.service')
    atomic(STATE / 'update-intent.json', json.dumps({'path': str(previous)}).encode())
    try:
        switch_link(link, slot)
        if running:
            run(['systemctl', 'restart', 'sky-ui-mihomo.service'])
            ready(environment(), version=tag)
        atomic(root / 'previous.json', json.dumps({'path': str(previous)}).encode(), gid=gid)
        (STATE / 'update-intent.json').unlink()
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
            'update': {'id', 'action', 'core', 'tag'}}
    require(action in keys and set(value) == keys[action], 'request_invalid')
    if action == 'restore':
        require(ID.fullmatch(value['backupId']), 'request_invalid')
    if action == 'update':
        require(value['core'] == 'mihomo' and TAG.fullmatch(value['tag']), 'request_invalid')
    if remove:
        path.unlink()
    return value


def recover(gid):
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


def main():
    require(os.geteuid() == 0, 'root_required')
    os.umask(0o077)
    owner = pwd.getpwnam('sky-ui')
    if sys.argv[1:2] == ['--cli']:
        cli(sys.argv[2:], owner)
        return
    lock = open(STATE / 'worker.lock', 'a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if sys.argv[1:] == ['--recover']:
        recover(owner.pw_gid)
        return
    require(not (STATE / 'restore-intent.json').exists() and not (STATE / 'update-intent.json').exists(),
            'maintenance_recovery_required')
    job = consume_request(STATE / 'inbox/request.json', owner.pw_uid, remove=False)
    result = {key: job[key] for key in ['id', 'action']}
    result['status'] = 'running'
    output = STATE / 'result.json'
    atomic(output, json.dumps(result).encode(), gid=owner.pw_gid)
    (STATE / 'inbox/request.json').unlink()
    api_running = active('sky-ui.service')
    try:
        # The API is stopped after the durable job is visible, so configuration
        # writes cannot race snapshots, restores or binary activation.
        if api_running:
            time.sleep(1)
            run(['systemctl', 'stop', 'sky-ui.service'])
        if job['action'] == 'backup':
            result['data'] = create_backup(owner.pw_gid)
        elif job['action'] == 'restore':
            result['data'] = restore_backup(job['backupId'], owner.pw_gid)
        else:
            result['data'] = update_core(job['core'], job['tag'], owner.pw_gid)
        result['status'] = 'completed'
    except Exception as error:
        result.update(status='failed', error=str(error) if isinstance(error, MaintenanceError) else 'maintenance_failed')
    finally:
        if api_running and not (STATE / 'restore-intent.json').exists() and not (STATE / 'update-intent.json').exists():
            try:
                run(['systemctl', 'reset-failed', 'sky-ui.service'])
                run(['systemctl', 'start', 'sky-ui.service'])
                api_ready(environment())
            except Exception:
                result.update(status='failed', error='api_not_ready')
        atomic(output, json.dumps(result).encode(), gid=owner.pw_gid)


def cli(arguments, owner):
    require(arguments and arguments[0] in ['backup', 'backups', 'restore', 'update-core'], 'request_invalid')
    if arguments == ['backups']:
        for path in sorted((STATE / 'backups').glob('*.json')):
            value = json.loads(read_regular(path, 4096))
            print(value['id'], value['created'], value['version'], value['size'])
        return
    if arguments == ['backup']:
        job = {'action': 'backup'}
    elif len(arguments) == 2 and arguments[0] == 'restore':
        require(ID.fullmatch(arguments[1]), 'request_invalid')
        print('Restore replaces settings, access and owner data. Services restart and sessions are revoked.')
        require(input('Type RESTORE to continue: ') == 'RESTORE', 'cancelled')
        job = {'action': 'restore', 'backupId': arguments[1]}
    elif arguments == ['update-core']:
        tag, _, _ = latest_mihomo()
        print('Install official mihomo', tag, 'and restart the running core after validation.')
        require(input('Type UPDATE to continue: ') == 'UPDATE', 'cancelled')
        job = {'action': 'update', 'core': 'mihomo', 'tag': tag}
    else:
        raise MaintenanceError('request_invalid')
    require(not (STATE / 'inbox/request.json').exists() and not active('sky-ui-maintenance.service'), 'maintenance_busy')
    job['id'] = os.urandom(16).hex()
    atomic(STATE / 'inbox/request.json', json.dumps(job).encode(), 0o600, owner.pw_uid, owner.pw_gid)
    run(['systemctl', 'start', '--no-block', 'sky-ui-maintenance.service'])
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
                         'sky-ui-maintenance.service']).decode().strip()
            if state == 'failed':
                pending = STATE / 'inbox/request.json'
                if pending.exists() and json.loads(read_regular(pending, 4096)).get('id') == job['id']:
                    pending.unlink()
                raise MaintenanceError('Служба обслуживания не запустилась. Проверь skyui logs all.')
        time.sleep(.5)
    raise MaintenanceError('maintenance_timeout')


if __name__ == '__main__':
    main()
