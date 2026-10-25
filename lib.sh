# shellcheck shell=sh
# lib.sh - where things are, and how to reach them. Sourced by every script here; not a
# command.
#
# Sets OPS (this directory, symlinks resolved), FLUXER_DIR and BACKUP_ROOT, so no
# script carries a path of its own and a host laid out differently needs no edits.
#
# FLUXER_DIR, first match wins:
#   1. FLUXER_DIR from the environment (cron lines written by setup.sh set it)
#   2. the directory above ops/, if it holds .rexctl/state.json or docker-compose.yml:
#      the usual layout
#   3. the one Fluxer project `docker compose ls` knows about
# Otherwise it is empty, and need_instance says where it looked and how to fix it.
# Two Fluxer projects are never guessed between.
#
# BACKUP_ROOT: from the environment, else fluxer-backups next to the instance. Empty
# iff FLUXER_DIR is empty: an inherited BACKUP_ROOT with no instance behind it is only
# a trap (every consumer calls need_instance first), so it is dropped, not kept.

OPS=$(dirname "$(readlink -f "${OPS_SELF:-$0}")")

# Directories of compose projects that are Fluxer instances, one per line: rexctl's
# .rexctl/state.json, or an old-installer .env naming a FLUXER_DOMAIN. Silent without
# docker, or without permission to talk to it. No python: get.sh runs the same pipeline
# before anything but git is known to be installed.
fluxer_projects() {
	command -v docker > /dev/null 2>&1 || return 0
	docker compose ls --all --format json 2> /dev/null \
		| grep -o '"ConfigFiles":"[^"]*"' \
		| sed 's/^"ConfigFiles":"//; s/[",].*//' \
		| while IFS= read -r f; do
			d=$(dirname "$f")
			if [ -f "$d/.rexctl/state.json" ] || grep -q '^FLUXER_DOMAIN=' "$d/.env" 2> /dev/null; then
				printf '%s\n' "$d"
			fi
		done | sort -u
}

if [ -z "${FLUXER_DIR:-}" ]; then
	if [ -f "$(dirname "$OPS")/.rexctl/state.json" ] || [ -f "$(dirname "$OPS")/docker-compose.yml" ]; then
		FLUXER_DIR=$(dirname "$OPS")
	else
		_found=$(fluxer_projects)
		if [ -n "$_found" ] && [ "$(printf '%s\n' "$_found" | grep -c .)" -eq 1 ]; then
			FLUXER_DIR=$_found
		else
			FLUXER_DIR=''
		fi
		unset _found
	fi
fi
if [ -n "$FLUXER_DIR" ]; then
	BACKUP_ROOT=${BACKUP_ROOT:-$(dirname "$FLUXER_DIR")/fluxer-backups}
else
	BACKUP_ROOT=''
fi

need_instance() {
	[ -n "$FLUXER_DIR" ] && return 0
	cat >&2 <<EOF
No Fluxer instance found. Looked at:
  - FLUXER_DIR (not set)
  - $(dirname "$OPS") (no .rexctl/state.json, no docker-compose.yml)
  - docker compose ls (no single Fluxer project)
Point at it:   FLUXER_DIR=/path/to/fluxer $(basename "${OPS_SELF:-$0}") ...
Or install:    $OPS/setup.sh
EOF
	exit 2
}

# --- reaching the instance -----------------------------------------------------------
# Upstream's rexctl installs, upgrades and configures Fluxer. Once it manages the
# instance (.rexctl/state.json, after `rexctl install` or `rexctl takeover`), .env is
# gone (settings and secrets live in .rexctl/state.json) and the rendered
# docker-compose.yml refuses a plain `docker compose up`. So scripts never read .env or
# load the compose files themselves; they go through these:
#
#   fx_managed            true when rexctl manages the instance
#   rexctl ...            rexctl on this instance (--dir and --yes filled in)
#   compose ...           docker compose on the running project, by name: ps, exec,
#                         logs, restart, stop, start. Never up/config/down/pull.
#   fx_env KEY            one setting (FLUXER_DOMAIN, POSTGRES_PASSWORD...), secrets too
#   fx_env_set K=V ...    change settings; recreates whatever reads them
#   fx_domain             the instance's domain
#   fx_apply              bring the containers in line with the files (compose up -d)
#   fx_services           the services of the project, one per line
#   fx_image SERVICE      the image SERVICE's container was created from
#   fx_custom_compose     the compose file of our own that the stack also loads
#
# On an instance the old installer made (before `fluxer migrate`), they fall back to
# .env and docker compose in FLUXER_DIR, so everything keeps working until then.

fx_managed() { [ -n "${FLUXER_DIR:-}" ] && [ -f "$FLUXER_DIR/.rexctl/state.json" ]; }

