#!/bin/sh
# autoupdate.sh - run `fluxer update` on a schedule, but only when there is one.
#
# An update costs a downtime (rexctl's backup, then the recreate), so updating every
# night would cost one every night for nothing. Each run first asks rexctl whether a
# newer release exists (rexctl upgrade --check). Nothing new, which is most nights:
# nothing happens. Something new:
# changelog.sh --summary, then update.sh --yes (overlay off and back on, health
# checks), then the changelog goes to a channel (AUTOUPDATE_WEBHOOK_URL), in
# French, as one short message: versions, a summary from a cheap model on
# OpenRouter if AUTOUPDATE_OPENROUTER_KEY is set (else the heads-up section),
# and a link to the full upstream compare. A failure, a check that cannot run
# and a new major tag are posted too, and failures go to notify.sh as well. After a failure, automatic updates PAUSE until `on` is
# run again: retrying every night on a broken stack helps nobody.
#
# A release rexctl cannot reach directly (it reports it blocked: one in between is
# needed first) is reported as a check failure, never forced.
#
# cron fires every hour at the chosen minute and the run goes on only when the
# hour in --tz matches, so a DST change needs no crontab edit. The host clock is
# UTC: 05:00 in Paris is 03:00 UTC in summer, the hour backup.sh runs, so a run
# waits (up to 30 min) for a backup in progress.
#
#   autoupdate.sh on [--at HH:MM] [--tz ZONE] [--yes]   enable (default 05:00 Europe/Paris)
#   autoupdate.sh off                                   disable
#   autoupdate.sh status                                schedule, pause, last result, log
#   autoupdate.sh run [--dry-run]                       check now, update if needed
#
# Config: AUTOUPDATE_WEBHOOK_URL, and optionally AUTOUPDATE_OPENROUTER_KEY and
# AUTOUPDATE_AI_MODEL, in notify.conf (see notify.conf.example) or the environment. State and log: ~/.local/state/fluxer-autoupdate.
set -eu

. "$(dirname "$(readlink -f "${OPS_SELF:-$0}")")/lib.sh"

# Every outside command is a variable, so tests run against stubs.
STATE=${AUTOUPDATE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/fluxer-autoupdate}
CRONTAB=${CRONTAB:-crontab}
# rexctl's answer, as JSON: {"current", "latest", "available", "blocked", "min_from"...}
UPGRADE_CHECK=${UPGRADE_CHECK:-}
UPDATE=${UPDATE:-$OPS/update.sh}
CHANGELOG=${CHANGELOG:-$OPS/changelog.sh}
NOTIFY=${NOTIFY:-$OPS/notify.sh}
POST=${POST:-}
AI=${AI:-}
CURL=${CURL:-curl}
ZONEINFO=${ZONEINFO:-/usr/share/zoneinfo}
SUDO_CHECK=${SUDO_CHECK:-sudo -n true}
PGREP=${PGREP:-pgrep}
SLEEP=${SLEEP:-sleep}
NOTIFY_CONF=${NOTIFY_CONF:-$OPS/notify.conf}
WAIT_BACKUP=1800

conf_value() { # KEY from notify.conf, quotes stripped
	[ -f "$NOTIFY_CONF" ] || return 0
	sed -n "s/^$1=//p" "$NOTIFY_CONF" | tail -n 1 | sed "s/^['\"]//; s/['\"]\$//"
}
AUTOUPDATE_WEBHOOK_URL=${AUTOUPDATE_WEBHOOK_URL-$(conf_value AUTOUPDATE_WEBHOOK_URL)}
AUTOUPDATE_OPENROUTER_KEY=${AUTOUPDATE_OPENROUTER_KEY-$(conf_value AUTOUPDATE_OPENROUTER_KEY)}
AUTOUPDATE_AI_MODEL=${AUTOUPDATE_AI_MODEL:-$(conf_value AUTOUPDATE_AI_MODEL)}
# Cheap and good at French: about $0.0005 per update at OpenRouter's prices (2026-10).
AUTOUPDATE_AI_MODEL=${AUTOUPDATE_AI_MODEL:-anthropic/claude-haiku-5.5}

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$STATE"; printf '%s %s\n' "$(stamp)" "$*" >> "$STATE/log"; }
record() { mkdir -p "$STATE"; printf '%s %s\n' "$(stamp)" "$*" > "$STATE/last"; }
marker() { printf '%s/autoupdate.sh run' "$OPS"; }
cron_ours() { $CRONTAB -l 2> /dev/null | grep -F "$(marker)" || true; }
cron_others() { $CRONTAB -l 2> /dev/null | grep -vF "$(marker)" || true; }

