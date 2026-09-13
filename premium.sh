#!/bin/sh
# premium.sh - grant or revoke Plutonium, badge included, in one command.
#
#   premium.sh <username>               Visionary badge (lifetime)
#   premium.sh <username> --subscriber  Plutonium badge, "subscriber since"
#   premium.sh <username> --off         revoke
#   premium.sh --list                   who has premium
#
# Two things have to be true for the badge to appear, and neither is reachable
# from the admin panel on its own:
#
#   1. The account needs premium_type set (1 subscription, 2 lifetime). The badge
#      renders off that field. The admin API only toggles PremiumFlags bits -
#      /admin/users/:id/premium-flags - so there is no endpoint for it, and the
#      premium override alone leaves premium_type at 0: perks, no badge.
#   2. The client has to stop hiding the badge on self-hosted instances. That is
#      badge-patch.sh, which this runs for you if it is not applied yet.
#
# So the row is edited directly. That is the only path for premium_type, and doing
# the ENABLED_OVERRIDE flag the same way keeps it one transaction and means you do
# not need the STAFF flag on your own account to grant it to yourself.
#
# Values are written in the KV store's own encoding: dates as
# {"value":...,"__fluxer_type":"date"}, plain numbers bare, and `version` (the
# row's optimistic-concurrency counter) bumped, exactly as the app would.
set -eu

FLUXER_DIR=${FLUXER_DIR:-/home/ubuntu/Documents/fluxer}
OPS="$FLUXER_DIR/ops"
OVERRIDE="$FLUXER_DIR/docker-compose.override.yml"

# PremiumFlags, from packages/constants/src/UserConstants.ts.
BADGE_HIDDEN=2
BADGE_MASKED=4
PURCHASE_DISABLED=64
ENABLED_OVERRIDE=128
PERKS_DISABLED=256

die() { printf 'premium: %s\n' "$*" >&2; exit 1; }
compose() { (cd "$FLUXER_DIR" && docker compose "$@"); }
psql_() { compose exec -T postgres psql -U fluxer -d fluxer -v ON_ERROR_STOP=1 "$@"; }
psql_val() { psql_ -At "$@" | tr -d '\r'; }

# Rows are addressed by the bare numeric user id, never by row_key (which is a JSON
# blob full of quotes) and never by an interpolated username: psql does not perform
# variable interpolation on -c strings, and hand-quoting into SQL is how injection
# bugs get written. Usernames are validated before they reach a query at all.
where_user() { printf "table_name = 'users' and row_data->'user_id'->>'value' = '%s'" "$1"; }

usage() {
	cat <<'USAGE'
usage: premium.sh <username> [--subscriber | --off]
       premium.sh --list

  <username>       grant Plutonium with the Visionary badge (lifetime)
  --subscriber     grant Plutonium with the "subscriber since" badge instead
  --off            revoke premium and the badge
  --list           show every account's premium state
USAGE
}

cmd_list() {
	psql_ -c "
select row_data->>'username' as username,
       lpad(row_data->>'discriminator', 4, '0') as tag,
       coalesce(row_data->>'premium_type', '0') as type,
       case coalesce((row_data->>'premium_type')::int, 0)
            when 2 then 'visionary #' || coalesce(row_data->>'premium_lifetime_sequence', '?')
            when 1 then 'subscriber'
            else '-' end as badge,
       case when (coalesce((row_data->>'premium_flags')::int, 0) & $ENABLED_OVERRIDE) <> 0
            then 'yes' else 'no' end as override,
       case when (coalesce((row_data->>'premium_flags')::int, 0) & $BADGE_HIDDEN) <> 0
            then 'HIDDEN' else '' end as badge_hidden
from fluxer_kv
where table_name = 'users'
order by username;"
}

# Resolve a username to its numeric user id, rejecting anything ambiguous rather than
# guessing which of two accounts was meant.
resolve_user() {
	name=$1
	case "$name" in
		'' | *[!A-Za-z0-9._-]*) die "not a valid username: '$name'" ;;
	esac
	rows=$(psql_val -c "
select (row_data->'user_id'->>'value') || '|' || lpad(row_data->>'discriminator', 4, '0')
from fluxer_kv
where table_name = 'users' and lower(row_data->>'username') = lower('$name');")
	count=$(printf '%s' "$rows" | grep -c . || true)
	if [ "${count:-0}" -eq 0 ]; then
		echo "premium: no account named '$name'. Accounts on this instance:" >&2
		psql_val -c "select '  ' || (row_data->>'username') || '#' || lpad(row_data->>'discriminator', 4, '0')
			from fluxer_kv where table_name = 'users' order by 1;" >&2
		exit 1
	fi
	if [ "$count" -gt 1 ]; then
		echo "premium: '$name' matches $count accounts:" >&2
		printf '%s\n' "$rows" | sed 's/.*|/  #/' >&2
		die 'usernames are not unique here - edit the row by hand'
	fi
	printf '%s\n' "${rows%%|*}"
}

# Applied means: our override is in place. badge-patch.sh is idempotent but spends
# a minute on brotli, so it is not worth re-running when it is already on.
badge_patch_applied() {
	[ -f "$OVERRIDE" ] && head -n 1 "$OVERRIDE" | grep -q 'badge-patch.sh'
}

ensure_badge_patch() {
	if badge_patch_applied; then
		echo "Badge patch: already applied."
		return 0
	fi
	echo "Badge patch: not applied yet, applying it now."
	echo
	"$OPS/badge-patch.sh"
}

