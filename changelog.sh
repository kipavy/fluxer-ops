#!/bin/sh
# What an update would bring, before running one.
#
# Upstream writes no release notes. Each component is released on its own, as
# tags like fluxer-api@2026.913.183320, and a release body is only a compare
# link. What does exist: every image is labelled with the commit it was built
# from (org.opencontainers.image.revision), and the registry says which image
# the tag in .env (v1) points at right now. So this compares, per component,
# the revision running here with the revision on that tag, and lists the commit
# subjects in between. Third-party images move only when docker-compose.yml
# does, so those are compared against upstream's compose file.
#
# Deliberately not the GitHub API: unauthenticated it allows 60 requests an hour
# and caps a compare at 250 commits. The registry is asked anonymously, and the
# commits come from a throwaway blobless clone (a few MB), which has neither limit.
#
#   ./changelog.sh          versions, then the newest 60 commits an update brings
#   ./changelog.sh --all    every commit
#   ./changelog.sh --summary
#                           chat markdown instead: what changed per component, then
#                           the commits grouped and filtered by changelog_fmt.py
#                           (what autoupdate.sh posts to its channel)
set -eu

. "$(dirname "$(readlink -f "$0")")/lib.sh"
need_instance
REPO=${FLUXER_SOURCE_REPO:-https://github.com/fluxerapp/fluxer}
RAW_BASE='https://raw.githubusercontent.com/fluxerapp/fluxer'
LIMIT=60
SUMMARY=0
case "${1:-}" in
	'') ;;
	--all) LIMIT=0 ;;
	--summary) SUMMARY=1 ;;
	*) echo "usage: changelog.sh [--all | --summary]" >&2; exit 2 ;;
esac

die() { printf '%s\n' "$*" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$FLUXER_DIR"
# --summary: the human report still gets built (same code path, nothing to
# drift), into a file; the summary is written to the real stdout at the end.
if [ "$SUMMARY" -eq 1 ]; then exec 3>&1 > "$tmp/human"; fi

env_value() { sed -n "s/^$1=//p" .env | head -n 1; }
tag=$(env_value FLUXER_IMAGE_TAG)
tag=${tag:-v1}
case "$tag" in v1 | latest) ref=main ;; *) ref=$tag ;; esac

domain=$(env_value FLUXER_DOMAIN)
live=$(curl -sS -I --max-time 15 "https://$domain/api/_health" 2>/dev/null \
	| sed -n 's/^[Xx]-[Ff]luxer-[Vv]ersion: *//p' | tr -d '\r') || live=''
printf 'instance   https://%s reports version %s\n' "$domain" "${live:-unknown (no answer)}"
printf 'image tag  %s (from .env)\n\n' "$tag"

# 1. What runs: the image each container was created from, not what the tag
#    points at locally now (a pull without a recreate moves the tag).
docker compose ps -aq > "$tmp/containers" || die "docker compose ps failed in $FLUXER_DIR"
[ -s "$tmp/containers" ] || die "no containers in $FLUXER_DIR, so nothing to compare."
xargs docker inspect --format '{{.Config.Image}} {{.Image}}' < "$tmp/containers" | sort -u > "$tmp/running"
: > "$tmp/fluxer"
while read -r image id; do
	case "$image" in */fluxer-*) ;; *) continue ;; esac
	docker image inspect --format \
		'{{index .Config.Labels "org.opencontainers.image.version"}}|{{index .Config.Labels "org.opencontainers.image.revision"}}|{{join .RepoDigests ","}}' \
		"$id" | { IFS='|' read -r ver rev digests
		printf '%s %s %s %s %s\n' "$image" "${ver:--}" "${rev:--}" "${digests:--}" "$id"; } >> "$tmp/fluxer"
done < "$tmp/running"
[ -s "$tmp/fluxer" ] || die "no fluxer-* image is running here."

# 2. What the tag points at in the registry, anonymously (the same token dance
#    docker pull does), for this host's platform.
platform=$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null || echo linux/amd64)
# shellcheck disable=SC2046 # one argument per image reference, none has spaces
python3 "$OPS/registry.py" manifests "$platform" $(awk '{ print $1 }' "$tmp/fluxer") > "$tmp/remote"

