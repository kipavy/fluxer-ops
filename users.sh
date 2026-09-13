#!/bin/sh
# users.sh - look at accounts from a shell, and the two row edits worth having here.
#
#   users.sh list [--recent N]              every account, oldest first (or the newest N)
#   users.sh show <user> [--reveal]         one account in detail; email and IP masked
#   users.sh staff <user> [--off]           set or clear the STAFF flag
#   users.sh verify-email <user>            mark the email verified
#   users.sh stats [--messages]             users, guilds, channels (+ messages, opt-in)
#
# <user> is a username, or username#tag when the name is shared.
#
# Reads go straight to the KV table. The admin API's equivalents need an admin API key
# minted in the panel (Authorization: Admin <key>) and list through the Meilisearch
# index; the rows are the source of truth.
#
# The two writes mirror what the api does for the same admin action, field for field:
#   staff         AdminUserSecurityService.updateUserFlags  (PATCH /admin/users/:id/flags)
#   verify-email  AdminUserProfileService.verifyUserEmail   (PUT /admin/users/:id/email-verification)
# both of which end in UserAccountRepository.patchAccount -> UserDataRepository.patchUser:
# `row_data || patch`, `version` + 1, `updated_at = now()`. `flags` is a bigint, so it
# is stored as {"__fluxer_type":"bigint","value":"..."} (PostgresKvQueryExecutor
# encodeValue). All paths under fluxer_api/src/api/ upstream.
#
# What a row edit does NOT do, that the admin panel does:
#   - dispatch USER_UPDATE / GUILD_MEMBER_UPDATE, so open clients show the change only
#     after a reload. Server-side checks read Postgres per request and see it at once.
#   - invalidate the users service cache, which serves other people's view of the
#     account; it expires on its own (FLUXER_SVC_CACHE_TTL_MS, 30 s by default).
#   - update the admin panel's search index (Meilisearch) or write an admin audit entry.
#
# Deliberately left out: disable / ban / unban. The api's tempBanUser also terminates
# every session and sends mail, which a row edit cannot do; a "banned" row with live
# sessions is worse than no command. Use the admin panel for those.
#
# Test against a scratch database with PG_CONTAINER=<container> (plain docker exec,
# user and db "fluxer"); unset, it is the deployment's postgres service.
set -eu

FLUXER_DIR=${FLUXER_DIR:-/home/ubuntu/Documents/fluxer}
PG_CONTAINER=${PG_CONTAINER:-}

# UserFlags, from packages/constants/src/UserConstants.ts (a bigint: bit 0..62).
STAFF=1
DISABLED=$((1 << 38))
DELETED=$((1 << 34))
SELF_DELETED=$((1 << 36))
# UserAccountRepository.migratePremiumFlagsInPatch rewrites these on every patch
# (LEGACY_PREMIUM_FLAGS_MASK | LEGACY_DEAD_USER_FLAGS_MASK). A row carrying any of them
# cannot be patched faithfully by a single statement here, so it is refused.
LEGACY_MASK=$(((1 << 37) | (1 << 40) | (1 << 41) | (1 << 42) | (1 << 43) | (1 << 44) | (1 << 45) | (1 << 46) \
	| (1 << 52) | (1 << 54) | (1 << 55) | (1 << 56) | (1 << 58)))
# EMAIL_CLEARABLE_SUSPICIOUS_ACTIVITY_FLAGS, fluxer_api/src/api/auth/AuthEmail.ts.
EMAIL_CLEARABLE=243
# PremiumFlags.ENABLED_OVERRIDE
ENABLED_OVERRIDE=128
# Snowflakes carry their creation time: (id >> 22) + FLUXER_EPOCH, in ms.
EPOCH_MS=1420070400000

die() { printf 'users: %s\n' "$*" >&2; exit 1; }

psql_() {
	if [ -n "$PG_CONTAINER" ]; then
		docker exec -i "$PG_CONTAINER" psql -X -U fluxer -d fluxer -v ON_ERROR_STOP=1 "$@"
	else
		(cd "$FLUXER_DIR" && docker compose exec -T postgres psql -X -U fluxer -d fluxer -v ON_ERROR_STOP=1 "$@")
	fi
}
psql_val() { psql_ -At "$@" | tr -d '\r'; }

