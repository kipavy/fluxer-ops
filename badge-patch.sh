#!/bin/sh
# badge-patch.sh - show the Visionary badge on this self-hosted instance.
#
# The web client hides self-hosted-only bits of the profile badges. From
# src/features/user/components/popouts/UserProfileBadges.tsx (2026-10 releases):
#
#   const selfHosted = RuntimeConfig.isSelfHosted();
#   ...
#   if (!selfHosted && profile.premiumType === UserPremiumTypes.LIFETIME) {
#           tooltipText = "Fluxer Visionary since ..."; badgeUrl = helpArticle('visionary');
#   } else if (profile.premiumSince) { tooltipText = "... subscriber since ..."; }
#   ...
#   if (!selfHosted && profile.premiumType === UserPremiumTypes.LIFETIME
#           && profile.premiumLifetimeSequence != null) {
#           result.push({type: 'text', key: 'visionary_id', text: `#${sequence}`, ...});
#
# The Plutonium badge itself is no longer gated: it shows whenever the instance
# reports premium_enabled (premium mode 'mirror'). Earlier releases gated the whole
# premium badge instead (`!selfHosted && profile?.premiumType && ...`); that gate is
# still removed if a bundle has it. So this deletes `!selfHosted` from each of those
# conditions, and a lifetime account shows "Visionary since" and "Visionary ID #n"
# exactly as on fluxer.app. All gates are client-side only: the API serves
# premium_type, premium_since and premium_lifetime_sequence to profile viewers on any
# instance (UserAccountLookupService strips them only for BADGE_HIDDEN or a restricted
# profile). The STAFF badge has no such gate.
#
# There is no environment variable for this, and flipping FLUXER_SELF_HOSTED would
# change the setup flow, registration and the Stripe paths too. So this patches the
# shipped bundle: take the chunk out of the app-proxy image, edit it, and serve it
# back through docker-compose.override.yml, which overlay.sh writes (it
# also carries the STAFF Ops panel when that is on). The image is never modified, and
# `badge-patch.sh --revert` puts everything back.
#
# The patched chunk is published under a NEW, content-derived name
# (<chunk>.<sha8>.js) and index.html is rewritten to point at it, rather than
# overwriting the original chunk in place. That is not cosmetic. Bundle chunks go
# out as `cache-control: public, max-age=31536000, immutable`, so overwriting one
# leaves browsers and every CDN edge serving the pre-patch bytes from a URL that,
# by contract, never revalidates - a purge of that URL was observed NOT to reach
# every Cloudflare PoP, and the badge stayed missing while the origin was provably
# correct. index.html is `no-cache` and never CDN-cached, so a new chunk name is
# picked up on the next page load, everywhere, with nothing to purge.
#
# Since the 2026-10 releases the badge chunk is lazy-loaded: index.html only
# preloads it, and the module runtime (itself a <script> in index.html) fetches it by
# its stock name. So every file that loads the chunk by name gets the same treatment:
# the reference repointed at the patched copy, published under its own new
# content-derived name, and index.html repointed at that. A loader that index.html
# does not load itself is refused rather than guessed at.
#
# Because the mounted index.html names a release-specific chunk, it must NOT stay
# mounted across an update: the new image would be served an index.html pointing at
# chunks it no longer has, breaking the app rather than just losing the badge.
# update.sh reverts before updating and re-applies afterwards. Do the same by hand
# if you update some other way.
#
# Exit status: 0 patched and live, 1 something did not apply.
set -eu

. "$(dirname "$(readlink -f "$0")")/lib.sh"
. "$OPS/lib-node.sh"
need_instance
PATCH_DIR="$OPS/patches"
STATIC=/srv/app/static
ASSET_DIR="$STATIC/assets"

die() { printf 'badge-patch: %s\n' "$*" >&2; exit 1; }
compose() { (cd "$FLUXER_DIR" && docker compose "$@"); }

app_proxy_image() {
	img=$(compose config --images 2>/dev/null | grep 'fluxer-app-proxy' | head -n 1) || img=''
	[ -n "$img" ] || die 'cannot resolve the app-proxy image from the compose config'
	printf '%s\n' "$img"
}

in_image() {
	docker run --rm --user "$(id -u):$(id -g)" --entrypoint sh -v "$1:/out" "$IMAGE" -c "$2"
}

# No mount: docker would create a root-owned directory at a bind source that does
# not exist yet, which this script then could not clean up.
in_image_ro() {
	docker run --rm --user "$(id -u):$(id -g)" --entrypoint sh "$IMAGE" -c "$1"
}

