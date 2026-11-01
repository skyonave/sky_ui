#!/usr/bin/env python3
"""Own only Sky UI AWG interfaces and its named NAT table; never execute profile hooks."""
import base64
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import socket
import stat
import subprocess
import sys
import time

OPTIONS = {'Jc': 'jc', 'Jmin': 'jmin', 'Jmax': 'jmax', **{f'S{i}': f's{i}' for i in range(1, 5)},
           **{f'H{i}': f'h{i}' for i in range(1, 5)}, **{f'I{i}': f'i{i}' for i in range(1, 6)},
           'ContentPaddingAddition': 'content_padding_addition', 'RandomTrailers': 'random_trailers',
           'DisableCookies': 'disable_cookies', 'RekeyAfterTime': 'rekey_after_time',
           'RekeyTimeout': 'rekey_timeout', 'RejectAfterTime': 'reject_after_time',
           'KeepaliveTimeout': 'keepalive_timeout', 'MaxHandshakeAttempts': 'max_handshake_attempts'}
TABLE = 'sky_ui_awg'
BOUNDS = {'Jc': (0,128), 'Jmin': (0,1280), 'Jmax': (0,1280),
          **{f'S{i}': (12,1024) for i in range(1,5)}, **{f'H{i}': (1,4294967295) for i in range(1,5)},
          'RekeyAfterTime': (10,86400), 'RekeyTimeout': (1,120), 'RejectAfterTime': (20,172800),
          'KeepaliveTimeout': (1,120), 'MaxHandshakeAttempts': (1,128)}


def signature(value):
    tags = re.compile(r'<(?:b 0x([a-fA-F0-9]+)|(r|rd|rc) ([0-9]{1,4})|(t))>')
    offset, size = 0, 0
    for tag in tags.finditer(value):
        require(tag.start() == offset)
        offset = tag.end()
        if tag[1] is not None:
            require(len(tag[1]) % 2 == 0)
            size += len(tag[1]) // 2
        else: size += int(tag[3]) if tag[3] is not None else 4
        require(size <= 1280)
    require(offset == len(value))


def require(value):
    if not value: raise ValueError('amnezia_configuration_invalid')


def key(value):
    require(isinstance(value, str))
    try: decoded = base64.b64decode(value, validate=True)
    except Exception: raise ValueError('amnezia_configuration_invalid') from None
    require(len(decoded) == 32)
    return decoded.hex()


def validate(value):
    require(isinstance(value, dict) and set(value) == {'version', 'interfaces'} and value['version'] == '3.1')
    require(isinstance(value['interfaces'], list) and len(value['interfaces']) <= 32)
    names, ports, networks = set(), set(), []
    for interface in value['interfaces']:
        require(set(interface) == {'name', 'address', 'port', 'mtu', 'privateKey', 'headerProtectionKey', 'options', 'peers'})
        name = interface['name']
        require(isinstance(name, str) and re.fullmatch(r'skyawg[a-f0-9]{8}', name) and name not in names)
        names.add(name)
        address = ipaddress.IPv4Interface(interface['address'])
        require(any(address.ip in ipaddress.ip_network(block) for block in ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16')) and 24 <= address.network.prefixlen <= 30 and address.ip not in (address.network.network_address, address.network.broadcast_address))
        require(not any(address.network.overlaps(n) for n in networks))
        networks.append(address.network)
        port = interface['port']
        require(type(port) is int and 1 <= port <= 65535 and port not in ports)
        ports.add(port)
        require(type(interface['mtu']) is int and 1280 <= interface['mtu'] <= 1420)
        key(interface['privateKey']); key(interface['headerProtectionKey'])
        options = interface['options']
        require(isinstance(options, dict) and set(options) <= OPTIONS.keys())
        for option, text in options.items():
            require(isinstance(text, str) and len(text) <= 2048 and not any(c in text for c in '\n\r\x00'))
            if option in ('RandomTrailers', 'DisableCookies'): require(text in ('true', 'false'))
            elif option.startswith('I') and len(option) == 2: signature(text)
            elif option == 'ContentPaddingAddition':
                require(re.fullmatch(r'\d{1,4}(?:-\d{1,4})?', text))
                bounds = list(map(int, text.split('-')))
                require(max(bounds) <= 4096 and bounds[0] <= bounds[-1])
            else: require(re.fullmatch(r'[0-9]{1,10}', text) and BOUNDS[option][0] <= int(text) <= BOUNDS[option][1])
        require(set(BOUNDS) <= options.keys())
        require(int(options['Jmin']) <= int(options['Jmax']) and int(options['RekeyAfterTime']) < int(options['RejectAfterTime']))
        require(isinstance(interface['peers'], list) and len(interface['peers']) <= 253)
        addresses, keys = set(), set()
        for peer in interface['peers']:
            require(set(peer) == {'publicKey', 'presharedKey', 'address'})
            public = key(peer['publicKey']); key(peer['presharedKey'])
            ip = ipaddress.IPv4Interface(peer['address'])
            require(ip.network.prefixlen == 32 and ip.ip in address.network and ip.ip not in (address.ip, address.network.network_address, address.network.broadcast_address))
            require(str(ip) not in addresses and public not in keys)
            addresses.add(str(ip)); keys.add(public)
    return value


def load(path):
    path = Path(path)
    require(path.is_absolute() and '..' not in path.parts)
    parent = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:-1]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent); parent = next_fd
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    finally: os.close(parent)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= 4 * 1024 * 1024)
        return validate(json.load(stream))


