#!/usr/bin/env python3
"""Exercise certificate publishing and native TLS reload using private loopback fixtures."""
import argparse,hashlib,http.client,importlib.util,json,os,secrets,socket,ssl,subprocess,tempfile,threading,time
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer

SPEC=importlib.util.spec_from_file_location('certificate_sync',Path(__file__).resolve().parents[1]/'deploy/certificate_sync.py')
publisher=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(publisher)
def run(*args):subprocess.run(args,check=True,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
def free_port():
    with socket.socket() as candidate:candidate.bind(('127.0.0.1',0));return candidate.getsockname()[1]
def main():
    parser=argparse.ArgumentParser();parser.add_argument('binary');args=parser.parse_args()
    if os.name!='posix' or os.geteuid()!=0:raise SystemExit('Run isolated certificate publisher checks as Linux root.')
    processes=[];handles=[];echo=None
    with tempfile.TemporaryDirectory(prefix='sky-ui-private-certificate-reload-') as temporary:
        root=Path(temporary);source=root/'source';destination=root/'published';home=root/'core';home.mkdir()
        host='fixture.example.test';issuer=source/'acme-v02.api.letsencrypt.org-directory'/host;issuer.mkdir(parents=True)
        ca=root/'ca.pem';ca_key=root/'ca.key'
        run('openssl','req','-x509','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes','-days','2','-subj','/CN=Isolated Sky UI Fixture CA','-addext','basicConstraints=critical,CA:TRUE','-keyout',str(ca_key),'-out',str(ca))
        extensions=root/'leaf-extensions.cnf';extensions.write_text('subjectAltName=DNS:'+host+'\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n')
        def issue():
            key=issuer/(host+'.key');cert=issuer/(host+'.crt');csr=root/'leaf.csr'
            run('openssl','req','-new','-newkey','ec','-pkeyopt','ec_paramgen_curve:P-256','-nodes','-subj','/CN='+host,'-keyout',str(key),'-out',str(csr))
            run('openssl','x509','-req','-in',str(csr),'-CA',str(ca),'-CAkey',str(ca_key),'-CAcreateserial','-days','1','-extfile',str(extensions),'-out',str(cert))
            return publisher.sync(source,destination,[host],host,0,0)['panel']['fingerprint']
        first=issue();server_port=free_port();client_port=free_port()
        marker=('private-renewal-'+secrets.token_hex(16)).encode()
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200);self.send_header('Content-Length',str(len(marker)));self.end_headers();self.wfile.write(marker)
            def log_message(self,*_):pass
        echo=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=echo.serve_forever,daemon=True).start()
        uuid='00000000-0000-4000-8000-000000000123'
        server={'mode':'rule','log-level':'silent','rules':['MATCH,DIRECT'],'listeners':[{'name':'sky-ui/certificate-fixture','type':'vless','listen':'127.0.0.1','port':server_port,'users':[{'username':'fixture','uuid':uuid}],'certificate':str(destination/'panel/fullchain.pem'),'private-key':str(destination/'panel/private.key')}]}
        client={'mixed-port':client_port,'allow-lan':False,'mode':'rule','log-level':'silent','tls':{'custom-certifactes':[ca.read_text()]},'proxies':[{'name':'fixture','type':'vless','server':'127.0.0.1','port':server_port,'uuid':uuid,'tls':True,'servername':host,'client-fingerprint':'chrome'}],'proxy-groups':[{'name':'Fixture select','type':'select','proxies':['fixture']}],'rules':['MATCH,Fixture select']}
        try:
            for name,config in [('server',server),('client',client)]:
                directory=home/name;directory.mkdir();path=directory/'fixture.json';path.write_text(json.dumps(config))
                handle=(directory/'native.log').open('wb');handles.append(handle)
                environment=dict(os.environ,SAFE_PATHS=str(destination))
                processes.append(subprocess.Popen([str(Path(args.binary).resolve()),'-d',str(directory),'-f',str(path)],stdout=handle,stderr=subprocess.STDOUT,env=environment))
            context=ssl.create_default_context(cafile=ca)
            def observed():
                with socket.create_connection(('127.0.0.1',server_port),timeout=2) as connection:
                    with context.wrap_socket(connection,server_hostname=host) as tls:return hashlib.sha256(tls.getpeercert(binary_form=True)).hexdigest()
            def wait_for(expected):
                deadline=time.monotonic()+15
                while time.monotonic()<deadline:
                    if any(process.poll() is not None for process in processes):raise RuntimeError('Native certificate fixture exited.')
                    try:
                        if observed()==expected:return
                    except (OSError,ssl.SSLError):pass
                    time.sleep(.1)
                raise RuntimeError('Native TLS certificate did not reach the expected fingerprint.')
            def transfer():
                connection=http.client.HTTPConnection('127.0.0.1',client_port,timeout=5)
                try:
                    connection.request('GET','http://127.0.0.1:'+str(echo.server_port)+'/fixture')
                    response=connection.getresponse()
                    if response.status!=200 or response.read()!=marker:raise RuntimeError('Authenticated TLS profile failed after certificate publishing.')
                finally:connection.close()
            wait_for(first);transfer();pid=processes[0].pid
            second=issue()
            if second==first:raise RuntimeError('Renewal fixture did not change the certificate.')
            wait_for(second);transfer()
            if processes[0].pid!=pid or processes[0].poll() is not None:raise RuntimeError('Native core restarted during certificate renewal.')
            print('PASS: renewed TLS pair served by the same core PID; unchanged client profile transfers data.')
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try:process.wait(timeout=4)
                    except subprocess.TimeoutExpired:process.kill();process.wait(timeout=4)
            for handle in handles:handle.close()
            if echo is not None:echo.shutdown();echo.server_close()
if __name__=='__main__':main()
