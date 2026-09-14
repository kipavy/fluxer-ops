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
	# Ctrl-C while `read` is blocked here would otherwise skip the stty echo
	# below and leave the terminal silently not echoing keystrokes afterwards.
	trap 'stty echo 2> /dev/null || true; exit 130' INT TERM
	read -r _reply || { stty echo 2> /dev/null || true; trap - INT TERM; die 2 "No answer (input closed)."; }
	stty echo 2> /dev/null || true
	trap - INT TERM
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
		say "    The docker group is effectively root on this host (a member can bind-mount the"
		say "    host filesystem into a container and read or write anything root can) - the same"
		say "    trust this script asks about above when it is itself run as root."
		ask "Add $_me to the docker group?" y || die 2 "Add yourself with: sudo usermod -aG docker $_me, log in again, and run this again."
		[ "$SUDO_OK" -eq 1 ] || die 2 "That needs sudo: sudo usermod -aG docker $_me"
		as_root usermod -aG docker "$_me"
		st_ok "$_me added to the docker group"
	fi
	# sg re-runs this script with the new group active, without a fresh login.
	# Without sg itself, "exec: sg: not found" would be the last word instead.
	command -v sg > /dev/null 2>&1 || die 2 "Log out and back in to pick up the docker group, then run this again."
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

# --- phase 2: the instance ------------------------------------------------------

PORTS='80/tcp 443/tcp 7881/tcp 7882/udp'
BEHIND_CF=0

valid_domain() {
	printf '%s' "$1" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
}
valid_email() {
	printf '%s' "$1" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
}

ask_domain_email() {
	while ! valid_domain "$DOMAIN"; do
		[ -z "$DOMAIN" ] || st_bad "not a domain name: $DOMAIN"
		[ "$ASSUME_YES" -eq 0 ] || die 2 "--yes needs --domain, e.g. --domain chat.example.com"
		DOMAIN=$(prompt "Domain for the instance (e.g. chat.example.com)")
	done
	while ! valid_email "$EMAIL"; do
		[ -z "$EMAIL" ] || st_bad "not an email address: $EMAIL"
		[ "$ASSUME_YES" -eq 0 ] || die 2 "--yes needs --email (for the certificate and the instance's own mail)"
		EMAIL=$(prompt "Your email (certificate notices, instance mail)")
	done
}

public_ip() {
	_ip=$(curl -fsS --max-time 10 "${PUBLIC_IP_URL:-https://1.1.1.1/cdn-cgi/trace}" 2> /dev/null | sed -n 's/^ip=//p' | head -n 1)
	[ -n "$_ip" ] || _ip=$(curl -fsS --max-time 10 https://api.ipify.org 2> /dev/null || true)
	printf '%s' "$_ip"
}

resolve4() {
	getent ahostsv4 "$1" 2> /dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# dns_verdict <public ip> <resolved ips> <file of Cloudflare CIDRs>
dns_verdict() {
	[ -n "$2" ] || { echo none; return 0; }
	for _ip in $2; do [ "$_ip" = "$1" ] && { echo here; return 0; }; done
	# shellcheck disable=SC2086 # $2 is a list of addresses
	if python3 - "$3" $2 <<'PY'
import ipaddress, sys
nets = [ipaddress.ip_network(l.strip()) for l in open(sys.argv[1]) if l.strip()]
addrs = [ipaddress.ip_address(a) for a in sys.argv[2:]]
sys.exit(0 if nets and all(any(a in n for n in nets) for a in addrs) else 1)
PY
	then echo cloudflare; else echo elsewhere; fi
}

phase_dns() {
	_ip=$(public_ip)
	if [ -z "$_ip" ]; then
		st_skip "could not learn this server's public IP; DNS not checked"
		return 0
	fi
	curl -fsS --max-time 10 "${CF_IPS_URL:-https://www.cloudflare.com/ips-v4}" > "$TMP/cf-v4" 2> /dev/null || : > "$TMP/cf-v4"
	while :; do
		case "$(dns_verdict "$_ip" "$(resolve4 "$DOMAIN")" "$TMP/cf-v4")" in
			here)
				st_ok "$DOMAIN points at this server ($_ip)"
				return 0
				;;
			cloudflare)
				st_ok "$DOMAIN is proxied through Cloudflare"
				say "    If the certificate is not issued, switch the record to \"DNS only\" until it is,"
				say "    then back, with SSL/TLS mode \"Full (strict)\"."
				BEHIND_CF=1
				return 0
				;;
		esac
		st_bad "$DOMAIN does not point at this server yet"
		say "    Create this record where the domain's DNS is managed:"
		say "        A    $DOMAIN    $_ip"
		[ "$ASSUME_YES" -eq 0 ] || die 2 "DNS for $DOMAIN does not point at $_ip. Fix the record, then run this again."
		printf '    Enter to check again (a new record can take a few minutes), or type skip: '
		read -r _reply || _reply=skip
		if [ "$_reply" = skip ]; then
			st_skip "DNS: no certificate can be issued until $DOMAIN points at $_ip"
			return 0
		fi
	done
}

