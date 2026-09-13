#!/bin/sh
# debug.sh - the shortcuts you reach for when something is off.
#
#   debug.sh psql [args]                  psql into the fluxer database
#   debug.sh valkey [args]                valkey-cli in the valkey container
#   debug.sh sh <service>                 a shell in a service (bash if it has one)
#   debug.sh errors [--since 1h] [--warn] [service]
#                                         error lines from the logs, grouped and counted
#   debug.sh top                          memory and CPU per service, against its limit
#   debug.sh voice                        can clients reach LiveKit directly?
#
# `errors` exists because the stack logs in five dialects - pino JSON (api, worker),
# Rust tracing JSON (media-proxy, users, messages...), Erlang reports (gateway), Go
# console (livekit), Postgres - so grepping for "error" finds mostly INFO lines that
# mention one, and misses Erlang reports entirely. It reads the level each format
# actually carries, and collapses ids and numbers so a thousand copies of one failure
# are one line with a count.
#
# `voice` exists because check.sh cannot see it: LiveKit's 7881/tcp and 7882/udp go
# direct to the origin, not through Cloudflare, and this is the path the firewalld /
# Docker iptables bug breaks first. It says what each test proves and what it does not:
# a test from the host itself cannot prove the cloud firewall admits the internet.
#
# PG_CONTAINER=<container> points psql at a scratch database instead (plain docker exec).
set -eu

. "$(dirname "$(readlink -f "$0")")/lib.sh"
need_instance
PG_CONTAINER=${PG_CONTAINER:-}

die() { printf 'debug: %s\n' "$*" >&2; exit 1; }
compose() { (cd "$FLUXER_DIR" && docker compose "$@"); }
# Only ever read single, non-secret keys out of .env.
env_val() { sed -n "s/^$1=//p" "$FLUXER_DIR/.env" 2>/dev/null | head -n 1 | tr -d '"'"'"; }

# Allocate a TTY only when there is one: piped input (`... < file.sql`) needs -T.
tty_flag() { if [ -t 0 ] && [ -t 1 ]; then echo ''; else echo '-T'; fi; }

usage() {
	cat <<'USAGE'
usage: debug.sh psql [psql args]
       debug.sh valkey [valkey-cli args]
       debug.sh sh <service>
       debug.sh errors [--since 1h] [--warn] [--top N] [service]
       debug.sh top
       debug.sh voice
USAGE
}

cmd_psql() {
	if [ -n "$PG_CONTAINER" ]; then
		if [ -t 0 ]; then
			exec docker exec -it "$PG_CONTAINER" psql -U fluxer -d fluxer "$@"
		fi
		exec docker exec -i "$PG_CONTAINER" psql -U fluxer -d fluxer "$@"
	fi
	cd "$FLUXER_DIR"
	# shellcheck disable=SC2046 # empty or -T, deliberately unquoted
	exec docker compose exec $(tty_flag) postgres psql -U fluxer -d fluxer "$@"
}

# The compose file starts valkey with no requirepass, so no auth is needed.
cmd_valkey() {
	cd "$FLUXER_DIR"
	# shellcheck disable=SC2046
	exec docker compose exec $(tty_flag) valkey valkey-cli "$@"
}

cmd_sh() {
	[ $# -eq 1 ] || die 'usage: debug.sh sh <service>'
	svc=$1
	compose config --services | grep -qx "$svc" || die "no such service: $svc"
	cd "$FLUXER_DIR"
	# shellcheck disable=SC2046
	exec docker compose exec $(tty_flag) "$svc" sh -c 'command -v bash > /dev/null && exec bash || exec sh'
}

cmd_errors() {
	since=1h warn=0 top=15 svc=''
	while [ $# -gt 0 ]; do
		case "$1" in
			--since) [ $# -ge 2 ] || die '--since needs a value, e.g. 1h, 30m, 2026-09-13T12:00:00'; since=$2; shift ;;
			--warn) warn=1 ;;
			--top) [ $# -ge 2 ] || die '--top needs a number'; top=$2; shift
				case "$top" in '' | *[!0-9]*) die "--top needs a number, not '$top'" ;; esac ;;
			-*) die "unknown option: $1" ;;
			*) [ -z "$svc" ] || die 'give one service'; svc=$1 ;;
		esac
		shift
	done
	case "$since" in *[!A-Za-z0-9:.+-]*) die "odd --since value: '$since'" ;; esac
	if [ -n "$svc" ]; then
		compose config --services | grep -qx "$svc" || die "no such service: $svc"
	fi

	out=$(mktemp)
	trap 'rm -f "$out"' EXIT
	# shellcheck disable=SC2086 # $svc is empty or one validated service name
	compose logs --no-color --since "$since" $svc 2>&1 \
		| sed 's/\x1b\[[0-9;]*[A-Za-z]//g' \
		| awk -v warn="$warn" -f /dev/fd/3 3<<'AWK' > "$out"
