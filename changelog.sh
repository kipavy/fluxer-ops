#!/bin/sh
# What an update would bring, before running one.
#
# Upstream writes no release notes. rexctl moves the whole stack from one release to
# the next, and each release is a git tag, fluxer-release@<version>, that names the
# commit every image of it was built from. What runs here is known too: every image is
# labelled with the commit it was built from (org.opencontainers.image.revision). So
# this lists, per component, the commits between the revision running here and the
# release `rexctl upgrade` would install. Third-party images are pinned in that
# release's compose file, so those are compared against it.
#
# Deliberately not the GitHub API: unauthenticated it allows 60 requests an hour and
# caps a compare at 250 commits. The commits come from a throwaway blobless clone (a
# few MB), which has neither limit.
#
#   ./changelog.sh              versions, then the newest 60 commits an update brings
#   ./changelog.sh --all        every commit
#   ./changelog.sh --summary    chat markdown instead: what changed per component, then
#                               the commits grouped and filtered by changelog_fmt.py
#                               (what autoupdate.sh posts to its channel)
#   ./changelog.sh --to VERSION against that release instead of the latest
set -eu

. "$(dirname "$(readlink -f "$0")")/lib.sh"
need_rexctl
REPO=${FLUXER_SOURCE_REPO:-https://github.com/fluxerapp/fluxer}
STACK_COMPOSE=fluxer_rexctl/internal/stack/files/docker-compose.yml
LIMIT=60
SUMMARY=0
TO=''
while [ $# -gt 0 ]; do
	case "$1" in
		--all) LIMIT=0 ;;
		--summary) SUMMARY=1 ;;
		--to) [ $# -ge 2 ] || { echo "--to needs a version" >&2; exit 2; }; TO=$2; shift ;;
		*) echo "usage: changelog.sh [--all | --summary] [--to VERSION]" >&2; exit 2 ;;
	esac
	shift
done

die() { printf '%s\n' "$*" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# --summary: the human report still gets built (same code path, nothing to
# drift), into a file; the summary is written to the real stdout at the end.
if [ "$SUMMARY" -eq 1 ]; then exec 3>&1 > "$tmp/human"; fi

# 1. Where an upgrade goes: rexctl's own answer.
rexctl -q upgrade --check --json > "$tmp/check.json" 2> "$tmp/check.err" \
	|| die "rexctl upgrade --check failed: $(tail -n 1 "$tmp/check.err")"
read -r current latest <<EOF
$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("current") or "-", d.get("latest") or "-")' "$tmp/check.json")
EOF
target=${TO:-$latest}
[ "$target" != '-' ] || die "rexctl did not name a release to upgrade to."

domain=$(fx_domain)
live=$(curl -sS -I --max-time 15 "https://$domain/api/_health" 2>/dev/null \
	| sed -n 's/^[Xx]-[Ff]luxer-[Vv]ersion: *//p' | tr -d '\r') || live=''
printf 'instance   https://%s reports version %s\n' "$domain" "${live:-unknown (no answer)}"
printf 'release    %s here, %s %s\n\n' "$current" "$target" "$([ -n "$TO" ] && echo '(asked for)' || echo '(latest)')"

# 2. What runs: the image each container was created from, not what a tag points at
#    locally now.
compose ps -aq > "$tmp/containers" || die "docker compose ps failed for project $(fx_project)"
[ -s "$tmp/containers" ] || die "no containers for project $(fx_project), so nothing to compare."
xargs docker inspect --format '{{.Config.Image}} {{.Image}}' < "$tmp/containers" | sort -u > "$tmp/running"
: > "$tmp/fluxer"
while read -r image id; do
	case "$image" in */fluxer-*) ;; *) continue ;; esac
	docker image inspect --format \
		'{{index .Config.Labels "org.opencontainers.image.version"}}|{{index .Config.Labels "org.opencontainers.image.revision"}}' \
		"$id" | { IFS='|' read -r ver rev
		printf '%s %s %s\n' "$image" "${ver:--}" "${rev:--}"; } >> "$tmp/fluxer"
done < "$tmp/running"
[ -s "$tmp/fluxer" ] || die "no fluxer-* image is running here."

