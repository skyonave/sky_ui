#!/usr/bin/env python3
"""Local administration for a managed Sky UI installation."""
import argparse
from contextlib import contextmanager
import fcntl
import grp
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys

import maintenance as m

UNITS = ('sky-ui.service', 'sky-ui-mihomo.service', 'sky-ui-sing-box.service', 'sky-ui-xray.service', 'sky-ui-amneziawg.service', 'sky-ui-edge.service',
         'sky-ui-certificates.service', 'sky-ui-certificates.timer',
         'sky-ui-maintenance.service', 'sky-ui-maintenance-recovery.service', 'sky-ui-update.service', 'sky-ui-update-recovery.service',
         'sky-ui-cleanup.service','sky-ui-cleanup.timer')
ACCOUNTS = ('sky-ui', 'sky-ui-core', 'sky-ui-sing-box', 'sky-ui-xray', 'sky-ui-build', 'sky-ui-edge')
DIRECTORIES = tuple(map(Path, ('/etc/sky-ui', '/var/lib/sky-ui', '/var/lib/sky-ui-edge',
    '/var/lib/sky-ui-certificates', '/var/lib/sky-ui-maintenance', '/var/lib/sky-ui-amneziawg-network', '/opt/sky-ui')))
COMMANDS = (Path('/usr/local/bin/skyui'), Path('/usr/local/bin/sky-ui'))
SYSTEMD = Path('/etc/systemd/system')
POLKIT = Path('/etc/polkit-1/rules.d/49-sky-ui.rules')
LOCKS = (Path('/run/lock/sky-ui-install.lock'), Path('/run/lock/sky-ui-setup.lock'))


def run(*args, check=True, capture=False):
    return subprocess.run(args, check=check, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.STDOUT if capture else None)


def trusted(path, directory=False, uid=0):
    """Reject substituted paths before reading or removing managed files."""
    path = Path(path)
    for item in (path, *path.parents):
        if item.is_symlink():
            raise ValueError(f'Символическая ссылка недопустима: {item}')
    if path.exists():
        stat = path.stat()
        if stat.st_uid != uid or (directory and not path.is_dir()):
            raise ValueError(f'Неожиданный владелец или тип: {path}')
        if not directory and (not path.is_file() or stat.st_nlink != 1):
            raise ValueError(f'Неожиданный тип файла: {path}')
    return path


def managed():
    if os.geteuid() != 0:
        raise ValueError('Запусти команду через sudo или от root.')
    marker = trusted(m.ETC / 'managed-by-sky-ui')
    if not marker.is_file():
        raise ValueError('Управляемая установка Sky UI не найдена.')


@contextmanager
def locked():
    descriptors = []
    try:
        m.wait_cleanup()
        if (m.STATE / 'panel-update-intent.json').exists():
            raise ValueError('Выполняется обновление Sky UI. Дождитесь завершения.')
        for path in (LOCKS[0], m.STATE / 'worker.lock'):
            fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            descriptors.append(fd)
            try:
                m.acquire_lock(fd)
            except BlockingIOError:
                raise ValueError('Установка, настройка или обслуживание уже выполняется.')
        yield
    finally:
        for fd in reversed(descriptors):
            os.close(fd)


def setup():
    run('bash', str(m.CURRENT / 'deploy/setup.sh'), 'setup')


def status():
    print('Sky UI / ' + m.read_regular(m.CURRENT.resolve() / 'VERSION', 128).decode().strip())
    for unit in UNITS:
        result = run('systemctl', 'is-active', unit, check=False, capture=True)
        print(f'{unit}: {result.stdout.strip()}')


