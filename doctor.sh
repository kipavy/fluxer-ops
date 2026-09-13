#!/bin/sh
# doctor.sh - check every piece of configuration that has drifted on this
# instance, or quietly could.
#
# check.sh answers "is it serving right now". This answers "will it still be
# serving, and recoverable, next week": the watchdog is actually scheduled, the
# backups are fresh and complete and not only on this disk, someone gets told
# when things break, Docker survives firewalld, Cloudflare's ranges are trusted,
# the badge patch still matches the image under it, certificates are not about
# to lapse, and a rollback still has its images. Every one of these fails
# silently, which is how the instance was down for two weeks in Sept 2026.
#
# Read-only. Each check prints ok / warn / FAIL, and a fix for anything not ok.
# A check whose tool or permission is missing is skipped, not failed.
#
#   doctor.sh           everything
#   doctor.sh --quiet   only warn and FAIL
#
# Exit 0 = no FAIL (warnings allowed), 1 = at least one FAIL.
set -eu

FLUXER_DIR=${FLUXER_DIR:-/home/ubuntu/Documents/fluxer}
BACKUP_ROOT=${BACKUP_ROOT:-/home/ubuntu/Documents/fluxer-backups}
OPS="$FLUXER_DIR/ops"
KEEP_DAYS=${KEEP_DAYS:-14}
UPLOADS_VOLUME=fluxer_seaweedfs-data
HELPER_IMAGE=alpine:3.22

QUIET=0
case "${1:-}" in
	--quiet | -q) QUIET=1 ;;
	'') ;;
	*) echo "usage: doctor.sh [--quiet]" >&2; exit 2 ;;
esac

fails=0 warns=0
ok() { [ "$QUIET" -eq 1 ] || printf 'ok    %s\n' "$1"; }
skip() { [ "$QUIET" -eq 1 ] || printf 'skip  %s\n' "$1"; }
warn() {
	warns=$((warns + 1))
	printf 'warn  %s\n' "$1"
	[ -z "${2:-}" ] || printf '      fix: %s\n' "$2"
}
fail() {
	fails=$((fails + 1))
	printf 'FAIL  %s\n' "$1"
	[ -z "${2:-}" ] || printf '      fix: %s\n' "$2"
}

have() { command -v "$1" > /dev/null 2>&1; }
has_sudo() { sudo -n true 2> /dev/null; }
env_value() { sed -n "s/^$1=//p" "$FLUXER_DIR/.env" 2> /dev/null | head -n 1; }
compose() { (cd "$FLUXER_DIR" && docker compose "$@"); }

# Age in hours of a path's mtime.
age_hours() { echo $((($(date +%s) - $(stat -c %Y "$1")) / 3600)); }

# --- Docker and firewalld --------------------------------------------------

check_iptables() {
	if ! has_sudo; then
		skip "DOCKER nat chain (needs passwordless sudo)"
	elif sudo -n iptables -t nat -L -n 2> /dev/null | grep -q '^Chain DOCKER'; then
		ok "DOCKER nat chain present"
	else
		fail "DOCKER nat chain MISSING: no container can publish a port" \
			"sudo systemctl restart docker"
	fi
}

check_firewall_fix() {
	if [ ! -x "$OPS/firewall-fix.sh" ]; then
		skip "firewall fix (no ops/firewall-fix.sh)"
	elif "$OPS/firewall-fix.sh" --installed; then
		ok "firewall fix installed: docker restarts whenever firewalld starts"
	else
		warn "firewall fix not installed: a firewalld restart can wipe Docker's chains (the watchdog repairs it within 10 min)" \
			"fluxer firewall-fix --apply"
	fi

	# The latent version of the Sept 2026 outage: docker still running, but
	# deaf to firewalld because the bus it was connected to has gone.
	pid=$(systemctl show docker.service -p MainPID --value 2> /dev/null || true)
	if have busctl && [ -n "$pid" ] && [ "$pid" != 0 ] && systemctl is-active --quiet firewalld 2> /dev/null; then
		if busctl --system list --no-pager 2> /dev/null | awk -v p="$pid" '$2 == p {f=1} END {exit !f}'; then
			ok "dockerd is connected to D-Bus and will hear firewalld"
		else
			warn "dockerd has no D-Bus connection: the next firewalld reload will wipe its chains unnoticed" \
				"at a quiet moment: sudo systemctl restart docker"
		fi
	fi
}

