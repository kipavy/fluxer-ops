#!/bin/sh
# gifts.sh - Plutonium gift codes on a self-hosted instance: mint, list, revoke, redeem.
#
#   gifts.sh create [--duration 1m] [--count N]   mint codes (Nd, Nw, Nm or Ny)
#   gifts.sh list [--unredeemed | --redeemed | --revoked]
#   gifts.sh show <code>
#   gifts.sh revoke <code>                        only while unredeemed
#   gifts.sh redeem <code> <user>                 apply one to an account
#
# Upstream has gift codes, but a self-hosted instance can neither mint nor redeem them:
#
#   - POST /admin/gift-codes throws FeatureNotAvailableSelfHostedError when
#     instance.self_hosted is set, and the admin panel's /gift-codes page redirects to
#     the dashboard (admin/controllers/CodesAdminController.ts, fluxer_admin/src/routes/codes.rs).
#   - GET /gifts/:code and POST /gifts/:code/redeem live in StripeController, which
#     app/ControllerRegistry.ts only mounts when self_hosted is off. The instance
#     answers {"code":"NOT_FOUND"} - a missing route, not UNKNOWN_GIFT_CODE - so a
#     /gift/<code> link opens in the app and says the code does not exist.
#
# So this script does, row for row, what the api would have done, and both halves are
# commands here rather than links. What it mirrors (fluxer_api/src/api/ upstream,
# checked against the source shipped in the running fluxer-api image):
#
#   create  AdminCodeGenerationService.generateGiftCodes -> GiftCodeRepository.createGiftCode:
#           a 'gift_codes' row (code = RandomUtils.randomString(32) over A-Za-z0-9,
#           created_by SYSTEM_USER_ID 0, version 1) plus its 'gift_codes_by_creator' row.
#   revoke  GiftCodeRepository.revokeGiftCode: revoked_at = now. Revoked codes read as
#           unknown everywhere (StripeGiftService.getGiftCode).
#   redeem  StripeGiftService.redeemGiftCode, on the path a self-hosted instance takes
#           (no Stripe client, so nothing to stack onto): the code gets redeemed_by and
#           redeemed_at plus a 'gift_codes_by_redeemer' row, and the account goes through
#           StripePremiumService.extendPremiumByGift ->
#           UserAccountRepository.patchUpsert -> UserDataRepository.patchUser:
#             premium_gift_extension_ends_at  max(now, premium_until, that field) + duration
#                                             (addGiftCodeDuration: days/weeks exact,
#                                             months/years clamped to the month's end)
#             premium_grace_ends_at           cleared, if it was set
#             premium_type, premium_since     1 and (existing or now), only if type was 0
#             version                         + 1
#           with the same refusals: revoked or redeemed code, unclaimed account,
#           unverified email, PURCHASE_DISABLED, bot, or an account already on lifetime.
#           The api does the two writes one after the other and undoes the first if the
#           second fails; here they are one transaction.
#
# Not done, deliberately:
#   - lifetime (Visionary) gifts. Upstream can only mint them from a Stripe checkout,
#     and redeeming one allocates a visionary_slots row and joins the Visionaries
#     guild, neither of which exists here. 'fluxer premium <user>' is the lifetime path.
#   - a note or label. The row has no such field and the api would never read one.
#   - redeeming onto an open-ended grant from 'fluxer premium --subscriber' (type 1, no
#     end date). The api would accept it, but it would give that grant an end date:
#     once the gift runs out, the api strips premium on the next session start or
#     profile view (shouldStripExpiredPremium), badge included.
#
# A gift expires on its own: nothing needs to run when it ends. Like any row edit, no
# USER_UPDATE is dispatched, so open clients show the change after a reload.
#
# Test against a scratch database with PG_CONTAINER=<container> (plain docker exec,
# user and db "fluxer"); unset, it is the deployment's postgres service.
set -eu

. "$(dirname "$(readlink -f "$0")")/lib.sh"
need_instance
PG_CONTAINER=${PG_CONTAINER:-}
OVERRIDE="$FLUXER_DIR/docker-compose.override.yml"

# GiftCodeConstants.ts and AdminCodeGenerationService.ts.
CODE_LENGTH=32
MAX_COUNT=100
MAX_QUANTITY=3650

die() { printf 'gifts: %s\n' "$*" >&2; exit 1; }