def lifecycle(action, target):
    if target == 'all':
        for core in ('sing-box', 'xray', 'amneziawg'):
            if (m.CORES / core / 'current' / core).is_file() or m.active('sky-ui-' + core + '.service'):
                lifecycle(action, core)
    if target in ('sing-box', 'xray', 'amneziawg'):
        with locked():
            if action != 'stop' and not (m.CORES / target / 'current' / target).is_file():
                raise ValueError('Ядро не установлено. Используйте skyui install-core ' + target)
            api_running = m.active('sky-ui.service')
            if api_running: run('systemctl', 'stop', 'sky-ui.service')
            try:
                m.assert_configuration_settled()
                owner = pwd.getpwnam('sky-ui')
                path = m.DATA / 'instances' / (target + '.json')
                run('systemctl', action, 'sky-ui-' + target + '.service')
                m.atomic(path, json.dumps({'instanceId': target, 'coreId': target, 'desiredState': 'stopped' if action == 'stop' else 'running'}).encode(), 0o600, owner.pw_uid, owner.pw_gid)
            finally:
                if api_running: run('systemctl', 'start', 'sky-ui.service')
        status()
        return
    with locked():
        if action != 'stop' and target == 'core' and not Path(m.environment()['SKY_UI_CORE_BINARY']).is_file():
            raise ValueError('Ядро не установлено. Используйте skyui install-core.')
        api_running = m.active('sky-ui.service')
        if target == 'core' or target == 'all' and (action == 'stop' or Path(m.environment()['SKY_UI_CORE_BINARY']).is_file()):
            # Stop API writes while changing persisted instance state.
            if api_running:
                run('systemctl', 'stop', 'sky-ui.service')
            try:
                m.assert_configuration_settled()
                path = m.DATA / 'instances/primary.json'
                instance = json.loads(m.read_regular(path, 65536)) if path.exists() else {
                    'instanceId': 'primary', 'coreId': 'mihomo'}
                if instance.get('instanceId') != 'primary' or instance.get('coreId') != 'mihomo':
                    raise ValueError('Неизвестная управляемая инстанция ядра.')
                owner = pwd.getpwnam('sky-ui')
                if not path.parent.exists():
                    path.parent.mkdir(mode=0o700)
                    os.chown(path.parent, owner.pw_uid, owner.pw_gid)
                trusted(path.parent, directory=True, uid=owner.pw_uid)
                instance['desiredState'] = 'stopped' if action == 'stop' else 'running'
                run('systemctl', action, 'sky-ui-mihomo.service')
                m.atomic(path, json.dumps(instance).encode(), uid=pwd.getpwnam('sky-ui').pw_uid,
                         gid=grp.getgrnam('sky-ui').gr_gid)
            finally:
                if target == 'core' and api_running:
                    run('systemctl', 'reset-failed', 'sky-ui.service')
                    run('systemctl', 'start', 'sky-ui.service')
        if target in ('panel', 'all'):
            units = ('sky-ui-edge.service', 'sky-ui.service') if action == 'stop' else (
                'sky-ui.service', 'sky-ui-edge.service')
            for unit in units:
                if unit == 'sky-ui-edge.service' and action != 'stop' and not (m.ETC / 'Caddyfile').is_file():
                    print('Для настройки HTTPS запусти skyui setup.')
                    continue
                if unit == 'sky-ui.service' and action != 'stop':
                    run('systemctl', 'reset-failed', unit)
                run('systemctl', action, unit)
    status()


def logs(target, follow, lines):
    units = {'panel': ('sky-ui.service', 'sky-ui-edge.service'),
             'core': ('sky-ui-mihomo.service',), 'all': UNITS,
             'certificates': ('sky-ui-edge.service', 'sky-ui-certificates.service')}
    units.update({core: ('sky-ui-' + core + '.service',) for core in ('sing-box', 'xray', 'amneziawg')})
    args = ['journalctl', '--namespace=+sky-ui', '--no-pager', '-n', str(lines)]
    for unit in units[target]:
        args += ['-u', unit]
    if follow:
        args.append('-f')
    run(*args)


def certificates(action, follow=False, lines=100):
    if action == 'setup':
        return setup()
    if action == 'logs':
        return logs('certificates', follow, lines)
    if action == 'check':
        # Reloading checks the managed configuration. Caddy schedules renewal itself.
        run('systemctl', 'reload', 'sky-ui-edge.service')
        run('systemctl', 'start', 'sky-ui-certificates.service')
        print('Настройки HTTPS применены, сертификаты синхронизированы с ядром.')
    access_path = m.ETC / 'access.conf'
    access = m.read_regular(access_path, 4096).decode().splitlines() if access_path.exists() else []
    print('IP: ' + (access[0] if access else '—'))
    print('Домен: ' + (access[1] if len(access) > 1 and access[1] else 'не настроен'))
    root = Path('/var/lib/sky-ui-edge/data/caddy/certificates')
    found = False
    if root.exists():
        for cert in sorted(root.glob('*/*/*.crt')):
            # Source certificates belong to the isolated gateway service.
            if cert.is_symlink() or not cert.is_file():
                continue
            found = True
            print('\n' + cert.parent.name)
            run('openssl', 'x509', '-in', str(cert), '-noout', '-subject', '-issuer', '-dates')
    if not found:
        print('Выпущенных сертификатов пока нет. Проверь журнал HTTPS.')
    print('\nПродлением управляет Caddy автоматически. Проверка синхронизации:')
    run('systemctl', 'list-timers', 'sky-ui-certificates.timer', '--no-pager')