# --- Scheduling and the command itself --------------------------------------

check_cron() {
	if ! has_sudo; then
		skip "root crontab (needs passwordless sudo)"
	elif sudo -n crontab -l -u root 2> /dev/null | grep -v '^[[:space:]]*#' | grep -qF "$OPS/watchdog.sh"; then
		ok "root cron runs watchdog.sh"
	else
		fail "watchdog.sh is not in root's crontab: nothing repairs the firewalld flush or a stopped stack" \
			"sudo crontab -e  ->  */10 * * * * $OPS/watchdog.sh >/dev/null 2>&1"
	fi

	if crontab -l 2> /dev/null | grep -v '^[[:space:]]*#' | grep -qF "$OPS/backup.sh"; then
		ok "user cron runs backup.sh"
	else
		fail "backup.sh is not in $(id -un)'s crontab: no scheduled backups" \
			"crontab -e  ->  0 3 * * * $OPS/backup.sh >/dev/null 2>&1"
	fi
}

check_symlink() {
	link="$HOME/.local/bin/fluxer"
	if [ ! -e "$link" ]; then
		warn "$link is missing: \`fluxer\` is not on PATH" "ln -sf $OPS/fluxer $link"
	elif [ "$(readlink -f "$link")" = "$(readlink -f "$OPS/fluxer")" ]; then
		ok "fluxer command points at $OPS/fluxer"
	else
		warn "$link points at $(readlink -f "$link"), not this checkout" "ln -sf $OPS/fluxer $link"
	fi
}

# --- Backups ------------------------------------------------------------------

