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