psql_() {
	if [ -n "$PG_CONTAINER" ]; then
		docker exec -i "$PG_CONTAINER" psql -X -q -U fluxer -d fluxer -v ON_ERROR_STOP=1 "$@"
	else
		(cd "$FLUXER_DIR" && docker compose exec -T postgres psql -X -q -U fluxer -d fluxer -v ON_ERROR_STOP=1 "$@")
	fi
}

# Every query is a quoted heredoc on stdin and every input goes in as a psql variable
# (:'name' is quoted by psql itself), so nothing typed on the command line is ever
# spliced into SQL by the shell. Inputs are validated before that anyway. Errors come
# back as one line: plpgsql RAISE texts are the refusals, written for this output.
run_sql() {
	if out=$(psql_ "$@" 2>&1); then
		[ -z "$out" ] || printf '%s\n' "$out" | tr -d '\r'
		return 0
	fi
	printf '%s\n' "$out" | tr -d '\r' \
		| sed -n 's/^psql:[^:]*:[0-9]*: ERROR:  */gifts: /p; s/^ERROR:  */gifts: /p' >&2
	printf '%s\n' "$out" | grep -q 'ERROR:' || printf '%s\n' "$out" >&2
	exit 1
}

usage() {
	cat <<'USAGE'
usage: gifts.sh create [--duration 1m] [--count N]
       gifts.sh list [--unredeemed | --redeemed | --revoked]
       gifts.sh show <code>
       gifts.sh revoke <code>
       gifts.sh redeem <code> <user>

  create      mint N codes (default 1, at most 100), each worth --duration of
              Plutonium: Nd, Nw, Nm or Ny, N from 1 to 3650 (default 1m)
  list        every code, newest first, or only the ones in one state
  show        one code in detail
  revoke      make an unredeemed code unusable
  redeem      apply a code to an account, as the app would have

  <code> is the 32-character code, or a link ending in it.
  <user> is a username, or username#tag when several accounts share the name.

Gift links do not work on a self-hosted instance (the api does not mount /gifts),
so codes are handed out as codes and redeemed here. Lifetime gifts are not
supported: use 'fluxer premium <user>' for Visionary.
USAGE
}