check_backup() {
	newest=$(ls -dt "$BACKUP_ROOT"/auto-*/ 2> /dev/null | head -n 1 || true)
	newest=${newest%/}
	if [ -z "$newest" ]; then
		fail "no scheduled backup in $BACKUP_ROOT" "$OPS/backup.sh, then check the user crontab"
		return
	fi
	name=$(basename "$newest")
	h=$(age_hours "$newest")
	if [ "$h" -ge 30 ]; then
		fail "newest scheduled backup $name is ${h}h old (cron runs it daily)" \
			"$OPS/backup.sh and read $BACKUP_ROOT/backup.log"
	else
		ok "newest scheduled backup $name is ${h}h old"
	fi

	missing=''
	[ -s "$newest/fluxer.dump" ] || missing="$missing fluxer.dump"
	[ -s "$newest/seaweedfs-data.tgz" ] || missing="$missing seaweedfs-data.tgz"
	[ -s "$newest/.env" ] || missing="$missing .env"
	if [ -n "$missing" ]; then
		fail "$name is incomplete, missing:$missing" "read $BACKUP_ROOT/backup.log, then $OPS/backup.sh"
	else
		ok "$name has the dump, the uploads and .env"
	fi

	# The last run is everything from its "dump" line on; backup.sh logs an
	# uploads failure and carries on to "complete", so look at the whole run.
	log="$BACKUP_ROOT/backup.log"
	if [ ! -r "$log" ]; then
		warn "no $log" "$OPS/backup.sh"
		return
	fi
	last_run=$(grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z  ' "$log" \
		| awk '/  dump / {run = ""} {run = run $0 "\n"} END {printf "%s", run}')
	if printf '%s' "$last_run" | grep -q 'FAILED'; then
		fail "last backup run logged a failure: $(printf '%s' "$last_run" | grep 'FAILED' | head -n 1 | cut -c23-)" \
			"read $log"
	elif printf '%s' "$last_run" | grep -q '  complete '; then
		ok "last backup run completed cleanly"
	else
		warn "last backup run did not log completion (still running, or killed)" "read $log"
	fi
}

check_disk() {
	size=$(df -Pk "$FLUXER_DIR" | awk 'NR == 2 {print $2}')
	avail=$(df -Pk "$FLUXER_DIR" | awk 'NR == 2 {print $4}')
	pct=$((avail * 100 / size))
	if [ "$pct" -lt 10 ]; then
		fail "only ${pct}% free on the deployment filesystem ($((avail / 1048576)) GB)" \
			"fluxer backups, then remove old ones, or grow the disk"
	elif [ "$pct" -lt 20 ]; then
		warn "only ${pct}% free on the deployment filesystem ($((avail / 1048576)) GB)" \
			"fluxer backups, then remove old ones, or grow the disk"
	else
		ok "${pct}% free on the deployment filesystem ($((avail / 1048576)) GB)"
	fi

	# Retention keeps KEEP_DAYS full copies, so steady state is newest x KEEP_DAYS.
	newest=$(ls -dt "$BACKUP_ROOT"/auto-*/ 2> /dev/null | head -n 1 || true)
	[ -n "$newest" ] || return 0
	one=$(du -sk "$newest" 2> /dev/null | cut -f1)
	now=$(du -sk "$BACKUP_ROOT" 2> /dev/null | cut -f1)
	projected=$((one * KEEP_DAYS))
	growth=$((projected - now))
	[ "$growth" -gt 0 ] || growth=0
	summary="backups: $((now / 1024)) MB now, ~$((projected / 1024)) MB at ${KEEP_DAYS}-day retention"
	if [ "$growth" -ge "$avail" ]; then
		fail "$summary, which does not fit in the $((avail / 1024)) MB free" \
			"move to off-site backups and shorten KEEP_DAYS (README: Backup strategy)"
	elif [ "$((growth * 2))" -ge "$avail" ]; then
		warn "$summary, over half of the $((avail / 1024)) MB free" \
			"move to off-site backups and shorten KEEP_DAYS (README: Backup strategy)"
	else
		ok "$summary"
	fi
}

OFFSITE=unknown
check_offsite() {
	if [ ! -x "$OPS/offsite.sh" ]; then
		OFFSITE=none
		warn "no off-site backups: every backup is on the same disk as the data" \
			"README: Backup strategy (restic to R2)"
		return
	fi
	rc=0
	out=$(timeout 90 "$OPS/offsite.sh" status 2>&1) || rc=$?
	if printf '%s' "$out" | grep -qi 'not configured'; then
		OFFSITE=none
		warn "off-site backups not configured: every backup is on the same disk as the data" \
			"configure $OPS/offsite.conf (see offsite.conf.example), then: offsite.sh init"
	elif [ "$rc" -eq 0 ]; then
		OFFSITE=ok
		ok "off-site: $(printf '%s\n' "$out" | grep '^last push' | head -n 1 | sed 's/  */ /g')"
	else
		OFFSITE=broken
		fail "off-site backups are configured but not healthy: $(printf '%s\n' "$out" \
			| grep -E 'STALE|NONE|NOT|WRONG|UNREACHABLE' | head -n 1 | sed 's/  */ /g')" \
			"$OPS/offsite.sh status"
	fi
}

check_uploads() {
	if ! docker volume inspect "$UPLOADS_VOLUME" > /dev/null 2>&1; then
		skip "uploads volume size (no $UPLOADS_VOLUME volume)"
		return
	fi
	if ! docker image inspect "$HELPER_IMAGE" > /dev/null 2>&1; then
		skip "uploads volume size ($HELPER_IMAGE not pulled)"
		return
	fi
	kb=$(timeout 60 docker run --rm --pull never -v "$UPLOADS_VOLUME:/data:ro" "$HELPER_IMAGE" \
		du -sk /data 2> /dev/null | cut -f1) || kb=''
	case "$kb" in
		'' | *[!0-9]*) skip "uploads volume size (du failed)"; return ;;
	esac
	if [ "$kb" -gt 1048576 ] && [ "$OFFSITE" != ok ]; then
		warn "uploads are $((kb / 1024)) MB, past the 1 GB trigger for leaving full nightly copies" \
			"README: Backup strategy - move to restic on R2, then KEEP_DAYS=2"
	else
		ok "uploads are $((kb / 1024)) MB (1 GB is the trigger to move to restic)"
	fi
}

