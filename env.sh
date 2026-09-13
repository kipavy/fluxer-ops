#!/bin/sh
# Read and change .env without an editor.
#
# .env holds every secret the instance has. Opening it to change one line puts
# all of them on screen, and a slip in an editor can break a line compose reads
# differently than it looks ("a #b" is "a"; "$x" expands). So this never shows a
# secret unless asked, backs the file up before every change, rewrites exactly
# one line atomically, and never touches the containers: it prints the command
# that applies the change instead, because recreating services is a decision.
#
#   ./env.sh keys                  list keys; secret-looking ones are marked
#   ./env.sh get KEY [--reveal]    print a value; secrets masked unless --reveal
#   ./env.sh set KEY VALUE         change or add one key (VALUE - reads stdin,
#                                  which keeps a secret out of shell history)
#   ./env.sh diff [--upstream]     keys new upstream / gone upstream, never values;
#                                  --upstream compares against the next update's
#                                  .env.example instead of the local one
set -eu

. "$(dirname "$(readlink -f "$0")")/lib.sh"
need_instance
ENV="$FLUXER_DIR/.env"
RAW_BASE='https://raw.githubusercontent.com/fluxerapp/fluxer'

LC_ALL=C
export LC_ALL

usage() {
	cat >&2 <<'USAGE'
usage: env.sh keys
       env.sh get KEY [--reveal]
       env.sh set KEY VALUE        (VALUE - reads it from stdin)
       env.sh diff [--upstream]
USAGE
	exit 2
}
die() { printf '%s\n' "$*" >&2; exit 1; }
[ -f "$ENV" ] || die "no .env in $FLUXER_DIR"

# Names only; the value is looked at separately, for URLs carrying a password.
SECRET_RE='PASS|SECRET|KEY|TOKEN|COOKIE|PRIVATE|CREDENTIAL|SALT|DSN'
is_secret() {
	printf '%s\n' "$1" | grep -Eq "$SECRET_RE" && return 0
	raw_value "$1" | grep -Eq '://[^/@]*:[^/@]*@'
}

valid_key() { printf '%s\n' "$1" | grep -Eq '^[A-Z0-9_]+$' && [ "$(printf '%s' "$1" | wc -l)" -eq 0 ]; }
count_key() { grep -c "^$1=" "$ENV" || true; }
# The first match, exactly as install.sh reads it.
raw_value() { sed -n "s/^$1=//p" "$ENV" | head -n 1; }
unquote() {
	case "$1" in
		\'*\' | \"*\") v=${1#?}; printf '%s' "${v%?}" ;;
		*) printf '%s' "$1" ;;
	esac
}

mask() {
	n=$(printf '%s' "$1" | wc -c | tr -d ' ')
	if [ "$n" -eq 0 ]; then printf '(empty)'
	elif [ "$n" -ge 16 ]; then printf '%.4s... (%s chars, masked; --reveal shows it)' "$1" "$n"
	else printf '(%s chars, hidden; --reveal shows it)' "$n"
	fi
}

cmd_keys() {
	grep -E '^[A-Za-z0-9_]+=' "$ENV" | sed 's/=.*//' | awk '{ n[$0]++; if (n[$0] == 1) o[++c] = $0 }
		END { for (i = 1; i <= c; i++) print o[i], n[o[i]] }' | while read -r k n; do
		flags=''
		is_secret "$k" && flags='secret'
		[ "$n" -eq 1 ] || flags="${flags:+$flags, }set $n times (first one wins for install.sh)"
		printf '%-48s %s\n' "$k" "$flags"
	done
}

cmd_get() {
	key=${1:-}; reveal=0
	[ "${2:-}" = '--reveal' ] && reveal=1
	valid_key "$key" || die "not a key: $key (want ^[A-Z0-9_]+\$)"
	n=$(count_key "$key")
	[ "$n" -gt 0 ] || die "$key is not set in $ENV"
	[ "$n" -eq 1 ] || echo "note: $key is set $n times; showing the first" >&2
	v=$(unquote "$(raw_value "$key")")
	if [ "$reveal" -eq 0 ] && is_secret "$key"; then
		mask "$v"; echo
	else
		printf '%s\n' "$v"
	fi
}

