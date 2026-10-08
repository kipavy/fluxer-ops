# STAFF Ops Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the `fluxer` account commands (gifts, premium, users) and read-only health commands from an "Ops…" item in the web app's STAFF menu.

**Architecture:**
- `ops-panel.js` is loaded before the app bundle. It captures the session token from the app's own XHR calls, adds the menu item, and draws a panel in a shadow root.
- The panel calls `/ops-api/*`. Caddy (`edge`) forwards that to `ops_bridge.py` over a Unix socket. The bridge is a stdlib-only systemd service running as the instance user. It checks the token with the api and the STAFF bit in the database, then runs one allowlisted script with a fixed argv.
- `overlay.sh` becomes the only writer of `docker-compose.override.yml` and of the served `index.html`, so the badge patch and the panel compose instead of overwriting each other.

**Tech Stack:**
- POSIX `sh` (dash-compatible, like every script here).
- Python 3.10 stdlib (`http.server`, `socketserver`, `unittest`).
- Plain ES2017 JavaScript, no build step.
- Caddy 2.11 (`reverse_proxy unix//…`, `file_server`).
- systemd 249. node only through `lib-node.sh` (host node or the api image's) for brotli.

**Spec:** `docs/superpowers/specs/2026-10-08-staff-ops-panel-design.md`

## Global Constraints

- **Where to work.** On the TradingSim host (voltius connection "TradingSim"), in a separate clone:
  ```sh
  git clone https://github.com/kipavy/fluxer-ops ~/fluxer-ops-dev
  cd ~/fluxer-ops-dev
  git checkout staff-ops-panel
  ```
  The Windows machine has no python. **Never edit `~/Documents/fluxer/ops` (the live checkout) before Task 6.** Cron runs the live scripts.
- **Tests never touch the live instance.** That means no real sudo, no `docker compose up`, no real database. Tests use stubs in `mktemp -d` directories, the way `tests/setup_test.sh` does.
- **Scripts.** `#!/bin/sh`, `set -eu`, tabs for indentation, and comments that explain *why*. Every script that needs the instance sources `lib.sh` as:
  ```sh
  . "$(dirname "$(readlink -f "${OPS_SELF:-$0}")")/lib.sh"
  ```
  so tests can source it.
- **Python** is stdlib only, and must run under `python3 -I` (isolated mode). It needs Python ≥ 3.10.
- **JavaScript.** UI text is in English, like the CLI. It must never throw into the app: wrap the entry points in `try`/`catch`.
- **URLs.** The script is at `/ops-panel.js`, the API at `/ops-api/*` (Caddy strips the prefix, so the bridge sees `/health`, `/whoami`, `/run`). The identity call is `GET /api/v1/users/@me` to `127.0.0.1:443` with SNI = `FLUXER_DOMAIN`.
- **Socket.** `ops/panel/run/bridge.sock` on the host, mounted at `/run/fluxer-ops` in `edge`, mode 0660.
- **systemd unit.** `fluxer-ops-bridge`, `User=` the instance user, `SupplementaryGroups=docker`, `NoNewPrivileges=yes`.
- **Argument patterns.** Match each with `fullmatch`:
  - duration: `[1-9][0-9]{0,3}[dwmy]|lifetime`
  - code: `[A-Za-z0-9]{32}`
  - user: `[A-Za-z0-9][A-Za-z0-9._-]{0,31}(?:#[0-9]{1,4})?`
  - community: `[0-9]{1,20}`
  - count: `1..50`
  - recent: `1..200`
- **Limits.** Timeouts are 60 s by default, 300 s for `health.check` and `health.doctor`, 120 s for `gifts.setup-lifetime`. Rate limit: 30 writes per minute per user.
- **After every task**, `./selftest.sh` must pass. Commit after every task, with messages ending in:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```
- **Task 6 changes the live instance.** It restarts `edge` and `app-proxy` and installs a systemd unit with sudo. Do not start it without the user's explicit go-ahead in chat.

## Review Focus

1. **A `user` value that looks like a flag** (`--off`, `-x`, `--list`) must be refused with 400 and never reach a script, where `premium.sh`/`users.sh` would parse it as an option. Pinned in Task 1 (`test_user_cannot_be_a_flag`).
2. **Values with a trailing newline or shell metacharacters** (`1w\n`, `$(id)`, `a;b`, `bob\n`) are refused. argv never goes through a shell. Pinned in Task 1 (`test_duration_patterns`, `test_user_patterns`) and Task 2 (`test_stub_script_sees_exact_argv`).
3. **Typing in a panel field while the app wants the keyboard.** Keystrokes must stay in the panel and must not leak into the message composer or trigger app hotkeys. Pinned in Task 5 Step 4 and Task 6 Step 6.
4. **The bridge is down or its socket is missing.** The web app must load and work normally, and the panel must say the bridge is not answering. Pinned in Task 6 Step 7.
5. **`fluxer update` with the badge and/or the panel on.** After the update the app must work. A badge patch built for the old release must be left out, never mounted, until it is rebuilt. Pinned in Task 3 (`stale badge is left out`) and Task 4 (update.sh re-applies the panel).

Also covered: an expired or not-yet-seen session token gives a clear message (Task 2 `test_unknown_token_401_message`), and a foreign `docker-compose.override.yml` is never overwritten (Task 3 `foreign override refused`).

## File Map

| File | Status | Responsibility |
| --- | --- | --- |
| `ops_bridge.py` | create | Allowlist, argument validation, identity and STAFF check, script runner, HTTP on a Unix socket. |
| `tests/test_ops_bridge_actions.py` | create | Allowlist and validation unit tests. |
| `tests/test_ops_bridge_server.py` | create | Auth chain, rate limit, runner, real-socket round trip. |
| `lib-node.sh` | create | `resolve_node`, `run_node` (moved out of badge-patch.sh). Sourced, not a command. |
| `overlay.sh` | create | Only writer of `docker-compose.override.yml` and of the served `index.html`. |
| `tests/overlay_test.sh` | create | Tag insertion, override rendering, stale badge, foreign override. |
| `panel.sh` | create | `on`, `off`, `status`, `refresh`: unit, Caddyfile copy, script, socket dir. |
| `tests/panel_test.sh` | create | Caddyfile rendering and round trip, unit rendering. |
| `tests/fixtures/Caddyfile` | create | Upstream's Caddyfile, copied from the live instance. |
| `ops-panel.js` | create | Token capture, menu item, panel UI. |
| `badge-patch.sh` | modify | Builds `patches/` only, then calls `overlay.sh apply`. Sources `lib-node.sh`. |
| `update.sh` | modify | `overlay.sh suspend` before an update; re-apply badge and panel after. |
| `doctor.sh` | modify | `check_overlay` (mounted files exist), badge check keyed on `patches/`, `check_panel`. |
| `fluxer`, `completion.bash` | modify | `panel` command. |
| `selftest.sh` | modify | `lib-node.sh` is a library; run the python tests. |
| `.gitignore` | modify | `panel/`, `overlay/`. |
| `README.md` | modify | "In-app Ops panel" section; Known gaps mentions the panel. |

---

### Task 1: Bridge allowlist and argument validation

**Files:**
- Create: `ops_bridge.py`
- Test: `tests/test_ops_bridge_actions.py`

**Interfaces:**
- Produces:
  - `ops_bridge.BadRequest(Exception)`.
  - `ops_bridge.Action`, a frozen dataclass with fields `script: str`, `build: Callable[[dict], list[str]]`, `keys: frozenset[str]`, `write: bool`, `timeout: int = 60`.
  - `ops_bridge.ACTIONS: dict[str, Action]`.
  - `ops_bridge.build_argv(name: str, args: object, ops: str = OPS) -> list[str]`. It returns `[<ops>/<script>, *arguments]` or raises `BadRequest`.
  - `ops_bridge.parse_community_choices(stderr: str) -> list[dict] | None`. Each dict is `{"name": str, "id": str}`.
  - `ops_bridge.OPS`, the real directory of the file.

- [ ] **Step 1: Write the failing tests**

`tests/test_ops_bridge_actions.py`:

```python
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s tests -p 'test_ops_bridge_actions.py' -v`
Expected: ERROR, `ModuleNotFoundError: No module named 'ops_bridge'`.

- [ ] **Step 3: Write `ops_bridge.py` (allowlist part)**

```python
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
import os
import re
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s tests -p 'test_ops_bridge_actions.py' -v`
Expected: every test `ok`, final line `OK`.

- [ ] **Step 5: Commit**

```bash
git add ops_bridge.py tests/test_ops_bridge_actions.py
git commit -m "bridge: allowlist and argument validation for the STAFF Ops panel

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Bridge runtime: identity, STAFF check, runner, HTTP on a Unix socket

**Files:**
- Modify: `ops_bridge.py` (append everything below to the end of the file)
- Test: `tests/test_ops_bridge_server.py`

**Interfaces:**
- Consumes: `ACTIONS`, `build_argv`, `BadRequest`, `parse_community_choices` from Task 1.
- Produces:
  - `UpstreamError(Exception)`.
  - `run_script(argv: list[str], timeout: float) -> dict`. The dict has keys `exit: int`, `stdout: str`, `stderr: str`, `timed_out: bool`. `exit` is 124 on timeout and 127 when the script cannot start.
  - `RateLimiter(limit=30, window=60.0, clock=time.monotonic)`, with `.allow(key: str) -> bool`.
  - `Identity(domain, fetch=None, psql=None, ttl=60.0, clock=time.monotonic)`:
    - `.whoami(token, fresh=False) -> {'id': str, 'username': str} | None`;
    - `.is_staff(user_id) -> bool`;
    - `fetch(token) -> (status: int, body: bytes)` and `psql(sql: str, variables: dict) -> str` are injectable.
  - `docker_psql(fluxer_dir) -> psql callable`.
  - `make_audit(ops) -> audit(user, name, args, result)`.
  - `Bridge(identity, domain, ops=OPS, run=run_script, audit=None, limiter=None)`, with `.handle(method, path, headers, body: bytes) -> (status: int, payload: dict)`. `headers` only needs `.get(name)` with exact-case `Authorization` and `Origin`.
  - `serve(socket_path, bridge) -> server`. Not started: call `.serve_forever()`.
  - `main(argv=None) -> int`.

- [ ] **Step 1: Write the failing tests**

`tests/test_ops_bridge_server.py`:

```python
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s tests -p 'test_ops_bridge_server.py' -v`
Expected: errors such as `AttributeError: module 'ops_bridge' has no attribute 'Bridge'`.

- [ ] **Step 3: Append the runtime to `ops_bridge.py`**

First add these imports to the import block at the top of the file, keeping it alphabetical:

```python
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
```

Then append to the end of the file:

```python
log = logging.getLogger('ops-bridge')

MAX_OUTPUT = 200_000
MAX_BODY = 64 * 1024
# A Fluxer session token as the app sends it: printable ASCII, no spaces or line
# breaks, so it can never smuggle a header into the request to the api.
TOKEN = re.compile(r'[\x21-\x7e]{1,512}')
SNOWFLAKE = re.compile(r'[0-9]{1,20}')
NO_SESSION = 'No Fluxer session: reload the web app, then try again.'


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
                return hit[1]
        status, body = self._fetch(token)
        if status in (401, 403):
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
    def __init__(self, identity, domain, ops=OPS, run=None, audit=None, limiter=None):
        self.identity = identity
        self.origin = f'https://{domain}'
        self.ops = ops
        self.run = run or run_script
        self.audit = audit or (lambda *a: None)
        self.limiter = limiter or RateLimiter()

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

    def _serve(self):
        length = int(self.headers.get('Content-Length') or 0)
        if length > MAX_BODY:
            status, payload = 413, {'error': 'request too large'}
            self.close_connection = True
        else:
            body = self.rfile.read(length) if length else b''
            try:
                status, payload = self.bridge.handle(self.command, self.path, self.headers, body)
            except Exception:  # never let one request take the bridge down
                log.exception('request failed')
                status, payload = 500, {'error': 'internal error in the bridge'}
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(data)

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
    handler = type('Handler', (_Handler,), {'bridge': bridge})
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
```

- [ ] **Step 4: Run all the bridge tests**

Run: `python3 -m unittest discover -s tests -p 'test_ops_bridge_*.py' -v`
Expected: every test `ok`, final line `OK`. The runner tests each finish in under 5 s.

- [ ] **Step 5: Smoke the entry point**

Run:
```sh
d=$(mktemp -d)
printf 'FLUXER_DOMAIN=chat.example.test\n' > "$d/.env"
FLUXER_DIR=$d python3 -I ops_bridge.py --socket "$d/s.sock" &
pid=$!
sleep 1
curl -s --unix-socket "$d/s.sock" http://bridge/health
echo
kill $pid
wait $pid
ls "$d"
```
Expected: `{"ok": true}`. After the kill, `ls` shows only `.env`: the socket was removed on SIGTERM.

- [ ] **Step 6: Commit**

```bash
git add ops_bridge.py tests/test_ops_bridge_server.py
git commit -m "bridge: identity, STAFF check, runner and Unix-socket HTTP server

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `overlay.sh`, the one writer of the override, and the badge patch moved onto it

**Files:**
- Create: `lib-node.sh`, `overlay.sh`, `tests/overlay_test.sh`
- Modify: `badge-patch.sh`, `update.sh` (step 5 and the failure message), `doctor.sh` (`check_badge_patch`, new `check_overlay`), `selftest.sh` (library list), `.gitignore`

**Interfaces:**
- Produces:
  - `overlay.sh apply | suspend | status`.
  - With `OVERLAY_SOURCE_ONLY=1` sourced, it defines:
    - `insert_panel_tag <html>`: prints the html; exit 3 if there is no external `<script>`;
    - `render_override <badge names> <panel 0|1>`: prints the YAML;
    - `badge_names`: prints names or nothing; warns on stderr when stale;
    - `ours`, `badge_on`, `panel_on`.
  - Constants: `PANEL_TAG='<script src="/ops-panel.js"></script>'`, `MARKER='# generated by ops/overlay.sh - do not edit by hand'`.
  - Feature switches: badge is on while `ops/patches/patched.names` is non-empty; panel is on while `ops/panel/enabled` exists.
  - `lib-node.sh`: `resolve_node`, `run_node <dir> <script>`. The caller defines `compose` and `die`.

- [ ] **Step 1: Write the failing test**

`tests/overlay_test.sh`:

```sh
#!/bin/sh
# overlay_test.sh - overlay.sh composes the badge patch and the Ops panel into one
# override and one index.html. Stubs only: docker never reaches the real instance.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(dirname "$HERE")
. "$HERE/assert.sh"
tmp=$(readlink -f "$(mktemp -d)")
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/inst/ops/patches" "$tmp/stub"
cp "$SRC"/*.sh "$tmp/inst/ops/"
: > "$tmp/inst/docker-compose.yml"
printf 'FLUXER_DOMAIN=chat.example.test\n' > "$tmp/inst/.env"

# docker stub: logs every call; `compose config --images` names an image, `run` exits
# with $DOCKER_RUN_RC (the "is this chunk still in the image" probe).
cat > "$tmp/stub/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$DOCKER_LOG"
case "$1 $2" in
	"compose config") echo ghcr.io/fluxerapp/fluxer-app-proxy-self-hosted:v1; exit 0 ;;
	"compose up") exit 0 ;;
esac
[ "$1" = run ] && exit "${DOCKER_RUN_RC:-0}"
exit 0
EOF
chmod +x "$tmp/stub/docker"
export DOCKER_LOG="$tmp/docker.log"
: > "$DOCKER_LOG"
PATH="$tmp/stub:$PATH"

load() {
	FLUXER_DIR="$tmp/inst" OPS_SELF="$tmp/inst/ops/overlay.sh" OVERLAY_SOURCE_ONLY=1
	. "$tmp/inst/ops/overlay.sh"
}

# --- insert_panel_tag ------------------------------------------------------------
cat > "$tmp/multi.html" <<'EOF'
<html><head>
<script nonce="{{CSP_NONCE_PLACEHOLDER}}">window.__X=1</script>
<script src="/assets/a.js" type="module"></script>
<script src="/assets/b.js" type="module"></script>
</head></html>
EOF
out=$(load; insert_panel_tag "$tmp/multi.html")
assert_contains "tag goes before the first external script" \
	'<script src="/ops-panel.js"></script><script src="/assets/a.js" type="module">' "$out"
assert_eq "tag inserted once" 1 "$(printf '%s\n' "$out" | grep -o 'ops-panel.js' | grep -c .)"
assert_contains "inline nonce script stays first" '<script nonce="{{CSP_NONCE_PLACEHOLDER}}">window.__X=1</script>' \
	"$(printf '%s\n' "$out" | sed -n 2p)"

printf '<html><script nonce="n">x</script><script src="/assets/a.js" type="module"></script><script src="/assets/b.js"></script></html>\n' > "$tmp/one.html"
out=$(load; insert_panel_tag "$tmp/one.html")
assert_contains "single-line html: before the first external script" \
	'<script nonce="n">x</script><script src="/ops-panel.js"></script><script src="/assets/a.js"' "$out"

printf '<html><script>inline only</script></html>\n' > "$tmp/none.html"
rc=0; (load; insert_panel_tag "$tmp/none.html" > /dev/null) || rc=$?
assert_eq "no external script: exit 3" 3 "$rc"

# --- render_override -------------------------------------------------------------
ops="$tmp/inst/ops"
yaml=$(load; render_override "c.1.js loader.2.js" 0)
assert_eq "marker on line 1" '# generated by ops/overlay.sh - do not edit by hand' "$(printf '%s\n' "$yaml" | head -n 1)"
assert_contains "badge chunk mounted" "      - $ops/patches/c.1.js.br:/srv/app/static/assets/c.1.js.br:ro" "$yaml"
assert_contains "loader mounted" "      - $ops/patches/loader.2.js:/srv/app/static/assets/loader.2.js:ro" "$yaml"
assert_contains "composed index.html mounted" "      - $ops/overlay/index.html.gz:/srv/app/static/index.html.gz:ro" "$yaml"
case "$yaml" in *"edge:"*) fail "badge only: no edge section" ;; *) pass "badge only: no edge section" ;; esac

yaml=$(load; render_override "" 1)
assert_contains "panel: Caddyfile over upstream's" "      - $ops/panel/Caddyfile:/etc/caddy/Caddyfile:ro" "$yaml"
assert_contains "panel: socket dir" "      - $ops/panel/run:/run/fluxer-ops" "$yaml"
assert_contains "panel: script dir" "      - $ops/panel/www:/srv/ops-panel:ro" "$yaml"
case "$yaml" in *"/patches/"*) fail "panel only: no badge mounts" ;; *) pass "panel only: no badge mounts" ;; esac

# --- badge_names -----------------------------------------------------------------
names=$(load; badge_names)
assert_eq "badge off: no names" "" "$names"
printf 'c.js\n' > "$ops/patches/chunk.name"
printf 'c.1.js\nloader.2.js\n' > "$ops/patches/patched.names"
: > "$ops/patches/index.html"
names=$(export DOCKER_RUN_RC=0; load; badge_names)
assert_eq "badge current: its names" "c.1.js loader.2.js " "$names"
err=$( (export DOCKER_RUN_RC=1; load; badge_names > "$tmp/stale.out") 2>&1)
assert_eq "stale badge is left out" "" "$(cat "$tmp/stale.out")"
assert_contains "stale badge is reported" "built for another release" "$err"

# --- ours / apply refusals ---------------------------------------------------------
printf 'services:\n  web: {}\n' > "$tmp/inst/docker-compose.override.yml"
: > "$DOCKER_LOG"
rc=0
err=$(FLUXER_DIR="$tmp/inst" sh "$ops/overlay.sh" apply 2>&1) || rc=$?
assert_eq "foreign override refused" 1 "$rc"
assert_contains "foreign override: says why" "not written by fluxer-ops" "$err"
assert_eq "foreign override untouched" "$(printf 'services:\n  web: {}')" "$(cat "$tmp/inst/docker-compose.override.yml")"
assert_eq "foreign override: docker never called" "" "$(cat "$DOCKER_LOG")"

printf '# generated by ops/badge-patch.sh - do not edit by hand\n' > "$tmp/inst/docker-compose.override.yml"
(load; ours) && pass "legacy badge-patch override counts as ours" || fail "legacy badge-patch override counts as ours"

rm -f "$ops/patches/patched.names"
FLUXER_DIR="$tmp/inst" sh "$ops/overlay.sh" apply > /dev/null
[ ! -e "$tmp/inst/docker-compose.override.yml" ] && pass "nothing on: our override removed" \
	|| fail "nothing on: our override removed"
assert_contains "nothing on: app-proxy and edge recreated stock" "compose up -d app-proxy edge" "$(cat "$DOCKER_LOG")"

finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tests/overlay_test.sh`
Expected: it fails at once with `.../overlay.sh: No such file or directory` (non-zero exit).

- [ ] **Step 3: Create `lib-node.sh`**

Move `resolve_node` and `run_node` out of `badge-patch.sh`, verbatim, under this header:

```sh
# shellcheck shell=sh
# lib-node.sh - a node for the small build steps (patching, brotli). Sourced by
# badge-patch.sh and overlay.sh; not a command.
#
# Prefers the host's node (or the newest nvm one, which is not on PATH under cron or
# a plain sh), and falls back to the node inside the api image, so a host with no node
# at all still works. The caller defines compose() and die().

# node does the patch, the rewrite and both recompressions in one pass. Prefer the
# host's, fall back to the node that ships inside the api image so this works on a
# host with no node at all.
resolve_node() {
	NODE_BIN=$(command -v node 2>/dev/null || true)
	[ -n "$NODE_BIN" ] && return 0
	# nvm installs are not on PATH under cron or a plain sh.
	NODE_BIN=$(ls -d "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V | tail -n 1 || true)
}

run_node() {
	dir=$1 script=$2
	if [ -n "${NODE_BIN:-}" ]; then
		(cd "$dir" && "$NODE_BIN" "$script")
		return
	fi
	api_image=$(compose config --images 2>/dev/null | grep 'fluxer-api' | head -n 1) || api_image=''
	[ -n "$api_image" ] || die 'no node on this host and no api image to borrow one from'
	docker run --rm --user "$(id -u):$(id -g)" -v "$dir:/work" -w /work "$api_image" node "$script"
}
```

In `badge-patch.sh`, delete those two functions and their comment. Right after the `. "…/lib.sh"` line, add:

```sh
. "$OPS/lib-node.sh"
```

- [ ] **Step 4: Create `overlay.sh`**

```sh
#!/bin/sh
# overlay.sh - the one writer of docker-compose.override.yml and of the index.html the
# web app is served with.
#
#   overlay.sh apply     rebuild both from the features that are on, recreate what changed
#   overlay.sh suspend   drop the override (stock app and edge), keep every feature's state
#   overlay.sh status    which features are on
#
# Two features change what the browser gets, and both need index.html:
#   badge   badge-patch.sh: patched chunks in ops/patches/ and patches/index.html
#           repointed at them. On while ops/patches/patched.names is non-empty.
#   panel   panel.sh: a <script> for the STAFF Ops panel in index.html, plus a Caddyfile
#           with the /ops-api/ route, the bridge's socket directory and the script
#           itself mounted into edge. On while ops/panel/enabled exists.
# Each feature keeps its own files; this composes them, so turning one off never takes
# the other with it. index.html is built in one pass: stock (or the badge's repointed
# copy), then the panel's <script>.
#
# A badge patch built for another release (after an update) is left out with a warning
# instead of mounted: its index.html names chunks the new image no longer has, which
# would break the app outright rather than just lose the badge.
set -eu

. "$(dirname "$(readlink -f "${OPS_SELF:-$0}")")/lib.sh"
. "$OPS/lib-node.sh"

OVERRIDE="$FLUXER_DIR/docker-compose.override.yml"
MARKER='# generated by ops/overlay.sh - do not edit by hand'
# Written by badge-patch.sh before overlay.sh existed; still ours to replace.
LEGACY_MARKER='# generated by ops/badge-patch.sh - do not edit by hand'
PATCH_DIR="$OPS/patches"
PANEL_DIR="$OPS/panel"
OUT_DIR="$OPS/overlay"
STATIC=/srv/app/static
ASSET_DIR="$STATIC/assets"
PANEL_TAG='<script src="/ops-panel.js"></script>'

die() { printf 'overlay: %s\n' "$*" >&2; exit 1; }
compose() { (cd "$FLUXER_DIR" && docker compose "$@"); }

# Anything else at that path is someone else's file and is never touched.
ours() {
	[ -f "$OVERRIDE" ] || return 1
	first=$(head -n 1 "$OVERRIDE")
	[ "$first" = "$MARKER" ] || [ "$first" = "$LEGACY_MARKER" ]
}
badge_on() { [ -s "$PATCH_DIR/patched.names" ] && [ -s "$PATCH_DIR/chunk.name" ] && [ -f "$PATCH_DIR/index.html" ]; }
panel_on() { [ -f "$PANEL_DIR/enabled" ]; }

app_proxy_image() {
	img=$(compose config --images 2> /dev/null | grep 'fluxer-app-proxy' | head -n 1) || img=''
	[ -n "$img" ] || die 'cannot resolve the app-proxy image from the compose config'
	printf '%s\n' "$img"
}

# Was the badge patch built from the release app-proxy runs now? Its stock chunk is
# still in the image only if so.
badge_current() {
	chunk=$(cat "$PATCH_DIR/chunk.name")
	docker run --rm --pull never --entrypoint sh "$(app_proxy_image)" \
		-c "test -f $ASSET_DIR/$chunk" > /dev/null 2>&1
}

# The badge's files to mount, space-separated, or nothing when it is off or stale.
badge_names() {
	badge_on || return 0
	if badge_current; then
		tr '\n' ' ' < "$PATCH_DIR/patched.names"
	else
		echo "overlay: the badge patch was built for another release; leaving it out until 'fluxer badge-patch' rebuilds it" >&2
	fi
}

# The html with the panel's <script> right before the first external script. It must
# run before the bundle: the app deletes window.localStorage at start-up, and the panel
# wraps XMLHttpRequest before the app's first api call. A classic script there runs
# before every module script, which are deferred. Exit 3: nowhere to put it.
insert_panel_tag() {
	awk -v tag="$PANEL_TAG" '
		!done && /<script[^>]* src=/ { sub(/<script[^>]* src=/, tag "&"); done = 1 }
		{ print }
		END { if (!done) exit 3 }' "$1"
}

render_override() { # <badge names> <panel 0|1>
	printf '%s\n' "$MARKER"
	cat <<'YAML'
#
# Composed by ops/overlay.sh from the features that are on: the Visionary badge patch
# (badge-patch.sh) and the STAFF Ops panel (panel.sh). Regenerated by those scripts and
# by update.sh; never edit by hand. Sources are absolute: compose resolves relative
# bind sources against $FLUXER_DIR, which is ops/'s parent only in the usual layout.
services:
  app-proxy:
    volumes:
YAML
	for n in $1; do
		for f in "$n" "$n.br" "$n.gz"; do
			printf '      - %s/%s:%s/%s:ro\n' "$PATCH_DIR" "$f" "$ASSET_DIR" "$f"
		done
	done
	for f in index.html index.html.br index.html.gz; do
		printf '      - %s/%s:%s/%s:ro\n' "$OUT_DIR" "$f" "$STATIC" "$f"
	done
	[ "$2" = 1 ] || return 0
	cat <<YAML
  edge:
    volumes:
      # Same container path as upstream's ./Caddyfile mount, so this one replaces it.
      - $PANEL_DIR/Caddyfile:/etc/caddy/Caddyfile:ro
      - $PANEL_DIR/www:/srv/ops-panel:ro
      # The directory, not the socket: the bridge recreates the socket on restart.
      - $PANEL_DIR/run:/run/fluxer-ops
YAML
}

write_compress_program() {
	cat > "$1/compress.js" <<'NODE'
// app-proxy serves whichever precompressed sibling the browser asks for, so the
// composed index.html needs its own .br and .gz or the stock ones would shadow it.
const fs = require('node:fs');
const zlib = require('node:zlib');
const html = fs.readFileSync('index.html');
fs.writeFileSync('index.html.br', zlib.brotliCompressSync(html, {
	params: {[zlib.constants.BROTLI_PARAM_QUALITY]: 5},
}));
fs.writeFileSync('index.html.gz', zlib.gzipSync(html, {level: 9}));
NODE
}

cmd_apply() {
	need_instance
	if [ -f "$OVERRIDE" ] && ! ours; then
		die "$OVERRIDE was not written by fluxer-ops - merge its mounts by hand"
	fi
	names=$(badge_names)
	panel=0
	if panel_on; then panel=1; fi

	if [ -z "$names" ] && [ "$panel" = 0 ]; then
		if ours; then
			rm -f "$OVERRIDE"
			echo "Nothing to serve on top of the stock app: override removed."
			compose up -d app-proxy edge
		fi
		return 0
	fi

	work="$OUT_DIR.new"
	rm -rf "$work"
	mkdir -p "$work" "$OUT_DIR"
	if [ -n "$names" ]; then
		cp "$PATCH_DIR/index.html" "$work/base.html"
	else
		# Read from the image, never the running container: always the pristine bytes.
		docker run --rm --user "$(id -u):$(id -g)" --entrypoint sh -v "$work:/out" "$(app_proxy_image)" \
			-c "cp $STATIC/index.html /out/base.html"
	fi
	if [ "$panel" = 1 ]; then
		insert_panel_tag "$work/base.html" > "$work/index.html" \
			|| die "index.html has no external <script> to put the panel before - did the bundle layout change?"
	else
		cp "$work/base.html" "$work/index.html"
	fi
	write_compress_program "$work"
	resolve_node
	run_node "$work" compress.js || die 'compressing index.html failed - nothing was changed'

	# Copy in over what is mounted; never delete a mounted file, or docker replaces the
	# bind source with a root-owned directory on the next up.
	for f in index.html index.html.br index.html.gz; do
		cat "$work/$f" > "$OUT_DIR/$f"
	done
	rm -rf "$work"
	render_override "$names" "$panel" > "$OVERRIDE.new"
	mv "$OVERRIDE.new" "$OVERRIDE"
	compose up -d app-proxy edge
	printf 'Client overlay: badge %s, Ops panel %s.\n' \
		"$([ -n "$names" ] && echo on || echo off)" "$([ "$panel" = 1 ] && echo on || echo off)"
}

cmd_suspend() {
	need_instance
	if ! ours; then
		echo "No fluxer-ops override in place."
		return 0
	fi
	rm -f "$OVERRIDE"
	compose up -d app-proxy edge
	echo "Override removed: app and edge are stock until 'overlay.sh apply' (features keep their state)."
}

cmd_status() {
	need_instance
	printf 'badge   %s\n' "$(badge_on && echo on || echo off)"
	printf 'panel   %s\n' "$(panel_on && echo on || echo off)"
	if ours; then echo "override  ours ($OVERRIDE)"
	elif [ -f "$OVERRIDE" ]; then echo "override  someone else's ($OVERRIDE)"
	else echo "override  none (stock app)"; fi
}

[ "${OVERLAY_SOURCE_ONLY:-0}" = 1 ] && return 0

case "${1:-status}" in
	apply) cmd_apply ;;
	suspend) cmd_suspend ;;
	status) cmd_status ;;
	-h | --help | help) echo "usage: overlay.sh [apply|suspend|status]" ;;
	*) die "unknown command: $1 (apply, suspend, status)" ;;
esac
```

Run `chmod +x overlay.sh`.

- [ ] **Step 5: Move `badge-patch.sh` onto `overlay.sh`**

In the header comment, replace the sentence "and serve it back through docker-compose.override.yml." with:

```sh
# and serve it back through docker-compose.override.yml, which overlay.sh writes (it
# also carries the STAFF Ops panel when that is on).
```

Delete:
- the `OVERRIDE=` and `MARKER=` lines;
- the `ours()` function and its comment;
- the `compose()` line, but only if nothing else uses it. `verify` still calls `compose exec`, so **keep** `compose()`.

Replace `cmd_revert` with:

```sh
cmd_revert() {
	# Off first (overlay.sh reads patched.names to decide), files last: a file still
	# mounted must not disappear, or docker replaces it with a root-owned directory.
	rm -f "$PATCH_DIR/patched.names"
	"$OPS/overlay.sh" apply
	rm -rf "$PATCH_DIR"
	echo "Badge patch off. The served index.html points back at the stock chunk, so a reload is enough."
}
```

In `cmd_apply`, delete the opening `if [ -f "$OVERRIDE" ] && ! ours; then … fi` block: `overlay.sh` refuses a foreign override itself. Then replace everything from `mounts=''` down to and including `compose up -d app-proxy` (the `mounts` loop, the `cat > "$OVERRIDE" <<YAML … YAML` block and the recreate) with:

```sh
	"$OPS/overlay.sh" apply
```

Keep the cleanup loop that follows ("Anything else in here is from an earlier release…") and the final `verify`.

- [ ] **Step 6: `update.sh` takes the whole overlay off and puts the badge back**

Replace the block from `# 5. Take the badge patch off` through the end of `reapply_badge_patch() { … }` with:

```sh
# 5. Take the client overlay off (the badge patch and the Ops panel), if it is on.
#    It mounts an index.html naming release-specific chunks, and the panel a copy of
#    upstream's Caddyfile. Leaving them mounted across an update serves the new image
#    with an index.html pointing at chunks it no longer has, which breaks the app
#    outright. Off before, back on after. Each feature keeps its state meanwhile.
OVERLAID=0
BADGE_ON=0
if grep -qs -e '^# generated by ops/overlay.sh' -e '^# generated by ops/badge-patch.sh' \
	"$FLUXER_DIR/docker-compose.override.yml"; then
	OVERLAID=1
	[ -s "$OPS/patches/patched.names" ] && BADGE_ON=1
	echo
	echo "--- taking the client overlay (badge patch, Ops panel) off for the update ---"
	"$OPS/overlay.sh" suspend
fi

reapply_overlay() {
	[ "$OVERLAID" -eq 1 ] || return 0
	echo
	echo "--- re-applying the client overlay to the new release ---"
	if [ "$BADGE_ON" -eq 1 ]; then
		"$OPS/badge-patch.sh" || echo "WARNING: the badge patch did not re-apply. Run: fluxer badge-patch" >&2
	fi
	# Whatever the badge did, put back what is still on (badge-patch.sh already did if it ran).
	"$OPS/overlay.sh" apply || echo "WARNING: the client overlay did not re-apply. Run: fluxer badge-patch" >&2
}
```

Then:
- Replace both calls to `reapply_badge_patch` with `reapply_overlay`.
- In the failure branch, replace the `if [ "$BADGE_PATCHED" -eq 1 ]; then … fi` block with:

```sh
	if [ "$OVERLAID" -eq 1 ]; then
		echo "The client overlay is OFF (badge patch / Ops panel). Re-apply with 'fluxer badge-patch' once this is sorted." >&2
	fi
```

- [ ] **Step 7: `doctor.sh`: overlay mounts, and the badge keyed on its own state**

Add above `check_badge_patch`:

```sh
# Every file the override mounts must exist: a missing bind source makes docker
# create an empty root-owned directory in its place, and app-proxy or edge then serves
# a directory where index.html or the Caddyfile should be.
check_overlay() {
	override="$FLUXER_DIR/docker-compose.override.yml"
	if [ ! -f "$override" ]; then
		ok "no client overlay (stock app)"
		return
	fi
	case "$(head -n 1 "$override")" in
		'# generated by ops/overlay.sh'* | '# generated by ops/badge-patch.sh'*) ;;
		*) skip "docker-compose.override.yml is not fluxer-ops' (not checked)"; return ;;
	esac
	missing=''
	for src in $(sed -n 's|^ *- \(/[^:]*\):.*|\1|p' "$override"); do
		[ -e "$src" ] || missing="$missing $src"
	done
	if [ -n "$missing" ]; then
		fail "the override mounts files that do not exist:$missing (docker would mount empty directories)" \
			"fluxer badge-patch (or 'ops/overlay.sh apply')"
	else
		ok "client overlay: every mounted file exists"
	fi
}
```

In `check_badge_patch`, replace everything from the start of the function body through the `missing` loop and its `fail`/`return` with:

```sh
	if [ ! -s "$OPS/patches/patched.names" ]; then
		ok "badge patch not applied (stock bundle)"
		return
	fi
```

Keep the rest (the chunk.name, patched index and image checks). In the call list, add `check_overlay` on the line before `check_badge_patch`.

- [ ] **Step 8: `selftest.sh` treats `lib-node.sh` as a library; `.gitignore`**

In `selftest.sh`, change the two `lib.sh` lines of section 1 to:

```sh
# lib.sh and lib-node.sh are sourced, not run: they must parse, but are not commands.
scripts=$(ls ./*.sh fluxer | sed 's|^\./||' | grep -vxE 'lib(-node)?\.sh')
for lib in lib.sh lib-node.sh; do sh -n "$lib" 2>/dev/null || fail "$lib does not parse"; done
```

In section 7's `nolib` loop, add `lib-node.sh` to the skipped names:

```sh
	case "$f" in lib.sh | lib-node.sh | get.sh | selftest.sh) continue ;; esac
```

Append to `.gitignore`:

```
# Generated by overlay.sh (the served index.html) and panel.sh (Caddyfile copy,
# served script, bridge socket, on/off switch).
overlay/
panel/
```

- [ ] **Step 9: Run the tests and the selftest**

Run: `sh tests/overlay_test.sh && ./selftest.sh --lint`
Expected: every overlay_test line is `ok`. The selftest ends `PASS  ops tooling intact`, including `ok    tests/overlay_test.sh` and `ok    shellcheck clean`. Fix every shellcheck warning in the new or changed files.

- [ ] **Step 10: Commit**

```bash
git add lib-node.sh overlay.sh tests/overlay_test.sh badge-patch.sh update.sh doctor.sh selftest.sh .gitignore
git commit -m "overlay: one writer for the override and index.html; badge patch moved onto it

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `panel.sh` and the `fluxer panel` command

**Files:**
- Create: `panel.sh`, `tests/panel_test.sh`, `tests/fixtures/Caddyfile`
- Modify: `fluxer` (help and dispatch), `completion.bash`, `update.sh` (`reapply_overlay`), `doctor.sh` (`check_panel`), `selftest.sh` (python tests)

**Interfaces:**
- Consumes:
  - `overlay.sh apply` and the `ops/panel/enabled` switch (Task 3);
  - `ops_bridge.py --socket PATH` (Task 2);
  - `ops-panel.js` at the repository root (Task 5 writes the real one; this task works with whatever is there, and `on` refuses if it is missing).
- Produces:
  - `panel.sh on | off | status | refresh`;
  - with `PANEL_SOURCE_ONLY=1`: `render_caddyfile <upstream>` (prints; exit 3 unless there is exactly one `\thandle {`) and `render_unit <user> <group> <python>`;
  - Caddyfile block markers `\t# >>> fluxer-ops panel` … `\t# <<< fluxer-ops panel`.

- [ ] **Step 1: Copy the fixture and write the failing test**

Run: `cp ~/Documents/fluxer/Caddyfile tests/fixtures/Caddyfile`. This is a read of the live file, not a change to it.

`tests/panel_test.sh`:

```sh
#!/bin/sh
# panel_test.sh - panel.sh's renderers: the Caddyfile copy with the panel's routes, and
# the bridge's systemd unit. Pure text; no sudo, no systemd, no docker.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(dirname "$HERE")
. "$HERE/assert.sh"
tmp=$(readlink -f "$(mktemp -d)")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/inst/ops"
cp "$SRC"/*.sh "$tmp/inst/ops/"
: > "$tmp/inst/docker-compose.yml"

load() {
	FLUXER_DIR="$tmp/inst" OPS_SELF="$tmp/inst/ops/panel.sh" PANEL_SOURCE_ONLY=1
	. "$tmp/inst/ops/panel.sh"
}
TAB=$(printf '\t')
up="$HERE/fixtures/Caddyfile"

out=$(load; render_caddyfile "$up")
assert_contains "route to the bridge socket" "${TAB}handle_path /ops-api/* {
${TAB}${TAB}reverse_proxy unix//run/fluxer-ops/bridge.sock" "$out"
assert_contains "panel script served by edge" "${TAB}handle /ops-panel.js {
${TAB}${TAB}root * /srv/ops-panel" "$out"
assert_contains "block sits right before the catch-all" "${TAB}# <<< fluxer-ops panel
${TAB}handle {
${TAB}${TAB}reverse_proxy app-proxy:8080" "$out"
assert_eq "block added once" 1 "$(printf '%s\n' "$out" | grep -c 'handle_path /ops-api/')"
printf '%s\n' "$out" | sed '/# >>> fluxer-ops panel/,/# <<< fluxer-ops panel/d' > "$tmp/stripped"
cmp -s "$tmp/stripped" "$up" && pass "removing the marked block gives upstream's back" \
	|| fail "removing the marked block gives upstream's back"

grep -v "^${TAB}handle {\$" "$up" > "$tmp/nocatchall"
rc=0; (load; render_caddyfile "$tmp/nocatchall" > /dev/null) || rc=$?
assert_eq "no catch-all handle: exit 3" 3 "$rc"
cat "$up" "$up" > "$tmp/two"
rc=0; (load; render_caddyfile "$tmp/two" > /dev/null) || rc=$?
assert_eq "two catch-all handles: exit 3" 3 "$rc"

unit=$(load; render_unit alice alice /usr/bin/python3)
assert_contains "runs as the instance user" "User=alice" "$unit"
assert_contains "may use docker" "SupplementaryGroups=docker" "$unit"
assert_contains "can never sudo" "NoNewPrivileges=yes" "$unit"
assert_contains "isolated python, socket in ops/panel/run" \
	"ExecStart=/usr/bin/python3 -I $tmp/inst/ops/ops_bridge.py --socket $tmp/inst/ops/panel/run/bridge.sock" "$unit"
assert_contains "knows the instance" "Environment=FLUXER_DIR=$tmp/inst" "$unit"

finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tests/panel_test.sh`
Expected: non-zero exit; `panel.sh` does not exist.

- [ ] **Step 3: Create `panel.sh`**

```sh
#!/bin/sh
# panel.sh - the STAFF "Ops" panel: run the account and health commands from the web
# app's STAFF menu instead of a shell. Design: docs/superpowers/specs/2026-10-08-staff-ops-panel-design.md
#
#   panel.sh on        install and start the bridge, add the route and the script
#   panel.sh off       the kill switch: stop the bridge, drop the route and the script
#   panel.sh status    is it on, is the bridge answering, is the route live
#   panel.sh refresh   rebuild from upstream's current Caddyfile and re-apply (update.sh runs it)
#
# Three pieces:
#   ops_bridge.py   systemd unit fluxer-ops-bridge, as this user and never root
#                   (NoNewPrivileges: nothing it starts can sudo). It checks the caller's
#                   session and STAFF flag, then runs one allowlisted script.
#   ops-panel.js    served by edge at /ops-panel.js; overlay.sh puts it in index.html.
#   Caddyfile       a copy of upstream's with a marked /ops-api/* block before the
#                   catch-all. Upstream's own file is never edited.
# The socket lives in ops/panel/run, a directory on disk rather than /run: after a
# reboot docker starts edge before the bridge, and a missing bind source would be
# created root-owned, where the bridge could not create its socket.
#
# Web app only: the desktop and mobile apps never load this server's index.html.
set -eu

. "$(dirname "$(readlink -f "${OPS_SELF:-$0}")")/lib.sh"
PANEL_DIR="$OPS/panel"
SOCKET="$PANEL_DIR/run/bridge.sock"
UNIT=fluxer-ops-bridge
UNIT_FILE="/etc/systemd/system/$UNIT.service"
PANEL_TAG='<script src="/ops-panel.js"></script>'

die() { printf 'panel: %s\n' "$*" >&2; exit 1; }
compose() { (cd "$FLUXER_DIR" && docker compose "$@"); }
domain() { sed -n 's/^FLUXER_DOMAIN=//p' "$FLUXER_DIR/.env" 2> /dev/null | head -n 1; }

# GET through edge on this host. Cloudflare in front would cache, and a failure there
# says nothing about this server. Prints the status code; the body goes to $2.
origin_get() {
	d=$(domain)
	curl -s --max-time 15 -o "${2:-/dev/null}" -w '%{http_code}' --resolve "$d:443:127.0.0.1" "https://$d$1" || true
}
bridge_health() { curl -s --max-time 3 --unix-socket "$SOCKET" http://bridge/health 2> /dev/null | grep -q '"ok": *true'; }

render_caddyfile() { # <upstream Caddyfile>
	awk '
		/^\thandle [{]$/ {
			n++
			if (n == 1) {
				print "\t# >>> fluxer-ops panel (ops/panel.sh): the bridge API and the panel script"
				print "\thandle_path /ops-api/* {"
				print "\t\treverse_proxy unix//run/fluxer-ops/bridge.sock"
				print "\t}"
				print "\thandle /ops-panel.js {"
				print "\t\troot * /srv/ops-panel"
				print "\t\theader Cache-Control \"no-cache\""
				print "\t\tfile_server"
				print "\t}"
				print "\t# <<< fluxer-ops panel"
			}
		}
		{ print }
		END { if (n != 1) exit 3 }' "$1"
}

render_unit() { # <user> <group> <python3>
	cat <<EOF
# generated by ops/panel.sh - do not edit by hand
[Unit]
Description=fluxer-ops bridge for the in-app STAFF Ops panel (ops/panel.sh)
After=docker.service
Wants=docker.service

[Service]
User=$1
Group=$2
SupplementaryGroups=docker
Environment=FLUXER_DIR=$FLUXER_DIR
ExecStart=$3 -I $OPS/ops_bridge.py --socket $SOCKET
Restart=always
RestartSec=2
UMask=0007
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
}

# until <seconds> <command...>: retry once a second.
until_ok() {
	n=$1
	shift
	i=0
	until "$@"; do
		i=$((i + 1))
		[ "$i" -lt "$n" ] || return 1
		sleep 1
	done
}
route_live() { [ "$(origin_get /ops-api/health)" = 200 ]; }
script_live() { [ "$(origin_get /ops-panel.js)" = 200 ]; }
html_loads_panel() {
	f=$(mktemp)
	origin_get / "$f" > /dev/null
	grep -qF "$PANEL_TAG" "$f"
	rc=$?
	rm -f "$f"
	return "$rc"
}

cmd_on() {
	need_instance
	[ -n "$(domain)" ] || die "no FLUXER_DOMAIN in $FLUXER_DIR/.env"
	[ -f "$OPS/ops-panel.js" ] || die "$OPS/ops-panel.js is missing"
	command -v python3 > /dev/null 2>&1 || die 'the bridge needs python3'
	command -v curl > /dev/null 2>&1 || die 'checking the bridge needs curl'
	id -nG | tr ' ' '\n' | grep -qx docker \
		|| die "$(id -un) is not in the docker group, so the bridge could not run the scripts"

	mkdir -p "$PANEL_DIR/www" "$PANEL_DIR/run"
	if ! render_caddyfile "$FLUXER_DIR/Caddyfile" > "$PANEL_DIR/Caddyfile.new"; then
		rm -f "$PANEL_DIR/Caddyfile.new"
		die "$FLUXER_DIR/Caddyfile has no single catch-all 'handle {' to put the route before"
	fi
	# Copied over, never replaced: edge has the Caddyfile mounted as a file, and a
	# replaced file would leave it reading the old inode.
	cat "$PANEL_DIR/Caddyfile.new" > "$PANEL_DIR/Caddyfile"
	rm -f "$PANEL_DIR/Caddyfile.new"
	cat "$OPS/ops-panel.js" > "$PANEL_DIR/www/ops-panel.js"

	render_unit "$(id -un)" "$(id -gn)" "$(command -v python3)" > "$PANEL_DIR/unit.new"
	if ! cmp -s "$PANEL_DIR/unit.new" "$UNIT_FILE"; then
		echo "Installing $UNIT_FILE (sudo)."
		sudo install -m 0644 "$PANEL_DIR/unit.new" "$UNIT_FILE"
		sudo systemctl daemon-reload
	fi
	rm -f "$PANEL_DIR/unit.new"
	sudo systemctl enable "$UNIT" > /dev/null 2>&1
	sudo systemctl restart "$UNIT"
	until_ok 15 bridge_health || die "the bridge does not answer on $SOCKET - see: journalctl -u $UNIT -n 50"
	echo "Bridge answering on $SOCKET."

	: > "$PANEL_DIR/enabled"
	"$OPS/overlay.sh" apply
	# A Caddyfile that changed under an edge that was not recreated needs a reload.
	compose exec -T edge caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null 2>&1 \
		|| die "edge refused the panel's Caddyfile - see: docker compose logs edge"

	until_ok 30 route_live || die "edge does not answer /ops-api/health: the route is not live"
	until_ok 30 script_live || die "edge does not serve /ops-panel.js"
	until_ok 30 html_loads_panel || die "the served index.html does not load /ops-panel.js"
	echo
	echo "Ops panel on. Reload the web app, then STAFF menu -> Ops…"
	echo "(Web app only: the desktop and mobile apps never load this server's index.html.)"
}

cmd_off() {
	need_instance
	rm -f "$PANEL_DIR/enabled"
	"$OPS/overlay.sh" apply
	sudo systemctl disable --now "$UNIT" > /dev/null 2>&1 || true
	echo "Ops panel off: the script, the route and the bridge are gone. Open clients lose it on their next reload."
}

cmd_refresh() {
	if [ ! -f "$PANEL_DIR/enabled" ]; then
		echo "Ops panel is off; nothing to refresh."
		return 0
	fi
	cmd_on
}

cmd_status() {
	need_instance
	if [ -f "$PANEL_DIR/enabled" ]; then echo "panel   on"; else echo "panel   off"; fi
	state=$(systemctl is-active "$UNIT" 2> /dev/null || true)
	echo "bridge  ${state:-unknown} ($UNIT)"
	if bridge_health; then echo "socket  answering ($SOCKET)"; else echo "socket  not answering ($SOCKET)"; fi
	if [ -f "$PANEL_DIR/enabled" ]; then
		if route_live; then echo "route   live through edge"; else echo "route   NOT live through edge"; fi
	fi
}

[ "${PANEL_SOURCE_ONLY:-0}" = 1 ] && return 0

case "${1:-status}" in
	on) cmd_on ;;
	off) cmd_off ;;
	status) cmd_status ;;
	refresh) cmd_refresh ;;
	-h | --help | help) echo "usage: panel.sh on | off | status | refresh" ;;
	*) die "unknown command: $1 (on, off, status, refresh)" ;;
esac
```

Run `chmod +x panel.sh`. Also create a placeholder `ops-panel.js` containing one comment line, `// ops-panel.js - replaced in the next task`, so `selftest` and `on`'s presence check have a file. Task 5 overwrites it.

- [ ] **Step 4: Run the test**

Run: `sh tests/panel_test.sh`
Expected: every line `ok`.

- [ ] **Step 5: Wire the command into `fluxer`, completion, update, doctor and selftest**

In `fluxer`'s `usage`, add under `Host`, after the `firewall-fix` lines:

```
  fluxer panel on | off | status | refresh
                             In-app STAFF Ops panel (web app only): gifts, premium, users, health
```

In the dispatcher `case`, after `badge-patch)`:

```sh
	panel) exec "$OPS/panel.sh" "$@" ;;
```

In `completion.bash`:
- add `panel` to the `COMP_CWORD -eq 1` word list, after `badge-patch`;
- add this case after `badge-patch)`:

```sh
			panel) [ "$COMP_CWORD" -eq 2 ] && words='on off status refresh' ;;
```

In `update.sh`'s `reapply_overlay`, replace the comment and the final `overlay.sh apply` line with:

```sh
	if [ -f "$OPS/panel/enabled" ]; then
		# Rebuilds the Caddyfile copy from the new upstream one, restarts the bridge, re-applies.
		"$OPS/panel.sh" refresh || echo "WARNING: the Ops panel did not re-apply. Run: fluxer panel refresh" >&2
	else
		"$OPS/overlay.sh" apply || echo "WARNING: the client overlay did not re-apply. Run: fluxer badge-patch" >&2
	fi
```

In the failure message, append `and/or 'fluxer panel refresh'` after `'fluxer badge-patch'`.

In `doctor.sh`, add after `check_badge_patch`:

```sh
# The Ops panel: the bridge answers, and the Caddyfile copy is still upstream's plus
# our marked block. Upstream may change its Caddyfile on any update; a stale copy
# would silently drop whatever the new one adds.
check_panel() {
	if [ ! -f "$OPS/panel/enabled" ]; then
		ok "Ops panel off"
		return
	fi
	if ! have curl; then
		skip "Ops panel (no curl)"
		return
	fi
	if curl -s --max-time 3 --unix-socket "$OPS/panel/run/bridge.sock" http://bridge/health 2> /dev/null \
		| grep -q '"ok": *true'; then
		ok "Ops panel bridge answers"
	else
		fail "Ops panel is on but the bridge does not answer" "journalctl -u fluxer-ops-bridge -n 50; fluxer panel refresh"
	fi
	if sed '/# >>> fluxer-ops panel/,/# <<< fluxer-ops panel/d' "$OPS/panel/Caddyfile" 2> /dev/null \
		| cmp -s - "$FLUXER_DIR/Caddyfile"; then
		ok "Ops panel Caddyfile is upstream's plus the /ops-api route"
	else
		fail "upstream's Caddyfile changed since the Ops panel copied it" "fluxer panel refresh"
	fi
}
```

Add `check_panel` to the call list after `check_badge_patch`.

In `selftest.sh`, before the `if [ "$LINT" -eq 1 ]` block, add:

```sh
# 8. The Ops panel bridge's unit tests (python3 stdlib only, no instance needed).
if command -v python3 > /dev/null 2>&1; then
	if out=$(python3 -m unittest discover -s tests -p 'test_*.py' 2>&1); then
		ok "bridge unit tests"
	else
		fail "bridge unit tests:"; printf '%s\n' "$out" | tail -n 30 | sed 's/^/      /'
	fi
else
	fail "python3 is missing: the Ops panel bridge needs it"
fi
```

- [ ] **Step 6: Run everything**

Run: `sh tests/panel_test.sh && ./selftest.sh --lint && ./fluxer help | grep -A1 'fluxer panel'`
Expected:
- the selftest passes, including `ok    every command in the help is dispatched`, `ok    completion covers the dispatcher`, `ok    bridge unit tests`, `ok    tests/panel_test.sh` and `ok    shellcheck clean`;
- the help shows the two `panel` lines.

- [ ] **Step 7: Commit**

```bash
git add panel.sh ops-panel.js tests/panel_test.sh tests/fixtures/Caddyfile fluxer completion.bash update.sh doctor.sh selftest.sh
git commit -m "panel: fluxer panel on|off|status|refresh - bridge unit, Caddy route, doctor check

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `ops-panel.js`, the menu item and the panel

**Files:**
- Modify: `ops-panel.js` (replace the placeholder)

**Interfaces:**
- Consumes: bridge endpoints from Task 2: `GET /ops-api/whoami` → `{id, username, staff}`; `POST /ops-api/run` with `{action, args}` → `{action, exit, stdout, stderr, timed_out, choices?}` or `{error}` with a non-200 status.
- Produces: `window.__fluxerOpsPanel = true` (load guard). The menu item has `data-ops-panel-item`, the panel host `data-ops-panel`.

- [ ] **Step 1: Write `ops-panel.js`**

```js
// ops-panel.js - the STAFF "Ops" panel in the web app. See ops/panel.sh.
//
// Served by edge at /ops-panel.js and loaded by index.html BEFORE the app bundle
// (overlay.sh puts it there). Two jobs:
//   1. Keep the latest session token the app sends to its own /api/, by wrapping
//      XMLHttpRequest. The app deletes window.localStorage at start-up and sends its
//      REST calls through XHR with an Authorization header, so this is the place to see
//      it - and only if installed before the bundle runs.
//   2. Add "Ops…" to the STAFF (developer tools) menu, opening a panel that calls the
//      bridge at /ops-api/. The bridge checks STAFF itself; nothing here is a control.
// Plain ES2017, no build step. Every failure stays inside this file: the app must
// never notice it is here.
(function () {
	'use strict';
	if (window.__fluxerOpsPanel) return;
	window.__fluxerOpsPanel = true;

	// --- 1. the session token --------------------------------------------------------
	var token = null;
	var nativeFetch = window.fetch.bind(window);
	var xhrOpen = XMLHttpRequest.prototype.open;
	var xhrSetHeader = XMLHttpRequest.prototype.setRequestHeader;

	function isOwnApi(url) {
		try {
			var u = new URL(String(url), location.href);
			return u.origin === location.origin && u.pathname.indexOf('/api/') === 0;
		} catch (e) {
			return false;
		}
	}
	XMLHttpRequest.prototype.open = function (method, url) {
		try { this.__opsOwnApi = isOwnApi(url); } catch (e) { /* never break the app */ }
		return xhrOpen.apply(this, arguments);
	};
	XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
		try {
			if (this.__opsOwnApi && value && String(name).toLowerCase() === 'authorization') token = String(value);
		} catch (e) { /* never break the app */ }
		return xhrSetHeader.apply(this, arguments);
	};

	// --- the bridge ----------------------------------------------------------------
	function call(method, path, body) {
		if (!token) {
			return Promise.resolve({status: 0, data: {error: 'No session seen yet. Reload the page, let the app load, then try again.'}});
		}
		var init = {method: method, credentials: 'omit', cache: 'no-store', headers: {'Authorization': token}};
		if (body !== undefined) {
			init.headers['Content-Type'] = 'application/json';
			init.body = JSON.stringify(body);
		}
		return nativeFetch('/ops-api' + path, init).then(function (r) {
			return r.json().catch(function () {
				return {error: 'HTTP ' + r.status + ': the bridge did not answer. Is it running? (fluxer panel status)'};
			}).then(function (data) { return {status: r.status, data: data}; });
		}, function (e) {
			return {status: 0, data: {error: 'Bridge unreachable: ' + e.message}};
		});
	}

	// --- what the panel offers (mirrors ops_bridge.ACTIONS) --------------------------
	var USER = {key: 'user', label: 'User', placeholder: 'username or username#tag'};
	var CODE = {key: 'code', label: 'Code', placeholder: '32 letters and digits'};
	var TABS = [
		{label: 'Gifts', forms: [
			{action: 'gifts.create', title: 'Create gift links', button: 'Create', fields: [
				{key: 'duration', label: 'Duration', value: '1m', placeholder: '1w, 1m, 3m, 1y… or lifetime'},
				{key: 'count', label: 'How many', type: 'number', value: 1, min: 1, max: 50}]},
			{action: 'gifts.list', title: 'List codes', button: 'List', fields: [
				{key: 'filter', label: 'Which', type: 'select', options: ['all', 'unredeemed', 'redeemed', 'revoked']}]},
			{action: 'gifts.show', title: 'Show a code', button: 'Show', fields: [CODE]},
			{action: 'gifts.revoke', title: 'Revoke an unredeemed code', button: 'Revoke', confirm: true, fields: [CODE]},
			{action: 'gifts.rm', title: 'Delete a code', button: 'Delete', confirm: true, fields: [CODE]},
			{action: 'gifts.redeem', title: 'Redeem a code onto an account', button: 'Redeem', fields: [CODE, USER]}]},
		{label: 'Premium', forms: [
			{action: 'premium.grant', title: 'Grant Plutonium', button: 'Grant', fields: [USER,
				{key: 'kind', label: 'Kind', type: 'select', options: ['lifetime', 'duration', 'subscriber']},
				{key: 'duration', label: 'Duration (when kind is duration)', placeholder: '1w, 1m, 1y…'}],
				prepare: function (a) { if (a.kind !== 'duration') delete a.duration; return a; }},
			{action: 'premium.revoke', title: 'Revoke Plutonium', button: 'Revoke', confirm: true, fields: [USER]},
			{action: 'premium.list', title: 'Who has premium', button: 'List', fields: []}]},
		{label: 'Users', forms: [
			{action: 'users.list', title: 'Recent accounts', button: 'List', fields: [
				{key: 'recent', label: 'How many', type: 'number', value: 20, min: 1, max: 200}]},
			{action: 'users.show', title: 'Show an account', button: 'Show', fields: [USER]},
			{action: 'users.stats', title: 'Instance counts', button: 'Show', fields: []},
			{action: 'users.staff', title: 'Set or clear STAFF', button: 'Apply', fields: [USER,
				{key: 'off', label: 'Remove STAFF instead', type: 'checkbox'}],
				confirmIf: function (a) { return a.off === true; }},
			{action: 'users.verify-email', title: 'Mark the email verified', button: 'Verify', fields: [USER]}]},
		{label: 'Health', forms: [
			{action: 'health.status', title: 'Status at a glance', button: 'Run', fields: []},
			{action: 'health.check', title: 'Is it serving now (check)', button: 'Run', fields: []},
			{action: 'health.doctor', title: 'Drift and next-week risks (doctor)', button: 'Run', fields: []},
			{action: 'health.errors', title: 'Errors in the last hour', button: 'Run', fields: []},
			{action: 'health.disk', title: 'Disk', button: 'Run', fields: []},
			{action: 'health.backups', title: 'Backups', button: 'Run', fields: []}]}
	];
	var GIFT_LINK = /https:\/\/[^\s/]+\/gift\/[A-Za-z0-9]{32}/g;
	var JSON_OUTPUT = {'health.status': true, 'health.disk': true};

	var CSS = [
		':host{all:initial}',
		'.backdrop{position:fixed;inset:0;background:rgba(0,0,0,.55)}',
		'.box{position:fixed;top:5vh;left:50%;transform:translateX(-50%);width:min(900px,94vw);max-height:90vh;display:flex;flex-direction:column;background:#1e1f24;color:#e6e6e9;border:1px solid #33343b;border-radius:10px;font:14px/1.45 system-ui,sans-serif;box-shadow:0 12px 40px rgba(0,0,0,.5)}',
		'header{display:flex;align-items:center;gap:12px;padding:12px 16px;border-bottom:1px solid #33343b}',
		'h2{margin:0;font-size:16px}.who{color:#a0a1aa;font-size:12px;flex:1}',
		'button{font:inherit;background:#3c3f4a;color:#fff;border:0;border-radius:6px;padding:6px 12px;cursor:pointer}',
		'button:hover{background:#4a4e5c}button.primary{background:#5865f2}button.danger{background:#d83c3e}button:disabled{opacity:.6;cursor:wait}',
		'nav{display:flex;gap:4px;padding:8px 16px 0}nav button{background:transparent;color:#a0a1aa;border-radius:6px 6px 0 0}',
		'nav button[aria-selected="true"]{background:#2b2d35;color:#fff}',
		'.body{display:grid;grid-template-columns:minmax(260px,1fr) 1.4fr;gap:12px;padding:12px 16px 16px;overflow:hidden;min-height:0;flex:1;background:#2b2d35;border-radius:0 0 10px 10px}',
		'.forms,.out{overflow:auto;min-height:0}',
		'form{background:#1e1f24;border-radius:8px;padding:10px 12px;margin:0 0 8px}h3{margin:0 0 8px;font-size:13px}',
		'label{display:flex;flex-direction:column;gap:2px;font-size:12px;color:#a0a1aa;margin:0 0 6px}label.check{flex-direction:row;align-items:center;gap:6px}',
		'input,select{font:inherit;background:#111214;color:#e6e6e9;border:1px solid #3c3f4a;border-radius:5px;padding:5px 7px}',
		'.out{background:#111214;border-radius:8px;padding:10px 12px}',
		'pre{white-space:pre-wrap;word-break:break-word;font:12px/1.4 ui-monospace,Consolas,monospace;margin:6px 0 0}pre.stderr{color:#f0b232}',
		'.ok{color:#3ba55d;font-weight:600}.err{color:#ed4245;font-weight:600}.muted{color:#a0a1aa}',
		'.links,.choices{display:flex;flex-direction:column;gap:6px;margin:8px 0}.link{display:flex;gap:8px;align-items:center}',
		'.link code{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12px}',
		'@media (max-width:700px){.body{grid-template-columns:1fr}}'
	].join('\n');

	// --- small DOM helpers ---------------------------------------------------------
	function el(tag, attrs, children) {
		var n = document.createElement(tag);
		Object.keys(attrs || {}).forEach(function (k) {
			var v = attrs[k];
			if (v !== undefined && v !== null && v !== false) n.setAttribute(k, v === true ? '' : String(v));
		});
		(children || []).forEach(function (c) { n.appendChild(typeof c === 'string' ? document.createTextNode(c) : c); });
		return n;
	}
	// Two clicks for anything destructive: no native dialog, which would block the page.
	function arm(b) {
		b.__armed = true;
		b.__text = b.textContent;
		b.textContent = 'Click again to confirm';
		b.__timer = setTimeout(function () { disarm(b); }, 4000);
	}
	function disarm(b) {
		if (!b.__armed) return;
		clearTimeout(b.__timer);
		b.__armed = false;
		b.textContent = b.__text;
	}
	function flash(b, text) {
		var old = b.textContent;
		b.textContent = text;
		setTimeout(function () { b.textContent = old; }, 1200);
	}
	function copy(text, b) {
		navigator.clipboard.writeText(text).then(function () { flash(b, 'Copied'); }, function () { flash(b, 'Copy failed'); });
	}

	// --- the panel -----------------------------------------------------------------
	var host = null, who = null, forms = null, out = null, tabButtons = [];

	function isOpen() { return host !== null && host.style.display !== 'none'; }

	function build() {
		host = el('div', {'data-ops-panel': true});
		host.style.cssText = 'position:fixed;inset:0;z-index:2147483000;display:none';
		var root = host.attachShadow({mode: 'open'});
		root.appendChild(el('style', {}, [CSS]));
		var backdrop = el('div', {class: 'backdrop'});
		backdrop.addEventListener('click', closePanel);
		var close = el('button', {type: 'button', 'aria-label': 'Close'}, ['Close']);
		close.addEventListener('click', closePanel);
		who = el('span', {class: 'who'}, ['']);
		var nav = el('nav', {role: 'tablist'});
		tabButtons = TABS.map(function (t, i) {
			var b = el('button', {type: 'button', role: 'tab'}, [t.label]);
			b.addEventListener('click', function () { showTab(i); });
			nav.appendChild(b);
			return b;
		});
		forms = el('div', {class: 'forms'});
		out = el('div', {class: 'out'}, [el('div', {class: 'muted'}, ['Output appears here.'])]);
		root.appendChild(backdrop);
		root.appendChild(el('div', {class: 'box', role: 'dialog', 'aria-label': 'Ops'}, [
			el('header', {}, [el('h2', {}, ['Ops']), who, close]),
			nav,
			el('div', {class: 'body'}, [forms, out])
		]));
		document.body.appendChild(host);
		showTab(0);
	}

	function openPanel() {
		if (!host) build();
		host.style.display = 'block';
		refreshWho();
	}
	function closePanel() { if (host) host.style.display = 'none'; }

	function refreshWho() {
		who.textContent = '…';
		call('GET', '/whoami').then(function (res) {
			var d = res.data || {};
			if (res.status === 200) who.textContent = 'as ' + d.username + (d.staff ? '' : ' (not STAFF: the bridge will refuse)');
			else who.textContent = d.error || ('HTTP ' + res.status);
		});
	}

	function showTab(i) {
		tabButtons.forEach(function (b, j) { b.setAttribute('aria-selected', String(i === j)); });
		forms.textContent = '';
		TABS[i].forms.forEach(function (spec) { forms.appendChild(buildForm(spec)); });
	}

	function buildForm(spec) {
		var inputs = {};
		var form = el('form', {}, [el('h3', {}, [spec.title])]);
		spec.fields.forEach(function (f) {
			var input;
			if (f.type === 'select') {
				input = el('select', {}, f.options.map(function (o) { return el('option', {value: o}, [o]); }));
			} else if (f.type === 'checkbox') {
				input = el('input', {type: 'checkbox'});
			} else {
				input = el('input', {type: f.type === 'number' ? 'number' : 'text', placeholder: f.placeholder,
					min: f.min, max: f.max, value: f.value, autocomplete: 'off', spellcheck: 'false'});
			}
			inputs[f.key] = input;
			form.appendChild(el('label', {class: f.type === 'checkbox' ? 'check' : null},
				f.type === 'checkbox' ? [input, f.label] : [f.label, input]));
		});
		var button = el('button', {type: 'submit', class: spec.confirm ? 'danger' : 'primary'}, [spec.button]);
		form.appendChild(button);
		form.addEventListener('submit', function (e) {
			e.preventDefault();
			submit(spec, inputs, button);
		});
		return form;
	}

	function collect(spec, inputs) {
		var a = {};
		spec.fields.forEach(function (f) {
			var n = inputs[f.key];
			if (f.type === 'checkbox') a[f.key] = n.checked;
			else if (f.type === 'number') { if (n.value !== '') a[f.key] = Number(n.value); }
			else { var v = n.value.trim(); if (v !== '') a[f.key] = v; }
		});
		return spec.prepare ? spec.prepare(a) : a;
	}

	function submit(spec, inputs, button) {
		var args = collect(spec, inputs);
		var needsConfirm = spec.confirm || (spec.confirmIf && spec.confirmIf(args));
		if (needsConfirm && !button.__armed) { arm(button); return; }
		disarm(button);
		button.disabled = true;
		run(spec.action, args).then(function () { button.disabled = false; });
	}

	function run(action, args) {
		out.textContent = '';
		out.appendChild(el('div', {class: 'muted'}, ['Running ' + action + '…']));
		return call('POST', '/run', {action: action, args: args}).then(function (res) {
			render(action, args, res);
			return res;
		});
	}

	function render(action, args, res) {
		out.textContent = '';
		var d = res.data || {};
		if (res.status !== 200) {
			out.appendChild(el('div', {class: 'err'}, [d.error || ('HTTP ' + res.status)]));
			return;
		}
		out.appendChild(el('div', {class: d.exit === 0 ? 'ok' : 'err'},
			[action + ': exit ' + d.exit + (d.timed_out ? ' (timed out)' : '')]));
		var links = (d.stdout || '').match(GIFT_LINK) || [];
		if (links.length) {
			var all = el('button', {type: 'button', class: 'primary'}, ['Copy all ' + links.length]);
			all.addEventListener('click', function () { copy(links.join('\n'), all); });
			var list = el('div', {class: 'links'}, [all]);
			links.forEach(function (link) {
				var b = el('button', {type: 'button'}, ['Copy']);
				b.addEventListener('click', function () { copy(link, b); });
				list.appendChild(el('div', {class: 'link'}, [el('code', {}, [link]), b]));
			});
			out.appendChild(list);
		}
		if (d.choices) renderChoices(args, d.choices);
		var stdout = d.stdout || '';
		if (JSON_OUTPUT[action]) {
			try { stdout = JSON.stringify(JSON.parse(stdout), null, 2); } catch (e) { /* show it raw */ }
		}
		if (stdout) out.appendChild(el('pre', {}, [stdout]));
		if (d.stderr) out.appendChild(el('pre', {class: 'stderr'}, [d.stderr]));
	}

	function renderChoices(args, choices) {
		var box = el('div', {class: 'choices'}, [el('div', {}, [
			'Lifetime links need one community to hold the Visionary role. Pick it: this creates the role there if it is missing, and restarts the gateway once.'])]);
		choices.forEach(function (c) {
			var b = el('button', {type: 'button', class: 'danger'}, [c.name + ' (' + c.id + ')']);
			b.addEventListener('click', function () {
				if (!b.__armed) { arm(b); return; }
				disarm(b);
				run('gifts.setup-lifetime', {community: c.id}).then(function (res) {
					if (res.status === 200 && res.data.exit === 0) run('gifts.create', args);
				});
			});
			box.appendChild(b);
		});
		out.appendChild(box);
	}

	// Keystrokes in the panel are the panel's. This capture listener is registered
	// before the bundle's, so it runs first: the app's global shortcuts and its
	// "typing anywhere goes to the composer" never see them. Typing still works, since
	// stopping propagation does not cancel the default action.
	['keydown', 'keyup', 'keypress'].forEach(function (type) {
		window.addEventListener(type, function (e) {
			try {
				if (!isOpen() || e.composedPath().indexOf(host) === -1) return;
				if (type === 'keydown' && e.key === 'Escape') closePanel();
				e.stopImmediatePropagation();
			} catch (err) { /* never break the app */ }
		}, true);
	});

	// --- 2. the menu item ------------------------------------------------------------
	// The STAFF menu is a [role=menu] holding icons whose data-flx starts with this.
	// Items themselves carry only generic data-flx values, so it is found by content.
	var MENU_MARK = '[data-flx^="channel.channel-header-components.developer-tools-context-menu."]';

	function addMenuItem(menu) {
		if (menu.querySelector('[data-ops-panel-item]')) return;
		var items = menu.querySelectorAll('[role="menuitem"]');
		if (!items.length) return;
		var proto = null;
		for (var i = 0; i < items.length; i++) if (!items[i].hasAttribute('aria-haspopup')) proto = items[i];
		proto = proto || items[items.length - 1];
		var lastGroup = items[items.length - 1].parentElement;
		var group = lastGroup.cloneNode(false);
		group.removeAttribute('id');
		var item = proto.cloneNode(true);
		['id', 'aria-haspopup', 'aria-expanded', 'data-highlighted', 'aria-checked', 'data-checked', 'aria-disabled', 'data-disabled']
			.forEach(function (a) { item.removeAttribute(a); });
		Array.prototype.forEach.call(item.querySelectorAll('svg,[role="img"]'), function (n) { n.remove(); });
		var label = item.querySelector('[class*="itemLabelText"]') || item;
		label.textContent = 'Ops…';
		item.setAttribute('data-flx', 'ops-panel.menu-item');
		item.setAttribute('data-ops-panel-item', '');
		item.addEventListener('mouseenter', function () { item.setAttribute('data-highlighted', ''); });
		item.addEventListener('mouseleave', function () { item.removeAttribute('data-highlighted'); });
		item.addEventListener('click', function (e) {
			e.preventDefault();
			e.stopPropagation();
			menu.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}));
			openPanel();
		});
		group.appendChild(item);
		lastGroup.parentElement.appendChild(group);
	}

	var scheduled = false;
	function scan() {
		scheduled = false;
		try {
			var menus = document.querySelectorAll('[role="menu"]');
			for (var i = 0; i < menus.length; i++) if (menus[i].querySelector(MENU_MARK)) addMenuItem(menus[i]);
		} catch (e) { /* never break the app */ }
	}
	function start() {
		new MutationObserver(function () {
			if (!scheduled) {
				scheduled = true;
				requestAnimationFrame(scan);
			}
		}).observe(document.body, {childList: true, subtree: true});
	}
	if (document.body) start();
	else document.addEventListener('DOMContentLoaded', start);
})();
```

- [ ] **Step 2: Syntax check with the api image's node**

Run:
```sh
docker run --rm -v "$PWD:/w:ro" -w /w ghcr.io/fluxerapp/fluxer-api:v1 node --check ops-panel.js \
	&& echo SYNTAX_OK
