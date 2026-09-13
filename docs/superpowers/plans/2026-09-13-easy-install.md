# Easy Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One pasted line takes a server with a domain to a live, backed-up, watched Fluxer instance, or wires fluxer-ops onto an instance that already runs.

**Architecture:** `get.sh` (curl target) only clones the repo next to the instance and hands over to `setup.sh`. `setup.sh` runs five phases: prerequisites, instance (detect, or pre-flight DNS/ports and run the checksum-verified upstream `install.sh`), core wiring (what `install-host.sh` did), optional extras, finish. A sourced `lib.sh` replaces every hardcoded `/home/ubuntu/...` default by resolving `OPS`, `FLUXER_DIR`, `BACKUP_ROOT` at run time.

**Tech Stack:** POSIX `sh` (dash-compatible, like every script here), `bash` only for `completion.bash`, `python3` for CIDR matching, shellcheck via `koalaman/shellcheck:stable`.

**Spec:** `docs/superpowers/specs/2026-09-13-easy-install-design.md`

## Global Constraints

- All scripts `#!/bin/sh`, `set -eu`, tabs for indentation, comments explain *why* (match the existing files).
- No script, `completion.bash` or `*.example` may contain `/home/ubuntu` after Task 2.
- This host must keep working with no config change: `/home/ubuntu/Documents/fluxer` with `ops/` inside, backups in `/home/ubuntu/Documents/fluxer-backups`.
- Upstream installer: `https://fluxer.dev/install.sh` + `https://fluxer.dev/install.sh.sha256`, verified with `sha256sum -c` before it runs.
- Upstream installer flags used: `--dir --domain --email --non-interactive [--allow-root]`. Its exit codes: 1 usage, 2 prerequisite, 3 refused to overwrite, 4 download, 5 secret generation, 6 stack did not come up, 7 backup, 130 interrupted.
- Docker Compose floor: `2.24.4`.
- Ports: `80/tcp 443/tcp 7881/tcp 7882/udp`.
- Status marks: `✓` done/present, `→` doing, `✗` failed, `–` skipped.
- Tests never touch the live instance, real crontabs, real sudo, or the network. Every external command setup.sh uses is overridable by env var for that reason.
- `selftest.sh` must pass after every task. Commit after every task, ending messages with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.

## File Map

| File | Status | Responsibility |
| --- | --- | --- |
| `lib.sh` | create | Resolve `OPS`, `FLUXER_DIR`, `BACKUP_ROOT`; `need_instance`. Sourced, not executable. |
| `tests/assert.sh` | create | `pass`/`fail`/`assert_eq`/`assert_contains`/`finish`. Sourced by tests. |
| `tests/lib_test.sh` | create | lib.sh resolution cases in scratch dirs. |
| `tests/setup_test.sh` | create | setup.sh pure helpers and phases with stubs. |
| `tests/get_test.sh` | create | get.sh against a scratch git repo with a stub setup.sh. |
| `setup.sh` | create | The guided install, five phases. |
| `get.sh` | create | curl target: find instance, clone/pull, hand over. |
| `install-host.sh` | rewrite | Two-line wrapper: `setup.sh --no-extras`. |
| every other `*.sh`, `fluxer`, `completion.bash` | modify | Source `lib.sh` instead of hardcoded defaults. |
| `fluxer`, `completion.bash` | modify | `setup` command. |
| `selftest.sh` | modify | lib.sh as library, run `tests/*_test.sh`, path and lib checks. |
| `offsite.conf.example` | modify | `$HOME` instead of `/home/ubuntu`. |
| `README.md` | modify | Quick start, troubleshooting, no host-specific install path. |

---

### Task 1: `lib.sh`, test harness, selftest runs tests

**Files:**
- Create: `lib.sh`, `tests/assert.sh`, `tests/lib_test.sh`
- Modify: `selftest.sh` (section 1 and a new section 6)

**Interfaces:**
- Produces: sourcing `lib.sh` sets `OPS` (real dir of `${OPS_SELF:-$0}`), `FLUXER_DIR` (may be empty), `BACKUP_ROOT` (empty iff `FLUXER_DIR` empty); defines `fluxer_projects` (prints instance dirs known to `docker compose ls`, one per line) and `need_instance` (returns 0, or exits 2 with a message on stderr).
- Produces: `tests/assert.sh` with `pass <msg>`, `fail <msg>`, `assert_eq <name> <expected> <actual>`, `assert_contains <name> <needle> <haystack>`, `finish` (exit 1 if any fail).

- [ ] **Step 1: Write the harness**

`tests/assert.sh`:

```sh
# shellcheck shell=sh
# assert.sh - the few assertions the tests need. Sourced, never run.
fails=0
pass() { printf 'ok    %s\n' "$*"; }
fail() { fails=$((fails + 1)); printf 'FAIL  %s\n' "$*"; }
assert_eq() { # <name> <expected> <actual>
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected [$2], got [$3]"; fi
}
assert_contains() { # <name> <needle> <haystack>
	case "$3" in *"$2"*) pass "$1" ;; *) fail "$1: [$2] not in [$3]" ;; esac
}
finish() {
	[ "$fails" -eq 0 ] && return 0
	echo "$fails failed"
	exit 1
}
```

- [ ] **Step 2: Write the failing lib test**

`tests/lib_test.sh` (mode 755):

```sh
#!/bin/sh
# lib_test.sh - how lib.sh finds the instance, in scratch directories. Touches nothing:
# docker is stubbed, so the host's real instance can never leak into a result.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OPS_SRC=$(dirname "$HERE")
. "$HERE/assert.sh"
tmp=$(readlink -f "$(mktemp -d)")
trap 'rm -rf "$tmp"' EXIT

# <inst>/docker-compose.yml with ops/ inside: the layout upstream and get.sh produce.
mkdir -p "$tmp/inst/ops" "$tmp/bin" "$tmp/stub" "$tmp/other" "$tmp/loose/ops"
: > "$tmp/inst/docker-compose.yml"
for d in "$tmp/inst/ops" "$tmp/loose/ops"; do
	cp "$OPS_SRC/lib.sh" "$d/lib.sh"
	cat > "$d/probe" <<'EOF'
#!/bin/sh
set -eu
. "$(dirname "$(readlink -f "$0")")/lib.sh"
printf '%s|%s|%s\n' "$OPS" "$FLUXER_DIR" "$BACKUP_ROOT"
[ "${NEED:-0}" = 1 ] && need_instance
exit 0
EOF
	chmod +x "$d/probe"
done
ln -s "$tmp/inst/ops/probe" "$tmp/bin/probe"

# docker stub: `compose ls` prints whatever $LS_JSON holds, everything else fails.
cat > "$tmp/stub/docker" <<'EOF'
#!/bin/sh
[ "$1 $2" = "compose ls" ] && { printf '%s\n' "${LS_JSON:-[]}"; exit 0; }
exit 1
EOF
chmod +x "$tmp/stub/docker"
run() { env -u FLUXER_DIR -u BACKUP_ROOT PATH="$tmp/stub:$PATH" "$@"; }

assert_eq "parent of ops/ is the instance" \
	"$tmp/inst/ops|$tmp/inst|$tmp/fluxer-backups" "$(run "$tmp/inst/ops/probe")"

assert_eq "found through a symlink" \
	"$tmp/inst/ops|$tmp/inst|$tmp/fluxer-backups" "$(run "$tmp/bin/probe")"

assert_eq "FLUXER_DIR from the environment wins" \
	"$tmp/inst/ops|$tmp/other|$tmp/fluxer-backups" "$(run env FLUXER_DIR="$tmp/other" "$tmp/inst/ops/probe")"

assert_eq "BACKUP_ROOT from the environment wins" \
	"$tmp/inst/ops|$tmp/inst|/b" "$(run env BACKUP_ROOT=/b "$tmp/inst/ops/probe")"

printf 'FLUXER_DOMAIN=x.test\n' > "$tmp/other/.env"
json="[{\"Name\":\"fluxer\",\"Status\":\"running(3)\",\"ConfigFiles\":\"$tmp/other/docker-compose.yml,$tmp/other/docker-compose.override.yml\"}]"
assert_eq "one compose project with a Fluxer .env is found" \
	"$tmp/loose/ops|$tmp/other|$tmp/fluxer-backups" "$(run env LS_JSON="$json" "$tmp/loose/ops/probe")"

mkdir -p "$tmp/second" && printf 'FLUXER_DOMAIN=y.test\n' > "$tmp/second/.env"
json2="[{\"Name\":\"a\",\"Status\":\"running(1)\",\"ConfigFiles\":\"$tmp/other/docker-compose.yml\"},{\"Name\":\"b\",\"Status\":\"running(1)\",\"ConfigFiles\":\"$tmp/second/docker-compose.yml\"}]"
assert_eq "two Fluxer projects: not guessed" \
	"$tmp/loose/ops||" "$(run env LS_JSON="$json2" "$tmp/loose/ops/probe")"

out=$(run env NEED=1 "$tmp/loose/ops/probe" 2>&1) && rc=0 || rc=$?
assert_eq "need_instance exits 2 when nothing is found" 2 "$rc"
assert_contains "need_instance says how to fix it" "FLUXER_DIR=" "$out"

finish
```

- [ ] **Step 3: Run it to verify it fails**

Run: `sh tests/lib_test.sh`
Expected: FAIL lines / `cp: cannot stat '.../lib.sh'` and a non-zero exit.

- [ ] **Step 4: Write `lib.sh`**

`lib.sh` (mode 644, not executable):