# 3. The history, without the API. Tags come along, for the latest-release column.
repo_ok=1
git clone -q --bare --filter=blob:none "$REPO" "$tmp/repo" 2> "$tmp/git-err" || repo_ok=0
[ "$repo_ok" -eq 1 ] || printf 'note: could not clone %s (%s); commit lists skipped.\n\n' "$REPO" "$(tail -n 1 "$tmp/git-err")"
g() { git -C "$tmp/repo" "$@"; }
has_commit() { [ "$repo_ok" -eq 1 ] && [ "$1" != '-' ] && g cat-file -e "$1^{commit}" 2>/dev/null; }

# An image without a revision label: a SHA-looking version is the revision, and a
# CalVer version is a release tag that names its commit.
revision_of() { # component version revision
	case "$3" in -) ;; *) printf '%s' "$3"; return ;; esac
	if printf '%s' "$2" | grep -Eq '^[0-9a-f]{7,40}$'; then printf '%s' "$2"; return; fi
	if [ "$repo_ok" -eq 1 ] && [ "$2" != '-' ]; then
		for t in "$1@$2" "$2"; do
			g rev-parse -q --verify "refs/tags/$t^{commit}" 2>/dev/null && return
		done
	fi
	printf -- '-'
}
latest_release() {
	[ "$repo_ok" -eq 1 ] || { printf -- '-'; return; }
	g tag -l "$1@*" | sed "s/^$1@//" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 | grep . || printf -- '-'
}

printf '%-30s %-17s %-17s %-17s %s\n' COMPONENT RUNNING "ON $tag" 'LATEST RELEASE' ''
: > "$tmp/ranges"; : > "$tmp/unknown"; : > "$tmp/changed"; : > "$tmp/thirdparty"
while read -r image ver rev digests id; do
	comp=${image##*/}; comp=${comp%:*}
	rev=$(revision_of "$comp" "$ver" "$rev")
	read -r _ rver rrev rdigest status <<-EOF
	$(awk -v r="$image" '$1 == r' "$tmp/remote")
	EOF
	rrev=$(revision_of "$comp" "${rver:--}" "${rrev:--}")
	note=''
	if [ "${status:-}" != 'ok' ]; then
		note="(${status:-registry not asked})"
	elif printf '%s' "$digests" | tr ',' '\n' | grep -q "@$rdigest\$"; then
		note='up to date'
	elif [ "$rev" != '-' ] && [ "$rev" = "$rrev" ]; then
		note='same commit, rebuilt image'
	elif has_commit "$rev" && has_commit "$rrev"; then
		n=$(g rev-list --count "$rrev" "^$rev")
		back=$(g rev-list --count "$rev" "^$rrev")
		if [ "$n" -eq 0 ] && [ "$back" -gt 0 ]; then
			note="running is $back commit(s) AHEAD of $tag"
		else
			note="$n commit(s) behind"
			printf '%s %s\n' "$rev" "$rrev" >> "$tmp/ranges"
		fi
	else
		note='revision unknown, cannot list commits'
		printf '%s %s %s\n' "$comp" "$rev" "$rrev" >> "$tmp/unknown"
	fi
	case "$note" in 'up to date' | '('*) ;; *) printf '%s %s %s\n' "$comp" "$ver" "${rver:--}" >> "$tmp/changed" ;; esac
	printf '%-30s %-17s %-17s %-17s %s\n' "$comp" "$ver" "${rver:--}" "$(latest_release "$comp")" "$note"
done < "$tmp/fluxer"