# Accepts the bare code or anything ending in /<code>, so a pasted link works too.
parse_code() {
	c=${1##*/}
	case "$c" in
		*[!A-Za-z0-9]*) die "not a gift code: '$1'" ;;
	esac
	[ ${#c} -eq "$CODE_LENGTH" ] || die "not a gift code: '$1' (codes are $CODE_LENGTH letters and digits)"
	printf '%s\n' "$c"
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
		echo "gifts: '$arg' matches $count accounts:" >&2
		printf '%s\n' "$rows" | sed 's/^[^|]*|/  /' >&2
		die "say which one, e.g. '$(printf '%s\n' "$rows" | head -n 1 | sed 's/^[^|]*|//')'"
	fi
	id=${rows%%|*}
	case "$id" in
		'' | *[!0-9]*) die "unexpected user id for '$arg': '$id'" ;;
	esac
	# constants/Core.ts assertMutableUserId: the api never writes these synthetic ids.
	[ "$id" != 0 ] && [ "$id" != 1 ] || die "'$arg' is a synthetic system account"
	printf '%s\n' "$id"
}

cmd_create() {
	duration=$1 count=$2
	case "$duration" in
		lifetime | visionary) die "lifetime gifts are not supported; 'fluxer premium <user>' grants Visionary" ;;
		'' | *[!0-9dwmy]* | [dwmy]* | *[dwmy]*[0-9dwmy] | *[0-9]) die "not a duration: '$duration' (Nd, Nw, Nm or Ny)" ;;
	esac
	qty=${duration%?}
	case "$duration" in
		*d) unit=days ;;
		*w) unit=weeks ;;
		*m) unit=months ;;
		*y) unit=years ;;
	esac
	# Strip leading zeros so the shell does not read the number as octal.
	qty=$(printf '%s' "$qty" | sed 's/^0*//')
	[ -n "$qty" ] && [ ${#qty} -le 4 ] && [ "$qty" -ge 1 ] && [ "$qty" -le "$MAX_QUANTITY" ] \
		|| die "duration must be 1 to $MAX_QUANTITY $unit"
	case "$count" in
		'' | *[!0-9]*) die "not a count: '$count'" ;;
	esac
	count=$(printf '%s' "$count" | sed 's/^0*//')
	[ -n "$count" ] && [ ${#count} -le 3 ] && [ "$count" -ge 1 ] && [ "$count" -le "$MAX_COUNT" ] \
		|| die "count must be 1 to $MAX_COUNT"

	# mapGiftCodeDurationToMonths: months and years also carry duration_months,
	# days and weeks store null there.
	case "$unit" in
		months) months=$qty ;;
		years) months=$((qty * 12)) ;;
		*) months=null ;;
	esac

	# RandomUtils.randomString draws uniformly from A-Za-z0-9 with crypto.getRandomValues;
	# secrets.choice is the same distribution from the OS CSPRNG.
	codes=$(python3 - "$count" "$CODE_LENGTH" <<'PY'
import secrets, string, sys
count, length = int(sys.argv[1]), int(sys.argv[2])
alphabet = string.ascii_uppercase + string.ascii_lowercase + string.digits
seen, out = set(), []
while len(out) < count:
    code = ''.join(secrets.choice(alphabet) for _ in range(length))
    if code not in seen:
        seen.add(code)
        out.append(code)
print(' '.join(out))
PY
)
	for c in $codes; do parse_code "$c" > /dev/null; done

	# One transaction. A plain INSERT, not the api's upsert: a code that somehow already
	# exists fails the whole batch instead of being merged into, and nothing is written.
	if ! out=$(psql_ -At -v codes="$codes" -v unit="$unit" -v qty="$qty" -v months="$months" 2>&1 <<'SQL'
\set VERBOSITY terse
begin;
with input as (
	select code, n from unnest(string_to_array(:'codes', ' ')) with ordinality as t(code, n)
), stamp as (
	select jsonb_build_object('__fluxer_type', 'date',
		'value', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')) as created_at
), gift as (
	insert into fluxer_kv (table_name, partition_key, row_key, row_data, expires_at, updated_at)
	select 'gift_codes', '"' || code || '"', '"' || code || '"',
	       jsonb_build_object(
	         'code', code,
	         'duration_months', :'months'::jsonb,
	         'duration_type', :'unit',
	         'duration_quantity', :'qty'::int,
	         'created_at', stamp.created_at,
	         'created_by_user_id', jsonb_build_object('__fluxer_type', 'bigint', 'value', '0'),
	         'redeemed_at', null,
	         'redeemed_by_user_id', null,
	         'stripe_payment_intent_id', null,
	         'visionary_sequence_number', null,
	         'checkout_session_id', null,
	         'version', 1,
	         'revoked_at', null),
	       null, now()
	from input, stamp
	returning row_data->>'code' as code
), creator as (
	insert into fluxer_kv as kv (table_name, partition_key, row_key, row_data, expires_at, updated_at)
	select 'gift_codes_by_creator',
	       '{"__fluxer_type":"bigint","value":"0"}' || chr(31) || '"' || code || '"',
	       '{"__fluxer_type":"bigint","value":"0"}' || chr(31) || '"' || code || '"',
	       jsonb_build_object('created_by_user_id', jsonb_build_object('__fluxer_type', 'bigint', 'value', '0'),
	                          'code', code),
	       null, now()
	from gift
	on conflict (table_name, row_key) do update
	set partition_key = excluded.partition_key, row_data = kv.row_data || excluded.row_data,
	    expires_at = excluded.expires_at, updated_at = now()
	returning 1
)
select (select count(*) from gift) || ' ' || (select count(*) from creator);
commit;
SQL
); then
		case "$out" in
			*duplicate\ key*) die "a generated code already exists (astronomically unlikely); nothing was written, run it again" ;;
		esac
		printf '%s\n' "$out" | tr -d '\r' >&2
		die "nothing was written"
	fi
	[ "$(printf '%s' "$out" | tr -d '\r')" = "$count $count" ] || die "unexpected result '$out'; check 'gifts.sh list'"

	label="$qty ${unit%s}"
	[ "$qty" -eq 1 ] || label="$qty $unit"
	if [ "$count" -eq 1 ]; then
		printf 'Created 1 gift code: %s of Plutonium.\n\n' "$label"
	else
		printf 'Created %s gift codes: %s of Plutonium each.\n\n' "$count" "$label"
	fi
	for c in $codes; do printf '  %s\n' "$c"; done
	cat <<'EOF'

