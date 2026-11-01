#!/usr/bin/env python3
"""Loopback data-path checks for product protocols across real engine processes."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import socket
import ssl
import subprocess
import threading
import time
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from protocol_traffic import read_exact, free_port


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('fixture')
    parser.add_argument('--only-failed', action='store_true')
    args = parser.parse_args()
    root = Path(args.fixture).resolve()
    assert 'protocol-first' in str(root)
    os.umask(0o077)
    marker = secrets.token_bytes(20)
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200); self.send_header('Content-Length', str(len(marker))); self.end_headers(); self.wfile.write(marker)
        def log_message(self, *_): pass
    echo = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    handshake = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(root / 'cert.pem', root / 'key.pem'); tls.set_alpn_protocols(['h2', 'http/1.1'])
    handshake.socket = tls.wrap_socket(handshake.socket, server_side=True)
    # Use a native TLS target for deterministic REALITY interoperability checks.
    handshake_port = free_port()
    handshake_config = root / 'handshake-target.json'
    handshake_config.write_text(json.dumps({'inbounds': [{'type': 'http', 'listen': '127.0.0.1', 'listen_port': handshake_port, 'tls': {'enabled': True, 'certificate_path': str(root/'cert.pem'), 'key_path': str(root/'key.pem'), 'alpn': ['h2','http/1.1']}}]}))
    handshake_log = (root/'handshake-target.log').open('wb')
    native_handshake = subprocess.Popen([str(root/'sing-box'), 'run', '-c', str(handshake_config)], stdout=handshake_log, stderr=subprocess.STDOUT)
    time.sleep(.5)
    assert native_handshake.poll() is None
    for server in (echo, handshake): threading.Thread(target=server.serve_forever, daemon=True).start()
    result_path = root / 'traffic-results.json'
    results = json.loads(result_path.read_text()) if args.only_failed and result_path.exists() else []
    passed = {r['id'] for r in results if r['passed']}
    results = [r for r in results if r['passed']]
    fixtures = json.loads((root / 'fixtures.json').read_text())
    for fixture in fixtures:
        if fixture['engine'] == 'amneziawg': continue
        if fixture['id'] in passed: continue
        processes, streams = [], []
        stage = 'start'
        try:
            server = json.loads(Path(fixture['server']).read_text())
            client = json.loads(Path(fixture['client']).read_text())
            engine = fixture['engine']
            inbounds = server['listeners'] if engine == 'mihomo' else server['inbounds']
            if engine == 'xray':
                server['log'] = {'loglevel': 'debug'}
                # Recent Xray versions block private destinations by default.
                # Permit only this loopback fixture; production retains that default.
                server['outbounds'][0]['settings'] = {'finalRules': [{'action': 'allow', 'ip': ['127.0.0.0/8']}]}
            port, socks = free_port(), free_port()
            for inbound in inbounds:
                assert inbound.get('listen') == '127.0.0.1'
                inbound['listen_port' if engine == 'sing-box' else 'port'] = port
                stream = inbound.get('streamSettings', {})
                if stream.get('security') == 'reality':
                    stream['realitySettings']['target'] = '127.0.0.1:' + str(handshake_port)
                if inbound.get('tls', {}).get('reality', {}).get('enabled'):
                    inbound['tls']['reality']['handshake'] = {'server': 'localhost', 'server_port': handshake.server_port}
            if fixture['clientEngine'] == 'sing-box':
                client['inbounds'][0]['listen_port'] = socks
                client['outbounds'][0]['server_port'] = port
            else:
                client['mixed-port'] = socks
                for proxy in client['proxies']:
                    proxy['port'] = port
            for role, configuration, selected in [('server', server, engine), ('client', client, fixture['clientEngine'])]:
                home = root / (fixture['id'] + '-' + role)
                home.mkdir(mode=0o700, exist_ok=True)
                path = root / (fixture['id'] + '-' + role + '.active.json'); path.write_text(json.dumps(configuration))
                binary = root / selected
                args = [str(binary), '-f', str(path), '-d', str(home)] if selected == 'mihomo' else (
                    [str(binary), 'run', '-config', str(path)] if selected == 'xray' else [str(binary), 'run', '-c', str(path)])
                stream = (root / (fixture['id'] + '-' + role + '.log')).open('wb'); streams.append(stream)
                processes.append(subprocess.Popen(args, stdout=stream, stderr=subprocess.STDOUT, cwd=root))
            time.sleep(.3)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if any(p.poll() is not None for p in processes): raise RuntimeError('process_exited')
                try:
                    with socket.create_connection(('127.0.0.1', socks), timeout=.2): break
                except OSError: time.sleep(.1)
            with socket.create_connection(('127.0.0.1', socks), timeout=5) as connection:
                connection.settimeout(10)
                stage = 'socks greeting'
                connection.sendall(b'\x05\x01\x00'); assert read_exact(connection, 2) == b'\x05\x00'
                stage = 'socks connect'
                connection.sendall(b'\x05\x01\x00\x01\x7f\x00\x00\x01' + echo.server_port.to_bytes(2, 'big'))
                header = read_exact(connection, 4); assert header[1] == 0
                if header[3] == 1: read_exact(connection, 6)
                elif header[3] == 4: read_exact(connection, 18)
                else: read_exact(connection, read_exact(connection, 1)[0] + 2)
                stage = 'http body'
                connection.sendall(b'GET / HTTP/1.1\r\nHost: fixture\r\nConnection: close\r\n\r\n')
                response = b''
                while True:
                    chunk = connection.recv(4096)
                    if not chunk: break
                    response += chunk
                    if b'\r\n\r\n' in response and response.split(b'\r\n\r\n', 1)[1] == marker: break
                assert response.endswith(marker)
            result = {'id': fixture['id'], 'passed': True}
        except Exception as error:
            time.sleep(.2)
            result = {'id': fixture['id'], 'passed': False, 'error': type(error).__name__, 'stage': stage}
        finally:
            for child in processes: child.terminate()
            for child in processes:
                try: child.wait(timeout=3)
                except subprocess.TimeoutExpired: child.kill(); child.wait()
            for stream in streams: stream.close()
        results.append(result); result_path.write_text(json.dumps(results, indent=2))
        print(json.dumps(result), flush=True)
    echo.shutdown(); handshake.shutdown()
    native_handshake.terminate(); native_handshake.wait(timeout=5); handshake_log.close()
    raise SystemExit(0 if all(r['passed'] for r in results) else 1)


if __name__ == '__main__': main()