# 4. Third-party images: pinned in docker-compose.yml, so they change when the
#    refreshed file does. install.sh refuses a postgres major bump outright.
if curl -fsSL --max-time 30 "$RAW_BASE/$ref/deploy/self-hosting/docker-compose.yml" -o "$tmp/upstream.yml"; then
	sed -n 's/^[[:space:]]*image:[[:space:]]*//p' docker-compose.yml | grep -v 'fluxer-' | sort -u > "$tmp/img-local"
	sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$tmp/upstream.yml" | grep -v 'fluxer-' | sort -u > "$tmp/img-up"
	echo
	if cmp -s "$tmp/img-local" "$tmp/img-up"; then
		echo "Third-party images: unchanged in upstream's docker-compose.yml ($ref)."
	else
		echo "Third-party images that change with the next update (docker-compose.yml at $ref):"
		comm -3 "$tmp/img-local" "$tmp/img-up" | awk -F'\t' '
			$1 != "" { r = $1; sub(/:[^:\/]*$/, "", r); old[r] = $1 }
			$2 != "" { r = $2; sub(/:[^:\/]*$/, "", r); new[r] = $2 }
			END {
				for (r in old) printf "  %-40s -> %s\n", old[r], (r in new ? new[r] : "(removed)")
				for (r in new) if (!(r in old)) printf "  %-40s -> %s\n", "(new)", new[r]
			}' | sort | tee "$tmp/thirdparty"
		pg_old=$(sed -n 's/^postgres:\([0-9][0-9]*\).*/\1/p' "$tmp/img-local")
		pg_new=$(sed -n 's/^postgres:\([0-9][0-9]*\).*/\1/p' "$tmp/img-up")
		if [ -n "$pg_old" ] && [ -n "$pg_new" ] && [ "$pg_old" != "$pg_new" ]; then
			echo "  WARNING: postgres $pg_old -> $pg_new is a major version change. install.sh --update refuses it; it needs a dump and restore." \
				| tee -a "$tmp/thirdparty"
		fi
	fi
else
	printf '\nThird-party images: could not fetch upstream docker-compose.yml at %s.\n' "$ref"
fi

summary() { # chat markdown on fd 3; commit subjects (sha TAB subject) on stdin
	{
		if [ -s "$tmp/changed" ]; then
			echo "**Composants**"
			while read -r comp ver rver; do printf -- '- %s %s → %s\n' "${comp#fluxer-}" "$ver" "$rver"; done < "$tmp/changed"
		fi
		if [ -s "$tmp/thirdparty" ]; then
			echo "**Images tierces**"
			sed 's/^ *//; s/  */ /g; s/^/- /' "$tmp/thirdparty"
		fi
		[ -s "$tmp/unknown" ] && printf '_Pas de liste de commits pour : %s_\n' "$(awk '{ print $1 }' "$tmp/unknown" | tr '\n' ' ')"
		echo
		# One compare link for the lot: the oldest running revision to the newest
		# available one (fewest / most commits in their history).
		if [ -s "$tmp/ranges" ]; then
			oldest=$(awk '{ print $1 }' "$tmp/ranges" | sort -u | while read -r r; do
				printf '%s %s\n' "$(g rev-list --count "$r")" "$r"; done | sort -n | head -n 1 | cut -d' ' -f2)
			newest=$(awk '{ print $2 }' "$tmp/ranges" | sort -u | while read -r r; do
				printf '%s %s\n' "$(g rev-list --count "$r")" "$r"; done | sort -n | tail -n 1 | cut -d' ' -f2)
			python3 "$OPS/changelog_fmt.py" --compare "$REPO/compare/$oldest...$newest"
		else
			python3 "$OPS/changelog_fmt.py"
		fi
	} >&3
}

# 5. The commits: union of every component's range, newest first. A commit
#    listed here is in some component's update; not every commit touches every one.
echo
if [ -s "$tmp/unknown" ]; then
	while read -r comp rev rrev; do
		if [ "$rev" = '-' ] || [ "$rrev" = '-' ]; then
			printf 'No commit list for %s (no revision to compare). Releases: %s/releases\n' "$comp" "$REPO"
		else
			printf 'No commit list for %s. Compare by hand: %s/compare/%s...%s\n' "$comp" "$REPO" "$rev" "$rrev"
		fi
	done < "$tmp/unknown"
	echo
fi
if [ ! -s "$tmp/ranges" ]; then
	echo "No new commits to list."
	[ "$SUMMARY" -eq 0 ] || summary < /dev/null
	exit 0
fi
while read -r rev rrev; do
	g rev-list "$rrev" "^$rev"
done < "$tmp/ranges" | sort -u > "$tmp/commits"
if [ "$SUMMARY" -eq 1 ]; then
	g log --no-walk=sorted --stdin --format='%h%x09%s' < "$tmp/commits" | summary
	exit 0
fi
total=$(grep -c . "$tmp/commits")
shown=$total
[ "$LIMIT" -eq 0 ] || [ "$total" -le "$LIMIT" ] || shown=$LIMIT
printf 'Commits an update brings: %s' "$total"
[ "$shown" -eq "$total" ] && echo || printf ' (newest %s; --all for every one)\n' "$shown"
g log --no-walk=sorted --stdin --date=short --format='  %h %ad %s' < "$tmp/commits" | head -n "$shown"
