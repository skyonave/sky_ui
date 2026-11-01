#!/usr/bin/env python3
"""Scoped installation/lifecycle for additional engines; the API never runs as root."""
import hashlib
import io
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import tarfile
import tempfile
import time

import core_artifacts as artifacts

ENGINES = ('sing-box', 'xray', 'amneziawg')
GO_TOOLCHAINS = {
    'linux-amd64': ('go1.27.3.linux-amd64.tar.gz', '65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40'),
    'linux-arm64': ('go1.27.3.linux-arm64.tar.gz', 'a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49'),
}


def build_awg(source, work, tag, m, reporter=None):
    """Build the verified upstream source as an account with no panel data access."""
    account = pwd.getpwnam('sky-ui-build')
    tree = work / 'source'
    tree.mkdir(mode=0o755)
    with tarfile.open(fileobj=io.BytesIO(source), mode='r:gz') as archive:
        members = archive.getmembers()
        m.require(len(members) <= 8192 and sum(x.size for x in members) <= 64 * 1024 * 1024, 'archive_invalid')
        for entry in members:
            parts = Path(entry.name).parts[1:]
            m.require(not Path(entry.name).is_absolute() and '..' not in parts and (entry.isdir() or entry.isfile()), 'archive_invalid')
            if not parts:
                continue
            target = tree.joinpath(*parts)
            if entry.isdir():
                target.mkdir(mode=0o755, parents=True, exist_ok=True)
            else:
                target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                target.write_bytes(archive.extractfile(entry).read())
    for directory, dirs, files in os.walk(work):
        os.chown(directory, account.pw_uid, account.pw_gid)
        for name in files:
            os.chown(Path(directory) / name, account.pw_uid, account.pw_gid)
    # Upstream's constant still names the old WireGuard base version. Stamp the
    # verified AWG source tag in the generated build's public version only.
    (tree / 'version.go').write_text('package main\nconst Version = ' + json.dumps(tag[1:]) + '\n')
    os.chown(tree / 'version.go', account.pw_uid, account.pw_gid)
    filename, checksum = GO_TOOLCHAINS[artifacts.target_platform()]
    if reporter: reporter.stage('toolchain', bytesReceived=0, bytesTotal=None, artifact=filename)
    compiler = artifacts.download('https://go.dev/dl/' + filename, 96 * 1024 * 1024,
        **({'on_progress':lambda received:reporter.transfer(received,None,filename,'toolchain'),
            'on_size':lambda size:reporter.stage('toolchain',bytesTotal=size)} if reporter else {}))
    m.require(hashlib.sha256(compiler).hexdigest() == checksum, 'release_checksum_failed')
    with tarfile.open(fileobj=io.BytesIO(compiler), mode='r:gz') as archive:
        for entry in archive:
            path = Path(entry.name)
            m.require(not path.is_absolute() and '..' not in path.parts and path.parts[0] == 'go' and (entry.isfile() or entry.isdir()), 'archive_invalid')
            target = work / path
            if entry.isdir(): target.mkdir(parents=True, mode=0o755, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, mode=0o755, exist_ok=True)
                target.write_bytes(archive.extractfile(entry).read())
                target.chmod(0o755 if entry.mode & 0o111 else 0o644)
    # The worker's umask is 077. Explicitly make root-owned SDK directories
    # traversable by the separate build account; files remain read-only to it.
    for directory, _, _ in os.walk(work / 'go'):
        Path(directory).chmod(0o755)
    go = str(work / 'go/bin/go')
    args = ['nice', '-n', '10', 'runuser', '-u', 'sky-ui-build', '--', '/usr/bin/env',
           'HOME=' + str(work), 'GOCACHE=' + str(work / 'cache'),
           'GOMODCACHE=' + str(work / 'modules'), 'GOTOOLCHAIN=local', 'CGO_ENABLED=0',
           'GOPROXY=https://proxy.golang.org,direct', 'GOSUMDB=sum.golang.org',
           'GOMAXPROCS=1', 'GOMEMLIMIT=128MiB', 'GOFLAGS=-p=1',
           go, '-C', str(tree), 'build', '-trimpath',
           '-o', str(work / 'amneziawg'), '.']
    if reporter:
        from update_progress import run_installer, InstallerFailure
        reporter.stage('build', bytesReceived=None, bytesTotal=None, artifact=None, command='go build')
        try: run_installer(m,args,reporter,timeout=480)
        except InstallerFailure as error:
            reporter.progress['exitCode']=error.exit_code
            raise m.MaintenanceError('core_build_failed')
    else: m.run(args, timeout=480)
    return m.read_regular(work / 'amneziawg', 100 * 1024 * 1024)