```
Expected: `SYNTAX_OK`.

- [ ] **Step 3: Smoke-test in a browser against the live app (read-only)**

The bridge is not deployed yet. This checks the menu and the UI only.
1. Open `https://fluxer.kipavy.fr/` as the STAFF account.
2. Run the file's contents in the page context (devtools console, or the browser tool's JavaScript runner).
3. Make one api call by opening "Members".
4. Click the STAFF (developer tools) header button.

Expected:
- the menu ends with an "Ops…" item, styled like its neighbours, and hovering highlights it;
- clicking it closes the menu and opens the panel;
- all four tabs render their forms;
- running "Health → Status" shows a red line. The `/ops-api/` route does not exist yet, so the error is "HTTP 200: the bridge did not answer…" or "HTTP 404…";
- Escape and the backdrop both close the panel.

- [ ] **Step 4: Check that keystrokes stay in the panel (Review Focus 3)**

In the same tab, open the panel, then:
1. Click the Gifts → Code field and type `abc`, then Backspace once.
2. Close the panel.

Expected: the field shows `ab`. The message composer is still empty and no app shortcut fired.

- [ ] **Step 5: Run the selftest and commit**

Run: `./selftest.sh`
Expected: `PASS  ops tooling intact`.

```bash
git add ops-panel.js
git commit -m "panel: ops-panel.js - token capture, STAFF menu item, Ops panel UI

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Roll out on the live instance, README, end-to-end check

**Order: Steps 8 and 9 come first**, in the dev clone on the branch: the README ships in the same PR as the code. **Then STOP.** Steps 1–7 change the live instance:
- `edge` is recreated, so the whole site blips for a few seconds;
- `app-proxy` is recreated;
- a systemd unit is installed with sudo.

Before Step 1, ask the user in chat:
1. whether PR #5 (branch `staff-ops-panel`) may be merged first, or whether the live checkout should be switched to the branch;
2. for a go-ahead to roll out.

Do not continue without a yes. Steps 1–7 are the rollout and end-to-end check.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Bring the live checkout to the new code**

Run, after the merge:
```sh
cd ~/Documents/fluxer/ops
git pull --ff-only
./selftest.sh
```
If the user chose the branch instead, run `git fetch && git checkout staff-ops-panel` in place of the pull.
Expected: `PASS  ops tooling intact`.

- [ ] **Step 2: Move the badge override onto overlay.sh**

Run:
```sh
./overlay.sh apply
head -n 1 ../docker-compose.override.yml
./doctor.sh --quiet
echo "doctor rc=$?"
```
Expected:
- the first line is `# generated by ops/overlay.sh - do not edit by hand`;
- the output says `Client overlay: badge on, Ops panel off.`;
- doctor prints no new FAIL (the known warnings are fine).

