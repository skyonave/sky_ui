#!/usr/bin/env python3
"""Destructive-to-test-records integration check for an otherwise empty Sky UI test VPS."""
import argparse
import contextlib
import getpass
import json
import os
import secrets
import socket
import socketserver
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--run-installed-test', action='store_true', required=True)
parser.add_argument('--external-handoff', action='store_true')
arguments = parser.parse_args()
assert os.geteuid() == 0, 'Run only on the authorized disposable test VPS.'
assert Path('/etc/sky-ui/managed-by-sky-ui').is_file()
os.umask(0o077)
environment = dict(line.split('=', 1) for line in Path('/etc/sky-ui/server.env').read_text().splitlines() if '=' in line)
origin = environment['SKY_UI_WEB_ORIGIN'].rstrip('/')
api_origin = 'http://127.0.0.1:' + environment['SKY_UI_PORT']
gateway = Path(environment['SKY_UI_GATEWAY_SECRET_FILE']).read_text().strip()
http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
owner_cookie = owner_csrf = None
tag = 'qa-' + secrets.token_hex(8)
binary = '/opt/sky-ui/cores/mihomo/current/mihomo'


def request(url, method='GET', payload=None, headers=None):
    req = urllib.request.Request(url, method=method, headers=headers or {},
        data=None if payload is None else json.dumps(payload).encode())
    if payload is not None:
        req.add_header('Content-Type', 'application/json')
    try:
        with http.open(req, timeout=90) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def api(path, method='GET', payload=None, expected=200):
    headers = {'X-Sky-UI-Gateway': gateway}
    if owner_cookie:
        headers.update({'Cookie': owner_cookie, 'X-Sky-UI-CSRF': owner_csrf})
    status, body = request(api_origin + '/api/v1/' + path, method, payload, headers)
    assert status == expected, f'API {method} {path.split("/")[0]} returned {status}, expected {expected}.'
    parsed = json.loads(body)
    return parsed.get('data', parsed)


def state():
    return api('panel')


def save(kind, value, identity=None, expected=200):
    path = kind + (('/' + identity) if identity else '')
    key = 'connection' if kind == 'connections' else 'recipient'
    return api(path, 'PUT' if identity else 'POST', {'revision': state()['revision'], key: value}, expected)


def remove(kind, identity):
    return api(kind + '/' + identity, 'DELETE', {'revision': state()['revision']})


def wait_api():
    for _ in range(60):
        try:
            return state()
        except (OSError, AssertionError):
            time.sleep(0.25)
    raise AssertionError('API did not recover.')


def read_exact(stream, size):
    data = b''
    while len(data) < size:
        chunk = stream.recv(size - len(data))
        if not chunk:
            raise OSError('Proxy stream closed.')
        data += chunk
    return data


def socks(port, command, destination):
    stream = socket.create_connection(('127.0.0.1', port), timeout=4)
    stream.settimeout(4)
    try:
        stream.sendall(b'\x05\x01\x00')
        assert read_exact(stream, 2) == b'\x05\x00'
        stream.sendall(bytes([5, command, 0, 1]) + socket.inet_aton('127.0.0.1') + destination.to_bytes(2, 'big'))
        reply = read_exact(stream, 4)
        if reply[1] != 0:
            raise OSError('Proxy rejected connection.')
        length = {1: 4, 4: 16}.get(reply[3])
        if length is None:
            length = read_exact(stream, 1)[0]
        read_exact(stream, length)
        bound_port = int.from_bytes(read_exact(stream, 2), 'big')
        return stream, bound_port
    except BaseException:
        stream.close()
        raise


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            while data := self.request.recv(4096):
                self.request.sendall(data)
        except OSError:
            pass


class UdpEcho(socketserver.BaseRequestHandler):
    def handle(self):
        data, transport = self.request
        transport.sendto(data, self.client_address)


@contextlib.contextmanager
def echo_server(udp=False, port=0):
    cls = socketserver.ThreadingUDPServer if udp else socketserver.ThreadingTCPServer
    with cls(('127.0.0.1', port), UdpEcho if udp else Echo) as server:
        server.daemon_threads = True
        thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.05), daemon=True)
        thread.start()
        try:
            yield server.server_address[1]
        finally:
            server.shutdown()


