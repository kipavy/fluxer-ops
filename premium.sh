#!/bin/sh
# premium.sh - grant or revoke Plutonium, any length, badge included, in one command.
#
#   premium.sh <user>                   lifetime: Visionary badge and number
#   premium.sh <user> --duration 1m     a set length (Nd, Nw, Nm or Ny); ends on its own
#   premium.sh <user> --subscriber      open-ended, "subscriber since" badge
#   premium.sh <user> --off             revoke
#   premium.sh --list                   who has premium
#   premium.sh --repair                 keep lifetime grants from being stripped (watchdog)
#
# <user> is a username, or username#tag when several accounts share the name.
#
# What has to be true for the badge to appear:
#
#   1. The account needs premium_type set (1 subscription, 2 lifetime). The badge
#      renders off that field. The admin API only toggles PremiumFlags bits -
#      /admin/users/:id/premium-flags - so there is no endpoint for it, and the
#      premium override alone leaves premium_type at 0: perks, no badge.
#   2. The instance has to report premium_enabled, i.e. the admin panel's premium
#      mode is 'mirror'. In 'everyone' mode the client hides premium altogether
#      (shouldShowPremiumFeatures). This script warns when that is the case.
#   3. For lifetime only: the stock client shows the Plutonium badge but hides the
#      "Visionary since" tooltip and the "Visionary ID #n" badge on self-hosted
#      instances. badge-patch.sh brings those back; a lifetime grant applies it.
#
# --duration is a gift code minted and redeemed in one go (gifts.sh create, then
# redeem), so it gets a gift's end-date handling and stacking. Being an admin's grant
# rather than a purchase, it skips the purchase-only refusals (unclaimed account,
# unverified email, PURCHASE_DISABLED) that a gift link is subject to.
#
# Lifetime numbers come from the api's visionary_slots table, as the api's own
# setPremiumLifetime does, so a lifetime gift redeemed in the app and a grant made
# here never hand out the same "Visionary #n". Visionaries granted before slots were
# tracked here are registered into it first.
#
# --repair exists because of an upstream gap. Redeeming a lifetime gift in the app
# (StripePremiumService.setPremiumLifetime) clears premium_until but leaves
# premium_gift_extension_ends_at, so an account that still had a time-limited gift
# running keeps that end date. getEffectivePremiumUntil takes the later of the two,
# and once it is past by more than PREMIUM_GRACE_PERIOD_DAYS (3), the api strips the
# premium on the next session start (shouldStripExpiredPremium) - lifetime included.
# --repair drops every end date from lifetime accounts; watchdog.sh runs it every
# 10 minutes, well inside the 3 days. Grants made by this script never leave one behind.
#
# Values are written in the KV store's own encoding: dates as
# {"value":...,"__fluxer_type":"date"}, plain numbers bare, and `version` (the
# row's optimistic-concurrency counter) bumped, exactly as the app would.
#
# Test against a scratch database with PG_CONTAINER=<container> (plain docker exec,
# user and db "fluxer"); unset, it is the deployment's postgres service.
set -eu

. "$(dirname "$(readlink -f "$0")")/lib.sh"
need_instance
OVERRIDE="$FLUXER_DIR/docker-compose.override.yml"
PG_CONTAINER=${PG_CONTAINER:-}

# PremiumFlags, from packages/constants/src/UserConstants.ts.
BADGE_HIDDEN=2
BADGE_MASKED=4
PURCHASE_DISABLED=64
ENABLED_OVERRIDE=128
PERKS_DISABLED=256

die() { printf 'premium: %s\n' "$*" >&2; exit 1; }

# Plain docker exec, never `docker compose exec`: compose writes its own warnings to
# stderr, which would end up mixed into captured output.
psql_() {
	if [ -z "$PG_CONTAINER" ]; then
		PG_CONTAINER=$(cd "$FLUXER_DIR" && docker compose ps -q postgres 2> /dev/null) || PG_CONTAINER=''
		[ -n "$PG_CONTAINER" ] || die "the postgres service in $FLUXER_DIR is not running"
	fi
	docker exec -i "$PG_CONTAINER" psql -X -q -U fluxer -d fluxer -v ON_ERROR_STOP=1 "$@"
}
psql_val() { psql_ -At "$@" | tr -d '\r'; }

