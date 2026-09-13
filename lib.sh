# shellcheck shell=sh
# lib.sh - where things are. Sourced by every script here; not a command.
#
# Sets OPS (this directory, symlinks resolved), FLUXER_DIR and BACKUP_ROOT, so no
# script carries a path of its own and a host laid out differently needs no edits.
#
# FLUXER_DIR, first match wins:
#   1. FLUXER_DIR from the environment (cron lines written by setup.sh set it)
#   2. the directory above ops/, if it holds docker-compose.yml: the usual layout
#   3. the one Fluxer project `docker compose ls` knows about
# Otherwise it is empty, and need_instance says where it looked and how to fix it.
# Two Fluxer projects are never guessed between.
#
# BACKUP_ROOT: from the environment, else fluxer-backups next to the instance.

OPS=$(dirname "$(readlink -f "${OPS_SELF:-$0}")")

# Directories of compose projects whose .env names a FLUXER_DOMAIN, one per line.
# Silent without docker, or without permission to talk to it. No python: get.sh
# runs the same pipeline before anything but git is known to be installed.
fluxer_projects() {
	command -v docker > /dev/null 2>&1 || return 0
	docker compose ls --all --format json 2> /dev/null \
		| grep -o '"ConfigFiles":"[^"]*"' \
		| sed 's/^"ConfigFiles":"//; s/[",].*//' \
		| while IFS= read -r f; do
			d=$(dirname "$f")
			if grep -q '^FLUXER_DOMAIN=' "$d/.env" 2> /dev/null; then printf '%s\n' "$d"; fi
		done | sort -u
}

if [ -z "${FLUXER_DIR:-}" ]; then
	if [ -f "$(dirname "$OPS")/docker-compose.yml" ]; then
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
	BACKUP_ROOT=${BACKUP_ROOT:-}
fi

need_instance() {
	[ -n "$FLUXER_DIR" ] && return 0
	cat >&2 <<EOF
No Fluxer instance found. Looked at:
  - FLUXER_DIR (not set)
  - $(dirname "$OPS") (no docker-compose.yml)
  - docker compose ls (no single Fluxer project)
Point at it:   FLUXER_DIR=/path/to/fluxer $(basename "${OPS_SELF:-$0}") ...
Or install:    $OPS/setup.sh
EOF
	exit 2
}