Redeem one for an account with:
  fluxer gifts redeem <code> <user>

Hand out the code itself, not a /gift/ link: the api does not mount the gift routes on
a self-hosted instance, so the app would report the link as an unknown gift.
EOF
}

# Shared SQL for list and show, as a view over the rows: status, duration label, and
# the redeemer's name (users are keyed by the JSON of their bigint id).
GIFTS_CTE="with g as (
	select row_data as r, row_data->>'code' as code,
	       (row_data->'created_at'->>'value')::timestamptz as created_at,
	       case when jsonb_typeof(row_data->'redeemed_at') = 'object'
	            then (row_data->'redeemed_at'->>'value')::timestamptz end as redeemed_at,
	       case when jsonb_typeof(row_data->'revoked_at') = 'object'
	            then (row_data->'revoked_at'->>'value')::timestamptz end as revoked_at,
	       row_data->'redeemed_by_user_id'->>'value' as redeemer_id,
	       row_data->'created_by_user_id'->>'value' as creator_id,
	       coalesce(row_data->>'duration_type',
	                case when (row_data->>'duration_months')::int % 12 = 0
	                      and (row_data->>'duration_months')::int <> 0 then 'years' else 'months' end) as unit,
	       coalesce((row_data->>'duration_quantity')::int,
	                case when (row_data->>'duration_months')::int % 12 = 0
	                      and (row_data->>'duration_months')::int <> 0
	                     then (row_data->>'duration_months')::int / 12
	                     else (row_data->>'duration_months')::int end) as qty
	from fluxer_kv
	where table_name = 'gift_codes' and (expires_at is null or expires_at > now())
), v as (
	select g.*,
	       case when revoked_at is not null then 'revoked'
	            when redeemer_id is not null then 'redeemed'
	            else 'unredeemed' end as status,
	       case when qty = 0 then 'lifetime'
	            when qty = 1 then '1 ' || rtrim(unit, 's')
	            else qty || ' ' || unit end as duration,
	       coalesce((select (u.row_data->>'username') || '#' || lpad(u.row_data->>'discriminator', 4, '0')
	                 from fluxer_kv u
	                 where u.table_name = 'users'
	                   and u.row_key = '{\"__fluxer_type\":\"bigint\",\"value\":\"' || redeemer_id || '\"}'),
	                redeemer_id) as redeemer
	from g
)"

when_fmt="'YYYY-MM-DD HH24:MI'"

cmd_list() {
	filter=$1
	sql="$GIFTS_CTE
select code, duration, status,
       to_char(created_at at time zone 'utc', $when_fmt) as created,
       coalesce(redeemer, '') as \"redeemed by\",
       coalesce(to_char(coalesce(redeemed_at, revoked_at) at time zone 'utc', $when_fmt), '') as \"when\"
from v
where :'filter' = 'all' or status = :'filter'
order by created_at desc, code;"
	printf '%s\n' "$sql" | run_sql -v filter="$filter"
	echo "(times UTC)"
}

cmd_show() {
	code=$(parse_code "$1")
	sql="$GIFTS_CTE
select rpad(k, 12) || val from v,
lateral (values
	(1, 'code', code),
	(2, 'status', status),
	(3, 'duration', duration),
	(4, 'created', to_char(created_at at time zone 'utc', $when_fmt) || ' UTC'
	               || case when creator_id = '0' then ' (system)' else ' by ' || creator_id end),
	(5, 'redeemed by', redeemer || coalesce(' (' || redeemer_id || ')', '')),
	(6, 'redeemed', to_char(redeemed_at at time zone 'utc', $when_fmt) || ' UTC'),
	(7, 'revoked', to_char(revoked_at at time zone 'utc', $when_fmt) || ' UTC'),
	(8, 'version', r->>'version')
) l(n, k, val)
where code = :'code' and val is not null
order by n;"
	out=$(printf '%s\n' "$sql" | run_sql -At -v code="$code")
	[ -n "$out" ] || die "no gift code '$code'"
	printf '%s\n' "$out"
}