def removal_plan():
    managed()
    if not shutil.rmtree.avoids_symlink_attacks:
        raise ValueError('Python не поддерживает безопасное удаление каталогов.')
    if m.environment().get('SKY_UI_DATA_DIR') != str(m.DATA):
        raise ValueError('Настроена внешняя папка данных. Автоматическое удаление недоступно.')
    for path in DIRECTORIES:
        account = 'sky-ui' if path == m.DATA else 'sky-ui-edge' if path == m.EDGE else None
        trusted(path, directory=True, uid=pwd.getpwnam(account).pw_uid if account else 0)
    files = [SYSTEMD / unit for unit in UNITS] + [POLKIT, *LOCKS]
    journal_config=SYSTEMD.parent/'journald@sky-ui.conf'
    if journal_config.exists() or journal_config.is_symlink():
        if not journal_config.is_symlink() or journal_config.readlink()!=Path('/opt/sky-ui/current/deploy/journald-sky-ui.conf'):
            raise ValueError('Journal namespace configuration does not belong to Sky UI.')
    for command in COMMANDS:
        trusted(command)
        if command.exists() and '/opt/sky-ui/current/deploy/' not in m.read_regular(command, 16384).decode():
            raise ValueError(f'Команда не принадлежит Sky UI: {command}')
        files.append(command)
    for unit in UNITS:
        unit_path = trusted(SYSTEMD / unit)
        if unit_path.exists() and 'Sky UI' not in m.read_regular(unit_path, 65536).decode():
            raise ValueError(f'Служба не принадлежит Sky UI: {unit}')
        trusted(SYSTEMD / (unit + '.d'), directory=True)
    for path in files:
        trusted(path)
    # Do not delete accounts or groups adopted by unrelated host services.
    for account in ACCOUNTS:
        try:
            user = pwd.getpwnam(account)
        except KeyError:
            continue
        if user.pw_uid == 0 or user.pw_gid == 0 or user.pw_shell not in ('/usr/sbin/nologin', '/sbin/nologin', '/bin/false'):
            raise ValueError(f'Неожиданная учётная запись: {account}')
        for other in pwd.getpwall():
            if other.pw_name not in ACCOUNTS and other.pw_gid == user.pw_gid:
                raise ValueError(f'Группа {account} используется другой учётной записью.')
    for account in ACCOUNTS:
        try:
            group = grp.getgrnam(account)
        except KeyError:
            continue
        if set(group.gr_mem) - set(ACCOUNTS):
            raise ValueError(f'В группе {account} есть сторонние пользователи.')
    return files


def uninstall(confirm=input):
    files = removal_plan()
    print('Будут удалены Sky UI, ядро, настройки, доступы, пароли, сертификаты и резервные копии Sky UI:')
    for path in DIRECTORIES:
        print('  ' + str(path))
    forwarding = Path('/var/lib/sky-ui-amneziawg-network/ip_forward')
    if forwarding.exists(): print('Будет восстановлено значение IP forwarding, сохранённое до включения AmneziaWG.')
    if confirm('Введи DELETE для полного удаления: ').strip() != 'DELETE':
        print('Удаление отменено.')
        return
    # Serialize with the root maintenance worker before stopping the application.
    with locked():
        removal_plan()
        for unit in UNITS:
            run('systemctl', 'disable', '--now', unit, check=False, capture=True)
        for unit in UNITS:
            state = run('systemctl', 'is-active', unit, check=False, capture=True).stdout.strip()
            if state in ('active', 'activating', 'deactivating', 'reloading'):
                raise ValueError(f'Служба не остановилась: {unit}. Удаление прервано.')
        if forwarding.exists():
            trusted(forwarding)
            original = m.read_regular(forwarding, 16).decode().strip()
            if original in ('0', '1') and Path('/proc/sys/net/ipv4/ip_forward').read_text().strip() == '1':
                Path('/proc/sys/net/ipv4/ip_forward').write_text(original + '\n')
        for account in reversed(ACCOUNTS):
            if run('id', '-u', account, check=False, capture=True).returncode == 0:
                run('userdel', account)
        for account in ACCOUNTS:
            try:
                grp.getgrnam(account)
            except KeyError:
                continue
            run('groupdel', account)
        run('systemctl','stop','systemd-journald@sky-ui.service','systemd-journald@sky-ui.socket','systemd-journald-varlink@sky-ui.socket',check=False,capture=True)
        machine=Path('/etc/machine-id').read_text().strip()
        if __import__('re').fullmatch('[0-9a-f]{32}',machine):
            journal=m.DATA.parent.parent/'log/journal'/(machine+'.sky-ui')
            if journal.exists(): shutil.rmtree(trusted(journal,directory=True))
        for path in files:
            if path not in LOCKS:
                path.unlink(missing_ok=True)
        (SYSTEMD.parent/'journald@sky-ui.conf').unlink(missing_ok=True)
        for unit in UNITS:
            dropin = SYSTEMD / (unit + '.d')
            if dropin.exists():
                shutil.rmtree(dropin)
        run('systemctl', 'daemon-reload')
        for unit in UNITS:
            run('systemctl', 'reset-failed', unit, check=False, capture=True)
        for path in DIRECTORIES:
            if path.exists():
                shutil.rmtree(path)
        for path in LOCKS:
            path.unlink(missing_ok=True)
    print('Sky UI удалён. Системные зависимости и общая история journalctl сохранены.')


