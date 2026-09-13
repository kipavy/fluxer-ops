#!/bin/sh
# Nightly backup, run from the ubuntu user's cron.
#
# The database dump is fully consistent and needs no downtime. The uploads copy
# is taken hot (no stack stop): SeaweedFS blobs are effectively write-once, so
# this is safe in practice. install.sh --update still takes its own cold,
# stack-stopped copy before every upgrade, so upgrades are covered separately.
set -eu

FLUXER_DIR=${FLUXER_DIR:-/home/ubuntu/Documents/fluxer}
BACKUP_ROOT=${BACKUP_ROOT:-/home/ubuntu/Documents/fluxer-backups}
KEEP_DAYS=${KEEP_DAYS:-14}
LOG="$BACKUP_ROOT/backup.log"

mkdir -p "$BACKUP_ROOT"
log() { printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG"; }

ts=$(date -u +%Y%m%dT%H%M%SZ)
dest="$BACKUP_ROOT/auto-$ts"
mkdir -p "$dest"
cd "$FLUXER_DIR"

# 1. Database.
if docker compose exec -T postgres pg_dump -U fluxer -d fluxer --format=custom > "$dest/fluxer.dump" 2>> "$LOG"; then
	log "dump ok      $(du -h "$dest/fluxer.dump" | cut -f1)  -> auto-$ts"
else
	log "dump FAILED  - removing incomplete $dest"
	rm -rf "$dest"
	exit 1
fi

# 2. Uploads.
if docker run --rm -v fluxer_seaweedfs-data:/data:ro -v "$dest:/backup" alpine:3.22 \
	tar czf /backup/seaweedfs-data.tgz -C /data . >> "$LOG" 2>&1; then
	log "uploads ok   $(du -h "$dest/seaweedfs-data.tgz" | cut -f1)"
else
	log "uploads FAILED"
fi

# 3. Config and secrets - without .env the other two cannot be restored.
cp .env "$dest/.env"
chmod 600 "$dest/.env"
cp docker-compose.yml Caddyfile "$dest/" 2> /dev/null || true
cp -r ops "$dest/ops" 2> /dev/null || true

# 4. Retention.
find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'auto-*' -mtime +"$KEEP_DAYS" -exec rm -rf {} + 2> /dev/null || true
log "complete     $(du -sh "$dest" | cut -f1)  (keeping ${KEEP_DAYS}d)"