function jstr(line, key,    s) {
	# the value of "key":"..." in a JSON line, escapes and all
	if (match(line, "\"" key "\":\"([^\"\\\\]|\\\\.)*\"")) {
		s = substr(line, RSTART + length(key) + 4, RLENGTH - length(key) - 5)
		gsub(/\\"/, "\"", s)
		return s
	}
	return ""
}
function hexify(s,    out, t) {
	# runs of 8+ hex digits containing a digit: snowflakes, hashes, request ids
	out = ""
	while (match(s, /[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]+/)) {
		t = substr(s, RSTART, RLENGTH)
		out = out substr(s, 1, RSTART - 1) (t ~ /[0-9]/ ? "<id>" : t)
		s = substr(s, RSTART + RLENGTH)
	}
	return out s
}
function norm(s) {
	gsub(/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][0-9:.]+Z?/, "<time>", s)
	gsub(/[0-9a-fA-F]+-[0-9a-fA-F]+-[0-9a-fA-F]+-[0-9a-fA-F]+-[0-9a-fA-F]+/, "<uuid>", s)
	gsub(/<<"[^"]*">>/, "<<..>>", s)
	gsub(/0x[0-9a-fA-F]+/, "0x#", s)
	gsub(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(:[0-9]+)?/, "<ip>", s)
	s = hexify(s)
	gsub(/[0-9]+/, "N", s)
	gsub(/[ \t]+/, " ", s)
	sub(/^ /, "", s)
	if (length(s) > 160) s = substr(s, 1, 157) "..."
	return s
}
function emit(svc, sev, msg) {
	if (sev == "warn" && !warn) return
	if (msg == "") msg = "(no message)"
	print svc "\t" sev "\t" norm(msg)
}
{
	if (!match($0, /^[^ |]+ +\| ?/)) next
	svc = substr($0, 1, RLENGTH); sub(/ +\| ?$/, "", svc); sub(/-[0-9]+$/, "", svc)
	line = substr($0, RLENGTH + 1)

	# Erlang reports: the header carries the level, the next line the message.
	if (svc in pending) {
		if (line !~ /^[ \t]*$/) { emit(svc, pending[svc], line); delete pending[svc] }
		next
	}
	if (line ~ /^=(ERROR|CRASH|SUPERVISOR) REPORT====/) { pending[svc] = "error"; next }
	if (line ~ /^=WARNING REPORT====/) { pending[svc] = "warn"; next }
	if (line ~ /^=[A-Z]+ REPORT====/) next

	if (line ~ /^[ \t]*\{/) {
		# JSON: pino ("level":"error" or 50), Rust tracing ("ERROR"), Caddy ("error").
		lvl = tolower(jstr(line, "level"))
		if (lvl == "" && match(line, /"level":[0-9]+/)) {
			n = substr(line, RSTART + 8, RLENGTH - 8) + 0
			lvl = n >= 50 ? "error" : (n >= 40 ? "warn" : "info")
		}
		if (lvl ~ /^(error|fatal|panic|dpanic|crit|critical|alert|emerg)$/) sev = "error"
		else if (lvl ~ /^warn(ing)?$/) sev = "warn"
		else next
		m = jstr(line, "msg"); e = jstr(line, "message"); x = jstr(line, "error")
		if (m == "") { m = e; e = "" }
		if (e != "" && e != m) m = m ": " e
		if (x != "" && index(m, x) == 0) m = m ": " x
		emit(svc, sev, m)
		next
	}

	# Stack frames belong to the line above them; do not count them on their own.
	if (line ~ /^[ \t]+(at |\.\.\. [0-9]+ more|File ")/) next

	if (match(line, /(ERROR|FATAL|PANIC):  +/)) {                 # postgres
		emit(svc, "error", substr(line, RSTART + RLENGTH)); next
	}
	if (match(line, /WARNING:  +/)) { emit(svc, "warn", substr(line, RSTART + RLENGTH)); next }
	n = split(line, f, "\t")
	if (n >= 5 && f[2] ~ /^(ERROR|DPANIC|PANIC|FATAL)$/) { emit(svc, "error", f[5]); next }   # livekit (zap)
	if (n >= 5 && f[2] == "WARN") { emit(svc, "warn", f[5]); next }
	if (line ~ /^[EF][0-9][0-9][0-9][0-9] [0-9:.]+ /) {          # seaweedfs (glog)
		sub(/^[EF][0-9]+ [0-9:.]+ [^ ]+ /, "", line); emit(svc, "error", line); next
	}
	if (line ~ /^W[0-9][0-9][0-9][0-9] [0-9:.]+ /) {
		sub(/^W[0-9]+ [0-9:.]+ [^ ]+ /, "", line); emit(svc, "warn", line); next
	}
	if (match(line, /\[(ERR|FTL)\] /)) { emit(svc, "error", substr(line, RSTART + RLENGTH)); next }   # nats
	if (match(line, /\[WRN\] /)) { emit(svc, "warn", substr(line, RSTART + RLENGTH)); next }
	if (line ~ /^[0-9]+:[A-Z] [0-9]+ [A-Za-z]+ [0-9]+ [0-9:.]+ # /) {   # valkey warning
		sub(/^[^#]*# /, "", line); emit(svc, "warn", line); next
	}
	if (line ~ /panic:|panicked at|Unhandled|Uncaught|Traceback \(most recent|(^|[^A-Za-z_])(ERROR|FATAL|CRITICAL)([^A-Za-z_]|$)/) {
		emit(svc, "error", line); next
	}
	if (line ~ /(^|[^A-Za-z_])WARN(ING)?([^A-Za-z_]|$)/) emit(svc, "warn", line)
}
AWK

	scope=${svc:-all services}
	total=$(grep -c . "$out" || true)
	if [ "${total:-0}" -eq 0 ]; then
		printf 'No %s in the last %s (%s).\n' "$( [ "$warn" -eq 1 ] && echo 'errors or warnings' || echo errors)" "$since" "$scope"
		return 0
	fi
	printf '%s line(s) in the last %s (%s)%s\n\n' "$total" "$since" "$scope" \
		"$( [ "$warn" -eq 1 ] && echo ', warnings included' || echo '')"
	printf '%-18s %7s %7s\n' SERVICE ERRORS WARNINGS
	awk -F '\t' '{ k[$1] = 1; c[$1 SUBSEP $2]++ }
		END { for (s in k) printf "%-18s %7d %7d\n", s, c[s SUBSEP "error"], c[s SUBSEP "warn"] }' "$out" \
		| sort -k2,2nr -k3,3nr
	echo
	echo "Most frequent (ids and numbers collapsed):"
	awk -F '\t' '{ print $1 "\t" $2 "\t" $3 }' "$out" | sort | uniq -c | sort -k1,1nr | head -n "$top" \
		| awk -F '\t' '{ n = $1; sub(/^ */, "", n); split(n, a, " "); printf "%6s  %-14s %-5s %s\n", a[1], a[2], $2, $3 }'
}

cmd_top() {
	ids=$(compose ps -q)
	[ -n "$ids" ] || die 'no containers running'
	names=$(mktemp)
	trap 'rm -f "$names"' EXIT
	compose ps --format '{{.Name}}	{{.Service}}' > "$names"
	host_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
	# shellcheck disable=SC2086 # one id per word
	docker stats --no-stream --format '{{.Name}}	{{.MemUsage}}	{{.MemPerc}}	{{.CPUPerc}}' $ids \
		| awk -F '\t' -v host_kb="$host_kb" -v names="$names" '
function bytes(s,    n, u) {
	n = s + 0; u = s; sub(/^[0-9.]+/, "", u)
	if (u == "KiB" || u == "kB") return n * 1024
	if (u == "MiB" || u == "MB") return n * 1024 * 1024
	if (u == "GiB" || u == "GB") return n * 1024 * 1024 * 1024
	if (u == "TiB") return n * 1024 * 1024 * 1024 * 1024
	return n
}
BEGIN { while ((getline l < names) > 0) { split(l, p, "\t"); svc[p[1]] = p[2] } }
{
	split($2, m, " / ")
	used = bytes(m[1]); lim = bytes(m[2])
	name = ($1 in svc) ? svc[$1] : $1
	# With no compose limit, docker reports the whole host as the limit.
	nolimit = (lim >= host_kb * 1024 * 0.98)
	printf "%d\t%-18s %10s %10s %8s %7s\n", used, name, m[1], nolimit ? "-" : m[2], nolimit ? "no limit" : $3, $4
}' | sort -t "$(printf '\t')" -k1,1nr | cut -f2- \
		| { printf '%-18s %10s %10s %8s %7s\n' SERVICE MEMORY LIMIT '%LIMIT' CPU; cat; }
	awk -v kb="$host_kb" 'BEGIN { printf "\nhost memory %.1f GiB\n", kb / 1024 / 1024 }'
}

cmd_voice() {
	tcp=$(env_val FLUXER_LIVEKIT_TCP_PORT); tcp=${tcp:-7881}
	udp=$(env_val FLUXER_LIVEKIT_UDP_PORT); udp=${udp:-7882}
	fails=0
	ok() { printf 'ok    %s\n' "$*"; }
	bad() { fails=$((fails + 1)); printf 'FAIL  %s\n' "$*"; }
	info() { printf 'info  %s\n' "$*"; }
	note() { printf '      %s\n' "$*"; }

	echo "LiveKit, voice: ${tcp}/tcp and ${udp}/udp direct to the origin (not via Cloudflare)"
	echo

	cid=$(compose ps -q livekit 2>/dev/null || true)
	if [ -z "$cid" ]; then
		bad "livekit container is not running"
	else
		health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' "$cid")
		if [ "$health" = healthy ]; then ok "container healthy"; else bad "container health: $health"; fi
		body=$(compose exec -T livekit wget -q -T 5 -O - http://127.0.0.1:7880/ 2>/dev/null || true)
		if [ "$body" = OK ]; then
			ok "HTTP 7880 answers inside the container"
		else
			bad "HTTP 7880 inside the container answered '${body:-nothing}' (want OK)"
		fi
	fi
	# Signalling is the one part that does go through Cloudflare: edge proxies /livekit/*.
	domain=$(env_val FLUXER_DOMAIN)
	if [ -n "$domain" ]; then
		body=$(curl -fsS --max-time 15 "https://$domain/livekit/" 2>/dev/null || true)
		if [ "$body" = OK ]; then
			ok "signalling answers publicly at https://$domain/livekit/"
		else
			bad "https://$domain/livekit/ answered '${body:-nothing}' (want OK)"
		fi
	fi

	# The IP that matters is the one LiveKit advertises in its ICE candidates.
	node_ip=$(env_val FLUXER_LIVEKIT_NODE_IP) src='FLUXER_LIVEKIT_NODE_IP in .env'
	if [ -z "$node_ip" ] && [ -n "$cid" ]; then
		node_ip=$(docker logs "$cid" 2>&1 | grep -o '"nodeIP": "[^"]*"' | tail -n 1 | sed 's/.*: "//; s/"$//')
		src="what LiveKit discovered via STUN at startup"
	fi
	public_ip=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null \
		|| curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)
	if [ -n "$node_ip" ]; then
		info "advertised IP $node_ip ($src)"
	else
		bad "could not tell which IP LiveKit advertises"
	fi
	if [ -z "$public_ip" ]; then
		info "could not ask an outside service for this host's public IP"
	elif [ -n "$node_ip" ] && [ "$public_ip" != "$node_ip" ]; then
		bad "this host egresses as $public_ip but LiveKit advertises $node_ip - clients will dial the wrong address"
	else
		ok "the outside world sees this host as $public_ip, matching what LiveKit advertises"
	fi
	ip=${node_ip:-$public_ip}

	# Local plumbing: a listener, and Docker's DNAT rules - which a firewalld reload
	# flushes (see README, "Why the watchdog exists").
	if ss -Htln "sport = :$tcp" 2>/dev/null | grep -q .; then ok "${tcp}/tcp is listening on the host"; else bad "${tcp}/tcp is not listening on the host"; fi
	if ss -Huln "sport = :$udp" 2>/dev/null | grep -q .; then ok "${udp}/udp is bound on the host"; else bad "${udp}/udp is not bound on the host"; fi
	if nat=$(sudo -n iptables -t nat -S DOCKER 2>/dev/null); then
		for rule in "tcp $tcp" "udp $udp"; do
			# shellcheck disable=SC2086 # "proto port" into $1 $2
			set -- $rule
			if printf '%s\n' "$nat" | grep -q -- "-p $1 .*--dport $2 -j DNAT"; then
				ok "Docker DNAT rule for $2/$1 present"
			else
				bad "no Docker DNAT rule for $2/$1 - the firewalld bug; fix: sudo systemctl restart docker"
			fi
		done
	else
		info "skipped the iptables DNAT check (needs passwordless sudo)"
	fi

	if [ -n "$ip" ]; then
		if python3 - "$ip" "$tcp" <<'PY' 2>/dev/null
import socket, sys
socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5).close()
PY
		then
			ok "TCP connect to $ip:$tcp succeeded"
			note "proves: the public address routes back to LiveKit from this host."
			note "does not prove: the cloud firewall (OCI security list / NSG) admits the internet."
		else
			bad "TCP connect to $ip:$tcp failed, even from the host itself"
		fi

		stun=$(python3 - "$ip" "$udp" <<'PY' 2>/dev/null || echo error
import os, socket, struct, sys
tid = os.urandom(12)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
s.sendto(struct.pack('!HHI', 1, 0, 0x2112A442) + tid, (sys.argv[1], int(sys.argv[2])))
try:
    data = s.recvfrom(2048)[0]
    print('reply' if data[8:20] == tid else 'other')
except socket.timeout:
    print('silent')
PY
		)
		case "$stun" in
			reply) ok "UDP $ip:$udp answered a STUN binding request" ;;
			*)
				info "UDP $ip:$udp: no answer to a bare STUN binding request (expected)"
				note "LiveKit only answers STUN carrying a live session's ICE credentials, so UDP"
				note "reachability cannot be proven from here; the bound port and DNAT rule above"
				note "are the most this host can show."
				;;
		esac
	fi

	# The only real proof is a client that connected. LiveKit logs the transport it got.
	if [ -n "$cid" ]; then
		types=$(docker logs --since 24h "$cid" 2>&1 | grep -o '"connectionType": "[a-z]*"' | sed 's/.*: "//; s/"$//' | sort | uniq -c | awk '{ printf "%s%s %s", sep, $1, $2; sep = ", " }')
		if [ -n "$types" ]; then
			ok "client connections in the last 24h by transport: $types"
			note "a 'udp' count here is proof that external UDP works; only 'tcp' or 'turn' means UDP is blocked."
		else
			info "no client connections logged in the last 24h to learn from"
		fi
	fi

	echo
	echo "To prove it from outside, on another network:"
	echo "  nc -vz ${ip:-<ip>} $tcp          # TCP"
	echo "  join a voice channel, then: fluxer voice   # look for a 'udp' connection above"
	[ "$fails" -eq 0 ] || { printf '\n%s check(s) failed\n' "$fails" >&2; return 1; }
}

cmd=${1:-}
[ $# -gt 0 ] && shift || true
case "$cmd" in
	psql) cmd_psql "$@" ;;
	valkey) cmd_valkey "$@" ;;
	sh) cmd_sh "$@" ;;
	errors) cmd_errors "$@" ;;
	top) cmd_top ;;
	voice) cmd_voice ;;
	help | -h | --help) usage ;;
	'') usage >&2; exit 2 ;;
	*) printf 'debug: unknown command: %s\n\n' "$cmd" >&2; usage >&2; exit 2 ;;
esac
