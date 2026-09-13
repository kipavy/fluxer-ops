#!/bin/sh
# Verify the Fluxer instance is actually serving, not merely running.
# Exit 0 = healthy, 1 = something is wrong. Safe to run at any time.
#   ./check.sh            full output
#   ./check.sh --quiet    only failures (used by watchdog.sh)
set -eu

FLUXER_DIR=${FLUXER_DIR:-/home/ubuntu/Documents/fluxer}
QUIET=0
if [ "${1:-}" = "--quiet" ]; then QUIET=1; fi

say() { if [ "$QUIET" -eq 0 ]; then printf '%s\n' "$*"; fi; }
fails=0
note_fail() { fails=$((fails + 1)); printf 'FAIL  %s\n' "$*" >&2; }

domain=$(sed -n 's/^FLUXER_DOMAIN=//p' "$FLUXER_DIR/.env" | head -n 1)
if [ -z "$domain" ]; then
	echo "FAIL  no FLUXER_DOMAIN in $FLUXER_DIR/.env" >&2
	exit 1
fi
base="https://$domain"
say "Checking $base"
say ""

# 1. Public HTTP endpoints.
for p in /_health /api/_health /gateway/_health /media/_health /.well-known/fluxer /; do
	code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$base$p" 2>/dev/null || echo 000)
	if [ "$code" = "200" ]; then
		say "ok    $code  $p"
	else
		note_fail "$code  $p"
	fi
done

# 2. WebSocket upgrade. Must be 101. curl cannot test this: its handshake is
#    malformed and returns a misleading 426 even when the gateway is fine.
if command -v python3 > /dev/null 2>&1; then
	ws=$(python3 - "$domain" 2>/dev/null <<'PY' || echo ERROR
import socket, ssl, base64, os, sys
h = sys.argv[1]
k = base64.b64encode(os.urandom(16)).decode()
req = (f"GET /gateway HTTP/1.1\r\nHost: {h}\r\nUpgrade: websocket\r\n"
       f"Connection: Upgrade\r\nSec-WebSocket-Key: {k}\r\n"
       f"Sec-WebSocket-Version: 13\r\n\r\n")
ctx = ssl.create_default_context()
with socket.create_connection((h, 443), timeout=20) as s:
    with ctx.wrap_socket(s, server_hostname=h) as ss:
        ss.sendall(req.encode())
        print(ss.recv(200).decode(errors="replace").splitlines()[0])
PY
	)
	case "$ws" in
		*101*) say "ok    101  /gateway websocket upgrade" ;;
		*) note_fail "websocket upgrade: ${ws:-no response} (want 101)" ;;
	esac
else
	say "skip  websocket check (no python3)"
fi

# 3. Container health. seaweedfs-init is a one-shot bucket job; Exited (0) is correct.
bad=$(cd "$FLUXER_DIR" && docker compose ps -a --format '{{.Service}} {{.Status}}' 2>/dev/null \
	| grep -v '^seaweedfs-init ' | grep -Ev ' Up .*healthy| Up [0-9]' || true)
if [ -n "$bad" ]; then
	note_fail "containers not healthy:"
	printf '%s\n' "$bad" >&2
else
	say "ok    all containers healthy"
fi

say ""
if [ "$fails" -eq 0 ]; then
	say "PASS  instance healthy"
	exit 0
fi
printf '\n%s check(s) failed\n' "$fails" >&2
exit 1