live_version() {
	$CURL -sS -I --max-time 15 "https://$(fx_domain)/api/_health" 2> /dev/null \
		| sed -n 's/^[Xx]-[Ff]luxer-[Vv]ersion: *//p' | tr -d '\r' | grep . || echo unknown
}

# Post a message (stdin) to the changelog channel (webhook_post.py; split only
# past the size limit). Best effort: never fails its caller. Message ids go to
# $STATE/posted, so a post can be found again to edit or delete.
post() {
	[ -n "$AUTOUPDATE_WEBHOOK_URL" ] || { cat > /dev/null; return 0; }
	if [ -n "$POST" ]; then
		$POST || log "posting to the channel failed"
		return 0
	fi
	mkdir -p "$STATE"
	ids=$(WEBHOOK="$AUTOUPDATE_WEBHOOK_URL" python3 "$OPS/webhook_post.py" 2>> "$STATE/log") \
		|| log "posting to the channel failed"
	[ -z "${ids:-}" ] || printf '%s\n' "$ids" | sed "s/^/$(stamp) /" >> "$STATE/posted"
}

# A few French bullets from the changelog (stdin), or nothing. Optional and best
# effort: no key, a timeout or any error just leaves the summary out.
ai_summary() {
	[ -n "$AUTOUPDATE_OPENROUTER_KEY" ] || { cat > /dev/null; return 0; }
	if [ -n "$AI" ]; then $AI 2> /dev/null || true; return 0; fi
	KEY="$AUTOUPDATE_OPENROUTER_KEY" MODEL="$AUTOUPDATE_AI_MODEL" python3 -c '
import json, os, sys, urllib.request
system = ("Tu résumes une mise à jour de Fluxer (messagerie type Discord) pour une petite "
          "instance auto-hébergée. À partir du changelog fourni, écris 3 à 5 puces courtes en "
          "français sur ce qui change concrètement pour ses membres et son admin. Ignore ce qui "
          "ne concerne que l\u2019app desktop, la CI ou l\u2019instance officielle hébergée. N\u2019invente rien "
          "qui ne soit pas dans le changelog. Pas de titre ni d\u2019introduction : seulement des "
          "lignes commençant par « - ».")
# Reasoning off: left on, it spends the whole token budget thinking on a long
# changelog and the answer comes back empty (seen with claude-haiku-5.5).
body = {"model": os.environ["MODEL"], "max_tokens": 800, "temperature": 0.2,
        "reasoning": {"enabled": False},
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": sys.stdin.read()[:20000]}]}
req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", json.dumps(body).encode(),
                             {"Content-Type": "application/json", "Authorization": "Bearer " + os.environ["KEY"],
                              "X-Title": "fluxer-ops autoupdate"})
text = json.load(urllib.request.urlopen(req, timeout=60))["choices"][0]["message"].get("content") or ""
lines = [l for l in text.strip().splitlines() if l.strip().startswith(("-", "*", "•"))]
if not lines:
    sys.exit(1)
print("\n".join(lines)[:1500])
' 2> /dev/null || log "AI summary skipped (OpenRouter call failed)"
}