# cloud_provider: "name|where its firewall is|docs", or nothing when unknown.
cloud_provider() {
	_d=${DMI_DIR:-/sys/class/dmi/id}
	_v=$(cat "$_d/sys_vendor" "$_d/chassis_asset_tag" "$_d/product_name" 2> /dev/null | tr '\n' ' ')
	case "$_v" in
		*OracleCloud*) echo 'Oracle Cloud|the VCN security list: Networking > Virtual cloud networks > your VCN > Security Lists > Add Ingress Rules|https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/securitylists.htm' ;;
		*Amazon*) echo 'AWS|the instance security group: EC2 > Security Groups > Inbound rules|https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/working-with-security-groups.html' ;;
		*Google*) echo 'Google Cloud|a VPC firewall rule: VPC network > Firewall|https://cloud.google.com/firewall/docs/using-firewalls' ;;
		*Microsoft*) echo 'Azure|the network security group: Networking > Inbound port rules|https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview' ;;
		*Hetzner*) echo 'Hetzner|the Cloud Firewall attached to the server, if any|https://docs.hetzner.com/cloud/firewalls/getting-started/creating-a-firewall' ;;
		*DigitalOcean*) echo 'DigitalOcean|the Cloud Firewall attached to the droplet, if any|https://docs.digitalocean.com/products/networking/firewalls/' ;;
		*Scaleway*) echo 'Scaleway|the instance security group|https://www.scaleway.com/en/docs/instances/how-to/use-security-groups/' ;;
	esac
}

phase_ports() {
	say "    Fluxer needs these ports open to the internet: $PORTS"
	_p=$(cloud_provider)
	if [ -n "$_p" ]; then
		_name=${_p%%|*}
		_rest=${_p#*|}
		say "    On $_name that is ${_rest%%|*}:"
		say "    ${_rest#*|}"
	else
		say "    If your hosting provider has a firewall in its web console, open them there."
	fi
	say "    Docker takes care of this server's own firewall. The provider's cannot be seen from here."
	[ "$ASSUME_YES" -eq 1 ] && return 0
	ask "Are they open?" y || die 2 "Open them, then run this again."
}

fetch_installer() {
	_url=${INSTALLER_URL:-https://fluxer.dev/install.sh}
	curl -fsSL "$_url" -o "$TMP/install.sh" && curl -fsSL "$_url.sha256" -o "$TMP/install.sh.sha256" \
		|| die 4 "Could not download $_url."
	# The same check update.sh does. This script writes every secret the instance has.
	(cd "$TMP" && sha256sum -c install.sh.sha256 > /dev/null 2>&1) \
		|| die 4 "The Fluxer installer's checksum did not verify. It was not run."
}

installer_meaning() {
	case "$1" in
		1) echo "it rejected its arguments (a setup.sh bug: please report it)" ;;
		2) echo "a prerequisite is missing (its message is above)" ;;
		3) echo "it refused to overwrite an existing instance (message above)" ;;
		4) echo "a download failed" ;;
		5) echo "generating the instance's secrets failed" ;;
		6) echo "the stack did not come up. Most often: DNS does not point here yet, or ports 80/443 are closed at the provider" ;;
		130) echo "it was interrupted" ;;
		*) echo "exit code $1" ;;
	esac
}

