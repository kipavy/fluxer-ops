# bash completion for `fluxer`. install-host.sh links it into
# ~/.local/share/bash-completion/completions/fluxer, where bash-completion loads it
# on first use.
#
# Service and backup names are read live (compose config, the backup dirs), so they
# stay right across updates without this file changing.

# Same resolution as lib.sh, which cannot be sourced into an interactive shell
# (it sets variables and may call docker). Parent of the real ops/ directory,
# unless FLUXER_DIR is set.
_fluxer_ops=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
_fluxer_dir() { printf '%s' "${FLUXER_DIR:-$(dirname "$_fluxer_ops")}"; }
# Named apart from _fluxer_backups() below (which lists backup NAMES, not the
# root they live under): giving both the same name would make the lister call
# itself instead of this one.
_fluxer_backup_root() { printf '%s' "${BACKUP_ROOT:-$(dirname "$(_fluxer_dir)")/fluxer-backups}"; }

_fluxer_services() {
	(cd "$(_fluxer_dir)" 2>/dev/null && docker compose config --services 2>/dev/null)
}

_fluxer_backups() {
	local d
	for d in "$(_fluxer_backup_root)"/*/ "$(_fluxer_dir)"/backups/*/; do
		[ -f "$d/fluxer.dump" ] && basename "$d"
	done
}

_fluxer() {
	local cur=${COMP_WORDS[COMP_CWORD]} cmd=${COMP_WORDS[1]:-} sub=${COMP_WORDS[2]:-}
	local words=''

	if [ "$COMP_CWORD" -eq 1 ]; then
		words='status check doctor errors top voice logs up down ps restart psql valkey sh
			changelog update rollback prune users premium gifts badge-patch
			backup backups verify-backup restore offsite
			notify disk env cf-ips firewall-fix install-host help'
	else
		case "$cmd" in
			status) words='--json' ;;
			doctor | check) words='--quiet' ;;
			logs) words="-f --tail --since $(_fluxer_services)" ;;
			restart | sh) words=$(_fluxer_services) ;;
			errors) words="--since --warn --top $(_fluxer_services)" ;;
			update) words='--check --yes' ;;
			changelog) words='--all' ;;
			prune) words='--apply --keep' ;;
			restore) words=$(_fluxer_backups) ;;
			premium) words='--subscriber --off --list' ;;
			badge-patch) words='--revert' ;;
			cf-ips) words='--apply --quiet --yes' ;;
			firewall-fix) words='--apply --revert --installed --test --yes' ;;
			disk) words='--json --record' ;;
			install-host) words='--check --yes' ;;
			users)
				if [ "$COMP_CWORD" -eq 2 ]; then words='list show staff verify-email stats'
				else case "$sub" in
					list) words='--recent' ;; show) words='--reveal' ;;
					staff) words='--off' ;; stats) words='--messages' ;;
				esac; fi ;;
			gifts | gift)
				if [ "$COMP_CWORD" -eq 2 ]; then words='create list show revoke redeem --help'
				else case "$sub" in
					create) words='--duration --count' ;;
					list) words='--unredeemed --redeemed --revoked' ;;
				esac; fi ;;
			offsite)
				if [ "$COMP_CWORD" -eq 2 ]; then words='status init push snapshots check restore forget restic'
				else case "$sub" in
					push) words="--if-configured $(_fluxer_backups)" ;;
					check) words='--read-data-subset=5%' ;;
					restore) [ "$COMP_CWORD" -eq 3 ] && words='latest' ;;
				esac; fi ;;
			notify) [ "$COMP_CWORD" -eq 2 ] && words='test status send alert ok' ;;
			env)
				if [ "$COMP_CWORD" -eq 2 ]; then words='keys get set diff'
				elif [ "$COMP_CWORD" -eq 3 ] && { [ "$sub" = get ] || [ "$sub" = set ]; }; then
					words=$(sed -n 's/^\([A-Z0-9_]*\)=.*/\1/p' "$(_fluxer_dir)/.env" 2>/dev/null)
				else case "$sub" in get) words='--reveal' ;; diff) words='--upstream' ;; esac; fi ;;
		esac
	fi
	# shellcheck disable=SC2207 # word lists are space-separated by construction
	COMPREPLY=($(compgen -W "$words" -- "$cur"))
}

complete -F _fluxer fluxer