# Errors come back as one line: plpgsql RAISE texts are the refusals.
run_sql() {
	if out=$(psql_ "$@" 2>&1); then
		[ -z "$out" ] || printf '%s\n' "$out" | tr -d '\r'
		return 0
	fi
	printf '%s\n' "$out" | tr -d '\r' \
		| sed -n 's/^psql:[^:]*:[0-9]*: ERROR:  */premium: /p; s/^ERROR:  */premium: /p' >&2
	printf '%s\n' "$out" | grep -q 'ERROR:' || printf '%s\n' "$out" >&2
	exit 1
}

usage() {
	cat <<'USAGE'
usage: premium.sh <user> [--duration D | --subscriber | --off]
       premium.sh --list
       premium.sh --repair

  <user>           grant lifetime Plutonium: Visionary badge and number
  --duration D     grant D of Plutonium instead (Nd, Nw, Nm or Ny); it ends on its
                   own, like a redeemed gift. Stacks onto an earlier time-limited grant.
  --subscriber     grant open-ended Plutonium with the "subscriber since" badge
  --off            revoke premium and the badge
  --list           show every account's premium state
  --repair         drop leftover end dates from lifetime accounts, which would
                   otherwise get them stripped (the watchdog runs it every 10 min)

  <user> is a username, or username#tag when several accounts share the name.
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
       coalesce(to_char(greatest(
                  case when jsonb_typeof(row_data->'premium_until') = 'object'
                       then (row_data->'premium_until'->>'value')::timestamptz end,
                  case when jsonb_typeof(row_data->'premium_gift_extension_ends_at') = 'object'
                       then (row_data->'premium_gift_extension_ends_at'->>'value')::timestamptz end)
                at time zone 'utc', 'YYYY-MM-DD HH24:MI'),
                case when coalesce((row_data->>'premium_type')::int, 0) > 0 then 'never' else '' end) as \"ends (UTC)\",
       case when (coalesce((row_data->>'premium_flags')::int, 0) & $ENABLED_OVERRIDE) <> 0
            then 'yes' else 'no' end as override,
       case when (coalesce((row_data->>'premium_flags')::int, 0) & $BADGE_HIDDEN) <> 0
            then 'HIDDEN' else '' end as badge_hidden
from fluxer_kv
where table_name = 'users' and (expires_at is null or expires_at > now())
order by username, tag;"
}

# Resolve <user> to its numeric id. Anything ambiguous is rejected, never guessed.
resolve_user() {
	arg=$1 name=${1%%#*} tag=''
	case "$arg" in *'#'*) tag=${arg#*#} ;; esac
	case "$name" in
		'' | *[!A-Za-z0-9._-]*) die "not a valid username: '$arg'" ;;
	esac
	case "$tag" in
		*[!0-9]*) die "not a valid tag: '$arg'" ;;
	esac
	[ ${#tag} -le 4 ] || die "not a valid tag: '$arg'"
	rows=$(run_sql -At -v name="$name" -v tag="${tag:--1}" <<'SQL'
select (row_data->'user_id'->>'value') || '|' || (row_data->>'username') || '#'
       || lpad(row_data->>'discriminator', 4, '0')
from fluxer_kv
where table_name = 'users' and (expires_at is null or expires_at > now())
  and lower(row_data->>'username') = lower(:'name')
  and (:'tag'::int < 0 or (row_data->>'discriminator')::int = :'tag'::int)
order by 1;
SQL
)
	count=$(printf '%s' "$rows" | grep -c . || true)
	[ "${count:-0}" -gt 0 ] || die "no account '$arg' ('fluxer users list' shows every account)"
	if [ "$count" -gt 1 ]; then
		echo "premium: '$arg' matches $count accounts:" >&2
		printf '%s\n' "$rows" | sed 's/^[^|]*|/  /' >&2
		die "say which one, e.g. '$(printf '%s\n' "$rows" | head -n 1 | sed 's/^[^|]*|//')'"
	fi
	id=${rows%%|*}
	case "$id" in
		'' | *[!0-9]*) die "unexpected user id for '$arg': '$id'" ;;
	esac
	[ "$id" != 0 ] && [ "$id" != 1 ] || die "'$arg' is a synthetic system account"
	printf '%s\n' "$id"
}

