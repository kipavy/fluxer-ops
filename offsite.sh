#!/bin/sh
# Off-site backups: restic, pushed to Cloudflare R2.
#
# backup.sh keeps full nightly copies on the same disk as the data. That covers a
# bad upgrade and nothing else, and it costs total_size x KEEP_DAYS. This pushes
# the newest local backup into a restic repository on R2: deduplicated,
# incremental, encrypted client-side, and off the box. R2 has no egress fees,
# which is the bill that matters on the day you restore.
#
# What goes in, and why it is not simply the backup directory:
#   - the backup directory (fluxer.dump, .env, docker-compose.yml, Caddyfile,
#     ops/), so the dump and the secrets that open it travel together, EXCEPT
#   - seaweedfs-data.tgz. A gzip stream changes from its first differing byte
#     on, so a tarball that is 99% unchanged still uploads 100% new every
#     night: it defeats dedup entirely. Instead the uploads VOLUME is mounted
#     read-only and backed up as files. SeaweedFS keeps blobs in append-only
#     .dat files, so content-defined chunking uploads roughly the new tail.
#     (A volume vacuum rewrites .dat files; expect a bigger push that night.)
# The volume is read at push time, after the dump was taken. That skew is the
# safe direction: blobs nothing references yet, never rows pointing at blobs
# that are missing. Same hot-copy reasoning as backup.sh.
#
# restic runs from its pinned official image, so nothing is installed on the
# host. The container runs as root because it must read every file in the volume
# and backup directory; restores are chowned back to the caller. Secrets reach
# it as `-e NAME` (inherited from this process), never as values in argv, so
# they do not show up in `ps`. --network host keeps pushes working when
# firewalld has wiped Docker's NAT chains (see README, "Why the watchdog
# exists"). restic's cache lives in a named volume so each run does not rebuild
# the index from R2, and root-owned cache files do not litter $HOME.
#
# Restores only ever go to a fresh local directory, shaped like a backup
# directory, which `fluxer restore` then applies. Never straight onto a volume.
set -eu

. "$(dirname "$(readlink -f "$0")")/lib.sh"
need_instance
CONF=${OFFSITE_CONF:-$OPS/offsite.conf}
# Pinned by tag AND digest: this image handles every secret we have.
RESTIC_IMAGE=${RESTIC_IMAGE:-restic/restic:0.19.1@sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510}

usage() {
	cat <<'USAGE'
offsite.sh - encrypted, deduplicated off-site backups (restic -> Cloudflare R2)

  offsite.sh status                    Configured? reachable? last push age (exit 1 if stale)
  offsite.sh init                      Create the repository (safe to re-run)
  offsite.sh push [backup-dir]         Push the newest local backup, then apply retention
             [--if-configured]         Silent no-op when not configured (for cron)
  offsite.sh snapshots                 List snapshots
  offsite.sh check [--read-data-subset=5%]
                                       Verify repository integrity
  offsite.sh restore <snapshot|latest> <target-dir>
                                       Restore into a NEW local directory, never live
  offsite.sh forget                    Apply retention and prune, without pushing
  offsite.sh restic <args...>          Run any restic command against the repository

Config: ops/offsite.conf (see offsite.conf.example)
USAGE
}

