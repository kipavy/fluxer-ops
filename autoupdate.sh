#!/bin/sh
# autoupdate.sh - run `fluxer update` on a schedule, but only when there is one.
#
# An update stops the stack (the installer's cold backup, then the recreate), so
# updating every night would cost a downtime every night for nothing. Each run
# first asks whether anything changed: the registry digest of every fluxer-*
# image against what runs here, and the stack files install.sh would refresh.
# Nothing new, which is most nights: nothing happens. Something new:
# changelog.sh --summary, then update.sh --yes (overlay off and back on, health
# checks), then the changelog goes to a channel (AUTOUPDATE_WEBHOOK_URL), in
# French, optionally headed by a short summary from a cheap model on OpenRouter
# (AUTOUPDATE_OPENROUTER_KEY), and a failure goes to notify.sh as well. After a failure, automatic updates PAUSE until `on` is
# run again: retrying every night on a broken stack helps nobody.
#
# Not followed automatically: a new major image tag (v1 -> v2). It is announced
# once in the channel; moving FLUXER_IMAGE_TAG stays a human decision.
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
DOCKER=${DOCKER:-docker}
REGISTRY=${REGISTRY:-python3 $OPS/registry.py}
INSTALL_DRY=${INSTALL_DRY:-sh install.sh --update --dry-run}
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
# The image whose tags say whether a new major exists. Every component is tagged together.
MAJOR_PROBE=ghcr.io/fluxerapp/fluxer-api
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

env_value() { sed -n "s/^$1=//p" "$FLUXER_DIR/.env" | head -n 1; }
stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$STATE"; printf '%s %s\n' "$(stamp)" "$*" >> "$STATE/log"; }
record() { mkdir -p "$STATE"; printf '%s %s\n' "$(stamp)" "$*" > "$STATE/last"; }
marker() { printf '%s/autoupdate.sh run' "$OPS"; }
cron_ours() { $CRONTAB -l 2> /dev/null | grep -F "$(marker)" || true; }
cron_others() { $CRONTAB -l 2> /dev/null | grep -vF "$(marker)" || true; }

live_version() {
	$CURL -sS -I --max-time 15 "https://$(env_value FLUXER_DOMAIN)/api/_health" 2> /dev/null \
		| sed -n 's/^[Xx]-[Ff]luxer-[Vv]ersion: *//p' | tr -d '\r' | grep . || echo unknown
}

# Post a message (stdin) to the changelog channel. Long messages are split under
# the 2000-character limit, closing and reopening a ``` block across the cut.
# Best effort: never fails its caller.
post() {
	[ -n "$AUTOUPDATE_WEBHOOK_URL" ] || { cat > /dev/null; return 0; }
	if [ -n "$POST" ]; then
		$POST || log "posting to the channel failed"
		return 0
	fi
	# The URL is a credential: through the environment, not argv (ps shows argv).
	WEBHOOK="$AUTOUPDATE_WEBHOOK_URL" python3 -c '
import json, os, sys, time, urllib.request
text, limit, chunks, cur, fence = sys.stdin.read(), 1900, [], "", False
for line in text.splitlines():
    line = line[:limit - 10]
    if len(cur) + len(line) + 5 > limit:
        chunks.append(cur + ("```" if fence else ""))
        cur = "```\n" if fence else ""
    cur += line + "\n"
    if line.startswith("```"):
        fence = not fence
chunks.append(cur)
if len(chunks) > 5:
    chunks = chunks[:5]
    chunks[-1] += ("```\n" if fence else "") + "(cut here: run `fluxer changelog` for the rest)"
for c in chunks:
    req = urllib.request.Request(os.environ["WEBHOOK"], json.dumps({"content": c}).encode(),
                                 {"Content-Type": "application/json", "User-Agent": "fluxer-ops"})
    urllib.request.urlopen(req, timeout=15).read()
    time.sleep(1)
' || log "posting to the channel failed"
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
body = {"model": os.environ["MODEL"], "max_tokens": 400, "temperature": 0.2,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": sys.stdin.read()[:20000]}]}
req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", json.dumps(body).encode(),
                             {"Content-Type": "application/json", "Authorization": "Bearer " + os.environ["KEY"],
                              "X-Title": "fluxer-ops autoupdate"})
text = json.load(urllib.request.urlopen(req, timeout=60))["choices"][0]["message"]["content"]
print("\n".join(l for l in text.strip().splitlines() if l.strip())[:1500])
' 2> /dev/null || log "AI summary skipped (OpenRouter call failed)"
}

