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

# --- prerequisites
( load
  version_ge 2.26.1 2.24.4 && pass "2.26.1 >= 2.24.4" || fail "2.26.1 >= 2.24.4"
  version_ge 2.24.4 2.24.4 && pass "equal versions are enough" || fail "equal versions are enough"
  version_ge 2.9.0 2.24.4 && fail "2.9.0 is older than 2.24.4" || pass "2.9.0 is older than 2.24.4"
  version_ge 10.0.0 2.24.4 && pass "numeric, not lexical" || fail "numeric, not lexical"

  mkdir -p "$tmp/pm"; printf '#!/bin/sh\n' > "$tmp/pm/apt-get"; chmod +x "$tmp/pm/apt-get"
  assert_eq "pkg_hint on apt" "sudo apt-get install -y git" "$(PATH="$tmp/pm:/usr/bin:/bin" pkg_hint git)"

  # docker compose too old, tools present
  mkdir -p "$tmp/d"
  cat > "$tmp/d/docker" <<'EOF'
#!/bin/sh
case "$*" in
	"compose version --short") echo "${COMPOSE_V:-2.26.1}" ;;
	info) exit "${DOCKER_INFO_RC:-0}" ;;
	version*) echo 27.0.0 ;;
esac
EOF
  chmod +x "$tmp/d/docker"
  DOCKER="$tmp/d/docker" CHECK_ONLY=1 MISSING=0
  export COMPOSE_V=2.20.0  # read by the docker stub, a child process
  out=$(phase_tools); assert_contains "old compose is reported" "older than 2.24.4" "$out"
  phase_tools > /dev/null; assert_eq "old compose counts as missing" 1 "$MISSING"
  unset COMPOSE_V
  MISSING=0; out=$(phase_tools); assert_contains "compose ok" "✓ Docker Compose 2.26.1" "$out"

  # no docker at all, check mode: reported, not installed
  DOCKER="$tmp/nope/docker" MISSING=0
  out=$(phase_docker ''); assert_contains "missing docker reported" "Docker is not installed" "$out"
  phase_docker '' > /dev/null; assert_eq "missing docker counts" 1 "$MISSING"

  # no docker, interactive, declined: exits 2 with the manual route
  CHECK_ONLY=0 ASSUME_YES=0
  rc=0; ( printf 'n\n' | phase_docker '' > "$tmp/o" 2>&1 ) || rc=$?
  assert_eq "declined docker install exits 2" 2 "$rc"
  assert_contains "points at the docs" "docs.docker.com" "$(cat "$tmp/o")"
  finish )

# --- phase_docker: the docker-group branch (not-in-group, stale login, usermod, sg re-exec)
( load
  if [ "$(id -u)" -eq 0 ]; then
    pass "docker-group branch skipped (running as root)"
  else
    # A real docker stub that answers "info" per test (DOCKER_INFO_RC), plus
    # getent/usermod/sg stubs that record their argv instead of touching the
    # host. Prepended to PATH, never replacing it: cut/tr/grep/id stay real.
    mkdir -p "$tmp/d" "$tmp/bin" "$tmp/calls"
    cat > "$tmp/d/docker" <<'EOF'
#!/bin/sh
case "$*" in
	"compose version --short") echo "${COMPOSE_V:-2.26.1}" ;;
	info) exit "${DOCKER_INFO_RC:-0}" ;;
	version*) echo 27.0.0 ;;
esac
EOF
    chmod +x "$tmp/d/docker"
    cat > "$tmp/bin/getent" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/calls/getent"
case "\$*" in
	"group docker") printf 'docker:x:999:%s\n' "\${GETENT_DOCKER_MEMBERS:-}" ;;
	*) exit 2 ;;
esac
EOF
    chmod +x "$tmp/bin/getent"
    cat > "$tmp/bin/usermod" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/calls/usermod"
EOF
    chmod +x "$tmp/bin/usermod"
    cat > "$tmp/bin/sg" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/calls/sg"
