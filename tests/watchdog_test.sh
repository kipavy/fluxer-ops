#!/bin/sh
# watchdog_test.sh - the watchdog finds iptables, systemctl and runuser under cron.
# Cron starts jobs with PATH=/usr/bin:/bin. On Debian those three live in /usr/sbin or
# /sbin, so without its own PATH the watchdog took a missing iptables for a flushed
# DOCKER chain and restarted docker every 10 minutes (2026-11-08, in an LXC).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(dirname "$HERE")
. "$HERE/assert.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Everything watchdog.sh runs before it sources lib.sh, with cron's environment: the
# PATH it ends up with.
sed -n '1,/^\. .*lib\.sh/p' "$SRC/watchdog.sh" | sed '$d' > "$tmp/head.sh"
printf '\nprintf "%%s\\n" "$PATH"\n' >> "$tmp/head.sh"
path=$(env -i PATH=/usr/bin:/bin sh "$tmp/head.sh")

for d in /usr/sbin /sbin /usr/bin /bin; do
	case ":$path:" in
		*":$d:"*) pass "under cron's PATH, $d is searched" ;;
		*) fail "under cron's PATH, $d is searched: got [$path]" ;;
	esac
done
case ":$path:" in
	*":/usr/bin:/bin:"*) pass "the caller's PATH is kept" ;;
	*) fail "the caller's PATH is kept: got [$path]" ;;
esac

finish