phase_install() {
	fetch_installer
	mkdir -p "$FLUXER_DIR"
	# A record for update.sh to refresh later, NOT what is about to run: $TMP is a
	# private 0700 mktemp directory, but $FLUXER_DIR is not, so between this copy
	# landing and the `sh` below, anyone who can write $FLUXER_DIR could otherwise
	# swap in their own script and have it run with $ALLOW_ROOT/sudo behind it.
	# Running the $TMP copy directly closes that: the bytes executed are exactly
	# the bytes fetch_installer just checksum-verified.
	cp "$TMP/install.sh" "$FLUXER_DIR/install.sh"
	st_do "installing Fluxer into $FLUXER_DIR (about 3.5 GB of images: a few minutes)"
	_rc=0
	# shellcheck disable=SC2086 # ALLOW_ROOT is empty or one flag
	sh "$TMP/install.sh" --dir "$FLUXER_DIR" --domain "$DOMAIN" --email "$EMAIL" --non-interactive $ALLOW_ROOT || _rc=$?
	[ "$_rc" -eq 0 ] || die "$_rc" "The Fluxer installer stopped: $(installer_meaning "$_rc"). Fix that and run setup again."
	NEW_INSTANCE=1
	st_ok "Fluxer is installed"
}

phase_instance() {
	if [ -n "$FLUXER_DIR" ] && [ -f "$FLUXER_DIR/docker-compose.yml" ] && [ -f "$FLUXER_DIR/.env" ]; then
		DOMAIN=$(sed -n 's/^FLUXER_DOMAIN=//p' "$FLUXER_DIR/.env" | head -n 1)
		if [ -n "$DOMAIN" ]; then
			st_ok "Fluxer found at $FLUXER_DIR (https://$DOMAIN)"
		else
			# .env exists but has no FLUXER_DOMAIN yet (edited by hand, or written by
			# a step that died before this line): "(https://)" would read as found
			# and working, when nothing is actually being served yet.
			st_ok "Fluxer found at $FLUXER_DIR (no FLUXER_DOMAIN in .env yet)"
		fi
		return 0
	fi
	if [ "$CHECK_ONLY" -eq 1 ]; then
		st_bad "no Fluxer instance${FLUXER_DIR:+ at $FLUXER_DIR}"
		MISSING=1
		return 0
	fi
	if [ -z "$FLUXER_DIR" ]; then
		# A clone at <dir>/ops is the layout get.sh makes: install next to it.
		if [ "$(basename "$OPS")" = ops ]; then
			FLUXER_DIR=$(dirname "$OPS")
		else
			FLUXER_DIR=$(readlink -m "$(prompt "Install Fluxer into" "$HOME/fluxer")")
		fi
	fi
	export FLUXER_DIR
	if [ -f "$FLUXER_DIR/docker-compose.yml" ] || [ -f "$FLUXER_DIR/.env" ]; then
		# Exactly one of the two files upstream's installer writes together is
		# here: an interrupt, or a failure partway through generating secrets, left
		# this half-installed. Upstream refuses to overwrite what exists (exit 3)
		# rather than finishing the rest, so without this a plain re-run would just
		# land back in phase_install and wedge on the same refusal, with only
		# "message above" (installer_meaning 3) to go on.
		if [ -f "$FLUXER_DIR/docker-compose.yml" ]; then _have=docker-compose.yml; else _have=.env; fi
		die 3 "$FLUXER_DIR has $_have but not a complete instance (docker-compose.yml and .env both need to be there) - a previous install looks interrupted. The Fluxer installer will refuse to overwrite $_have. Move or remove $FLUXER_DIR/$_have (read it first: it may hold real secrets), then run this again."
	fi
	say "  No Fluxer instance yet: installing one into $FLUXER_DIR."
	ask_domain_email
	phase_dns
	phase_ports
	phase_install
	BACKUP_ROOT=${BACKUP_ROOT:-$(dirname "$FLUXER_DIR")/fluxer-backups}
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

# README and lib.sh both say a Fluxer found through Docker is fine to point at,
# from anywhere. That is true for most of ops/ - every script takes FLUXER_DIR
# from lib.sh - but not for everything: badge-patch.sh's compose override, and
# `fluxer update`'s re-apply of it, and backup.sh's `cp -r ops` all assume ops/
# sits at $FLUXER_DIR/ops. Say so plainly rather than let any of those surprise
# someone later. Not a MISSING: the instance itself is fine, only these are not.
check_ops_layout() {
	[ -n "$FLUXER_DIR" ] || return 0
	[ "$OPS" = "$FLUXER_DIR/ops" ] && return 0
	st_skip "ops/ is at $OPS, not $FLUXER_DIR/ops"
	say "    Degraded because of that: \`fluxer badge-patch\` (and update's re-apply of it) will"
	say "    not find its files there, and nightly backups will not include ops/. Everything"
	say "    else (finding the instance, cron, backups of the instance itself) still works."
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
			if [ "$CHECK_ONLY" -eq 1 ]; then
				# --check without passwordless sudo cannot read root's crontab, so
				# whether this job is really there is simply unknown. README and
				# doctor.sh both say --check exits 1 if anything is missing; an
				# unverified root cron job is exactly the kind of gap that leaves
				# the stack down after a crash, so it counts as missing, not skipped.
				st_bad "$_label: cannot verify without sudo"
				MISSING=1
			else
				st_skip "$_label: needs sudo. Without it nothing restarts the stack after a crash or a firewalld reload."
			fi
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

# --- phase 4: optional extras -------------------------------------------------

# write_private <file>: stdin to a file only its owner can read. These hold tokens.
write_private() {
	(umask 077 && cat > "$1")
	chmod 600 "$1"
}

extra_alerts() {
	if [ -f "$OPS/notify.conf" ]; then st_ok "alerts configured (fluxer notify test)"; return 0; fi
	say "  Alerts: hear about an outage or a failed backup on your phone, in a chat, or by email."
	if ! ask "Set up alerts?" n; then st_skip "alerts (later: fluxer setup)"; return 0; fi
	_ch=$(prompt "Channel: ntfy, webhook or email" ntfy)
	case "$_ch" in
		ntfy)
			_url=$(prompt "ntfy topic URL" "https://ntfy.sh/fluxer-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')")
			_line="NOTIFY_NTFY_URL='$_url'"
			say "    In the ntfy app (Android, iOS, web), subscribe to: $_url"
			;;
		webhook)
			_url=$(prompt "Webhook URL (Discord, Slack or Fluxer)")
			_line="NOTIFY_WEBHOOK_URL='$_url'"
			;;
		email)
			_url=$(prompt "Send alerts to")
			valid_email "$_url" || { st_bad "not an email address: $_url"; st_skip "alerts"; return 0; }
			_line="NOTIFY_EMAIL_TO='$_url'"
			say "    Sent through the SMTP settings already in .env (FLUXER_EMAIL_SMTP_*)."
			;;
		*) st_bad "unknown channel: $_ch"; st_skip "alerts"; return 0 ;;
	esac
	case "$_url" in '' | *"'"*) st_bad "that value is empty or contains a quote"; st_skip "alerts"; return 0 ;; esac
	printf '# Written by setup.sh on %s. Every option: notify.conf.example\n%s\n' "$(date -u +%F)" "$_line" \
		| write_private "$OPS/notify.conf"
	if "$OPS/notify.sh" test; then
		st_ok "alerts set up; a test was sent"
	else
		st_bad "the test alert did not go through: edit $OPS/notify.conf, then fluxer notify test"
	fi
}

