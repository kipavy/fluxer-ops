#!/bin/sh
# Runs from ROOT cron every 10 minutes.
#
# It fixes the two failure modes that have actually taken this instance down:
#   1. firewalld reloads flush Docker's iptables chains. Every published port
#      then fails to bind and the whole stack dies silently. This is what kept
#      the instance down for two weeks in Sept 2026 with nobody noticing.
#   2. The stack simply not being up afterwards.
set -eu

FLUXER_DIR=${FLUXER_DIR:-/home/ubuntu/Documents/fluxer}
LOG=${LOG:-/var/log/fluxer-watchdog.log}

log() { printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG"; }

# Keep the log bounded without needing logrotate.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 5242880 ]; then
	tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# 1. Docker's nat chain.
if ! iptables -t nat -L -n 2>/dev/null | grep -q '^Chain DOCKER'; then
	log "DOCKER nat chain MISSING (firewalld flush) - restarting docker"
	if systemctl restart docker; then
		log "docker restarted"
	else
		log "docker restart FAILED"
	fi
	sleep 15
fi

# 2. Is the whole stack up?
cd "$FLUXER_DIR"
expected=$(docker compose config --services 2>/dev/null | grep -vc '^seaweedfs-init$' || echo 0)
running=$(docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -c . || true)
if [ "${expected:-0}" -gt 0 ] && [ "${running:-0}" -lt "${expected:-0}" ]; then
	log "only ${running:-0}/${expected} services running - bringing the stack up"
	if docker compose up -d > "$LOG.compose" 2>&1; then
		log "compose up -d done (output in $LOG.compose)"
	else
		log "compose up -d FAILED - see $LOG.compose"
	fi
	sleep 30
fi

# 3. Is it actually serving? Logged only - do not restart on a transient blip.
if ! "$FLUXER_DIR/ops/check.sh" --quiet > /dev/null 2>&1; then
	log "health check FAILING - run $FLUXER_DIR/ops/check.sh to see why"
fi
