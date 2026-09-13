#!/bin/sh
# selftest.sh - prove the ops tooling itself is intact, without touching the instance.
#
#   selftest.sh          syntax, dispatcher wiring, help output
#   selftest.sh --lint   also shellcheck everything (pulls koalaman/shellcheck once)
#
# `fluxer` is a dispatcher over a dozen scripts, and a typo in its case table, a lost
# execute bit or a renamed script only shows up when that one command is needed -
# typically `restore`, on the worst day. This runs in seconds and changes nothing:
# no container is started (bar shellcheck), no database is queried, nothing is sent.
set -eu

OPS=$(cd "$(dirname "$0")" && pwd)
LINT=0
case "${1:-}" in
	--lint) LINT=1 ;;
	'') ;;
	*) echo "usage: selftest.sh [--lint]" >&2; exit 2 ;;
esac

fails=0
ok() { printf 'ok    %s\n' "$*"; }
fail() { fails=$((fails + 1)); printf 'FAIL  %s\n' "$*"; }

cd "$OPS"
# lib.sh is sourced, not run: it must parse, but it is not a command.
scripts=$(ls ./*.sh fluxer | sed 's|^\./||' | grep -vx 'lib.sh')
sh -n lib.sh 2>/dev/null || fail "lib.sh does not parse"

# 1. Every script parses and is executable.
for f in $scripts; do
	if ! sh -n "$f" 2>/dev/null; then fail "$f does not parse"; continue; fi
	[ -x "$f" ] || { fail "$f is not executable"; continue; }
done
bash -n completion.bash 2>/dev/null || fail "completion.bash does not parse"
[ "$fails" -eq 0 ] && ok "$(printf '%s\n' "$scripts" | grep -c .) scripts parse and are executable"

# 2. Every script the dispatcher execs exists.
missing=$(grep -o '"$OPS/[a-z-]*\.sh"' fluxer | sed 's|"$OPS/||; s|"$||' | sort -u \
	| while read -r s; do [ -x "$s" ] || printf '%s ' "$s"; done)
if [ -n "$missing" ]; then fail "dispatcher names missing scripts: $missing"
else ok "every script the dispatcher runs exists"; fi

# 3. Every command in the help text is dispatched, and every dispatched command is in
#    the help text, so the two cannot drift apart.
help_cmds=$(./fluxer help | sed -n 's/^  fluxer \([a-z-]*\).*/\1/p' | sort -u)
case_cmds=$(sed -n '/^case "$cmd" in/,/^esac/p' fluxer \
	| sed -n 's/^\t\([a-z| -]*\)).*/\1/p' | tr '|' '\n' | tr -d ' \t' | grep -v '^$' | sort -u)
undispatched=$(for c in $help_cmds; do printf '%s\n' "$case_cmds" | grep -qxF -- "$c" || printf '%s ' "$c"; done)
[ -z "$undispatched" ] && ok "every command in the help is dispatched" \
	|| fail "in the help but not dispatched: $undispatched"
# Aliases and the stack verbs shown on one shared line are fine to leave out.
undocumented=$(for c in $case_cmds; do
	case "$c" in help | --help | -h | verify | gift | down | ps | valkey) continue ;; esac
	printf '%s\n' "$help_cmds" | grep -qxF -- "$c" || printf '%s ' "$c"
done)
[ -z "$undocumented" ] && ok "every dispatched command is in the help" \
	|| fail "dispatched but not in the help: $undocumented"

# 4. Every command in the completion is real, and every real one completes.
comp_cmds=$(bash -c '. ./completion.bash; COMP_WORDS=(fluxer ""); COMP_CWORD=1; _fluxer; printf "%s\n" "${COMPREPLY[@]}"' | sort -u)
comp_bad=0
for c in $case_cmds; do
	case "$c" in --help | -h | verify | gift) continue ;; esac
	printf '%s\n' "$comp_cmds" | grep -qxF -- "$c" || { fail "completion does not offer: $c"; comp_bad=1; }
done
for c in $comp_cmds; do
	printf '%s\n' "$case_cmds" | grep -qxF -- "$c" || { fail "completion offers unknown command: $c"; comp_bad=1; }
done
[ "$comp_bad" -eq 0 ] && ok "completion covers the dispatcher"

./fluxer help > /dev/null && ok "help text renders"

# 5. Nothing secret is tracked.
tracked=$(git -C "$OPS" ls-files 2>/dev/null | grep -E '(^|/)(\.env|notify\.conf|offsite\.conf)$|\.dump$|\.tgz$' || true)
[ -z "$tracked" ] && ok "no secrets or backup artifacts tracked by git" || fail "tracked secrets: $tracked"

# 7. Paths come from lib.sh, never from the file: a host laid out differently
#    must not need edits. Excludes this file itself: it necessarily contains the
#    string it greps for, right here.
hard=$(grep -l '/home/ubuntu' ./*.sh fluxer completion.bash ./*.example 2>/dev/null \
	| sed 's|^\./||' | grep -vx 'selftest.sh' || true)
[ -z "$hard" ] && ok "no hardcoded /home/ubuntu paths" || fail "hardcoded /home/ubuntu in: $hard"
nolib=$(for f in $(grep -l 'FLUXER_DIR' ./*.sh fluxer | sed 's|^\./||'); do
	case "$f" in lib.sh | get.sh | selftest.sh) continue ;; esac
	grep -q '/lib\.sh"' "$f" || printf '%s ' "$f"
done)
[ -z "$nolib" ] && ok "every script that needs the instance sources lib.sh" || fail "does not source lib.sh: $nolib"

# 6. The tests. Scratch directories and stubs only: nothing here reaches the instance.
for t in tests/*_test.sh; do
	if out=$(sh "$t" 2>&1); then
		ok "$t"
	else
		fail "$t:"; printf '%s\n' "$out" | grep -v '^ok ' | sed 's/^/      /'
	fi
done

if [ "$LINT" -eq 1 ]; then
	# shellcheck disable=SC2086 # $scripts is a list of plain file names
	if out=$(docker run --rm -v "$OPS:/mnt:ro" -w /mnt koalaman/shellcheck:stable -S warning $scripts lib.sh tests/*.sh 2>&1); then
		ok "shellcheck clean (warnings and above)"
	else
		fail "shellcheck:"; printf '%s\n' "$out" | sed 's/^/      /'
	fi
fi

echo
[ "$fails" -eq 0 ] && { echo "PASS  ops tooling intact"; exit 0; }
echo "$fails problem(s)"; exit 1