usage() {
	cat <<'USAGE'
usage: users.sh list [--recent N]
       users.sh show <user> [--reveal]
       users.sh staff <user> [--off]
       users.sh verify-email <user>
       users.sh stats [--messages]

  <user> is a username, or username#tag when several accounts share the name.
  --reveal shows the email address and last IP unmasked.
  --messages also counts messages; it reads every message row, so it is opt-in.
USAGE
}

# SQL fragments. Only constants and validated numeric ids are ever interpolated.
live="(expires_at is null or expires_at > now())"
# flags has been written as a bigint object; tolerate a bare number or null too.
flags_sql="coalesce(case jsonb_typeof(row_data->'flags')
	when 'object' then row_data->'flags'->>'value'
	when 'number' then row_data->>'flags'
	when 'string' then row_data->>'flags' end, '0')::bigint"
uid_sql="(row_data->'user_id'->>'value')"
tag_sql="(row_data->>'username') || '#' || lpad(row_data->>'discriminator', 4, '0')"
when_sql() { printf "to_char(%s at time zone 'utc', 'YYYY-MM-DD HH24:MI')" "$1"; }
created_sql() { when_sql "to_timestamp(((($1)::bigint >> 22) + $EPOCH_MS) / 1000.0)"; }
date_sql() { printf "(case when jsonb_typeof(row_data->'%s') = 'object' then (row_data->'%s'->>'value')::timestamptz end)" "$1" "$1"; }
set_sql() { printf "(case jsonb_typeof(row_data->'%s') when 'object' then row_data->'%s'->'value' when 'array' then row_data->'%s' else '[]'::jsonb end)" "$1" "$1" "$1"; }

where_user() { printf "table_name = 'users' and %s = '%s'" "$uid_sql" "$1"; }

# Row keys are the app's JSON.stringify of the key columns, joined by \x1f. For a table
# keyed (user_id, ...), every row of one user sits in [key || \x1f, key || ' '), the same
# range PostgresKvQueryExecutor scans, so this rides the primary key instead of reading
# the whole table.
key_prefix_where() {
	k="{\"__fluxer_type\":\"bigint\",\"value\":\"$2\"}"
	printf "table_name = '%s' and row_key collate \"C\" >= '%s' || chr(31) and row_key collate \"C\" < '%s' || ' ' and %s" \
		"$1" "$k" "$k" "$live"
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
	tag_where=''
	[ -z "$tag" ] || tag_where="and (row_data->>'discriminator')::int = $tag"
	rows=$(psql_val -c "
select $uid_sql || '|' || $tag_sql
from fluxer_kv
where table_name = 'users' and lower(row_data->>'username') = lower('$name') $tag_where
order by 1;")
	count=$(printf '%s' "$rows" | grep -c . || true)
	if [ "${count:-0}" -eq 0 ]; then
		die "no account '$arg' ('users.sh list' shows every account)"
	fi
	if [ "$count" -gt 1 ]; then
		echo "users: '$arg' matches $count accounts:" >&2
		printf '%s\n' "$rows" | sed 's/^[^|]*|/  /' >&2
		die "say which one, e.g. '$(printf '%s\n' "$rows" | head -n 1 | sed 's/^[^|]*|//')'"
	fi
	id=${rows%%|*}
	case "$id" in
		'' | *[!0-9]*) die "unexpected user id for '$arg': '$id'" ;;
	esac
	# The api refuses to mutate these synthetic ids (constants/Core.ts assertMutableUserId).
	[ "$id" != 0 ] && [ "$id" != 1 ] || die "'$arg' is a synthetic system account"
	printf '%s\n' "$id"
}

summary_sql="coalesce(nullif(concat_ws(' ',
	case when ($flags_sql & $STAFF) <> 0 then 'staff' end,
	case when jsonb_array_length($(set_sql acls)) > 0 then 'admin' end,
	case when (row_data->>'bot')::boolean then 'bot' end,
	case when (row_data->>'system')::boolean then 'system' end,
	case when coalesce((row_data->>'premium_type')::int, 0) > 0
	       or (coalesce((row_data->>'premium_flags')::int, 0) & $ENABLED_OVERRIDE) <> 0 then 'premium' end,
	case when (row_data->>'email_verified')::boolean then 'verified'
	     when row_data->>'email' is not null then 'unverified' end,
	case when jsonb_array_length($(set_sql authenticator_types)) > 0 then 'mfa' end,
	case when ($flags_sql & $DISABLED) <> 0 then 'DISABLED' end,
	case when $(date_sql temp_banned_until) > now() then 'BANNED' end,
	case when ($flags_sql & ($DELETED | $SELF_DELETED)) <> 0 then 'DELETED'
	     when $(date_sql pending_deletion_at) is not null then 'deleting' end), ''), '-')"

