#!/bin/sh
# Reclaim disk from old Docker images without breaking `fluxer rollback`.
#
# Why not `docker image prune`: on the moving v1 tag, install.sh --rollback puts
# the image IDs from the newest backups/record-*/images back onto v1. After an
# update those old images carry no tag at all, which makes them *dangling*, so
# even a plain `docker image prune` (no -a) deletes exactly what a rollback
# needs, and the rollback then fails with "every recorded image has been
# removed from this host". This removes only what nothing can want:
#
#   kept      images of any container on the host, running or stopped
#             images the current compose file resolves to
#             image IDs (and refs) in the newest N installer records
#   removed   dangling images of a repository the stack uses, and registry
#             fluxer-* images, that are in none of the above
#
# Anything else, including other projects' images, is not ours and is left alone.
#
#   ./prune.sh              list what would go and how much it frees, change nothing
#   ./prune.sh --apply      the same, then ask, then `docker image rm` each by ID
#   ./prune.sh --keep N     keep the images of the newest N records (default 2)
set -eu

. "$(dirname "$(readlink -f "$0")")/lib.sh"
need_instance
RECORD_DIR=${RECORD_DIR:-$FLUXER_DIR/backups}
KEEP=2
APPLY=0
while [ $# -gt 0 ]; do
	case "$1" in
		--apply) APPLY=1 ;;
		--keep) [ $# -ge 2 ] || { echo "--keep needs a number" >&2; exit 2; }; KEEP=$2; shift ;;
		*) echo "usage: prune.sh [--apply] [--keep N]" >&2; exit 2 ;;
	esac
	shift
done
# 0 would drop the images the very next rollback reads. The newest record is
# not always enough either: an update that fails after recording leaves a record
# of the state already running, and the real previous release is one further back.
case "$KEEP" in
	'' | *[!0-9]* | 0) echo "--keep takes a whole number of records, 1 or more" >&2; exit 2 ;;
esac

