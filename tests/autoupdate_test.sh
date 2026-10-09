#!/bin/sh
# shellcheck disable=SC2034 # file-wide: the stub variables set here (DOCKER, REGISTRY,
# UPDATE, ...) are inputs to the autoupdate.sh functions this file sources with `load`.
# autoupdate_test.sh - autoupdate.sh against stubs in a scratch directory.
# No real crontab, docker, registry, update or network is touched.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(dirname "$HERE")
. "$HERE/assert.sh"
tmp=$(readlink -f "$(mktemp -d)")
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/inst/ops" "$tmp/cron" "$tmp/zoneinfo/Europe" "$tmp/bin"
cp "$SRC/autoupdate.sh" "$SRC/lib.sh" "$tmp/inst/ops/"
: > "$tmp/inst/docker-compose.yml"
: > "$tmp/zoneinfo/Europe/Paris"
printf 'FLUXER_DOMAIN=chat.example.test\nFLUXER_IMAGE_TAG=v1\n' > "$tmp/inst/.env"

# crontab stub, as in setup_test.sh: -l prints, - replaces (via a rename).
cat > "$tmp/bin/crontab" <<'EOF'
#!/bin/sh
f="$CRON_DIR/user"
case "$1" in
	-l) [ -f "$f" ] && cat "$f" || exit 1 ;;
	-) cat > "$f.new" && mv "$f.new" "$f" ;;
esac
EOF
# docker stub: two fluxer containers and one third-party one. RepoDigests come
# from $DIGESTS_<n> so each case can say what runs.
cat > "$tmp/bin/docker" <<'EOF'
#!/bin/sh
case "$*" in
	"compose ps -aq") printf 'c1\nc2\nc3\n' ;;
	"version --format"*) echo linux/arm64 ;;
	inspect*) cat <<'X'
ghcr.io/fluxerapp/fluxer-api:v1 sha256:i1
ghcr.io/fluxerapp/fluxer-gateway:v1 sha256:i2
postgres:16-alpine sha256:i3
X
	;;
	"image inspect --format"*sha256:i1) echo "ghcr.io/fluxerapp/fluxer-api@sha256:${API_DIGEST:-aaa}" ;;
	"image inspect --format"*sha256:i2) echo "ghcr.io/fluxerapp/fluxer-gateway@sha256:bbb" ;;
	*) echo "docker stub: unexpected: $*" >&2; exit 1 ;;
esac
EOF
# registry stub: the tag points at aaa/bbb unless REMOTE_API says otherwise.
cat > "$tmp/bin/registry" <<'EOF'
#!/bin/sh
if [ "$1" = tags ]; then printf 'latest\nv1\n%s' "${EXTRA_TAG:-}"; exit 0; fi
shift 2
for r in "$@"; do
	case "$r" in
		*fluxer-api:v1) printf '%s 2026.1 rev1 sha256:%s %s\n' "$r" "${REMOTE_API:-aaa}" "${REMOTE_STATUS:-ok}" ;;
		*fluxer-gateway:v1) printf '%s 2026.1 rev2 sha256:bbb ok\n' "$r" ;;
		*) echo "registry stub: unexpected ref $r" >&2; exit 1 ;;
	esac
done
EOF
# install.sh --update --dry-run stub: its file list, from $CHANGED (space-separated).
cat > "$tmp/bin/installdry" <<'EOF'
#!/bin/sh
[ -n "${DRY_FAIL:-}" ] && { echo "boom"; exit 1; }
echo "Downloading the stack files from ref main."
echo "  file changes"
for f in docker-compose.yml Caddyfile .env.example; do
	case " ${CHANGED:-} " in *" $f "*) echo "    $f changes" ;; *) echo "    $f is unchanged" ;; esac