# What counts as an update: a newer release than the one running, as rexctl sees it.
# Prints one reason per line.
# Returns 0 = an update is pending, 1 = nothing new, 2 = cannot tell (why on stderr).
detect() {
	if [ -z "$UPGRADE_CHECK" ] && ! fx_managed; then
		echo "rexctl does not manage $FLUXER_DIR yet (upstream retired the old installer): run fluxer migrate" >&2
		return 2
	fi
	_t=$(mktemp -d)
	_crc=0
	if [ -n "$UPGRADE_CHECK" ]; then
		$UPGRADE_CHECK > "$_t/check" 2> "$_t/err" || _crc=$?
	else
		rexctl -q upgrade --check --json > "$_t/check" 2> "$_t/err" || _crc=$?
	fi
	if [ "$_crc" -ne 0 ] || [ ! -s "$_t/check" ]; then
		echo "rexctl upgrade --check failed: $(tail -n 1 "$_t/err")" >&2
		rm -rf "$_t"; return 2
	fi
	_rc=0
	python3 - "$_t/check" <<'PY' || _rc=$?
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except ValueError as e:
    print(f"rexctl upgrade --check said something that is not JSON ({e})", file=sys.stderr)
    sys.exit(2)
cur, new = d.get("current") or "?", d.get("latest") or "?"
if not d.get("available"):
    sys.exit(1)
if d.get("blocked"):
    need = f" (it needs {d['min_from']} or newer first)" if d.get("min_from") else ""
    print(f"release {new} is out but rexctl cannot upgrade {cur} to it directly{need}", file=sys.stderr)
    sys.exit(2)
print(f"new release: {cur} -> {new}")
PY
	rm -rf "$_t"
	return "$_rc"
}

cmd_on() {
	at=05:00 tz=Europe/Paris yes=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--at) [ $# -ge 2 ] || { echo "--at needs HH:MM" >&2; return 2; }; at=$2; shift 2 ;;
			--tz) [ $# -ge 2 ] || { echo "--tz needs a zone" >&2; return 2; }; tz=$2; shift 2 ;;
			--yes | -y) yes=1; shift ;;
			*) echo "usage: autoupdate.sh on [--at HH:MM] [--tz ZONE] [--yes]" >&2; return 2 ;;
		esac
	done
	printf '%s' "$at" | grep -Eqx '([01][0-9]|2[0-3]):[0-5][0-9]' \
		|| { echo "bad time: $at (HH:MM, 24h)" >&2; return 2; }
	[ -f "$ZONEINFO/$tz" ] || { echo "unknown time zone: $tz (e.g. Europe/Paris, UTC)" >&2; return 2; }
	# update.sh runs sudo (iptables preflight, docker restart). cron cannot type a password.
	if ! $SUDO_CHECK > /dev/null 2>&1; then
		echo "This user has no passwordless sudo, which update.sh needs (iptables preflight)." >&2
		echo "An unattended update would stop at the first sudo. Nothing changed." >&2
		return 1
	fi

	cat <<EOF
WARNING: automatic updates apply upstream changes with nobody watching.

  - Every night at $at ($tz) this checks for a new release. Most nights there is
    none and nothing happens. When there is one, it is applied right away:
    a few minutes of DOWNTIME (rexctl's backup, then the recreate).
  - Upstream publishes no release notes: what gets applied is not reviewed
    first. The changelog is posted to the channel afterwards, not before.
  - There is no automatic rollback. A failed update leaves the instance as
    update.sh left it, pauses automatic updates, and alerts. You roll back
    by hand (fluxer rollback).
  - A release rexctl cannot reach in one step is reported, never forced.
EOF
	if [ -z "$AUTOUPDATE_WEBHOOK_URL" ]; then
		printf '\nNote: AUTOUPDATE_WEBHOOK_URL is not set (notify.conf), so no changelog will be posted.\n'
	elif [ -n "$AUTOUPDATE_OPENROUTER_KEY" ]; then
		printf '\nEach changelog gets a short summary from %s on OpenRouter (the commit list is sent there).\n' "$AUTOUPDATE_AI_MODEL"
	fi
	printf '  Failures also go to your fluxer notify channels: check them with fluxer notify status.\n'

	if [ "$yes" -eq 0 ]; then
		printf '\nEnable automatic updates? [y/N] '
		read -r reply || { printf '\nNo answer (no terminal). Use --yes to confirm non-interactively.\n' >&2; return 2; }
		case "$reply" in
			y | Y | yes | YES) ;;
			*) echo "Nothing changed."; return 0 ;;
		esac
	fi

	# 05:08 -> 8 (no expr: it exits 1 when the result is 0, which set -e takes for a failure)
	min=${at#*:}; min=${min#0}
	{ cron_others; printf '%s * * * * FLUXER_DIR=%s %s --at %s --tz %s >/dev/null 2>&1\n' \
		"$min" "$FLUXER_DIR" "$(marker)" "$at" "$tz"; } | $CRONTAB -
	rm -f "$STATE/paused"
	log "enabled: daily at $at $tz"
	echo "Automatic updates on: daily at $at ($tz). Check with: fluxer autoupdate status"
}