Then run:
```sh
d=$(sed -n 's/^FLUXER_DOMAIN=//p' ../.env)
curl -s --resolve "$d:443:127.0.0.1" "https://$d/" | grep -c "$(head -n 1 patches/html.names)"
```
Expected: at least `1`. The served index still loads the badge's patched loader.

- [ ] **Step 3: Turn the panel on**

Run: `./panel.sh on`
Expected:
- `Installing /etc/systemd/system/fluxer-ops-bridge.service (sudo).`
- `Bridge answering on …/panel/run/bridge.sock.`
- `Client overlay: badge on, Ops panel on.`
- the final `Ops panel on. Reload the web app…`

Then run:
```sh
(cd .. && docker compose config | grep -n -e 'Caddyfile' -e 'ops-panel' -e 'fluxer-ops')
./panel.sh status
./doctor.sh --quiet
echo "doctor rc=$?"
```
Expected:
- edge mounts `…/ops/panel/Caddyfile:/etc/caddy/Caddyfile`, `…/panel/www:/srv/ops-panel` and `…/panel/run:/run/fluxer-ops`, and no longer mounts `./Caddyfile`;
- status shows `panel on`, `bridge active`, `socket answering`, `route live through edge`;
- doctor prints no FAIL from `check_overlay` or `check_panel`.

