#!/bin/sh
# setup.sh - take this server from nothing, or from a running Fluxer, to an instance
# that is backed up, watched, and operable with `fluxer`.
#
#   setup.sh                  guided: prerequisites, instance, cron, optional extras
#   setup.sh --check          report what is missing, change nothing (exit 1 if any)
#   setup.sh --yes            no questions: take every default, skip the extras
#   setup.sh --no-extras      stop after the core wiring
#   setup.sh --fluxer-dir D   the instance directory (found on its own otherwise)
#   setup.sh --domain D --email E
#                             for a new instance, instead of being asked
#
# Safe to run again: every step looks before it acts, a finished step prints ✓ and
# does nothing, and existing crontab lines are never rewritten or removed.
#
# Every outside command is overridable, so tests/setup_test.sh can run all of this
# against stubs: DOCKER SUDO CRONTAB CRONTAB_ROOT SYSTEMCTL DMI_DIR PUBLIC_IP_URL
# CF_IPS_URL INSTALLER_URL DOCKER_INSTALL_URL BIN_DIR COMPLETION_DIR.
set -eu

SELF=$(readlink -f "${OPS_SELF:-$0}")
SELF_DIR=$(dirname "$SELF")

DOCKER=${DOCKER:-docker}
SUDO=${SUDO-sudo}
SYSTEMCTL=${SYSTEMCTL:-systemctl}
BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
COMPLETION_DIR=${COMPLETION_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions}

CHECK_ONLY=0 ASSUME_YES=0 EXTRAS=1 DOMAIN='' EMAIL='' ALLOW_ROOT=''
SUDO_OK=0 NEW_INSTANCE=0 MISSING=0 TMP=''

# --- output and questions -----------------------------------------------------

say() { printf '%s\n' "$*"; }
st_ok() { printf '  ✓ %s\n' "$*"; }
st_do() { printf '  → %s\n' "$*"; }
st_skip() { printf '  – %s\n' "$*"; }
st_bad() { printf '  ✗ %s\n' "$*"; }
die() {
	_code=$1
	shift
	printf '\n✗ %s\n' "$*" >&2
	exit "$_code"
}

# ask <question> <default y|n>: status 0 for yes. --yes answers with the default.
# A closed stdin is not an answer: guessing "yes" there could install things.
ask() {
	if [ "$ASSUME_YES" -eq 1 ]; then [ "$2" = y ]; return; fi
	case "$2" in y) _hint='[Y/n]' ;; *) _hint='[y/N]' ;; esac
	printf '  %s %s ' "$1" "$_hint"
	read -r _reply || die 2 "No answer (input closed). Run setup.sh from a terminal, or with --yes."
	case "${_reply:-$2}" in y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
}

# prompt <question> [default]: the answer on stdout. Used as $(prompt ...), so the
# question goes to stderr.
prompt() {
	if [ "$ASSUME_YES" -eq 1 ]; then printf '%s' "${2:-}"; return 0; fi
	printf '  %s%s: ' "$1" "${2:+ [$2]}" >&2
	read -r _reply || die 2 "No answer (input closed). Run setup.sh from a terminal, or with --yes."
	printf '%s' "${_reply:-${2:-}}"
}

# prompt_secret <question>: like prompt, without echoing what is typed.
prompt_secret() {
	printf '  %s: ' "$1" >&2
	stty -echo 2> /dev/null || true
	read -r _reply || { stty echo 2> /dev/null || true; die 2 "No answer (input closed)."; }
	stty echo 2> /dev/null || true
	printf '\n' >&2
	printf '%s' "$_reply"
}

as_root() {
	if [ "$(id -u)" -eq 0 ]; then "$@"; else $SUDO "$@"; fi
}

# quote_cmd <args...>: one string that `eval set --` or `sh -c` turns back into them.
quote_cmd() {
	for _a in "$@"; do
		printf "'%s' " "$(printf '%s' "$_a" | sed "s/'/'\\\\''/g")"
	done
}

# --- phase 3: core wiring -----------------------------------------------------

cron_list() {
	if [ "$1" = root ]; then
		# shellcheck disable=SC2086 # CRONTAB_ROOT may carry arguments (tests)
		as_root ${CRONTAB_ROOT:-crontab} -l 2> /dev/null || true
	else
		# shellcheck disable=SC2086
		${CRONTAB:-crontab} -l 2> /dev/null || true
	fi
}
cron_write() {
	if [ "$1" = root ]; then
		# shellcheck disable=SC2086
		as_root ${CRONTAB_ROOT:-crontab} -
	else
		# shellcheck disable=SC2086
		${CRONTAB:-crontab} -
	fi
}