die() { printf '%s\n' "$*" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# docker prints sizes as 1.13GB, 447MB, 8.54kB (powers of 1000).
human() { awk -v b="$1" 'BEGIN { split("B kB MB GB TB", u, " "); i = 1
	while (b >= 1000 && i < 5) { b /= 1000; i++ } printf (i == 1 ? "%d%s" : "%.1f%s"), b, u[i] }'; }

# 1. Everything that must survive. Each line: <image id> <reason>.
: > "$tmp/keep"
docker ps -aq --no-trunc > "$tmp/containers" || die "docker ps failed; refusing to guess what is in use."
if [ -s "$tmp/containers" ]; then
	xargs docker inspect --format '{{.Image}} container {{slice .Name 1}}' < "$tmp/containers" >> "$tmp/keep" \
		|| die "docker inspect failed; refusing to guess what is in use."
fi

(cd "$FLUXER_DIR" && docker compose config --images) > "$tmp/refs" 2> "$tmp/compose-err" \
	|| die "docker compose config --images failed in $FLUXER_DIR, so the stack's images are unknown. Nothing removed.
$(cat "$tmp/compose-err")"
[ -s "$tmp/refs" ] || die "the compose file in $FLUXER_DIR names no images. Nothing removed."
sort -u "$tmp/refs" -o "$tmp/refs"
# The registry as compose resolves it (.env may spell it as ${...}).
registry=$(sed -n 's|/fluxer-[^/]*$||p' "$tmp/refs" | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')
[ -n "$registry" ] || die "no fluxer-* image in the compose file; cannot tell which registry is Fluxer's."

resolve() { docker image inspect --format '{{.Id}}' "$1" 2>/dev/null || true; }
while read -r ref; do
	id=$(resolve "$ref")
	[ -z "$id" ] || printf '%s compose %s\n' "$id" "$ref" >> "$tmp/keep"
done < "$tmp/refs"

# Record names carry a UTC stamp, so byte order is age order (as install.sh reads them).
for rec in "$RECORD_DIR"/record-*; do
	[ -d "$rec" ] && printf '%s\n' "$rec"
done | sort -r > "$tmp/records"
head -n "$KEEP" "$tmp/records" > "$tmp/records-kept"
tail -n +"$((KEEP + 1))" "$tmp/records" > "$tmp/records-old"
: > "$tmp/known-repos"
while read -r rec; do
	[ -f "$rec/images" ] || continue
	awk '{ r = $1; sub(/:[^:\/]*$/, "", r); print r }' "$rec/images" >> "$tmp/known-repos"
done < "$tmp/records"
while read -r rec; do
	name=${rec##*/}
	if [ ! -e "$rec/images" ]; then
		echo "note: $name records no images, so it protects nothing (and cannot be rolled back to)." >&2
		continue
	fi
	[ -r "$rec/images" ] || die "cannot read $rec/images; refusing to prune what it may need."
	while read -r ref id; do
		[ -n "$ref" ] || continue
		# A moving tag rolls back by ID; a pinned tag by the tag itself. Keep both.
		[ "$id" = '-' ] || printf '%s rollback %s(%s)\n' "$id" "$name" "$ref" >> "$tmp/keep"
		rid=$(resolve "$ref")
		[ -z "$rid" ] || [ "$rid" = "$id" ] || printf '%s rollback %s(%s)\n' "$rid" "$name" "$ref" >> "$tmp/keep"
	done < "$rec/images"
done < "$tmp/records-kept"
sed 's|:[^:/]*$||' "$tmp/refs" >> "$tmp/known-repos"
sort -u "$tmp/known-repos" -o "$tmp/known-repos"

# 2. Every image, with its unique size (what removing it alone frees).
docker system df -v --format '{{json .}}' > "$tmp/df.json" || die "docker system df failed."
# system df names no repository for an untagged image; docker images does (from its digest).
# It also lists an image once however many tags it has; docker images lists every tag.
docker images --no-trunc --format '{{.ID}} {{.Repository}} {{.Tag}}' > "$tmp/repos" || die "docker images failed."
python3 - "$tmp/df.json" "$tmp/repos" > "$tmp/images" <<'PY'
import json, re, sys
units = {"B": 1, "kB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12}
def b(s):
    m = re.match(r"([\d.]+)\s*([kMGT]?B)", s or "0B")
    return int(float(m.group(1)) * units[m.group(2)]) if m else 0
repos, tags = {}, {}
for line in open(sys.argv[2]):
    k, r, t = line.split()
    if r != "<none>":
        repos.setdefault(k, r)
        if t != "<none>":
            tags.setdefault(k, []).append(r + ":" + t)
seen = {}
for i in json.load(open(sys.argv[1]))["Images"]:
    seen.setdefault(i["ID"], [b(i["UniqueSize"]), b(i["Size"]), repos.get(i["ID"], "<none>"), tags.get(i["ID"], [])])
for k, (u, s, repo, tags) in seen.items():
    print(k, u, s, repo, ",".join(tags) or "-")
PY

# 3. Sort each image into kept, candidate, or not ours.
: > "$tmp/cand"; : > "$tmp/rollback"; : > "$tmp/unsure"
used=0; used_n=0
while read -r id uniq _size repo tags; do
	why=$(awk -v i="$id" '$1 == i { $1 = ""; sub(/^ /, ""); print; exit }' "$tmp/keep")
	case "$why" in
		rollback*)
			why_all=$(awk -v i="$id" '$1 == i && $2 == "rollback" { print $3 }' "$tmp/keep" | sort -u | tr '\n' ' ')
			printf '%s %s %s\n' "$id" "$uniq" "$why_all" >> "$tmp/rollback"
			continue ;;
		?*) used=$((used + uniq)); used_n=$((used_n + 1)); continue ;;
	esac
	if [ "$tags" = '-' ]; then
		if [ "$repo" != '<none>' ] && grep -qxF "$repo" "$tmp/known-repos"; then
			printf '%s %s %s dangling\n' "$id" "$uniq" "$repo" >> "$tmp/cand"
		else
			printf '%s %s %s dangling, but not a repository this stack uses\n' "$id" "$uniq" "$repo" >> "$tmp/unsure"
		fi
		continue
	fi
	ours=1
	for t in $(printf '%s' "$tags" | tr ',' ' '); do
		case "$t" in "$registry"/fluxer-*) ;; *) ours=0 ;; esac
	done
	if [ "$ours" -eq 1 ]; then
		printf '%s %s %s in no container, record or compose file\n' "$id" "$uniq" "$tags" >> "$tmp/cand"
	else
		case "$tags" in
			*"$registry"/fluxer-*) printf '%s %s %s also tagged outside %s\n' "$id" "$uniq" "$tags" "$registry" >> "$tmp/unsure" ;;
		esac
	fi