def config_path(core, m):
    return m.DATA / 'cores' / core / 'config.json'


def validate(binary, core, m):
    config = config_path(core, m)
    if core == 'amneziawg':
        # Dependency packages are installed by install.sh, outside the worker's
        # read-only system mount. Keep the privileged worker narrowly scoped.
        m.require(shutil.which('nft') is not None and shutil.which('ip') is not None, 'amnezia_dependencies_required')
        import amnezia_network
        amnezia_network.load(config)
        return
    args = ['run', '-test', '-config', str(config)] if core == 'xray' else ['check', '-c', str(config)]
    m.run(['runuser', '-u', 'sky-ui-' + core, '--', str(binary), *args])


def await_ready(core, m):
    """Check sockets owned by this service, including AWG child processes."""
    value = json.loads(m.read_regular(config_path(core, m), 4 * 1024 * 1024))
    expected = []
    for item in value.get('interfaces', []) if core == 'amneziawg' else value.get('inbounds', []):
        port = item.get('listen_port', item.get('port'))
        udp = core == 'amneziawg' or item.get('type') in ('hysteria2', 'tuic') or item.get('network') == 'udp'
        expected.append((port, udp))
        if item.get('type', item.get('protocol')) == 'shadowsocks': expected.append((port, True))
    unit = 'sky-ui-' + core + '.service'
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if m.active(unit):
            group = m.run(['systemctl', 'show', '--property=ControlGroup', '--value', unit]).decode().strip()
            m.require(group == '/system.slice/' + unit, 'service_failed')
            try:
                # systemd can use either unified v2 or a legacy name=systemd
                # hierarchy. Both expose the service's actual process list.
                paths = [root / group.lstrip('/') / 'cgroup.procs' for root in
                         (Path('/sys/fs/cgroup'), Path('/sys/fs/cgroup/systemd'))]
                processes = next((path for path in paths if path.is_file()), paths[0])
                pids = processes.read_text().split()
                inodes = {os.readlink(fd)[8:-1] for pid in pids for fd in Path('/proc', pid, 'fd').iterdir() if os.readlink(fd).startswith('socket:[')}
                sockets = set()
                for family in ('tcp', 'tcp6', 'udp', 'udp6'):
                    for line in Path('/proc/net', family).read_text().splitlines()[1:]:
                        fields = line.split()
                        if fields[9] in inodes and (family.startswith('udp') or fields[3] == '0A'):
                            sockets.add((int(fields[1].split(':')[1], 16), family.startswith('udp')))
                if set(expected) <= sockets and (core != 'amneziawg' or all(Path('/sys/class/net', x['name']).exists() for x in value['interfaces'])):
                    return
            except (FileNotFoundError, ProcessLookupError): pass
        time.sleep(.2)
    raise m.MaintenanceError('listener_not_ready')


def restart_ready(core, m):
    unit = 'sky-ui-' + core + '.service'
    # Clear a candidate's crash-loop limit before activating a rollback. An
    # unloaded inactive unit may reject reset-failed; restart remains decisive.
    try: m.run(['systemctl', 'reset-failed', unit])
    except m.MaintenanceError: pass
    m.run(['systemctl', 'restart', unit])
    await_ready(core, m)


