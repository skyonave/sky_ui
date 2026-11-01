#!/usr/bin/env python3
"""Exercise AWG 3.1, cached-profile revocation and cleanup in a private network."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import threading
import time

from protocol_traffic import free_port, read_exact


def command(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('fixture')
    parser.add_argument('--inside', action='store_true')
    args = parser.parse_args()
    root = Path(args.fixture).resolve()
    assert 'protocol-first' in str(root) and os.geteuid() == 0
    os.umask(0o077)
    if not args.inside:
        subprocess.run(['unshare', '--mount', '--net', '--fork', '/usr/bin/python3', str(Path(__file__).resolve()), str(root), '--inside'], check=True)
        return
    # These mounts and network changes are confined to this process namespace.
    command('mount', '--make-rprivate', '/')
    command('mount', '-t', 'tmpfs', 'tmpfs', '/run')
    command('mount', '-t', 'tmpfs', 'tmpfs', '/var/lib')
    command('mount', '-t', 'sysfs', 'sysfs', '/sys')
    Path('/run/amneziawg').mkdir(mode=0o700)
    command('ip', 'link', 'set', 'lo', 'up')
    item = next(x for x in json.loads((root/'fixtures.json').read_text()) if x['engine'] == 'amneziawg')
    original = json.loads(Path(item['server']).read_text())
    client = json.loads(Path(item['client']).read_text())
    port, socks, http_port = free_port(), free_port(), free_port()
    original['interfaces'][0]['port'] = port
    client['mixed-port'] = socks
    client['bind-address'] = '127.0.0.1'
    client['proxies'][0]['port'] = port
    private = root / 'awg-namespace'
    private.mkdir(mode=0o700, exist_ok=True)
    config = private/'config.json'
    profile = private/'client.json'
    profile.write_text(json.dumps(client))
    marker = secrets.token_bytes(24)
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header('Content-Length', str(len(marker)))
            self.end_headers()
            self.wfile.write(marker)
        def log_message(self, *_): pass
    helper = Path(__file__).resolve().parents[1]/'deploy/amnezia_network.py'
    children, streams = [], []
    def launch(argv, name):
        stream = (private/(name+'.log')).open('wb'); streams.append(stream)
        process = subprocess.Popen(argv, stdout=stream, stderr=subprocess.STDOUT)
        children.append(process)
        return process
    def stop(process):
        process.terminate()
        try: process.wait(timeout=12)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
        assert process.returncode == 0, 'fixture process did not stop cleanly: ' + str(process.returncode)
    def start_server(value):
        config.write_text(json.dumps(value))
        process = launch(['python3', str(helper), 'run', str(config), str(root/'amneziawg')], 'server')
        for _ in range(100):
            assert process.poll() is None
            if (private/'server.log').read_text().find('3.1 ready') >= 0: return process
            time.sleep(.1)
        raise RuntimeError('AWG startup timeout')
    def start_client():
        process = launch([str(root/'mihomo'), '-f', str(profile), '-d', str(private)], 'client')
        for _ in range(100):
            assert process.poll() is None
            try:
                with socket.create_connection(('127.0.0.1', socks), timeout=.1): return process
            except OSError: time.sleep(.1)
        raise RuntimeError('AWG client startup timeout')
    address = original['interfaces'][0]['address'].split('/')[0]
    def fetch():
        with socket.create_connection(('127.0.0.1', socks), timeout=3) as stream:
            stream.settimeout(5)
            stream.sendall(b'\x05\x01\x00'); assert read_exact(stream, 2) == b'\x05\x00'
            stream.sendall(b'\x05\x01\x00\x01' + socket.inet_aton(address) + http_port.to_bytes(2,'big'))
            head = read_exact(stream, 4); assert head[1] == 0
            read_exact(stream, 6 if head[3] == 1 else 18)
            stream.sendall(b'GET / HTTP/1.1\r\nHost: fixture\r\nConnection: close\r\n\r\n')
            data = b''
            while True:
                chunk = stream.recv(4096)
                if not chunk: break
                data += chunk
                if data.endswith(marker): return True
            return False
    server = None
    http = None
    try:
        server = start_server(original)
        http = ThreadingHTTPServer((address, http_port), Handler)
        threading.Thread(target=http.serve_forever, daemon=True).start()
        peer = start_client()
        assert fetch()
        stop(peer); stop(server)
        revoked = json.loads(json.dumps(original)); revoked['interfaces'][0]['peers'] = []
        server = start_server(revoked)
        peer = start_client()
        try: delivered = fetch()
        except (OSError, AssertionError): delivered = False
        assert not delivered
        stop(peer); stop(server)
        server = start_server(original)
        peer = start_client()
        assert fetch()
        stop(peer); stop(server)
        assert not Path('/sys/class/net', original['interfaces'][0]['name']).exists()
        assert subprocess.run(['nft','list','table','ip','sky_ui_awg'], capture_output=True).returncode != 0
        (root/'awg-results.json').write_text(json.dumps({'traffic': True, 'revocation': True, 'regrant': True, 'cleanup': True}))
        print('AWG 3.1: traffic, revocation, regrant and cleanup passed.', flush=True)
    finally:
        for process in children:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=12)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
        for stream in streams: stream.close()
        if http: http.shutdown()


if __name__ == '__main__': main()
