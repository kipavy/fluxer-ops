#!/usr/bin/env python3
"""ops_bridge.py - runs allowlisted fluxer-ops commands for the in-app STAFF Ops panel.

Caddy (the edge container) forwards /ops-api/* here over a Unix socket. Each request
carries the caller's Fluxer session token. The bridge asks the api who that is, checks
the STAFF flag in the database, and runs one script from ACTIONS with a fixed argv.
There is no business logic here: every rule about gifts, premium and users stays in
the scripts, which are also what `fluxer` and cron run.

Stdlib only, so it runs on the host's python3 with nothing installed. See panel.sh for
how it is installed, and docs/superpowers/specs/2026-10-08-staff-ops-panel-design.md
for why it is shaped this way.
"""
import argparse
import hashlib
import http.client
import http.server
import json
import logging
import os
import re
import signal
import socket
import socketserver
import ssl
import subprocess
import sys
import threading
import time
from collections import deque
from dataclasses import dataclass
from typing import Callable

OPS = os.path.dirname(os.path.realpath(__file__))


class BadRequest(Exception):
    """The request names no allowlisted action, or an argument is not acceptable."""


# fullmatch everywhere: with match() or search(), '$' also matches before a trailing
# newline, and '1w\n' would pass.
DURATION = re.compile(r'[1-9][0-9]{0,3}[dwmy]|lifetime')
CODE = re.compile(r'[A-Za-z0-9]{32}')
# What the scripts take: a username, or username#tag when the name is shared. The first
# character is never '-', so a "user" can never be read as an option like --off.
USER = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,31}(?:#[0-9]{1,4})?')
COMMUNITY = re.compile(r'[0-9]{1,20}')


def _text(args, key, pattern):
    value = args.get(key)
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise BadRequest(f'{key}: not an acceptable value')
    return value


def _number(args, key, low, high, default):
    value = args.get(key, default)
    # bool is an int in Python; True must not pass as 1.
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise BadRequest(f'{key}: a whole number from {low} to {high}')
    return value


def _choice(args, key, choices, default):
    value = args.get(key, default)
    if value not in choices:
        raise BadRequest(f'{key}: one of {", ".join(choices)}')
    return value


def _flag(args, key):
    value = args.get(key, False)
    if not isinstance(value, bool):
        raise BadRequest(f'{key}: true or false')
    return value


@dataclass(frozen=True)
class Action:
    script: str
    build: Callable[[dict], list]
    keys: frozenset
    write: bool
    timeout: int = 60


def _gifts_list(a):
    which = _choice(a, 'filter', ('all', 'unredeemed', 'redeemed', 'revoked'), 'all')
    return ['list'] if which == 'all' else ['list', f'--{which}']


def _premium_grant(a):
    user = _text(a, 'user', USER)
    kind = _choice(a, 'kind', ('lifetime', 'duration', 'subscriber'), 'lifetime')
    if kind == 'subscriber':
        return [user, '--subscriber']
    if kind == 'duration':
        duration = _text(a, 'duration', DURATION)
        if duration == 'lifetime':
            raise BadRequest('duration: use kind "lifetime" for a lifetime grant')
        return [user, '--duration', duration]
    return [user]


def _a(script, build, keys=(), write=False, timeout=60):
    return Action(script, build, frozenset(keys), write, timeout)


ACTIONS = {
    'gifts.create': _a('gifts.sh', lambda a: [
        'create', '--duration', _text(a, 'duration', DURATION),
        '--count', str(_number(a, 'count', 1, 50, 1))], ('duration', 'count'), write=True),
    'gifts.list': _a('gifts.sh', _gifts_list, ('filter',)),
    'gifts.show': _a('gifts.sh', lambda a: ['show', _text(a, 'code', CODE)], ('code',)),
    'gifts.revoke': _a('gifts.sh', lambda a: ['revoke', _text(a, 'code', CODE)], ('code',), write=True),
    'gifts.rm': _a('gifts.sh', lambda a: ['rm', _text(a, 'code', CODE)], ('code',), write=True),
    'gifts.redeem': _a('gifts.sh', lambda a: [
        'redeem', _text(a, 'code', CODE), _text(a, 'user', USER)], ('code', 'user'), write=True),
    # Only reached from the panel's lifetime flow, when gifts.create lists communities.
    'gifts.setup-lifetime': _a('gifts.sh', lambda a: [
        'setup-lifetime', '--community', _text(a, 'community', COMMUNITY)], ('community',),
        write=True, timeout=120),
    'premium.grant': _a('premium.sh', _premium_grant, ('user', 'kind', 'duration'), write=True),
    'premium.revoke': _a('premium.sh', lambda a: [_text(a, 'user', USER), '--off'], ('user',), write=True),
    'premium.list': _a('premium.sh', lambda a: ['--list']),
    'users.list': _a('users.sh', lambda a: ['list', '--recent', str(_number(a, 'recent', 1, 200, 20))],
                     ('recent',)),
    'users.show': _a('users.sh', lambda a: ['show', _text(a, 'user', USER)], ('user',)),
    'users.stats': _a('users.sh', lambda a: ['stats']),
    'users.staff': _a('users.sh', lambda a: ['staff', _text(a, 'user', USER)] + (['--off'] if _flag(a, 'off') else []),
                      ('user', 'off'), write=True),
    'users.verify-email': _a('users.sh', lambda a: ['verify-email', _text(a, 'user', USER)], ('user',), write=True),
    'health.status': _a('fluxer', lambda a: ['status', '--json']),
    'health.check': _a('fluxer', lambda a: ['check'], timeout=300),
    'health.doctor': _a('fluxer', lambda a: ['doctor', '--quiet'], timeout=300),
    'health.errors': _a('fluxer', lambda a: ['errors', '--since', '1h']),
    'health.disk': _a('fluxer', lambda a: ['disk', '--json']),
    'health.backups': _a('fluxer', lambda a: ['backups']),
}


def build_argv(name, args, ops=OPS):
    """The exact argv for one panel action, or BadRequest. Never a shell string."""
    action = ACTIONS.get(name)
    if action is None:
        raise BadRequest(f'unknown action: {name}')
    if not isinstance(args, dict):
        raise BadRequest('args must be an object')
    extra = set(args) - action.keys
    if extra:
        raise BadRequest('unexpected argument(s): ' + ', '.join(sorted(extra)))
    return [os.path.join(ops, action.script)] + action.build(args)


# gifts.sh setup-lifetime, reached through `create --duration lifetime`, answers this
# way when the instance has several communities and none was named.
_CHOICES_HEAD = 'this instance has several communities; say which one with --community:'
_CHOICE_LINE = re.compile(r'  (.+)  \(([0-9]{1,20})\)')


def parse_community_choices(stderr):
    """The communities gifts.sh listed, or None if this is any other failure."""
    lines = stderr.splitlines()
    for i, line in enumerate(lines):
        if line.endswith(_CHOICES_HEAD):
            found = []
            for following in lines[i + 1:]:
                m = _CHOICE_LINE.fullmatch(following)
                if not m:
                    break
                found.append({'name': m.group(1), 'id': m.group(2)})
            return found or None
    return None


log = logging.getLogger('ops-bridge')

MAX_OUTPUT = 200_000
MAX_BODY = 64 * 1024
# A Fluxer session token as the app sends it: printable ASCII, no spaces or line
# breaks, so it can never smuggle a header into the request to the api.
TOKEN = re.compile(r'[\x21-\x7e]{1,512}')
SNOWFLAKE = re.compile(r'[0-9]{1,20}')
NO_SESSION = 'No Fluxer session: reload the web app, then try again.'
TOO_MANY = {'error': 'too many requests; wait a little'}
MAX_CONCURRENT = 8


class UpstreamError(Exception):
    """The api or the database could not answer the identity or STAFF question."""


def run_script(argv, timeout):
    """Run one allowlisted command: no shell, empty stdin, the whole group killed on timeout."""
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, start_new_session=True,
                                text=True, encoding='utf-8', errors='replace')
    except OSError as e:
        return {'exit': 127, 'stdout': '', 'stderr': f'cannot start {argv[0]}: {e}', 'timed_out': False}
    try:
        out, err = proc.communicate(timeout=timeout)
        code, timed_out = proc.returncode, False
    except subprocess.TimeoutExpired:
        # The scripts start docker and psql children; killing only the shell would
        # leave them holding the pipes open.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass  # it finished between the timeout and the kill
        out, err = proc.communicate()
        code, timed_out = 124, True
        err += f'\n(stopped after {timeout:g} s)\n'
    return {'exit': code, 'stdout': out[-MAX_OUTPUT:], 'stderr': err[-MAX_OUTPUT:], 'timed_out': timed_out}


