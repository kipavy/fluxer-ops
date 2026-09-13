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
set -eu

. "$(dirname "$(readlink -f "$0")")/lib.sh"
need_instance
REPO=${FLUXER_SOURCE_REPO:-https://github.com/fluxerapp/fluxer}
RAW_BASE='https://raw.githubusercontent.com/fluxerapp/fluxer'
LIMIT=60
case "${1:-}" in
	'') ;;
	--all) LIMIT=0 ;;
	*) echo "usage: changelog.sh [--all]" >&2; exit 2 ;;
esac

die() { printf '%s\n' "$*" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$FLUXER_DIR"

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
python3 - "$platform" $(awk '{ print $1 }' "$tmp/fluxer") > "$tmp/remote" <<'PY'
import json, re, sys, urllib.request, urllib.error
os_, arch = sys.argv[1].split("/", 1)
ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json"])
tokens = {}
def get(host, repo, path, accept):
    url = f"https://{host}/v2/{repo}/{path}"
    for attempt in (0, 1):
        h = {"Accept": accept}
        if repo in tokens:
            h["Authorization"] = "Bearer " + tokens[repo]
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=20) as r:
                return r.headers, r.read()
        except urllib.error.HTTPError as e:
            auth = e.headers.get("WWW-Authenticate", "")
            if e.code != 401 or attempt or not auth.startswith("Bearer"):
                raise
            p = dict(re.findall(r'(\w+)="([^"]*)"', auth))
            q = f"{p['realm']}?service={p.get('service', '')}&scope=repository:{repo}:pull"
            with urllib.request.urlopen(q, timeout=20) as r:
                j = json.load(r)
            tokens[repo] = j.get("token") or j.get("access_token")
for ref in sys.argv[2:]:
    name, _, tag = ref.rpartition(":")
    host, _, repo = name.partition("/")
    try:
        hdr, body = get(host, repo, "manifests/" + tag, ACCEPT)
        digest = hdr.get("Docker-Content-Digest", "-")
        m = json.loads(body)
        if "manifests" in m:
            pick = [x for x in m["manifests"] if x.get("platform", {}).get("os") == os_
                    and x.get("platform", {}).get("architecture") == arch]
            if not pick:
                print(ref, "-", "-", digest, "no image for " + sys.argv[1]); continue
            _, body = get(host, repo, "manifests/" + pick[0]["digest"], ACCEPT)
            m = json.loads(body)
        _, body = get(host, repo, "blobs/" + m["config"]["digest"], "*/*")
        labels = json.loads(body).get("config", {}).get("Labels") or {}
        print(ref, labels.get("org.opencontainers.image.version") or "-",
              labels.get("org.opencontainers.image.revision") or "-", digest, "ok")
    except Exception as e:
        print(ref, "-", "-", "-", "registry: " + str(e).replace("\n", " ")[:80])
PY

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
: > "$tmp/ranges"; : > "$tmp/unknown"
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
			}' | sort
		pg_old=$(sed -n 's/^postgres:\([0-9][0-9]*\).*/\1/p' "$tmp/img-local")
		pg_new=$(sed -n 's/^postgres:\([0-9][0-9]*\).*/\1/p' "$tmp/img-up")
		if [ -n "$pg_old" ] && [ -n "$pg_new" ] && [ "$pg_old" != "$pg_new" ]; then
			echo "  WARNING: postgres $pg_old -> $pg_new is a major version change. install.sh --update refuses it; it needs a dump and restore."
		fi
	fi
else
	printf '\nThird-party images: could not fetch upstream docker-compose.yml at %s.\n' "$ref"
fi

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
	exit 0
fi
while read -r rev rrev; do
	g rev-list "$rrev" "^$rev"
done < "$tmp/ranges" | sort -u > "$tmp/commits"
total=$(grep -c . "$tmp/commits")
shown=$total
[ "$LIMIT" -eq 0 ] || [ "$total" -le "$LIMIT" ] || shown=$LIMIT
printf 'Commits an update brings: %s' "$total"
[ "$shown" -eq "$total" ] && echo || printf ' (newest %s; --all for every one)\n' "$shown"
g log --no-walk=sorted --stdin --date=short --format='  %h %ad %s' < "$tmp/commits" | head -n "$shown"