def main(argv=None):
    parser = argparse.ArgumentParser(prog='skyui', description='Управление Sky UI на этом сервере')
    commands = parser.add_subparsers(dest='command', required=True)
    for name, help_text in [('status','Состояние служб и версия'), ('version','Версия Sky UI'), ('update','Обновить Sky UI'),
            ('setup','Настройка IP, домена и администратора'), ('backup','Создать резервную копию'),
            ('backups','Список резервных копий'), ('remove-core','Удалить ядро, сохранив подключения'), ('install-core','Установить проверенное ядро'), ('update-core','Установить проверенную версию ядра'),
            ('cleanup','Удалить ненужные артефакты и логи'), ('uninstall','Полностью удалить Sky UI и его данные')]:
        sub = commands.add_parser(name, help=help_text)
        if name in ('install-core', 'update-core', 'remove-core'):
            sub.add_argument('core', choices=tuple(m.CORE_REPOSITORIES), nargs='?', default='mihomo')
    restore = commands.add_parser('restore', help='Восстановить резервную копию')
    restore.add_argument('id')
    for action in ('start', 'stop', 'restart'):
        sub = commands.add_parser(action)
        sub.add_argument('target', choices=('panel','core','all','sing-box','xray','amneziawg'), default='panel', nargs='?')
    for name in ('logs', 'certificates'):
        sub = commands.add_parser(name, help='Журнал' if name == 'logs' else 'HTTPS и Let’s Encrypt')
        sub.add_argument('target', nargs='?', default='panel' if name == 'logs' else 'status',
                         choices=('panel','core','all','sing-box','xray','amneziawg') if name == 'logs' else ('status','setup','check','logs'))
        sub.add_argument('-f','--follow', action='store_true')
        sub.add_argument('-n','--lines', type=int, default=100)
    if argv == [] or (argv is None and len(sys.argv) == 1):
        parser.print_help()
        return
    args = parser.parse_args(argv)
    managed()
    command = args.command
    if command in ('backup','backups','restore','update-core','install-core','remove-core','update'):
        return m.cli([command] + ([args.id] if command == 'restore' else [args.core] if command.endswith('-core') and args.core != 'mihomo' else []), pwd.getpwnam('sky-ui'))
    if command in ('start','stop','restart'):
        return lifecycle(command, args.target)
    if command == 'version':
        print(m.read_regular(m.CURRENT.resolve() / 'VERSION', 128).decode().strip())
    elif command == 'status':
        status()
    elif command == 'setup':
        setup()
    elif command == 'cleanup':
        run('systemctl','start','sky-ui-cleanup.service')
        print('Свободно: '+format(shutil.disk_usage(m.STATE).free/1073741824,'.1f')+' GB')
    elif command == 'uninstall':
        uninstall()
    elif command in ('logs','certificates'):
        if not 1 <= args.lines <= 10000:
            raise ValueError('Число строк должно быть от 1 до 10000.')
        (logs if command == 'logs' else certificates)(args.target, args.follow, args.lines)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, m.MaintenanceError, subprocess.CalledProcessError) as error:
        print('Ошибка: ' + str(error), file=sys.stderr)
        sys.exit(1)
    except (KeyboardInterrupt, EOFError):
        sys.exit(130)