def change(action, core, tag, gid, uid, m, *, reporter=None, before_activation=None):
    m.require(core in ENGINES, 'core_unsupported')
    root = m.CORES / core
    m.core_install.trusted(root, directory=True)
    unit = 'sky-ui-' + core + '.service'
    instance = m.DATA / 'instances' / (core + '.json')
    if action == 'remove':
        value = {'instanceId': core, 'coreId': core, 'desiredState': 'stopped'}
        m.atomic(m.STATE / 'engine-intent.json', json.dumps({'action': action, 'core': core}).encode(), 0o600)
        m.run(['systemctl', 'stop', unit])
        m.require(not m.active(unit), 'service_stop_timeout')
        m.atomic(instance, json.dumps(value).encode(), 0o600, uid, gid)
        (root / 'current').unlink(missing_ok=True)
        # Only independently downloaded, root-owned managed slots are disposable.
        for slot in root.iterdir():
            if re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+-[a-f0-9]{16}', slot.name):
                m.core_install.trusted(slot, directory=True)
                for path in slot.iterdir():
                    m.require(path.name in (core, 'LICENSE', 'artifact.json'), 'unsafe_file')
                    m.core_install.trusted(path)
                for path in slot.iterdir(): path.unlink()
                slot.rmdir()
        m.atomic(root / 'removed.json', json.dumps({'coreId': core, 'removed': True}).encode(), 0o644)
        (m.STATE / 'engine-intent.json').unlink()
        return {'core': core, 'installed': False}
    previous = None
    if (root / 'current').is_symlink():
        previous = (root / 'current').resolve(strict=True)
        m.require(previous.parent == root, 'unsafe_file')
        m.core_install.trusted(previous, directory=True)
    m.require((action == 'install') == (previous is None), 'core_already_installed' if action == 'install' else 'binary_missing')
    selected, url, checksum = m.verified_release(core, tag)
    m.require(selected == tag, 'release_changed')
    try:
        if reporter: reporter.stage('download', bytesReceived=0, bytesTotal=None)
        fetch = m.download
        if reporter:
            def fetch(url, limit):
                name = url.rsplit('/',1)[-1]
                reporter.stage('download',bytesReceived=0,bytesTotal=None,artifact=name)
                return m.download(url,limit,on_progress=lambda received:reporter.transfer(received,None,name),
                    on_size=lambda size:reporter.stage('download',bytesTotal=size))
        files = artifacts.artifact_files(core, tag, url, checksum, artifacts.target_platform(), fetch=fetch)
    except artifacts.ArtifactError as error:
        raise m.MaintenanceError(str(error))
    if core == 'amneziawg':
        with tempfile.TemporaryDirectory(prefix='sky-ui-build-') as temporary:
            if reporter: files[core] = build_awg(files.pop('source.tar.gz'), Path(temporary), tag, m, reporter)
            else: files[core] = build_awg(files.pop('source.tar.gz'), Path(temporary), tag, m)
        receipt = json.loads(files['artifact.json'])
        receipt['binarySha256'] = hashlib.sha256(files[core]).hexdigest()
        files['artifact.json'] = json.dumps(receipt).encode()
    digest = hashlib.sha256(files[core]).hexdigest()
    slot = root / (tag + '-' + digest[:16])
    if slot.exists(): m.core_install.trusted(slot, directory=True)
    else: slot.mkdir(mode=0o755)
    # The root worker uses umask 077; native parsers run as dedicated users.
    slot.chmod(0o755)
    for name, data in files.items():
        m.require(name in (core, 'LICENSE', 'artifact.json'), 'archive_invalid')
        m.atomic(slot / name, data, 0o755 if name == core else 0o644)
    if reporter: reporter.stage('validate', bytesReceived=None, bytesTotal=None, artifact=None, command=None)
    if before_activation: before_activation()
    validate(slot / core, core, m)
    running = m.active(unit)
    m.atomic(m.STATE / 'engine-intent.json', json.dumps({'action': action, 'core': core, 'previous': str(previous) if previous else None, 'running': running}).encode(), 0o600)
    try:
        if reporter: reporter.stage('activate')
        m.switch_link(root / 'current', slot)
        if running:
            restart_ready(core, m)
        (root / 'removed.json').unlink(missing_ok=True)
        (m.STATE / 'engine-intent.json').unlink()
    except Exception:
        if previous: m.switch_link(root / 'current', previous)
        else: (root / 'current').unlink(missing_ok=True)
        if running:
            restart_ready(core, m)
        (m.STATE / 'engine-intent.json').unlink(missing_ok=True)
        raise m.MaintenanceError('update_rolled_back')
    return {'core': core, 'version': tag, 'installed': True}


def recover(gid, uid, m):
    path = m.STATE / 'engine-intent.json'
    if not path.exists(): return
    value = json.loads(m.read_regular(path, 4096))
    core = value.get('core')
    m.require(core in ENGINES, 'request_invalid')
    if value.get('action') == 'remove':
        change('remove', core, None, gid, uid, m)
        return
    link = m.CORES / core / 'current'
    if value.get('previous'):
        previous = Path(value['previous'])
        m.require(previous.parent == m.CORES / core, 'unsafe_file')
        m.core_install.trusted(previous, directory=True)
        m.switch_link(link, previous)
    else: link.unlink(missing_ok=True)
    if value.get('running'):
        restart_ready(core, m)
    path.unlink()