done < "$tmp/images"

short() { printf '%.19s' "$1"; }
sum() { awk '{ s += $2 } END { print s + 0 }' "$1"; }

printf 'In use by containers or the compose file: %s images, %s unique\n' "$used_n" "$(human "$used")"

echo
if [ -s "$tmp/records-kept" ]; then
	printf 'Kept for rollback (newest %s record(s): %s): %s images, %s unique\n' "$KEEP" \
		"$(sed 's|.*/||' "$tmp/records-kept" | tr '\n' ' ' | sed 's/ $//')" \
		"$(grep -c . "$tmp/rollback" || true)" "$(human "$(sum "$tmp/rollback")")"
	while read -r id uniq why; do
		printf '  %s  %8s  %s\n' "$(short "$id")" "$(human "$uniq")" "$why"
	done < "$tmp/rollback"
else
	echo "No installer records in $RECORD_DIR, so there is no rollback to protect."
fi

if [ -s "$tmp/unsure" ]; then
	echo
	echo "Left alone, not clearly Fluxer's:"
	while read -r id uniq what why; do
		printf '  %s  %8s  %s  (%s)\n' "$(short "$id")" "$(human "$uniq")" "$what" "$why"
	done < "$tmp/unsure"
fi

echo
n=$(grep -c . "$tmp/cand" || true)
total=$(sum "$tmp/cand")
if [ "$n" -eq 0 ]; then
	echo "Removable: nothing."
else
	echo "Removable:"
	while read -r id uniq what why; do
		printf '  %s  %8s  %s  (%s)\n' "$(short "$id")" "$(human "$uniq")" "$what" "$why"
	done < "$tmp/cand"
	# Unique size undercounts layers shared only between candidates.
	printf 'Total: %s images, at least %s\n' "$n" "$(human "$total")"
fi

if [ -s "$tmp/records-old" ]; then
	echo
	echo "Older installer records (not used by rollback; never deleted here):"
	while read -r rec; do
		printf '  %-28s %6s\n' "${rec##*/}" "$(du -sh "$rec" 2>/dev/null | cut -f1)"
	done < "$tmp/records-old"
	echo "  Their images are not protected. Remove a record by hand with rm -rf once you are sure of the release."
fi

bc=$(docker system df --format '{{.Type}}|{{.Size}}|{{.Reclaimable}}' | awk -F'|' '$1 == "Build Cache" { print $2 " (" $3 " reclaimable)" }')
printf '\nBuild cache: %s. Not touched here; docker builder prune clears it.\n' "${bc:-unknown}"

[ "$APPLY" -eq 1 ] || { [ "$n" -eq 0 ] || printf '\nNothing changed. Run with --apply to remove the images above.\n'; exit 0; }
[ "$n" -gt 0 ] || exit 0
# No record at all more often means the installer kept them elsewhere
# (--backup-dir) than that there is no rollback, and guessing wrong is the one
# mistake this script exists to prevent.
[ -s "$tmp/records" ] || die "
No installer records in $RECORD_DIR, so rollback images cannot be told apart.
If install.sh ran with --backup-dir, set RECORD_DIR to it. Nothing removed."

printf '\nRemove these %s image(s)? [y/N] ' "$n"
read -r reply || reply=''
case "$reply" in
	y | Y | yes | YES) ;;
	*) echo "Aborted. Nothing changed."; exit 0 ;;
esac

# By ID and never forced: docker itself then refuses an image a container uses
# or one tagged into several repositories, which is the last safety net.
failed=0
while read -r id uniq what why; do
	if docker image rm "$id" > "$tmp/rm.out" 2>&1; then
		printf 'removed  %s  %s\n' "$(short "$id")" "$what"
	else
		failed=$((failed + 1))
		printf 'KEPT     %s  %s: %s\n' "$(short "$id")" "$what" "$(tail -n 1 "$tmp/rm.out")" >&2
	fi
done < "$tmp/cand"
[ "$failed" -eq 0 ] || { echo "$failed image(s) could not be removed; see above." >&2; exit 1; }
