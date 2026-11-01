#!/usr/bin/env python3
"""Owner-authenticated installer and lifecycle smoke check for a fresh test VM."""
import getpass
import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

assert os.geteuid() == 0
environment = dict(line.split('=', 1) for line in Path('/etc/sky-ui/server.env').read_text().splitlines() if '=' in line)
base = 'http://127.0.0.1:' + environment['SKY_UI_PORT'] + '/api/v1/'
origin = environment['SKY_UI_WEB_ORIGIN']
gateway = Path(environment['SKY_UI_GATEWAY_SECRET_FILE']).read_text().strip()
http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
owner_db = Path(environment['SKY_UI_DATA_DIR']) / 'owner.sqlite'
with sqlite3.connect(f'file:{owner_db}?mode=ro', uri=True) as db:
    original_owner = tuple(db.execute('SELECT username,password_hash,generation,seed_hash FROM owner').fetchone())
headers = {'X-Sky-UI-Gateway': gateway, 'Origin': origin}

def call(path, method='GET', payload=None, expected=200):
    request = urllib.request.Request(base + path, method=method, headers=headers,
        data=None if payload is None else json.dumps(payload).encode())
    if payload is not None:
        request.add_header('Content-Type', 'application/json')
    try:
        response = http.open(request, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        assert response.status == expected, f'{method} {path}: {response.status}'
        result = json.loads(response.read())
        return result.get('data', result), response.headers

call('panel', expected=401)
password = getpass.getpass('Owner password (not stored): ')
state, response_headers = call('auth/login', 'POST', {'username': original_owner[0], 'password': password})
del password
headers.update({'Cookie': response_headers['Set-Cookie'].split(';', 1)[0], 'X-Sky-UI-CSRF': state['csrf']})
try:
    panel, _ = call('panel')
    assert not panel['connections'] and not panel['recipients'], 'Refusing lifecycle checks on a nonempty installation.'
    for operation, field, value in [('start', 'controllerReady', True), ('restart', 'controllerReady', True), ('stop', 'processState', 'inactive')]:
        result, _ = call('cores/primary/actions/' + operation, 'POST', {})
        assert result[field] == value
    files = [Path('/etc/sky-ui/controller.secret'), Path('/etc/sky-ui/gateway.secret'), Path('/var/lib/sky-ui/cores/mihomo/config.yaml')]
    before = [hashlib.sha256(p.read_bytes()).digest() for p in files]
    subprocess.run(['bash', sys.argv[1], '--bundle', sys.argv[2]], check=True)
    assert before == [hashlib.sha256(p.read_bytes()).digest() for p in files]
    assert call('cores/primary')[0]['processState'] == 'inactive'
    assert call('auth/session')[0]['authenticated']
    with sqlite3.connect(f'file:{owner_db}?mode=ro', uri=True) as db:
        assert original_owner == tuple(db.execute('SELECT username,password_hash,generation,seed_hash FROM owner').fetchone())
finally:
    call('auth/logout', 'POST', {})
print('Linux owner, systemd and repeat-installer checks passed.')