# Who owns the instance: rexctl must run as them (it refuses otherwise, and as root it
# would leave root-owned files in .rexctl/). The watchdog runs from root's cron.
fx_owner() { stat -c %U "$FLUXER_DIR/.rexctl/state.json" 2> /dev/null || id -un; }
fx_owner_home() { getent passwd "$(fx_owner)" | cut -d: -f6; }

# rexctl's installer puts it in ~/.local/bin (/usr/local/bin as root), which cron's PATH
# lacks: look there too, and in the owner's home when running as someone else.
fx_rexctl_bin() {
	if [ -n "${REXCTL:-}" ]; then
		printf '%s\n' "$REXCTL"
		return 0
	fi
	for _b in "$(command -v rexctl 2> /dev/null || true)" "$HOME/.local/bin/rexctl" \
		"$(fx_owner_home 2> /dev/null)/.local/bin/rexctl" /usr/local/bin/rexctl; do
		if [ -n "$_b" ] && [ -x "$_b" ]; then
			printf '%s\n' "$_b"
			return 0
		fi
	done
	return 1
}

rexctl() {
	_rx=$(fx_rexctl_bin) || {
		echo "rexctl is not installed. Install it with: fluxer migrate" >&2
		return 127
	}
	_ow=$(fx_owner)
	if [ "$(id -u)" -eq 0 ] && [ "$_ow" != root ]; then
		runuser -u "$_ow" -- env HOME="$(fx_owner_home)" "$_rx" --dir "$FLUXER_DIR" --yes "$@"
	else
		"$_rx" --dir "$FLUXER_DIR" --yes "$@"
	fi
}

# The compose project. rexctl keeps the old name when it takes an instance over.
fx_project() {
	if [ -z "${FX_PROJECT:-}" ]; then
		if fx_managed; then
			FX_PROJECT=$(grep -o '"project": *"[^"]*"' "$FLUXER_DIR/.rexctl/state.json" \
				| head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')
		fi
		[ -n "${FX_PROJECT:-}" ] || FX_PROJECT=$(basename "$FLUXER_DIR")
	fi
	printf '%s\n' "$FX_PROJECT"
}

# By project name and from /, so compose never loads the rendered files: they refuse to
# load outside rexctl. ps, exec, logs, restart, stop and start need only the name.
compose() {
	need_instance
	if fx_managed; then
		(cd / && docker compose -p "$(fx_project)" "$@")
	else
		(cd "$FLUXER_DIR" && docker compose "$@")
	fi
}

fx_env() {
	if fx_managed; then
		rexctl -q config get "$1" --reveal 2> /dev/null | tr -d '\r'
	else
		sed -n "s/^$1=//p" "$FLUXER_DIR/.env" 2> /dev/null | head -n 1 | tr -d '\r"' | sed "s/'//g"
	fi
}

fx_domain() {
	if [ -z "${FX_DOMAIN:-}" ]; then
		FX_DOMAIN=$(fx_env FLUXER_DOMAIN)
		if [ -z "$FX_DOMAIN" ] && fx_managed; then
			FX_DOMAIN=$(fx_env domain)
		fi
	fi
	printf '%s\n' "$FX_DOMAIN"
}

fx_env_set() {
	if fx_managed; then
		rexctl config set "$@"
	else
		for _kv in "$@"; do
			"$OPS/env.sh" set "${_kv%%=*}" "${_kv#*=}" || return
		done
		(cd "$FLUXER_DIR" && docker compose up -d)
	fi
}

fx_apply() {
	if fx_managed; then
		rexctl start
	else
		(cd "$FLUXER_DIR" && docker compose up -d "$@")
	fi
}

fx_services() {
	if fx_managed; then
		compose ps -a --format '{{.Service}}' 2> /dev/null | sort -u
	else
		compose config --services 2> /dev/null
	fi
}

fx_image() {
	_cid=$(compose ps -aq "$1" 2> /dev/null | head -n 1)
	[ -n "$_cid" ] || return 1
	docker inspect -f '{{.Config.Image}}' "$_cid"
}

# rexctl loads custom.compose.yml after its own files; the old installer's compose
# loaded docker-compose.override.yml. Either way it is the one place for our mounts.
fx_custom_compose() {
	if fx_managed; then
		printf '%s\n' "$FLUXER_DIR/custom.compose.yml"
	else
		printf '%s\n' "$FLUXER_DIR/docker-compose.override.yml"
	fi
}

# For what only rexctl does now: update, rollback, config.
need_rexctl() {
	need_instance
	fx_managed && return 0
	cat >&2 <<EOF
rexctl does not manage $FLUXER_DIR yet. Upstream replaced the old installer with
rexctl, so updates go through it. Hand the instance over (Fluxer keeps running):
  fluxer migrate
EOF
	exit 2
}
