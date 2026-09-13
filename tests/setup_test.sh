#!/bin/sh
# setup_test.sh - setup.sh's helpers and phases, against stubs in a scratch directory.
# No real crontab, sudo, docker or network is touched.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(dirname "$HERE")
. "$HERE/assert.sh"
tmp=$(readlink -f "$(mktemp -d)")
trap 'rm -rf "$tmp"' EXIT

# A fake instance with a copy of the tooling, so $OPS never points at the real one.
# Only what setup.sh touches is copied - not patches/ (megabytes of vendor bundle
# chunks) or .superpowers/ (scratch state), which "cp -r $SRC" would drag in.
mkdir -p "$tmp/inst" "$tmp/home" "$tmp/inst/ops"
cp "$SRC"/*.sh "$SRC/fluxer" "$SRC/completion.bash" "$tmp/inst/ops/"
: > "$tmp/inst/docker-compose.yml"
printf 'FLUXER_DOMAIN=chat.example.test\n' > "$tmp/inst/.env"

# crontab stub: one file per user.
cat > "$tmp/crontab" <<'EOF'
#!/bin/sh
who=$1; shift
f="$CRON_DIR/$who"
case "$1" in
	-l) [ -f "$f" ] && cat "$f" || exit 1 ;;
	# core_wiring pipes `cron_list | cron_write` in one pipeline, so both sides
	# run concurrently: writing straight to $f would race the -l side reading
	# it and could truncate it first. Write to a temp file and rename into
	# place once all of stdin (including what -l already produced) is in hand.
	-) cat > "$f.new" && mv "$f.new" "$f" ;;
esac
EOF
chmod +x "$tmp/crontab"
mkdir -p "$tmp/cron"

load() {
	FLUXER_DIR="$tmp/inst" OPS_SELF="$tmp/inst/ops/setup.sh" SETUP_SOURCE_ONLY=1
	export FLUXER_DIR
	. "$tmp/inst/ops/setup.sh"
	OPS="$tmp/inst/ops"  # main sources lib.sh, which SETUP_SOURCE_ONLY skips
	CRON_DIR="$tmp/cron"; export CRON_DIR
	CRONTAB="$tmp/crontab user" CRONTAB_ROOT="$tmp/crontab root" SUDO=''
	BIN_DIR="$tmp/home/bin" COMPLETION_DIR="$tmp/home/completions"
}

# --- quote_cmd round-trips awkward arguments
( load
  eval "set -- $(quote_cmd "a b" "it's" '$x' '')"
  assert_eq "quote_cmd keeps spaces" "a b" "$1"
  assert_eq "quote_cmd keeps quotes" "it's" "$2"
  assert_eq "quote_cmd keeps dollars" '$x' "$3"
  assert_eq "quote_cmd keeps empty args" 4 "$#"
  finish )

# --- ask / prompt
( load
  ASSUME_YES=0
  printf 'y\n' | { ask "q?" n > /dev/null && pass "ask: y is yes" || fail "ask: y is yes"; }
  printf '\n' | { ask "q?" y > /dev/null && pass "ask: Enter takes the default" || fail "ask: Enter takes the default"; }
  r=$(printf '\n' | prompt "name" dflt 2>/dev/null); assert_eq "prompt: Enter takes the default" dflt "$r"
  rc=0; ( : | ask "q?" y > /dev/null 2>&1 ) || rc=$?; assert_eq "ask: closed stdin dies 2" 2 "$rc"
  ASSUME_YES=1
  ask "q?" n < /dev/null > /dev/null && fail "ask --yes: default n stays no" || pass "ask --yes: default n stays no"
  r=$(prompt "name" dflt < /dev/null 2>/dev/null); assert_eq "prompt --yes takes the default" dflt "$r"
  finish )

# --- core wiring: check, install, idempotent
( load
  SUDO_OK=1 CHECK_ONLY=1 ASSUME_YES=1 MISSING=0
  core_wiring > /dev/null; assert_eq "check on a bare host reports missing" 1 "$MISSING"
  [ -e "$tmp/cron/user" ] && fail "check mode wrote a crontab" || pass "check mode writes nothing"

  CHECK_ONLY=0 MISSING=0
  core_wiring > "$tmp/out1"
  assert_eq "fluxer link" "$tmp/inst/ops/fluxer" "$(readlink "$tmp/home/bin/fluxer")"
  assert_eq "completion link" "$tmp/inst/ops/completion.bash" "$(readlink "$tmp/home/completions/fluxer")"
  assert_contains "backup cron carries FLUXER_DIR" "0 3 * * * FLUXER_DIR=$tmp/inst $tmp/inst/ops/backup.sh" "$(cat "$tmp/cron/user")"
  assert_contains "disk cron" "30 3 * * * FLUXER_DIR=$tmp/inst $tmp/inst/ops/disk.sh --record" "$(cat "$tmp/cron/user")"
  assert_contains "watchdog in root's crontab" "*/10 * * * * FLUXER_DIR=$tmp/inst $tmp/inst/ops/watchdog.sh" "$(cat "$tmp/cron/root")"

  before=$(cat "$tmp/cron/user" "$tmp/cron/root")
  core_wiring > "$tmp/out2"
  assert_eq "second run changes no crontab" "$before" "$(cat "$tmp/cron/user" "$tmp/cron/root")"
  assert_contains "second run says ✓" "✓" "$(cat "$tmp/out2")"
  CHECK_ONLY=1 MISSING=0; core_wiring > /dev/null; assert_eq "check after install: nothing missing" 0 "$MISSING"

  # A line an operator wrote by hand, without FLUXER_DIR=, counts as present.
  printf '0 4 * * * %s/backup.sh\n' "$tmp/inst/ops" > "$tmp/cron/user"
  CHECK_ONLY=0; core_wiring > /dev/null
  assert_eq "hand-written backup line is kept, not duplicated" 1 "$(grep -c 'backup.sh' "$tmp/cron/user")"

  # No sudo: the watchdog is skipped, not failed.
  rm -f "$tmp/cron/root"; SUDO_OK=0
  out=$(core_wiring); assert_contains "no sudo skips the watchdog" "– " "$out"
  [ -e "$tmp/cron/root" ] && fail "no sudo wrote root's crontab" || pass "no sudo leaves root's crontab alone"
  finish )

finish
