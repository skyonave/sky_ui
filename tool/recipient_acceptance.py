#!/usr/bin/env python3
"""Interactive, tagged recipient acceptance against an authorized installed panel."""
import getpass
import json
import os
from pathlib import Path
import secrets
import socket
import urllib.error
import urllib.request


def main():
    assert os.geteuid() == 0
    os.umask(0o077)
    env = dict(line.split('=', 1) for line in Path('/etc/sky-ui/server.env').read_text().splitlines() if '=' in line)
    origin = env['SKY_UI_WEB_ORIGIN'].rstrip('/')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    cookie = csrf = ''

    def request(path, method='GET', value=None, expected=200, anonymous=False):
        headers = {} if anonymous else {'Cookie': cookie, 'X-Sky-UI-CSRF': csrf, 'Origin': origin}
        headers['User-Agent'] = 'mihomo/acceptance'
        if value is not None:
            headers['Content-Type'] = 'application/json'
        req = urllib.request.Request(origin + path, method=method, headers=headers,
                                     data=None if value is None else json.dumps(value).encode())
        try:
            response = opener.open(req, timeout=90)
        except urllib.error.HTTPError as error:
            assert error.code == expected, f'Unexpected status: {error.code}'
            return None
        assert response.status == expected
        data = json.loads(response.read())
        return data.get('data', data), response.headers

    login, headers = request('/api/v1/auth/login', 'POST', {
        'username': input('Owner username: ').strip(), 'password': getpass.getpass('Owner password: ')})
    cookie, csrf = headers['Set-Cookie'].split(';', 1)[0], login['csrf']
    def api(path, method='GET', value=None):
        return request('/api/v1/' + path, method, value)[0]
    def state():
        return api('panel')
    def save(kind, value, identity=None):
        return api(kind + ('/' + identity if identity else ''), 'PUT' if identity else 'POST', {
            'revision': state()['revision'], 'connection' if kind == 'connections' else 'recipient': value})
    def remove(kind, identity):
        return api(kind + '/' + identity, 'DELETE', {'revision': state()['revision']})
    initial = state()
    tag = 'qa-verge-' + secrets.token_hex(4)
    folder = Path('/root/sky-ui-test/recipient-acceptance')
    folder.mkdir(mode=0o700, exist_ok=True)
    connections = []
    recipient = None
    url = None
    try:
        for suffix in ['A', 'B']:
            with socket.socket() as probe:
                probe.bind(('0.0.0.0', 0))
                port = probe.getsockname()[1]
            result = save('connections', {'id': '', 'name': tag + '-' + suffix, 'coreId': 'mihomo',
                'instanceId': 'primary', 'protocolId': 'vless', 'port': port, 'enabled': True, 'settings': {}})
            connections.append(next(c for c in result['connections'] if c['name'] == tag + '-' + suffix))
        result = save('recipients', {'id': '', 'name': tag, 'enabled': True, 'connectionIds': [connections[0]['id']]})
        recipient = next(r for r in result['recipients'] if r['name'] == tag)
        share = api('recipients/' + recipient['id'] + '/share')
        url = share['subscriptionUrl']
        def export():
            profile = request(url.removeprefix(origin), anonymous=True)[0]
            (folder / 'handoff.json').write_text(json.dumps({'url': url, 'profile': profile, 'tag': tag}))
            print('Profile nodes:', len(profile['proxies']), flush=True)
        export()
        print('READY; commands: add, remove, disable, enable, delete, finish', flush=True)
        for command in iter(input, 'finish'):
            if command in ['add', 'remove', 'disable', 'enable']:
                recipient = dict(recipient, enabled=command != 'disable', connectionIds=[
                    c['id'] for c in (connections if command == 'add' else connections[:1])])
                save('recipients', recipient, recipient['id'])
                if command == 'disable':
                    request(url.removeprefix(origin), expected=404, anonymous=True)
                    print('Disabled subscription rejected; cached profile retained for traffic rejection check.', flush=True)
                else:
                    export()
            elif command == 'delete':
                remove('recipients', recipient['id'])
                recipient = None
                request(url.removeprefix(origin), expected=404, anonymous=True)
                print('Deleted subscription rejected.', flush=True)
            else:
                print('Unknown command.', flush=True)
    finally:
        if recipient:
            remove('recipients', recipient['id'])
        for connection in reversed(connections):
            remove('connections', connection['id'])
        final = state()
        assert final['connections'] == initial['connections']
        assert final['recipients'] == initial['recipients']
        api('auth/logout', 'POST', {})
        for path in folder.iterdir():
            if path.name == 'handoff.json':
                path.unlink()
        print('CLEANUP PASS: original connections and recipients unchanged.', flush=True)


if __name__ == '__main__':
    main()
