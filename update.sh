#!/bin/sh
# One command to update Fluxer safely. It does the steps that are easy to forget:
# the iptables preflight, refreshing the installer (install.sh never updates
# itself), showing the plan, and verifying the result afterwards.
#
#   ./update.sh           show the plan, ask, then apply
#   ./update.sh --check   show the plan and stop, change nothing
#   ./update.sh --yes     apply without asking
set -eu

FLUXER_DIR=${FLUXER_DIR:-/home/ubuntu/Documents/fluxer}
ASSUME_YES=0
CHECK_ONLY=0
for a in "$@"; do
	case "$a" in
		--yes | -y) ASSUME_YES=1 ;;
		--check) CHECK_ONLY=1 ;;
		*) echo "usage: update.sh [--check] [--yes]" >&2; exit 2 ;;
	esac
done

cd "$FLUXER_DIR"

# 1. Preflight. firewalld wipes Docker's nat chain; without it the upgrade dies
#    partway through on an opaque "iptables: No chain/target/match by that name".
if ! sudo iptables -t nat -L -n 2>/dev/null | grep -q '^Chain DOCKER'; then
	echo "Docker's DOCKER nat chain is missing (firewalld flushed it)."
	echo "Restarting docker before going any further."
	sudo systemctl restart docker
	sleep 15
fi

# 2. Refresh the installer. --update refreshes the five stack files but never
#    install.sh itself, so it goes stale and misses new upgrade steps.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if curl -fsSL https://fluxer.dev/install.sh -o "$tmp/install.sh" \
	&& curl -fsSL https://fluxer.dev/install.sh.sha256 -o "$tmp/install.sh.sha256"; then
	if (cd "$tmp" && sha256sum -c install.sh.sha256 > /dev/null 2>&1); then
		if cmp -s "$tmp/install.sh" install.sh; then
			echo "Installer is current."
		else
			cp "$tmp/install.sh" install.sh
			echo "Installer refreshed to a newer verified version."
		fi
	else
		echo "WARNING: installer checksum did NOT verify. Keeping the existing one." >&2
	fi
else
	echo "WARNING: could not fetch the installer. Using the existing one." >&2
fi

# 3. The plan.
echo
sh install.sh --update --dry-run
if [ "$CHECK_ONLY" -eq 1 ]; then
	exit 0
fi

# 4. Confirm.
if [ "$ASSUME_YES" -eq 0 ]; then
	printf '\nApply this update? [y/N] '
	read -r reply
	case "$reply" in
		y | Y | yes | YES) ;;
		*) echo "Aborted. Nothing changed."; exit 0 ;;
	esac
fi

# 5. Apply, then prove it actually works.
echo
if sh install.sh --update --non-interactive; then
	echo
	echo "--- verifying ---"
	if ./ops/check.sh; then
		echo
		echo "Update complete and verified."
	else
		echo
		echo "Update applied but the health checks FAIL." >&2
		echo "Roll back with:  sh install.sh --rollback --dir $FLUXER_DIR" >&2
		exit 1
	fi
else
	echo
	echo "Update FAILED." >&2
	echo "Roll back with:  sh install.sh --rollback --dir $FLUXER_DIR" >&2
	exit 1
fi
