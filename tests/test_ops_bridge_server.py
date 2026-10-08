"""The bridge's runtime: who may run what, and the transport. No api, no database."""
import http.client
import json
import os
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import ops_bridge as ob  # noqa: E402

DOMAIN = 'chat.example.test'
ORIGIN = 'https://' + DOMAIN
STAFF = {'id': '1', 'username': 'boss'}
PLEB = {'id': '2', 'username': 'pleb'}


class FakeIdentity:
    def __init__(self, error=None):
        self.users = {'tok-staff': STAFF, 'tok-pleb': PLEB}
        self.calls = []
        self.error = error

    def whoami(self, token, fresh=False):
        self.calls.append(('whoami', token, fresh))
        if self.error:
            raise self.error
        return self.users.get(token)

    def is_staff(self, user_id):
        self.calls.append(('is_staff', user_id))
        return user_id == '1'


def ok_run(argv, timeout):
    return {'exit': 0, 'stdout': 'ok\n', 'stderr': '', 'timed_out': False}


class Harness:
    def __init__(self, run=ok_run, limiter=None, identity=None):
        self.identity = identity or FakeIdentity()
        self.ran = []
        self.audits = []

        def recording_run(argv, timeout):
            self.ran.append((argv, timeout))
            return run(argv, timeout)

        self.bridge = ob.Bridge(self.identity, DOMAIN, ops='/ops', run=recording_run,
                                audit=lambda *a: self.audits.append(a), limiter=limiter)

    def post(self, body, token='tok-staff', origin=ORIGIN, raw=None):
        headers = {}
        if token is not None:
            headers['Authorization'] = token
        if origin is not None:
            headers['Origin'] = origin
        data = raw if raw is not None else json.dumps(body).encode()
        return self.bridge.handle('POST', '/run', headers, data)


class Auth(unittest.TestCase):
    def test_health_needs_nothing(self):
        self.assertEqual(Harness().bridge.handle('GET', '/health', {}, b''), (200, {'ok': True}))

    def test_no_token_401(self):
        h = Harness()
        status, _ = h.post({'action': 'gifts.list'}, token=None)
        self.assertEqual(status, 401)
        self.assertEqual(h.ran, [])

    def test_unknown_token_401_message(self):
        h = Harness()
        status, payload = h.post({'action': 'gifts.list'}, token='tok-expired')
        self.assertEqual(status, 401)
        self.assertIn('reload', payload['error'])
        self.assertEqual(h.ran, [])

    def test_token_with_control_characters_401(self):
        h = Harness()
        status, _ = h.post({'action': 'gifts.list'}, token='tok\r\nX-Evil: 1')
        self.assertEqual(status, 401)
        self.assertEqual(h.identity.calls, [])

    def test_not_staff_403(self):
        h = Harness()
        status, _ = h.post({'action': 'gifts.list'}, token='tok-pleb')
        self.assertEqual(status, 403)
        self.assertEqual(h.ran, [])

    def test_foreign_origin_403_before_identity(self):
        h = Harness()
        status, _ = h.post({'action': 'gifts.list'}, origin='https://evil.test')
        self.assertEqual(status, 403)
        self.assertEqual(h.identity.calls, [])

    def test_no_origin_is_fine(self):
        self.assertEqual(Harness().post({'action': 'gifts.list'}, origin=None)[0], 200)

    def test_upstream_down_502(self):
        h = Harness(identity=FakeIdentity(error=ob.UpstreamError('api unreachable')))
        status, payload = h.post({'action': 'gifts.list'})
        self.assertEqual(status, 502)
        self.assertIn('api unreachable', payload['error'])