@contextlib.contextmanager
def client(profile, directory, label):
    folder = directory / label
    folder.mkdir()
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    profile = dict(profile, **{'mixed-port': port, 'bind-address': '127.0.0.1', 'allow-lan': False,
        'external-controller': '', 'dns': {'enable': False}, 'tun': {'enable': False}, 'log-level': 'error'})
    config = folder / 'profile.json'
    config.write_text(json.dumps(profile))
    subprocess.run([binary, '-t', '-d', str(folder), '-f', str(config)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with (folder / 'client.log').open('wb') as log:
        process = subprocess.Popen([binary, '-d', str(folder), '-f', str(config)], stdout=log, stderr=subprocess.STDOUT)
        try:
            for _ in range(80):
                assert process.poll() is None, 'Isolated client exited.'
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=0.1):
                        break
                except OSError:
                    time.sleep(0.05)
            else:
                raise AssertionError('Isolated client did not start.')
            yield port
        except BaseException:
            # Only sanitized diagnostics may leave the private test directory.
            import re
            text = (folder / 'client.log').read_text(errors='replace')
            text = re.sub(r'[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}', '[uuid]', text)
            print(text[-8000:], flush=True)
            raise
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def tcp_echo(port, destination):
    stream, _ = socks(port, 1, destination)
    try:
        payload = secrets.token_bytes(16)
        stream.sendall(payload)
        assert read_exact(stream, len(payload)) == payload, 'Authenticated TCP echo failed.'
    finally:
        stream.close()


def revoked(port, destination):
    try:
        tcp_echo(port, destination)
    except OSError:
        return
    raise AssertionError('Revoked credentials still passed traffic.')


def fetch_profile(url):
    status, body = request(url)
    assert status == 200, 'Anonymous bearer subscription failed.'
    result = json.loads(body)
    assert 'listeners' not in result and 'secret' not in result and 'private-key' not in body.decode()
    return result


assert request(origin + '/api/v1/panel')[0] == 401
assert request(api_origin + '/api/v1/panel')[0] == 401
owner = input('Owner username: ').strip()
password = getpass.getpass('Owner password (not stored): ')
login_request = urllib.request.Request(origin + '/api/v1/auth/login', method='POST',
    data=json.dumps({'username': owner, 'password': password}).encode(),
    headers={'Origin': origin, 'Content-Type': 'application/json'})
del password
with http.open(login_request, timeout=30) as response:
    assert response.status == 200, 'Owner sign-in failed.'
    owner_csrf = json.loads(response.read())['data']['csrf']
    owner_cookie = response.headers['Set-Cookie'].split(';', 1)[0]
del login_request
assert request(origin + '/api/v1/panel', headers={'Cookie': owner_cookie})[0] == 200
initial = state()
assert not initial['connections'] and not initial['recipients'], 'Refusing to test a nonempty installation.'
assert api('cores/primary')['controllerReady'], 'Start the managed core before this test.'
print('Owner gate and internal gateway authentication: PASS', flush=True)

try:
    with tempfile.TemporaryDirectory(prefix='sky-ui-e2e-', dir='/root/sky-ui-test') as temporary, echo_server() as target, echo_server(udp=True) as udp_target:
        directory = Path(temporary)
        connection = {'id': '', 'name': tag + '-connection', 'coreId': 'mihomo', 'instanceId': 'primary',
            'protocolId': 'vless', 'port': 8443, 'enabled': True, 'settings': {}}
        current = save('connections', connection)
        connection = current['connections'][0]
        current = save('recipients', {'id': '', 'name': tag + '-alpha', 'enabled': True, 'connectionIds': [connection['id']]})
        alpha = current['recipients'][0]
        current = save('recipients', {'id': '', 'name': tag + '-beta', 'enabled': True, 'connectionIds': [connection['id']]})
        beta = current['recipients'][1]
        first_share = api('recipients/' + alpha['id'] + '/share')
        second_share = api('recipients/' + beta['id'] + '/share')
        first_profile = fetch_profile(first_share['subscriptionUrl'])
        second_profile = fetch_profile(second_share['subscriptionUrl'])
        assert first_profile['proxies'][0]['uuid'] != second_profile['proxies'][0]['uuid']
        assert first_share['links'][0]['uri'].startswith('vless://')
        with client(first_profile, directory, 'alpha') as first, client(second_profile, directory, 'beta') as second:
            tcp_echo(first, target)
            tcp_echo(second, target)
            downloaded = subprocess.run(['curl', '--silent', '--fail', '--max-time', '15', '--noproxy', '',
                '--proxy', f'socks5h://127.0.0.1:{first}', 'https://example.com/'], capture_output=True)
            assert downloaded.returncode == 0 and b'Example Domain' in downloaded.stdout, 'HTTPS traffic through the exported profile failed.'
            print('Distinct users, exported mihomo profiles and real HTTPS/TCP traffic: PASS', flush=True)
            stream, _ = socks(first, 1, target)
            stream.sendall(b'live')
            assert read_exact(stream, 4) == b'live'
            udp_control, relay = socks(first, 3, 0)
            with udp_control, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                udp.bind(('127.0.0.1', 0))
                udp.settimeout(4)
                packet = b'\x00\x00\x00\x01' + socket.inet_aton('127.0.0.1') + udp_target.to_bytes(2, 'big')
                nonce = secrets.token_bytes(16)
                udp.sendto(packet + nonce, ('127.0.0.1', relay))
                assert udp.recv(4096).endswith(nonce), 'UDP/XUDP echo failed.'
                print('UDP/XUDP traffic through the exported profile: PASS', flush=True)
                if arguments.external_handoff:
                    (directory / 'external-profile.json').write_text(json.dumps(first_profile))
                    (directory / 'external-targets.json').write_text(json.dumps({'tcp': target, 'udp': udp_target}))
                    print('External client files: ' + str(directory), flush=True)
                    input('Press Enter after the external client check: ')
                    stream.close()
                    stream, _ = socks(first, 1, target)
                    stream.sendall(b'live')
                    assert read_exact(stream, 4) == b'live', 'Access did not survive external/update checks.'
                save('recipients', dict(alpha, enabled=False), alpha['id'])
                assert request(first_share['subscriptionUrl'])[0] == 404
                try:
                    stream.sendall(b'dead')
                    assert stream.recv(4) != b'dead', 'Existing session survived revocation.'
                except OSError:
                    pass
                finally:
                    stream.close()
                revoked(first, target)
                tcp_echo(second, target)
                print('Recipient revocation rejects old profile and closes an existing TCP session; other user works: PASS', flush=True)
            save('recipients', alpha, alpha['id'])
            tcp_echo(first, target)
            save('connections', dict(connection, enabled=False), connection['id'])
            assert request(first_share['subscriptionUrl'])[0] == 404
            revoked(first, target)
            save('connections', connection, connection['id'])
            tcp_echo(first, target)
            restricted = subprocess.run(['curl', '--silent', '--max-time', '10', '--noproxy', '', '--proxy',
                f'socks5h://127.0.0.1:{first}', '-o', '/dev/null', '-w', '%{http_code}', api_origin + '/api/v1/panel'], capture_output=True)
            assert restricted.returncode == 0 and restricted.stdout == b'401', 'A VPN recipient could reach the owner API.'
            print('Enable/disable works; a VPN recipient cannot access the owner API through the tunnel: PASS', flush=True)
            old_revision = state()['revision']
            subprocess.run(['systemctl', 'restart', 'sky-ui.service'], check=True)
            restored = wait_api()
            assert restored['revision'] == old_revision and len(restored['recipients']) == 2
            tcp_echo(first, target)
            fetch_profile(first_share['subscriptionUrl'])
            remove('recipients', alpha['id'])
            assert request(first_share['subscriptionUrl'])[0] == 404
            revoked(first, target)
            tcp_echo(second, target)
            print('API restart preserves access; deleting a recipient permanently rejects their old profile: PASS', flush=True)
        no_vision = dict(connection, settings=dict(connection['settings'], flow='None'))
        save('connections', no_vision, connection['id'])
        with client(fetch_profile(second_share['subscriptionUrl']), directory, 'without-vision') as plain:
            tcp_echo(plain, target)
        save('connections', connection, connection['id'])
        print('TCP + REALITY with and without Vision: PASS', flush=True)
        # Low ports skip an unprivileged bind preflight. Prove a foreign listener cannot pass activation.
        with echo_server(port=895):
            occupied = dict(connection, id='', name=tag + '-occupied', port=895, settings=dict(connection['settings'], listen='0.0.0.0'))
            current = save('connections', occupied)
            occupied = next(c for c in current['connections'] if c['name'] == tag + '-occupied')
            revision = state()['revision']
            result = save('recipients', {'id': '', 'name': tag + '-rejected', 'enabled': True, 'connectionIds': [occupied['id']]}, expected=503)
            assert state()['revision'] == revision and state()['deliveryReady'], 'Failed activation did not roll back.'
            remove('connections', occupied['id'])
        print('Foreign occupied port rejected and last working configuration restored: PASS', flush=True)
finally:
    wait_api()
    for kind in ['recipients', 'connections']:
        for record in state()[kind]:
            if record['name'].startswith(tag + '-'):
                remove(kind, record['id'])
    final = state()
    assert not final['connections'] and not final['recipients'], 'Test records were not cleaned up.'
    assert final['synchronized'] and api('cores/primary')['controllerReady']
    print('Temporary credentials removed; empty managed configuration and running core restored: PASS', flush=True)
