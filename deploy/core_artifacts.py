#!/usr/bin/env python3
"""Project-approved core artifacts shared by initial installation and updates."""
import gzip
import hashlib
import io
import json
from pathlib import Path
import platform
import re
import urllib.parse
import urllib.request

CATALOG_BASE = 'https://raw.githubusercontent.com/skyonave/sky_ui/main/compatibility/cores'
REPOSITORIES = {'mihomo': 'MetaCubeX/mihomo', 'sing-box': 'SagerNet/sing-box', 'xray': 'XTLS/Xray-core'}
TAG = re.compile(r'v[0-9]+\.[0-9]+\.[0-9]+')


class ArtifactError(Exception):
    pass


def require(condition, code):
    if not condition:
        raise ArtifactError(code)


def target_platform():
    return {'x86_64': 'linux-amd64', 'aarch64': 'linux-arm64'}.get(platform.machine())


def download(url, limit):
    allowed = {'raw.githubusercontent.com', 'github.com', 'api.github.com',
               'release-assets.githubusercontent.com', 'objects.githubusercontent.com'}

    def check(target):
        parsed = urllib.parse.urlparse(target)
        require(parsed.scheme == 'https' and parsed.hostname in allowed and
                parsed.username is None and parsed.password is None and parsed.port in (None, 443),
                'download_invalid')

    class OfficialRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, request, fp, code, message, headers, target):
            check(target)
            return super().redirect_request(request, fp, code, message, headers, target)

    check(url)
    request = urllib.request.Request(url, headers={'User-Agent': 'Sky-UI', 'Cache-Control': 'no-cache'})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), OfficialRedirect())
    with opener.open(request, timeout=30) as response:
        check(response.url)
        data = response.read(limit + 1)
        require(len(data) <= limit, 'download_too_large')
        return data


def verified_release(core, panel_version, platform_key, selected=None, *, fetch=download):
    require(core in REPOSITORIES and (selected is None or TAG.fullmatch(selected)), 'core_release_unverified')
    try:
        catalog = json.loads(fetch(f'{CATALOG_BASE}/{core}.json', 262144))
        require(type(catalog['schemaVersion']) is int and catalog['schemaVersion'] == 1 and
                catalog['coreId'] == core and isinstance(catalog['releases'], list) and
                len(catalog['releases']) <= 256, 'catalog_unavailable')
        approved, seen = [], set()
        for release in catalog['releases']:
            if release.get('verified') is not True:
                continue
            version = release['version']
            require(TAG.fullmatch(version) and version not in seen, 'catalog_unavailable')
            seen.add(version)
            require(isinstance(release['panelVersions'], list), 'catalog_unavailable')
            if panel_version not in release['panelVersions']:
                continue
            asset = release['platforms'].get(platform_key)
            if not isinstance(asset, dict) or asset.get('verified') is not True:
                continue
            require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,255}', asset['asset']) and
                    re.fullmatch(r'[a-f0-9]{64}', asset['sha256']), 'catalog_unavailable')
            approved.append((version, asset))
        approved.sort(key=lambda item: tuple(map(int, item[0][1:].split('.'))), reverse=True)
        chosen = next((item for item in approved if selected is None or item[0] == selected), None)
        require(chosen is not None, 'core_release_unverified')
        tag, asset = chosen
        return tag, f"https://github.com/{REPOSITORIES[core]}/releases/download/{tag}/{asset['asset']}", asset['sha256']
    except ArtifactError:
        raise
    except Exception:
        raise ArtifactError('catalog_unavailable')


def artifact_files(core, tag, url, expected, platform_key, *, fetch=download):
    require(core == 'mihomo', 'core_unsupported')
    compressed = fetch(url, 40 * 1024 * 1024)
    require(hashlib.sha256(compressed).hexdigest() == expected, 'release_checksum_failed')
    with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as archive:
        binary = archive.read(100 * 1024 * 1024 + 1)
    machine = {'linux-amd64': 62, 'linux-arm64': 183}.get(platform_key)
    require(machine is not None and 64 <= len(binary) <= 100 * 1024 * 1024 and
            binary[:6] == b'\x7fELF\x02\x01' and int.from_bytes(binary[18:20], 'little') == machine,
            'binary_invalid')
    license_data = fetch(f'https://raw.githubusercontent.com/{REPOSITORIES[core]}/{tag}/LICENSE', 1048576)
    require(bool(license_data.decode('utf-8').strip()), 'license_invalid')
    receipt = {'coreId': core, 'version': tag, 'platform': platform_key,
               'archiveSha256': expected, 'binarySha256': hashlib.sha256(binary).hexdigest(), 'source': url}
    return {core: binary, 'LICENSE': license_data, 'artifact.json': json.dumps(receipt).encode()}


def prepare(core, panel_version, platform_key, output, *, fetch=download):
    tag, url, expected = verified_release(core, panel_version, platform_key, fetch=fetch)
    files = artifact_files(core, tag, url, expected, platform_key, fetch=fetch)
    output = Path(output)
    output.mkdir(mode=0o755)
    output.chmod(0o755)
    for name, data in files.items():
        path = output / name
        with path.open('xb') as stream:
            stream.write(data)
        path.chmod(0o755 if name == core else 0o644)
    return output / core