- [ ] **Step 4: Bad tokens are refused through the public route**

Run:
```sh
d=$(sed -n 's/^FLUXER_DOMAIN=//p' ../.env)
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Authorization: bogus-token' \
	-H 'Content-Type: application/json' --data '{"action":"gifts.list"}' "https://$d/ops-api/run"
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "Origin: https://evil.test" -H 'Authorization: x' \
	--data '{}' "https://$d/ops-api/run"
```
Expected: `401`, then `403`. These go through Cloudflare, to prove the public path behaves too.

- [ ] **Step 5: End to end in the browser, as the STAFF account**

1. Reload `https://fluxer.kipavy.fr/`.
2. Open the STAFF menu, then "Ops…". The header shows `as <username>`.
3. Gifts → Create gift links: duration `1w`, how many `1`, then Create. Expected: `gifts.create: exit 0`, one link with a Copy button.
4. Open the copied link in a new tab. Expected: the gift page shows a one-week gift.
5. Back in the panel, Gifts → Delete a code: paste the code, then click twice. Expected: `gifts.rm: exit 0`.
6. Health → Status. Expected: pretty-printed JSON with `"version"`.
7. Run `journalctl -u fluxer-ops-bridge -n 20 --no-pager | grep audit`. Expected: two `audit:` lines, for `gifts.create` and `gifts.rm`, naming the account.