class Requests(unittest.TestCase):
    def test_unknown_action_400_after_auth(self):
        h = Harness()
        self.assertEqual(h.post({'action': 'restore'})[0], 400)
        self.assertEqual(h.post({'action': 'restore'}, token='tok-pleb')[0], 403)

    def test_bad_args_400(self):
        h = Harness()
        status, payload = h.post({'action': 'users.show', 'args': {'user': '--off'}})
        self.assertEqual(status, 400)
        self.assertIn('user', payload['error'])
        self.assertEqual(h.ran, [])

    def test_malformed_bodies_400(self):
        h = Harness()
        self.assertEqual(h.post(None, raw=b'{not json')[0], 400)
        self.assertEqual(h.post(None, raw=b'\xff\xfe')[0], 400)
        self.assertEqual(h.post(['gifts.list'])[0], 400)
        self.assertEqual(h.post({'args': {}})[0], 400)

    def test_methods_and_paths(self):
        b = Harness().bridge
        self.assertEqual(b.handle('GET', '/run', {'Authorization': 'tok-staff'}, b'')[0], 405)
        self.assertEqual(b.handle('POST', '/whoami', {'Authorization': 'tok-staff'}, b'')[0], 405)
        self.assertEqual(b.handle('GET', '/etc/passwd', {}, b'')[0], 404)

    def test_read_runs_without_audit_or_fresh_identity(self):
        h = Harness()
        status, payload = h.post({'action': 'gifts.list', 'args': {'filter': 'revoked'}})
        self.assertEqual(status, 200)
        self.assertEqual(payload['action'], 'gifts.list')
        self.assertEqual(payload['exit'], 0)
        self.assertEqual(h.ran, [(['/ops/gifts.sh', 'list', '--revoked'], 60)])
        self.assertEqual(h.audits, [])
        self.assertIn(('whoami', 'tok-staff', False), h.identity.calls)

    def test_write_is_audited_with_fresh_identity(self):
        h = Harness()
        status, _ = h.post({'action': 'gifts.create', 'args': {'duration': '1w', 'count': 2}})
        self.assertEqual(status, 200)
        self.assertIn(('whoami', 'tok-staff', True), h.identity.calls)
        self.assertEqual(len(h.audits), 1)
        user, name, args, result = h.audits[0]
        self.assertEqual((user, name, args, result['exit']), (STAFF, 'gifts.create', {'duration': '1w', 'count': 2}, 0))

    def test_staff_is_checked_on_every_request(self):
        h = Harness()
        h.post({'action': 'gifts.list'})
        h.post({'action': 'gifts.list'})
        self.assertEqual([c for c in h.identity.calls if c[0] == 'is_staff'], [('is_staff', '1')] * 2)

    def test_doctor_gets_its_long_timeout(self):
        h = Harness()
        h.post({'action': 'health.doctor'})
        self.assertEqual(h.ran[0][1], 300)

    def test_lifetime_choices_are_returned(self):
        stderr = ('gifts: this instance has several communities; say which one with --community:\n'
                  '  Racelards Land  (1521090864246423552)\n')
        h = Harness(run=lambda argv, t: {'exit': 1, 'stdout': '', 'stderr': stderr, 'timed_out': False})
        status, payload = h.post({'action': 'gifts.create', 'args': {'duration': 'lifetime'}})
        self.assertEqual(status, 200)
        self.assertEqual(payload['choices'], [{'name': 'Racelards Land', 'id': '1521090864246423552'}])

    def test_whoami(self):
        b = Harness().bridge
        self.assertEqual(b.handle('GET', '/whoami', {'Authorization': 'tok-staff'}, b''),
                         (200, {'id': '1', 'username': 'boss', 'staff': True}))
        self.assertEqual(b.handle('GET', '/whoami', {'Authorization': 'tok-pleb'}, b''),
                         (200, {'id': '2', 'username': 'pleb', 'staff': False}))
        self.assertEqual(b.handle('GET', '/whoami', {'Authorization': 'nope'}, b'')[0], 401)


class Limits(unittest.TestCase):
    def test_rate_limiter_window(self):
        now = [0.0]
        rl = ob.RateLimiter(limit=2, window=60.0, clock=lambda: now[0])
        self.assertTrue(rl.allow('1'))
        self.assertTrue(rl.allow('1'))
        self.assertFalse(rl.allow('1'))
        self.assertTrue(rl.allow('2'))
        now[0] = 61.0
        self.assertTrue(rl.allow('1'))

    def test_writes_limited_reads_not(self):
        h = Harness(limiter=ob.RateLimiter(limit=1))
        self.assertEqual(h.post({'action': 'users.verify-email', 'args': {'user': 'bob'}})[0], 200)
        self.assertEqual(h.post({'action': 'users.verify-email', 'args': {'user': 'bob'}})[0], 429)
        self.assertEqual(h.post({'action': 'gifts.list'})[0], 200)


