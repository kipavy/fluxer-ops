#!/bin/sh
# cf-ips.sh - keep FLUXER_EDGE_TRUSTED_PROXIES in step with Cloudflare's ranges.
#
# Public traffic reaches Caddy (the `edge` service) through Cloudflare's DNS proxy.
# The shipped Caddyfile sets trusted_proxies_strict and trusts only what this key
# lists, so a Cloudflare range missing from it means every visitor arriving through
# that range looks like Cloudflare's own address: rate limits and bans key off
# the edge node, not the client, and one abusive user can lock out everyone behind
# the same PoP. Cloudflare changes its list rarely and without telling anyone, so
# this compares the key with https://www.cloudflare.com/ips-v4 and /ips-v6.
#
# What is kept: `private_ranges`, any private/loopback/link-local range, and any
# token that is not a CIDR. Every other public range is treated as a Cloudflare
# range: one that is no longer on Cloudflare's list shows as removed. A fetch
# that fails, or returns anything that is not a plain list of CIDRs of a sane
# size, changes nothing.
#
#   cf-ips.sh            check: show drift. Exit 0 in sync, 1 drift, 2 cannot tell
#   cf-ips.sh --quiet    same, but print only drift and errors (doctor.sh)
#   cf-ips.sh --apply    back up .env, rewrite that one line, offer to recreate edge
#   cf-ips.sh --yes      with --apply: do not ask
#
# Only the FLUXER_EDGE_TRUSTED_PROXIES line of .env is ever read or printed.
set -eu

FLUXER_DIR=${FLUXER_DIR:-/home/ubuntu/Documents/fluxer}
ENV_FILE="$FLUXER_DIR/.env"
KEY=FLUXER_EDGE_TRUSTED_PROXIES
CF_URL=${CF_URL:-https://www.cloudflare.com}
MIN_V4=8 MIN_V6=4 MAX_RANGES=64

QUIET=0 APPLY=0 ASSUME_YES=0
for a in "$@"; do
	case "$a" in
		--quiet | -q) QUIET=1 ;;
		--apply) APPLY=1 ;;
		--yes | -y) ASSUME_YES=1 ;;
		-h | --help) sed -n '/^#   cf-ips.sh /s/^# *//p' "$0"; exit 0 ;;
		*) echo "usage: cf-ips.sh [--quiet] [--apply [--yes]]" >&2; exit 2 ;;
	esac
done