cmd_list() {
	recent=$1
	if [ -n "$recent" ]; then
		inner="order by ($uid_sql)::bigint desc limit $recent"
	else
		inner=''
	fi
	psql_ -c "
select tag as \"user\", created, last_active as \"last active\", summary as flags
from (
	select $tag_sql as tag,
	       $(created_sql "$uid_sql") as created,
	       coalesce($(when_sql "$(date_sql last_active_at)"), '-') as last_active,
	       $summary_sql as summary,
	       ($uid_sql)::bigint as id
	from fluxer_kv
	where table_name = 'users' and $live
	$inner
) u
order by id;"
}

cmd_show() {
	id=$(resolve_user "$1")
	reveal=$2
	if [ "$reveal" -eq 1 ]; then
		email="row_data->>'email'"
		ip="row_data->>'last_active_ip'"
	else
		email="left(split_part(row_data->>'email', '@', 1), 1) || '***@'
			|| left(split_part(row_data->>'email', '@', 2), 1) || '***'
			|| coalesce(substring(split_part(row_data->>'email', '@', 2) from '(\.[^.]+)$'), '')"
		ip="case when row_data->>'last_active_ip' ~ '^[0-9]+\.[0-9]+\.' then substring(row_data->>'last_active_ip' from '^[0-9]+\.[0-9]+\.') || 'x.x'
			when row_data->>'last_active_ip' is not null then 'x:x (--reveal)' end"
	fi
	# Deliberately never selected: password_hash, totp_secret, stripe ids, anything token-like.
	psql_val -c "
with u as (select row_data, $flags_sql as flags from fluxer_kv where $(where_user "$id")),
names(bit, name) as (values
	(0, 'STAFF'), (2, 'PARTNER'), (3, 'BUG_HUNTER'), (4, 'FRIENDLY_BOT'),
	(5, 'FRIENDLY_BOT_MANUAL_APPROVAL'), (6, 'SPAMMER'), (33, 'HIGH_GLOBAL_RATE_LIMIT'),
	(34, 'DELETED'), (35, 'DISABLED_SUSPICIOUS_ACTIVITY'), (36, 'SELF_DELETED'), (38, 'DISABLED'),
	(39, 'HAS_SESSION_STARTED'), (47, 'RATE_LIMIT_BYPASS'), (48, 'REPORT_BANNED'),
	(49, 'VERIFIED_NOT_UNDERAGE'), (51, 'HAS_DISMISSED_PREMIUM_ONBOARDING'),
	(53, 'APP_STORE_REVIEWER'), (57, 'STAFF_HIDDEN'), (60, 'AGE_VERIFIED_ADULT'),
	(61, 'FORCE_INBOUND_PHONE_VERIFICATION'), (62, 'NOT_SUSPICIOUS'))
select line from u, lateral (values
	(1, 'user         ' || $tag_sql),
	(2, 'id           $id'),
	(3, 'display name ' || coalesce(row_data->>'global_name', '-')),
	(4, 'created      ' || $(created_sql "'$id'") || ' UTC'),
	(5, 'last active  ' || coalesce($(when_sql "$(date_sql last_active_at)") || ' UTC', '-')
		|| coalesce('  from ' || ($ip), '')),
	(6, 'email        ' || coalesce(($email) || case when (row_data->>'email_verified')::boolean
		then '  (verified)' else '  (NOT verified)' end, '-')
		|| case when (row_data->>'email_bounced')::boolean then '  BOUNCED' else '' end),
	(7, 'phone        ' || case when (row_data->>'has_verified_phone')::boolean then 'verified' else '-' end),
	(8, 'flags        ' || coalesce((select string_agg(coalesce(n.name, 'bit' || b), ' ' order by b)
		from generate_series(0, 62) b left join names n on n.bit = b
		where (flags & (1::bigint << b)) <> 0), '-') || '  (' || flags || ')'),
	(9, 'admin acls   ' || coalesce((select string_agg(a, ' ' order by a)
		from jsonb_array_elements_text($(set_sql acls)) a), '-')),
	(10, 'premium      ' || case coalesce((row_data->>'premium_type')::int, 0)
		when 2 then 'lifetime, visionary #' || coalesce(row_data->>'premium_lifetime_sequence', '?')
		when 1 then 'subscription' else 'none' end
		|| '  (premium_flags ' || coalesce(row_data->>'premium_flags', '0') || ')'),
	(11, 'mfa          ' || case when jsonb_array_length($(set_sql authenticator_types)) > 0 then 'on' else 'off' end),
	(12, 'status       ' || concat_ws(', ',
		case when (flags & $DISABLED) <> 0 then 'DISABLED' end,
		case when $(date_sql temp_banned_until) > now()
			then 'banned until ' || $(when_sql "$(date_sql temp_banned_until)") || ' UTC' end,
		case when (flags & ($DELETED | $SELF_DELETED)) <> 0 then 'DELETED' end,
		case when $(date_sql pending_deletion_at) is not null
			then 'deletion pending since ' || $(when_sql "$(date_sql pending_deletion_at)") || ' UTC' end,
		case when coalesce((row_data->>'suspicious_activity_flags')::int, 0) <> 0
			then 'suspicious-activity gate ' || (row_data->>'suspicious_activity_flags') end,
		case when (row_data->>'bot')::boolean then 'bot' end)),
	(13, 'locale       ' || coalesce(row_data->>'locale', '-')),
	(14, 'guilds       ' || (select count(*) from fluxer_kv where $(key_prefix_where guild_members_by_user_id "$id"))
		|| ' joined, ' || (select count(*) from fluxer_kv
			where table_name = 'guilds' and $live and row_data->'owner_id'->>'value' = '$id') || ' owned'),
	(15, 'messages     ' || (select count(*) from fluxer_kv where $(key_prefix_where messages_by_author_id_v2 "$id"))
		|| ' authored'),
	(16, 'version      ' || coalesce(row_data->>'version', '-'))
) v(n, line)
order by n;" | sed 's/  *$//; s/^status *$/status       active/'
}

