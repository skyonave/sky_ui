#!/usr/bin/env python3
"""Loopback-only data-path checks against generated, isolated protocol fixtures."""
import argparse,base64,hashlib,json,os,re,secrets,socket,ssl,subprocess,threading,time,uuid
from pathlib import Path
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer

def read_exact(stream,count):
    result=b''
    while len(result)<count:
        chunk=stream.recv(count-len(result))
        if not chunk:raise OSError('Unexpected socket EOF.')
        result+=chunk
    return result
def free_port(exclude=()):
    for _ in range(100):
        port=20000+secrets.randbelow(28000)
        if port in exclude:continue
        try:
            with socket.socket() as tcp,socket.socket(type=socket.SOCK_DGRAM) as udp:
                tcp.bind(('127.0.0.1',port));udp.bind(('127.0.0.1',port));return port
        except OSError:pass
    raise OSError('No free TCP/UDP fixture port.')
def main():
    parser=argparse.ArgumentParser();parser.add_argument('binary');parser.add_argument('fixture_directory');parser.add_argument('--only-failed',action='store_true');parser.add_argument('--client-binary');parser.add_argument('--udp',action='store_true');parser.add_argument('--auth',action='store_true');args=parser.parse_args()
    root=Path(args.fixture_directory).resolve()
    if 'protocol-matrix' not in str(root):raise SystemExit('Use the dedicated protocol-matrix fixture directory.')
    marker=('sky-ui-fixture-'+secrets.token_hex(16)).encode()
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            body=marker if self.server is echo else b'isolated-tls-upstream-only'
            self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        def log_message(self,*_):pass
    class FixtureHTTPServer(ThreadingHTTPServer):
        def handle_error(self,*_):pass
    echo=FixtureHTTPServer(('127.0.0.1',0),Handler)
    tls_echo=FixtureHTTPServer(('127.0.0.1',0),Handler)
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.minimum_version=ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(root/'cert.pem',root/'key.pem');context.set_alpn_protocols(['h2','http/1.1'])
    tls_echo.socket=context.wrap_socket(tls_echo.socket,server_side=True)
    for server in [echo,tls_echo]:threading.Thread(target=server.serve_forever,daemon=True).start()
    udp_echo=socket.socket(type=socket.SOCK_DGRAM);udp_echo.bind(('127.0.0.1',0));udp_echo.settimeout(.2)
    stop_udp=threading.Event()
    def echo_datagrams():
        while not stop_udp.is_set():
            try:
                payload,address=udp_echo.recvfrom(65535);udp_echo.sendto(payload,address)
            except socket.timeout:pass
            except OSError:return
    threading.Thread(target=echo_datagrams,daemon=True).start()
    previous=json.loads((root/'traffic-summary.json').read_text()) if args.only_failed and (root/'traffic-summary.json').exists() else []
    results=[result for result in previous if result.get('tcp')]
    passed={result['protocol'] for result in results}
    pin=hashlib.sha256(ssl.PEM_cert_to_DER_cert((root/'cert.pem').read_text())).hexdigest()
    for entry in json.loads((root/'summary.json').read_text()):
        if not entry.get('client'):continue
        protocol=entry.get('id',entry['protocol']);processes=[];files=[]
        if args.only_failed and protocol in passed:continue
        try:
            server=json.loads((root/(protocol+'-server.json')).read_text())
            server_port=free_port()
            allowed={'vless','vmess','trojan','shadowsocks','snell','mieru','sudoku','trusttunnel','tuic','hysteria2','shadowquic','anytls','http','socks','mixed'}
            if any(listener['type'] not in allowed or listener['listen']!='127.0.0.1' for listener in server['listeners']):raise ValueError('Fixture listener is not loopback-safe.')
            for listener in server['listeners']:
                listener['port']=server_port
                if listener.get('reality-config',{}).get('dest'):listener['reality-config']['dest']='localhost:'+str(tls_echo.server_port)
            client=json.loads((root/(protocol+'-client.json')).read_text());proxy_port=free_port({server_port})
            for proxy in client['proxies']:proxy['port']=server_port
            client['mixed-port']=proxy_port;client['bind-address']='127.0.0.1'
            client['log-level']='debug';server['log-level']='debug'
            client['tls']={'custom-certifactes':[(root/'cert.pem').read_text()]}
            for listener in server['listeners']:
                for field in ['jls-config','res-tls','tlsmirror-config']:
                    if listener.get(field,{}).get('enable'):listener[field]['dest']='localhost:'+str(tls_echo.server_port)
                if listener.get('tlsmirror-config',{}).get('primary-key'):listener['tlsmirror-config']['dest']='localhost:'+str(tls_echo.server_port)
                if listener.get('shadow-tls',{}).get('enable'):listener['shadow-tls']['handshake']={'dest':'localhost:'+str(tls_echo.server_port)}
            for proxy in client['proxies']:
                if 'restls-opts' in proxy:proxy['fingerprint']=pin
                if proxy.get('plugin')=='restls':proxy['plugin-opts']['fingerprint']=pin
                if proxy.get('obfs-opts',{}).get('mode')=='restls':proxy['obfs-opts']['fingerprint']=pin
            for label,configuration in [('live-server',server),('live-client',client)]:
                home=root/(protocol+'-'+label);home.mkdir(exist_ok=True)
                path=home/'fixture.json';path.write_text(json.dumps(configuration))
                log=(home/'native.log').open('wb');files.append(log)
                binary=args.client_binary if label=='live-client' and args.client_binary else args.binary
                processes.append(subprocess.Popen([str(Path(binary).resolve()),'-d',str(home),'-f',str(path)],stdout=log,stderr=subprocess.STDOUT,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0)))
                time.sleep(.35)
            deadline=time.monotonic()+12;success=False;last='No response.'
            while time.monotonic()<deadline and not success:
                if any(process.poll() is not None for process in processes):raise OSError('Native fixture process exited; see its log.')
                try:
                    with socket.create_connection(('127.0.0.1',proxy_port),timeout=2) as connection:
                        connection.settimeout(4);connection.sendall(b'\x05\x01\x00')
                        if read_exact(connection,2)!=b'\x05\x00':raise OSError('Local SOCKS greeting failed.')
                        connection.sendall(b'\x05\x01\x00\x01\x7f\x00\x00\x01'+echo.server_port.to_bytes(2,'big'))
                        header=read_exact(connection,4)
                        if header[1]!=0:raise OSError('SOCKS target connection rejected.')
                        read_exact(connection,4 if header[3]==1 else 16);read_exact(connection,2)
                        connection.sendall(b'GET /fixture HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
                        body=b''
                        while marker not in body:
                            chunk=connection.recv(4096)
                            if not chunk:break
                            body+=chunk
                        if marker not in body:raise OSError('Authenticated data path returned no fixture marker.')
                        success=True
                except OSError as error:last=str(error);time.sleep(.2)
            if not success:raise OSError(last)
            server_log=root/(protocol+'-live-server')/'native.log'
            target='127.0.0.1:'+str(echo.server_port)
            if not any('[TCP]' in line and target in line for line in server_log.read_text(errors='replace').splitlines()):raise OSError('TCP bypassed the intended native server.')
            result={'protocol':protocol,'tcp':True}
            print(protocol+': TCP PASS',flush=True)
            if args.udp and client['proxies'][0].get('type')!='http' and client['proxies'][0].get('udp',True):
                payload=marker+protocol.encode()
                with socket.create_connection(('127.0.0.1',proxy_port),timeout=3) as association:
                    association.settimeout(3);association.sendall(b'\x05\x01\x00')
                    if read_exact(association,2)!=b'\x05\x00':raise OSError('UDP greeting failed.')
                    association.sendall(b'\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00')
                    header=read_exact(association,4)
                    if header[1]!=0:raise OSError('UDP association rejected.')
                    address=socket.inet_ntop(socket.AF_INET if header[3]==1 else socket.AF_INET6,read_exact(association,4 if header[3]==1 else 16))
                    port=int.from_bytes(read_exact(association,2),'big')
                    if address in ('0.0.0.0','::'):address='127.0.0.1'
                    with socket.socket(type=socket.SOCK_DGRAM) as datagram:
                        datagram.settimeout(3);received=False
                        packet=b'\x00\x00\x00\x01\x7f\x00\x00\x01'+udp_echo.getsockname()[1].to_bytes(2,'big')+payload
                        for _ in range(3):
                            datagram.sendto(packet,(address,port))
                            try:
                                response,_=datagram.recvfrom(65535)
                                if response.endswith(payload):received=True;break
                            except socket.timeout:pass
                    if not received:raise OSError('Native UDP data path returned no fixture marker.')
                udp_target='127.0.0.1:'+str(udp_echo.getsockname()[1])
                if not any('[UDP]' in line and udp_target in line for line in server_log.read_text(errors='replace').splitlines()):raise OSError('UDP bypassed the intended native server.')
                result['udp']=True;print(protocol+': UDP PASS',flush=True)
            if args.auth and '--' not in protocol:
                accepted=processes.pop();accepted.terminate()
                try:accepted.wait(timeout=4)
                except subprocess.TimeoutExpired:accepted.kill();accepted.wait(timeout=4)
                rejected=json.loads(json.dumps(client));proxy=rejected['proxies'][0]
                if 'uuid' in proxy:proxy['uuid']=str(uuid.uuid4())
                elif 'username' in proxy:proxy['username']='rejected-fixture-only'
                elif 'psk' in proxy:proxy['psk']='rejected-fixture-only'
                elif 'token' in proxy:proxy['token']='rejected-fixture-only'
                elif 'password' in proxy:
                    proxy['password']=base64.b64encode(secrets.token_bytes(len(base64.b64decode(proxy['password'])))).decode() if str(proxy.get('cipher','')).startswith('2022-') else 'rejected-fixture-only'
                elif 'key' in proxy:
                    generated=subprocess.run([str(Path(args.binary).resolve()),'generate','sudoku-keypair'],capture_output=True,text=True,check=True,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
                    proxy['key']=re.search(r'^PrivateKey:\s*(\S+)',generated.stdout,re.M)[1]
                else:raise ValueError('No credential mutation defined for the profile.')
                rejected_home=root/(protocol+'-rejected-client');rejected_home.mkdir(exist_ok=True)
                rejected_path=rejected_home/'fixture.json';rejected_path.write_text(json.dumps(rejected))
                log=(rejected_home/'native.log').open('wb');files.append(log)
                binary=args.client_binary or args.binary
                processes.append(subprocess.Popen([str(Path(binary).resolve()),'-d',str(rejected_home),'-f',str(rejected_path)],stdout=log,stderr=subprocess.STDOUT,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0)))
                time.sleep(.5);allowed=False
                with socket.create_connection(('127.0.0.1',proxy_port),timeout=2) as connection:
                    connection.settimeout(3);connection.sendall(b'\x05\x01\x00');read_exact(connection,2)
                    try:
                        connection.sendall(b'\x05\x01\x00\x01\x7f\x00\x00\x01'+echo.server_port.to_bytes(2,'big'))
                        header=read_exact(connection,4)
                        if header[1]==0:
                            read_exact(connection,4 if header[3]==1 else 16);read_exact(connection,2)
                            connection.sendall(b'GET /fixture HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
                            allowed=marker in connection.recv(4096)
                    except OSError:pass
                if allowed:raise OSError('Incorrect credentials reached the private target.')
                result['rejectsWrongCredentials']=True;print(protocol+': wrong credentials REJECTED',flush=True)
            results.append(result)
        except (OSError,ValueError) as error:
            results.append({'protocol':protocol,'tcp':False,'error':str(error)});print(protocol+': TCP FAIL '+str(error),flush=True)
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try:process.wait(timeout=4)
                    except subprocess.TimeoutExpired:process.kill();process.wait(timeout=4)
            for file in files:file.close()
    stop_udp.set();udp_echo.close();echo.shutdown();tls_echo.shutdown()
    (root/'traffic-summary.json').write_text(json.dumps(results,indent=2))
    if any(not result['tcp'] or result.get('udp') is False for result in results):raise SystemExit(1)
if __name__=='__main__':main()