say() { if [ "$QUIET" -eq 0 ]; then printf '%s\n' "$*"; fi; }
cant() { printf 'cf-ips: %s\n' "$*" >&2; exit 2; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# One list, validated line by line. Output: one CIDR per line.
fetch() {
	curl -fsS --max-time 20 "$CF_URL/$1" > "$tmp/$1.raw" 2> "$tmp/$1.err" \
		|| cant "could not fetch $CF_URL/$1: $(head -n 1 "$tmp/$1.err")"
	# The files end without a newline; tolerate CRLF and blank lines, nothing else.
	{ cat "$tmp/$1.raw"; echo; } | tr -d '\r' | sed '/^[[:space:]]*$/d' > "$tmp/$1"
	case "$1" in
		ips-v4) bad=$(awk -F'[./]' '
			!/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ || $1 > 255 || $2 > 255 || $3 > 255 || $4 > 255 || $5 > 32 { print; exit }
			' "$tmp/$1") min=$MIN_V4 ;;
		ips-v6) bad=$(awk -F/ '
			!/^[0-9A-Fa-f:]+\/[0-9]+$/ || $1 !~ /:/ || $2 > 128 { print; exit }
			' "$tmp/$1") min=$MIN_V6 ;;
	esac
	[ -z "$bad" ] || cant "$CF_URL/$1 returned something that is not a CIDR list (first bad line: $(printf '%.60s' "$bad"))"
	n=$(grep -c . "$tmp/$1" || true)
	[ "$n" -ge "$min" ] && [ "$n" -le "$MAX_RANGES" ] \
		|| cant "$CF_URL/$1 returned $n ranges, expected $min-$MAX_RANGES - refusing to trust it"
}

# Kept regardless of what Cloudflare says: Caddy keywords, anything that is not
# a CIDR, and private address space.
keep_token() {
	case "$1" in
		*/*) ;;
		*) return 0 ;;
	esac
	case "$1" in
		10.* | 127.* | 192.168.* | 169.254.*) return 0 ;;
		172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 0 ;;
		100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].*) return 0 ;;
		[Ff][CcDd]*:* | [Ff][Ee]80:* | ::1/* | ::1) return 0 ;;
	esac
	return 1
}

fetch ips-v4
fetch ips-v6
cat "$tmp/ips-v4" "$tmp/ips-v6" > "$tmp/cf"
sort -u "$tmp/cf" > "$tmp/cf.sorted"

[ -r "$ENV_FILE" ] || cant "cannot read $ENV_FILE"
lines=$(grep -c "^$KEY=" "$ENV_FILE" || true)
[ "$lines" -le 1 ] || cant "$KEY is set $lines times in $ENV_FILE - fix that by hand first"
raw=$(sed -n "s/^$KEY=//p" "$ENV_FILE")
quote=''
case "$raw" in
	\"*\") quote='"'; raw=${raw#\"}; raw=${raw%\"} ;;
	\'*\') quote="'"; raw=${raw#\'}; raw=${raw%\'} ;;
esac
[ "$lines" -eq 1 ] || raw=''

: > "$tmp/kept"
: > "$tmp/current"
for t in $raw; do
	if keep_token "$t"; then
		printf '%s\n' "$t" >> "$tmp/kept"
	else
		printf '%s\n' "$t" >> "$tmp/current"
	fi
done
sort -u "$tmp/current" > "$tmp/current.sorted"
added=$(comm -13 "$tmp/current.sorted" "$tmp/cf.sorted")
removed=$(comm -23 "$tmp/current.sorted" "$tmp/cf.sorted")

say "cloudflare  $(grep -c . "$tmp/ips-v4") IPv4 + $(grep -c . "$tmp/ips-v6") IPv6 ranges"
if [ "$lines" -eq 0 ]; then
	say ".env        $KEY not set (Caddy falls back to private_ranges)"
else
	say ".env        $(grep -c . "$tmp/current.sorted" || true) Cloudflare ranges, kept: $(tr '\n' ' ' < "$tmp/kept")"
fi

if [ -z "$added$removed" ]; then
	say "ok    $KEY matches Cloudflare"
	[ "$APPLY" -eq 1 ] && say "Nothing to apply."
	exit 0
fi

[ -z "$added" ] || printf '%s\n' "$added" | sed 's/^/+ /; s/$/    on Cloudflare'"'"'s list, missing from .env/'
[ -z "$removed" ] || printf '%s\n' "$removed" | sed 's/^/- /; s/$/    in .env, no longer on Cloudflare'"'"'s list/'

if [ "$APPLY" -eq 0 ]; then
	printf 'drift  %s is out of step with Cloudflare - run: cf-ips.sh --apply\n' "$KEY"
	exit 1
fi

# Private entries first, in their original order, then Cloudflare's, in its order.
if [ "$lines" -eq 0 ]; then
	printf '%s\n' private_ranges > "$tmp/kept"
fi
value=$(cat "$tmp/kept" "$tmp/cf" | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//')
newline="$KEY=$quote$value$quote"

echo
echo "New value:"
printf '  %s\n' "$newline"
if [ "$ASSUME_YES" -eq 0 ]; then
	printf '\nBack up .env and write this line? [y/N] '
	read -r reply
	case "$reply" in
		y | Y | yes | YES) ;;
		*) echo "Aborted. Nothing changed."; exit 1 ;;
	esac
fi

ts=$(date -u +%Y%m%dT%H%M%SZ)
backup="$ENV_FILE.bak-$ts"
[ ! -e "$backup" ] || backup="$backup.$$"
cp -p "$ENV_FILE" "$backup"
chmod 600 "$backup"

# Same directory, so the final mv is an atomic rename on one filesystem.
new=$(mktemp "$ENV_FILE.tmp.XXXXXX")
chmod 600 "$new"
if [ "$lines" -eq 1 ]; then
	NEWLINE=$newline K="$KEY=" awk '
		index($0, ENVIRON["K"]) == 1 { print ENVIRON["NEWLINE"]; next } { print }
	' "$ENV_FILE" > "$new"
else
	{ cat "$ENV_FILE"; [ -z "$(tail -c 1 "$ENV_FILE")" ] || echo; printf '%s\n' "$newline"; } > "$new"
fi

# Everything but that one line must be byte-identical.
grep -v "^$KEY=" "$ENV_FILE" > "$tmp/old.rest" || true
grep -v "^$KEY=" "$new" > "$tmp/new.rest" || true
if ! cmp -s "$tmp/old.rest" "$tmp/new.rest" \
	|| [ "$(grep -c "^$KEY=" "$new")" -ne 1 ] \
	|| [ "$(sed -n "s/^$KEY=//p" "$new")" != "$quote$value$quote" ]; then
	rm -f "$new"
	echo "cf-ips: the rewritten .env did not check out - nothing changed (backup: $backup)" >&2
	exit 1
fi
chmod "$(stat -c %a "$ENV_FILE")" "$new"
[ "$(id -u)" -ne 0 ] || chown "$(stat -c %u:%g "$ENV_FILE")" "$new"
mv "$new" "$ENV_FILE"
echo "Wrote $KEY. Backup: $backup"

echo
echo "Caddy reads this only when the edge container is created, so it is not live yet."
echo "It needs: docker compose up -d edge  (a few seconds of TLS downtime)"
if [ "$ASSUME_YES" -eq 0 ]; then
	printf 'Recreate the edge now? [y/N] '
	read -r reply
	case "$reply" in
		y | Y | yes | YES) ;;
		*) echo "Not recreated. Run it when ready: cd $FLUXER_DIR && docker compose up -d edge"; exit 0 ;;
	esac
fi
(cd "$FLUXER_DIR" && docker compose up -d edge)
echo "Edge recreated with the new trusted proxies."