# Refuse rows the app itself would rewrite on this patch; see LEGACY_MASK.
assert_patchable() {
	legacy=$(psql_val -c "select ($flags_sql & $LEGACY_MASK) from fluxer_kv where $(where_user "$1");")
	[ "${legacy:-0}" = 0 ] || die "this account still carries legacy flag bits ($legacy) that the api migrates on write; change it in the admin panel instead"
}

cmd_staff() {
	name=$1 on=$2
	id=$(resolve_user "$name")
	assert_patchable "$id"
	if [ "$on" -eq 1 ]; then
		expr="$flags_sql | $STAFF"
	else
		expr="$flags_sql & ~$STAFF::bigint"
	fi
	before=$(psql_val -c "select $flags_sql from fluxer_kv where $(where_user "$id");")
	if [ $((before & STAFF)) -eq "$on" ]; then
		echo "$name: STAFF already $( [ "$on" -eq 1 ] && echo on || echo off). Nothing changed."
		return 0
	fi
	# One statement: the flags and the version move together, as patchUser writes them.
	after=$(psql_val -c "
update fluxer_kv
set row_data = row_data || jsonb_build_object(
		'flags', jsonb_build_object('__fluxer_type', 'bigint', 'value', ($expr)::text),
		'version', coalesce((row_data->>'version')::int, 0) + 1),
    updated_at = now()
where $(where_user "$id")
returning $flags_sql || ' ' || (row_data->>'version');" | head -n 1)
	# shellcheck disable=SC2086 # split "flags version" into $1 $2
	set -- $after
	printf '%s: STAFF %s.\n' "$name" "$( [ "$on" -eq 1 ] && echo on || echo off)"
	printf '  flags    %s -> %s\n' "$before" "$1"
	printf '  version  %s\n' "$2"
	echo "Open clients show it after a reload; other people's view within ~30 s (users service cache)."
}

cmd_verify_email() {
	name=$1
	id=$(resolve_user "$name")
	assert_patchable "$id"
	state=$(psql_val -c "
select coalesce(row_data->>'email', '') <> '', coalesce((row_data->>'email_verified')::boolean, false),
       coalesce((row_data->>'email_bounced')::boolean, false),
       coalesce((row_data->>'suspicious_activity_flags')::int, 0)
from fluxer_kv where $(where_user "$id");" | tr '|' ' ')
	# shellcheck disable=SC2086 # split the four columns into $1..$4
	set -- $state
	[ "$1" = t ] || die "$name has no email address to verify"
	sus_before=$4
	sus_after=$((sus_before & ~EMAIL_CLEARABLE))
	if [ "$2" = t ] && [ "$3" = f ] && [ "$sus_after" -eq "$sus_before" ]; then
		echo "$name: email already verified. Nothing changed."
		return 0
	fi
	# verifyUserEmail: email_verified true, email_bounced false, and the email-related
	# suspicious-activity gates cleared - only written when that actually changes them.
	psql_ -q -c "
update fluxer_kv
set row_data = row_data || jsonb_build_object('email_verified', true, 'email_bounced', false,
		'version', coalesce((row_data->>'version')::int, 0) + 1)
		|| case when $sus_before <> 0 and $sus_after <> $sus_before
			then jsonb_build_object('suspicious_activity_flags', $sus_after) else '{}'::jsonb end,
    updated_at = now()
where $(where_user "$id");"
	echo "$name: email verified."
	[ "$3" = f ] || echo "  cleared  email_bounced"
	[ "$sus_after" -eq "$sus_before" ] || printf '  suspicious_activity_flags %s -> %s\n' "$sus_before" "$sus_after"
	echo "Open clients show it after a reload."
}

cmd_stats() {
	messages=$1
	day_id="(((extract(epoch from now() - interval '1 day') * 1000)::bigint - $EPOCH_MS) << 22)"
	week_id="(((extract(epoch from now() - interval '7 days') * 1000)::bigint - $EPOCH_MS) << 22)"
	psql_val -F ' ' -c "
select rpad('users', 10), count(*),
       '(' || count(*) filter (where not coalesce((row_data->>'bot')::boolean, false)) || ' people, '
       || count(*) filter (where coalesce((row_data->>'bot')::boolean, false)) || ' bots, '
       || count(*) filter (where ($uid_sql)::bigint >= $day_id) || ' new in 24h, '
       || count(*) filter (where ($uid_sql)::bigint >= $week_id) || ' in 7d)'
from fluxer_kv where table_name = 'users' and $live
union all
select rpad('guilds', 10), count(*),
       '(' || count(*) filter (where (row_data->'guild_id'->>'value')::bigint >= $week_id) || ' new in 7d)'
from fluxer_kv where table_name = 'guilds' and $live
union all
select rpad('channels', 10), count(*),
       '(' || count(*) filter (where row_data->'guild_id' is not null and row_data->'guild_id' <> 'null'::jsonb)
       || ' in guilds, ' || count(*) filter (where row_data->'guild_id' is null or row_data->'guild_id' = 'null'::jsonb)
       || ' DMs/groups)'
from fluxer_kv where table_name = 'channels' and $live
	and not coalesce((row_data->>'soft_deleted')::boolean, false);"
	if [ "$messages" -eq 0 ]; then
		echo "messages   (skipped: add --messages, it reads every message row)"
		return 0
	fi
	# Message ids are snowflakes, so "last 24h" is an id comparison - no timestamp column needed.
	psql_val -F ' ' -c "
select rpad('messages', 10), count(*),
       '(' || count(*) filter (where (row_data->'message_id'->>'value')::bigint >= $day_id) || ' in 24h, '
       || count(*) filter (where (row_data->'message_id'->>'value')::bigint >= $week_id) || ' in 7d)'
from fluxer_kv where table_name = 'messages' and $live;"
}

cmd=${1:-}
[ $# -gt 0 ] && shift || true
user='' off=0 reveal=0 recent='' messages=0
while [ $# -gt 0 ]; do
	case "$1" in
		--off) off=1 ;;
		--reveal) reveal=1 ;;
		--messages) messages=1 ;;
		--recent)
			[ $# -ge 2 ] || die '--recent needs a number'
			recent=$2; shift
			case "$recent" in '' | *[!0-9]*) die "--recent needs a number, not '$recent'" ;; esac
			[ "$recent" -gt 0 ] || die '--recent needs a number above 0' ;;
		-h | --help) usage; exit 0 ;;
		-*) die "unknown option: $1" ;;
		*) [ -z "$user" ] || die 'give one user'; user=$1 ;;
	esac
	shift
done

need_user() { [ -n "$user" ] || { usage >&2; exit 2; }; }
case "$cmd" in
	list) cmd_list "$recent" ;;
	show) need_user; cmd_show "$user" "$reveal" ;;
	staff) need_user; cmd_staff "$user" $((1 - off)) ;;
	verify-email) need_user; cmd_verify_email "$user" ;;
	stats) cmd_stats "$messages" ;;
	help | -h | --help) usage ;;
	'') usage >&2; exit 2 ;;
	*) printf 'users: unknown command: %s\n\n' "$cmd" >&2; usage >&2; exit 2 ;;
esac