class Identity(unittest.TestCase):
    def make(self, answers, psql_out='1\n'):
        self.fetched = []
        now = [0.0]
        self.now = now

        def fetch(token):
            self.fetched.append(token)
            return answers.pop(0)

        return ob.Identity(DOMAIN, fetch=fetch, psql=lambda sql, v: psql_out, clock=lambda: now[0])

    def test_whoami_parses_and_caches(self):
        ident = self.make([(200, b'{"id": "1521", "username": "boss", "flags": 1}')] * 3)
        self.assertEqual(ident.whoami('t'), {'id': '1521', 'username': 'boss'})
        self.assertEqual(ident.whoami('t'), {'id': '1521', 'username': 'boss'})
        self.assertEqual(len(self.fetched), 1)
        ident.whoami('t', fresh=True)
        self.assertEqual(len(self.fetched), 2)
        self.now[0] = 61.0
        ident.whoami('t')
        self.assertEqual(len(self.fetched), 3)

    def test_rejected_token_is_none_and_not_cached(self):
        ident = self.make([(401, b'{}'), (401, b'{}')])
        self.assertIsNone(ident.whoami('t'))
        self.assertIsNone(ident.whoami('t'))
        self.assertEqual(len(self.fetched), 2)

    def test_odd_answers_are_upstream_errors(self):
        for answer in ((500, b''), (200, b'not json'), (200, b'{"username": "x"}'), (200, b'{"id": "12; drop"}')):
            ident = self.make([answer])
            with self.assertRaises(ob.UpstreamError):
                ident.whoami('t')

    def test_is_staff(self):
        self.assertTrue(self.make([], psql_out='1\n').is_staff('1521'))
        self.assertFalse(self.make([], psql_out='0\n').is_staff('1521'))
        self.assertFalse(self.make([], psql_out='').is_staff('1521'))
        self.assertFalse(self.make([], psql_out='1\n').is_staff("1' or '1'='1"))


class Runner(unittest.TestCase):
    def test_exit_and_streams(self):
        r = ob.run_script(['sh', '-c', 'echo out; echo err >&2; exit 3'], 10)
        self.assertEqual((r['exit'], r['stdout'], r['stderr'], r['timed_out']), (3, 'out\n', 'err\n', False))

    def test_stdin_is_empty(self):
        start = time.monotonic()
        r = ob.run_script(['sh', '-c', 'read x || true; echo "got:$x"'], 10)
        self.assertEqual(r['stdout'], 'got:\n')
        self.assertLess(time.monotonic() - start, 5)

    def test_timeout_kills_the_whole_group(self):
        start = time.monotonic()
        r = ob.run_script(['sh', '-c', 'sleep 30 & wait'], 0.5)
        self.assertTrue(r['timed_out'])
        self.assertEqual(r['exit'], 124)
        self.assertLess(time.monotonic() - start, 5)

    def test_missing_script(self):
        self.assertEqual(ob.run_script(['/nonexistent/gifts.sh'], 5)['exit'], 127)


class UnixConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__('bridge', timeout=10)
        self.unix_path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.unix_path)


class Transport(unittest.TestCase):
    def test_stub_script_sees_exact_argv(self):
        with tempfile.TemporaryDirectory() as tmp:
            stub = os.path.join(tmp, 'gifts.sh')
            with open(stub, 'w') as f:
                f.write('#!/bin/sh\nprintf "[%s]\\n" "$@"\n')
            os.chmod(stub, 0o755)
            bridge = ob.Bridge(FakeIdentity(), DOMAIN, ops=tmp, audit=lambda *a: None)
            path = os.path.join(tmp, 'bridge.sock')
            srv = ob.serve(path, bridge)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            try:
                self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o660)
                conn = UnixConnection(path)
                body = json.dumps({'action': 'gifts.redeem', 'args': {'code': 'A' * 32, 'user': 'bob#0042'}})
                conn.request('POST', '/run', body=body,
                             headers={'Authorization': 'tok-staff', 'Origin': ORIGIN, 'Content-Type': 'application/json'})
                resp = conn.getresponse()
                payload = json.loads(resp.read())
                self.assertEqual(resp.status, 200)
                self.assertEqual(resp.getheader('Cache-Control'), 'no-store')
                self.assertEqual(payload['stdout'], '[redeem]\n[' + 'A' * 32 + ']\n[bob#0042]\n')
                conn.close()
            finally:
                srv.shutdown()
                srv.server_close()


if __name__ == '__main__':
    unittest.main()