cmd_revert() {
	# Off first (overlay.sh reads patched.names to decide), files last: a file still
	# mounted must not disappear, or docker replaces it with a root-owned directory.
	rm -f "$PATCH_DIR/patched.names"
	"$OPS/overlay.sh" apply
	rm -rf "$PATCH_DIR"
	echo "Badge patch off. The served index.html points back at the stock chunk, so a reload is enough."
}

write_patch_program() {
	cat > "$1/patch.js" <<'NODE'
const fs = require('node:fs');
const zlib = require('node:zlib');
const crypto = require('node:crypto');
const chunk = fs.readFileSync('chunk.name', 'utf8').trim();

// Minified identifiers change between builds, so anchor on the shape of each
// condition rather than on this release's variable names. Each gate may appear at
// most once; every gate found is removed, and at least one must be.
const ID = '[A-Za-z_$][\\w$]*';
const PATH = `${ID}(?:\\.${ID})*`;
const GATES = [
	{
		// if (N || t.premiumType !== b.Gm.LIFETIME) {subscriber tooltip} else {Visionary tooltip}
		name: 'Visionary since tooltip',
		re: new RegExp(`\\((${ID})\\|\\|(${ID})\\.premiumType!==(${PATH})\\.LIFETIME\\)`, 'g'),
		to: (_m, _selfHosted, profile, constants) => `(${profile}.premiumType!==${constants}.LIFETIME)`,
	},
	{
		// !N && t.premiumType === b.Gm.LIFETIME && null != t.premiumLifetimeSequence
		name: 'Visionary ID badge',
		re: new RegExp(`!(${ID})&&(${ID})\\.premiumType===(${PATH})\\.LIFETIME&&null!=\\2\\.premiumLifetimeSequence`, 'g'),
		to: (_m, _selfHosted, profile, constants) =>
			`${profile}.premiumType===${constants}.LIFETIME&&null!=${profile}.premiumLifetimeSequence`,
	},
	{
		// Earlier releases: !E && (null == t ? void 0 : t.premiumType) && t.premiumType !== g.Gm.NONE
		name: 'Plutonium badge (earlier releases)',
		re: new RegExp(`!(${ID})&&\\(null==(${ID})\\?void 0:\\2\\.premiumType\\)&&\\2\\.premiumType!==(${PATH})\\.NONE`, 'g'),
		to: (_m, _selfHosted, profile, constants) =>
			`(null==${profile}?void 0:${profile}.premiumType)&&${profile}.premiumType!==${constants}.NONE`,
	},
];

const src = fs.readFileSync(chunk, 'utf8');
let patched = src;
const removed = [];
for (const gate of GATES) {
	const hits = patched.match(gate.re);
	if (!hits) continue;
	if (hits.length !== 1) {
		console.error(`patch: expected the ${gate.name} gate at most once, found it ${hits.length} times`);
		process.exit(3);
	}
	patched = patched.replace(gate.re, gate.to);
	gate.re.lastIndex = 0;
	if (gate.re.test(patched)) {
		console.error(`patch: the ${gate.name} replacement did not take`);
		process.exit(3);
	}
	removed.push(gate.name);
}
if (removed.length === 0) {
	console.error('patch: none of the self-hosted badge gates is in this bundle');
	process.exit(3);
}

// Content-derived name: identical content re-publishes to the same URL (so a
// no-op re-run changes nothing), and any change to the patch gets a fresh URL
// that no cache can have seen.
const body = Buffer.from(patched, 'utf8');
const sha8 = crypto.createHash('sha256').update(body).digest('hex').slice(0, 8);
const base = chunk.replace(/\.js$/, '');
const name = `${base}.${sha8}.js`;

// app-proxy serves whichever precompressed sibling the browser asks for, so the
// patched chunk needs its own .br and .gz or the originals would shadow it.
const publish = (file, buf, quality) => {
	fs.writeFileSync(file, buf);
	fs.writeFileSync(
		`${file}.br`,
		zlib.brotliCompressSync(buf, {
			params: {
				[zlib.constants.BROTLI_PARAM_QUALITY]: quality,
				[zlib.constants.BROTLI_PARAM_SIZE_HINT]: buf.length,
			},
		}),
	);
	fs.writeFileSync(`${file}.gz`, zlib.gzipSync(buf, {level: 9}));
};
publish(name, body, 11);

// Repoint whatever loads the chunk by name. The module runtime fetches it by its
// stock name, so it gets the new name and is published under a new name of its
// own; index.html then points at that. A loader must be loaded from index.html,
// or the renaming would have to cascade further than this follows.
let html = fs.readFileSync('index.html', 'utf8');
const names = [name];
const htmlNames = [];
if (html.includes(`/assets/${chunk}`)) {
	html = html.replaceAll(`/assets/${chunk}`, `/assets/${name}`);
	htmlNames.push(name);
}
const loaders = fs.readFileSync('loaders.name', 'utf8').split('\n').map((l) => l.trim()).filter(Boolean);
for (const loader of loaders) {
	if (!html.includes(`/assets/${loader}`)) {
		console.error(`patch: ${loader} loads the badge chunk, but index.html does not load ${loader}`);
		process.exit(3);
	}
	const repointed = Buffer.from(
		fs.readFileSync(loader, 'utf8').replaceAll(`assets/${chunk}`, `assets/${name}`),
		'utf8',
	);
	const loaderSha8 = crypto.createHash('sha256').update(repointed).digest('hex').slice(0, 8);
	const loaderName = `${loader.replace(/\.js$/, '')}.${loaderSha8}.js`;
	publish(loaderName, repointed, 11);
	html = html.replaceAll(`/assets/${loader}`, `/assets/${loaderName}`);
	names.push(loaderName);
	htmlNames.push(loaderName);
}
if (htmlNames.length === 0) {
	console.error(`patch: nothing index.html loads reaches /assets/${chunk}`);
	process.exit(3);
}
// app-proxy templates index.html on every request (it injects __FLUXER_CONFIG__),
// so this file is a template, not a served artifact.
publish('index.html', Buffer.from(html, 'utf8'), 5);

fs.writeFileSync('patched.name', `${name}\n`);
fs.writeFileSync('patched.names', `${names.join('\n')}\n`);
fs.writeFileSync('html.names', `${htmlNames.join('\n')}\n`);
console.log(`  removed: ${removed.join(', ')}`);
console.log(`  published ${names.join(', ')} (${body.length} bytes for the chunk) and repointed index.html`);
NODE
}

