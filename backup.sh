#!/bin/sh
# Nightly backup, run from the ubuntu user's cron.
#
# The database dump is fully consistent and needs no downtime. The uploads copy
# is taken hot (no stack stop): SeaweedFS blobs are effectively write-once, so
# this is safe in practice. install.sh --update still takes its own cold,
# stack-stopped copy before every upgrade, so upgrades are covered separately.
#
# A backup that silently stopped working is found out at restore time, which is
# the worst time. So a failure goes to notify.sh (key `backup`), and the next
# good run sends the all-clear. Without a notify.conf that is a no-op.
set -eu

. "$(dirname "$(readlink -f "$0")")/lib.sh"
need_instance
KEEP_DAYS=${KEEP_DAYS:-14}
LOG="$BACKUP_ROOT/backup.log"
NOTIFY="$OPS/notify.sh"

# Best effort: a missing or failing notify.sh never fails the backup itself.
notify() {
	[ -x "$NOTIFY" ] || return 0
	if [ -d "$BACKUP_ROOT" ]; then
		"$NOTIFY" "$@" 2>> "$LOG" > /dev/null || true
	else
		"$NOTIFY" "$@" > /dev/null 2>&1 || true
	fi
}

# Anything that kills the run, set -e included, is reported with where it died.
stage='starting'
on_exit() {
	rc=$?
	if [ "$rc" -ne 0 ]; then
		notify alert backup "Backup FAILED at: $stage (exit $rc). Last log lines:
$(tail -n 5 "$LOG" 2> /dev/null | cut -c 1-200)"
	fi
}
trap on_exit EXIT

mkdir -p "$BACKUP_ROOT"
log() { printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG"; }

ts=$(date -u +%Y%m%dT%H%M%SZ)
dest="$BACKUP_ROOT/auto-$ts"
mkdir -p "$dest"
cd "$FLUXER_DIR"

# 1. Database.
stage='database dump (pg_dump)'
if docker compose exec -T postgres pg_dump -U fluxer -d fluxer --format=custom > "$dest/fluxer.dump" 2>> "$LOG"; then
	log "dump ok      $(du -h "$dest/fluxer.dump" | cut -f1)  -> auto-$ts"
else
	log "dump FAILED  - removing incomplete $dest"
	rm -rf "$dest"
	exit 1
fi

# 2. Uploads.
stage='uploads copy'
uploads=ok
if docker run --rm -v fluxer_seaweedfs-data:/data:ro -v "$dest:/backup" alpine:3.22 \
	tar czf /backup/seaweedfs-data.tgz -C /data . >> "$LOG" 2>&1; then
	log "uploads ok   $(du -h "$dest/seaweedfs-data.tgz" | cut -f1)"
else
	log "uploads FAILED"
	uploads=failed
fi

# 3. Config and secrets - without .env the other two cannot be restored.
stage='copying .env and config'
cp .env "$dest/.env"
chmod 600 "$dest/.env"
cp docker-compose.yml Caddyfile "$dest/" 2> /dev/null || true
cp -r ops "$dest/ops" 2> /dev/null || true

# 4. Retention.
stage='retention'
find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'auto-*' -mtime +"$KEEP_DAYS" -exec rm -rf {} + 2> /dev/null || true
log "complete     $(du -sh "$dest" | cut -f1)  (keeping ${KEEP_DAYS}d)"

# 5. Off-site. A silent no-op until ops/offsite.conf exists; offsite.sh alerts on
#    its own key, so a failed push never marks the local backup as failed.
stage='off-site push'
"$OPS/offsite.sh" push --if-configured "$dest" >> "$BACKUP_ROOT/offsite.log" 2>&1 \
	|| log "offsite FAILED  (see offsite.log)"

if [ "$uploads" = ok ]; then
	notify ok backup "auto-$ts complete, $(du -sh "$dest" | cut -f1)."
else
	notify alert backup "Uploads copy FAILED in auto-$ts: the database was dumped, but that backup has no uploads (seaweedfs-data.tgz). See $LOG."
fi
