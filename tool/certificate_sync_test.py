#!/usr/bin/env python3
"""Linux security and renewal tests for the private TLS certificate publisher."""
import hashlib,importlib.util,os,ssl,stat,subprocess,tempfile,unittest
from pathlib import Path

SPEC=importlib.util.spec_from_file_location('certificate_sync',Path(__file__).resolve().parents[1]/'deploy/certificate_sync.py')
sync=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(sync)
@unittest.skipUnless(os.name=='posix' and os.geteuid()==0,'Requires isolated Linux root fixtures.')
class CertificatePublisherTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix='sky-ui-certificates-test-')
        self.root=Path(self.temporary.name);self.source=self.root/'source';self.source.mkdir()
    def tearDown(self):self.temporary.cleanup()
    def test_file_and_parent_symlinks_are_rejected(self):
        secret=self.root/'private-fixture';secret.write_bytes(b'private-fixture-only')
        (self.source/'leaf').symlink_to(secret)
        with self.assertRaises(OSError):sync.safe_read(self.source,('leaf',),0)
        (self.source/'parent').symlink_to(self.root,target_is_directory=True)
        with self.assertRaises(OSError):sync.safe_read(self.source,('parent','private-fixture'),0)
    def test_hard_links_foreign_owners_and_fifos_are_rejected(self):
        plain=self.source/'plain';plain.write_bytes(b'fixture')
        os.link(plain,self.source/'hard-link')
        with self.assertRaises(ValueError):sync.safe_read(self.source,('hard-link',),0)
        (self.source/'hard-link').unlink();os.chown(plain,65534,65534)
        with self.assertRaises(ValueError):sync.safe_read(self.source,('plain',),0)
        os.mkfifo(self.source/'pipe')
        with self.assertRaises(ValueError):sync.safe_read(self.source,('pipe',),0)
    def certificate(self,host):
        issuer=self.source/'acme-v02.api.letsencrypt.org-directory'/host;issuer.mkdir(parents=True,exist_ok=True)
        cert=issuer/(host+'.crt');key=issuer/(host+'.key')
        subprocess.run(['openssl','req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes','-days','1','-subj','/CN='+host,'-addext','subjectAltName=DNS:'+host,'-keyout',str(key),'-out',str(cert)],check=True,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        return cert,key
    def test_renewal_updates_alias_and_retains_last_valid_pair_on_corruption(self):
        host='fixture.example.test';certificate,key=self.certificate(host);destination=self.root/'published'
        def publish():return sync.sync(self.source,destination,[host],host,0,0)
        initial=publish();pair=[(destination/'panel'/name).read_bytes() for name in ['fullchain.pem','private.key']]
        before=(destination/'panel/private.key').stat().st_mtime_ns
        self.assertEqual(publish(),initial);self.assertEqual((destination/'panel/private.key').stat().st_mtime_ns,before)
        self.assertEqual(initial['panel']['host'],host)
        self.assertEqual(stat.S_IMODE((destination/'panel/private.key').stat().st_mode),0o640)
        key.write_bytes(b'invalid fixture key')
        self.assertEqual(publish(),initial)
        self.assertEqual(pair,[(destination/'panel'/name).read_bytes() for name in ['fullchain.pem','private.key']])
        self.certificate(host);renewed=publish()
        self.assertNotEqual(renewed['panel']['fingerprint'],initial['panel']['fingerprint'])
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(destination/'panel/fullchain.pem',destination/'panel/private.key')
        self.assertEqual(renewed['panel'],renewed[host])
if __name__=='__main__':unittest.main()