badge_patch_applied() {
	[ -f "$OVERRIDE" ] && head -n 1 "$OVERRIDE" | grep -q 'badge-patch.sh'
}

ensure_badge_patch() {
	if badge_patch_applied; then
		echo "Visionary badge patch: already applied."
		return 0
	fi
	echo "Visionary badge patch: not applied yet, applying it now."
	echo
	"$OPS/badge-patch.sh" || echo "premium: the badge patch did not apply; premium is granted, only the Visionary extras are missing" >&2
}

# The client shows no premium at all unless the instance reports premium_enabled
# (admin panel, premium mode 'mirror'). Silent when the check itself cannot run.
warn_if_premium_hidden() {
	domain=$(sed -n 's/^FLUXER_DOMAIN=//p' "$FLUXER_DIR/.env" 2> /dev/null | head -n 1 | tr -d '\r"' | sed "s/'//g")
	domain=${domain#*://}
	[ -n "$domain" ] || return 0
	wk=$(curl -s --max-time 10 "https://${domain%/}/.well-known/fluxer" 2> /dev/null) || return 0
	case "$wk" in
		*'"premium_enabled":false'*)
			echo
			echo "WARNING: this instance reports premium_enabled=false (premium mode 'everyone')."
			echo "  Clients hide every premium badge in that mode. Set premium mode to 'mirror'"
			echo "  in the admin panel's instance settings for the badge to show."
			;;
	esac
}

