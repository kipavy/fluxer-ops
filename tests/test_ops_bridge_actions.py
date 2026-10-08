"""The bridge's allowlist: what each panel action may run, and what it refuses."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import ops_bridge as ob  # noqa: E402

OPS = '/ops'


def argv(name, **args):
    return ob.build_argv(name, args, ops=OPS)


class BuildArgv(unittest.TestCase):
    def test_gifts_create(self):
        self.assertEqual(argv('gifts.create', duration='1w', count=3),
                         ['/ops/gifts.sh', 'create', '--duration', '1w', '--count', '3'])

    def test_gifts_create_defaults_to_one(self):
        self.assertEqual(argv('gifts.create', duration='lifetime'),
                         ['/ops/gifts.sh', 'create', '--duration', 'lifetime', '--count', '1'])

    def test_gifts_list_filters(self):
        self.assertEqual(argv('gifts.list'), ['/ops/gifts.sh', 'list'])
        self.assertEqual(argv('gifts.list', filter='all'), ['/ops/gifts.sh', 'list'])
        self.assertEqual(argv('gifts.list', filter='revoked'), ['/ops/gifts.sh', 'list', '--revoked'])

    def test_code_actions(self):
        code = 'A1' * 16
        self.assertEqual(argv('gifts.show', code=code), ['/ops/gifts.sh', 'show', code])
        self.assertEqual(argv('gifts.revoke', code=code), ['/ops/gifts.sh', 'revoke', code])
        self.assertEqual(argv('gifts.rm', code=code), ['/ops/gifts.sh', 'rm', code])
        self.assertEqual(argv('gifts.redeem', code=code, user='bob#0042'),
                         ['/ops/gifts.sh', 'redeem', code, 'bob#0042'])

    def test_setup_lifetime(self):
        self.assertEqual(argv('gifts.setup-lifetime', community='1521090864246423552'),
                         ['/ops/gifts.sh', 'setup-lifetime', '--community', '1521090864246423552'])

    def test_premium(self):
        self.assertEqual(argv('premium.grant', user='bob'), ['/ops/premium.sh', 'bob'])
        self.assertEqual(argv('premium.grant', user='bob', kind='lifetime'), ['/ops/premium.sh', 'bob'])
        self.assertEqual(argv('premium.grant', user='bob', kind='subscriber'),
                         ['/ops/premium.sh', 'bob', '--subscriber'])
        self.assertEqual(argv('premium.grant', user='bob', kind='duration', duration='3m'),
                         ['/ops/premium.sh', 'bob', '--duration', '3m'])
        self.assertEqual(argv('premium.revoke', user='bob'), ['/ops/premium.sh', 'bob', '--off'])
        self.assertEqual(argv('premium.list'), ['/ops/premium.sh', '--list'])

    def test_users(self):
        self.assertEqual(argv('users.list'), ['/ops/users.sh', 'list', '--recent', '20'])
        self.assertEqual(argv('users.list', recent=200), ['/ops/users.sh', 'list', '--recent', '200'])
        self.assertEqual(argv('users.show', user='bob.smith_1-2'), ['/ops/users.sh', 'show', 'bob.smith_1-2'])
        self.assertEqual(argv('users.stats'), ['/ops/users.sh', 'stats'])
        self.assertEqual(argv('users.staff', user='bob'), ['/ops/users.sh', 'staff', 'bob'])
        self.assertEqual(argv('users.staff', user='bob', off=True), ['/ops/users.sh', 'staff', 'bob', '--off'])
        self.assertEqual(argv('users.verify-email', user='bob'), ['/ops/users.sh', 'verify-email', 'bob'])

    def test_health(self):
        self.assertEqual(argv('health.status'), ['/ops/fluxer', 'status', '--json'])
        self.assertEqual(argv('health.check'), ['/ops/fluxer', 'check'])
        self.assertEqual(argv('health.doctor'), ['/ops/fluxer', 'doctor', '--quiet'])
        self.assertEqual(argv('health.errors'), ['/ops/fluxer', 'errors', '--since', '1h'])
        self.assertEqual(argv('health.disk'), ['/ops/fluxer', 'disk', '--json'])
        self.assertEqual(argv('health.backups'), ['/ops/fluxer', 'backups'])

    def test_write_actions_are_exactly_these(self):
        writes = {n for n, a in ob.ACTIONS.items() if a.write}
        self.assertEqual(writes, {
            'gifts.create', 'gifts.revoke', 'gifts.rm', 'gifts.redeem', 'gifts.setup-lifetime',
            'premium.grant', 'premium.revoke', 'users.staff', 'users.verify-email'})

    def test_timeouts(self):
        self.assertEqual(ob.ACTIONS['health.check'].timeout, 300)
        self.assertEqual(ob.ACTIONS['health.doctor'].timeout, 300)
        self.assertEqual(ob.ACTIONS['gifts.setup-lifetime'].timeout, 120)
        self.assertEqual(ob.ACTIONS['gifts.list'].timeout, 60)


class Refusals(unittest.TestCase):
    def bad(self, name, **args):
        with self.assertRaises(ob.BadRequest):
            argv(name, **args)

    def test_unknown_action(self):
        self.bad('gifts.nuke')
        self.bad('restore')

    def test_unknown_key(self):
        self.bad('gifts.list', filter='all', extra='x')
        self.bad('users.show', user='bob', reveal=True)

    def test_args_must_be_an_object(self):
        with self.assertRaises(ob.BadRequest):
            ob.build_argv('gifts.list', ['--revoked'], ops=OPS)

    def test_duration_patterns(self):
        for d in ('0d', '1h', '99999d', '1w; rm -rf /', '$(id)', '1w\n', '', None, 5, 'Lifetime'):
            self.bad('gifts.create', duration=d)

    def test_count_bounds(self):
        for c in (0, 51, '3', True, 1.5, None):
            self.bad('gifts.create', duration='1w', count=c)

    def test_code_patterns(self):
        for c in ('A' * 31, 'A' * 33, 'A' * 31 + '-', 'A' * 32 + '\n', '', None):
            self.bad('gifts.show', code=c)

    def test_user_cannot_be_a_flag(self):
        for u in ('--off', '-x', '--list', '--subscriber', '-'):
            self.bad('premium.grant', user=u)
            self.bad('users.staff', user=u)

    def test_user_patterns(self):
        for u in ('a b', 'a;b', 'é', 'x' * 33, 'bob#12345', 'bob#', 'bob\n', '$(id)', '', None, 7):
            self.bad('users.show', user=u)

    def test_premium_kinds(self):
        self.bad('premium.grant', user='bob', kind='gift')
        self.bad('premium.grant', user='bob', kind='duration')
        self.bad('premium.grant', user='bob', kind='duration', duration='lifetime')

    def test_flags_must_be_booleans(self):
        self.bad('users.staff', user='bob', off='yes')

    def test_recent_bounds(self):
        self.bad('users.list', recent=0)
        self.bad('users.list', recent=201)

    def test_community_patterns(self):
        for c in ('Racelards Land', '12a', '1' * 21, '', None):
            self.bad('gifts.setup-lifetime', community=c)


class CommunityChoices(unittest.TestCase):
    STDERR = (
        'Lifetime links are not set up on this instance yet; setting them up first.\n'
        'gifts: this instance has several communities; say which one with --community:\n'
        '  Racelards Land  (1521090864246423552)\n'
        '  Test  (42)\n'
    )

    def test_parsed(self):
        self.assertEqual(ob.parse_community_choices(self.STDERR), [
            {'name': 'Racelards Land', 'id': '1521090864246423552'},
            {'name': 'Test', 'id': '42'},
        ])

    def test_other_errors_are_not_choices(self):
        self.assertIsNone(ob.parse_community_choices('gifts: no community yet\n'))
        self.assertIsNone(ob.parse_community_choices(''))


if __name__ == '__main__':
    unittest.main()