EOF
    chmod +x "$tmp/bin/sg"
    DOCKER="$tmp/d/docker"
    _me=$(id -un)

    # (a) docker info fails, not in the group, --check: reported and counted, no usermod
    # assert_* run outside the subshell below: fails they record would
    # otherwise not reach this group's own finish (subshells don't share it back).
    rm -f "$tmp/calls/usermod"
    ( PATH="$tmp/bin:$PATH"; export PATH
      DOCKER_INFO_RC=1 GETENT_DOCKER_MEMBERS=''; export DOCKER_INFO_RC GETENT_DOCKER_MEMBERS
      CHECK_ONLY=1 MISSING=0
      phase_docker '' > "$tmp/o1" 2>&1
      echo "$MISSING" > "$tmp/missing1"
    )
    assert_contains "not-in-group reported under --check" "not in the docker group" "$(cat "$tmp/o1")"
    assert_eq "not-in-group counts as missing" 1 "$(cat "$tmp/missing1")"
    [ -e "$tmp/calls/usermod" ] && fail "check mode ran usermod" || pass "check mode ran no usermod"

    # (b) same, interactive, declined: exits 2, no usermod
    rm -f "$tmp/calls/usermod"
    rc=0
    ( PATH="$tmp/bin:$PATH"; export PATH
      DOCKER_INFO_RC=1 GETENT_DOCKER_MEMBERS=''; export DOCKER_INFO_RC GETENT_DOCKER_MEMBERS
      CHECK_ONLY=0 ASSUME_YES=0 SUDO_OK=1
      printf 'n\n' | phase_docker '' > "$tmp/o2" 2>&1
    ) || rc=$?
    assert_eq "declined docker-group add exits 2" 2 "$rc"
    [ -e "$tmp/calls/usermod" ] && fail "declined add ran usermod" || pass "declined add ran no usermod"

    # (c) same, interactive, accepted: usermod once, then sg re-exec with the
    # original arguments intact (the space in "my domain" proves quote_cmd's
    # round trip survives usermod -> exec sg).
    rm -f "$tmp/calls/usermod" "$tmp/calls/sg"
    ( PATH="$tmp/bin:$PATH"; export PATH
      DOCKER_INFO_RC=1 GETENT_DOCKER_MEMBERS=''; export DOCKER_INFO_RC GETENT_DOCKER_MEMBERS
      CHECK_ONLY=0 ASSUME_YES=0 SUDO_OK=1
      printf 'y\n' | phase_docker "$(quote_cmd --domain 'my domain')" > "$tmp/o3" 2>&1
    )
    assert_eq "accepted add calls usermod once" 1 "$(wc -l < "$tmp/calls/usermod" 2> /dev/null || echo 0)"
    assert_contains "usermod adds this user to docker" "-aG docker $_me" "$(cat "$tmp/calls/usermod" 2> /dev/null)"
    assert_contains "sg re-exec carries the original args intact" "my domain" "$(cat "$tmp/calls/sg" 2> /dev/null)"

    # (d) SETUP_SG=1 already set, docker info still fails, user already in the
    # group: dies instead of re-execing, so there is no exec loop.
    rm -f "$tmp/calls/sg"
    rc=0
    ( PATH="$tmp/bin:$PATH"; export PATH
      DOCKER_INFO_RC=1 GETENT_DOCKER_MEMBERS=$_me; export DOCKER_INFO_RC GETENT_DOCKER_MEMBERS
      CHECK_ONLY=0 ASSUME_YES=0 SUDO_OK=1 SETUP_SG=1
      phase_docker '' > "$tmp/o4" 2>&1
    ) || rc=$?
    assert_eq "stale SETUP_SG dies instead of looping" 2 "$rc"
    [ -e "$tmp/calls/sg" ] && fail "stale SETUP_SG re-exec'd sg" || pass "stale SETUP_SG never re-exec'd"
  fi
  finish )

finish
