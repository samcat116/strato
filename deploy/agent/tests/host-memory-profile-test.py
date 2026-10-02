import importlib.util
from pathlib import Path
import tempfile
import sys
sys.dont_write_bytecode = True
import unittest

spec = importlib.util.spec_from_file_location('profile', Path(__file__).parents[1] / 'host-memory-profile.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class Fixture(p.Host):
    def __init__(self, root):
        self.calls = []
        super().__init__(root, self.command)
        for path, value in {
            p.THP: 'always [madvise] never', p.KSM + 'run': '0',
            p.KSM + 'pages_shared': '0', p.KSM + 'pages_sharing': '0',
            p.KSM + 'pages_to_scan': '200', p.KSM + 'sleep_millisecs': '20',
            p.ZSWAP + 'enabled': '0', p.ZSWAP + 'max_pool_percent': '10',
            p.MGLRU: '0x0007', '/sys/block/zram0/disksize': '0',
            '/sys/block/zram0/reset': '0',
            '/proc/swaps': 'Filename Type Size Used Priority\n/operator file 1024 0 -2\n',
        }.items():
            self.path(path).parent.mkdir(parents=True, exist_ok=True)
            self.write(path, value)

    def nvme(self, path):
        if path != '/dev/nvme0n1p1':
            raise p.ProfileError('nvme_swap_not_on_nvme')

    def write(self, path, value):
        super().write(path, value)
        if path == '/sys/block/zram0/reset' and str(value) == '1':
            super().write('/sys/block/zram0/disksize', 0)

    def command(self, args):
        self.calls.append(args)
        if args[0] == 'blkid':
            return 'strato-density'
        if args[0] == 'swapon':
            self.write('/proc/swaps', self.read('/proc/swaps') + f'\n{args[-1]} partition 1024 0 {args[2]}')
        elif args[0] == 'swapoff':
            self.write('/proc/swaps', '\n'.join(line for line in self.read('/proc/swaps').splitlines()
                                               if not line.startswith(args[1] + ' ')))
        return ''


class Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.host = Fixture(self.temp.name)
        self.config = {'tier': 'zram', 'tenant_class': 'multi', 'nvme_swap': '/dev/nvme0n1p1'}

    def test_idempotent_and_reboot(self):
        p.apply(self.host, self.config)
        first = list(self.host.calls)
        p.apply(self.host, self.config)
        self.assertEqual([c for c in first if c[0] != 'blkid'],
                         [c for c in self.host.calls if c[0] != 'blkid'])
        swaps = self.host.swaps()
        self.assertGreater(swaps['/dev/zram0'], swaps[self.config['nvme_swap']])
        self.host.write('/proc/swaps', 'Filename Type Size Used Priority\n/operator file 1024 0 -2')
        self.host.write('/sys/block/zram0/disksize', 0)
        self.host.write(p.THP, 'always [madvise] never')
        p.apply(self.host, self.config)
        self.assertEqual(self.host.read(p.THP), 'madvise')
        self.assertIn('/dev/zram0', self.host.swaps())

    def test_rollback_preserves_operator_swap(self):
        p.apply(self.host, self.config)
        p.disable(self.host)
        self.assertEqual(self.host.swaps(), {'/operator': -2})
        self.assertEqual(self.host.read(p.ZSWAP + 'enabled'), '0')
        self.assertEqual(self.host.read(p.KSM + 'run'), '0')
        self.assertFalse(any(call[0] in ('rm', 'wipefs') for call in self.host.calls))
        p.disable(self.host)

    def test_preexisting_fallback_stays_active(self):
        self.host.command(['swapon', '--priority', '10', self.config['nvme_swap']])
        p.apply(self.host, self.config)
        p.disable(self.host)
        self.assertIn(self.config['nvme_swap'], self.host.swaps())

    def test_unsupported_fail_before_mutation(self):
        for missing in (p.THP, p.KSM + 'run', '/sys/block/zram0/disksize'):
            host = Fixture(self.temp.name)
            host.path(missing).unlink()
            with self.assertRaises(p.ProfileError):
                p.apply(host, self.config)
            self.assertEqual(host.calls, [])
            self.assertFalse(host.path(p.STATE).exists())

    def test_zram_without_zswap_and_unsupported_zswap(self):
        self.host.path(p.ZSWAP + 'enabled').unlink()
        p.apply(self.host, self.config)
        self.assertIn('/dev/zram0', self.host.swaps())
        p.disable(self.host)
        self.config['tier'] = 'zswap'
        self.host.write(p.THP, 'always [madvise] never')
        with self.assertRaisesRegex(p.ProfileError, 'unsupported:'):
            p.apply(self.host, self.config)

    def test_disabled_mglru_and_secondary_bits(self):
        self.config['require_mglru'] = True
        for enabled in ('0', '0x0006'):
            self.host.write(p.MGLRU, enabled)
            with self.assertRaisesRegex(p.ProfileError, 'mglru_disabled'):
                p.apply(self.host, self.config)

    def test_ksm_tenant_policy_and_bounded_scanner(self):
        self.config['ksm'] = True
        with self.assertRaisesRegex(p.ProfileError, 'ksm_multitenant_forbidden'):
            p.apply(self.host, self.config)
        self.config['tenant_class'] = 'single'
        self.config['ksm_pages_to_scan'] = 1001
        with self.assertRaisesRegex(p.ProfileError, 'invalid_ksm_pages_to_scan'):
            p.apply(self.host, self.config)
        self.config['ksm_pages_to_scan'] = 100
        p.apply(self.host, self.config)
        self.assertEqual(self.host.read(p.KSM + 'run'), '1')
        self.assertEqual(self.host.read(p.KSM + 'sleep_millisecs'), '100')
        self.host.write(p.KSM + 'pages_sharing', 2)
        with self.assertRaisesRegex(p.ProfileError, 'ksm_unmerge_pending'):
            p.disable(self.host)
        self.assertTrue(self.host.path(p.STATE).exists())
        self.assertEqual(self.host.read(p.KSM + 'run'), '2')
        self.host.write(p.KSM + 'pages_sharing', 0)
        p.disable(self.host)
        self.config.update(tenant_class='multi', ksm=False)
        self.host.write(p.THP, 'always [madvise] never')
        p.apply(self.host, self.config)
        self.assertEqual(self.host.read(p.KSM + 'run'), '0')

    def test_operator_zram_and_priority_conflicts(self):
        self.host.write('/sys/block/zram0/disksize', 100)
        with self.assertRaisesRegex(p.ProfileError, 'operator_zram_in_use'):
            p.apply(self.host, self.config)
        self.host.write('/sys/block/zram0/disksize', 0)
        self.host.command(['swapon', '--priority', '100', '/operator-high'])
        with self.assertRaisesRegex(p.ProfileError, 'operator_swap_priority_conflict'):
            p.apply(self.host, self.config)

    def test_bootstrap_persistence_and_profile_change_guard(self):
        tool = Path(__file__).parents[1] / 'host-memory-profile.py'
        p.install_profile(self.host, self.config, tool)
        baseline = self.host.load(p.STATE)
        p.install_profile(self.host, self.config, tool)
        self.assertEqual(baseline, self.host.load(p.STATE))
        self.assertEqual(self.host.load(p.CONFIG), self.config)
        self.assertEqual(self.host.read('/etc/modules-load.d/strato-host-memory-profile.conf'), 'zram')
        self.assertIn('Before=strato-agent.service',
                      self.host.read('/etc/systemd/system/strato-host-memory-profile.service'))
        changed = dict(self.config, tenant_class='single')
        with self.assertRaisesRegex(p.ProfileError, 'profile_change_requires_disable'):
            p.install_profile(self.host, changed, tool)
        self.assertEqual(self.host.load(p.CONFIG), self.config)
        p.disable(self.host)
        self.assertFalse(self.host.path(p.CONFIG).exists())
        self.assertFalse(self.host.path('/etc/modules-load.d/strato-host-memory-profile.conf').exists())

    def test_nvme_provenance_and_signature(self):
        host = p.Host(self.temp.name, lambda args: '/dev/nvme0n1p1' if args[0] == 'findmnt' else 'swap')
        host.path('/swap-file').write_text('fixture')
        host.nvme('/swap-file')
        host.runner = lambda args: '/dev/sda' if args[0] == 'findmnt' else 'swap'
        with self.assertRaisesRegex(p.ProfileError, 'not_on_nvme'):
            host.nvme('/swap-file')
        host.runner = lambda args: '/dev/nvme0n1p1' if args[0] == 'findmnt' else 'ext4'
        with self.assertRaisesRegex(p.ProfileError, 'not_prepared'):
            host.nvme('/swap-file')

    def test_rollback_refuses_replaced_operator_zram(self):
        p.apply(self.host, self.config)
        original = self.host.runner
        self.host.runner = lambda args: 'operator' if args[0] == 'blkid' else original(args)
        with self.assertRaisesRegex(p.ProfileError, 'operator_zram_in_use'):
            p.disable(self.host)
        self.assertIn('/dev/zram0', self.host.swaps())
        self.assertTrue(self.host.path(p.STATE).exists())

    def test_partial_failure_can_be_rolled_back(self):
        original = self.host.runner
        def fail(args):
            if args[0] == 'swapon' and args[-1] == self.config['nvme_swap']:
                raise p.ProfileError('injected_swap_activation_failure')
            return original(args)
        self.host.runner = fail
        with self.assertRaisesRegex(p.ProfileError, 'injected'):
            p.apply(self.host, self.config)
        self.assertTrue(self.host.path(p.STATE).exists())
        self.host.runner = original
        p.disable(self.host)
        self.assertEqual(self.host.swaps(), {'/operator': -2})

    def test_zswap_and_failure_recovery(self):
        self.config['tier'] = 'zswap'
        p.apply(self.host, self.config)
        self.assertEqual(self.host.read(p.ZSWAP + 'enabled'), '1')
        self.assertEqual(self.host.read(p.ZSWAP + 'max_pool_percent'), '20')
        p.apply(self.host, self.config)
        p.disable(self.host)
        self.assertEqual(self.host.read(p.ZSWAP + 'max_pool_percent'), '10')


if __name__ == '__main__':
    unittest.main()