# script | schedule | crontab. The watchdog needs root for iptables and systemctl;
# the rest runs as the deploying user.
JOBS="watchdog.sh|*/10 * * * *|root
backup.sh|0 3 * * *|user
disk.sh --record|30 3 * * *|user"

link_step() { # <name> <link> <target>
	if [ "$(readlink "$2" 2> /dev/null || true)" = "$3" ]; then
		st_ok "$1"
	elif [ "$CHECK_ONLY" -eq 1 ]; then
		st_bad "$1 missing ($2)"
		MISSING=1
	else
		mkdir -p "$(dirname "$2")"
		ln -sfn "$3" "$2"
		st_ok "$1 ($2)"
	fi
}

core_wiring() {
	link_step "fluxer command" "$BIN_DIR/fluxer" "$OPS/fluxer"
	link_step "tab completion" "$COMPLETION_DIR/fluxer" "$OPS/completion.bash"

	# Not a pipe into while: MISSING must survive the loop.
	_jobs=$(printf '%s\n' "$JOBS")
	_ifs=$IFS
	IFS='
'
	for _job in $_jobs; do
		IFS=$_ifs
		_script=${_job%%|*}
		_rest=${_job#*|}
		_when=${_rest%|*}
		_who=${_rest#*|}
		_file=$OPS/${_script%% *}
		_label="$_script ($_who cron, $_when)"
		if [ "$_who" = root ] && [ "$SUDO_OK" -ne 1 ]; then
			st_skip "$_label: needs sudo. Without it nothing restarts the stack after a crash or a firewalld reload."
			continue
		fi
		if cron_list "$_who" | grep -v '^[[:space:]]*#' | grep -qF "$_file"; then
			st_ok "$_label"
		elif [ "$CHECK_ONLY" -eq 1 ]; then
			st_bad "$_label missing"
			MISSING=1
		else
			# Appended, never rewriting what is there. FLUXER_DIR is spelled out
			# because cron's environment is empty and ops/ may live elsewhere.
			{ cron_list "$_who"; printf '%s FLUXER_DIR=%s %s/%s >/dev/null 2>&1\n' "$_when" "$FLUXER_DIR" "$OPS" "$_script"; } \
				| cron_write "$_who"
			st_ok "$_label"
		fi
	done
	IFS=$_ifs
}

# --- main ---------------------------------------------------------------------

[ "${SETUP_SOURCE_ONLY:-0}" = 1 ] && return 0

usage() {
	sed -n '/^#   setup.sh/,/^#$/s/^# \{0,1\}//p' "$SELF" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
		--check) CHECK_ONLY=1 ;;
		--yes | -y) ASSUME_YES=1 ;;
		--no-extras) EXTRAS=0 ;;
		--fluxer-dir) [ $# -ge 2 ] || usage; FLUXER_DIR=$(readlink -m "$2"); export FLUXER_DIR; shift ;;
		--domain) [ $# -ge 2 ] || usage; DOMAIN=$2; shift ;;
		--email) [ $# -ge 2 ] || usage; EMAIL=$2; shift ;;
		-h | --help) sed -n '/^#   setup.sh/,/^#$/s/^# \{0,1\}//p' "$SELF"; exit 0 ;;
		*) usage ;;
	esac
	shift
done
[ "$ASSUME_YES" -eq 1 ] && EXTRAS=0
[ "$CHECK_ONLY" -eq 1 ] && EXTRAS=0

# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

if [ "$(id -u)" -eq 0 ] || { [ "$CHECK_ONLY" -eq 1 ] && $SUDO -n true 2> /dev/null; } || { [ "$CHECK_ONLY" -eq 0 ] && $SUDO -v 2> /dev/null; }; then
	SUDO_OK=1
fi

say "Fluxer"
if [ -n "$FLUXER_DIR" ] && [ -f "$FLUXER_DIR/.env" ]; then
	st_ok "found at $FLUXER_DIR (https://$(sed -n 's/^FLUXER_DOMAIN=//p' "$FLUXER_DIR/.env" | head -n 1))"
else
	die 2 "No Fluxer instance found. (Installing one arrives in a later task.)"
fi

say ""
say "Wiring"
core_wiring

[ "$CHECK_ONLY" -eq 1 ] && exit "$MISSING"
exit 0