- [ ] **Step 6: Keystrokes stay in the panel (Review Focus 3)**

With the panel open, type into Users → Show an account → User, then press Enter.
Expected: the text is in the field and `users.show` runs. Nothing appears in the message composer.

- [ ] **Step 7: The app survives a dead bridge (Review Focus 4)**

Run `sudo systemctl stop fluxer-ops-bridge`. Then reload the web app and use it normally: open a channel and send nothing.
Expected: the app loads normally. "Ops…" → Health → Status shows a red line ending with `Is it running? (fluxer panel status)`.

Then run `sudo systemctl start fluxer-ops-bridge && ./panel.sh status`.
Expected: `socket answering`.

- [ ] **Step 8: README**

Add a section after `## Accounts from a shell: \`fluxer users\``:

```markdown
## In-app Ops panel: `fluxer panel`

The account commands and the read-only health ones, from the web app instead of a
shell. A STAFF account opens the STAFF (developer tools) menu in a channel header,
then **Ops…**, which has four tabs:

- Gifts: create links (copy buttons included), list, show, revoke, delete, redeem.
- Premium: grant, revoke, list.
- Users: list, show, counts, STAFF on or off, mark an email verified.
- Health: status, check, doctor, errors, disk, backups.

```sh
fluxer panel on        # install the bridge, add the route and the script
fluxer panel status    # is it on, is the bridge answering, is the route live
fluxer panel off       # the kill switch: bridge, route and script all gone
```

How it holds together:

- **The bridge.** `ops_bridge.py` runs as a systemd unit (`fluxer-ops-bridge`) under this
  user, with `NoNewPrivileges`, so nothing it starts can `sudo`. It listens on a Unix
  socket in `ops/panel/run`, which only `edge` mounts; no port is opened.
- **Each request.** The bridge asks the api who the session token belongs to and reads
  the STAFF flag from the database every time, so removing STAFF cuts access at once.
  It then runs one command from a fixed allowlist with a fixed argv: there is no shell,
  and every argument is checked against a pattern.
- **Audit.** Every change is logged (`journalctl -u fluxer-ops-bridge | grep audit`)
  and sent through `notify.sh` under the key `ops-panel`. Any STAFF account can use
  the panel, including to give STAFF to someone else, and that is the trace it leaves.
- **The script.** `ops-panel.js` is served by `edge` at `/ops-panel.js`. `overlay.sh`
  puts it in `index.html` ahead of the app's bundle, because it has to see the app's
  first api calls to pick up the session. `overlay.sh` is now the only writer of
  `docker-compose.override.yml`: it composes the badge patch and the panel, so either
  can be turned off without the other.
- **Updates.** `update.sh` takes both off before an update and puts them back after
  (`fluxer panel refresh` rebuilds the Caddyfile copy from upstream's new one).
  `doctor` flags a copy that has drifted from upstream's.

**Web app only.** The desktop and mobile apps never load this server's `index.html`
(see *Known gaps*), so the panel, like the badge, is not there.
```