cmd_grant_lifetime() {
	id=$1 label=$2
	before=$(psql_val -v id="$id" <<'SQL'
select coalesce(row_data->>'premium_flags', '0')
from fluxer_kv where table_name = 'users' and row_key = '{"__fluxer_type":"bigint","value":"' || :'id' || '"}';
SQL
)
	run_sql -v id="$id" -v override="$ENABLED_OVERRIDE" -v strip="$((PERKS_DISABLED | BADGE_HIDDEN | BADGE_MASKED))" <<'SQL'
\set VERBOSITY terse
begin;
select set_config('fluxer_premium.user_id', :'id', true) is null as unused1,
       set_config('fluxer_premium.override', :'override', true) is null as unused2,
       set_config('fluxer_premium.strip', :'strip', true) is null as unused3 \gset
do $$
declare
	v_uid text := current_setting('fluxer_premium.user_id');
	v_ukey text := '{"__fluxer_type":"bigint","value":"' || current_setting('fluxer_premium.user_id') || '"}';
	v_now timestamptz := date_trunc('milliseconds', now());
	u jsonb;
	seq int;
	owner text;
begin
	select row_data into u from fluxer_kv
	where table_name = 'users' and row_key = v_ukey and (expires_at is null or expires_at > now())
	for update;
	if u is null then
		raise exception 'no account with id %', v_uid;
	end if;
	if coalesce((u->>'bot')::boolean, false) then
		raise exception 'bots cannot hold premium';
	end if;

	-- Serialise slot allocation against any other grant in flight.
	perform pg_advisory_xact_lock(hashtext('fluxer visionary_slots'));

	-- Register every Visionary number already handed out - including on accounts
	-- revoked since, as the number is theirs for good - so the api never allocates
	-- one of them again. An existing slot always wins.
	insert into fluxer_kv (table_name, partition_key, row_key, row_data, expires_at, updated_at)
	select distinct on (s.seq) 'visionary_slots', s.seq::text, s.seq::text,
	       jsonb_build_object('slot_index', s.seq,
	           'user_id', jsonb_build_object('__fluxer_type', 'bigint', 'value', s.uid)),
	       null, now()
	from (select (row_data->>'premium_lifetime_sequence')::int as seq,
	             row_data->'user_id'->>'value' as uid
	      from fluxer_kv
	      where table_name = 'users'
	        and row_data->>'premium_lifetime_sequence' ~ '^[0-9]+$') s
	order by s.seq, s.uid
	on conflict (table_name, row_key) do nothing;

	-- StripePremiumService.setPremiumLifetime: keep the account's number if it has
	-- one, else allocateVisionarySequence: its reserved slot, else the lowest free
	-- slot, else a new one after the highest.
	if (u->>'premium_lifetime_sequence') ~ '^[0-9]+$' then
		seq := (u->>'premium_lifetime_sequence')::int;
	end if;
	if seq is null then
		select (row_data->>'slot_index')::int into seq from fluxer_kv
		where table_name = 'visionary_slots' and row_data->'user_id'->>'value' = v_uid
		order by 1 limit 1;
	end if;
	if seq is null then
		select (row_data->>'slot_index')::int into seq from fluxer_kv
		where table_name = 'visionary_slots' and coalesce(jsonb_typeof(row_data->'user_id'), 'null') = 'null'
		order by 1 limit 1;
	end if;
	if seq is null then
		select coalesce(max((row_data->>'slot_index')::int), 0) + 1 into seq
		from fluxer_kv where table_name = 'visionary_slots';
	end if;

	select row_data->'user_id'->>'value' into owner from fluxer_kv
	where table_name = 'visionary_slots' and row_key = seq::text;
	if owner is not null and owner <> v_uid then
		raise exception 'Visionary #% is also held by account %; fix the duplicate number by hand first', seq, owner;
	end if;
	insert into fluxer_kv as kv (table_name, partition_key, row_key, row_data, expires_at, updated_at)
	values ('visionary_slots', seq::text, seq::text,
	        jsonb_build_object('slot_index', seq,
	            'user_id', jsonb_build_object('__fluxer_type', 'bigint', 'value', v_uid)),
	        null, now())
	on conflict (table_name, row_key) do update
	set row_data = excluded.row_data, expires_at = null, updated_at = now();

	-- The grant. ENABLED_OVERRIDE on and PERKS_DISABLED off are the perks;
	-- BADGE_HIDDEN and BADGE_MASKED off, because they suppress or downgrade the
	-- badge. premium_until and premium_gift_extension_ends_at go: with neither, the
	-- server (checkHasActivePaidPremium) and the client (isPremiumExpiredLocally)
	-- read "never expires", and a leftover gift end would otherwise strip this grant
	-- the day it passes.
	update fluxer_kv
	set row_data = (row_data - 'premium_until' - 'premium_gift_extension_ends_at'
	                         - 'premium_grace_ends_at' - 'premium_will_cancel')
	    || jsonb_build_object(
	         'user_id', u->'user_id',
	         'premium_type', 2,
	         'premium_flags', (coalesce((u->>'premium_flags')::int, 0)
	                           | current_setting('fluxer_premium.override')::int)
	                          & ~current_setting('fluxer_premium.strip')::int,
	         'premium_since', case when jsonb_typeof(u->'premium_since') = 'object' then u->'premium_since'
	             else jsonb_build_object('__fluxer_type', 'date',
	                 'value', to_char(v_now at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')) end,
	         'premium_lifetime_sequence', seq,
	         'version', coalesce((u->>'version')::int, 0) + 1),
	    updated_at = now()
	where table_name = 'users' and row_key = v_ukey;
end
$$;
commit;
SQL

	after=$(psql_val -v id="$id" <<'SQL'
select (row_data->>'premium_type') || ' ' || (row_data->>'premium_flags') || ' '
       || coalesce(row_data->>'premium_lifetime_sequence', '-')
from fluxer_kv where table_name = 'users' and row_key = '{"__fluxer_type":"bigint","value":"' || :'id' || '"}';
SQL
)
	# shellcheck disable=SC2086 # split "type flags seq" into $1..$3
	set -- $after
	echo "$label: lifetime premium on."
	printf '  badge        Visionary #%s\n' "$3"
	printf '  premium_type %s\n' "$1"
	printf '  flags        %s -> %s\n' "$before" "$2"
	[ $((before & BADGE_HIDDEN)) -eq 0 ] || echo "  cleared      BADGE_HIDDEN (it was hiding the badge)"
	[ $((before & BADGE_MASKED)) -eq 0 ] || echo "  cleared      BADGE_MASKED (it was showing lifetime as subscription)"
	echo
	if [ -z "${PREMIUM_SKIP_BADGE_PATCH:-}" ]; then
		ensure_badge_patch
		echo
	fi
	warn_if_premium_hidden
	echo "Reload the client to see it."
}

cmd_grant_subscriber() {
	id=$1 label=$2
	before=$(psql_val -v id="$id" <<'SQL'
select coalesce(row_data->>'premium_flags', '0')
from fluxer_kv where table_name = 'users' and row_key = '{"__fluxer_type":"bigint","value":"' || :'id' || '"}';
SQL
)
	run_sql -v id="$id" -v override="$ENABLED_OVERRIDE" -v strip="$((PERKS_DISABLED | BADGE_HIDDEN | BADGE_MASKED))" <<'SQL'
\set VERBOSITY terse
begin;
update fluxer_kv
set row_data = (row_data - 'premium_until' - 'premium_gift_extension_ends_at'
                         - 'premium_grace_ends_at' - 'premium_will_cancel')
    || jsonb_build_object(
         'premium_type', 1,
         'premium_flags', (coalesce((row_data->>'premium_flags')::int, 0) | :'override'::int) & ~:'strip'::int,
         'premium_since', case when jsonb_typeof(row_data->'premium_since') = 'object' then row_data->'premium_since'
             else jsonb_build_object('__fluxer_type', 'date',
                 'value', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')) end,
         'version', coalesce((row_data->>'version')::int, 0) + 1),
    updated_at = now()
where table_name = 'users' and row_key = '{"__fluxer_type":"bigint","value":"' || :'id' || '"}';
commit;
SQL
	after=$(psql_val -v id="$id" <<'SQL'
select (row_data->>'premium_type') || ' ' || (row_data->>'premium_flags')
from fluxer_kv where table_name = 'users' and row_key = '{"__fluxer_type":"bigint","value":"' || :'id' || '"}';
SQL
)
	# shellcheck disable=SC2086
	set -- $after
	echo "$label: open-ended premium on."
	printf '  badge        Plutonium, subscriber since\n'
	printf '  premium_type %s\n' "$1"
	printf '  flags        %s -> %s\n' "$before" "$2"
	warn_if_premium_hidden
	echo "Reload the client to see it."
}

# A set length is a gift minted and redeemed on the spot, so it gets the api's own
# gift rules: stacking after a running gift, the end date, the refusals.
cmd_grant_duration() {
	user=$1 duration=$2
	case "$duration" in
		lifetime | visionary) die "--duration $duration is the default; drop --duration for lifetime" ;;
	esac
	code=$("$OPS/gifts.sh" create --duration "$duration" --quiet) || exit 1
	if ! GIFTS_DIRECT=1 "$OPS/gifts.sh" redeem "$code" "$user"; then
		"$OPS/gifts.sh" revoke "$code" > /dev/null 2>&1 || true
		die "nothing granted (the minted code was revoked)"
	fi
	warn_if_premium_hidden
}

cmd_revoke() {
	id=$1 label=$2
	# Mirrors the api's own PREMIUM_CLEAR_FIELDS, which leaves the Visionary
	# sequence (and its slot) alone: it is an identity, not an entitlement.
	run_sql -v id="$id" -v clear="$((ENABLED_OVERRIDE | PURCHASE_DISABLED))" <<'SQL'
\set VERBOSITY terse
begin;
update fluxer_kv
set row_data = (row_data - 'premium_since' - 'premium_until' - 'premium_gift_extension_ends_at'
                         - 'premium_grace_ends_at' - 'premium_will_cancel' - 'premium_billing_cycle')
    || jsonb_build_object(
         'premium_type', 0,
         'premium_flags', coalesce((row_data->>'premium_flags')::int, 0) & ~:'clear'::int,
         'version', coalesce((row_data->>'version')::int, 0) + 1),
    updated_at = now()
where table_name = 'users' and row_key = '{"__fluxer_type":"bigint","value":"' || :'id' || '"}';
commit;
SQL
	echo "$label: premium off. Reload the client."
}

# Lifetime has no end. Any end date on a lifetime account is a leftover (see the
# header) that would get the account stripped, so remove them all. Also keeps
# visionary_slots in step with the accounts, before the api allocates from it: every
# lifetime number is registered, and an empty table gets a free slot 1, because the
# api's allocateVisionarySequence would otherwise start at #0 and then hand out #1
# again (expandVisionarySlots counts from 0 when the table is empty). Quiet when
# there is nothing to do, so cron stays silent.
cmd_repair() {
	fixed=$(run_sql -At <<'SQL'
\set VERBOSITY terse
begin;
select pg_advisory_xact_lock(hashtext('fluxer visionary_slots')) is null as unused \gset
insert into fluxer_kv (table_name, partition_key, row_key, row_data, expires_at, updated_at)
select distinct on (s.seq) 'visionary_slots', s.seq::text, s.seq::text,
       jsonb_build_object('slot_index', s.seq,
           'user_id', jsonb_build_object('__fluxer_type', 'bigint', 'value', s.uid)),
       null, now()
from (select (row_data->>'premium_lifetime_sequence')::int as seq,
             row_data->'user_id'->>'value' as uid
      from fluxer_kv
      where table_name = 'users'
        and row_data->>'premium_lifetime_sequence' ~ '^[0-9]+$') s
order by s.seq, s.uid
on conflict (table_name, row_key) do nothing;
insert into fluxer_kv (table_name, partition_key, row_key, row_data, expires_at, updated_at)
select 'visionary_slots', '1', '1', jsonb_build_object('slot_index', 1, 'user_id', null), null, now()
where not exists (select 1 from fluxer_kv where table_name = 'visionary_slots');
with fixed as (
	update fluxer_kv
	set row_data = (row_data - 'premium_until' - 'premium_gift_extension_ends_at' - 'premium_grace_ends_at')
	    || jsonb_build_object('version', coalesce((row_data->>'version')::int, 0) + 1),
	    updated_at = now()
	where table_name = 'users' and (row_data->>'premium_type') = '2'
	  and (coalesce(jsonb_typeof(row_data->'premium_until'), 'null') <> 'null'
	       or coalesce(jsonb_typeof(row_data->'premium_gift_extension_ends_at'), 'null') <> 'null'
	       or coalesce(jsonb_typeof(row_data->'premium_grace_ends_at'), 'null') <> 'null')
	returning (row_data->>'username') || '#' || lpad(row_data->>'discriminator', 4, '0') as who
)
select who from fixed order by 1;
commit;
SQL
)
	[ -z "$fixed" ] && return 0
	printf '%s\n' "$fixed" | while IFS= read -r who; do
		echo "repaired $who: lifetime account had a leftover end date, which is now removed"
	done
}

user='' mode=lifetime duration=''
while [ $# -gt 0 ]; do
	case "$1" in
		--list) mode=list ;;
		--repair) mode=repair ;;
		--off) mode=revoke ;;
		--subscriber) mode=subscriber ;;
		--visionary | --lifetime) mode=lifetime ;;
		--duration) [ $# -ge 2 ] || die '--duration needs a value'; mode=duration; duration=$2; shift ;;
		--duration=*) mode=duration; duration=${1#*=} ;;
		-h | --help | help) usage; exit 0 ;;
		-*) die "unknown option: $1" ;;
		*) [ -z "$user" ] || die 'give one user'; user=$1 ;;
	esac
	shift
done

case "$mode" in
	list) cmd_list; exit 0 ;;
	repair) cmd_repair; exit 0 ;;
esac
[ -n "$user" ] || { usage >&2; exit 2; }
case "$mode" in
	duration) cmd_grant_duration "$user" "$duration" ;;
	lifetime) cmd_grant_lifetime "$(resolve_user "$user")" "$user" ;;
	subscriber) cmd_grant_subscriber "$(resolve_user "$user")" "$user" ;;
	revoke) cmd_revoke "$(resolve_user "$user")" "$user" ;;
esac