# What counts as an update. Prints one reason per line.
# Returns 0 = an update is pending, 1 = nothing new, 2 = cannot tell (why on stderr).
detect() {
	_t=$(mktemp -d)
	_rc=1
	if ! (cd "$FLUXER_DIR" && $DOCKER compose ps -aq) > "$_t/ids" 2> "$_t/err" || [ ! -s "$_t/ids" ]; then
		echo "no containers to compare (docker compose ps: $(tail -n 1 "$_t/err"))" >&2
		rm -rf "$_t"; return 2
	fi
	# The image each container was created from, and the digests it was pulled as.
	xargs $DOCKER inspect --format '{{.Config.Image}} {{.Image}}' < "$_t/ids" | sort -u > "$_t/running"
	: > "$_t/fluxer"
	while read -r image id; do
		case "$image" in */fluxer-*) ;; *) continue ;; esac
		printf '%s %s\n' "$image" "$($DOCKER image inspect --format '{{join .RepoDigests ","}}' "$id")" >> "$_t/fluxer"
	done < "$_t/running"
	platform=$($DOCKER version --format '{{.Server.Os}}/{{.Server.Arch}}' 2> /dev/null || echo linux/amd64)
	# shellcheck disable=SC2046 # one argument per image reference, none has spaces
	$REGISTRY manifests "$platform" $(awk '{ print $1 }' "$_t/fluxer") > "$_t/remote" 2> "$_t/err" || true
	while read -r image digests; do
		read -r _ rver _ rdigest status <<-EOF
		$(awk -v r="$image" '$1 == r' "$_t/remote")
		EOF
		comp=${image##*/}
		if [ "${status:-}" != ok ]; then
			echo "registry, $comp: ${status:-no answer} $(tail -n 1 "$_t/err")" >&2
			_rc=2
		elif ! printf '%s' "$digests" | tr ',' '\n' | grep -q "@$rdigest\$"; then
			echo "new image: ${comp%:*} ${rver:-}"
			[ "$_rc" -eq 2 ] || _rc=0
		fi
	done < "$_t/fluxer"

	# The stack files, as install.sh itself lists them. A change to .env.example
	# alone (a new optional setting) is not worth a downtime; it rides along with
	# the next real update.
	if ! (cd "$FLUXER_DIR" && $INSTALL_DRY) > "$_t/dry" 2>&1; then
		echo "install.sh --update --dry-run failed: $(tail -n 1 "$_t/dry")" >&2
		rm -rf "$_t"; return 2
	fi
	awk '$1 != "file" && NF == 2 && $2 == "changes" { print "changed", $1 }
		NF == 3 && $2 == "is" && $3 == "unchanged" { print "same", $1 }' "$_t/dry" > "$_t/files"
	if [ ! -s "$_t/files" ]; then
		echo "could not read install.sh's list of stack files (its dry-run output changed?)" >&2
		rm -rf "$_t"; return 2
	fi
	while read -r what f; do
		[ "$what" = changed ] && [ "$f" != .env.example ] || continue
		echo "stack file changed upstream: $f"
		[ "$_rc" -eq 2 ] || _rc=0
	done < "$_t/files"
	rm -rf "$_t"
	return "$_rc"
}

# A new major tag is announced once and never followed.
check_major() {
	tag=$(env_value FLUXER_IMAGE_TAG)
	n=${tag:-v1}; n=${n#v}
	case "$n" in '' | *[!0-9]*) return 0 ;; esac
	next="v$((n + 1))"
	[ -e "$STATE/announced-$next" ] && return 0
	if $REGISTRY tags "$MAJOR_PROBE" 2> /dev/null | grep -qx "$next"; then
		printf '%s\n' "**Nouvelle version majeure : $next** (cette instance suit ${tag:-v1})." \
			"Pas appliquée automatiquement : une version majeure peut demander des étapes manuelles." \
			"Lire les notes upstream, puis : \`fluxer env set FLUXER_IMAGE_TAG $next && fluxer update\`" | post
		log "announced the new major tag $next"
		mkdir -p "$STATE"; : > "$STATE/announced-$next"
	fi
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
    a few minutes of DOWNTIME (the installer's backup, then the recreate).
  - Upstream publishes no release notes: what gets applied is not reviewed
    first. The changelog is posted to the channel afterwards, not before.
  - There is no automatic rollback. A failed update leaves the instance as
    update.sh left it, pauses automatic updates, and alerts. You roll back
    by hand (fluxer rollback).
  - A new major tag (v1 -> v2) is announced, never applied.
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

	[ "$dry" -eq 1 ] || check_major

	rc=0
	reasons=$(detect 2> "$STATE/detect.err") || rc=$?
	if [ "$rc" -eq 2 ]; then
		msg="could not check for updates: $(tr '\n' ' ' < "$STATE/detect.err")"
		log "$msg"
		[ "$dry" -eq 1 ] && { echo "$msg" >&2; return 1; }
		$NOTIFY alert autoupdate "$msg" || true
		record "could not check"
		return 1
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
	domain=$(env_value FLUXER_DOMAIN)

	if [ "$urc" -eq 0 ]; then
		after=$(live_version)
		ai_summary < "$t/changelog" > "$t/ai"
		images=$(printf '%s\n' "$reasons" | grep -c '^new image' || true)
		files=$(printf '%s\n' "$reasons" | sed -n 's/^stack file changed upstream: //p' | tr '\n' ' ')
		{
			printf '**Fluxer mis à jour** sur %s : %s → %s\n' "$domain" "$before" "$after"
			trigger=''
			[ "$images" -eq 0 ] || trigger="$images nouvelle(s) image(s)"
			[ -z "$files" ] || trigger="${trigger:+$trigger, }modifié : ${files% }"
			printf '_Déclencheur : %s_\n\n' "$trigger"
			if [ -s "$t/ai" ]; then printf '**En bref**\n'; cat "$t/ai"; printf '\n'; fi
			cat "$t/changelog"
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