cmd_revoke() {
	code=$(parse_code "$1")
	run_sql -v code="$code" <<'SQL'
\set VERBOSITY terse
begin;
select set_config('fluxer_gifts.code', :'code', true) is null as unused \gset
do $$
declare
	v_code text := current_setting('fluxer_gifts.code');
	g jsonb;
begin
	select row_data into g from fluxer_kv
	where table_name = 'gift_codes' and row_key = '"' || v_code || '"'
	  and (expires_at is null or expires_at > now())
	for update;
	if g is null then
		raise exception 'no gift code ''%''', v_code;
	end if;
	if jsonb_typeof(g->'revoked_at') = 'object' then
		raise exception 'gift code ''%'' is already revoked', v_code;
	end if;
	if coalesce(jsonb_typeof(g->'redeemed_by_user_id'), 'null') <> 'null' then
		raise exception 'gift code ''%'' was already redeemed; revoking it now would take nothing back', v_code;
	end if;
	-- GiftCodes.patchByPk({code}, {revoked_at}): the key column and the patched column.
	update fluxer_kv
	set row_data = row_data || jsonb_build_object('code', v_code,
	        'revoked_at', jsonb_build_object('__fluxer_type', 'date',
	            'value', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))),
	    updated_at = now()
	where table_name = 'gift_codes' and row_key = '"' || v_code || '"';
end
$$;
commit;
SQL
	echo "Revoked $code. It can no longer be redeemed."
}

premium_state() {
	run_sql -At -F ' ' -v id="$1" <<'SQL'
select coalesce(row_data->>'premium_type', '0'),
       coalesce(row_data->'premium_since'->>'value', '-'),
       coalesce(row_data->'premium_gift_extension_ends_at'->>'value', '-'),
       coalesce(row_data->>'version', '0')
from fluxer_kv
where table_name = 'users' and row_key = '{"__fluxer_type":"bigint","value":"' || :'id' || '"}';
SQL
}

badge_patch_applied() {
	[ -f "$OVERRIDE" ] && head -n 1 "$OVERRIDE" | grep -q 'badge-patch.sh'
}