cmd_off() {
	cron_others | $CRONTAB -
	log "disabled"
	echo "Automatic updates off."
}

cmd_status() {
	line=$(cron_ours)
	if [ -n "$line" ]; then
		printf 'schedule   daily at %s (%s)\n' \
			"$(printf '%s' "$line" | sed -n 's/.*--at \([0-9:]*\).*/\1/p')" \
			"$(printf '%s' "$line" | sed -n 's/.*--tz \([^ ]*\).*/\1/p')"
	else
		printf 'schedule   off (enable: fluxer autoupdate on)\n'
	fi
	[ -e "$STATE/paused" ] && printf 'PAUSED     after a failed update (%s). Resume: fluxer autoupdate on\n' "$(cat "$STATE/paused")"
	printf 'last run   %s\n' "$(cat "$STATE/last" 2> /dev/null || echo never)"
	if [ -n "$AUTOUPDATE_WEBHOOK_URL" ]; then printf 'channel    configured\n'
	else printf 'channel    not configured (AUTOUPDATE_WEBHOOK_URL in notify.conf)\n'; fi
	if [ -n "$AUTOUPDATE_OPENROUTER_KEY" ]; then printf 'summary    %s on OpenRouter\n' "$AUTOUPDATE_AI_MODEL"
	else printf 'summary    off (AUTOUPDATE_OPENROUTER_KEY in notify.conf)\n'; fi
	if [ -s "$STATE/log" ]; then printf '\nlog (%s):\n' "$STATE/log"; tail -n 8 "$STATE/log" | sed 's/^/  /'; fi
}