extra_offsite() {
	if [ -f "$OPS/offsite.conf" ]; then st_ok "off-site backups configured (fluxer offsite status)"; return 0; fi
	say "  Off-site backups: an encrypted copy of each nightly backup in a Cloudflare R2 bucket,"
	say "  so losing this server is not losing the data. Needs a bucket and an R2 API token"
	say "  with Object Read & Write on it (R2 > Manage API tokens)."
	if ! ask "Set up off-site backups?" n; then st_skip "off-site backups (later: fluxer setup)"; return 0; fi
	_acc=$(prompt "Cloudflare account ID")
	_bkt=$(prompt "Bucket name")
	_key=$(prompt "Access key ID")
	_sec=$(prompt_secret "Secret access key")
	for _v in "$_acc" "$_bkt" "$_key" "$_sec"; do
		case "$_v" in '' | *"'"*) st_bad "all four are needed, without quotes"; st_skip "off-site backups"; return 0 ;; esac
	done
	_pw=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
	write_private "$OPS/offsite.conf" <<EOF
# Written by setup.sh on $(date -u +%F). Every option: offsite.conf.example
RESTIC_PASSWORD='$_pw'
RESTIC_REPOSITORY='s3:https://$_acc.r2.cloudflarestorage.com/$_bkt'
AWS_ACCESS_KEY_ID='$_key'
AWS_SECRET_ACCESS_KEY='$_sec'
AWS_DEFAULT_REGION=auto
EOF
	say ""
	say "    The encryption password of your off-site backups:"
	say ""
	say "        $_pw"
	say ""
	say "    Save it in a password manager now. Without it nobody can restore them, you included,"
	say "    and the copy on this server is gone exactly when you would need it."
	prompt "Press Enter once it is saved" > /dev/null
	if "$OPS/offsite.sh" init; then
		st_ok "off-site repository ready: every nightly backup is pushed to it"
	else
		st_bad "offsite init failed: fix $OPS/offsite.conf, then fluxer offsite init"
	fi
}

