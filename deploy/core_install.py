#!/usr/bin/env python3
"""Bootstrap a managed core without including it in the panel release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import subprocess
import sys

import core_artifacts as artifacts

CORE = Path('/opt/sky-ui/cores/mihomo')
RELEASES = Path('/opt/sky-ui/releases')


def trusted(path, directory=False):
    path = Path(path)
    for parent in (path, *path.parents):
        artifacts.require(not parent.is_symlink(), 'unsafe_file')
    info = path.stat()
    artifacts.require(info.st_uid == 0 and not info.st_mode & 0o022 and
                      (stat.S_ISDIR(info.st_mode) if directory else
                       stat.S_ISREG(info.st_mode) and info.st_nlink == 1), 'unsafe_file')
    return path


def existing_core(root=CORE, releases=RELEASES):
    link = root / 'current'
    if not link.exists() and not link.is_symlink():
        return None
    artifacts.require(link.is_symlink(), 'unsafe_file')
    target = link.resolve(strict=True)
    artifacts.require(target.parent == root or
                      (target.name == 'bin' and target.parent.parent == releases), 'unsafe_file')
    trusted(target, directory=True)
    return trusted(target / 'mihomo')


def prepare(panel_version, platform_key, output, *, root=CORE, releases=RELEASES, fetch=artifacts.download):
    marker = root / 'removed.json'
    if marker.exists():
        artifacts.require(json.loads(trusted(marker).read_bytes()) == {'coreId': 'mihomo', 'removed': True}, 'unsafe_file')
        print('Keeping the core intentionally uninstalled.', file=sys.stderr)
        return None
    existing = existing_core(root, releases)
    if existing is None:
        print('Downloading the project-approved mihomo release…', file=sys.stderr)
        return artifacts.prepare('mihomo', panel_version, platform_key, output, fetch=fetch)
    if existing.parent.parent == root:
        print('Keeping the installed core.', file=sys.stderr)
        return existing
    # Copy the exact legacy binary into independent storage; never run it as root.
    output = Path(output)
    output.mkdir(mode=0o755)
    output.chmod(0o755)
    binary = existing.read_bytes()
    source_license = trusted(existing.parent.parent / 'licenses/mihomo.LICENSE')
    receipt = {'coreId': 'mihomo', 'version': None, 'platform': platform_key,
               'binarySha256': hashlib.sha256(binary).hexdigest(), 'source': 'legacy-panel-bundle'}
    for name, data in {'mihomo': binary, 'LICENSE': source_license.read_bytes(),
                       'artifact.json': json.dumps(receipt).encode()}.items():
        path = output / name
        with path.open('xb') as stream:
            stream.write(data)
        path.chmod(0o755 if name == 'mihomo' else 0o644)
    print('Moving the existing core out of the panel release without changing its binary.', file=sys.stderr)
    return output / 'mihomo'


def validate(binary, configuration, directory):
    binary = trusted(Path(binary))
    args = ['runuser', '-u', 'sky-ui-core', '-g', 'sky-ui', '--', 'env',
            'SAFE_PATHS=/var/lib/sky-ui-certificates', str(binary)]
    version = subprocess.run(args + ['-v'], capture_output=True, text=True, timeout=20, check=True).stdout
    receipt = binary.parent / 'artifact.json'
    if receipt.exists():
        expected = json.loads(trusted(receipt).read_bytes()).get('version')
        if expected:
            artifacts.require(re.search(r'\bv?' + re.escape(expected[1:]) + r'\b', version),
                              'binary_version_mismatch')
    subprocess.run(args + ['-t', '-d', str(directory), '-f', str(configuration)], check=True, timeout=30)


def activate(prepared, *, root=CORE, releases=RELEASES):
    installed = existing_core(root, releases)
    if installed is not None and installed.parent.parent == root:
        return installed
    prepared = Path(prepared)
    files = {name: trusted(prepared / name).read_bytes() for name in ('mihomo','LICENSE','artifact.json')}
    receipt = json.loads(files['artifact.json'])
    digest = hashlib.sha256(files['mihomo']).hexdigest()
    artifacts.require(receipt['coreId'] == 'mihomo' and receipt['binarySha256'] == digest, 'release_checksum_failed')
    version = receipt.get('version')
    artifacts.require((version is not None and artifacts.TAG.fullmatch(version)) or
                      (version is None and receipt['source'] == 'legacy-panel-bundle'), 'binary_invalid')
    trusted(root, directory=True)
    slot = root / ((version or 'imported') + '-' + digest[:16])
    if slot.exists():
        trusted(slot, directory=True)
        artifacts.require(hashlib.sha256(trusted(slot / 'mihomo').read_bytes()).hexdigest() == digest,
                          'release_checksum_failed')
    else:
        staging = root / ('.bootstrap-' + secrets.token_hex(8))
        staging.mkdir(mode=0o755)
        staging.chmod(0o755)
        try:
            for name, data in files.items():
                path = staging / name
                with path.open('xb') as stream:
                    stream.write(data)
                path.chmod(0o755 if name == 'mihomo' else 0o644)
            staging.rename(slot)
        finally:
            if staging.exists():
                shutil.rmtree(staging)
    link = root / ('.next-' + secrets.token_hex(8))
    try:
        link.symlink_to(slot)
        os.replace(link, root / 'current')
        # Initial independent installs have no earlier slot to retain.
        # Later replacements are tracked after the worker health check.
        if installed is None:
            marker=root/'retention.json'
            if not marker.exists():
                marker.write_text(json.dumps({'current':str(slot),'previous':None}))
                marker.chmod(0o600)
    finally:
        link.unlink(missing_ok=True)
    return slot / 'mihomo'


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='action',required=True)
    prepare_command = commands.add_parser('prepare')
    prepare_command.add_argument('--panel-version',required=True)
    prepare_command.add_argument('--platform',required=True,choices=('linux-amd64','linux-arm64'))
    prepare_command.add_argument('--output',type=Path,required=True)
    validate_command = commands.add_parser('validate')
    validate_command.add_argument('--binary',type=Path,required=True)
    validate_command.add_argument('--configuration',type=Path,required=True)
    validate_command.add_argument('--directory',type=Path,required=True)
    activate_command = commands.add_parser('activate')
    activate_command.add_argument('--prepared',type=Path,required=True)
    args = parser.parse_args()
    artifacts.require(os.geteuid() == 0, 'root_required')
    if args.action == 'prepare':
        result = prepare(args.panel_version,args.platform,args.output)
        print(result if result is not None else "-")
    elif args.action == 'validate':
        validate(args.binary,args.configuration,args.directory)
    else:
        print(activate(args.prepared))


if __name__ == '__main__':
    try:
        main()
    except (artifacts.ArtifactError, OSError, ValueError, subprocess.SubprocessError) as error:
        print('Sky UI core: ' + str(error),file=sys.stderr)
        sys.exit(1)
