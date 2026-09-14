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

# The docker-detection path (find_instance's middle step, mirroring lib.sh's
# fluxer_projects): a second stub docker that answers `compose ls --all --format
# json` from a JSON fixture, so this pipeline actually runs instead of always
# failing like the "exit 1" stub above. Still no real docker, no network.
mkdir -p "$tmp/dstub"
printf '#!/bin/sh\nif [ "$1" = compose ] && [ "$2" = ls ]; then cat "$DOCKER_LS_JSON"; else exit 1; fi\n' > "$tmp/dstub/docker"
chmod +x "$tmp/dstub/docker"
gd() { env -u FLUXER_DIR HOME="$home" PATH="$tmp/dstub:$PATH" FLUXER_OPS_REPO="$tmp/repo" GET_TEST_OUT="$tmp/called" DOCKER_LS_JSON="$tmp/ls.json" "$@" setsid -w sh "$SRC/get.sh" < /dev/null; }

# One compose project with a FLUXER_DOMAIN in its .env: chosen.
home="$tmp/home_a"; mkdir -p "$home"
mkdir -p "$tmp/proj_a" && printf 'FLUXER_DOMAIN=proj-a.test\n' > "$tmp/proj_a/.env" && : > "$tmp/proj_a/docker-compose.yml"
printf '[{"Name":"proja","Status":"running(1)","ConfigFiles":"%s/docker-compose.yml"}]\n' "$tmp/proj_a" > "$tmp/ls.json"
gd env FLUXER_OPS_YES=1 > /dev/null 2>&1
[ -f "$tmp/proj_a/ops/setup.sh" ] && pass "docker: sole domain project chosen" || fail "docker: sole domain project chosen"

# One compose project with no FLUXER_DOMAIN in .env: not chosen, falls through
# to the well-known paths (here, neither exists, so the ~/fluxer default).
home="$tmp/home_b"; mkdir -p "$home"
mkdir -p "$tmp/proj_b" && : > "$tmp/proj_b/docker-compose.yml"
printf '[{"Name":"projb","Status":"running(1)","ConfigFiles":"%s/docker-compose.yml"}]\n' "$tmp/proj_b" > "$tmp/ls.json"
gd env FLUXER_OPS_YES=1 > /dev/null 2>&1
[ -f "$home/fluxer/ops/setup.sh" ] && pass "docker: domain-less project ignored, falls back" || fail "docker: domain-less project ignored, falls back"
[ -e "$tmp/proj_b/ops" ] && fail "docker: domain-less project not cloned into" || pass "docker: domain-less project not cloned into"

# Two compose projects each naming a FLUXER_DOMAIN: never guess between them,
# fall through to the well-known paths (here, the ~/fluxer default) instead.
home="$tmp/home_c"; mkdir -p "$home"
mkdir -p "$tmp/proj_c1" "$tmp/proj_c2"
printf 'FLUXER_DOMAIN=c1.test\n' > "$tmp/proj_c1/.env"; : > "$tmp/proj_c1/docker-compose.yml"
printf 'FLUXER_DOMAIN=c2.test\n' > "$tmp/proj_c2/.env"; : > "$tmp/proj_c2/docker-compose.yml"
printf '[{"Name":"c1","Status":"running(1)","ConfigFiles":"%s/docker-compose.yml"},{"Name":"c2","Status":"running(1)","ConfigFiles":"%s/docker-compose.yml"}]\n' \
	"$tmp/proj_c1" "$tmp/proj_c2" > "$tmp/ls.json"
gd env FLUXER_OPS_YES=1 > /dev/null 2>&1
[ -f "$home/fluxer/ops/setup.sh" ] && pass "docker: two domain projects, refuses to guess" || fail "docker: two domain projects, refuses to guess"
[ -e "$tmp/proj_c1/ops" ] && fail "docker: did not settle on project one" || pass "docker: did not settle on project one"
[ -e "$tmp/proj_c2/ops" ] && fail "docker: did not settle on project two" || pass "docker: did not settle on project two"

# A ConfigFiles value listing several comma-separated compose files (an overlay
# file alongside the base one, both in the project's directory): the directory
# comes from the first entry, not mangled by the comma.
home="$tmp/home_d"; mkdir -p "$home"
mkdir -p "$tmp/proj_d" && printf 'FLUXER_DOMAIN=d.test\n' > "$tmp/proj_d/.env" \
	&& : > "$tmp/proj_d/docker-compose.yml" && : > "$tmp/proj_d/docker-compose.override.yml"
printf '[{"Name":"projd","Status":"running(1)","ConfigFiles":"%s/docker-compose.yml,%s/docker-compose.override.yml"}]\n' \
	"$tmp/proj_d" "$tmp/proj_d" > "$tmp/ls.json"
gd env FLUXER_OPS_YES=1 > /dev/null 2>&1
[ -f "$tmp/proj_d/ops/setup.sh" ] && pass "docker: comma-separated ConfigFiles parsed from the first entry" || fail "docker: comma-separated ConfigFiles parsed from the first entry"

# Arguments after `sh -s --` reach setup.sh.
env -u FLUXER_DIR HOME="$tmp/home" PATH="$tmp/stub:$PATH" FLUXER_OPS_REPO="$tmp/repo" GET_TEST_OUT="$tmp/called" \
	FLUXER_OPS_YES=1 setsid -w sh -s -- --domain c.test < "$SRC/get.sh" > /dev/null 2>&1 || true
assert_contains "piped with args: forwarded" "--domain c.test" "$(cat "$tmp/called")"

finish
