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
assert_contains "the bridge never reaches badge-patch.sh" "Environment=PREMIUM_SKIP_BADGE_PATCH=1" "$unit"
assert_contains "knows the instance" "Environment=FLUXER_DIR=$tmp/inst" "$unit"

# The switch, with stubs for sudo, docker, curl and id on PATH and a stub overlay.sh:
# only the order and the exit codes are under test, nothing real is touched.
bin="$tmp/bin"; log="$tmp/log"
mkdir -p "$bin"
cat > "$bin/sudo" <<'STUB'
#!/bin/sh
echo "sudo $*" >> "$STUB_LOG"
case "$*" in *disable*) [ ! -f "$STUB_DIR/fail_systemctl" ] || exit 1 ;; esac
exit 0
STUB
cat > "$bin/docker" <<'STUB'
#!/bin/sh
echo "docker $*" >> "$STUB_LOG"
case "$*" in *adapt*) [ ! -f "$STUB_DIR/fail_adapt" ] || { echo "adapt: boom" >&2; exit 1; } ;; esac
case "$*" in *reload*) [ ! -f "$STUB_DIR/fail_reload" ] || exit 1 ;; esac
exit 0
STUB
cat > "$bin/curl" <<'STUB'
#!/bin/sh
echo '{"ok": true}'
STUB
cat > "$bin/id" <<'STUB'
#!/bin/sh
case "$*" in -nG) echo "alice docker" ;; -un | -gn) echo alice ;; esac
STUB
chmod +x "$bin"/*
cat > "$tmp/inst/ops/overlay.sh" <<'STUB'
#!/bin/sh
echo "overlay $*" >> "$STUB_LOG"
STUB
chmod +x "$tmp/inst/ops/overlay.sh"
cp "$up" "$tmp/inst/Caddyfile"
echo 'FLUXER_DOMAIN=example.test' > "$tmp/inst/.env"
echo '// stub' > "$tmp/inst/ops/ops-panel.js"
mkdir -p "$tmp/inst/ops/panel"
: > "$tmp/inst/ops/panel/enabled"
export STUB_LOG="$log" STUB_DIR="$tmp"
# The bridge unit "installed": off only talks to systemd when the unit file exists.
export PANEL_UNIT_FILE="$tmp/fluxer-ops-bridge.service"
: > "$PANEL_UNIT_FILE"

: > "$log"
rc=0; (PATH="$bin:$PATH"; load; cmd_off > /dev/null 2>&1) || rc=$?
assert_eq "off: exit 0 when everything works" 0 "$rc"
assert_eq "off: systemctl before overlay apply" "sudo systemctl disable --now fluxer-ops-bridge
overlay apply" "$(cat "$log")"
[ ! -f "$tmp/inst/ops/panel/enabled" ] && pass "off: switch removed" || fail "off: switch removed"

: > "$tmp/inst/ops/panel/enabled"; : > "$tmp/fail_systemctl"; : > "$log"
rc=0; err=$( (PATH="$bin:$PATH"; load; cmd_off) 2>&1 >/dev/null) || rc=$?
assert_eq "off: systemctl failure -> non-zero" 1 "$rc"
assert_contains "off: says what to do by hand" "systemctl disable --now fluxer-ops-bridge" "$err"
[ ! -f "$tmp/inst/ops/panel/enabled" ] && pass "off: switch still removed on failure" || fail "off: switch still removed on failure"
assert_contains "off: overlay still applied on failure" "overlay apply" "$(cat "$log")"
rm -f "$tmp/fail_systemctl"

rm -f "$tmp/inst/ops/panel/enabled" "$tmp/inst/ops/panel/Caddyfile"; : > "$tmp/fail_adapt"; : > "$log"
rc=0; err=$( (PATH="$bin:$PATH"; load; cmd_on) 2>&1 >/dev/null) || rc=$?
assert_eq "on: edge rejects the Caddyfile -> non-zero" 1 "$rc"
assert_contains "on: edge's error is shown" "adapt: boom" "$err"
[ ! -f "$tmp/inst/ops/panel/enabled" ] && [ ! -f "$tmp/inst/ops/panel/Caddyfile" ] \
	&& pass "on: failed adapt changed nothing" || fail "on: failed adapt changed nothing"
case "$(cat "$log")" in *systemctl*|*overlay*) fail "on: failed adapt touched systemd or overlay" ;; *) pass "on: failed adapt touched no service" ;; esac
rm -f "$tmp/fail_adapt"

# off with no unit installed: no systemctl at all, no failure
mv "$PANEL_UNIT_FILE" "$tmp/unit.hidden"; : > "$tmp/inst/ops/panel/enabled"; : > "$tmp/fail_systemctl"; : > "$log"
rc=0; out=$( (PATH="$bin:$PATH"; load; cmd_off) 2>&1) || rc=$?
assert_eq "off: no unit installed -> exit 0 even if systemctl would fail" 0 "$rc"
assert_contains "off: says the unit is not installed" "bridge unit not installed" "$out"
assert_eq "off: no unit installed -> systemctl not called" "overlay apply" "$(cat "$log")"
rm -f "$tmp/fail_systemctl"; mv "$tmp/unit.hidden" "$PANEL_UNIT_FILE"

# first on: edge refuses the Caddyfile at reload -> panel back off AND the bridge stopped
rm -f "$tmp/inst/ops/panel/enabled" "$tmp/inst/ops/panel/Caddyfile"; : > "$tmp/fail_reload"; : > "$log"
rc=0; err=$( (PATH="$bin:$PATH"; load; cmd_on) 2>&1 >/dev/null) || rc=$?
assert_eq "on: first-on reload failure -> non-zero" 1 "$rc"
assert_contains "on: first-on reload failure: message says the bridge stopped" "switched back off and the bridge stopped" "$err"
assert_eq "on: first-on reload failure: bridge disabled last" "sudo systemctl disable --now fluxer-ops-bridge" "$(grep '^sudo' "$log" | tail -n 1)"
[ ! -f "$tmp/inst/ops/panel/enabled" ] && pass "on: first-on reload failure: switch removed" || fail "on: first-on reload failure: switch removed"
rm -f "$tmp/fail_reload"

finish