def uapi_payload(interface):
    lines = ['set=1', 'private_key=' + key(interface['privateKey']), 'listen_port=' + str(interface['port']),
             'header_protection_key=' + key(interface['headerProtectionKey']), 'replace_peers=true']
    for name, text in interface['options'].items():
        lines.append(OPTIONS[name] + '=' + ({'true': '1', 'false': '0'}.get(text, text)))
    for peer in interface['peers']:
        lines += ['public_key=' + key(peer['publicKey']), 'preshared_key=' + key(peer['presharedKey']),
                  'replace_allowed_ips=true', 'allowed_ip=' + peer['address']]
    return ('\n'.join(lines) + '\n\n').encode()


def command(args, *, input=None, check=True):
    value = subprocess.run(args, input=input, capture_output=True, timeout=15)
    if check and value.returncode: raise ValueError('amnezia_network_failed')
    return value


def cleanup_table():
    value = command(['nft', '-j', 'list', 'table', 'ip', TABLE], check=False)
    if value.returncode == 0:
        parsed = json.loads(value.stdout)
        require(any(entry.get('table', {}).get('comment') == 'Managed by Sky UI' for entry in parsed['nftables']))
        command(['nft', 'delete', 'table', 'ip', TABLE])


def run(config, binary):
    require(os.geteuid() == 0)
    value = load(config)
    children, owned = [], []
    stopping = False
    def stop(*_):
        nonlocal stopping
        stopping = True
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
    cleanup_table()
    try:
        routes = json.loads(command(['ip', '-j', 'route', 'show', 'table', 'main']).stdout)
        for interface in value['interfaces']:
            name = interface['name']
            require(not Path('/sys/class/net', name).exists())
            network = ipaddress.IPv4Interface(interface['address']).network
            for route in routes:
                destination = route.get('dst', 'default')
                if destination != 'default': require(not network.overlaps(ipaddress.ip_network(destination, strict=False)))
            child = subprocess.Popen([binary, '-f', name], env={'PATH': '/usr/sbin:/usr/bin:/sbin:/bin', 'LOG_LEVEL': 'error'})
            children.append(child); owned.append(name)
            path = '/var/run/amneziawg/' + name + '.sock'
            deadline = time.monotonic() + 10
            while not Path(path).exists() and child.poll() is None and time.monotonic() < deadline: time.sleep(.05)
            require(Path(path).exists() and child.poll() is None)
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(5); connection.connect(path)
                connection.sendall(uapi_payload(interface))
                response = b''
                while not response.endswith(b'\n\n') and len(response) < 4096:
                    chunk = connection.recv(4096)
                    if not chunk: break
                    response += chunk
                require(response == b'errno=0\n\n')
            command(['ip', 'address', 'add', interface['address'], 'dev', name])
            command(['ip', 'link', 'set', 'dev', name, 'mtu', str(interface['mtu']), 'up'])
        if owned:
            # Keep the prior value in the project's own root-owned directory for
            # complete uninstall. Stopping one VPN must not disable host forwarding.
            state = Path('/var/lib/sky-ui-amneziawg-network')
            state.mkdir(mode=0o700, exist_ok=True)
            require(not state.is_symlink() and state.stat().st_uid == 0)
            saved = state / 'ip_forward'
            if not saved.exists():
                fd = os.open(saved, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(fd, 'w') as out: out.write(Path('/proc/sys/net/ipv4/ip_forward').read_text())
            Path('/proc/sys/net/ipv4/ip_forward').write_text('1\n')
            rules = 'add table ip ' + TABLE + ' { comment "Managed by Sky UI"; }\n'
            rules += 'add chain ip ' + TABLE + ' postrouting { type nat hook postrouting priority srcnat; policy accept; }\n'
            for interface in value['interfaces']:
                rules += 'add rule ip ' + TABLE + ' postrouting ip saddr ' + str(ipaddress.IPv4Interface(interface['address']).network) + ' oifname != "' + interface['name'] + '" masquerade\n'
            command(['nft', '-f', '-'], input=rules.encode())
        print('AmneziaWG 3.1 ready', flush=True)
        while not stopping:
            if any(child.poll() is not None for child in children): raise ValueError('amnezia_process_failed')
            time.sleep(.2)
    finally:
        for child in children: child.terminate()
        for child in children:
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired: child.kill(); child.wait()
        for name in owned: command(['ip', 'link', 'delete', 'dev', name], check=False)
        cleanup_table()


if __name__ == '__main__':
    try:
        if len(sys.argv) == 3 and sys.argv[1] == 'check': load(sys.argv[2])
        elif len(sys.argv) == 4 and sys.argv[1] == 'run': run(sys.argv[2], sys.argv[3])
        elif sys.argv[1:] == ['cleanup']: cleanup_table()
        else: raise ValueError('request_invalid')
    except Exception:
        # Never echo a malformed key or the configuration back into journald.
        print('AmneziaWG operation failed; check configuration and networking.', file=sys.stderr)
        sys.exit(1)