cmd_apply() {
	IMAGE=$(app_proxy_image)

	# Read the bundle out of the image, not out of the running container, so a
	# re-run always starts from the pristine bytes of the current release.
	echo "Locating the bundle chunk that renders the badges, in $IMAGE."
	# The chunk holding a gate: the Visionary one (2026-10 on), else the old premium one.
	chunk=$(in_image_ro "grep -lE '\\.LIFETIME&&null!=[^&]+\\.premiumLifetimeSequence' $ASSET_DIR/*.js 2>/dev/null | head -n 2" \
		| tr -d '\r' | sed 's|.*/||')
	if [ -z "$chunk" ]; then
		chunk=$(in_image_ro "grep -lE '\\?void 0:[^?]+\\.premiumType\\)&&' $ASSET_DIR/*.js 2>/dev/null | head -n 2" \
			| tr -d '\r' | sed 's|.*/||')
	fi
	[ -n "$chunk" ] || die "no chunk in $ASSET_DIR has a self-hosted badge gate - did the bundle layout change?"
	[ "$(printf '%s\n' "$chunk" | wc -l)" -eq 1 ] \
		|| die "more than one chunk has a badge gate - patch them by hand: $chunk"
	echo "  $chunk"

	work="$PATCH_DIR.new"
	rm -rf "$work"
	mkdir -p "$work" "$PATCH_DIR"
	printf '%s\n' "$chunk" > "$work/chunk.name"
	# Files that load the chunk by name (the module runtime, since 2026-10).
	loaders=$(in_image_ro "grep -lF 'assets/$chunk' $ASSET_DIR/*.js 2>/dev/null" \
		| tr -d '\r' | sed 's|.*/||' | grep -vxF "$chunk" || true)
	printf '%s\n' $loaders > "$work/loaders.name"
	[ -z "$loaders" ] || echo "  loaded by $(printf '%s ' $loaders)"
	srcs="$ASSET_DIR/$chunk"
	for l in $loaders; do srcs="$srcs $ASSET_DIR/$l"; done
	in_image "$work" "cp $srcs $STATIC/index.html /out/"
	write_patch_program "$work"

	echo "Removing the gates and recompressing (brotli q11 on a few MB takes a moment)."
	resolve_node
	run_node "$work" patch.js || die 'the patch step failed - nothing was changed'
	name=$(cat "$work/patched.name")
	names=$(cat "$work/patched.names")

	# Copy in over whatever is already mounted; never delete a mounted file, or
	# docker replaces the bind source with a root-owned directory on the next up.
	for n in $names; do
		for f in "$n" "$n.br" "$n.gz"; do
			cat "$work/$f" > "$PATCH_DIR/$f"
		done
	done
	for f in index.html index.html.br index.html.gz patched.names html.names; do
		cat "$work/$f" > "$PATCH_DIR/$f"
	done
	printf '%s\n' "$chunk" > "$PATCH_DIR/chunk.name"
	printf '%s\n' "$name" > "$PATCH_DIR/patched.name"
	rm -rf "$work"

	"$OPS/overlay.sh" apply

	# Anything else in here is from an earlier release or an earlier patch. Safe to
	# drop now: the new override no longer names it, and the container is recreated.
	for f in "$PATCH_DIR"/*; do
		[ -e "$f" ] || continue
		b=$(basename "$f")
		case "$b" in
			index.html | index.html.br | index.html.gz | chunk.name | patched.name | patched.names | html.names) continue ;;
		esac
		case " $(printf '%s ' $names)" in
			*" ${b%.br} "* | *" ${b%.gz} "*) ;;
			*) rm -f "$f" ;;
		esac
	done

	verify
}

verify() {
	names=$(cat "$PATCH_DIR/patched.names")
	html_names=$(cat "$PATCH_DIR/html.names")
	first=$(printf '%s\n' $names | head -n 1)

	# app-proxy needs a moment to come back before it will serve the asset.
	i=0
	while [ "$i" -lt 30 ]; do
		code=$(compose exec -T edge wget -qS --spider "http://app-proxy:8080/assets/$first" 2>&1 \
			| sed -n 's/.*HTTP\/1\.[01] \([0-9]*\).*/\1/p' | head -n 1) || code=''
		[ "${code:-}" = "200" ] && break
		i=$((i + 1))
		sleep 1
	done
	[ "${code:-000}" = "200" ] || die "app-proxy still answers ${code:-no response} for /assets/$first"

	echo
	fail=0
	for n in $names; do
		for enc in identity gzip br; do
			case "$enc" in
				identity) want=$(sha256sum "$PATCH_DIR/$n" | cut -d' ' -f1) ;;
				gzip) want=$(sha256sum "$PATCH_DIR/$n.gz" | cut -d' ' -f1) ;;
				br) want=$(sha256sum "$PATCH_DIR/$n.br" | cut -d' ' -f1) ;;
			esac
			# wget hands the body over untouched, so the precompressed siblings can be
			# compared byte for byte.
			got=$(compose exec -T edge wget -qO- --header="Accept-Encoding: $enc" \
				"http://app-proxy:8080/assets/$n" | sha256sum | cut -d' ' -f1)
			if [ "$got" = "$want" ]; then
				printf '%-32s %-9s patched\n' "$n" "$enc"
			else
				printf '%-32s %-9s WRONG BYTES\n' "$n" "$enc"
				fail=1
			fi
		done
	done
	[ "$fail" -eq 0 ] || die 'app-proxy is not serving the patched files'

	# The HTML is what makes the patch reachable, and it is the one thing no cache
	# holds on to, so check it at the origin and through the public hostname.
	domain=$(sed -n 's/^FLUXER_DOMAIN=//p' "$FLUXER_DIR/.env" | head -n 1)
	[ -n "$domain" ] || die 'no FLUXER_DOMAIN in .env, cannot check the public URL'
	local_html=$(compose exec -T edge wget -qO- http://app-proxy:8080/ 2>/dev/null) || local_html=''
	pub_html=$(curl -s --max-time 30 "https://$domain/") || pub_html=''
	for n in $html_names; do
		case "$local_html" in
			*"/assets/$n"*) printf 'html  app-proxy  loads %s\n' "$n" ;;
			*) die "the served index.html does not load /assets/$n" ;;
		esac
		case "$pub_html" in
			*"/assets/$n"*) printf 'html  public     loads %s\n' "$n" ;;
			*) die "https://$domain/ does not load /assets/$n yet" ;;
		esac
	done

	for n in $names; do
		pub=$(curl -s --max-time 120 -H 'Accept-Encoding: identity' "https://$domain/assets/$n" \
			| sha256sum | cut -d' ' -f1)
		[ "$pub" = "$(sha256sum "$PATCH_DIR/$n" | cut -d' ' -f1)" ] \
			&& printf '%-32s %-9s patched\n' "$n" 'public' \
			|| die "https://$domain/assets/$n is not serving the patched bytes"
	done

	echo
	echo "Visionary badge patch applied and live. A normal reload picks it up."
}

case "${1:-apply}" in
	apply | '') cmd_apply ;;
	--revert | revert) cmd_revert ;;
	-h | --help | help) echo "usage: badge-patch.sh [apply|--revert]" ;;
	*) die "unknown argument: $1" ;;
esac