cmd_grant() {
	name=$1 lifetime=$2
	id=$(resolve_user "$name")

	if [ "$lifetime" -eq 1 ]; then
		type=2
		# Visionary IDs are sequential across the instance. Keep an existing one.
		seq_sql="case when row_data->>'premium_lifetime_sequence' is null
		              then to_jsonb((select coalesce(max((row_data->>'premium_lifetime_sequence')::int), 0) + 1
		                             from fluxer_kv where table_name = 'users'))
		              else row_data->'premium_lifetime_sequence' end"
	else
		type=1
		seq_sql="row_data->'premium_lifetime_sequence'"
	fi

	before=$(psql_val -c "
select coalesce(row_data->>'premium_flags', '0')
from fluxer_kv where $(where_user "$id");")

	# One statement, so the row is never left half granted:
	#  - ENABLED_OVERRIDE on, PERKS_DISABLED off: the perks
	#  - BADGE_HIDDEN and BADGE_MASKED off: those exist to suppress or downgrade
	#    the badge, which is the one thing this command is for
	#  - premium_until and premium_gift_extension_ends_at removed: the server takes
	#    the later of the two as the end (getEffectivePremiumUntil), and with both
	#    absent it means "never expires" to the server (checkHasActivePaidPremium)
	#    and the client (isPremiumExpiredLocally). A leftover gift end would
	#    otherwise strip this grant, badge and all, the day it passes.
	psql_ -c "
update fluxer_kv
set row_data = jsonb_set(
      jsonb_set(
        jsonb_set(
          jsonb_set(
            (row_data - 'premium_until' - 'premium_gift_extension_ends_at' - 'premium_grace_ends_at' - 'premium_will_cancel'),
            '{premium_flags}',
            to_jsonb(((coalesce((row_data->>'premium_flags')::int, 0)
                       | $ENABLED_OVERRIDE)
                      & ~($PERKS_DISABLED | $BADGE_HIDDEN | $BADGE_MASKED)))),
          '{premium_type}', to_jsonb($type)),
        '{premium_since}',
        case when row_data->'premium_since' is null or row_data->'premium_since' = 'null'::jsonb
             then jsonb_build_object(
                    'value', to_char(now() at time zone 'utc', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),
                    '__fluxer_type', 'date')
             else row_data->'premium_since' end),
      '{version}', to_jsonb(coalesce((row_data->>'version')::int, 0) + 1))
where $(where_user "$id");" > /dev/null

	psql_ -c "
update fluxer_kv
set row_data = jsonb_set(row_data, '{premium_lifetime_sequence}', $seq_sql),
    updated_at = now()
where $(where_user "$id");" > /dev/null

	after=$(psql_val -c "
select (row_data->>'premium_type') || ' ' || (row_data->>'premium_flags') || ' '
       || coalesce(row_data->>'premium_lifetime_sequence', '-')
from fluxer_kv where $(where_user "$id");")
	set -- $after

	echo "$name: premium on."
	if [ "$1" = "2" ]; then
		printf '  badge        Visionary #%s\n' "$3"
	else
		printf '  badge        Plutonium, subscriber since\n'
	fi
	printf '  premium_type %s\n' "$1"
	printf '  flags        %s -> %s\n' "$before" "$2"
	if [ $((before & BADGE_HIDDEN)) -ne 0 ]; then
		echo "  cleared      BADGE_HIDDEN (it was hiding the badge)"
	fi
	if [ $((before & BADGE_MASKED)) -ne 0 ]; then
		echo "  cleared      BADGE_MASKED (it was showing lifetime as subscription)"
	fi
	echo
	ensure_badge_patch
	echo
	echo "Reload the client to see it."
}

cmd_revoke() {
	name=$1
	id=$(resolve_user "$name")
	# Mirrors the api's own PREMIUM_CLEAR_FIELDS, which leaves the Visionary
	# sequence alone: it is an identity, not an entitlement.
	psql_ -c "
update fluxer_kv
set row_data = jsonb_set(
      jsonb_set(
        (row_data - 'premium_since' - 'premium_until' - 'premium_gift_extension_ends_at'
                  - 'premium_grace_ends_at' - 'premium_will_cancel' - 'premium_billing_cycle'),
        '{premium_flags}',
        to_jsonb((coalesce((row_data->>'premium_flags')::int, 0)
                  & ~($ENABLED_OVERRIDE | $PURCHASE_DISABLED)))),
      '{premium_type}', to_jsonb(0)),
    updated_at = now()
where $(where_user "$id");" > /dev/null

	psql_ -c "
update fluxer_kv
set row_data = jsonb_set(row_data, '{version}',
      to_jsonb(coalesce((row_data->>'version')::int, 0) + 1))
where $(where_user "$id");" > /dev/null

	echo "$name: premium off. Reload the client."
	echo "The badge patch is left in place; 'fluxer badge-patch --revert' removes it."
}

user='' lifetime=1 action=grant
for a in "$@"; do
	case "$a" in
		--list) action=list ;;
		--off) action=revoke ;;
		--subscriber) lifetime=0 ;;
		--visionary) lifetime=1 ;;
		-h | --help | help) usage; exit 0 ;;
		-*) die "unknown option: $a" ;;
		*) [ -z "$user" ] || die 'give one username'; user=$a ;;
	esac
done

case "$action" in
	list) cmd_list ;;
	grant) [ -n "$user" ] || { usage >&2; exit 2; }; cmd_grant "$user" "$lifetime" ;;
	revoke) [ -n "$user" ] || { usage >&2; exit 2; }; cmd_revoke "$user" ;;
esac
