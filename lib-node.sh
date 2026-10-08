# shellcheck shell=sh
# lib-node.sh - a node for the small build steps (patching, brotli). Sourced by
# badge-patch.sh and overlay.sh; not a command.
#
# Prefers the host's node (or the newest nvm one, which is not on PATH under cron or
# a plain sh), and falls back to the node inside the api image, so a host with no node
# at all still works. The caller defines compose() and die().

# node does the patch, the rewrite and both recompressions in one pass. Prefer the
# host's, fall back to the node that ships inside the api image so this works on a
# host with no node at all.
resolve_node() {
	NODE_BIN=$(command -v node 2>/dev/null || true)
	[ -n "$NODE_BIN" ] && return 0
	# nvm installs are not on PATH under cron or a plain sh.
	NODE_BIN=$(ls -d "$HOME"/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V | tail -n 1 || true)
}

run_node() {
	dir=$1 script=$2
	if [ -n "${NODE_BIN:-}" ]; then
		(cd "$dir" && "$NODE_BIN" "$script")
		return
	fi
	api_image=$(compose config --images 2>/dev/null | grep 'fluxer-api' | head -n 1) || api_image=''
	[ -n "$api_image" ] || die 'no node on this host and no api image to borrow one from'
	docker run --rm --user "$(id -u):$(id -g)" -v "$dir:/work" -w /work "$api_image" node "$script"
}