extra_firewall() {
	$SYSTEMCTL is-active --quiet firewalld 2> /dev/null || return 0
	if "$OPS/firewall-fix.sh" --installed; then st_ok "firewalld fix installed"; return 0; fi
	if [ "$SUDO_OK" -ne 1 ]; then st_skip "firewalld fix (needs sudo)"; return 0; fi
	say "  firewalld is running here. A firewalld reload wipes Docker's network rules and every"
	say "  port of the stack stops answering until Docker restarts. The fix restarts it with firewalld."
	if ! ask "Install the firewalld fix?" y; then st_skip "firewalld fix (later: fluxer firewall-fix)"; return 0; fi
	if "$OPS/firewall-fix.sh" --apply --yes; then st_ok "firewalld fix installed"; else st_bad "firewall-fix failed (above)"; fi
}

extra_cf() {
	if [ "$BEHIND_CF" -ne 1 ]; then
		_ip=$(public_ip)
		[ -n "$_ip" ] || return 0
		curl -fsS --max-time 10 "${CF_IPS_URL:-https://www.cloudflare.com/ips-v4}" > "$TMP/cf-v4" 2> /dev/null || return 0
		[ "$(dns_verdict "$_ip" "$(resolve4 "$DOMAIN")" "$TMP/cf-v4")" = cloudflare ] || return 0
	fi
	if "$OPS/cf-ips.sh" --quiet > /dev/null 2>&1; then st_ok "Cloudflare ranges trusted"; return 0; fi
	say "  $DOMAIN is behind Cloudflare, and the instance does not trust all of Cloudflare's"
	say "  addresses yet: rate limits and logs would see Cloudflare instead of your users."
	if ! ask "Trust Cloudflare's current ranges?" y; then st_skip "Cloudflare ranges (later: fluxer cf-ips)"; return 0; fi
	if "$OPS/cf-ips.sh" --apply --yes; then st_ok "Cloudflare ranges trusted"; else st_bad "cf-ips failed (above)"; fi
}

phase_extras() {
	say ""
	say "Optional (Enter skips)"
	extra_alerts
	extra_offsite
	extra_firewall
	extra_cf
}

# --- phase 5: finish ----------------------------------------------------------

phase_finish() {
	say ""
	say "Checking"
	if "$OPS/check.sh" --quiet; then
		st_ok "https://$DOMAIN is serving"
	else
		st_bad "some checks fail (above). A new stack can take a minute: run fluxer check again shortly"
	fi
	"$OPS/doctor.sh" --quiet || true
	say ""
	case ":$PATH:" in
		*":$BIN_DIR:"*) ;;
		*) say "Open a new shell (or: export PATH=\"$BIN_DIR:\$PATH\") for the fluxer command."; say "" ;;
	esac
	if [ "$NEW_INSTANCE" -eq 1 ]; then
		cat <<EOF
Your instance is live: https://$DOMAIN

Next:
  1. Open it and create your account.
  2. fluxer users staff <your username>     make yourself an admin
  3. fluxer status                          any time; fluxer help for the rest
EOF
	else
		say "fluxer-ops is set up for https://$DOMAIN. fluxer status any time; fluxer help for the rest."
	fi
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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say "Fluxer"
phase_instance
check_ops_layout

say ""
say "Wiring"
if [ -n "$FLUXER_DIR" ] && [ -f "$FLUXER_DIR/.env" ]; then core_wiring; fi

[ "$CHECK_ONLY" -eq 1 ] && exit "$MISSING"
[ "$EXTRAS" -eq 1 ] && phase_extras
phase_finish
exit 0
