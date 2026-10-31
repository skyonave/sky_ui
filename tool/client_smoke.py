#!/usr/bin/env python3
"""Check an ephemeral recipient profile using an isolated installed mihomo binary."""
import argparse
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', required=True)
parser.add_argument('--profile', required=True)
parser.add_argument('--targets', required=True)
args = parser.parse_args()
workspace = Path(__file__).resolve().parent.parent
runtime = (workspace / 'runtime').resolve()
assert runtime.is_relative_to(workspace), 'Unsafe runtime directory.'
runtime.mkdir(exist_ok=True)
os.umask(0o077)
profile = json.loads(Path(args.profile).read_text())
targets = json.loads(Path(args.targets).read_text())
assert len(profile['proxies']) == 1
version = subprocess.run([args.binary, '-v'], capture_output=True, text=True, check=True).stdout.splitlines()[0]
print(version, flush=True)


def exact(stream, length):
    result = b''
    while len(result) < length:
        data = stream.recv(length - len(result))
        if not data:
            raise OSError('Proxy stream closed.')
        result += data
    return result


def socks(port, command, destination):
    stream = socket.create_connection(('127.0.0.1', port), timeout=10)
    stream.settimeout(10)
    try:
        stream.sendall(b'\x05\x01\x00')
        assert exact(stream, 2) == b'\x05\x00'
        stream.sendall(bytes([5, command, 0, 1]) + socket.inet_aton('127.0.0.1') + destination.to_bytes(2, 'big'))
        reply = exact(stream, 4)
        assert reply[1] == 0, 'SOCKS request rejected.'
        length = {1: 4, 4: 16}.get(reply[3])
        if length is None:
            length = exact(stream, 1)[0]
        exact(stream, length)
        return stream, int.from_bytes(exact(stream, 2), 'big')
    except BaseException:
        stream.close()
        raise


with tempfile.TemporaryDirectory(prefix='client-test-', dir=runtime) as temporary:
    directory = Path(temporary).resolve()
    assert directory.is_relative_to(runtime), 'Unsafe test directory.'
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    profile.update({'mixed-port': port, 'bind-address': '127.0.0.1', 'allow-lan': False, 'external-controller': '',
        'dns': {'enable': False}, 'tun': {'enable': False}, 'log-level': 'error'})
    config = directory / 'client.json'
    config.write_text(json.dumps(profile))
    subprocess.run([args.binary, '-t', '-d', str(directory), '-f', str(config)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with (directory / 'client.log').open('wb') as log:
        process = subprocess.Popen([args.binary, '-d', str(directory), '-f', str(config)], stdout=log, stderr=subprocess.STDOUT,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        try:
            for _ in range(100):
                assert process.poll() is None, 'Isolated client exited.'
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=0.1):
                        break
                except OSError:
                    time.sleep(0.05)
            else:
                raise AssertionError('Isolated client did not start.')
            proxy = f'http://127.0.0.1:{port}'
            # Use the platform's trusted CA store; portable Python may have no CA bundle.
            curl = str(Path(os.environ['SystemRoot']) / 'System32' / 'curl.exe') if os.name == 'nt' else 'curl'
            response = subprocess.run([curl, '--silent', '--show-error', '--fail', '--max-time', '20', '--noproxy', '',
                '--proxy', proxy, 'https://example.com/'], capture_output=True)
            assert response.returncode == 0 and b'Example Domain' in response.stdout, 'Verified HTTPS request failed: ' + response.stderr.decode(errors='replace')[:512]
            print('External HTTPS through installed client core and server-issued profile: PASS', flush=True)
            stream, _ = socks(port, 1, targets['tcp'])
            with stream:
                data = secrets.token_bytes(16)
                stream.sendall(data)
                assert exact(stream, len(data)) == data
            control, relay = socks(port, 3, 0)
            with control, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                udp.bind(('127.0.0.1', 0))
                udp.settimeout(10)
                nonce = secrets.token_bytes(16)
                packet = b'\x00\x00\x00\x01' + socket.inet_aton('127.0.0.1') + targets['udp'].to_bytes(2, 'big') + nonce
                udp.sendto(packet, ('127.0.0.1', relay))
                assert udp.recv(4096).endswith(nonce)
            print('External authenticated TCP and UDP/XUDP: PASS', flush=True)
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