# 3. The history, without the API, tags included: the release tag names its commit.
repo_ok=1
git clone -q --bare --filter=blob:none "$REPO" "$tmp/repo" 2> "$tmp/git-err" || repo_ok=0
[ "$repo_ok" -eq 1 ] || printf 'note: could not clone %s (%s); commit lists skipped.\n\n' "$REPO" "$(tail -n 1 "$tmp/git-err")"
g() { git -C "$tmp/repo" "$@"; }
has_commit() { [ "$repo_ok" -eq 1 ] && [ "$1" != '-' ] && g cat-file -e "$1^{commit}" 2>/dev/null; }
tag="fluxer-release@$target"
trev='-'
if [ "$repo_ok" -eq 1 ]; then
	trev=$(g rev-parse -q --verify "refs/tags/$tag^{commit}" 2>/dev/null) || trev='-'
	[ "$trev" != '-' ] || printf 'note: no tag %s upstream; commit lists skipped.\n\n' "$tag"
fi

# An image without a revision label: a SHA-looking version is the revision, and a
# CalVer version is a tag (per component before rexctl, per release since) that names
# its commit.
revision_of() { # component version revision
	case "$3" in -) ;; *) printf '%s' "$3"; return ;; esac
	if printf '%s' "$2" | grep -Eq '^[0-9a-f]{7,40}$'; then printf '%s' "$2"; return; fi
	if [ "$repo_ok" -eq 1 ] && [ "$2" != '-' ]; then
		for t in "fluxer-release@$2" "$1@$2" "$2"; do
			g rev-parse -q --verify "refs/tags/$t^{commit}" 2>/dev/null && return
		done
	fi
	printf -- '-'
}

printf '%-30s %-17s %s\n' COMPONENT RUNNING ''
: > "$tmp/ranges"; : > "$tmp/unknown"; : > "$tmp/changed"; : > "$tmp/thirdparty"
while read -r image ver rev; do
	comp=${image##*/}; comp=${comp%:*}
	rev=$(revision_of "$comp" "$ver" "$rev")
	if [ "$rev" != '-' ] && [ "$rev" = "$trev" ]; then
		note='up to date'
	elif has_commit "$rev" && has_commit "$trev"; then
		n=$(g rev-list --count "$trev" "^$rev")
		back=$(g rev-list --count "$rev" "^$trev")
		if [ "$n" -eq 0 ]; then
			note='up to date'
			[ "$back" -eq 0 ] || note="running is $back commit(s) AHEAD of $target"
		else
			note="$n commit(s) behind"
			printf '%s %s\n' "$rev" "$trev" >> "$tmp/ranges"
		fi
	else
		note='revision unknown, cannot list commits'
		printf '%s %s %s\n' "$comp" "$rev" "$trev" >> "$tmp/unknown"
	fi
	case "$note" in 'up to date' | *AHEAD*) ;; *) printf '%s %s %s\n' "$comp" "$ver" "$target" >> "$tmp/changed" ;; esac
	printf '%-30s %-17s %s\n' "$comp" "$ver" "$note"
done < "$tmp/fluxer"

# 4. Third-party images: pinned as ${VAR:-image} defaults in the release's compose file.
#    rexctl refuses a postgres major bump on its own; it is still worth a warning.
if [ "$trev" != '-' ] && g show "$trev:$STACK_COMPOSE" > "$tmp/upstream.yml" 2> /dev/null; then
	sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$tmp/upstream.yml" \
		| sed 's/^\${[A-Za-z0-9_]*:-\(.*\)}$/\1/' | grep -v 'fluxer-' | sort -u > "$tmp/img-up"
	awk '{ print $1 }' "$tmp/running" | grep -v 'fluxer-' | sort -u > "$tmp/img-local"
	echo
	if cmp -s "$tmp/img-local" "$tmp/img-up"; then
		echo "Third-party images: unchanged in $target."
	else
		echo "Third-party images that change with $target:"
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
			echo "  WARNING: postgres $pg_old -> $pg_new is a major version change; it needs a dump and restore." \
				| tee -a "$tmp/thirdparty"
		fi
	fi
else
	printf '\nThird-party images: could not read the compose file of %s.\n' "$target"
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
		# One compare link for the lot: the oldest running revision to the release.
		if [ -s "$tmp/ranges" ]; then
			oldest=$(awk '{ print $1 }' "$tmp/ranges" | sort -u | while read -r r; do
				printf '%s %s\n' "$(g rev-list --count "$r")" "$r"; done | sort -n | head -n 1 | cut -d' ' -f2)
			python3 "$OPS/changelog_fmt.py" --compare "$REPO/compare/$oldest...$trev"
		else
			python3 "$OPS/changelog_fmt.py"
		fi
	} >&3
}

# 5. The commits: union of every component's range, newest first. A commit listed
#    here is in some component's update; not every commit touches every one.
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