done
EOF
# update.sh / changelog.sh / notify.sh / webhook poster: record their calls.
printf '#!/bin/sh\necho "update $*" >> "$CALLS"\necho "update output line"\nexit "${UPDATE_RC:-0}"\n' > "$tmp/bin/update"
cat > "$tmp/bin/changelog" <<'EOF'
#!/bin/sh
echo "changelog $*" >> "$CALLS"
printf '**Composants**\n- COMPONENT RUNNING ON v1\n\n**⚠️ À noter (1)**\n- moderation: remove a thing\n\n**✨ Nouveautés (1)**\n- app: a new thing\n\nTout voir : <https://github.com/x/compare/aaa...bbb>\n'
EOF
printf '#!/bin/sh\ncat > /dev/null\n[ -n "${AI_FAIL:-}" ] && exit 1\necho "- the short summary"\n' > "$tmp/bin/ai"
printf '#!/bin/sh\necho "notify $*" >> "$CALLS"\n' > "$tmp/bin/notify"
cat > "$tmp/bin/post" <<'EOF'
#!/bin/sh
body=$(cat)
echo "post $body" >> "$CALLS"
n=$(ls "$CALLS".post.* 2> /dev/null | wc -l)
printf '%s\n' "$body" > "$CALLS.post.$n.visible"
EOF
chmod +x "$tmp/bin/"*

load() {
	FLUXER_DIR="$tmp/inst" OPS_SELF="$tmp/inst/ops/autoupdate.sh" AUTOUPDATE_SOURCE_ONLY=1
	export FLUXER_DIR
	. "$tmp/inst/ops/autoupdate.sh"
	CRON_DIR="$tmp/cron" CALLS="$tmp/calls"; export CRON_DIR CALLS
	CRONTAB="$tmp/bin/crontab" DOCKER="$tmp/bin/docker" REGISTRY="$tmp/bin/registry"
	INSTALL_DRY="$tmp/bin/installdry" UPDATE="$tmp/bin/update" CHANGELOG="$tmp/bin/changelog"
	NOTIFY="$tmp/bin/notify" POST="$tmp/bin/post" ZONEINFO="$tmp/zoneinfo"
	SUDO_CHECK=true PGREP=false SLEEP=true CURL=false
	STATE="$tmp/state"; rm -rf "$STATE" "$CALLS" "$CALLS".post.* "$tmp/cron/user" "$tmp/pgn"
	AUTOUPDATE_WEBHOOK_URL=https://chat.example.test/api/v1/webhooks/1/secret
	AUTOUPDATE_OPENROUTER_KEY='' AI="$tmp/bin/ai"
}
cron() { cat "$tmp/cron/user" 2> /dev/null || true; }
posts() { cat "$CALLS".post.*."$1" 2> /dev/null || true; }

# --- on / off: the crontab line, the confirmation, other lines left alone
( load
  printf '0 3 * * * FLUXER_DIR=x /x/backup.sh\n' > "$tmp/cron/user"
  printf 'n\n' | cmd_on --at 05:30 > /dev/null
  assert_eq "on: answering n writes nothing" 1 "$(cron | grep -c .)"
  out=$(printf 'y\n' | cmd_on --at 05:30)
  assert_contains "on: warns about downtime" "DOWNTIME" "$out"
  assert_contains "on: asks y/N" "[y/N]" "$out"
  assert_contains "on: hourly at the minute, the hour is checked at run time" \
	"30 * * * * FLUXER_DIR=$tmp/inst $tmp/inst/ops/autoupdate.sh run --at 05:30 --tz Europe/Paris" "$(cron)"
  assert_contains "on: keeps other lines" "/x/backup.sh" "$(cron)"
  cmd_on --at 04:00 --yes > /dev/null
  assert_eq "on again: replaces, never duplicates" 1 "$(cron | grep -c autoupdate.sh)"
  assert_contains "on again: new time" "run --at 04:00" "$(cron)"
  mkdir -p "$STATE"; : > "$STATE/paused"
  cmd_on --yes > /dev/null
  [ -e "$STATE/paused" ] && fail "on: resumes after a failure" || pass "on: resumes after a failure"
  assert_contains "on: default 05:00" "run --at 05:00 --tz Europe/Paris" "$(cron)"
  cmd_off > /dev/null
  assert_eq "off: removes only its line" "0 3 * * * FLUXER_DIR=x /x/backup.sh" "$(cron)"
  finish )

