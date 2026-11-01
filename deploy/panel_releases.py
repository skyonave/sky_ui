#!/usr/bin/env python3
"""Unprivileged release discovery shared with the privileged updater."""
import argparse
import datetime
import functools
import hashlib
import json
from pathlib import Path
import re
import sys

import core_artifacts as artifacts

FEED = 'https://api.github.com/repos/skyonave/sky_ui/releases?per_page=20'
REPOSITORY = 'https://github.com/skyonave/sky_ui'
VERSION = re.compile(r'v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?')


def version(value):
    if not isinstance(value, str) or len(value) > 96:
        return None
    match = VERSION.fullmatch(value)
    if not match:
        return None
    pre = match[4].split('.') if match[4] else []
    if any(x.isdigit() and len(x) > 1 and x[0] == '0' for x in pre):
        return None
    return tuple(int(match[i]) for i in (1, 2, 3)), pre


def compare(left, right):
    left, right = version(left), version(right)
    artifacts.require(left is not None and right is not None, 'release_invalid')
    if left[0] != right[0]:
        return (left[0] > right[0]) - (left[0] < right[0])
    a, b = left[1], right[1]
    if not a or not b:
        return bool(b) - bool(a)
    for x, y in zip(a, b):
        if x == y:
            continue
        if x.isdigit() and y.isdigit():
            return (int(x) > int(y)) - (int(x) < int(y))
        if x.isdigit() != y.isdigit():
            return -1 if x.isdigit() else 1
        return (x > y) - (x < y)
    return (len(a) > len(b)) - (len(a) < len(b))


def release_assets(release, platform):
    tag = release['tag_name']
    if platform not in ('linux-amd64', 'linux-arm64'):
        return None
    bundle = 'sky-ui-' + platform + '.tar.gz'
    required = {bundle: 160 * 1024 * 1024, bundle + '.sha256': 4096,
                'install.sh': 262144, 'install.sh.sha256': 4096}
    assets = release.get('assets')
    if not isinstance(assets, list) or len(assets) > 100:
        return None
    result = {}
    for item in assets:
        name = item.get('name')
        if name not in required:
            continue
        if (name in result or item.get('state') != 'uploaded' or
                type(item.get('size')) is not int or not 0 < item['size'] <= required[name] or
                not isinstance(item.get('digest'), str) or
                not re.fullmatch(r'sha256:[a-f0-9]{64}', item['digest']) or
                item.get('browser_download_url') != f'{REPOSITORY}/releases/download/{tag}/{name}'):
            return None
        result[name] = item
    return result if result.keys() == required.keys() else None


def candidate(current, platform, requested=None, *, fetch=artifacts.download):
    artifacts.require(version(current) is not None, 'release_invalid')
    artifacts.require(requested is None or (version(requested) and requested.startswith('v')), 'release_invalid')
    if platform not in ('linux-amd64', 'linux-arm64'):
        return None
    try:
        releases = json.loads(fetch(FEED, 2 * 1024 * 1024))
        artifacts.require(isinstance(releases, list) and len(releases) <= 20, 'release_feed_unavailable')
        choices = []
        for release in releases:
            tag = release.get('tag_name')
            parsed = version(tag)
            if (not parsed or not tag.startswith('v') or release.get('draft') is not False or
                    compare(tag, current) <= 0 or
                    (not version(current)[1] and (parsed[1] or release.get('prerelease') is True)) or
                    (requested is not None and requested != tag)):
                continue
            assets = release_assets(release, platform)
            if assets is not None:
                choices.append({'tag': tag, 'assets': assets})
        choices.sort(key=functools.cmp_to_key(lambda a, b: compare(a['tag'], b['tag'])), reverse=True)
        return choices[0] if choices else None
    except artifacts.ArtifactError:
        raise
    except Exception:
        raise artifacts.ArtifactError('release_feed_unavailable')


def discover(current, platform, requested=None, *, fetch=artifacts.download):
    found = candidate(current, platform, requested, fetch=fetch)
    return {'currentVersion': current, 'available': found is not None,
            'latestVersion': found['tag'][1:] if found else None,
            'tag': found['tag'] if found else None,
            'releaseUrl': f"{REPOSITORY}/releases/tag/{found['tag']}" if found else None,
            'supported': platform in ('linux-amd64', 'linux-arm64'),
            'checkedAt': datetime.datetime.now(datetime.timezone.utc).isoformat()}


def prepare(release, platform, destination, *, fetch=artifacts.download, on_progress=None, on_verify=None):
    files = {}
    total = sum(item['size'] for item in release['assets'].values())
    received = 0
    for name, metadata in release['assets'].items():
        def progress(size):
            if on_progress: on_progress(received + size, total, name)
        if fetch is artifacts.download:
            data = fetch(metadata['browser_download_url'], metadata['size'], on_progress=progress)
        else:
            data = fetch(metadata['browser_download_url'], metadata['size'])
        files[name] = data
        received += len(data)
        if on_progress: on_progress(received, total, name)
    if on_verify: on_verify()
    for name, metadata in release['assets'].items():
        data = files[name]
        artifacts.require(len(data) == metadata['size'] and
            'sha256:' + hashlib.sha256(data).hexdigest() == metadata['digest'], 'release_checksum_failed')
    for name in ('install.sh', 'sky-ui-' + platform + '.tar.gz'):
        parts = files[name + '.sha256'].decode('ascii').split()
        artifacts.require(len(parts) == 2 and parts[1] == name and
            parts[0] == hashlib.sha256(files[name]).hexdigest(), 'release_checksum_failed')
    destination = Path(destination)
    for name, data in files.items():
        path = destination / name
        with path.open('xb') as stream:
            stream.write(data)
        path.chmod(0o600)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('check',))
    parser.add_argument('--version', required=True)
    parser.add_argument('--platform', required=True)
    parser.add_argument('--tag')
    args = parser.parse_args()
    try:
        print(json.dumps(discover(args.version, args.platform, args.tag)))
    except Exception:
        print('release_feed_unavailable', file=sys.stderr)
        sys.exit(1)
