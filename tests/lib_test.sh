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

# No instance found (default LS_JSON=[], no docker-compose.yml above loose/ops):
# an inherited BACKUP_ROOT must not survive, or it becomes a trap once need_instance
# is bypassed or misused - only FLUXER_DIR earns a BACKUP_ROOT.
assert_eq "BACKUP_ROOT from the environment is dropped when no instance is found" \
	"$tmp/loose/ops||" "$(run env BACKUP_ROOT=/b "$tmp/loose/ops/probe")"

out=$(run env NEED=1 "$tmp/loose/ops/probe" 2>&1) && rc=0 || rc=$?
assert_eq "need_instance exits 2 when nothing is found" 2 "$rc"
assert_contains "need_instance says how to fix it" "FLUXER_DIR=" "$out"

# --- reaching edge on this host, by rexctl's edge mode ------------------------------
# curl stub: prints its arguments, one per line, and the status code it was asked for.
mkdir -p "$tmp/edge/.rexctl" "$tmp/curlstub"
cat > "$tmp/curlstub/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$CURL_ARGS"
printf 200
EOF
chmod +x "$tmp/curlstub/curl"
export CURL_ARGS="$tmp/curl.args"
edge() { # <state.json settings lines> -> runs fx_edge_mode and fx_origin_get in that instance
	printf '{\n  "project": "fluxer",\n  "settings": {\n%s\n  }\n}\n' "$1" > "$tmp/edge/.rexctl/state.json"
	(
		PATH="$tmp/curlstub:$PATH" FLUXER_DIR="$tmp/edge"
		. "$OPS_SRC/lib.sh"
		printf '%s|%s\n' "$(fx_edge_mode)" "$(fx_origin_get chat.example.test /ops-api/health)"
	)
}

assert_eq "no edge.mode: bundled, reached over https on 127.0.0.1" "bundled|200" "$(edge '    "edge.trusted_proxies": "private_ranges"')"
args=$(cat "$CURL_ARGS")
assert_contains "bundled: resolves the domain to 127.0.0.1:443" "chat.example.test:443:127.0.0.1" "$args"
assert_contains "bundled: https URL" "https://chat.example.test/ops-api/health" "$args"

assert_eq "edge.mode proxy is read" "proxy|200" \
	"$(edge "$(printf '    "edge.bind": "10.0.0.5:8080",\n    "edge.mode": "proxy",')")"
args=$(cat "$CURL_ARGS")
assert_contains "proxy: plain http on edge.bind" "http://10.0.0.5:8080/ops-api/health" "$args"
assert_contains "proxy: Host header carries the domain" "Host: chat.example.test" "$args"
case "$args" in *--resolve*) fail "proxy: no --resolve" ;; *) pass "proxy: no --resolve" ;; esac

assert_eq "proxy without edge.bind: rexctl's default 127.0.0.1:8080" "proxy|200" \
	"$(edge '    "edge.mode": "proxy",')"
assert_contains "proxy default bind" "http://127.0.0.1:8080/ops-api/health" "$(cat "$CURL_ARGS")"
assert_contains "body goes to /dev/null unless asked" "$(printf -- '-o\n/dev/null')" "$(cat "$CURL_ARGS")"
(PATH="$tmp/curlstub:$PATH" FLUXER_DIR="$tmp/edge"; . "$OPS_SRC/lib.sh"; fx_origin_get d.test /x "$tmp/body" > /dev/null)
assert_contains "body file is the one asked for" "$(printf -- '-o\n%s' "$tmp/body")" "$(cat "$CURL_ARGS")"

# rexctl writes the Caddyfile under .rexctl/generated/, the old installer at the top.
: > "$tmp/edge/Caddyfile.none"
mkdir -p "$tmp/edge/.rexctl/generated"
printf 'import /etc/caddy/conf.d/*.caddy\n' > "$tmp/edge/.rexctl/generated/Caddyfile"
assert_eq "managed: the Caddyfile is rexctl's generated one" "$tmp/edge/.rexctl/generated/Caddyfile" \
	"$(FLUXER_DIR="$tmp/edge"; . "$OPS_SRC/lib.sh"; fx_caddyfile)"
rm -rf "$tmp/edge/.rexctl"
assert_eq "not managed: the Caddyfile at the top of the instance" "$tmp/edge/Caddyfile" \
	"$(FLUXER_DIR="$tmp/edge"; . "$OPS_SRC/lib.sh"; fx_caddyfile)"

finish