class RateLimiter:
    """At most `limit` events per `window` seconds per key, in memory."""

    def __init__(self, limit=30, window=60.0, clock=time.monotonic):
        self.limit, self.window, self.clock = limit, window, clock
        self._events = {}
        self._lock = threading.Lock()

    def allow(self, key):
        now = self.clock()
        with self._lock:
            q = self._events.setdefault(key, deque())
            while q and q[0] <= now - self.window:
                q.popleft()
            if len(q) >= self.limit:
                return False
            q.append(now)
            return True


class _EdgeConnection(http.client.HTTPSConnection):
    """HTTPS to this host's own edge, with the public name for SNI and certificate
    checks: the identity question must not go out through Cloudflare and back."""

    def __init__(self, domain, address, timeout):
        super().__init__(domain, 443, timeout=timeout, context=ssl.create_default_context())
        self._address = address

    def connect(self):
        sock = socket.create_connection(self._address, self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


# flags read exactly as users.sh reads them: written as a bigint object, tolerated as
# a bare number or string. Bit 0 is STAFF (UserFlags, packages/constants).
STAFF_SQL = """
select coalesce(case jsonb_typeof(row_data->'flags')
	when 'object' then row_data->'flags'->>'value'
	when 'number' then row_data->>'flags'
	when 'string' then row_data->>'flags' end, '0')::bigint & 1
from fluxer_kv
where table_name = 'users' and (row_data->'user_id'->>'value') = :'id'
	and (expires_at is null or expires_at > now());
"""


def docker_psql(fluxer_dir):
    """psql in the deployment's postgres, as the scripts reach it. Inputs go in as psql
    variables (:'id' is quoted by psql itself), never into the SQL text."""
    def psql(sql, variables):
        pg = os.environ.get('PG_CONTAINER')
        cmd = ['docker', 'exec', '-i', pg] if pg else ['docker', 'compose', 'exec', '-T', 'postgres']
        cmd += ['psql', '-X', '-q', '-At', '-U', 'fluxer', '-d', 'fluxer', '-v', 'ON_ERROR_STOP=1']
        for key, value in variables.items():
            cmd += ['-v', f'{key}={value}']
        try:
            p = subprocess.run(cmd, input=sql, capture_output=True, text=True, timeout=30, cwd=fluxer_dir)
        except (OSError, subprocess.SubprocessError) as e:
            raise UpstreamError(f'database check failed: {e}') from e
        if p.returncode != 0:
            raise UpstreamError('database check failed: ' + p.stderr.strip()[-300:])
        return p.stdout
    return psql


class Identity:
    """Who a session token belongs to (the api), and whether that account is STAFF
    (the database, on every call: revoking STAFF cuts access at once)."""

    def __init__(self, domain, fetch=None, psql=None, ttl=60.0, clock=time.monotonic):
        self.domain = domain
        self._fetch = fetch or self._fetch_from_edge
        self._psql = psql
        self.ttl, self.clock = ttl, clock
        self._cache = {}
        self._lock = threading.Lock()

    def _fetch_from_edge(self, token):
        conn = _EdgeConnection(self.domain, ('127.0.0.1', 443), timeout=10)
        try:
            conn.request('GET', '/api/v1/users/@me',
                         headers={'Authorization': token, 'User-Agent': 'fluxer-ops-bridge'})
            resp = conn.getresponse()
            return resp.status, resp.read(65536)
        except (OSError, http.client.HTTPException) as e:
            raise UpstreamError(f'api unreachable: {e}') from e
        finally:
            conn.close()

    def whoami(self, token, fresh=False):
        # Keyed by a hash: the bridge never keeps a token it does not need to.
        key = hashlib.sha256(token.encode()).hexdigest()
        now = self.clock()
        if not fresh:
            with self._lock:
                hit = self._cache.get(key)
            if hit and hit[0] > now:
                return hit[1]  # None: the api rejected this token a moment ago
        status, body = self._fetch(token)
        if status in (401, 403):
            # Remembered too, so a loop of bad tokens cannot make the bridge call the api each time.
            with self._lock:
                if len(self._cache) > 1000:
                    self._cache.clear()
                self._cache[key] = (now + self.ttl, None)
            return None
        if status != 200:
            raise UpstreamError(f'api answered {status} for /users/@me')
        try:
            data = json.loads(body)
            user = {'id': str(data['id']), 'username': str(data.get('username', ''))}
        except (ValueError, KeyError, TypeError) as e:
            raise UpstreamError('unexpected answer from /users/@me') from e
        if not SNOWFLAKE.fullmatch(user['id']):
            raise UpstreamError('unexpected user id from /users/@me')
        with self._lock:
            if len(self._cache) > 1000:
                self._cache.clear()
            self._cache[key] = (now + self.ttl, user)
        return user

    def is_staff(self, user_id):
        if not SNOWFLAKE.fullmatch(user_id):
            return False
        return self._psql(STAFF_SQL, {'id': user_id}).strip() == '1'


def make_audit(ops):
    """Log every write to the journal, and tell a human through notify.sh."""
    def audit(user, name, args, result):
        msg = (f"{user['username']} ({user['id']}) ran {name} "
               f"{json.dumps(args, sort_keys=True)} from the Ops panel -> exit {result['exit']}")
        log.info('audit: %s', msg)

        def send():
            try:
                subprocess.run([os.path.join(ops, 'notify.sh'), 'send', 'info', 'ops-panel', msg],
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=60)
            except (OSError, subprocess.SubprocessError):
                log.warning('notify.sh failed for: %s', msg)
        threading.Thread(target=send, daemon=True).start()
    return audit


class Bridge:
    def __init__(self, identity, domain, ops=OPS, run=None, audit=None, limiter=None, request_limiter=None):
        self.identity = identity
        self.origin = f'https://{domain}'
        self.ops = ops
        self.run = run or run_script
        self.audit = audit or (lambda *a: None)
        self.limiter = limiter or RateLimiter()
        # Every authenticated request, STAFF or not, before the database is asked anything.
        self.request_limiter = request_limiter or RateLimiter(limit=60)

    def handle(self, method, path, headers, body):
        try:
            return self._handle(method, path.split('?', 1)[0], headers, body)
        except UpstreamError as e:
            log.warning('upstream: %s', e)
            return 502, {'error': str(e)}

    def _handle(self, method, path, headers, body):
        if path == '/health':
            return (200, {'ok': True}) if method == 'GET' else (405, {'error': 'method not allowed'})
        routes = {'/whoami': 'GET', '/run': 'POST'}
        if path not in routes:
            return 404, {'error': 'not found'}
        if method != routes[path]:
            return 405, {'error': 'method not allowed'}
        # Browsers send Origin on every POST; a page elsewhere cannot fake ours.
        origin = headers.get('Origin')
        if origin is not None and origin != self.origin:
            return 403, {'error': 'wrong origin'}
        token = headers.get('Authorization') or ''
        if not TOKEN.fullmatch(token):
            return 401, {'error': NO_SESSION}

        if path == '/whoami':
            user = self.identity.whoami(token)
            if user is None:
                return 401, {'error': NO_SESSION}
            if not self.request_limiter.allow(user['id']):
                return 429, TOO_MANY
            return 200, dict(user, staff=self.identity.is_staff(user['id']))

        try:
            request = json.loads(body.decode('utf-8'))
        except (UnicodeDecodeError, ValueError):
            return 400, {'error': 'the body must be JSON'}
        if not isinstance(request, dict) or not isinstance(request.get('action'), str):
            return 400, {'error': 'expected {"action": "...", "args": {...}}'}
        name, args = request['action'], request.get('args', {})
        action = ACTIONS.get(name)
        # A write re-asks the api: a token revoked a second ago must not still work.
        user = self.identity.whoami(token, fresh=bool(action and action.write))
        if user is None:
            return 401, {'error': NO_SESSION}
        if not self.request_limiter.allow(user['id']):
            return 429, TOO_MANY
        if not self.identity.is_staff(user['id']):
            return 403, {'error': 'STAFF accounts only'}
        try:
            argv = build_argv(name, args, ops=self.ops)
        except BadRequest as e:
            return 400, {'error': str(e)}
        if action.write and not self.limiter.allow(user['id']):
            return 429, {'error': 'too many changes in a minute; wait a little'}
        result = self.run(argv, action.timeout)
        if name == 'gifts.create' and result['exit'] != 0:
            choices = parse_community_choices(result['stderr'])
            if choices:
                result['choices'] = choices
        if action.write:
            self.audit(user, name, args, result)
        return 200, dict(result, action=name)


class _Handler(http.server.BaseHTTPRequestHandler):
    bridge = None
    server_version = 'fluxer-ops-bridge'
    protocol_version = 'HTTP/1.1'

    slots = threading.BoundedSemaphore(MAX_CONCURRENT)

    def _reply(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

    def _serve(self):
        if not self.slots.acquire(blocking=False):
            self.close_connection = True
            return self._reply(503, {'error': 'bridge busy; try again'})
        try:
            raw = (self.headers.get('Content-Length') or '0').strip()
            if not (raw.isascii() and raw.isdigit()):
                self.close_connection = True
                return self._reply(400, {'error': 'bad Content-Length'})
            length = int(raw)
            if length > MAX_BODY:
                self.close_connection = True
                return self._reply(413, {'error': 'request too large'})
            body = self.rfile.read(length) if length else b''
            try:
                status, payload = self.bridge.handle(self.command, self.path, self.headers, body)
            except Exception:  # never let one request take the bridge down
                log.exception('request failed')
                status, payload = 500, {'error': 'internal error in the bridge'}
            self._reply(status, payload)
        finally:
            self.slots.release()

    do_GET = _serve
    do_POST = _serve

    def address_string(self):
        return 'edge'  # a Unix socket has no peer address; only edge can reach it

    def log_message(self, fmt, *args):
        log.debug(fmt, *args)


class _Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def serve(socket_path, bridge):
    """Bind the bridge to a Unix socket (mode 0660). Call .serve_forever() on the result."""
    try:
        os.unlink(socket_path)  # left behind by a crash or a reboot
    except FileNotFoundError:
        pass
    handler = type('Handler', (_Handler,), {'bridge': bridge, 'slots': threading.BoundedSemaphore(MAX_CONCURRENT)})
    old = os.umask(0o117)
    try:
        server = _Server(socket_path, handler)
    finally:
        os.umask(old)
    os.chmod(socket_path, 0o660)
    return server


def env_value(path, key):
    try:
        with open(path, encoding='utf-8') as f:
            for line in f:
                if line.startswith(key + '='):
                    return line[len(key) + 1:].strip()
    except OSError:
        pass
    return ''


def main(argv=None):
    parser = argparse.ArgumentParser(description='Bridge between the STAFF Ops panel and the fluxer-ops scripts.')
    parser.add_argument('--socket', required=True, help='Unix socket to listen on')
    opts = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format='%(levelname)s %(message)s')
    fluxer_dir = os.environ.get('FLUXER_DIR') or os.path.dirname(OPS)
    domain = env_value(os.path.join(fluxer_dir, '.env'), 'FLUXER_DOMAIN')
    if not domain:
        log.error('no FLUXER_DOMAIN in %s/.env', fluxer_dir)
        return 2
    bridge = Bridge(Identity(domain, psql=docker_psql(fluxer_dir)), domain, audit=make_audit(OPS))
    server = serve(opts.socket, bridge)
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown).start())
    log.info('listening on %s for %s', opts.socket, bridge.origin)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        try:
            os.unlink(opts.socket)
        except OSError:
            pass
    return 0


if __name__ == '__main__':
    sys.exit(main())
