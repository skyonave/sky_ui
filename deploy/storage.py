#!/usr/bin/env python3
"""Bounded storage for managed releases, engine slots and maintenance artifacts."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import time

import core_install
import panel_releases

RELEASE = re.compile(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?-(?:amd64|arm64)')
SLOT = re.compile(r'(?:v\d+\.\d+\.\d+|imported)-[0-9a-f]{16}')
LOG = re.compile(r'(?:update|maintenance)-([0-9a-f]{32})\.log')
DAY = 86400


class Retention:
    def __init__(self, m, releases=Path('/opt/sky-ui/releases'), proc=Path('/proc'), temporary=Path('/var/tmp')):
        self.m, self.releases, self.proc = m, releases, proc
        self.temporary=temporary
        self.removed = []

    def read(self, file):
        if not file.exists(): return {}
        return json.loads(self.m.read_regular(core_install.trusted(file), 16384))

    def target(self, link):
        if not link.is_symlink(): return None
        target = link.resolve(strict=True)
        core_install.trusted(target, directory=True)
        return target

    def record(self, root, current, previous):
        """Only called after activation has passed health checks, under its lock."""
        core_install.trusted(root, directory=True)
        marker = root / 'retention.json'
        old = self.read(marker)
        if previous == current:
            previous = Path(old['previous']) if old.get('current') == str(current) and old.get('previous') else None
        if previous is not None:
            legacy=root.parent==self.m.CORES and previous.name=='bin' and previous.parent.parent==self.releases
            if (previous.parent != root and not legacy) or previous.is_symlink(): raise ValueError('unsafe_retention_path')
            core_install.trusted(previous, directory=True)
        self.m.atomic(marker, json.dumps({'current':str(current), 'previous':str(previous) if previous else None}).encode(), 0o600)

    def record_panel(self, previous):
        current = self.target(self.m.CURRENT)
        if current is None or current.parent != self.releases: raise ValueError('unsafe_retention_path')
        self.record(self.releases, current, Path(previous) if previous else None)

    def record_core(self, core, previous):
        root = self.m.CORES / core
        current = self.target(root / 'current')
        if current is None or current.parent != root: return
        self.record(root, current, previous)

    def referenced(self):
        """Preserve binaries/libraries and code still used by a running process."""
        result = []
        if not self.proc.exists(): return result
        for proc in self.proc.iterdir():
            if not proc.name.isdigit(): continue
            try:
                for name in ('exe','cwd'):
                    try: result.append(os.readlink(proc/name))
                    except OSError: pass
                result.extend((proc/'cmdline').read_bytes().decode(errors='replace').split('\0'))
                result.extend(line.split(maxsplit=5)[5] for line in (proc/'maps').read_text().splitlines() if len(line.split(maxsplit=5)) == 6)
                for fd in (proc/'fd').iterdir():
                    try: result.append(os.readlink(fd))
                    except OSError: pass
            except PermissionError: raise
            except (OSError, ProcessLookupError): pass
        return result

    def remove(self, path, root):
        if path.parent != root or path.is_symlink() or path.resolve() != path: raise ValueError('unsafe_retention_path')
        core_install.trusted(path, directory=path.is_dir())
        if path.is_dir(): shutil.rmtree(path)
        else: path.unlink()
        self.removed.append(str(path))

    def prune_versions(self, root, current, pattern, refs, *, panel=False):
        core_install.trusted(root, directory=True)
        candidates = [p for p in root.iterdir() if pattern.fullmatch(p.name) and p.is_dir() and not p.is_symlink()]
        keep = {current} if current else set()
        history = self.read(root/'retention.json')
        previous = None
        if current and history.get('current') == str(current):
            if history.get('previous'):
                previous = Path(history['previous'])
                legacy=root.parent==self.m.CORES and previous.name=='bin' and previous.parent.parent==self.releases
                if previous.parent != root and not legacy: raise ValueError('unsafe_retention_path')
                if previous.exists(): keep.add(previous)
                if legacy: refs.append(str(previous))
        elif current:
            older = [p for p in candidates if p != current]
            if panel:
                older = [p for p in older if panel_releases.compare(p.name.rsplit('-',1)[0], current.name.rsplit('-',1)[0]) < 0]
            if older: keep.add(max(older,key=lambda p:p.stat().st_mtime_ns))
        for p in candidates:
            if p in keep or any(ref == str(p) or ref.startswith(str(p)+'/') for ref in refs): continue
            self.remove(p,root)

    def prune_files(self, now):
        state = self.m.STATE
        result = self.read(state/'result.json')
        logs = state/'logs'
        if logs.exists():
            core_install.trusted(logs,directory=True)
            files = sorted([p for p in logs.iterdir() if LOG.fullmatch(p.name) and p.is_file() and not p.is_symlink()],key=lambda p:p.stat().st_mtime_ns,reverse=True)
            current_log=next((p for p in files if LOG.fullmatch(p.name)[1] == result.get('id')),None)
            keep=set(p for p in files if p!=current_log)
            keep=set(sorted(keep,key=lambda p:p.stat().st_mtime_ns,reverse=True)[:19 if current_log else 20])
            if current_log:keep.add(current_log)
            for p in files:
                if LOG.fullmatch(p.name)[1] == result.get('id'): continue
                if p not in keep or now-p.stat().st_mtime > 14*DAY: self.remove(p,logs)
        # Manual backups and unknown/legacy backup metadata are never expired.
        backups = state/'backups'
        if backups.exists():
            rescue = []
            for p in backups.glob('*.json'):
                if re.fullmatch(r'[0-9a-f]{32}\.json',p.name) and self.read(p).get('purpose') == 'rescue': rescue.append(p)
            for p in sorted(rescue,key=lambda p:p.stat().st_mtime_ns,reverse=True)[1:]:
                archive = backups/(p.stem+'.tar.gz')
                if archive.exists(): self.remove(archive,backups)
                self.remove(p,backups)
        work = state/'work'
        if work.exists():
            core_install.trusted(work,directory=True)
            for p in work.iterdir():
                if re.fullmatch(r'(?:tmp|panel-update-|prepare\.)[A-Za-z0-9_.-]+',p.name) and not p.is_symlink() and now-p.stat().st_mtime > DAY: self.remove(p,work)

    def clean(self):
        state = self.m.STATE
        core_install.trusted(state,directory=True)
        if any(p.name != 'cleanup-intent.json' for p in state.glob('*intent.json')) or (state/'inbox/request.json').exists(): return {'skipped':'busy'}
        if self.read(state/'result.json').get('status') in ('queued','running'): return {'skipped':'busy'}
        panel=self.target(self.m.CURRENT)
        if panel is None or panel.parent!=self.releases or not RELEASE.fullmatch(panel.name): raise ValueError('unsafe_retention_path')
        refs = self.referenced()
        for core in ('mihomo','sing-box','xray','amneziawg'):
            root = self.m.CORES/core
            if not root.exists(): continue
            current = self.target(root/'current')
            if current and not (current.parent==root or current.name=='bin' and current.parent.parent==self.releases): raise ValueError('unsafe_retention_path')
            if current: refs.append(str(current))
            self.prune_versions(root,current,SLOT,refs)
        self.prune_versions(self.releases,panel,RELEASE,refs,panel=True)
        self.prune_files(time.time())
        if self.temporary.exists():
            for p in self.temporary.iterdir():
                if re.fullmatch(r'sky-ui-install\.[A-Za-z0-9]{8}',p.name) and p.is_dir() and not p.is_symlink() and p.stat().st_uid==0 and time.time()-p.stat().st_mtime>DAY:
                    if not any(ref==str(p) or ref.startswith(str(p)+'/') for ref in refs):self.remove(p,self.temporary)
        return {'removed':len(self.removed)}


def best_effort(m, kind, previous, core=None):
    try:
        retention = Retention(m)
        if kind == 'panel': retention.record_panel(previous)
        else: retention.record_core(core,previous)
    except Exception:
        # Housekeeping metadata must not turn successful activation into rollback.
        print('Sky UI: retention metadata could not be updated.',flush=True)


def main():
    import maintenance as m
    m.require(os.geteuid()==0,'root_required')
    core_install.trusted(m.ETC/'managed-by-sky-ui')
    parser = argparse.ArgumentParser()
    parser.add_argument('--record-panel',nargs='?',const='')
    args = parser.parse_args()
    if args.record_panel is not None: return Retention(m).record_panel(args.record_panel)
    marker = m.STATE/'cleanup-intent.json'
    try:
        with open('/run/lock/sky-ui-install.lock','a') as install, (m.STATE/'worker.lock').open('a') as worker:
            fcntl.flock(install,fcntl.LOCK_EX|fcntl.LOCK_NB)
            fcntl.flock(worker,fcntl.LOCK_EX|fcntl.LOCK_NB)
            # Gate new API submissions without replacing the owner's last result.
            m.atomic(marker,b'{}',0o600)
            try: print(json.dumps(Retention(m).clean()),flush=True)
            finally: marker.unlink(missing_ok=True)
    except BlockingIOError: print('{"skipped":"busy"}',flush=True)


if __name__=='__main__': main()