```sh
# shellcheck shell=sh
# lib.sh - where things are. Sourced by every script here; not a command.
#
# Sets OPS (this directory, symlinks resolved), FLUXER_DIR and BACKUP_ROOT, so no
# script carries a path of its own and a host laid out differently needs no edits.
#
# FLUXER_DIR, first match wins:
#   1. FLUXER_DIR from the environment (cron lines written by setup.sh set it)
#   2. the directory above ops/, if it holds docker-compose.yml: the usual layout
#   3. the one Fluxer project `docker compose ls` knows about
# Otherwise it is empty, and need_instance says where it looked and how to fix it.
# Two Fluxer projects are never guessed between.
#
# BACKUP_ROOT: from the environment, else fluxer-backups next to the instance.

OPS=$(dirname "$(readlink -f "${OPS_SELF:-$0}")")

# Directories of compose projects whose .env names a FLUXER_DOMAIN, one per line.
# Silent without docker, or without permission to talk to it. No python: get.sh
# runs the same pipeline before anything but git is known to be installed.
fluxer_projects() {
	command -v docker > /dev/null 2>&1 || return 0
	docker compose ls --all --format json 2> /dev/null \
		| grep -o '"ConfigFiles":"[^"]*"' \
		| sed 's/^"ConfigFiles":"//; s/[",].*//' \
		| while IFS= read -r f; do
			d=$(dirname "$f")
			if grep -q '^FLUXER_DOMAIN=' "$d/.env" 2> /dev/null; then printf '%s\n' "$d"; fi
		done | sort -u
}

if [ -z "${FLUXER_DIR:-}" ]; then
	if [ -f "$(dirname "$OPS")/docker-compose.yml" ]; then
		FLUXER_DIR=$(dirname "$OPS")
	else
		_found=$(fluxer_projects)
		if [ -n "$_found" ] && [ "$(printf '%s\n' "$_found" | grep -c .)" -eq 1 ]; then
			FLUXER_DIR=$_found
		else
			FLUXER_DIR=''
		fi
		unset _found
	fi
fi
if [ -n "$FLUXER_DIR" ]; then
	BACKUP_ROOT=${BACKUP_ROOT:-$(dirname "$FLUXER_DIR")/fluxer-backups}
else
	BACKUP_ROOT=${BACKUP_ROOT:-}
fi

need_instance() {
	[ -n "$FLUXER_DIR" ] && return 0
	cat >&2 <<EOF
No Fluxer instance found. Looked at:
  - FLUXER_DIR (not set)
  - $(dirname "$OPS") (no docker-compose.yml)
  - docker compose ls (no single Fluxer project)
Point at it:   FLUXER_DIR=/path/to/fluxer $(basename "${OPS_SELF:-$0}") ...
Or install:    $OPS/setup.sh
EOF
	exit 2
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `sh tests/lib_test.sh`
Expected: every line `ok`, exit 0.

- [ ] **Step 6: Make selftest treat lib.sh as a library and run the tests**

In `selftest.sh`, section 1, replace:

```sh
scripts=$(ls ./*.sh fluxer | sed 's|^\./||')
```

with:

```sh
# lib.sh is sourced, not run: it must parse, but it is not a command.
scripts=$(ls ./*.sh fluxer | sed 's|^\./||' | grep -vx 'lib.sh')
sh -n lib.sh 2>/dev/null || fail "lib.sh does not parse"
```

Before the `if [ "$LINT" -eq 1 ]` block, add:

```sh
# 6. The tests. Scratch directories and stubs only: nothing here reaches the instance.
for t in tests/*_test.sh; do
	if out=$(sh "$t" 2>&1); then
		ok "$t"
	else
		fail "$t:"; printf '%s\n' "$out" | grep -v '^ok ' | sed 's/^/      /'
	fi
done
```

In the shellcheck line, lint `lib.sh` and the tests too: replace `$scripts 2>&1` with `$scripts lib.sh tests/*.sh 2>&1`.

- [ ] **Step 7: Run selftest**

Run: `./selftest.sh`
Expected: `PASS  ops tooling intact`, including `ok    tests/lib_test.sh`.

- [ ] **Step 8: Commit**

```bash
git add lib.sh tests/assert.sh tests/lib_test.sh selftest.sh
git commit -m "Add lib.sh to resolve the instance and backup paths at run time"
```

---

### Task 2: Every script sources `lib.sh`

**Files:**
- Modify: `backup.sh badge-patch.sh cf-ips.sh changelog.sh check.sh debug.sh disk.sh doctor.sh env.sh firewall-fix.sh gifts.sh notify.sh offsite.sh premium.sh prune.sh update.sh users.sh watchdog.sh fluxer completion.bash offsite.conf.example install-host.sh selftest.sh`

**Interfaces:**
- Consumes: `lib.sh` from Task 1 (`OPS`, `FLUXER_DIR`, `BACKUP_ROOT`, `need_instance`).
- Produces: no script defines its own path defaults; `$OPS` is the ops directory everywhere.

- [ ] **Step 1: Write the failing selftest checks**

In `selftest.sh`, after section 5, add:

```sh
# 7. Paths come from lib.sh, never from the file: a host laid out differently
#    must not need edits.
hard=$(grep -l '/home/ubuntu' ./*.sh fluxer completion.bash ./*.example 2>/dev/null | sed 's|^\./||' || true)
[ -z "$hard" ] && ok "no hardcoded /home/ubuntu paths" || fail "hardcoded /home/ubuntu in: $hard"
nolib=$(for f in $(grep -l 'FLUXER_DIR' ./*.sh fluxer | sed 's|^\./||'); do
	case "$f" in lib.sh | get.sh | selftest.sh) continue ;; esac
	grep -q '/lib\.sh"' "$f" || printf '%s ' "$f"
done)
[ -z "$nolib" ] && ok "every script that needs the instance sources lib.sh" || fail "does not source lib.sh: $nolib"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `./selftest.sh`
Expected: `FAIL  hardcoded /home/ubuntu in: backup.sh badge-patch.sh ...` and `FAIL  does not source lib.sh: ...`.

- [ ] **Step 3: Replace the defaults mechanically**

```sh
LIB='. "$(dirname "$(readlink -f "$0")")/lib.sh"'
for f in backup.sh badge-patch.sh cf-ips.sh changelog.sh check.sh debug.sh disk.sh doctor.sh \
	env.sh firewall-fix.sh gifts.sh notify.sh offsite.sh premium.sh prune.sh update.sh users.sh \
	watchdog.sh fluxer; do
	python3 - "$f" "$LIB" <<'PY'
import re, sys
path, lib = sys.argv[1], sys.argv[2]
s = open(path).read()
s = s.replace('FLUXER_DIR=${FLUXER_DIR:-/home/ubuntu/Documents/fluxer}\n', lib + '\n', 1)
s = s.replace('BACKUP_ROOT=${BACKUP_ROOT:-/home/ubuntu/Documents/fluxer-backups}\n', '')
s = s.replace('OPS="$FLUXER_DIR/ops"\n', '')
s = s.replace('"$(cd "$(dirname "$0")" && pwd)/notify.sh"', '"$OPS/notify.sh"')
s = s.replace('$FLUXER_DIR/ops/', '$OPS/').replace('"$FLUXER_DIR/ops/', '"$OPS/')
s = s.replace('$FLUXER_DIR/ops"', '$OPS"')
open(path, 'w').write(s)
PY
done
grep -n '/home/ubuntu\|FLUXER_DIR/ops' ./*.sh fluxer
```

Expected from the final grep: only `install-host.sh` and `completion.bash`/`offsite.conf.example` remain (handled next). Inspect `git diff --stat` and read each hunk: every file lost 1–3 lines and gained the one `lib.sh` line, at the place `FLUXER_DIR` was set.

- [ ] **Step 4: Add `need_instance` where an instance is required**

Right after the `lib.sh` line, add a line `need_instance` in: `backup.sh badge-patch.sh cf-ips.sh changelog.sh check.sh debug.sh disk.sh doctor.sh env.sh gifts.sh offsite.sh premium.sh prune.sh update.sh users.sh watchdog.sh`.

Not in `notify.sh` (only reads `.env` for optional SMTP defaults, and `$FLUXER_DIR/.env` missing is already tolerated there) nor `firewall-fix.sh` (only prints the path in a hint).

In `fluxer`, not at the top (so `fluxer help` and `fluxer setup` work without an instance). Instead, make the helpers that need it call it:

```sh
compose() { need_instance; (cd "$FLUXER_DIR" && docker compose "$@"); }
```

and add `need_instance` as the first line of `cmd_status`, `cmd_backups`, `cmd_verify_backup`, `cmd_restore`, `cmd_rollback`. Also in `fluxer`'s usage text, replace the line

```
Deployment: /home/ubuntu/Documents/fluxer   Backups: /home/ubuntu/Documents/fluxer-backups
```

with (the heredoc is quoted, so print it after the heredoc instead):

```sh
	printf '\nDeployment: %s   Backups: %s\n' "${FLUXER_DIR:-(none found)}" "${BACKUP_ROOT:-(none)}"
```

- [ ] **Step 5: `completion.bash`, `offsite.conf.example`, `install-host.sh`**

`completion.bash`: replace

```bash
_fluxer_dir() { printf '%s' "${FLUXER_DIR:-/home/ubuntu/Documents/fluxer}"; }
```

with

```bash
# Same resolution as lib.sh, which cannot be sourced into an interactive shell
# (it sets variables and may call docker). Parent of the real ops/ directory,
# unless FLUXER_DIR is set.
_fluxer_ops=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
_fluxer_dir() { printf '%s' "${FLUXER_DIR:-$(dirname "$_fluxer_ops")}"; }
_fluxer_backups() { printf '%s' "${BACKUP_ROOT:-$(dirname "$(_fluxer_dir)")/fluxer-backups}"; }
```

and replace `"${BACKUP_ROOT:-/home/ubuntu/Documents/fluxer-backups}"/*/` with `"$(_fluxer_backups)"/*/`.

`offsite.conf.example`: replace `#RESTIC_PASSWORD_FILE=/home/ubuntu/.config/fluxer-restic-password` with `#RESTIC_PASSWORD_FILE=$HOME/.config/fluxer-restic-password`.

`install-host.sh`: replace its two path lines

```sh
FLUXER_DIR=${FLUXER_DIR:-/home/ubuntu/Documents/fluxer}
OPS="$FLUXER_DIR/ops"
```

with the `lib.sh` line and `need_instance`. (It is replaced by a wrapper in Task 3; this keeps every commit working.)

- [ ] **Step 6: Run selftest and exercise the live host read-only**

Run: `./selftest.sh && fluxer status && ./doctor.sh --quiet; ./check.sh --quiet; echo "check rc=$?"; env -u FLUXER_DIR sh -c 'cd / && fluxer backups | head -3'`
Expected: selftest PASS; `status` shows `instance https://fluxer.kipavy.fr`, the running count and the last backup in `/home/ubuntu/Documents/fluxer-backups`; doctor and check print the same as before the change (compare against a run on `git stash` if in doubt); `backups` lists from any cwd.

- [ ] **Step 7: Commit**

```bash
git add -A ./*.sh fluxer completion.bash offsite.conf.example selftest.sh
git commit -m "Take every path from lib.sh instead of hardcoding this host's"
```

---

### Task 3: `setup.sh` skeleton and core wiring; `install-host.sh` becomes a wrapper

**Files:**
- Create: `setup.sh`, `tests/setup_test.sh`
- Modify: `install-host.sh` (rewrite), `fluxer` (help + dispatch), `completion.bash`, `selftest.sh` (alias list)

**Interfaces:**
- Consumes: `lib.sh`.
- Produces, all in `setup.sh`, loadable without running main via `OPS_SELF=<path to setup.sh> SETUP_SOURCE_ONLY=1 . setup.sh`:
  - globals `CHECK_ONLY ASSUME_YES EXTRAS DOMAIN EMAIL ALLOW_ROOT SUDO_OK NEW_INSTANCE MISSING TMP`
  - `say <text>`, `st_ok|st_do|st_skip|st_bad <text>`, `die <code> <text>`
  - `ask <question> <y|n>` → status 0 yes; `prompt <question> [default]` → answer on stdout; both die 2 on closed stdin
  - `as_root <cmd...>`; `quote_cmd <args...>` → shell-quoted string
  - `cron_list <root|user>`, `cron_write <root|user>` (stdin); overridable `CRONTAB`, `CRONTAB_ROOT`
  - `core_wiring` (uses `OPS FLUXER_DIR BIN_DIR COMPLETION_DIR SUDO_OK CHECK_ONLY ASSUME_YES`, sets `MISSING=1` in check mode)

- [ ] **Step 1: Write the failing test**

`tests/setup_test.sh` (mode 755):

```sh
#!/bin/sh
# setup_test.sh - setup.sh's helpers and phases, against stubs in a scratch directory.
# No real crontab, sudo, docker or network is touched.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(dirname "$HERE")
. "$HERE/assert.sh"
tmp=$(readlink -f "$(mktemp -d)")
trap 'rm -rf "$tmp"' EXIT

# A fake instance with a copy of the tooling, so $OPS never points at the real one.
mkdir -p "$tmp/inst" "$tmp/home"
cp -r "$SRC" "$tmp/inst/ops"
rm -f "$tmp/inst/ops/notify.conf" "$tmp/inst/ops/offsite.conf"
: > "$tmp/inst/docker-compose.yml"
printf 'FLUXER_DOMAIN=chat.example.test\n' > "$tmp/inst/.env"

# crontab stub: one file per user.
cat > "$tmp/crontab" <<'EOF'
#!/bin/sh
who=$1; shift
f="$CRON_DIR/$who"
case "$1" in
	-l) [ -f "$f" ] && cat "$f" || exit 1 ;;
	-) cat > "$f" ;;
esac
EOF
chmod +x "$tmp/crontab"
mkdir -p "$tmp/cron"

load() {
	FLUXER_DIR="$tmp/inst" OPS_SELF="$tmp/inst/ops/setup.sh" SETUP_SOURCE_ONLY=1
	export FLUXER_DIR
	. "$tmp/inst/ops/setup.sh"
	OPS="$tmp/inst/ops"  # main sources lib.sh, which SETUP_SOURCE_ONLY skips
	CRON_DIR="$tmp/cron"; export CRON_DIR
	CRONTAB="$tmp/crontab user" CRONTAB_ROOT="$tmp/crontab root" SUDO=''
	BIN_DIR="$tmp/home/bin" COMPLETION_DIR="$tmp/home/completions"
}

# --- quote_cmd round-trips awkward arguments
( load
  eval "set -- $(quote_cmd "a b" "it's" '$x' '')"
  assert_eq "quote_cmd keeps spaces" "a b" "$1"
  assert_eq "quote_cmd keeps quotes" "it's" "$2"
  assert_eq "quote_cmd keeps dollars" '$x' "$3"
  assert_eq "quote_cmd keeps empty args" 4 "$#"
  finish )

# --- ask / prompt
( load
  ASSUME_YES=0
  printf 'y\n' | { ask "q?" n > /dev/null && pass "ask: y is yes" || fail "ask: y is yes"; }
  printf '\n' | { ask "q?" y > /dev/null && pass "ask: Enter takes the default" || fail "ask: Enter takes the default"; }
  r=$(printf '\n' | prompt "name" dflt 2>/dev/null); assert_eq "prompt: Enter takes the default" dflt "$r"
  rc=0; ( : | ask "q?" y > /dev/null 2>&1 ) || rc=$?; assert_eq "ask: closed stdin dies 2" 2 "$rc"
  ASSUME_YES=1
  ask "q?" n < /dev/null > /dev/null && fail "ask --yes: default n stays no" || pass "ask --yes: default n stays no"
  r=$(prompt "name" dflt < /dev/null 2>/dev/null); assert_eq "prompt --yes takes the default" dflt "$r"
  finish )

# --- core wiring: check, install, idempotent
( load
  SUDO_OK=1 CHECK_ONLY=1 ASSUME_YES=1 MISSING=0
  core_wiring > /dev/null; assert_eq "check on a bare host reports missing" 1 "$MISSING"
  [ -e "$tmp/cron/user" ] && fail "check mode wrote a crontab" || pass "check mode writes nothing"

  CHECK_ONLY=0 MISSING=0
  core_wiring > "$tmp/out1"
  assert_eq "fluxer link" "$tmp/inst/ops/fluxer" "$(readlink "$tmp/home/bin/fluxer")"
  assert_eq "completion link" "$tmp/inst/ops/completion.bash" "$(readlink "$tmp/home/completions/fluxer")"
  assert_contains "backup cron carries FLUXER_DIR" "0 3 * * * FLUXER_DIR=$tmp/inst $tmp/inst/ops/backup.sh" "$(cat "$tmp/cron/user")"
  assert_contains "disk cron" "30 3 * * * FLUXER_DIR=$tmp/inst $tmp/inst/ops/disk.sh --record" "$(cat "$tmp/cron/user")"
  assert_contains "watchdog in root's crontab" "*/10 * * * * FLUXER_DIR=$tmp/inst $tmp/inst/ops/watchdog.sh" "$(cat "$tmp/cron/root")"

  before=$(cat "$tmp/cron/user" "$tmp/cron/root")
  core_wiring > "$tmp/out2"
  assert_eq "second run changes no crontab" "$before" "$(cat "$tmp/cron/user" "$tmp/cron/root")"
  assert_contains "second run says ✓" "✓" "$(cat "$tmp/out2")"
  CHECK_ONLY=1 MISSING=0; core_wiring > /dev/null; assert_eq "check after install: nothing missing" 0 "$MISSING"

  # A line an operator wrote by hand, without FLUXER_DIR=, counts as present.
  printf '0 4 * * * %s/backup.sh\n' "$tmp/inst/ops" > "$tmp/cron/user"
  CHECK_ONLY=0; core_wiring > /dev/null
  assert_eq "hand-written backup line is kept, not duplicated" 1 "$(grep -c 'backup.sh' "$tmp/cron/user")"

  # No sudo: the watchdog is skipped, not failed.
  rm -f "$tmp/cron/root"; SUDO_OK=0
  out=$(core_wiring); assert_contains "no sudo skips the watchdog" "– " "$out"
  [ -e "$tmp/cron/root" ] && fail "no sudo wrote root's crontab" || pass "no sudo leaves root's crontab alone"
  finish )