cmd_run() {
	at='' tz=Europe/Paris dry=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--at) at=${2:-}; shift 2 ;;
			--tz) tz=${2:-}; shift 2 ;;
			--dry-run) dry=1; shift ;;
			*) echo "usage: autoupdate.sh run [--dry-run]" >&2; return 2 ;;
		esac
	done
	# From cron: hourly, so only the hour asked for, in its own zone.
	if [ -n "$at" ]; then
		[ "${DATE_HOUR:-$(TZ="$tz" date +%H)}" = "${at%%:*}" ] || return 0
	fi
	mkdir -p "$STATE"
	if [ -e "$STATE/paused" ] && [ "$dry" -eq 0 ]; then
		log "skipped: paused since a failed update (resume: fluxer autoupdate on)"
		return 0
	fi
	exec 9> "$STATE/lock"
	flock -n 9 || { log "skipped: another run holds the lock"; return 0; }

	waited=0
	while $PGREP -f "$OPS/backup.sh" > /dev/null 2>&1; do
		if [ "$waited" -ge "$WAIT_BACKUP" ]; then
			log "skipped: backup.sh still running after $((WAIT_BACKUP / 60)) min"
			return 1
		fi
		$SLEEP 30
		waited=$((waited + 30))
	done

	rc=0
	reasons=$(detect 2> "$STATE/detect.err") || rc=$?
	if [ "$rc" -eq 2 ]; then
		msg="could not check for updates: $(tr '\n' ' ' < "$STATE/detect.err")"
		log "$msg"
		[ "$dry" -eq 1 ] && { echo "$msg" >&2; return 1; }
		$NOTIFY alert autoupdate "$msg" || true
		# Once when it starts failing, not every night it stays broken.
		if [ ! -e "$STATE/check-failing" ]; then
			printf '%s\n' "$msg" > "$STATE/check-failing"
			printf '**⚠️ Vérification des mises à jour impossible** sur %s\n%s\n%s\n' \
				"$(fx_domain)" "\`$(tr '\n' ' ' < "$STATE/detect.err")\`" \
				"Aucune mise à jour appliquée. Nouvel essai chaque nuit, sans nouveau message jusqu'au retour à la normale." | post
		fi
		record "could not check"
		return 1
	fi
	if [ "$dry" -eq 0 ] && [ -e "$STATE/check-failing" ]; then
		rm -f "$STATE/check-failing"
		printf '✅ Vérification des mises à jour rétablie sur %s.\n' "$(fx_domain)" | post
	fi
	if [ "$rc" -eq 1 ]; then
		[ "$dry" -eq 1 ] && { echo "Nothing new: no update to apply."; return 0; }
		log "up to date"
		record "up to date"
		$NOTIFY ok autoupdate || true
		return 0
	fi
	if [ "$dry" -eq 1 ]; then
		printf 'An update is pending; a real run would apply it:\n%s\n' "$reasons" | sed '2,$s/^/  /'
		return 0
	fi

	log "update pending: $(printf '%s' "$reasons" | tr '\n' ';')"
	t=$(mktemp -d)
	before=$(live_version)
	timeout 600 $CHANGELOG --summary > "$t/changelog" 2> "$t/changelog.err" \
		|| echo "_(changelog indisponible : voir fluxer changelog)_" >> "$t/changelog"
	urc=0
	$UPDATE --yes > "$t/update.log" 2>&1 || urc=$?
	sed 's/^/    /' "$t/update.log" >> "$STATE/log"
	domain=$(fx_domain)

	if [ "$urc" -eq 0 ]; then
		after=$(live_version)
		ai_summary < "$t/changelog" > "$t/ai"
		release=$(printf '%s\n' "$reasons" | sed -n 's/^new release: //p' | head -n 1)
		{
			printf '**Fluxer mis à jour** sur %s : %s → %s\n' "$domain" "$before" "$after"
			[ -z "$release" ] || printf '_Release %s_\n' "$release"
			printf '\n'
			# The summary, or without one the heads-up section (breaking changes,
			# reverts, removals); the full list is one click away, upstream.
			if [ -s "$t/ai" ]; then
				printf '**En bref**\n'; cat "$t/ai"; printf '\n'
			else
				awk '/^\*\*⚠️ À noter/ { f = 1 } f && /^$/ { exit } f' "$t/changelog"
				printf '\n'
			fi
			link=$(sed -n 's/^Tout voir : <\(.*\)>$/\1/p' "$t/changelog" | head -n 1)
			if [ -n "$link" ]; then printf 'Changelog détaillé : <%s>\n' "$link"
			else printf 'Changelog détaillé : `fluxer changelog`\n'; fi
		} | post
		log "updated: $before -> $after"
		record "updated ($before -> $after)"
		$NOTIFY ok autoupdate || true
		rm -rf "$t"
		return 0
	fi

	printf '%s update.sh exit %s\n' "$(stamp)" "$urc" > "$STATE/paused"
	{
		printf '**❌ Échec de la mise à jour automatique** sur %s (update.sh exit %s).\n' "$domain" "$urc"
		printf 'Mises à jour automatiques en pause. Pour reprendre : `fluxer autoupdate on`\n'
		printf 'Diagnostic : `fluxer check`, `fluxer autoupdate status`. Retour arrière : `fluxer rollback`\n'
		printf '```\n'; tail -n 25 "$t/update.log"; printf '```\n'
	} | post
	log "update FAILED (exit $urc); paused"
	record "FAILED (update.sh exit $urc), paused"
	$NOTIFY alert autoupdate "automatic update failed (update.sh exit $urc); automatic updates paused. See: fluxer autoupdate status" || true
	rm -rf "$t"
	return 1
}

# Tests source this file for its functions.
[ -n "${AUTOUPDATE_SOURCE_ONLY:-}" ] && return 0

need_instance
cmd=${1:-status}
[ $# -gt 0 ] && shift
case "$cmd" in
	on) cmd_on "$@" ;;
	off) cmd_off ;;
	status) cmd_status ;;
	run)
		rc=0
		cmd_run "$@" || rc=$?
		# The log is for humans: keep it bounded.
		if [ -f "$STATE/log" ] && [ "$(wc -l < "$STATE/log")" -gt 2000 ]; then
			tail -n 1000 "$STATE/log" > "$STATE/log.new" && mv "$STATE/log.new" "$STATE/log"
		fi
		exit "$rc"
		;;
	-h | --help | help) sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//' ;;
	*) echo "usage: autoupdate.sh on [--at HH:MM] [--tz ZONE] [--yes] | off | status | run [--dry-run]" >&2; exit 2 ;;
esac