cmd_redeem() {
	code=$(parse_code "$1")
	user=$2
	id=$(resolve_user "$user")
	before=$(premium_state "$id")

	run_sql -v code="$code" -v id="$id" <<'SQL'
\set VERBOSITY terse
begin;
select set_config('fluxer_gifts.code', :'code', true) is null as unused1,
       set_config('fluxer_gifts.user_id', :'id', true) is null as unused2 \gset
do $$
declare
	v_code text := current_setting('fluxer_gifts.code');
	v_uid text := current_setting('fluxer_gifts.user_id');
	v_ukey text := '{"__fluxer_type":"bigint","value":"' || current_setting('fluxer_gifts.user_id') || '"}';
	v_now timestamptz := date_trunc('milliseconds', now());
	g jsonb;
	u jsonb;
	d_type text;
	d_qty int;
	d_months int;
	flags bigint;
	pflags int;
	ptype int;
	p_until timestamptz;
	p_gift timestamptz;
	anchor timestamptz;
	new_end timestamptz;
	patch jsonb;
begin
	-- StripeGiftService.redeemGiftCode, in its order.
	select row_data into g from fluxer_kv
	where table_name = 'gift_codes' and row_key = '"' || v_code || '"'
	  and (expires_at is null or expires_at > now())
	for update;
	if g is null then
		raise exception 'no gift code ''%''', v_code;
	end if;
	if jsonb_typeof(g->'revoked_at') = 'object' then
		raise exception 'gift code ''%'' was revoked', v_code;
	end if;
	if coalesce(jsonb_typeof(g->'redeemed_by_user_id'), 'null') <> 'null' then
		raise exception 'gift code ''%'' is already redeemed (''gifts.sh show %'')', v_code, v_code;
	end if;

	-- GiftCode normaliseGiftCodeDuration: duration_type/quantity, else duration_months.
	d_type := g->>'duration_type';
	d_qty := (g->>'duration_quantity')::int;
	if d_type is null and d_qty is null then
		d_months := (g->>'duration_months')::int;
		if d_months is null then
			raise exception 'gift code ''%'' has no duration', v_code;
		end if;
		if d_months <> 0 and d_months % 12 = 0 then
			d_type := 'years'; d_qty := d_months / 12;
		else
			d_type := 'months'; d_qty := d_months;
		end if;
	elsif d_type is null or d_qty is null then
		raise exception 'gift code ''%'' has half a duration', v_code;
	end if;
	if d_type not in ('days', 'weeks', 'months', 'years') or d_qty < 0 then
		raise exception 'gift code ''%'' has an invalid duration (% %)', v_code, d_qty, d_type;
	end if;
	if d_qty = 0 then
		raise exception 'gift code ''%'' is a lifetime gift; redeeming one needs a Visionary slot and guild this instance does not have', v_code;
	end if;

	select row_data into u from fluxer_kv
	where table_name = 'users' and row_key = v_ukey and (expires_at is null or expires_at > now())
	for update;
	if u is null then
		raise exception 'no account with id %', v_uid;
	end if;
	flags := coalesce(case jsonb_typeof(u->'flags')
		when 'object' then u->'flags'->>'value'
		when 'number' then u->>'flags'
		when 'string' then u->>'flags' end, '0')::bigint;
	pflags := coalesce((u->>'premium_flags')::int, 0);
	ptype := coalesce((u->>'premium_type')::int, 0);

	-- DefaultUserOnly on the route.
	if coalesce((u->>'bot')::boolean, false) then
		raise exception 'bots cannot redeem gifts';
	end if;
	-- UserAccountRepository.migratePremiumFlagsInPatch would rewrite flags and
	-- premium_flags on this write; a single statement here cannot do that faithfully.
	if (flags & ((1::bigint << 37) | (1::bigint << 40) | (1::bigint << 41) | (1::bigint << 42)
	      | (1::bigint << 43) | (1::bigint << 44) | (1::bigint << 45) | (1::bigint << 46) | (1::bigint << 52)
	      | (1::bigint << 54) | (1::bigint << 55) | (1::bigint << 56) | (1::bigint << 58))) <> 0 then
		raise exception 'this account still carries legacy flag bits the api migrates on write; redeem after it has been edited in the admin panel';
	end if;
	-- StripeCheckoutService.validateUserCanPurchase.
	if u->>'password_hash' is null
	   and not coalesce((case jsonb_typeof(u->'traits') when 'object' then u->'traits'->'value'
	                          when 'array' then u->'traits' end) ? 'sso', false) then
		raise exception 'this is an unclaimed account (no password); the api refuses purchases and gifts for those';
	end if;
	if not coalesce((u->>'email_verified')::boolean, false) then
		raise exception 'this account''s email is not verified; the api refuses gifts until it is (''fluxer users verify-email'')';
	end if;
	if (pflags & 64) <> 0 then
		raise exception 'this account has PURCHASE_DISABLED set';
	end if;
	-- CannotRedeemPlutoniumWithVisionaryError.
	if ptype = 2 then
		raise exception 'this account already has lifetime Plutonium (Visionary); the api refuses gifts for it';
	end if;

	p_until := case when jsonb_typeof(u->'premium_until') = 'object'
	                then (u->'premium_until'->>'value')::timestamptz end;
	p_gift := case when jsonb_typeof(u->'premium_gift_extension_ends_at') = 'object'
	               then (u->'premium_gift_extension_ends_at'->>'value')::timestamptz end;
	if ptype = 1 and p_until is null and p_gift is null then
		raise exception 'this account has open-ended Plutonium (''fluxer premium --subscriber''); a gift would give it an end date, after which the api strips it. Nothing changed';
	end if;

	-- StripePremiumService.resolveGiftExtensionEnd + GiftCode.addGiftCodeDuration, in UTC.
	anchor := greatest(v_now, p_until, p_gift);
	new_end := case d_type
		when 'days' then (anchor at time zone 'utc' + make_interval(days => d_qty)) at time zone 'utc'
		when 'weeks' then (anchor at time zone 'utc' + make_interval(days => 7 * d_qty)) at time zone 'utc'
		when 'months' then (anchor at time zone 'utc' + make_interval(months => d_qty)) at time zone 'utc'
		when 'years' then (anchor at time zone 'utc' + make_interval(months => 12 * d_qty)) at time zone 'utc'
	end;

	-- GiftCodeRepository.redeemGiftCode: the code row, then the redeemer index.
	update fluxer_kv
	set row_data = row_data || jsonb_build_object('code', v_code,
	        'redeemed_by_user_id', jsonb_build_object('__fluxer_type', 'bigint', 'value', v_uid),
	        'redeemed_at', jsonb_build_object('__fluxer_type', 'date',
	            'value', to_char(v_now at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))),
	    updated_at = now()
	where table_name = 'gift_codes' and row_key = '"' || v_code || '"';

	insert into fluxer_kv as kv (table_name, partition_key, row_key, row_data, expires_at, updated_at)
	values ('gift_codes_by_redeemer',
	        v_ukey || chr(31) || '"' || v_code || '"',
	        v_ukey || chr(31) || '"' || v_code || '"',
	        jsonb_build_object('redeemed_by_user_id', jsonb_build_object('__fluxer_type', 'bigint', 'value', v_uid),
	                           'code', v_code),
	        null, now())
	on conflict (table_name, row_key) do update
	set partition_key = excluded.partition_key, row_data = kv.row_data || excluded.row_data,
	    expires_at = excluded.expires_at, updated_at = now();

	-- extendPremiumByGift's patch, through patchAccount (a null only clears a set field)
	-- and patchUser (the key column and version + 1 ride along).
	patch := jsonb_build_object('user_id', u->'user_id',
	    'premium_gift_extension_ends_at', jsonb_build_object('__fluxer_type', 'date',
	        'value', to_char(new_end at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')),
	    'version', coalesce((u->>'version')::int, 0) + 1);
	if coalesce(jsonb_typeof(u->'premium_grace_ends_at'), 'null') <> 'null' then
		patch := patch || jsonb_build_object('premium_grace_ends_at', null);
	end if;
	if ptype <= 0 then
		patch := patch || jsonb_build_object('premium_type', 1,
		    'premium_since', case when jsonb_typeof(u->'premium_since') = 'object' then u->'premium_since'
		        else jsonb_build_object('__fluxer_type', 'date',
		            'value', to_char(v_now at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')) end);
	end if;
	update fluxer_kv
	set row_data = row_data || patch, updated_at = now()
	where table_name = 'users' and row_key = v_ukey;
end
$$;
commit;
SQL

	after=$(premium_state "$id")
	# shellcheck disable=SC2086 # split "type since ends version" into $1..$4
	set -- $before
	b_type=$1 b_ends=$3 b_version=$4
	# shellcheck disable=SC2086
	set -- $after
	echo "$user: redeemed $code."
	printf '  premium_type  %s -> %s\n' "$b_type" "$1"
	printf '  since         %s\n' "$2"
	printf '  gift ends     %s -> %s\n' "$b_ends" "$3"
	printf '  version       %s -> %s\n' "$b_version" "$4"
	echo
	if badge_patch_applied; then
		echo "Badge patch: applied. Open clients show the badge after a reload; other"
		echo "people's view within ~30 s (users service cache)."
	else
		echo "Badge patch: not applied, so the badge will not render on this instance."
		echo "  'fluxer badge-patch' applies it (it recreates app-proxy)."
	fi
	echo "Premium ends on its own when the gift runs out; nothing needs to run then."
}

action=${1:-}
[ $# -gt 0 ] && shift || true

case "$action" in
	create)
		duration=1m count=1
		while [ $# -gt 0 ]; do
			case "$1" in
				--duration) [ $# -ge 2 ] || die '--duration needs a value'; duration=$2; shift ;;
				--duration=*) duration=${1#*=} ;;
				--count) [ $# -ge 2 ] || die '--count needs a value'; count=$2; shift ;;
				--count=*) count=${1#*=} ;;
				--note | --note=*) die "gift codes have no note field upstream; keep notes elsewhere" ;;
				*) die "unknown option: $1" ;;
			esac
			shift
		done
		cmd_create "$duration" "$count"
		;;
	list)
		filter=all
		for a in "$@"; do
			case "$a" in
				--unredeemed) filter=unredeemed ;;
				--redeemed) filter=redeemed ;;
				--revoked) filter=revoked ;;
				*) die "unknown option: $a" ;;
			esac
		done
		cmd_list "$filter"
		;;
	show)
		[ $# -eq 1 ] || { usage >&2; exit 2; }
		cmd_show "$1"
		;;
	revoke)
		[ $# -eq 1 ] || { usage >&2; exit 2; }
		cmd_revoke "$1"
		;;
	redeem)
		[ $# -eq 2 ] || { usage >&2; exit 2; }
		cmd_redeem "$1" "$2"
		;;
	-h | --help | help)
		usage
		;;
	'')
		usage >&2
		exit 2
		;;
	*)
		printf 'gifts: unknown command: %s\n\n' "$action" >&2
		usage >&2
		exit 2
		;;
esac