finish
```

Note: each `( ... finish )` group runs in a subshell; a failing group exits 1 and `set -e` stops the script there. Anything expected to exit non-zero is captured as `rc=0; ( ... ) || rc=$?`, never `( ... ); rc=$?`, which `set -e` would abort on. Functions that set globals (`MISSING`, `NEW_INSTANCE`) are called directly, not inside `$(...)`, before asserting on those globals.

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tests/setup_test.sh`
Expected: `sh: .: cannot open .../setup.sh` and non-zero exit.

- [ ] **Step 3: Write `setup.sh` (skeleton + core wiring)**

`setup.sh` (mode 755):

```sh
#!/bin/sh
# setup.sh - take this server from nothing, or from a running Fluxer, to an instance
# that is backed up, watched, and operable with `fluxer`.
#
#   setup.sh                  guided: prerequisites, instance, cron, optional extras
#   setup.sh --check          report what is missing, change nothing (exit 1 if any)
#   setup.sh --yes            no questions: take every default, skip the extras
#   setup.sh --no-extras      stop after the core wiring
#   setup.sh --fluxer-dir D   the instance directory (found on its own otherwise)
#   setup.sh --domain D --email E
#                             for a new instance, instead of being asked
#
# Safe to run again: every step looks before it acts, a finished step prints ✓ and
# does nothing, and existing crontab lines are never rewritten or removed.
#
# Every outside command is overridable, so tests/setup_test.sh can run all of this
# against stubs: DOCKER SUDO CRONTAB CRONTAB_ROOT SYSTEMCTL DMI_DIR PUBLIC_IP_URL
# CF_IPS_URL INSTALLER_URL DOCKER_INSTALL_URL BIN_DIR COMPLETION_DIR.
set -eu

SELF=$(readlink -f "${OPS_SELF:-$0}")
SELF_DIR=$(dirname "$SELF")

DOCKER=${DOCKER:-docker}
SUDO=${SUDO-sudo}
SYSTEMCTL=${SYSTEMCTL:-systemctl}
BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
COMPLETION_DIR=${COMPLETION_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions}

CHECK_ONLY=0 ASSUME_YES=0 EXTRAS=1 DOMAIN='' EMAIL='' ALLOW_ROOT=''
SUDO_OK=0 NEW_INSTANCE=0 MISSING=0 TMP=''

# --- output and questions -----------------------------------------------------

say() { printf '%s\n' "$*"; }
st_ok() { printf '  ✓ %s\n' "$*"; }
st_do() { printf '  → %s\n' "$*"; }
st_skip() { printf '  – %s\n' "$*"; }
st_bad() { printf '  ✗ %s\n' "$*"; }
die() {
	_code=$1
	shift
	printf '\n✗ %s\n' "$*" >&2
	exit "$_code"
}

# ask <question> <default y|n>: status 0 for yes. --yes answers with the default.
# A closed stdin is not an answer: guessing "yes" there could install things.
ask() {
	if [ "$ASSUME_YES" -eq 1 ]; then [ "$2" = y ]; return; fi
	case "$2" in y) _hint='[Y/n]' ;; *) _hint='[y/N]' ;; esac
	printf '  %s %s ' "$1" "$_hint"
	read -r _reply || die 2 "No answer (input closed). Run setup.sh from a terminal, or with --yes."
	case "${_reply:-$2}" in y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
}

# prompt <question> [default]: the answer on stdout. Used as $(prompt ...), so the
# question goes to stderr.
prompt() {
	if [ "$ASSUME_YES" -eq 1 ]; then printf '%s' "${2:-}"; return 0; fi
	printf '  %s%s: ' "$1" "${2:+ [$2]}" >&2
	read -r _reply || die 2 "No answer (input closed). Run setup.sh from a terminal, or with --yes."
	printf '%s' "${_reply:-${2:-}}"
}

# prompt_secret <question>: like prompt, without echoing what is typed.
prompt_secret() {
	printf '  %s: ' "$1" >&2
	stty -echo 2> /dev/null || true
	read -r _reply || { stty echo 2> /dev/null || true; die 2 "No answer (input closed)."; }
	stty echo 2> /dev/null || true
	printf '\n' >&2
	printf '%s' "$_reply"
}

as_root() {
	if [ "$(id -u)" -eq 0 ]; then "$@"; else $SUDO "$@"; fi
}

# quote_cmd <args...>: one string that `eval set --` or `sh -c` turns back into them.
quote_cmd() {
	for _a in "$@"; do
		printf "'%s' " "$(printf '%s' "$_a" | sed "s/'/'\\\\''/g")"
	done
}

# --- phase 3: core wiring -----------------------------------------------------

cron_list() {
	if [ "$1" = root ]; then
		# shellcheck disable=SC2086 # CRONTAB_ROOT may carry arguments (tests)
		as_root ${CRONTAB_ROOT:-crontab} -l 2> /dev/null || true
	else
		# shellcheck disable=SC2086
		${CRONTAB:-crontab} -l 2> /dev/null || true
	fi
}
cron_write() {
	if [ "$1" = root ]; then
		# shellcheck disable=SC2086
		as_root ${CRONTAB_ROOT:-crontab} -
	else
		# shellcheck disable=SC2086
		${CRONTAB:-crontab} -
	fi
}

# script | schedule | crontab. The watchdog needs root for iptables and systemctl;
# the rest runs as the deploying user.
JOBS="watchdog.sh|*/10 * * * *|root
backup.sh|0 3 * * *|user
disk.sh --record|30 3 * * *|user"

link_step() { # <name> <link> <target>
	if [ "$(readlink "$2" 2> /dev/null || true)" = "$3" ]; then
		st_ok "$1"
	elif [ "$CHECK_ONLY" -eq 1 ]; then
		st_bad "$1 missing ($2)"
		MISSING=1
	else
		mkdir -p "$(dirname "$2")"
		ln -sfn "$3" "$2"
		st_ok "$1 ($2)"
	fi
}

core_wiring() {
	link_step "fluxer command" "$BIN_DIR/fluxer" "$OPS/fluxer"
	link_step "tab completion" "$COMPLETION_DIR/fluxer" "$OPS/completion.bash"

	# Not a pipe into while: MISSING must survive the loop.
	_jobs=$(printf '%s\n' "$JOBS")
	_ifs=$IFS
	IFS='
'
	for _job in $_jobs; do
		IFS=$_ifs
		_script=${_job%%|*}
		_rest=${_job#*|}
		_when=${_rest%|*}
		_who=${_rest#*|}
		_file=$OPS/${_script%% *}
		_label="$_script ($_who cron, $_when)"
		if [ "$_who" = root ] && [ "$SUDO_OK" -ne 1 ]; then
			st_skip "$_label: needs sudo. Without it nothing restarts the stack after a crash or a firewalld reload."
			continue
		fi
		if cron_list "$_who" | grep -v '^[[:space:]]*#' | grep -qF "$_file"; then
			st_ok "$_label"
		elif [ "$CHECK_ONLY" -eq 1 ]; then
			st_bad "$_label missing"
			MISSING=1
		else
			# Appended, never rewriting what is there. FLUXER_DIR is spelled out
			# because cron's environment is empty and ops/ may live elsewhere.
			{ cron_list "$_who"; printf '%s FLUXER_DIR=%s %s/%s >/dev/null 2>&1\n' "$_when" "$FLUXER_DIR" "$OPS" "$_script"; } \
				| cron_write "$_who"
			st_ok "$_label"
		fi
	done
	IFS=$_ifs
}

# --- main ---------------------------------------------------------------------

[ "${SETUP_SOURCE_ONLY:-0}" = 1 ] && return 0

usage() {
	sed -n '/^#   setup.sh/,/^#$/s/^# \{0,1\}//p' "$SELF" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
		--check) CHECK_ONLY=1 ;;
		--yes | -y) ASSUME_YES=1 ;;
		--no-extras) EXTRAS=0 ;;
		--fluxer-dir) [ $# -ge 2 ] || usage; FLUXER_DIR=$(readlink -m "$2"); export FLUXER_DIR; shift ;;
		--domain) [ $# -ge 2 ] || usage; DOMAIN=$2; shift ;;
		--email) [ $# -ge 2 ] || usage; EMAIL=$2; shift ;;
		-h | --help) sed -n '/^#   setup.sh/,/^#$/s/^# \{0,1\}//p' "$SELF"; exit 0 ;;
		*) usage ;;
	esac
	shift
done
[ "$ASSUME_YES" -eq 1 ] && EXTRAS=0
[ "$CHECK_ONLY" -eq 1 ] && EXTRAS=0

# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

if [ "$(id -u)" -eq 0 ] || { [ "$CHECK_ONLY" -eq 1 ] && $SUDO -n true 2> /dev/null; } || { [ "$CHECK_ONLY" -eq 0 ] && $SUDO -v 2> /dev/null; }; then
	SUDO_OK=1
fi

say "Fluxer"
if [ -n "$FLUXER_DIR" ] && [ -f "$FLUXER_DIR/.env" ]; then
	st_ok "found at $FLUXER_DIR (https://$(sed -n 's/^FLUXER_DOMAIN=//p' "$FLUXER_DIR/.env" | head -n 1))"
else
	die 2 "No Fluxer instance found. (Installing one arrives in a later task.)"
fi

say ""
say "Wiring"
core_wiring

[ "$CHECK_ONLY" -eq 1 ] && exit "$MISSING"
exit 0
```

