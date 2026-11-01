#!/usr/bin/env python3
"""Publish validated TLS pairs without exposing Caddy's storage to panel/core users."""
import datetime, hashlib, json, os, pwd, grp, re, ssl, stat, tempfile
from pathlib import Path
from urllib.parse import urlsplit

MAX_SIZE=262144
def safe_read(root,parts,owner):
    descriptor=os.open('/',os.O_RDONLY|os.O_DIRECTORY)
    try:
        for part in Path(root).parts[1:]+tuple(parts[:-1]):
            next_fd=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=descriptor)
            os.close(descriptor);descriptor=next_fd
        file_fd=os.open(parts[-1],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=descriptor)
        try:
            info=os.fstat(file_fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid!=owner or info.st_nlink!=1 or not 0<info.st_size<=MAX_SIZE:
                raise ValueError('Invalid certificate source ownership/type/size.')
            result=bytearray()
            while len(result)<=MAX_SIZE:
                chunk=os.read(file_fd,min(16384,MAX_SIZE+1-len(result)))
                if not chunk:break
                result.extend(chunk)
            after=os.fstat(file_fd)
            if len(result)>MAX_SIZE or after.st_size!=info.st_size or after.st_mtime_ns!=info.st_mtime_ns or after.st_nlink!=1:
                raise ValueError('Certificate changed while being read.')
            return bytes(result)
        finally:os.close(file_fd)
    finally:os.close(descriptor)

def publish(path,data,gid,mode=0o640):
    if path.exists() and not path.is_symlink() and path.read_bytes()==data:
        os.chmod(path,mode);os.chown(path,0,gid);return False
    descriptor,name=tempfile.mkstemp(prefix='.publish-',dir=path.parent)
    try:
        with os.fdopen(descriptor,'wb') as output:
            os.fchmod(output.fileno(),mode);os.fchown(output.fileno(),0,gid)
            output.write(data);output.flush();os.fsync(output.fileno())
        os.replace(name,path)
        return True
    finally:
        if os.path.exists(name):os.unlink(name)

def sync(source,destination,hosts,primary,source_uid,gid):
    destination=Path(destination)
    destination.mkdir(mode=0o750,parents=True,exist_ok=True)
    if destination.is_symlink() or destination.stat().st_uid!=0:raise ValueError('Untrusted certificate destination.')
    os.chmod(destination,0o750);os.chown(destination,0,gid)
    index={};changed=False
    for host in hosts:
        if not re.fullmatch(r'[a-z0-9][a-z0-9.-]{0,252}',host):raise ValueError('Invalid configured TLS host.')
        try:
            parts=('acme-v02.api.letsencrypt.org-directory',host)
            chain=safe_read(source,parts+(host+'.crt',),source_uid)
            key=safe_read(source,parts+(host+'.key',),source_uid)
            with tempfile.TemporaryDirectory(prefix='.validate-',dir=destination) as temporary:
                cert_path=Path(temporary)/'cert.pem';key_path=Path(temporary)/'key.pem'
                cert_path.write_bytes(chain);key_path.write_bytes(key)
                context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                context.load_cert_chain(cert_path,key_path,password=lambda:b'')
                decoded=ssl._ssl._test_decode_cert(str(cert_path))
                if not any(kind in ('DNS','IP Address') and name.lower()==host.lower() for kind,name in decoded.get('subjectAltName',())):raise ValueError('Certificate does not match the configured host.')
                expiry=ssl.cert_time_to_seconds(decoded['notAfter'])
                if expiry<=datetime.datetime.now(datetime.timezone.utc).timestamp()+60:raise ValueError('Certificate expired.')
            leaf=re.search(rb'-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----',chain)
            der=ssl.PEM_cert_to_DER_cert(leaf[0].decode('ascii'))
            metadata={'host':host,'expiresAt':datetime.datetime.fromtimestamp(expiry,datetime.timezone.utc).isoformat(),'fingerprint':hashlib.sha256(der).hexdigest()}
            for identity in [host]+(['panel'] if host==primary else []):
                target=destination/identity
                target.mkdir(mode=0o750,exist_ok=True)
                if target.is_symlink() or target.stat().st_uid!=0:raise ValueError('Untrusted certificate identity directory.')
                os.chown(target,0,gid);os.chmod(target,0o750)
                changed=publish(target/'private.key',key,gid) or changed
                changed=publish(target/'fullchain.pem',chain,gid) or changed
                index[identity]=metadata
        except (OSError,ValueError,ssl.SSLError):
            # Retain a previous valid identity during an issuer/storage transition.
            try:
                old=json.loads((destination/'index.json').read_text())
                for identity in [host]+(['panel'] if host==primary else []):
                    if identity in old:index[identity]=old[identity]
            except (OSError,ValueError):pass
    changed=publish(destination/'index.json',(json.dumps(index,sort_keys=True)+'\n').encode(),gid) or changed
    if changed:print('Updated managed TLS certificate pairs.')
    return index

def main():
    if os.geteuid()!=0:raise SystemExit('Certificate publishing requires root.')
    access=Path('/etc/sky-ui/access.conf')
    if not access.exists():return
    hosts=list(dict.fromkeys(line.strip().lower() for line in access.read_text().splitlines() if line.strip()))
    environment=dict(line.split('=',1) for line in Path('/etc/sky-ui/server.env').read_text().splitlines() if '=' in line)
    primary=urlsplit(environment.get('SKY_UI_WEB_ORIGIN','')).hostname
    sync('/var/lib/sky-ui-edge/data/caddy/certificates','/var/lib/sky-ui-certificates',hosts,primary,pwd.getpwnam('sky-ui-edge').pw_uid,grp.getgrnam('sky-ui').gr_gid)
if __name__=='__main__':main()