# --- Alerting -------------------------------------------------------------------

check_notify() {
	if [ ! -x "$OPS/notify.sh" ]; then
		warn "no alerting: nothing tells anyone when the watchdog or a backup fails" \
			"add ops/notify.sh and a channel"
		return
	fi
	out=$(timeout 30 "$OPS/notify.sh" status 2>&1) || true
	channels=$(printf '%s\n' "$out" | grep -E '^(ntfy|webhook|email) ' | grep -vc 'not configured' || true)
	if [ "${channels:-0}" -eq 0 ]; then
		warn "no notification channel configured: failures are only logged" \
			"configure $OPS/notify.conf (see notify.conf.example), then: notify.sh test"
	else
		ok "notifications: $channels channel(s) configured"
	fi
	failing=$(printf '%s\n' "$out" | grep '^FAILING' | awk '{print $2}' | tr '\n' ' ')
	[ -z "$failing" ] || warn "notify.sh has keys currently failing: $failing" "$OPS/notify.sh status"
}

# --- Edge -----------------------------------------------------------------------

check_cf_ips() {
	if [ ! -x "$OPS/cf-ips.sh" ]; then
		skip "Cloudflare ranges (no ops/cf-ips.sh)"
		return
	fi
	rc=0
	out=$("$OPS/cf-ips.sh" --quiet 2>&1) || rc=$?
	case "$rc" in
		0) ok "FLUXER_EDGE_TRUSTED_PROXIES matches Cloudflare's published ranges" ;;
		1) warn "FLUXER_EDGE_TRUSTED_PROXIES has drifted from Cloudflare: $(printf '%s\n' "$out" | grep -c '^[+-] ') range(s) differ" \
			"fluxer cf-ips --apply" ;;
		*) warn "could not compare Cloudflare ranges: $(printf '%s\n' "$out" | head -n 1)" "fluxer cf-ips" ;;
	esac
}

# Compare the badge patch with the image it was built from. badge-patch.sh
# records the stock chunk it patched in ops/patches/chunk.name; if that chunk is
# gone from the current app-proxy image, the mounted index.html points into a
# release that is no longer there.
check_badge_patch() {
	override="$FLUXER_DIR/docker-compose.override.yml"
	if [ ! -f "$override" ] || ! head -n 1 "$override" | grep -qF 'generated by ops/badge-patch.sh'; then
		ok "badge patch not applied (stock bundle)"
		return
	fi
	missing=''
	for src in $(sed -n 's|^ *- \./\(ops/patches/[^:]*\):.*|\1|p' "$override"); do
		[ -f "$FLUXER_DIR/$src" ] || missing="$missing $src"
	done
	if [ -n "$missing" ]; then
		fail "the override mounts patch files that do not exist:$missing (docker would mount empty directories)" \
			"fluxer badge-patch"
		return
	fi
	chunk=$(cat "$OPS/patches/chunk.name" 2> /dev/null || true)
	patched=$(cat "$OPS/patches/patched.name" 2> /dev/null || true)
	case "$chunk" in
		*[!A-Za-z0-9._-]* | .*) chunk='' ;;
		?*.js) ;;
		*) chunk='' ;;
	esac
	if [ -z "$chunk" ]; then
		fail "ops/patches/chunk.name is missing or malformed" "fluxer badge-patch"
		return
	fi
	if [ -z "$patched" ] || ! grep -qF "/assets/$patched" "$OPS/patches/index.html" 2> /dev/null; then
		fail "patched index.html does not reference the patched chunk ${patched:-?}" "fluxer badge-patch"
		return
	fi
	image=$(compose config --images 2> /dev/null | grep 'fluxer-app-proxy' | head -n 1) || image=''
	if [ -z "$image" ] || ! docker image inspect "$image" > /dev/null 2>&1; then
		skip "badge patch vs image (cannot resolve the app-proxy image)"
		return
	fi
	if timeout 30 docker run --rm --pull never --entrypoint sh "$image" \
		-c "test -f /srv/app/static/assets/$chunk" > /dev/null 2>&1; then
		ok "badge patch matches the app-proxy image (stock chunk $chunk is still in it)"
	else
		fail "badge patch was built from a different release: $chunk is not in $image" \
			"fluxer badge-patch"
	fi
}

