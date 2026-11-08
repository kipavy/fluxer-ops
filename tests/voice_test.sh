#!/bin/sh
# voice_test.sh - the voice/ kit runs LiveKit alone, behind a TLS proxy, with the
# settings it is given and nothing of the main stack. Renders with `docker compose
# config` only: nothing is pulled or started.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(dirname "$HERE")
. "$HERE/assert.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if ! docker compose version > /dev/null 2>&1; then
	echo "skip  voice_test.sh: needs docker compose"
	exit 0
fi

sed -e 's|^LIVEKIT_KEYS=.*|LIVEKIT_KEYS=testkey: testsecret-testsecret-testsecret-0123|' \
	-e 's|^LIVEKIT_WEBHOOK_URL=.*|LIVEKIT_WEBHOOK_URL=https://chat.example.test/api/webhooks/livekit|' \
	-e 's|^VOICE_DOMAIN=.*|VOICE_DOMAIN=voice.example.test|' \
	"$SRC/voice/env.example" > "$tmp/.env"
render() { docker compose --env-file "$tmp/.env" -f "$SRC/voice/compose.yml" "$@"; }

assert_eq "two services: livekit and proxy" "$(printf 'livekit\nproxy')" "$(render config --services | sort)"
cfg=$(render config)
assert_contains "livekit: rtc tcp port published" 'target: 7881' "$cfg"
assert_contains "livekit: rtc udp port published" 'protocol: udp' "$cfg"
assert_contains "proxy: http published" 'target: 80' "$cfg"
assert_contains "proxy: https published" 'target: 443' "$cfg"
assert_contains "webhook goes to the given url" 'https://chat.example.test/api/webhooks/livekit' "$cfg"
assert_contains "keys come from the env file" 'testkey: testsecret' "$cfg"
assert_contains "proxy knows its domain" 'VOICE_DOMAIN: voice.example.test' "$cfg"
case "$cfg" in *redis*) fail "single node: no redis" ;; *) pass "single node: no redis" ;; esac
case "$cfg" in *api:8080*) fail "no reference to the main stack" ;; *) pass "no reference to the main stack" ;; esac

caddyfile=$(cat "$SRC/voice/Caddyfile")
assert_contains "Caddyfile: site from VOICE_DOMAIN" '{$VOICE_DOMAIN}' "$caddyfile"
assert_contains "Caddyfile: proxies to livekit" 'reverse_proxy livekit:7880' "$caddyfile"

(cd "$SRC" && git check-ignore -q voice/.env) && pass "voice/.env is git-ignored" \
	|| fail "voice/.env is git-ignored"

finish
