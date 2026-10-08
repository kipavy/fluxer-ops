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
	# shellcheck disable=SC2034 # read by the panel.sh sourced below
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