(Tasks 4–7 replace the temporary `die 2 "No Fluxer instance found..."` branch and the sudo line with the real phases.)

- [ ] **Step 4: `install-host.sh` wrapper, dispatcher, completion, selftest alias**

`install-host.sh`, whole file:

```sh
#!/bin/sh
# install-host.sh - kept so old habits and notes still work. setup.sh does this now.
exec "$(dirname "$(readlink -f "$0")")/setup.sh" --no-extras "$@"
```

`fluxer` help, in the `Host` block, replace the two `install-host` lines with:

```
  fluxer setup [--check]     Install or re-check: prerequisites, instance, cron, extras
```

`fluxer` dispatch, add next to `install-host)`:

```sh
	setup) exec "$OPS/setup.sh" "$@" ;;
```

`completion.bash`: add `setup` to the command word list (next to `install-host`), and in the per-command case:

```bash
			setup) words='--check --yes --no-extras --fluxer-dir --domain --email' ;;
```

`selftest.sh` section 3, the aliases line becomes:

```sh
	case "$c" in help | --help | -h | verify | gift | down | ps | valkey | install-host) continue ;; esac
```

- [ ] **Step 5: Run the tests**

Run: `sh tests/setup_test.sh && ./selftest.sh`
Expected: all `ok`; `PASS  ops tooling intact`.

- [ ] **Step 6: Check it on this host, read-only**

Run: `./setup.sh --check; echo "rc=$?"`
Expected: `✓ found at /home/ubuntu/Documents/fluxer (https://fluxer.kipavy.fr)`, `✓` for the link, backup and watchdog lines; `✗ disk.sh --record (user cron, 30 3 * * *) missing` (this host never got it); `rc=1`. Nothing written: `crontab -l` unchanged.

- [ ] **Step 7: Commit**

```bash
git add setup.sh tests/setup_test.sh install-host.sh fluxer completion.bash selftest.sh
git commit -m "Add setup.sh with the host wiring install-host.sh did, and fluxer setup"
```

---

### Task 4: Phase 1, prerequisites

**Files:**
- Modify: `setup.sh`, `tests/setup_test.sh`

**Interfaces:**
- Consumes: Task 3 helpers.
- Produces: `pkg_hint <pkg>` → install command; `version_ge <have> <want>`; `phase_root`, `phase_sudo`, `phase_docker <quoted original args>`, `phase_tools`. `phase_docker` may `exec sg docker` (guarded by `SETUP_SG=1`).

- [ ] **Step 1: Write the failing tests**

Append to `tests/setup_test.sh`, before the final `finish`:

```sh
# --- prerequisites
( load
  version_ge 2.26.1 2.24.4 && pass "2.26.1 >= 2.24.4" || fail "2.26.1 >= 2.24.4"
  version_ge 2.24.4 2.24.4 && pass "equal versions are enough" || fail "equal versions are enough"
  version_ge 2.9.0 2.24.4 && fail "2.9.0 is older than 2.24.4" || pass "2.9.0 is older than 2.24.4"
  version_ge 10.0.0 2.24.4 && pass "numeric, not lexical" || fail "numeric, not lexical"

  mkdir -p "$tmp/pm"; printf '#!/bin/sh\n' > "$tmp/pm/apt-get"; chmod +x "$tmp/pm/apt-get"
  assert_eq "pkg_hint on apt" "sudo apt-get install -y git" "$(PATH="$tmp/pm:/usr/bin:/bin" pkg_hint git)"

  # docker compose too old, tools present
  mkdir -p "$tmp/d"
  cat > "$tmp/d/docker" <<'EOF'
#!/bin/sh
case "$*" in
	"compose version --short") echo "${COMPOSE_V:-2.26.1}" ;;
	info) exit 0 ;;
	version*) echo 27.0.0 ;;
esac
EOF
  chmod +x "$tmp/d/docker"
  DOCKER="$tmp/d/docker" CHECK_ONLY=1 MISSING=0
  export COMPOSE_V=2.20.0  # read by the docker stub, a child process
  out=$(phase_tools); assert_contains "old compose is reported" "older than 2.24.4" "$out"
  phase_tools > /dev/null; assert_eq "old compose counts as missing" 1 "$MISSING"
  unset COMPOSE_V
  MISSING=0; out=$(phase_tools); assert_contains "compose ok" "✓ Docker Compose 2.26.1" "$out"

  # no docker at all, check mode: reported, not installed
  DOCKER="$tmp/nope/docker" MISSING=0
  out=$(phase_docker ''); assert_contains "missing docker reported" "Docker is not installed" "$out"
  phase_docker '' > /dev/null; assert_eq "missing docker counts" 1 "$MISSING"

  # no docker, interactive, declined: exits 2 with the manual route
  CHECK_ONLY=0 ASSUME_YES=0
  rc=0; ( printf 'n\n' | phase_docker '' > "$tmp/o" 2>&1 ) || rc=$?
  assert_eq "declined docker install exits 2" 2 "$rc"
  assert_contains "points at the docs" "docs.docker.com" "$(cat "$tmp/o")"
  finish )
```

- [ ] **Step 2: Run to verify failure**

Run: `sh tests/setup_test.sh`
Expected: `version_ge: not found` (or FAIL lines), non-zero exit.

- [ ] **Step 3: Implement phase 1**

Insert in `setup.sh` above `# --- phase 3: core wiring`:

```sh
# --- phase 1: prerequisites ---------------------------------------------------

pkg_hint() { # <package>: the command that installs it here
	if command -v apt-get > /dev/null 2>&1; then echo "sudo apt-get install -y $1"
	elif command -v dnf > /dev/null 2>&1; then echo "sudo dnf install -y $1"
	elif command -v zypper > /dev/null 2>&1; then echo "sudo zypper install -y $1"
	elif command -v pacman > /dev/null 2>&1; then echo "sudo pacman -S --needed $1"
	elif command -v apk > /dev/null 2>&1; then echo "sudo apk add $1"
	else echo "install $1 with this distribution's package manager"; fi
}

version_ge() { # <have> <want>: dotted numbers, compared numerically
	[ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" = "$2" ]
}

phase_root() {
	[ "$(id -u)" -eq 0 ] || return 0
	st_bad "running as root"
	say "    The Fluxer installer refuses root unless told otherwise: an ordinary user in the"
	say "    docker group keeps a mistake in a container from being a mistake on the host."
	[ "$CHECK_ONLY" -eq 1 ] && return 0
	if [ "$ASSUME_YES" -eq 1 ] || ask "Continue as root anyway?" n; then
		ALLOW_ROOT=--allow-root
	else
		die 2 "Run it again as a normal user who can sudo."
	fi
}

phase_sudo() {
	if [ "$(id -u)" -eq 0 ]; then SUDO_OK=1; return 0; fi
	if [ "$CHECK_ONLY" -eq 1 ]; then
		if $SUDO -n true 2> /dev/null; then SUDO_OK=1; st_ok "sudo"; else st_skip "sudo not checked (would ask for a password)"; fi
		return 0
	fi
	if $SUDO -v 2> /dev/null; then
		SUDO_OK=1
		st_ok "sudo"
	else
		st_skip "no sudo: the watchdog cron and the firewalld fix will be skipped"
	fi
}

# phase_docker <original args, quoted>: needs them to re-run itself under the new group.
phase_docker() {
	if ! command -v "$DOCKER" > /dev/null 2>&1; then
		st_bad "Docker is not installed"
		if [ "$CHECK_ONLY" -eq 1 ]; then MISSING=1; return 0; fi
		_url=${DOCKER_INSTALL_URL:-https://get.docker.com}
		say "    Docker's official install script can set it up: $_url"
		if ! ask "Install Docker now?" y; then
			die 2 "Install Docker Engine with the compose plugin (https://docs.docker.com/engine/install/), then run this again."
		fi
		[ "$SUDO_OK" -eq 1 ] || die 2 "Installing Docker needs root or sudo."
		st_do "installing Docker"
		_tmp=$(mktemp)
		curl -fsSL "$_url" -o "$_tmp" || die 4 "Could not download $_url."
		as_root sh "$_tmp" || die 2 "Docker's install script failed (output above)."
		rm -f "$_tmp"
		st_ok "Docker installed"
	fi

	if [ "$(id -u)" -eq 0 ] || $DOCKER info > /dev/null 2>&1; then
		st_ok "Docker $($DOCKER version --format '{{.Server.Version}}' 2> /dev/null || echo)"
		return 0
	fi
	_me=$(id -un)
	if getent group docker 2> /dev/null | cut -d: -f4 | tr ',' '\n' | grep -qx "$_me"; then
		# In the group, but this login predates it: sg gives it to this run.
		[ "${SETUP_SG:-0}" = 1 ] && die 2 "Docker is not answering. Is it running? sudo systemctl start docker"
		[ "$CHECK_ONLY" -eq 1 ] && { st_bad "$_me is in the docker group, but this login is not yet (log in again)"; MISSING=1; return 0; }
	else
		st_bad "$_me cannot use Docker (not in the docker group)"
		if [ "$CHECK_ONLY" -eq 1 ]; then MISSING=1; return 0; fi
		ask "Add $_me to the docker group?" y || die 2 "Add yourself with: sudo usermod -aG docker $_me, log in again, and run this again."
		[ "$SUDO_OK" -eq 1 ] || die 2 "That needs sudo: sudo usermod -aG docker $_me"
		as_root usermod -aG docker "$_me"
		st_ok "$_me added to the docker group"
	fi
	st_do "continuing with the docker group (no need to log in again)"
	SETUP_SG=1 exec sg docker -c "SETUP_SG=1 sh $(quote_cmd "$SELF") $1"
}

phase_tools() {
	_missing=''
	for _t in curl python3 sha256sum git; do
		command -v "$_t" > /dev/null 2>&1 || _missing="$_missing $_t"
	done
	_cv=$($DOCKER compose version --short 2> /dev/null | sed 's/^v//') || _cv=''
	if [ -z "$_cv" ]; then
		st_bad "Docker Compose plugin missing"
		_missing="$_missing docker-compose-plugin"
	elif ! version_ge "$_cv" 2.24.4; then
		st_bad "Docker Compose $_cv is older than 2.24.4"
		_missing="$_missing docker-compose-plugin"
	else
		st_ok "Docker Compose $_cv"
	fi
	if [ -z "$_missing" ]; then st_ok "curl, python3, sha256sum, git"; return 0; fi
	for _m in $_missing; do
		case "$_m" in sha256sum) _p=coreutils ;; *) _p=$_m ;; esac
		[ "$_m" = docker-compose-plugin ] && continue
		st_bad "$_m missing: $(pkg_hint "$_p")"
	done
	if [ "$CHECK_ONLY" -eq 1 ]; then MISSING=1; return 0; fi
	die 2 "Install what is missing above, then run this again."
}
```