# Compose reads an unquoted .env value with ${...} expansion and " #" comments,
# and trims it. Plain values stay bare (install.sh reads lines raw, quotes and
# all); anything else is single-quoted, which compose takes literally.
encode() {
	case "$1" in
		*"'"*) case "$1" in *'$'* | *'#'* | ' '* | *' ' | \"* | \'*) return 1 ;; esac; printf '%s' "$1" ;;
		*'$'* | *'#'* | ' '* | *' ' | "	"* | *"	" | \"* | *\\*) printf "'%s'" "$1" ;;
		*) printf '%s' "$1" ;;
	esac
}

# Services whose resolved config references ${KEY}: anchors and merge keys are
# already expanded, so a variable in a shared x- block counts for every service
# that uses it. --no-interpolate keeps values out of what is read.
services_using() {
	(cd "$FLUXER_DIR" && docker compose config --no-interpolate --format json 2>/dev/null) \
		| python3 -c '
import json, re, sys
key = sys.argv[1]
pat = re.compile(r"(?<!\$)\$\{?" + key + r"(?![A-Za-z0-9_])")
for name, svc in sorted(json.load(sys.stdin)["services"].items()):
    env = svc.get("environment") or {}
    if pat.search(json.dumps(svc)) or (isinstance(env, dict) and key in env):
        print(name)
' "$1"
}

cmd_set() {
	[ $# -eq 2 ] || usage
	key=$1; value=$2
	valid_key "$key" || die "refusing key '$key': keys must match ^[A-Z0-9_]+\$"
	if [ "$value" = '-' ]; then
		value=$(cat)
	fi
	case "$value" in
		*'
'* | *"$(printf '\r')"*) die "refusing a value with a line break: .env is one key per line." ;;
	esac
	line="$key=$(encode "$value")" || die "refusing: the value has a single quote and \$, # or edge spaces, which no .env quoting keeps literal. Set it by hand."

	n=$(count_key "$key")
	[ "$n" -le 1 ] || die "$key is set $n times in $ENV; install.sh reads the first, compose the last. Fix that by hand first."
	if [ "$key" = 'POSTGRES_PASSWORD' ] && [ "$n" -eq 1 ]; then
		die "refusing POSTGRES_PASSWORD: postgres sets its password only when the volume is first created, so a new one here does not change the database's and the stack can no longer log in. Change it in postgres (ALTER USER) first, then edit .env by hand."
	fi

	old=$(raw_value "$key")
	if [ "$n" -eq 1 ] && [ "$old" = "$(encode "$value")" ]; then
		echo "$key already has that value. Nothing changed."
		return 0
	fi

	umask 077
	ts=$(date -u +%Y%m%dT%H%M%SZ)
	bak="$ENV.bak-$ts"
	i=1
	while [ -e "$bak" ]; do bak="$ENV.bak-$ts-$i"; i=$((i + 1)); done
	cp -p "$ENV" "$bak"
	chmod 600 "$bak"

	# Same directory, so the rename is atomic: a crash leaves the old file or the new one.
	new="$ENV.tmp.$$"
	trap 'rm -f "$new"' EXIT
	ENVSH_KEY=$key ENVSH_LINE=$line awk '
		BEGIN { k = ENVIRON["ENVSH_KEY"] "="; l = ENVIRON["ENVSH_LINE"] }
		index($0, k) == 1 { print l; done = 1; next }
		{ print }
		END { if (!done) print l }' "$ENV" > "$new"
	chmod 600 "$new"
	mv "$new" "$ENV"
	trap - EXIT

	if is_secret "$key"; then
		shown="$(mask "$value")"
	else
		shown=$value
	fi
	if [ "$n" -eq 1 ]; then echo "$key changed to: $shown"; else echo "$key added: $shown"; fi
	echo "Backup of the previous .env: $bak (mode 600; it holds every secret, delete it when done)"

	echo
	case "$key" in
		COMPOSE_*)
			echo "$key changes how compose itself reads the stack. Apply with:"
			echo "  cd $FLUXER_DIR && docker compose up -d"
			return 0 ;;
	esac
	svcs=$(services_using "$key" | tr '\n' ' ' | sed 's/ $//') || svcs=''
	if [ -n "$svcs" ]; then
		echo "Referenced by: $svcs"
		echo "Nothing is running with it yet. Apply with:"
		echo "  cd $FLUXER_DIR && docker compose up -d $svcs"
	else
		echo "No compose service references \${$key} (or compose could not be read), so"
		echo "recreating containers changes nothing; install.sh or nothing at all reads it."
	fi
}