( load
  rc=0; cmd_on --at 25:00 --yes > /dev/null 2>&1 || rc=$?
  assert_eq "on: rejects a bad time" 2 "$rc"
  rc=0; cmd_on --tz Mars/Base --yes > /dev/null 2>&1 || rc=$?
  assert_eq "on: rejects an unknown zone" 2 "$rc"
  rc=0; cmd_on < /dev/null > /dev/null 2>&1 || rc=$?
  assert_eq "on: no terminal and no --yes refuses" 2 "$rc"
  SUDO_CHECK=false
  rc=0; cmd_on --yes > /dev/null 2>&1 || rc=$?
  assert_eq "on: refuses without passwordless sudo (update.sh needs it)" 1 "$rc"
  assert_eq "on: refusal writes nothing" "" "$(cron)"
  finish )

( load
  AUTOUPDATE_WEBHOOK_URL=''
  out=$(cmd_on --yes 2>&1)
  assert_contains "on: says when no changelog channel is configured" "AUTOUPDATE_WEBHOOK_URL" "$out"
  finish )

# --- detect: what counts as an update
( load
  rc=0; detect > /dev/null || rc=$?
  assert_eq "detect: same digests, files unchanged = nothing" 1 "$rc"
  REMOTE_API=new; export REMOTE_API
  rc=0; r=$(detect) || rc=$?
  assert_eq "detect: a new image digest is an update" 0 "$rc"
  assert_contains "detect: names the component" "fluxer-api" "$r"
  finish )
( load
  CHANGED='docker-compose.yml'; export CHANGED
  rc=0; r=$(detect) || rc=$?
  assert_eq "detect: a changed compose file is an update" 0 "$rc"
  assert_contains "detect: names the file" "docker-compose.yml" "$r"
  CHANGED='.env.example'
  rc=0; detect > /dev/null || rc=$?
  assert_eq "detect: .env.example alone is not worth a downtime" 1 "$rc"
  finish )
( load
  REMOTE_STATUS='registry:timeout'; export REMOTE_STATUS
  rc=0; r=$(detect 2>&1) || rc=$?
  assert_eq "detect: registry error = cannot tell" 2 "$rc"
  assert_contains "detect: says why" "timeout" "$r"
  finish )
( load
  DRY_FAIL=1; export DRY_FAIL
  rc=0; detect > /dev/null 2>&1 || rc=$?
  assert_eq "detect: failing dry run = cannot tell" 2 "$rc"
  INSTALL_DRY=true
  unset DRY_FAIL
  rc=0; detect > /dev/null 2>&1 || rc=$?
  assert_eq "detect: unparseable dry run = cannot tell, not 'nothing'" 2 "$rc"
  finish )

# --- run: the hour gate, pause, and both outcomes
( load
  DATE_HOUR=04
  cmd_run --at 05:00 --tz Europe/Paris
  [ -e "$CALLS" ] && fail "run: wrong hour does nothing" || pass "run: wrong hour does nothing"
  mkdir -p "$STATE"; : > "$STATE/paused"
  DATE_HOUR=05
  cmd_run --at 05:00 --tz Europe/Paris
  [ -e "$CALLS" ] && fail "run: paused does nothing" || pass "run: paused does nothing"
  finish )
( load
  DATE_HOUR=05
  cmd_run --at 05:00 --tz Europe/Paris
  assert_eq "run: nothing new = no update, no post" "notify ok autoupdate" "$(cat "$CALLS")"
  assert_contains "run: records it" "up to date" "$(cat "$STATE/last")"
  finish )
( load
  REMOTE_API=new; export REMOTE_API
  cmd_run
  calls=$(cat "$CALLS")
  assert_contains "run: changelog (summary form) before the update" "changelog --summary" "$(head -n 1 "$CALLS")"
  assert_contains "run: update with --yes" "update --yes" "$calls"
  assert_eq "run: one post per update" 1 "$(ls "$CALLS".post.* | wc -l)"
  case "$calls" in *"a new thing"*) fail "run: the detailed list is not posted" ;; *) pass "run: the detailed list is not posted" ;; esac
  assert_contains "run: no summary, so the heads-up is shown" "remove a thing" "$(posts visible)"
  assert_contains "run: links the detailed changelog" "Changelog détaillé : <https://github.com/x/compare/aaa...bbb>" "$(posts visible)"
  assert_contains "run: the post says what triggered it" "1 nouvelle(s) image(s)" "$calls"
  case "$calls" in *"En bref"*) fail "run: no key, no AI summary" ;; *) pass "run: no key, no AI summary" ;; esac
  assert_contains "run: success clears an alert" "notify ok autoupdate" "$calls"
  assert_contains "run: records it" "updated" "$(cat "$STATE/last")"
  finish )
