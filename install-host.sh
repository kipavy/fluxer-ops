#!/bin/sh
# install-host.sh - wire these scripts into a host: the `fluxer` command, its
# shell completion, and the cron jobs that make the rest of this directory work.
#
#   install-host.sh           show what is missing, ask, then install it
#   install-host.sh --check   show what is missing and stop (exit 1 if anything is)
#   install-host.sh --yes     install without asking
#
# Until this existed, a fresh host was set up by copying lines out of the README by
# hand, and a step skipped there fails silently: no watchdog means the firewalld
# flush takes the stack down with nothing to bring it back, and no backup cron
# means "we have backups" stops being true on a date nobody notices.
#
# Idempotent. Every step checks before it acts, existing crontab lines are never
# rewritten or removed, and a line already present in any form is left alone.
set -eu

. "$(dirname "$(readlink -f "$0")")/lib.sh"
need_instance
BIN_DIR=${BIN_DIR:-$HOME/.local/bin}
COMPLETION_DIR=${COMPLETION_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions}

# script | schedule | which crontab. The watchdog needs root for iptables and
# systemctl; everything else runs as the deploying user.
JOBS="watchdog.sh|*/10 * * * *|root
backup.sh|0 3 * * *|user
disk.sh --record|30 3 * * *|user"

CHECK_ONLY=0 ASSUME_YES=0
for a in "$@"; do
	case "$a" in
		--check) CHECK_ONLY=1 ;;
		--yes | -y) ASSUME_YES=1 ;;
		*) echo "usage: install-host.sh [--check] [--yes]" >&2; exit 2 ;;
	esac
done

crontab_of() {
	if [ "$1" = root ]; then sudo -n crontab -l 2>/dev/null || true
	else crontab -l 2>/dev/null || true; fi
}

todo=''
add_todo() { todo="$todo$1
"; }

link_state() { # <link> <target>
	if [ "$(readlink "$1" 2>/dev/null || true)" = "$2" ]; then echo ok; else echo missing; fi
}

echo "Host setup for $FLUXER_DIR"
echo

s=$(link_state "$BIN_DIR/fluxer" "$OPS/fluxer")
printf '%-8s fluxer command   %s -> %s\n' "$s" "$BIN_DIR/fluxer" "$OPS/fluxer"
[ "$s" = ok ] || add_todo "link|$BIN_DIR/fluxer|$OPS/fluxer"

s=$(link_state "$COMPLETION_DIR/fluxer" "$OPS/completion.bash")
printf '%-8s completion       %s\n' "$s" "$COMPLETION_DIR/fluxer"
[ "$s" = ok ] || add_todo "link|$COMPLETION_DIR/fluxer|$OPS/completion.bash"

printf '%s\n' "$JOBS" | while IFS='|' read -r script when who; do
	[ -x "$OPS/${script%% *}" ] || continue
	if crontab_of "$who" | grep -v '^[[:space:]]*#' | grep -qF "$OPS/${script%% *}"; then
		printf '%-8s %-4s cron        %s\n' ok "$who" "$script"
	else
		printf '%-8s %-4s cron        %s %s\n' missing "$who" "$when" "$script"
	fi
done
cron_todo=$(printf '%s\n' "$JOBS" | while IFS='|' read -r script when who; do
	[ -x "$OPS/${script%% *}" ] || continue
	crontab_of "$who" | grep -v '^[[:space:]]*#' | grep -qF "$OPS/${script%% *}" \
		|| printf 'cron|%s|%s %s/%s >/dev/null 2>&1\n' "$who" "$when" "$OPS" "$script"
done)
todo="$todo$cron_todo"

if [ -z "$(printf '%s' "$todo" | tr -d '\n')" ]; then
	echo
	echo "Nothing to do."
	exit 0
fi
[ "$CHECK_ONLY" -eq 0 ] || exit 1

if [ "$ASSUME_YES" -eq 0 ]; then
	printf '\nInstall what is missing? [y/N] '
	read -r reply
	case "$reply" in y | Y | yes | YES) ;; *) echo "Aborted. Nothing changed."; exit 0 ;; esac
fi

echo
printf '%s\n' "$todo" | while IFS='|' read -r kind a b; do
	case "$kind" in
		link)
			mkdir -p "$(dirname "$a")"
			ln -sfn "$b" "$a"
			echo "linked   $a"
			;;
		cron)
			# Append to whatever is there; never rewrite an existing line.
			if [ "$a" = root ]; then
				{ sudo -n crontab -l 2>/dev/null || true; printf '%s\n' "$b"; } | sudo -n crontab -
			else
				{ crontab -l 2>/dev/null || true; printf '%s\n' "$b"; } | crontab -
			fi
			echo "cron     ($a) $b"
			;;
	esac
done

case ":$PATH:" in
	*":$BIN_DIR:"*) ;;
	*) echo; echo "Note: $BIN_DIR is not on PATH for this shell." ;;
esac