In *Known gaps*, change the bullet's opening sentence to:

```markdown
- **Client-side changes reach the web app only.** Anything this repository puts into
  the client (the Visionary badge and the STAFF Ops panel) is served through this
  instance's
```

Keep the rest of that bullet as it is. Also add `panel` to the `Host` line of the command overview block near the top (`Host      notify  disk  env  cf-ips  firewall-fix  setup  panel`), and add these rows to the *Scripts* table:

```markdown
| `overlay.sh` | `badge-patch.sh`, `panel.sh`, `update.sh` | The one writer of `docker-compose.override.yml` and the served `index.html`: composes the badge patch and the Ops panel. `suspend` drops it for an update. |
| `panel.sh` | you, `update.sh` (`refresh`) | The in-app STAFF Ops panel: bridge unit, Caddy route, script. `off` is the kill switch. |
| `ops_bridge.py` | systemd (`fluxer-ops-bridge`) | Runs allowlisted commands for the Ops panel after checking the session and STAFF. |
```

- [ ] **Step 9: Run the selftest, commit and push**

Run: `./selftest.sh --lint`
Expected: `PASS  ops tooling intact`.

```bash
git add README.md
git commit -m "README: the in-app Ops panel, overlay.sh, and the panel among the web-only patches

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push
```

Make this commit in the dev clone (`~/fluxer-ops-dev`) and push it to the branch. Then go back to the STOP above Step 1. Never commit from the live checkout.
