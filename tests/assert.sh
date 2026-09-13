# shellcheck shell=sh
# assert.sh - the few assertions the tests need. Sourced, never run.
fails=0
pass() { printf 'ok    %s\n' "$*"; }
fail() { fails=$((fails + 1)); printf 'FAIL  %s\n' "$*"; }
assert_eq() { # <name> <expected> <actual>
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected [$2], got [$3]"; fi
}
assert_contains() { # <name> <needle> <haystack>
	case "$3" in *"$2"*) pass "$1" ;; *) fail "$1: [$2] not in [$3]" ;; esac
}
finish() {
	[ "$fails" -eq 0 ] && return 0
	echo "$fails failed"
	exit 1
}