# Days until the certificate served at $1 (host:port) for SNI $2 expires.
cert_days() {
	end=$(echo | timeout 15 openssl s_client -connect "$1" -servername "$2" 2> /dev/null \
		| openssl x509 -noout -enddate 2> /dev/null | sed 's/^notAfter=//') || end=''
	[ -n "$end" ] || return 1
	echo $((($(date -d "$end" +%s) - $(date +%s)) / 86400))
}

check_tls() {
	if ! have openssl; then
		skip "TLS certificates (no openssl)"
		return
	fi
	domain=$(env_value FLUXER_DOMAIN)
	if [ -z "$domain" ]; then
		fail "no FLUXER_DOMAIN in $FLUXER_DIR/.env"
		return
	fi
	for which in public origin; do
		case "$which" in
			public) target="$domain:443" label="public cert (Cloudflare's edge)"
				hint="Cloudflare dashboard: SSL/TLS > Edge Certificates" ;;
			origin) target="127.0.0.1:443" label="origin cert (Caddy)"
				hint="Caddy renews on its own; see: docker compose logs edge | grep -i acme" ;;
		esac
		days=$(cert_days "$target" "$domain") || days=''
		if [ -z "$days" ]; then
			warn "$label: could not read a certificate from $target" "$hint"
		elif [ "$days" -lt 3 ]; then
			fail "$label for $domain expires in $days day(s)" "$hint"
		elif [ "$days" -lt 14 ]; then
			warn "$label for $domain expires in $days days" "$hint"
		else
			ok "$label for $domain valid for $days days"
		fi
	done
}

# --- Rollback -------------------------------------------------------------------

# install.sh --rollback puts back the image IDs recorded by the newest upgrade
# (<dir>/backups/record-<ts>/images: "<reference> <sha256 id>", or "-" for one
# that was not running). An ID pruned from the host cannot come back: moving tags
# like v1 cannot be re-pulled to an old release.
check_rollback_images() {
	record=''
	for d in "$FLUXER_DIR"/backups/record-*; do
		[ -d "$d" ] && record=$d
	done
	if [ -z "$record" ]; then
		ok "no upgrade record yet (nothing to roll back to)"
		return
	fi
	if [ ! -r "$record/images" ]; then
		warn "$(basename "$record") has no images list: a rollback has nothing to restore" ""
		return
	fi
	total=0 gone=''
	while read -r ref id; do
		[ -n "$ref" ] && [ "${id:--}" != '-' ] || continue
		total=$((total + 1))
		docker image inspect "$id" > /dev/null 2>&1 || gone="$gone ${ref##*/}"
	done < "$record/images"
	if [ -n "$gone" ]; then
		warn "rollback to $(basename "$record") would miss pruned images:$gone" \
			"nothing restores them now; do not run 'docker image prune -a' until a release is trusted"
	else
		ok "rollback to $(basename "$record"): all $total recorded images still on disk"
	fi
}

check_iptables
check_firewall_fix
check_cron
check_symlink
check_backup
check_disk
check_offsite
check_uploads
check_notify
check_cf_ips
check_badge_patch
check_tls
check_rollback_images

if [ "$QUIET" -eq 0 ]; then
	echo
	if [ "$fails" -eq 0 ] && [ "$warns" -eq 0 ]; then
		echo "PASS  no drift found"
	else
		echo "$fails FAIL, $warns warn"
	fi
fi
[ "$fails" -eq 0 ]