die() { printf '%s\n' "$*" >&2; exit 1; }
say() { printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# notify.sh is optional; a missing or failing notifier must never fail a backup.
notify() {
	[ -x "$OPS/notify.sh" ] || return 0
	"$OPS/notify.sh" "$@" > /dev/null 2>&1 || true
}

configured() { [ -f "$CONF" ]; }

not_configured() {
	cat >&2 <<EOF
Off-site backups are not configured: $CONF does not exist.

  1. Create an R2 bucket, and an API token with Object Read & Write scoped to
     that bucket only.
  2. cp $OPS/offsite.conf.example $CONF
     chmod 600 $CONF
     and fill it in. Store RESTIC_PASSWORD somewhere other than this host.
  3. $OPS/offsite.sh init
EOF
	exit 1
}

load_conf() {
	configured || not_configured
	if [ -n "$(find "$CONF" -perm /077 2> /dev/null)" ]; then
		printf 'WARNING: %s is readable by others; run: chmod 600 %s\n' "$CONF" "$CONF" >&2
	fi
	set -a
	# shellcheck source=/dev/null
	. "$CONF"
	set +a

	[ -n "${RESTIC_REPOSITORY:-}" ] || die "$CONF: RESTIC_REPOSITORY is not set"
	if [ -n "${RESTIC_PASSWORD_FILE:-}" ]; then
		[ -r "$RESTIC_PASSWORD_FILE" ] || die "$CONF: RESTIC_PASSWORD_FILE $RESTIC_PASSWORD_FILE is not readable"
	elif [ -z "${RESTIC_PASSWORD:-}" ]; then
		die "$CONF: set RESTIC_PASSWORD or RESTIC_PASSWORD_FILE"
	fi
	case "$RESTIC_REPOSITORY" in
		*ACCOUNT_ID* | */BUCKET) die "$CONF: RESTIC_REPOSITORY still has the example placeholders" ;;
		s3:*)
			[ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] \
				|| die "$CONF: an s3: repository needs AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
			;;
		/*) ;;
		*) die "$CONF: RESTIC_REPOSITORY must be s3:https://... or an absolute local path" ;;
	esac

	OFFSITE_UPLOADS_VOLUME=${OFFSITE_UPLOADS_VOLUME:-fluxer_seaweedfs-data}
	OFFSITE_CACHE_VOLUME=${OFFSITE_CACHE_VOLUME:-fluxer-restic-cache}
	OFFSITE_HOST=${OFFSITE_HOST:-$(hostname)}
	OFFSITE_KEEP_DAILY=${OFFSITE_KEEP_DAILY:-14}
	OFFSITE_KEEP_WEEKLY=${OFFSITE_KEEP_WEEKLY:-8}
	OFFSITE_KEEP_MONTHLY=${OFFSITE_KEEP_MONTHLY:-12}
	OFFSITE_MAX_AGE_HOURS=${OFFSITE_MAX_AGE_HOURS:-36}
}

# Run restic in its container. Extra mounts come from MOUNT_BACKUP (a host backup
# dir), MOUNT_UPLOADS=1 (the uploads volume) and MOUNT_TARGET (a restore dir).
restic_run() {
	set -- "$RESTIC_IMAGE" --cache-dir /cache "$@"
	[ -n "${MOUNT_TARGET:-}" ] && set -- -v "$MOUNT_TARGET:/restore" "$@"
	[ "${MOUNT_UPLOADS:-0}" -eq 1 ] && set -- -v "$OFFSITE_UPLOADS_VOLUME:/fluxer/seaweedfs-data:ro" "$@"
	[ -n "${MOUNT_BACKUP:-}" ] && set -- -v "$MOUNT_BACKUP:/fluxer/backup:ro" "$@"
	case "$RESTIC_REPOSITORY" in
		/*) set -- -v "$RESTIC_REPOSITORY:$RESTIC_REPOSITORY" "$@" ;;
	esac
	if [ -n "${RESTIC_PASSWORD_FILE:-}" ]; then
		set -- -v "$RESTIC_PASSWORD_FILE:/run/restic-password:ro" \
			-e RESTIC_PASSWORD_FILE=/run/restic-password "$@"
	else
		set -- -e RESTIC_PASSWORD "$@"
	fi
	for v in RESTIC_REPOSITORY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION; do
		set -- -e "$v" "$@"
	done
	docker run --rm --network host -v "$OFFSITE_CACHE_VOLUME:/cache" "$@"
}

# Same resolution as `fluxer`: ours in BACKUP_ROOT, the installer's pre-upgrade
# records in <deployment>/backups, newest with a fluxer.dump wins.
newest_backup() {
	ls -dt "$BACKUP_ROOT"/*/ "$FLUXER_DIR"/backups/*/ 2> /dev/null | while read -r d; do
		[ -f "$d/fluxer.dump" ] && { printf '%s\n' "${d%/}"; break; }
	done
}

cmd_init() {
	load_conf
	rc=0
	err=$(restic_run cat config 2>&1 > /dev/null) || rc=$?
	case "$rc" in
		0) echo "Repository already initialised: $RESTIC_REPOSITORY"; return 0 ;;
		10) ;;
		12) die "A repository exists at $RESTIC_REPOSITORY but the password is wrong." ;;
		*) printf '%s\n' "$err" >&2; die "Could not reach $RESTIC_REPOSITORY (restic exit $rc)." ;;
	esac
	restic_run init
	cat <<EOF

Repository created. Now, before anything else:
  store RESTIC_PASSWORD somewhere that is NOT this host (password manager).
  Without it the repository cannot be decrypted by anyone, including you.
EOF
}

apply_retention() {
	restic_run forget --prune --retry-lock 30m \
		--host "$OFFSITE_HOST" --tag fluxer \
		--keep-daily "$OFFSITE_KEEP_DAILY" \
		--keep-weekly "$OFFSITE_KEEP_WEEKLY" \
		--keep-monthly "$OFFSITE_KEEP_MONTHLY"
}

push_exit() {
	if [ "$push_done" -eq 1 ]; then
		notify ok offsite "off-site push ok: $push_name"
	else
		notify alert offsite "off-site push FAILED at $push_stage: ${push_name:-?} (exit $1), see $BACKUP_ROOT/offsite.log"
		say "push FAILED at $push_stage (exit $1)" >&2
	fi
}

cmd_push() {
	if_configured=0
	src=''
	for a in "$@"; do
		case "$a" in
			--if-configured) if_configured=1 ;;
			-*) die "push: unknown option $a" ;;
			*) [ -z "$src" ] || die "push: one backup dir at most"; src=$a ;;
		esac
	done
	if ! configured; then
		[ "$if_configured" -eq 1 ] && exit 0
		not_configured
	fi

	push_done=0 push_name='' push_stage=setup
	trap 'push_exit $?' EXIT
	trap 'exit 130' INT TERM
	load_conf

	if [ -z "$src" ]; then
		d=$(newest_backup)
		[ -n "$d" ] || die "no backup with a fluxer.dump found in $BACKUP_ROOT"
	else
		case "$src" in
			/*) d=${src%/} ;;
			*) if [ -d "$BACKUP_ROOT/$src" ]; then d="$BACKUP_ROOT/$src"
			   else d="$FLUXER_DIR/backups/$src"; fi ;;
		esac
	fi
	[ -f "$d/fluxer.dump" ] || die "no fluxer.dump in $d"
	[ -f "$d/.env" ] || printf 'WARNING: %s has no .env; this snapshot alone cannot be restored\n' "$d" >&2
	push_name=$(basename "$d")
	docker volume inspect "$OFFSITE_UPLOADS_VOLUME" > /dev/null 2>&1 \
		|| die "uploads volume $OFFSITE_UPLOADS_VOLUME does not exist"

	# Stable in-container paths and an explicit --host are what let restic find
	# the previous snapshot as a parent; the container's own hostname is random.
	# offsite.conf is left out: the key to a repository is no use inside it.
	push_stage=backup
	say "push $push_name -> $RESTIC_REPOSITORY"
	MOUNT_BACKUP=$d MOUNT_UPLOADS=1 restic_run backup --retry-lock 30m \
		--host "$OFFSITE_HOST" --tag fluxer --tag "backup:$push_name" \
		--exclude /fluxer/backup/seaweedfs-data.tgz \
		--exclude /fluxer/backup/ops/offsite.conf \
		/fluxer/backup /fluxer/seaweedfs-data

	push_stage=retention
	say "retention: daily $OFFSITE_KEEP_DAILY, weekly $OFFSITE_KEEP_WEEKLY, monthly $OFFSITE_KEEP_MONTHLY"
	apply_retention

	push_done=1
	say "push ok $push_name"
}

cmd_forget() {
	load_conf
	apply_retention
}

cmd_snapshots() {
	load_conf
	restic_run snapshots "$@"
}

cmd_check() {
	load_conf
	for a in "$@"; do
		case "$a" in
			--read-data | --read-data-subset=*) ;;
			*) die "check: unknown option $a (use --read-data-subset=5% or --read-data)" ;;
		esac
	done
	restic_run check --retry-lock 30m "$@"
}

cmd_restore() {
	[ $# -eq 2 ] || die "usage: offsite.sh restore <snapshot|latest> <target-dir>"
	load_conf
	snap=$1
	target=$2
	case "$target" in /*) ;; *) target="$PWD/$target" ;; esac
	target=${target%/}
	case "$target" in
		/var/lib/docker | /var/lib/docker/*) die "refusing to restore into Docker's storage; pick a plain directory" ;;
	esac
	if [ -e "$target" ]; then
		[ -d "$target" ] && [ -z "$(ls -A "$target")" ] \
			|| die "$target exists and is not an empty directory; restore only into a fresh one"
	fi
	mkdir -p "$target"

	# `latest` is not narrowed by host: after losing the box, the new one has a
	# different hostname. Pass a snapshot ID if the repository holds several hosts.
	set -- "$snap"
	[ "$snap" = latest ] && set -- latest --tag fluxer
	echo "Restoring snapshot $snap into $target"
	MOUNT_TARGET=$target restic_run restore "$@" --target /restore --verify

	# Rebuild the shape `fluxer restore` expects. tar runs as root so the uploads
	# keep their numeric owners inside the archive; the files on disk are then
	# handed to whoever ran this.
	echo "Packing uploads into seaweedfs-data.tgz"
	docker run --rm --network none -v "$target:/restore" alpine:3.22 sh -eu -c '
		cd /restore
		[ -f fluxer/backup/fluxer.dump ] || { echo "snapshot has no fluxer.dump" >&2; exit 1; }
		if [ -d fluxer/seaweedfs-data ]; then
			tar czf fluxer/backup/seaweedfs-data.tgz -C fluxer/seaweedfs-data .
			rm -rf fluxer/seaweedfs-data
		fi
		mv fluxer/backup backup
		rmdir fluxer
		chown -R "$1:$2" /restore
	' sh "$(id -u)" "$(id -g)"

	cat <<EOF

Restored into $target/backup, a backup directory like any auto-* one:
$(cd "$target/backup" && ls -A | sed 's/^/  /')

Next steps:
  1. Read $target/backup/.env against the live .env. A restore onto a
     fresh host needs this .env in place first: it holds the database and
     object-store secrets.
  2. Prove the dump restores without touching live (verify-backup checks the
     newest backup, which a fresh copy is):
       cp -r $target/backup $BACKUP_ROOT/offsite-restore && fluxer verify-backup
  3. Apply it (destructive, asks first):
       fluxer restore $target/backup
EOF
}

cmd_status() {
	if ! configured; then
		echo "offsite    not configured ($CONF missing)"
		echo "           Off-site backups are off; local backups only. See offsite.conf.example."
		exit 0
	fi
	load_conf
	printf 'offsite    %s\n' "$RESTIC_REPOSITORY"

	rc=0
	err=$(restic_run cat config 2>&1 > /dev/null) || rc=$?
	case "$rc" in
		0) echo "repo       reachable" ;;
		10) echo "repo       NOT INITIALISED - run: offsite.sh init"; exit 1 ;;
		12) echo "repo       WRONG PASSWORD"; exit 1 ;;
		*) echo "repo       UNREACHABLE (restic exit $rc)"; printf '%s\n' "$err" | tail -n 3 | sed 's/^/           /'; exit 1 ;;
	esac

	last=$(restic_run snapshots --json --host "$OFFSITE_HOST" --tag fluxer --latest 1 \
		| python3 -c '
import datetime, json, re, sys
snaps = json.load(sys.stdin) or []
if not snaps:
    sys.exit(0)
def when(s):
    # restic writes nanoseconds, which fromisoformat does not take.
    t = re.sub(r"\.\d+", "", s["time"]).replace("Z", "+00:00")
    return datetime.datetime.fromisoformat(t)
s = max(snaps, key=when)
age = int((datetime.datetime.now(datetime.timezone.utc) - when(s)).total_seconds())
name = next((x[7:] for x in s.get("tags") or [] if x.startswith("backup:")), "?")
print(age, s["short_id"], name)
')
	if [ -z "$last" ]; then
		echo "last push  NONE for host $OFFSITE_HOST"
		exit 1
	fi
	# shellcheck disable=SC2086 # three space-free fields, split on purpose
	set -- $last
	h=$(($1 / 3600))
	if [ "$h" -ge 24 ]; then ago="$((h / 24))d $((h % 24))h"; else ago="${h}h $(($1 % 3600 / 60))m"; fi
	if [ "$1" -gt $((OFFSITE_MAX_AGE_HOURS * 3600)) ]; then
		printf 'last push  STALE %s ago (%s, snapshot %s; limit %sh)\n' "$ago" "$3" "$2" "$OFFSITE_MAX_AGE_HOURS"
		exit 1
	fi
	printf 'last push  %s ago (%s, snapshot %s)\n' "$ago" "$3" "$2"
}

cmd=${1:-help}
[ $# -gt 0 ] && shift || true

case "$cmd" in
	status) cmd_status ;;
	init) cmd_init ;;
	push) cmd_push "$@" ;;
	snapshots) cmd_snapshots "$@" ;;
	check) cmd_check "$@" ;;
	restore) cmd_restore "$@" ;;
	forget) cmd_forget ;;
	restic) load_conf; restic_run "$@" ;;
	help | --help | -h) usage ;;
	*) printf 'unknown command: %s\n\n' "$cmd" >&2; usage >&2; exit 2 ;;
esac
