#!/bin/sh
# get.sh - put fluxer-ops on this server and hand over to its setup.sh, which checks
# everything, asks before changing anything, and installs Fluxer too if there is none.
#
#   curl -fsSL https://raw.githubusercontent.com/kipavy/fluxer-ops/main/get.sh | sh
#
# Rather read first? The same, by hand:
#   git clone https://github.com/kipavy/fluxer-ops ~/fluxer/ops && ~/fluxer/ops/setup.sh
#
# Non-interactive (no terminal): FLUXER_OPS_YES=1, and setup's flags after `sh -s --`:
#   curl -fsSL .../get.sh | FLUXER_OPS_YES=1 sh -s -- --domain chat.example.com --email me@example.com

# Everything is inside main, called on the last line: a download cut short runs nothing.
main() {
	set -eu
	repo=${FLUXER_OPS_REPO:-https://github.com/kipavy/fluxer-ops.git}

	# Under `curl | sh` stdin is this script, so questions go to the terminal directly.
	tty=0
	if (: < /dev/tty) 2> /dev/null; then tty=1; fi
	if [ "$tty" -eq 0 ] && [ "${FLUXER_OPS_YES:-0}" != 1 ]; then
		die 2 "no terminal to ask questions on. Run it from an interactive shell, or set FLUXER_OPS_YES=1 (a new instance also needs: sh -s -- --domain D --email E)."
	fi

	command -v git > /dev/null 2>&1 || die 2 "git is needed first: $(pkg_hint git)"

	dir=$(find_instance)
	if [ -n "$dir" ]; then
		say "Fluxer found at $dir"
	else
		say "No Fluxer on this server yet: setup will install it."
		if [ "$tty" -eq 1 ]; then
			printf 'Install it into [%s]: ' "$HOME/fluxer"
			read -r dir < /dev/tty || dir=''
		fi
		dir=${dir:-$HOME/fluxer}
	fi

	target=$dir/ops
	if [ -d "$target/.git" ] && [ -f "$target/fluxer" ]; then
		say "Updating $target"
		git -C "$target" pull --ff-only -q || die 3 "$target has local changes that a fast-forward cannot keep. Sort them out with git, then run this again."
	elif [ -e "$target" ]; then
		die 3 "$target exists and is not fluxer-ops. Move it away, or choose another directory."
	else
		mkdir -p "$dir" || die 2 "cannot create $dir. Pick a directory you can write to."
		say "Downloading fluxer-ops into $target"
		git clone -q "$repo" "$target"
	fi

	if [ "$tty" -eq 1 ]; then
		exec sh "$target/setup.sh" --fluxer-dir "$dir" "$@" < /dev/tty
	fi
	exec sh "$target/setup.sh" --fluxer-dir "$dir" --yes "$@" < /dev/null
}

say() { printf '%s\n' "$*"; }
die() {
	code=$1
	shift
	printf 'get.sh: %s\n' "$*" >&2
	exit "$code"
}

pkg_hint() {
	if command -v apt-get > /dev/null 2>&1; then echo "sudo apt-get install -y $1"
	elif command -v dnf > /dev/null 2>&1; then echo "sudo dnf install -y $1"
	elif command -v zypper > /dev/null 2>&1; then echo "sudo zypper install -y $1"
	elif command -v pacman > /dev/null 2>&1; then echo "sudo pacman -S --needed $1"
	elif command -v apk > /dev/null 2>&1; then echo "sudo apk add $1"
	else echo "install $1 with this distribution's package manager"; fi
}

# The same rule as lib.sh, which is not here yet: FLUXER_DIR, a compose project
# whose .env names a FLUXER_DOMAIN, then the two usual places.
find_instance() {
	if [ -n "${FLUXER_DIR:-}" ]; then printf '%s' "$FLUXER_DIR"; return 0; fi
	if command -v docker > /dev/null 2>&1; then
		_d=$(docker compose ls --all --format json 2> /dev/null \
			| grep -o '"ConfigFiles":"[^"]*"' | sed 's/^"ConfigFiles":"//; s/[",].*//' \
			| while IFS= read -r f; do
				grep -q '^FLUXER_DOMAIN=' "$(dirname "$f")/.env" 2> /dev/null && dirname "$f"
			done | sort -u)
		if [ -n "$_d" ] && [ "$(printf '%s\n' "$_d" | grep -c .)" -eq 1 ]; then printf '%s' "$_d"; return 0; fi
	fi
	for _d in "$HOME/fluxer" /opt/fluxer; do
		if [ -f "$_d/docker-compose.yml" ] && [ -f "$_d/.env" ]; then printf '%s' "$_d"; return 0; fi
	done
}

main "$@"
