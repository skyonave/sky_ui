#!/usr/bin/env python3
"""Acquire pinned upstream engines into a private fixture, never into live slots."""
import hashlib
import json
import os
from pathlib import Path
import pwd
import subprocess
import sys
import tempfile
import io
import tarfile
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'deploy'))
import core_artifacts as artifacts
import engine_install
import maintenance as m


def main():
    fixture = Path(sys.argv[1]).resolve()
    if 'protocol-first' not in str(fixture): raise SystemExit('Use a dedicated protocol-first fixture directory.')
    fixture.mkdir(mode=0o700, parents=True, exist_ok=True)
    pins = {
        'mihomo': ('v1.19.33', 'mihomo-linux-amd64-v1-v1.19.33.gz', '8ec92e7b2fdc6b853ba00156bab7e4e965c8b0d843b8c4ac8ab98795f02ad524'),
        'sing-box': ('v1.14.4', 'sing-box-1.14.4-linux-amd64.tar.gz', '699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968'),
        'xray': ('v26.10.31', 'Xray-linux-64.zip', 'e4bd9119f50ae7c41658b1abd0679ae06f98bd864a2907ff33f2f2cf7081b214'),
    }
    for core, (tag, asset, sha) in pins.items():
        destination = fixture / core
        if destination.exists(): continue
        url = f'https://github.com/{artifacts.REPOSITORIES[core]}/releases/download/{tag}/{asset}'
        def fetch(selected, limit):
            data = artifacts.download(selected, limit)
            if core == 'sing-box' and selected == url:
                assert hashlib.sha256(data).hexdigest() == sha
                with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                    library = archive.getmember(f'sing-box-{tag[1:]}-linux-amd64/libcronet.so')
                    assert library.isfile() and library.size <= 32 * 1024 * 1024
                    (fixture/'libcronet.so').write_bytes(archive.extractfile(library).read())
            return data
        files = artifacts.artifact_files(core, tag, url, sha, 'linux-amd64', fetch=fetch)
        for name, data in files.items():
            target = fixture / (core if name == core else core + '.' + name)
            target.write_bytes(data); target.chmod(0o755 if name == core else 0o600)
        print(core, 'verified', flush=True)
    tag = 'v3.1.20260828'
    source = artifacts.download(f'https://github.com/amnezia-vpn/amneziawg-go/archive/refs/tags/{tag}.tar.gz', 16 * 1024 * 1024)
    assert hashlib.sha256(source).hexdigest() == '24c656cfb80ff6855702710eaf2e3729fa710bf6bfdbbbdfba01984ccd17de95'
    print('AWG source SHA256', hashlib.sha256(source).hexdigest(), flush=True)
    (fixture / 'awg-source.sha256').write_text(hashlib.sha256(source).hexdigest())
    try: pwd.getpwnam('sky-ui-build')
    except KeyError:
        subprocess.run(['useradd', '--system', '--no-create-home', '--home-dir', '/nonexistent', '--shell', '/usr/sbin/nologin', 'sky-ui-build'], check=True)
    if not (fixture / 'amneziawg').exists():
        with tempfile.TemporaryDirectory(prefix='sky-ui-awg-build-') as temporary:
            binary = engine_install.build_awg(source, Path(temporary), tag, SimpleNamespace(**vars(m)))
        (fixture / 'amneziawg').write_bytes(binary); (fixture / 'amneziawg').chmod(0o755)
        print('AWG build verified', flush=True)


if __name__ == '__main__': main()