In main, save the arguments before parsing (first line after `[ "${SETUP_SOURCE_ONLY:-0}" = 1 ] && return 0` and `usage()`):

```sh
ORIG_ARGS=$(quote_cmd "$@")
```

Replace the temporary sudo `if ... SUDO_OK=1 fi` block with:

```sh
say "Prerequisites"
phase_root
phase_sudo
phase_docker "$ORIG_ARGS"
phase_tools
say ""
```

- [ ] **Step 4: Run tests**

Run: `sh tests/setup_test.sh && ./selftest.sh && ./setup.sh --check; echo rc=$?`
Expected: tests pass; on this host `✓ Docker 2x`, `✓ Docker Compose 2.26.1`, `✓ curl, python3, sha256sum, git`, then the same wiring report as Task 3, `rc=1` (disk cron).

- [ ] **Step 5: Commit**

```bash
git add setup.sh tests/setup_test.sh
git commit -m "setup.sh: check root, sudo, Docker, the docker group and tools first"
```

---

### Task 5: Phase 2 pre-flight: domain, DNS, provider ports

**Files:**
- Modify: `setup.sh`, `tests/setup_test.sh`

**Interfaces:**
- Consumes: Task 3 helpers.
- Produces: `valid_domain <s>`, `valid_email <s>`; `public_ip` → IPv4 on stdout; `resolve4 <host>` → space-separated IPv4s; `dns_verdict <public ip> <resolved ips> <cloudflare cidr file>` → `here|cloudflare|elsewhere|none`; `cloud_provider` → `name|where|url` or empty; `ask_domain_email`, `phase_dns` (sets `BEHIND_CF=1`), `phase_ports`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/setup_test.sh` before the final `finish`:

```sh
# --- pre-flight
( load
  for d in chat.example.com a.b.co x-y.example.org; do valid_domain "$d" && pass "domain ok: $d" || fail "domain ok: $d"; done
  for d in '' localhost 'a b.com' -a.com http://x.com; do valid_domain "$d" && fail "domain rejected: [$d]" || pass "domain rejected: [$d]"; done
  valid_email me@example.com && pass "email ok" || fail "email ok"
  for e in '' me@ me@localhost 'a b@c.d'; do valid_email "$e" && fail "email rejected: [$e]" || pass "email rejected: [$e]"; done

  printf '173.245.48.0/20\n188.114.96.0/20\n' > "$tmp/cf"
  assert_eq "points here" here "$(dns_verdict 1.2.3.4 '1.2.3.4' "$tmp/cf")"
  assert_eq "proxied" cloudflare "$(dns_verdict 1.2.3.4 '188.114.96.6 188.114.97.6' "$tmp/cf")"
  assert_eq "elsewhere" elsewhere "$(dns_verdict 1.2.3.4 '5.6.7.8' "$tmp/cf")"
  assert_eq "mixed is elsewhere" elsewhere "$(dns_verdict 1.2.3.4 '188.114.96.6 5.6.7.8' "$tmp/cf")"
  assert_eq "no record" none "$(dns_verdict 1.2.3.4 '' "$tmp/cf")"
  : > "$tmp/cf-empty"
  assert_eq "no Cloudflare list: elsewhere" elsewhere "$(dns_verdict 1.2.3.4 '188.114.96.6' "$tmp/cf-empty")"

  mkdir -p "$tmp/dmi"
  printf 'QEMU\n' > "$tmp/dmi/sys_vendor"; printf 'OracleCloud.com\n' > "$tmp/dmi/chassis_asset_tag"
  assert_contains "Oracle from the asset tag" "Oracle Cloud|" "$(DMI_DIR="$tmp/dmi" cloud_provider)"
  printf 'Hetzner\n' > "$tmp/dmi/sys_vendor"; : > "$tmp/dmi/chassis_asset_tag"
  assert_contains "Hetzner" "Hetzner" "$(DMI_DIR="$tmp/dmi" cloud_provider)"
  printf 'LENOVO\n' > "$tmp/dmi/sys_vendor"
  assert_eq "unknown vendor" "" "$(DMI_DIR="$tmp/dmi" cloud_provider)"

  out=$(DMI_DIR="$tmp/dmi" ASSUME_YES=1 phase_ports)
  assert_contains "ports listed" "80/tcp 443/tcp 7881/tcp 7882/udp" "$out"

  # DNS loop: wrong record, then fixed on the second check.
  printf 'ip=1.2.3.4\n' > "$tmp/trace"
  PUBLIC_IP_URL="file://$tmp/trace" CF_IPS_URL="file://$tmp/cf" DOMAIN=chat.example.test ASSUME_YES=0
  TMP="$tmp/t"; mkdir -p "$TMP"
  printf '%s\n' 5.6.7.8 1.2.3.4 > "$tmp/answers"
  resolve4() { _a=$(head -n 1 "$tmp/answers"); sed -i 1d "$tmp/answers"; printf '%s' "$_a"; }
  out=$(printf '\n' | phase_dns)
  assert_contains "shows the record to create" "A    chat.example.test    1.2.3.4" "$out"
  assert_contains "passes once fixed" "✓ chat.example.test points at this server" "$out"

  printf '%s\n' 5.6.7.8 > "$tmp/answers"
  rc=0; ( ASSUME_YES=1; phase_dns > /dev/null 2>&1 ) || rc=$?; assert_eq "--yes with a wrong record exits 2" 2 "$rc"
  finish )
```

- [ ] **Step 2: Run to verify failure**

Run: `sh tests/setup_test.sh`
Expected: `valid_domain: not found`, non-zero exit.

- [ ] **Step 3: Implement**

Insert in `setup.sh` above `# --- phase 3: core wiring`:

```sh
# --- phase 2: the instance ------------------------------------------------------

PORTS='80/tcp 443/tcp 7881/tcp 7882/udp'
BEHIND_CF=0

valid_domain() {
	printf '%s' "$1" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
}
valid_email() {
	printf '%s' "$1" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
}

ask_domain_email() {
	while ! valid_domain "$DOMAIN"; do
		[ -z "$DOMAIN" ] || st_bad "not a domain name: $DOMAIN"
		[ "$ASSUME_YES" -eq 0 ] || die 2 "--yes needs --domain, e.g. --domain chat.example.com"
		DOMAIN=$(prompt "Domain for the instance (e.g. chat.example.com)")
	done
	while ! valid_email "$EMAIL"; do
		[ -z "$EMAIL" ] || st_bad "not an email address: $EMAIL"
		[ "$ASSUME_YES" -eq 0 ] || die 2 "--yes needs --email (for the certificate and the instance's own mail)"
		EMAIL=$(prompt "Your email (certificate notices, instance mail)")
	done
}

public_ip() {
	_ip=$(curl -fsS --max-time 10 "${PUBLIC_IP_URL:-https://1.1.1.1/cdn-cgi/trace}" 2> /dev/null | sed -n 's/^ip=//p' | head -n 1)
	[ -n "$_ip" ] || _ip=$(curl -fsS --max-time 10 https://api.ipify.org 2> /dev/null || true)
	printf '%s' "$_ip"
}

resolve4() {
	getent ahostsv4 "$1" 2> /dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# dns_verdict <public ip> <resolved ips> <file of Cloudflare CIDRs>
dns_verdict() {
	[ -n "$2" ] || { echo none; return 0; }
	for _ip in $2; do [ "$_ip" = "$1" ] && { echo here; return 0; }; done
	# shellcheck disable=SC2086 # $2 is a list of addresses
	if python3 - "$3" $2 <<'PY'
import ipaddress, sys
nets = [ipaddress.ip_network(l.strip()) for l in open(sys.argv[1]) if l.strip()]
addrs = [ipaddress.ip_address(a) for a in sys.argv[2:]]
sys.exit(0 if nets and all(any(a in n for n in nets) for a in addrs) else 1)
PY
	then echo cloudflare; else echo elsewhere; fi
}

phase_dns() {
	_ip=$(public_ip)
	if [ -z "$_ip" ]; then
		st_skip "could not learn this server's public IP; DNS not checked"
		return 0
	fi
	curl -fsS --max-time 10 "${CF_IPS_URL:-https://www.cloudflare.com/ips-v4}" > "$TMP/cf-v4" 2> /dev/null || : > "$TMP/cf-v4"
	while :; do
		case "$(dns_verdict "$_ip" "$(resolve4 "$DOMAIN")" "$TMP/cf-v4")" in
			here)
				st_ok "$DOMAIN points at this server ($_ip)"
				return 0
				;;
			cloudflare)
				st_ok "$DOMAIN is proxied through Cloudflare"
				say "    If the certificate is not issued, switch the record to \"DNS only\" until it is,"
				say "    then back, with SSL/TLS mode \"Full (strict)\"."
				BEHIND_CF=1
				return 0
				;;
		esac
		st_bad "$DOMAIN does not point at this server yet"
		say "    Create this record where the domain's DNS is managed:"
		say "        A    $DOMAIN    $_ip"
		[ "$ASSUME_YES" -eq 0 ] || die 2 "DNS for $DOMAIN does not point at $_ip. Fix the record, then run this again."
		printf '    Enter to check again (a new record can take a few minutes), or type skip: '
		read -r _reply || _reply=skip
		if [ "$_reply" = skip ]; then
			st_skip "DNS: no certificate can be issued until $DOMAIN points at $_ip"
			return 0
		fi
	done
}

# cloud_provider: "name|where its firewall is|docs", or nothing when unknown.
cloud_provider() {
	_d=${DMI_DIR:-/sys/class/dmi/id}
	_v=$(cat "$_d/sys_vendor" "$_d/chassis_asset_tag" "$_d/product_name" 2> /dev/null | tr '\n' ' ')
	case "$_v" in
		*OracleCloud*) echo 'Oracle Cloud|the VCN security list: Networking > Virtual cloud networks > your VCN > Security Lists > Add Ingress Rules|https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/securitylists.htm' ;;
		*Amazon*) echo 'AWS|the instance security group: EC2 > Security Groups > Inbound rules|https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/working-with-security-groups.html' ;;
		*Google*) echo 'Google Cloud|a VPC firewall rule: VPC network > Firewall|https://cloud.google.com/firewall/docs/using-firewalls' ;;
		*Microsoft*) echo 'Azure|the network security group: Networking > Inbound port rules|https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview' ;;
		*Hetzner*) echo 'Hetzner|the Cloud Firewall attached to the server, if any|https://docs.hetzner.com/cloud/firewalls/getting-started/creating-a-firewall' ;;
		*DigitalOcean*) echo 'DigitalOcean|the Cloud Firewall attached to the droplet, if any|https://docs.digitalocean.com/products/networking/firewalls/' ;;
		*Scaleway*) echo 'Scaleway|the instance security group|https://www.scaleway.com/en/docs/instances/how-to/use-security-groups/' ;;
	esac
}

phase_ports() {
	say "    Fluxer needs these ports open to the internet: $PORTS"
	_p=$(cloud_provider)
	if [ -n "$_p" ]; then
		_name=${_p%%|*}
		_rest=${_p#*|}
		say "    On $_name that is ${_rest%%|*}:"
		say "    ${_rest#*|}"
	else
		say "    If your hosting provider has a firewall in its web console, open them there."
	fi
	say "    Docker takes care of this server's own firewall. The provider's cannot be seen from here."
	[ "$ASSUME_YES" -eq 1 ] && return 0
	ask "Are they open?" y || die 2 "Open them, then run this again."
}
```

- [ ] **Step 4: Run tests**

Run: `sh tests/setup_test.sh && ./selftest.sh`
Expected: all ok, PASS.

- [ ] **Step 5: Commit**

```bash
git add setup.sh tests/setup_test.sh
git commit -m "setup.sh: check the domain's DNS and explain the provider firewall before installing"
```

---

### Task 6: Phase 2 install: run the verified upstream installer, wire main

**Files:**
- Modify: `setup.sh`, `tests/setup_test.sh`

