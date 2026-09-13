#!/bin/sh
# Runs from ROOT cron every 10 minutes.
#
# It fixes the two failure modes that have actually taken this instance down:
#   1. firewalld reloads flush Docker's iptables chains. Every published port
#      then fails to bind and the whole stack dies silently. This is what kept
#      the instance down for two weeks in Sept 2026 with nobody noticing.
#   2. The stack simply not being up afterwards.
#
# Repairing silently is how that outage went unnoticed, so every problem is also
# handed to notify.sh, which tells a human once per state change (and once more
# when it recovers). Without a notify.conf that is a no-op.
set -eu

FLUXER_DIR=${FLUXER_DIR:-/home/ubuntu/Documents/fluxer}
LOG=${LOG:-/var/log/fluxer-watchdog.log}
NOTIFY="$(cd "$(dirname "$0")" && pwd)/notify.sh"

log() { printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG"; }

# Alerting is best effort: a missing or failing notify.sh never stops a repair.
# Its complaints (a channel that did not deliver) land in our log.
notify() {
	if [ -x "$NOTIFY" ]; then
		out=$("$NOTIFY" "$@" 2>&1 > /dev/null) || true
		if [ -n "$out" ]; then log "$out"; fi
	fi
}

chain_ok() { iptables -t nat -L -n 2>/dev/null | grep -q '^Chain DOCKER'; }

# Keep the log bounded without needing logrotate.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 5242880 ]; then
	tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# 1. Docker's nat chain.
if ! chain_ok; then
	log "DOCKER nat chain MISSING (firewalld flush) - restarting docker"
	if systemctl restart docker; then
		log "docker restarted"
		restarted='docker was restarted'
	else
		log "docker restart FAILED"
		restarted='docker restart FAILED'
	fi
	sleep 15
	# Stays "failing" until a later run finds the chain in place, so a repair
	# that does not hold, or keeps being undone, is not reported as fixed.
	if chain_ok; then
		log "DOCKER nat chain restored"
		notify alert docker-chain "Docker's iptables nat chain was missing (a firewalld reload flushes it; every published port stops working). $restarted and the chain is back. Check the stack came back up."
	else
		log "DOCKER nat chain still MISSING"
		notify alert docker-chain "Docker's iptables nat chain is missing (a firewalld reload flushes it; every published port stops working). $restarted and the chain is STILL missing. Needs a human: sudo systemctl restart docker"
	fi
else
	notify ok docker-chain "Docker's iptables nat chain is present."
fi

# 2. Is the whole stack up?
cd "$FLUXER_DIR"
expected=$(docker compose config --services 2>/dev/null | grep -vc '^seaweedfs-init$' || echo 0)
running=$(docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -c . || true)
if [ "${expected:-0}" -gt 0 ] && [ "${running:-0}" -lt "${expected:-0}" ]; then
	log "only ${running:-0}/${expected} services running - bringing the stack up"
	if docker compose up -d > "$LOG.compose" 2>&1; then
		log "compose up -d done (output in $LOG.compose)"
		upped='ran docker compose up -d'
	else
		log "compose up -d FAILED - see $LOG.compose"
		upped="docker compose up -d FAILED (output in $LOG.compose)"
	fi
	sleep 30
	after=$(docker compose ps --status running --format '{{.Service}}' 2>/dev/null | grep -c . || true)
	notify alert stack-down "Only ${running:-0}/${expected} services were running; $upped. Now ${after:-0}/${expected} running."
elif [ "${expected:-0}" -gt 0 ]; then
	notify ok stack-down "All ${expected} services running."
fi

# 3. Is it actually serving? Do not restart on a transient blip, and do not page
#    on one either: a failure has to survive one retry before it is an alert.
if ! "$FLUXER_DIR/ops/check.sh" --quiet > /dev/null 2>&1; then
	log "health check FAILING - run $FLUXER_DIR/ops/check.sh to see why"
	sleep 30
	if errs=$("$FLUXER_DIR/ops/check.sh" --quiet 2>&1 > /dev/null); then
		log "health check passed on retry"
		notify ok health
	else
		why=$(printf '%s\n' "$errs" | grep -v '^[[:space:]]*$' | head -n 15 | cut -c 1-200)
		notify alert health "check.sh is failing (twice, 30s apart):
$why
Run $FLUXER_DIR/ops/check.sh for the full picture."
	fi
else
	notify ok health "check.sh passes again."
fi