# Keys of an .env.example: active lines, and the commented-out optional ones.
example_keys() {
	sed -n 's/^\([A-Za-z0-9_]*\)=.*/active \1/p; s/^#[[:space:]]*\([A-Z][A-Z0-9_]*\)=.*/optional \1/p' "$1" \
		| sort -u
}

cmd_diff() {
	tmp=$(mktemp -d)
	trap 'rm -rf "$tmp"' EXIT
	if [ "${1:-}" = '--upstream' ] || [ ! -f "$FLUXER_DIR/.env.example" ]; then
		tag=$(raw_value FLUXER_IMAGE_TAG)
		case "${tag:-v1}" in v1 | latest) ref=main ;; *) ref=$tag ;; esac
		url="$RAW_BASE/$ref/deploy/self-hosting/.env.example"
		curl -fsSL --max-time 30 "$url" -o "$tmp/example" || die "could not fetch $url"
		curl -fsSL --max-time 30 "${url%.env.example}docker-compose.yml" -o "$tmp/compose" || : > "$tmp/compose"
		src="upstream $url"
	else
		cp "$FLUXER_DIR/.env.example" "$tmp/example"
		cat "$FLUXER_DIR"/docker-compose*.yml > "$tmp/compose" 2>/dev/null || true
		src="$FLUXER_DIR/.env.example (refreshed by the last install.sh --update; --upstream for what the next brings)"
	fi
	example_keys "$tmp/example" > "$tmp/ex"
	grep -E '^[A-Za-z0-9_]+=' "$ENV" | sed 's/=.*//' | sort -u > "$tmp/have"
	# A key both active and commented in the example counts as active.
	awk '$1 == "active" { print $2 }' "$tmp/ex" | sort -u > "$tmp/active"
	awk '{ print $2 }' "$tmp/ex" | sort -u > "$tmp/all"
	comm -23 "$tmp/all" "$tmp/active" > "$tmp/optional"

	echo "Comparing keys in $ENV with $src"
	echo
	missing=$(comm -23 "$tmp/active" "$tmp/have")
	if [ -n "$missing" ]; then
		echo "Set in the example but missing from .env:"
		# ${KEY:?msg} is how compose marks a key it will not start without.
		for k in $missing; do
			if grep -Eq "\\$\\{$k:?\\?" "$tmp/compose"; then
				printf '  %-44s REQUIRED: compose will not start without it\n' "$k"
			else
				printf '  %-44s optional for compose (empty or defaulted)\n' "$k"
			fi
		done
	else
		echo "Every key the example sets is in .env."
	fi
	echo
	opt=$(comm -23 "$tmp/optional" "$tmp/have")
	printf 'Optional upstream keys not set here (%s, commented out in the example):\n' \
		"$(printf '%s' "$opt" | grep -c . || true)"
	printf '%s\n' "$opt" | tr '\n' ' ' | fold -s -w 78 | sed 's/^/  /'
	echo
	echo
	gone=$(comm -13 "$tmp/all" "$tmp/have")
	if [ -n "$gone" ]; then
		echo "In .env but not in the example at all (local additions, or dropped upstream):"
		printf '%s\n' "$gone" | sed 's/^/  /'
	else
		echo "Every key in .env appears in the example."
	fi
}

cmd=${1:-}
[ $# -gt 0 ] && shift || true
case "$cmd" in
	keys) cmd_keys ;;
	get) cmd_get "$@" ;;
	set) cmd_set "$@" ;;
	diff) cmd_diff "$@" ;;
	*) usage ;;
esac
