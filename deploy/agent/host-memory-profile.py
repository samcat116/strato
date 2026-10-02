#!/usr/bin/env python3
"""Explicit bootstrap/boot-time host memory policy; never called by heartbeat."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

CONFIG = '/etc/strato/host-memory-profile.json'
STATE = '/var/lib/strato/host-memory-profile.json'
THP = '/sys/kernel/mm/transparent_hugepage/enabled'
KSM = '/sys/kernel/mm/ksm/'
ZSWAP = '/sys/module/zswap/parameters/'
MGLRU = '/sys/kernel/mm/lru_gen/enabled'


class ProfileError(Exception):
    pass


def validate(config):
    if not isinstance(config, dict):
        raise ProfileError('invalid_profile_object')
    allowed = {'tier', 'tenant_class', 'nvme_swap', 'zram_bytes', 'zswap_pool_percent',
               'ksm', 'ksm_pages_to_scan', 'ksm_sleep_millisecs', 'require_mglru'}
    if set(config) - allowed:
        raise ProfileError('unknown_profile_field')
    if config.get('tier') not in ('zswap', 'zram'):
        raise ProfileError('compressed_tier_required')
    if config.get('tenant_class') not in ('single', 'multi'):
        raise ProfileError('explicit_tenant_class_required')
    for key in ('ksm', 'require_mglru'):
        if key in config and type(config[key]) is not bool:
            raise ProfileError('invalid_' + key)
    if config.get('ksm', False) and config['tenant_class'] != 'single':
        raise ProfileError('ksm_multitenant_forbidden')
    path = config.get('nvme_swap', '')
    if not isinstance(path, str) or not re.fullmatch(r'/(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+', path):
        raise ProfileError('explicit_nvme_swap_required')
    for key, default, low, high in (
        ('zram_bytes', 1073741824, 1048576, 1099511627776),
        ('zswap_pool_percent', 20, 1, 50),
        ('ksm_pages_to_scan', 100, 1, 1000),
        ('ksm_sleep_millisecs', 100, 50, 60000),
    ):
        value = config.get(key, default)
        if type(value) is not int or not low <= value <= high:
            raise ProfileError('invalid_' + key)
    return dict(config)


class Host:
    def __init__(self, root='/', runner=None):
        self.root = Path(root)
        self.runner = runner or self._run

    def path(self, path):
        return self.root / path.lstrip('/')

    def read(self, path):
        try:
            return self.path(path).read_text().strip()
        except FileNotFoundError:
            raise ProfileError('unsupported:' + path) from None

    def write(self, path, value):
        self.path(path).write_text(str(value) + '\n')

    def save(self, path, value):
        target = self.path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        temp = target.with_suffix('.tmp')
        temp.write_text(json.dumps(value, sort_keys=True) + '\n')
        temp.chmod(0o600)
        os.replace(temp, target)

    def load(self, path):
        return json.loads(self.read(path))

    @staticmethod
    def _run(args):
        return subprocess.run(args, check=True, text=True, capture_output=True, timeout=30).stdout.strip()

    def swaps(self):
        return {parts[0]: int(parts[4]) for line in self.read('/proc/swaps').splitlines()[1:]
                if len(parts := line.split()) >= 5}

    def nvme(self, path):
        target = self.path(path)
        mode = target.stat().st_mode
        if stat.S_ISBLK(mode):
            source = path
        elif stat.S_ISREG(mode):
            source = self.runner(['findmnt', '-n', '-o', 'SOURCE', '-T', path]).split('[')[0]
        else:
            raise ProfileError('invalid_nvme_swap')
        if not re.fullmatch(r'/dev/nvme\d+n\d+(p\d+)?', source):
            raise ProfileError('nvme_swap_not_on_nvme')
        # A prepared operator-owned swap signature is mandatory. Never format it.
        if self.runner(['blkid', '-p', '-s', 'TYPE', '-o', 'value', path]) != 'swap':
            raise ProfileError('nvme_swap_not_prepared')


def selected(raw):
    match = re.search(r'\[([^]]+)\]', raw)
    return match[1] if match else raw


def preflight(host, config):
    host.nvme(config['nvme_swap'])
    if 'madvise' not in host.read(THP).split() and '[madvise]' not in host.read(THP).split():
        raise ProfileError('unsupported_thp_madvise')
    host.read(KSM + 'run')  # Even default-off must be enforceable.
    if config.get('require_mglru', False):
        if not int(host.read(MGLRU), 0) & 1:
            raise ProfileError('mglru_disabled')
    if config['tier'] == 'zswap':
        host.read(ZSWAP + 'enabled')
        host.read(ZSWAP + 'max_pool_percent')
    else:
        if config.get('zram_bytes', 1073741824) % os.sysconf('SC_PAGE_SIZE'):
            raise ProfileError('zram_size_requires_host_page_alignment')
        # Do not load modules or take ownership of an operator's active zram.
        host.read('/sys/block/zram0/disksize')
        host.read('/sys/block/zram0/reset')
        host.read(ZSWAP + 'enabled')  # Avoid stacking zswap over zram.
    if config.get('ksm', False):
        host.read(KSM + 'pages_to_scan')
        host.read(KSM + 'sleep_millisecs')
    host.read(KSM + 'pages_shared')
    host.read(KSM + 'pages_sharing')


def apply(host, config):
    config = validate(config)
    preflight(host, config)
    state = host.load(STATE) if host.path(STATE).exists() else None
    if state and state['config'] != config:
        raise ProfileError('profile_change_requires_disable')
    if not state:
        if config['tier'] == 'zram' and int(host.read('/sys/block/zram0/disksize')) != 0:
            raise ProfileError('operator_zram_in_use')
        state = {'config': config, 'baseline': {THP: selected(host.read(THP)),
                 ZSWAP + 'enabled': host.read(ZSWAP + 'enabled')},
                 'fallback_owned': config['nvme_swap'] not in host.swaps(),
                 'zram_owned': config['tier'] == 'zram'}
        if config['tier'] == 'zswap':
            state['baseline'][ZSWAP + 'max_pool_percent'] = host.read(ZSWAP + 'max_pool_percent')
        if config.get('ksm', False):
            for name in ('pages_to_scan', 'sleep_millisecs'):
                state['baseline'][KSM + name] = host.read(KSM + name)
        # Persist recovery authority BEFORE any host effect.
        host.save(STATE, state)
    # Disabling merging is not enough: unmerge first and fail until complete.
    if not config.get('ksm', False):
        host.write(KSM + 'run', 2)
        if int(host.read(KSM + 'pages_shared')) or int(host.read(KSM + 'pages_sharing')):
            raise ProfileError('ksm_unmerge_pending_no_hostile_placement')
        host.write(KSM + 'run', 0)
    swaps = host.swaps()
    if config['tier'] == 'zram':
        if any(priority >= 100 for path, priority in swaps.items() if path != '/dev/zram0'):
            raise ProfileError('operator_swap_priority_conflict')
        size = int(host.read('/sys/block/zram0/disksize'))
        if size and host.runner(['blkid', '-s', 'LABEL', '-o', 'value', '/dev/zram0']) != 'strato-density':
            raise ProfileError('operator_zram_in_use')
        if '/dev/zram0' in swaps and swaps['/dev/zram0'] != 100:
            raise ProfileError('zram_priority_mismatch')
        host.write(ZSWAP + 'enabled', 0)
        if '/dev/zram0' not in swaps:
            host.write('/sys/block/zram0/disksize', config.get('zram_bytes', 1073741824))
            host.runner(['mkswap', '-L', 'strato-density', '/dev/zram0'])
            host.runner(['swapon', '--priority', '100', '/dev/zram0'])
    else:
        host.write(ZSWAP + 'max_pool_percent', config.get('zswap_pool_percent', 20))
        host.write(ZSWAP + 'enabled', 1)
    if config['nvme_swap'] not in swaps:
        host.runner(['swapon', '--priority', '10', config['nvme_swap']])
    host.write(THP, 'madvise')
    if config.get('ksm', False):
        host.write(KSM + 'pages_to_scan', config.get('ksm_pages_to_scan', 100))
        host.write(KSM + 'sleep_millisecs', config.get('ksm_sleep_millisecs', 100))
        host.write(KSM + 'run', 1)


def disable(host):
    if not host.path(STATE).exists():
        host.path(CONFIG).unlink(missing_ok=True)
        host.path('/etc/modules-load.d/strato-host-memory-profile.conf').unlink(missing_ok=True)
        return
    state = host.load(STATE)
    host.write(KSM + 'run', 2)
    if int(host.read(KSM + 'pages_shared')) or int(host.read(KSM + 'pages_sharing')):
        raise ProfileError('ksm_unmerge_pending_no_hostile_placement')
    host.write(KSM + 'run', 0)  # Never restore an unsafe operator KSM baseline.
    swaps = host.swaps()
    if state['zram_owned'] and int(host.read('/sys/block/zram0/disksize')):
        if host.runner(['blkid', '-s', 'LABEL', '-o', 'value', '/dev/zram0']) != 'strato-density':
            raise ProfileError('operator_zram_in_use')
    if state['zram_owned'] and '/dev/zram0' in swaps:
        host.runner(['swapoff', '/dev/zram0'])
    if state['zram_owned']:
        host.write('/sys/block/zram0/reset', 1)
    fallback = state['config']['nvme_swap']
    if state['fallback_owned'] and fallback in swaps:
        host.runner(['swapoff', fallback])
    for path, value in state['baseline'].items():
        host.write(path, value)
    host.path(STATE).unlink()
    host.path(CONFIG).unlink(missing_ok=True)
    host.path('/etc/modules-load.d/strato-host-memory-profile.conf').unlink(missing_ok=True)


def install_profile(host, config, tool_source):
    config = validate(config)
    preflight(host, config)
    if host.path(STATE).exists() and host.load(STATE)['config'] != config:
        raise ProfileError('profile_change_requires_disable')
    host.save(CONFIG, config)
    if config['tier'] == 'zram':
        modules = host.path('/etc/modules-load.d/strato-host-memory-profile.conf')
        modules.parent.mkdir(parents=True, exist_ok=True)
        modules.write_text('zram\n')
    tool = Path(tool_source).resolve()
    if str(tool) != '/usr/local/libexec/strato-host-memory-profile':
        target = host.path('/usr/local/libexec/strato-host-memory-profile')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(tool.read_bytes())
        target.chmod(0o755)
    unit = host.path('/etc/systemd/system/strato-host-memory-profile.service')
    unit.parent.mkdir(parents=True, exist_ok=True)
    unit.write_text(
        '[Unit]\nDescription=Strato opt-in host memory profile\nBefore=strato-agent.service\n'
        'After=local-fs.target systemd-modules-load.service\n'
        '[Service]\nType=oneshot\nRemainAfterExit=yes\nTimeoutStartSec=60\n'
        'ExecStart=/usr/local/libexec/strato-host-memory-profile apply\n'
        '[Install]\nWantedBy=multi-user.target\n')
    host.runner(['systemctl', 'daemon-reload'])
    host.runner(['systemctl', 'enable', 'strato-host-memory-profile.service'])
    apply(host, config)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('install', 'apply', 'disable'))
    parser.add_argument('--config', default=CONFIG)
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error('bootstrap profile requires root')
    host = Host()
    lock_path = host.path('/var/lib/strato/host-memory-profile.lock')
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == 'disable':
            # Stop boot application first, including after a pending rollback.
            host.runner(['systemctl', 'disable', 'strato-host-memory-profile.service'])
            disable(host)
            return
        config = validate(host.load(args.config))
        if args.action == 'install':
            install_profile(host, config, __file__)
        else:
            apply(host, config)


if __name__ == '__main__':
    try:
        main()
    except (ProfileError, OSError, ValueError, subprocess.SubprocessError) as error:
        print('host_memory_profile_failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