**Interfaces:**
- Consumes: Task 4 (`ALLOW_ROOT`), Task 5 (`ask_domain_email phase_dns phase_ports`).
- Produces: `fetch_installer` (verified copy at `$TMP/install.sh`, or `die 4`), `installer_meaning <rc>`, `phase_install` (sets `NEW_INSTANCE=1`), `phase_instance` (sets `FLUXER_DIR`, `DOMAIN`, may set `MISSING`).

- [ ] **Step 1: Write the failing tests**

Append before the final `finish`:

```sh
# --- the upstream installer
( load
  mkdir -p "$tmp/up" "$tmp/new"
  cat > "$tmp/up/install.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$tmp/up/args"
exit \${STUB_RC:-0}
EOF
  (cd "$tmp/up" && sha256sum install.sh > install.sh.sha256)
  INSTALLER_URL="file://$tmp/up/install.sh" TMP="$tmp/t2"; mkdir -p "$TMP"
  FLUXER_DIR="$tmp/new" DOMAIN=chat.example.test EMAIL=me@example.test ALLOW_ROOT=''

  phase_install > /dev/null
  assert_eq "installer gets dir, domain, email, non-interactive" \
	"--dir $tmp/new --domain chat.example.test --email me@example.test --non-interactive" "$(cat "$tmp/up/args")"
  assert_eq "installer kept in the instance dir" "$(cat "$tmp/up/install.sh")" "$(cat "$tmp/new/install.sh")"
  assert_eq "marks a new instance" 1 "$NEW_INSTANCE"

  rc=0; ( export STUB_RC=6; phase_install > "$tmp/o6" 2>&1 ) || rc=$?
  assert_eq "installer failure keeps its code" 6 "$rc"
  assert_contains "exit 6 explained" "DNS" "$(cat "$tmp/o6")"

  printf 'echo tampered\n' >> "$tmp/up/install.sh"
  rc=0; ( phase_install > "$tmp/o4" 2>&1 ) || rc=$?
  assert_eq "bad checksum exits 4" 4 "$rc"
  assert_contains "bad checksum refuses to run" "did not verify" "$(cat "$tmp/o4")"
  finish )
```

- [ ] **Step 2: Run to verify failure**

Run: `sh tests/setup_test.sh`
Expected: `phase_install: not found`, non-zero exit.

- [ ] **Step 3: Implement**

Append to the phase 2 section of `setup.sh`:

```sh
fetch_installer() {
	_url=${INSTALLER_URL:-https://fluxer.dev/install.sh}
	curl -fsSL "$_url" -o "$TMP/install.sh" && curl -fsSL "$_url.sha256" -o "$TMP/install.sh.sha256" \
		|| die 4 "Could not download $_url."
	# The same check update.sh does. This script writes every secret the instance has.
	(cd "$TMP" && sha256sum -c install.sh.sha256 > /dev/null 2>&1) \
		|| die 4 "The Fluxer installer's checksum did not verify. It was not run."
}

installer_meaning() {
	case "$1" in
		1) echo "it rejected its arguments (a setup.sh bug: please report it)" ;;
		2) echo "a prerequisite is missing (its message is above)" ;;
		3) echo "it refused to overwrite an existing instance (message above)" ;;
		4) echo "a download failed" ;;
		5) echo "generating the instance's secrets failed" ;;
		6) echo "the stack did not come up. Most often: DNS does not point here yet, or ports 80/443 are closed at the provider" ;;
		130) echo "it was interrupted" ;;
		*) echo "exit code $1" ;;
	esac
}

phase_install() {
	fetch_installer
	mkdir -p "$FLUXER_DIR"
	cp "$TMP/install.sh" "$FLUXER_DIR/install.sh"
	st_do "installing Fluxer into $FLUXER_DIR (about 3.5 GB of images: a few minutes)"
	_rc=0
	# shellcheck disable=SC2086 # ALLOW_ROOT is empty or one flag
	sh "$FLUXER_DIR/install.sh" --dir "$FLUXER_DIR" --domain "$DOMAIN" --email "$EMAIL" --non-interactive $ALLOW_ROOT || _rc=$?
	[ "$_rc" -eq 0 ] || die "$_rc" "The Fluxer installer stopped: $(installer_meaning "$_rc"). Fix that and run setup again."
	NEW_INSTANCE=1
	st_ok "Fluxer is installed"
}

phase_instance() {
	if [ -n "$FLUXER_DIR" ] && [ -f "$FLUXER_DIR/docker-compose.yml" ] && [ -f "$FLUXER_DIR/.env" ]; then
		DOMAIN=$(sed -n 's/^FLUXER_DOMAIN=//p' "$FLUXER_DIR/.env" | head -n 1)
		st_ok "Fluxer found at $FLUXER_DIR (https://$DOMAIN)"
		return 0
	fi
	if [ "$CHECK_ONLY" -eq 1 ]; then
		st_bad "no Fluxer instance${FLUXER_DIR:+ at $FLUXER_DIR}"
		MISSING=1
		return 0
	fi
	if [ -z "$FLUXER_DIR" ]; then
		# A clone at <dir>/ops is the layout get.sh makes: install next to it.
		if [ "$(basename "$OPS")" = ops ]; then
			FLUXER_DIR=$(dirname "$OPS")
		else
			FLUXER_DIR=$(readlink -m "$(prompt "Install Fluxer into" "$HOME/fluxer")")
		fi
	fi
	export FLUXER_DIR
	say "  No Fluxer instance yet: installing one into $FLUXER_DIR."
	ask_domain_email
	phase_dns
	phase_ports
	phase_install
	BACKUP_ROOT=${BACKUP_ROOT:-$(dirname "$FLUXER_DIR")/fluxer-backups}
}
```

In main, replace the temporary block

```sh
say "Fluxer"
if [ -n "$FLUXER_DIR" ] && [ -f "$FLUXER_DIR/.env" ]; then
	...
fi
```

with

```sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say "Fluxer"
phase_instance
```

and guard the wiring so `--check` without an instance does not wire against nothing:

```sh
say ""
say "Wiring"
if [ -n "$FLUXER_DIR" ] && [ -f "$FLUXER_DIR/.env" ]; then core_wiring; fi
```

(`TMP` is created after `phase_docker`, which may `exec`: an `exec` skips EXIT traps and would leak it.)

- [ ] **Step 4: Run tests and the host check**

Run: `sh tests/setup_test.sh && ./selftest.sh && ./setup.sh --check; echo rc=$?`
Expected: tests pass; host output as in Task 4, `rc=1`.

- [ ] **Step 5: Commit**

```bash
git add setup.sh tests/setup_test.sh
git commit -m "setup.sh: install Fluxer with the checksum-verified upstream installer when none exists"
```

---

### Task 7: Phase 4 extras and phase 5 finish

**Files:**
- Modify: `setup.sh`, `tests/setup_test.sh`

**Interfaces:**
- Consumes: Tasks 3–6; `notify.sh test`, `offsite.sh init`, `firewall-fix.sh --installed|--apply --yes`, `cf-ips.sh --quiet` (exit 0 in sync, 1 drift) / `--apply --yes`, `check.sh --quiet`, `doctor.sh --quiet`.
- Produces: `extra_alerts`, `extra_offsite`, `extra_firewall`, `extra_cf`, `phase_extras`, `phase_finish`.

- [ ] **Step 1: Write the failing tests**

Append before the final `finish`:

```sh
# --- extras
( load
  OPS="$tmp/inst/ops" ASSUME_YES=0 CHECK_ONLY=0
  printf '#!/bin/sh\necho "notify $*" >> "%s/calls"\n' "$tmp" > "$OPS/notify.sh"
  printf '#!/bin/sh\necho "offsite $*" >> "%s/calls"\n' "$tmp" > "$OPS/offsite.sh"
  chmod +x "$OPS/notify.sh" "$OPS/offsite.sh"

  printf 'n\n' | extra_alerts > /dev/null
  [ -e "$OPS/notify.conf" ] && fail "declining alerts writes nothing" || pass "declining alerts writes nothing"

  printf 'y\nwebhook\nhttps://discord.example.test/api/webhooks/1/abc\n' | extra_alerts > /dev/null 2>&1
  assert_contains "webhook written" "NOTIFY_WEBHOOK_URL='https://discord.example.test/api/webhooks/1/abc'" "$(cat "$OPS/notify.conf")"
  assert_eq "notify.conf is private" 600 "$(stat -c %a "$OPS/notify.conf")"
  assert_contains "test alert sent" "notify test" "$(cat "$tmp/calls")"
  out=$(extra_alerts < /dev/null); assert_contains "configured alerts are not offered again" "✓ alerts" "$out"

  printf 'y\nACC\nbkt\nKEYID\nSECRET\n\n' | extra_offsite > "$tmp/off" 2>&1
  conf=$(cat "$OPS/offsite.conf")
  assert_contains "R2 repository" "RESTIC_REPOSITORY='s3:https://ACC.r2.cloudflarestorage.com/bkt'" "$conf"
  assert_contains "key id" "AWS_ACCESS_KEY_ID='KEYID'" "$conf"
  pw=$(sed -n "s/^RESTIC_PASSWORD='\(.*\)'$/\1/p" "$OPS/offsite.conf")
  assert_eq "generated password is 48 hex chars" 48 "${#pw}"
  assert_contains "password shown once to save" "$pw" "$(cat "$tmp/off")"
  assert_eq "offsite.conf is private" 600 "$(stat -c %a "$OPS/offsite.conf")"
  assert_contains "repository initialised" "offsite init" "$(cat "$tmp/calls")"

  # firewalld not running: not offered at all
  SYSTEMCTL=false
  assert_eq "firewall fix not offered without firewalld" "" "$(extra_firewall < /dev/null)"
  finish )

# --- finish
( load
  OPS="$tmp/inst/ops" DOMAIN=chat.example.test
  printf '#!/bin/sh\nexit 0\n' > "$OPS/check.sh"; printf '#!/bin/sh\nexit 0\n' > "$OPS/doctor.sh"
  NEW_INSTANCE=1; out=$(phase_finish)
  assert_contains "live URL" "Your instance is live: https://chat.example.test" "$out"
  assert_contains "make yourself admin" "fluxer users staff" "$out"
  NEW_INSTANCE=0; out=$(phase_finish)
  case "$out" in *"users staff"*) fail "existing instance: no first-account steps" ;; *) pass "existing instance: no first-account steps" ;; esac
  finish )
```

- [ ] **Step 2: Run to verify failure**

Run: `sh tests/setup_test.sh`
Expected: `extra_alerts: not found`, non-zero exit.

- [ ] **Step 3: Implement**

Insert in `setup.sh` above `# --- main`:

```sh
# --- phase 4: optional extras -------------------------------------------------

# write_private <file>: stdin to a file only its owner can read. These hold tokens.
write_private() {
	(umask 077 && cat > "$1")
	chmod 600 "$1"
}

extra_alerts() {
	if [ -f "$OPS/notify.conf" ]; then st_ok "alerts configured (fluxer notify test)"; return 0; fi
	say "  Alerts: hear about an outage or a failed backup on your phone, in a chat, or by email."
	if ! ask "Set up alerts?" n; then st_skip "alerts (later: fluxer setup)"; return 0; fi
	_ch=$(prompt "Channel: ntfy, webhook or email" ntfy)
	case "$_ch" in
		ntfy)
			_url=$(prompt "ntfy topic URL" "https://ntfy.sh/fluxer-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')")
			_line="NOTIFY_NTFY_URL='$_url'"
			say "    In the ntfy app (Android, iOS, web), subscribe to: $_url"
			;;
		webhook)
			_url=$(prompt "Webhook URL (Discord, Slack or Fluxer)")
			_line="NOTIFY_WEBHOOK_URL='$_url'"
			;;
		email)
			_url=$(prompt "Send alerts to")
			valid_email "$_url" || { st_bad "not an email address: $_url"; st_skip "alerts"; return 0; }
			_line="NOTIFY_EMAIL_TO='$_url'"
			say "    Sent through the SMTP settings already in .env (FLUXER_EMAIL_SMTP_*)."
			;;
		*) st_bad "unknown channel: $_ch"; st_skip "alerts"; return 0 ;;
	esac
	case "$_url" in '' | *"'"*) st_bad "that value is empty or contains a quote"; st_skip "alerts"; return 0 ;; esac
	printf '# Written by setup.sh on %s. Every option: notify.conf.example\n%s\n' "$(date -u +%F)" "$_line" \
		| write_private "$OPS/notify.conf"
	if "$OPS/notify.sh" test; then
		st_ok "alerts set up; a test was sent"
	else
		st_bad "the test alert did not go through: edit $OPS/notify.conf, then fluxer notify test"
	fi
}

extra_offsite() {
	if [ -f "$OPS/offsite.conf" ]; then st_ok "off-site backups configured (fluxer offsite status)"; return 0; fi
	say "  Off-site backups: an encrypted copy of each nightly backup in a Cloudflare R2 bucket,"
	say "  so losing this server is not losing the data. Needs a bucket and an R2 API token"
	say "  with Object Read & Write on it (R2 > Manage API tokens)."
	if ! ask "Set up off-site backups?" n; then st_skip "off-site backups (later: fluxer setup)"; return 0; fi
	_acc=$(prompt "Cloudflare account ID")
	_bkt=$(prompt "Bucket name")
	_key=$(prompt "Access key ID")
	_sec=$(prompt_secret "Secret access key")
	for _v in "$_acc" "$_bkt" "$_key" "$_sec"; do
		case "$_v" in '' | *"'"*) st_bad "all four are needed, without quotes"; st_skip "off-site backups"; return 0 ;; esac
	done
	_pw=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
	write_private "$OPS/offsite.conf" <<EOF
# Written by setup.sh on $(date -u +%F). Every option: offsite.conf.example
RESTIC_PASSWORD='$_pw'
RESTIC_REPOSITORY='s3:https://$_acc.r2.cloudflarestorage.com/$_bkt'
AWS_ACCESS_KEY_ID='$_key'
AWS_SECRET_ACCESS_KEY='$_sec'
AWS_DEFAULT_REGION=auto
EOF
	say ""
	say "    The encryption password of your off-site backups:"
	say ""
	say "        $_pw"
	say ""
	say "    Save it in a password manager now. Without it nobody can restore them, you included,"
	say "    and the copy on this server is gone exactly when you would need it."
	prompt "Press Enter once it is saved" > /dev/null
	if "$OPS/offsite.sh" init; then
		st_ok "off-site repository ready: every nightly backup is pushed to it"
	else
		st_bad "offsite init failed: fix $OPS/offsite.conf, then fluxer offsite init"
	fi
}

extra_firewall() {
	$SYSTEMCTL is-active --quiet firewalld 2> /dev/null || return 0
	if "$OPS/firewall-fix.sh" --installed; then st_ok "firewalld fix installed"; return 0; fi
	if [ "$SUDO_OK" -ne 1 ]; then st_skip "firewalld fix (needs sudo)"; return 0; fi
	say "  firewalld is running here. A firewalld reload wipes Docker's network rules and every"
	say "  port of the stack stops answering until Docker restarts. The fix restarts it with firewalld."
	if ! ask "Install the firewalld fix?" y; then st_skip "firewalld fix (later: fluxer firewall-fix)"; return 0; fi
	if "$OPS/firewall-fix.sh" --apply --yes; then st_ok "firewalld fix installed"; else st_bad "firewall-fix failed (above)"; fi
}

extra_cf() {
	if [ "$BEHIND_CF" -ne 1 ]; then
		_ip=$(public_ip)
		[ -n "$_ip" ] || return 0
		curl -fsS --max-time 10 "${CF_IPS_URL:-https://www.cloudflare.com/ips-v4}" > "$TMP/cf-v4" 2> /dev/null || return 0
		[ "$(dns_verdict "$_ip" "$(resolve4 "$DOMAIN")" "$TMP/cf-v4")" = cloudflare ] || return 0
	fi
	if "$OPS/cf-ips.sh" --quiet > /dev/null 2>&1; then st_ok "Cloudflare ranges trusted"; return 0; fi
	say "  $DOMAIN is behind Cloudflare, and the instance does not trust all of Cloudflare's"
	say "  addresses yet: rate limits and logs would see Cloudflare instead of your users."
	if ! ask "Trust Cloudflare's current ranges?" y; then st_skip "Cloudflare ranges (later: fluxer cf-ips)"; return 0; fi
	if "$OPS/cf-ips.sh" --apply --yes; then st_ok "Cloudflare ranges trusted"; else st_bad "cf-ips failed (above)"; fi
}

phase_extras() {
	say ""
	say "Optional (Enter skips)"
	extra_alerts
	extra_offsite
	extra_firewall
	extra_cf
}

# --- phase 5: finish ----------------------------------------------------------

phase_finish() {
	say ""
	say "Checking"
	if "$OPS/check.sh" --quiet; then
		st_ok "https://$DOMAIN is serving"
	else
		st_bad "some checks fail (above). A new stack can take a minute: run fluxer check again shortly"
	fi
	"$OPS/doctor.sh" --quiet || true
	say ""
	case ":$PATH:" in
		*":$BIN_DIR:"*) ;;
		*) say "Open a new shell (or: export PATH=\"$BIN_DIR:\$PATH\") for the fluxer command."; say "" ;;
	esac
	if [ "$NEW_INSTANCE" -eq 1 ]; then
		cat <<EOF
Your instance is live: https://$DOMAIN

Next:
  1. Open it and create your account.
  2. fluxer users staff <your username>     make yourself an admin
  3. fluxer status                          any time; fluxer help for the rest
EOF
	else
		say "fluxer-ops is set up for https://$DOMAIN. fluxer status any time; fluxer help for the rest."
	fi
}
```

In main, replace the end

```sh
[ "$CHECK_ONLY" -eq 1 ] && exit "$MISSING"
exit 0
```

with

```sh
[ "$CHECK_ONLY" -eq 1 ] && exit "$MISSING"
[ "$EXTRAS" -eq 1 ] && phase_extras
phase_finish
exit 0
```

- [ ] **Step 4: Run tests and the host check**

Run: `sh tests/setup_test.sh && ./selftest.sh --lint && ./setup.sh --check; echo rc=$?`
Expected: tests pass, shellcheck clean, host `rc=1` (disk cron only).

- [ ] **Step 5: Commit**

```bash
git add setup.sh tests/setup_test.sh
git commit -m "setup.sh: offer alerts, off-site backups, the firewalld fix and Cloudflare ranges, then check"
```

---

### Task 8: `get.sh`

**Files:**
- Create: `get.sh`, `tests/get_test.sh`

**Interfaces:**
- Consumes: `setup.sh` flags `--fluxer-dir <dir> [--yes] [args...]`.
- Produces: `curl -fsSL .../get.sh | sh [-s -- setup args]`. Env: `FLUXER_DIR`, `FLUXER_OPS_REPO`, `FLUXER_OPS_YES`.

- [ ] **Step 1: Write the failing test**

`tests/get_test.sh` (mode 755):

```sh
#!/bin/sh
# get_test.sh - get.sh against a scratch repository whose setup.sh only records how
# it was called. No network, no real setup, no terminal (so the non-interactive path).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(dirname "$HERE")
. "$HERE/assert.sh"
tmp=$(readlink -f "$(mktemp -d)")
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/repo" "$tmp/home" "$tmp/stub"
( cd "$tmp/repo" && git init -q && : > fluxer \
  && printf '#!/bin/sh\nprintf "%%s\\n" "$*" > "$GET_TEST_OUT"\n' > setup.sh \
  && git add . && git -c user.email=t@t -c user.name=t commit -qm init )
printf '#!/bin/sh\nexit 1\n' > "$tmp/stub/docker"; chmod +x "$tmp/stub/docker"

# setsid: no controlling terminal, even when the tests are run from one, so /dev/tty
# cannot be opened and get.sh takes its non-interactive path.
g() { env -u FLUXER_DIR HOME="$tmp/home" PATH="$tmp/stub:$PATH" FLUXER_OPS_REPO="$tmp/repo" GET_TEST_OUT="$tmp/called" "$@" setsid -w sh "$SRC/get.sh" < /dev/null; }

out=$(g env 2>&1) && rc=0 || rc=$?
assert_eq "no terminal and no FLUXER_OPS_YES: exits 2" 2 "$rc"
assert_contains "explains the way out" "FLUXER_OPS_YES=1" "$out"
[ -e "$tmp/home/fluxer/ops" ] && fail "nothing cloned without consent" || pass "nothing cloned without consent"

g env FLUXER_OPS_YES=1 > /dev/null 2>&1
[ -f "$tmp/home/fluxer/ops/setup.sh" ] && pass "cloned into ~/fluxer/ops" || fail "cloned into ~/fluxer/ops"
assert_eq "setup gets the dir and --yes" "--fluxer-dir $tmp/home/fluxer --yes" "$(cat "$tmp/called")"

( cd "$tmp/repo" && printf 'x\n' > new && git add new && git -c user.email=t@t -c user.name=t commit -qm two )
g env FLUXER_OPS_YES=1 > /dev/null 2>&1
[ -f "$tmp/home/fluxer/ops/new" ] && pass "second run pulls" || fail "second run pulls"

# An existing instance elsewhere is used instead of ~/fluxer.
mkdir -p "$tmp/inst" && : > "$tmp/inst/docker-compose.yml" && printf 'FLUXER_DOMAIN=a.test\n' > "$tmp/inst/.env"
g env FLUXER_DIR="$tmp/inst" FLUXER_OPS_YES=1 > /dev/null 2>&1
[ -f "$tmp/inst/ops/setup.sh" ] && pass "clones next to FLUXER_DIR" || fail "clones next to FLUXER_DIR"

# Something else already at <dir>/ops is never overwritten.
mkdir -p "$tmp/busy/ops" && : > "$tmp/busy/ops/mine" && : > "$tmp/busy/docker-compose.yml" && printf 'FLUXER_DOMAIN=b.test\n' > "$tmp/busy/.env"
out=$(g env FLUXER_DIR="$tmp/busy" FLUXER_OPS_YES=1 2>&1) && rc=0 || rc=$?
assert_eq "foreign ops/ dir: exits 3" 3 "$rc"
[ -f "$tmp/busy/ops/mine" ] && pass "foreign ops/ untouched" || fail "foreign ops/ untouched"

# Arguments after `sh -s --` reach setup.sh.
env -u FLUXER_DIR HOME="$tmp/home" PATH="$tmp/stub:$PATH" FLUXER_OPS_REPO="$tmp/repo" GET_TEST_OUT="$tmp/called" \
	FLUXER_OPS_YES=1 setsid -w sh -s -- --domain c.test < "$SRC/get.sh" > /dev/null 2>&1 || true
assert_contains "piped with args: forwarded" "--domain c.test" "$(cat "$tmp/called")"

finish
```

(The last case pipes the script on stdin, exactly like `curl | sh -s --`.)

- [ ] **Step 2: Run to verify failure**

Run: `sh tests/get_test.sh`
Expected: `sh: 0: cannot open .../get.sh`, non-zero exit.

- [ ] **Step 3: Write `get.sh`**

`get.sh` (mode 755):

