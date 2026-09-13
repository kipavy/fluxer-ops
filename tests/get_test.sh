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
