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

# --- phase 1: prerequisites ---------------------------------------------------

pkg_hint() { # <package>: the command that installs it here
	if command -v apt-get > /dev/null 2>&1; then echo "sudo apt-get install -y $1"
	elif command -v dnf > /dev/null 2>&1; then echo "sudo dnf install -y $1"
	elif command -v zypper > /dev/null 2>&1; then echo "sudo zypper install -y $1"
	elif command -v pacman > /dev/null 2>&1; then echo "sudo pacman -S --needed $1"
	elif command -v apk > /dev/null 2>&1; then echo "sudo apk add $1"
	else echo "install $1 with this distribution's package manager"; fi
}

version_ge() { # <have> <want>: dotted numbers, compared numerically
	[ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" = "$2" ]
}

phase_root() {
	[ "$(id -u)" -eq 0 ] || return 0
	st_bad "running as root"
	say "    The Fluxer installer refuses root unless told otherwise: an ordinary user in the"
	say "    docker group keeps a mistake in a container from being a mistake on the host."
	[ "$CHECK_ONLY" -eq 1 ] && return 0
	if [ "$ASSUME_YES" -eq 1 ] || ask "Continue as root anyway?" n; then
		ALLOW_ROOT=--allow-root
	else
		die 2 "Run it again as a normal user who can sudo."
	fi
}

phase_sudo() {
	if [ "$(id -u)" -eq 0 ]; then SUDO_OK=1; return 0; fi
	if [ "$CHECK_ONLY" -eq 1 ]; then
		if $SUDO -n true 2> /dev/null; then SUDO_OK=1; st_ok "sudo"; else st_skip "sudo not checked (would ask for a password)"; fi
		return 0
	fi
	if $SUDO -v 2> /dev/null; then
		SUDO_OK=1
		st_ok "sudo"
	else
		st_skip "no sudo: the watchdog cron and the firewalld fix will be skipped"
	fi
}

# phase_docker <original args, quoted>: needs them to re-run itself under the new group.
phase_docker() {
	if ! command -v "$DOCKER" > /dev/null 2>&1; then
		st_bad "Docker is not installed"
		if [ "$CHECK_ONLY" -eq 1 ]; then MISSING=1; return 0; fi
		_url=${DOCKER_INSTALL_URL:-https://get.docker.com}
		say "    Docker's official install script can set it up: $_url"
		if ! ask "Install Docker now?" y; then
			die 2 "Install Docker Engine with the compose plugin (https://docs.docker.com/engine/install/), then run this again."
		fi
		[ "$SUDO_OK" -eq 1 ] || die 2 "Installing Docker needs root or sudo."
		st_do "installing Docker"
		_tmp=$(mktemp)
		curl -fsSL "$_url" -o "$_tmp" || die 4 "Could not download $_url."
		as_root sh "$_tmp" || die 2 "Docker's install script failed (output above)."
		rm -f "$_tmp"
		st_ok "Docker installed"
	fi

	if [ "$(id -u)" -eq 0 ] || $DOCKER info > /dev/null 2>&1; then
		st_ok "Docker $($DOCKER version --format '{{.Server.Version}}' 2> /dev/null || echo)"
		return 0
	fi
	_me=$(id -un)
	if getent group docker 2> /dev/null | cut -d: -f4 | tr ',' '\n' | grep -qx "$_me"; then
		# In the group, but this login predates it: sg gives it to this run.
		[ "${SETUP_SG:-0}" = 1 ] && die 2 "Docker is not answering. Is it running? sudo systemctl start docker"
		[ "$CHECK_ONLY" -eq 1 ] && { st_bad "$_me is in the docker group, but this login is not yet (log in again)"; MISSING=1; return 0; }
	else
		st_bad "$_me cannot use Docker (not in the docker group)"
		if [ "$CHECK_ONLY" -eq 1 ]; then MISSING=1; return 0; fi
		ask "Add $_me to the docker group?" y || die 2 "Add yourself with: sudo usermod -aG docker $_me, log in again, and run this again."
		[ "$SUDO_OK" -eq 1 ] || die 2 "That needs sudo: sudo usermod -aG docker $_me"
		as_root usermod -aG docker "$_me"
		st_ok "$_me added to the docker group"
	fi
	st_do "continuing with the docker group (no need to log in again)"
	SETUP_SG=1 exec sg docker -c "SETUP_SG=1 sh $(quote_cmd "$SELF") $1"
}

phase_tools() {
	_missing=''
	for _t in curl python3 sha256sum git; do
		command -v "$_t" > /dev/null 2>&1 || _missing="$_missing $_t"
	done
	_cv=$($DOCKER compose version --short 2> /dev/null | sed 's/^v//') || _cv=''
	if [ -z "$_cv" ]; then
		st_bad "Docker Compose plugin missing"
		_missing="$_missing docker-compose-plugin"
	elif ! version_ge "$_cv" 2.24.4; then
		st_bad "Docker Compose $_cv is older than 2.24.4"
		_missing="$_missing docker-compose-plugin"
	else
		st_ok "Docker Compose $_cv"
	fi
	if [ -z "$_missing" ]; then st_ok "curl, python3, sha256sum, git"; return 0; fi
	for _m in $_missing; do
		case "$_m" in sha256sum) _p=coreutils ;; *) _p=$_m ;; esac
		[ "$_m" = docker-compose-plugin ] && continue
		st_bad "$_m missing: $(pkg_hint "$_p")"
	done
	if [ "$CHECK_ONLY" -eq 1 ]; then MISSING=1; return 0; fi
	die 2 "Install what is missing above, then run this again."
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

ORIG_ARGS=$(quote_cmd "$@")

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

say "Prerequisites"
phase_root
phase_sudo
phase_docker "$ORIG_ARGS"
phase_tools
say ""

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