```sh
#!/bin/sh
# get.sh - put fluxer-ops on this server and hand over to its setup.sh, which checks
# everything, asks before changing anything, and installs Fluxer too if there is none.
#
#   curl -fsSL https://raw.githubusercontent.com/kipavy/fluxer-ops/main/get.sh | sh
#
# Rather read first? The same, by hand:
#   git clone https://github.com/kipavy/fluxer-ops ~/fluxer/ops && ~/fluxer/ops/setup.sh
#
# Non-interactive (no terminal): FLUXER_OPS_YES=1, and setup's flags after `sh -s --`:
#   curl -fsSL .../get.sh | FLUXER_OPS_YES=1 sh -s -- --domain chat.example.com --email me@example.com

# Everything is inside main, called on the last line: a download cut short runs nothing.
main() {
	set -eu
	repo=${FLUXER_OPS_REPO:-https://github.com/kipavy/fluxer-ops.git}

	# Under `curl | sh` stdin is this script, so questions go to the terminal directly.
	tty=0
	if (: < /dev/tty) 2> /dev/null; then tty=1; fi
	if [ "$tty" -eq 0 ] && [ "${FLUXER_OPS_YES:-0}" != 1 ]; then
		die 2 "no terminal to ask questions on. Run it from an interactive shell, or set FLUXER_OPS_YES=1 (a new instance also needs: sh -s -- --domain D --email E)."
	fi

	command -v git > /dev/null 2>&1 || die 2 "git is needed first: $(pkg_hint git)"

	dir=$(find_instance)
	if [ -n "$dir" ]; then
		say "Fluxer found at $dir"
	else
		say "No Fluxer on this server yet: setup will install it."
		if [ "$tty" -eq 1 ]; then
			printf 'Install it into [%s]: ' "$HOME/fluxer"
			read -r dir < /dev/tty || dir=''
		fi
		dir=${dir:-$HOME/fluxer}
	fi

	target=$dir/ops
	if [ -d "$target/.git" ] && [ -f "$target/fluxer" ]; then
		say "Updating $target"
		git -C "$target" pull --ff-only -q || die 3 "$target has local changes that a fast-forward cannot keep. Sort them out with git, then run this again."
	elif [ -e "$target" ]; then
		die 3 "$target exists and is not fluxer-ops. Move it away, or choose another directory."
	else
		mkdir -p "$dir" || die 2 "cannot create $dir. Pick a directory you can write to."
		say "Downloading fluxer-ops into $target"
		git clone -q "$repo" "$target"
	fi

	if [ "$tty" -eq 1 ]; then
		exec sh "$target/setup.sh" --fluxer-dir "$dir" "$@" < /dev/tty
	fi
	exec sh "$target/setup.sh" --fluxer-dir "$dir" --yes "$@" < /dev/null
}

say() { printf '%s\n' "$*"; }
die() {
	code=$1
	shift
	printf 'get.sh: %s\n' "$*" >&2
	exit "$code"
}

pkg_hint() {
	if command -v apt-get > /dev/null 2>&1; then echo "sudo apt-get install -y $1"
	elif command -v dnf > /dev/null 2>&1; then echo "sudo dnf install -y $1"
	elif command -v zypper > /dev/null 2>&1; then echo "sudo zypper install -y $1"
	elif command -v pacman > /dev/null 2>&1; then echo "sudo pacman -S --needed $1"
	elif command -v apk > /dev/null 2>&1; then echo "sudo apk add $1"
	else echo "install $1 with this distribution's package manager"; fi
}

# The same rule as lib.sh, which is not here yet: FLUXER_DIR, a compose project
# whose .env names a FLUXER_DOMAIN, then the two usual places.
find_instance() {
	if [ -n "${FLUXER_DIR:-}" ]; then printf '%s' "$FLUXER_DIR"; return 0; fi
	if command -v docker > /dev/null 2>&1; then
		_d=$(docker compose ls --all --format json 2> /dev/null \
			| grep -o '"ConfigFiles":"[^"]*"' | sed 's/^"ConfigFiles":"//; s/[",].*//' \
			| while IFS= read -r f; do
				grep -q '^FLUXER_DOMAIN=' "$(dirname "$f")/.env" 2> /dev/null && dirname "$f"
			done | sort -u)
		if [ -n "$_d" ] && [ "$(printf '%s\n' "$_d" | grep -c .)" -eq 1 ]; then printf '%s' "$_d"; return 0; fi
	fi
	for _d in "$HOME/fluxer" /opt/fluxer; do
		if [ -f "$_d/docker-compose.yml" ] && [ -f "$_d/.env" ]; then printf '%s' "$_d"; return 0; fi
	done
}

main "$@"
```

- [ ] **Step 4: Run tests**

Run: `sh tests/get_test.sh && ./selftest.sh --lint`
Expected: all ok; PASS; shellcheck clean.

Note for the selftest "sources lib.sh" check from Task 2: `get.sh` is excluded there on purpose (it runs before the repo exists).

- [ ] **Step 5: Commit**

```bash
git add get.sh tests/get_test.sh
git commit -m "Add get.sh: the one-line install that clones fluxer-ops and runs setup"
```

---

### Task 9: README

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the commands and messages from Tasks 3–8 (the troubleshooting text must match what setup prints).

- [ ] **Step 1: Replace the top of the README**

Replace everything from the first line to just before `## The \`fluxer\` command` with:

````markdown
# fluxer-ops

Run your own [Fluxer](https://github.com/fluxerapp/fluxer) chat server, and keep it
running: nightly backups, a watchdog, alerts, safe updates, and one `fluxer` command
for the rest.

## Quick start

You need:

- a Linux server with a public IP (any VPS: Oracle Cloud, Hetzner, AWS, DigitalOcean…)
- a domain or subdomain you can add a DNS record to

On the server, as a normal user who can `sudo`:

```sh
curl -fsSL https://raw.githubusercontent.com/kipavy/fluxer-ops/main/get.sh | sh
```

It checks everything before it changes anything, and asks before each change:

1. **Prerequisites**: installs Docker if it is missing, gives you access to it.
2. **Your instance**: uses the Fluxer already on the server, or installs one: it checks
   your domain points here, tells you which ports to open at your provider, then runs
   Fluxer's official installer (checksum-verified).
3. **Wiring**: the `fluxer` command, nightly backups, the watchdog.
4. **Optional**: alerts to your phone or chat, encrypted off-site backups, fixes for
   firewalld and Cloudflare, each offered only when it applies.
5. **Checks**, then prints your instance's URL and what to do next.

Running it again is safe: whatever is already done shows ✓ and is left alone.
`fluxer setup --check` reports without changing anything.

Prefer to read before running anything? The same thing, without the pipe:

```sh
git clone https://github.com/kipavy/fluxer-ops ~/fluxer/ops
~/fluxer/ops/setup.sh
```

Already running Fluxer somewhere else than `~/fluxer`? It is found through Docker, or
point at it: `FLUXER_DIR=/path/to/fluxer` before either command.

### If the first install does not come up

| Symptom | Fix |
| --- | --- |
| "does not point at this server yet" | Add the `A` record setup shows at your DNS provider. It can take a few minutes; press Enter to re-check. |
| Installer stops with "the stack did not come up" | Almost always ports 80/443 closed at the provider (security list / security group / cloud firewall), or DNS. Open them and run `fluxer setup` again. |
| Behind Cloudflare and no certificate | Set the record to "DNS only" until the certificate is issued, then back to proxied with SSL mode "Full (strict)". |
| "cannot use Docker" after a reboot or new login | Log out and back in once: the docker group applies to new logins. |
| Voice calls connect but no audio | Ports 7881/tcp and 7882/udp at the provider. `fluxer voice` checks them. |

## This deployment

Upstream ships `install.sh`, which handles **installs, updates and rollback**, and
takes a backup **only during an upgrade**. There is no upstream CLI for monitoring or
for scheduled backups. These scripts fill that gap. They started on an Oracle Cloud
host with firewalld, which is where several of them (watchdog, firewall-fix) come
from.
````

- [ ] **Step 2: Fix the scripts table and the old install section**

In the Scripts table, replace the `install-host.sh` row with:

```markdown
| `setup.sh` | you, or `get.sh` | Prerequisites, the instance (installing it if needed), the `fluxer` symlink, completion, cron jobs, optional extras. Idempotent; `--check` only reports. |
| `get.sh` | `curl \| sh` | Clones this repository next to the instance and runs `setup.sh`. |
| `lib.sh` | every script | Finds the instance (`FLUXER_DIR`) and backups (`BACKUP_ROOT`); nothing is hardcoded. |
| `install-host.sh` | old habits | Same as `setup.sh --no-extras`. |
```

Replace the whole `## Install on a fresh host` section with:

````markdown
## Cron jobs

`fluxer setup` adds them, and never rewrites a line already there:

- `watchdog.sh` every 10 minutes in **root's** crontab (it needs iptables and systemctl)
- `backup.sh` at 03:00 and `disk.sh --record` at 03:30 in the user's

Each line carries `FLUXER_DIR=`, since cron starts with an empty environment.
`fluxer setup --check` exits 1 if one is missing, which is also what `fluxer doctor`
looks at.
````

Replace the `Host` line in the command overview with:

```
Host      setup  notify  disk  env  cf-ips  firewall-fix
```

Then: `grep -n '/home/ubuntu' README.md` and reword every remaining hit as this deployment's example (e.g. "on this deployment, `/home/ubuntu/Documents/fluxer`"), never as an instruction.

- [ ] **Step 3: Verify**

Run: `./selftest.sh && grep -n 'install-host' README.md fluxer`
Expected: PASS; `install-host` only in the scripts table row and the `fluxer` dispatch line.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "README: lead with the one-line install and first-install troubleshooting"
```

---

### Task 10: End-to-end verification

**Files:** none changed unless a step fails (fix in the owning task's files, re-run its tests, commit).

- [ ] **Step 1: Everything static**

Run: `./selftest.sh --lint`
Expected: `PASS  ops tooling intact`, shellcheck clean.

- [ ] **Step 2: This host, report then apply**

Run: `./setup.sh --check; echo rc=$?`
Expected: all `✓` except `✗ disk.sh --record ... missing`, `rc=1`.

Run: `./setup.sh --no-extras` (answers nothing but sudo's password)
Expected: the disk cron line is appended with `FLUXER_DIR=/home/ubuntu/Documents/fluxer`; `crontab -l` shows the two old lines unchanged plus the new one; the Checking block ends with `fluxer-ops is set up for https://fluxer.kipavy.fr`.

Run: `./setup.sh --check; echo rc=$?`
Expected: everything `✓`, `rc=0`.

- [ ] **Step 3: A fresh machine, as far as it goes without a real domain**

```sh
docker run --rm -v "$PWD:/src:ro" ubuntu:24.04 sh -c '
  apt-get update -qq && apt-get install -y -qq git curl python3 sudo > /dev/null
  useradd -m -s /bin/sh -G sudo u && echo "u ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/u
  git config --global --add safe.directory /src/.git
  su u -c "cd && git config --global --add safe.directory \"*\" && FLUXER_OPS_REPO=/src FLUXER_OPS_YES=1 DOCKER_INSTALL_URL=file:///nonexistent sh /src/get.sh --domain chat.example.com --email me@example.com"
  echo "rc=$?"; ls ~u/fluxer/ops/setup.sh'
```

Expected: `Downloading fluxer-ops into /home/u/fluxer/ops`; setup prints `Prerequisites`, `✗ Docker is not installed`, `→ installing Docker`, then `✗ Could not download file:///nonexistent.` with `rc=4`; the clone exists. (Docker-in-container is not attempted; the point is the path from nothing to setup's first real decision.)

Then with a terminal, declining Docker:

```sh
docker run --rm -it -v "$PWD:/src:ro" ubuntu:24.04 sh -c '
  apt-get update -qq && apt-get install -y -qq git curl python3 > /dev/null
  git config --global --add safe.directory "*"
  FLUXER_OPS_REPO=/src sh /src/get.sh'
```

At `Install it into [/root/fluxer]:` press Enter; expect the root warning, answer `y`; at `Install Docker now? [Y/n]` answer `n`; expect exit with the docs.docker.com message.

- [ ] **Step 4: The published one-liner (after pushing)**

After `git push`: `curl -fsSL https://raw.githubusercontent.com/kipavy/fluxer-ops/main/get.sh | head -3` returns the script header.

- [ ] **Step 5: Manual acceptance (not automated)**

On a fresh VPS with a real domain: run the one-liner, follow it, and time it. Pass: instance reachable at `https://<domain>`, account created, `fluxer users staff` works, `fluxer doctor` has no FAIL. Record the time and any confusing prompt as follow-ups.