( load
  REMOTE_API=new UPDATE_RC=1; export REMOTE_API UPDATE_RC
  rc=0; cmd_run > /dev/null 2>&1 || rc=$?
  assert_eq "run: failed update exits 1" 1 "$rc"
  [ -e "$STATE/paused" ] && pass "run: failure pauses auto-updates" || fail "run: failure pauses auto-updates"
  calls=$(cat "$CALLS")
  assert_contains "run: failure alerts" "notify alert autoupdate" "$calls"
  assert_contains "run: failure posts the tail of the log" "update output line" "$calls"

  assert_contains "run: the post says it is paused" "en pause" "$calls"
  finish )
( load
  REMOTE_STATUS='registry:timeout'; export REMOTE_STATUS
  rc=0; cmd_run > /dev/null 2>&1 || rc=$?
  assert_eq "run: cannot tell exits 1" 1 "$rc"
  assert_contains "run: cannot tell alerts, no update" "notify alert autoupdate" "$(cat "$CALLS")"
  assert_contains "run: cannot tell is posted to the channel" "impossible" "$(posts visible)"
  rc=0; cmd_run > /dev/null 2>&1 || rc=$?
  assert_eq "run: ... once, not every night" 1 "$(grep -c 'impossible' "$CALLS")"
  REMOTE_STATUS=ok
  cmd_run > /dev/null
  assert_contains "run: recovery is posted" "rétablie" "$(cat "$CALLS")"
  cmd_run > /dev/null
  assert_eq "run: ... once" 1 "$(grep -c 'rétablie' "$CALLS")"
  case "$(cat "$CALLS")" in *update*--yes*) fail "run: cannot tell never updates" ;; *) pass "run: cannot tell never updates" ;; esac
  finish )
( load
  REMOTE_API=new; export REMOTE_API
  cmd_run --dry-run > /dev/null
  case "$(cat "$CALLS" 2>/dev/null)" in *update*) fail "run --dry-run: never updates" ;; *) pass "run --dry-run: never updates" ;; esac
  finish )

( load
  REMOTE_API=new CHANGED='docker-compose.yml'; export REMOTE_API CHANGED
  AUTOUPDATE_OPENROUTER_KEY=sk-test
  cmd_run
  calls=$(cat "$CALLS")
  assert_contains "run: with a key, the AI summary heads the post" "En bref" "$(posts visible)"
  case "$(posts visible)" in *"remove a thing"*) fail "run: with a summary, only the summary" ;;
	*) pass "run: with a summary, only the summary" ;; esac
  assert_contains "run: ... and the link" "Changelog détaillé" "$(posts visible)"
  assert_contains "run: the AI text is in it" "- the short summary" "$calls"
  assert_contains "run: trigger lists the stack file" "modifié : docker-compose.yml" "$calls"
  finish )
( load
  REMOTE_API=new AI_FAIL=1; export REMOTE_API AI_FAIL
  AUTOUPDATE_OPENROUTER_KEY=sk-test
  cmd_run
  calls=$(cat "$CALLS")
  case "$calls" in *"En bref"*) fail "run: failed AI call, no summary" ;; *) pass "run: failed AI call, no summary" ;; esac
  assert_contains "run: failed AI call falls back to the heads-up" "remove a thing" "$calls"
  finish )

# --- a new major tag is announced once, never followed
( load
  EXTRA_TAG=v2; export EXTRA_TAG
  cmd_run
  cmd_run
  assert_eq "major: announced once" 1 "$(grep -c 'post .*v2' "$CALLS")"
  case "$(cat "$CALLS")" in *update*--yes*) fail "major: not followed" ;; *) pass "major: not followed" ;; esac
  finish )

# --- the backup is waited for
( load
  n=0
  PGREP="$tmp/bin/pg"
  printf '#!/bin/sh\nc=$(cat "%s/pgn" 2>/dev/null || echo 0); echo $((c+1)) > "%s/pgn"; [ "$c" -lt 2 ]\n' "$tmp" "$tmp" > "$PGREP"
  chmod +x "$PGREP"
  cmd_run > /dev/null
  assert_eq "run: waits while backup.sh runs" 3 "$(cat "$tmp/pgn")"
  finish )

finish
