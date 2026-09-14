#!/bin/sh
# Tell a human when something breaks.
#
# The watchdog repairs what it can and writes to /var/log/fluxer-watchdog.log,
# which nobody reads. The instance was down for two weeks in Sept 2026 without
# anyone noticing, so logging alone is not monitoring. This pushes to ntfy, a
# webhook (Fluxer, Discord, Slack) and/or email.
#
# It sends on STATE CHANGES, not on every run: `alert` fires once when a key
# starts failing (then a reminder every NOTIFY_REMIND_HOURS), `ok` fires once
# when it recovers. A channel that pings every ten minutes gets muted, and a muted
# channel is the same as no channel.
#
# It must never break its caller, which is cron: nothing configured is a silent
# no-op, network calls time out after 10s, and delivery failures go to stderr
# with exit 0. Only `test` reports failure through its exit code.
#
#   notify.sh alert <key> <message>     failing; sends if newly failing (or reminder due)
#   notify.sh ok <key> [message]        healthy; sends "recovered" only if it was failing
#   notify.sh send <level> <key> <msg>  send unconditionally; level alert|recovered|info
#   notify.sh test                      send a test message, report each channel
#   notify.sh status                    channels configured, keys currently failing
#
# Config: $OPS/notify.conf (see notify.conf.example), overridden by
# environment variables of the same name. Email reuses the SMTP settings the
# instance already has in $FLUXER_DIR/.env.
set -eu

. "$(dirname "$(readlink -f "$0")")/lib.sh"
NOTIFY_CONF=${NOTIFY_CONF:-$OPS/notify.conf}
ENV_FILE="$FLUXER_DIR/.env"

# State lives with whoever runs us, so nobody fights over file ownership: the
# watchdog runs as root (/var/lib/fluxer-notify), backup.sh as ubuntu
# (~/.local/state/fluxer-notify). A shared dir would need a group and a umask
# that every caller agrees on, and a root-owned state file would leave the
# ubuntu user's `ok` unable to clear it. The keys never overlap between the two
# runners, and `status` reads both. Files are 644 in a 755 dir: nothing in them
# is secret.
umask 022
ROOT_STATE_DIR=/var/lib/fluxer-notify
USER_STATE_DIR="${XDG_STATE_HOME:-${HOME:-/nonexistent}/.local/state}/fluxer-notify"

usage() {
	cat <<'USAGE'
usage: notify.sh alert <key> <message>
       notify.sh ok <key> [message]
       notify.sh send <alert|recovered|info> <key> <message>
       notify.sh test
       notify.sh status
USAGE
	exit 2
}

warn() { printf 'notify: %s\n' "$*" >&2; }

# notify.conf is sourced, so an environment variable must be saved before and put
# back after, or the file would silently win over it. (Root sourcing a file the
# ubuntu user owns is no new trust: that user already owns the scripts root cron
# runs, and has sudo.)
CONF_VARS='NOTIFY_NTFY_URL NOTIFY_NTFY_TOKEN NOTIFY_WEBHOOK_URL NOTIFY_EMAIL_TO
NOTIFY_EMAIL_FROM NOTIFY_SMTP_HOST NOTIFY_SMTP_PORT NOTIFY_SMTP_USERNAME
NOTIFY_SMTP_PASSWORD NOTIFY_SMTP_SECURE NOTIFY_REMIND_HOURS NOTIFY_STATE_DIR'
load_config() {
	keep=''
	for v in $CONF_VARS; do
		if eval "[ -n \"\${$v+x}\" ]"; then
			keep="$keep $v"
			eval "_env_$v=\${$v}"
		fi
	done
	if [ -r "$NOTIFY_CONF" ]; then
		# shellcheck disable=SC1090
		. "$NOTIFY_CONF"
	fi
	for v in $keep; do
		eval "$v=\${_env_$v}"
	done
	# The delivery helper reads these from its environment, never from argv,
	# so tokens and passwords do not show up in `ps`.
	# shellcheck disable=SC2086,SC2163
	export $CONF_VARS
}

# One value from .env, read rather than sourced: values can hold anything.
# Only for non-secret keys; the delivery helper reads the SMTP password itself.
env_value() {
	sed -n "s/^$1=//p" "$ENV_FILE" 2> /dev/null | head -n 1 | sed "s/^[\"']//; s/[\"']\$//"
}

channels() {
	c=''
	[ -n "${NOTIFY_NTFY_URL:-}" ] && c="$c ntfy"
	[ -n "${NOTIFY_WEBHOOK_URL:-}" ] && c="$c webhook"
	[ -n "${NOTIFY_EMAIL_TO:-}" ] && c="$c email"
	printf '%s' "${c# }"
}

state_dir() {
	if [ -n "${NOTIFY_STATE_DIR:-}" ]; then
		printf '%s' "$NOTIFY_STATE_DIR"
	elif [ "$(id -u)" -eq 0 ]; then
		printf '%s' "$ROOT_STATE_DIR"
	else
		printf '%s' "$USER_STATE_DIR"
	fi
}

# Keys become file names: keep them to a safe alphabet.
clean_key() {
	k=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
	case "$k" in .*) k="_${k#.}" ;; esac
	printf '%s' "$k"
}

num() { case "$1" in '' | *[!0-9]*) printf 0 ;; *) printf '%s' "$1" ;; esac; }

utc() { date -u -d "@$1" '+%Y-%m-%d %H:%M UTC' 2> /dev/null || printf '@%s' "$1"; }

span() {
	s=$1
	if [ "$s" -ge 86400 ]; then
		printf '%dd %dh' $((s / 86400)) $((s % 86400 / 3600))
	elif [ "$s" -ge 3600 ]; then
		printf '%dh %dm' $((s / 3600)) $((s % 3600 / 60))
	else
		printf '%dm' $((s / 60))
	fi
}

# Show where a URL points without the part that is the secret: a webhook URL's
# path is its credential, and so is an ntfy topic.
mask_url() {
	printf '%s' "$1" | sed -E 's#^([A-Za-z]+://)([^/@]*@)?([^/]*).*#\1\3/...#'
}

# deliver <channel> <level> <title> <body> - one channel. Exit 0 = delivered,
# otherwise the reason is on stderr (with any secret it contains redacted).
deliver() {
	if ! command -v python3 > /dev/null 2>&1; then
		echo "python3 not found" >&2
		return 1
	fi
	# Belt and braces over the per-call 10s timeouts: DNS and TLS can still stall.
	limit=''
	if command -v timeout > /dev/null 2>&1; then limit='timeout 30'; fi
	# shellcheck disable=SC2086
	N_CHANNEL=$1 N_LEVEL=$2 N_TITLE=$3 N_BODY=$4 FLUXER_ENV_FILE=$ENV_FILE \
		$limit python3 - <<'PY'
import base64, json, os, smtplib, ssl, sys, urllib.parse, urllib.request
from email.header import Header
from email.message import EmailMessage
from email.utils import formataddr, formatdate, make_msgid

e = os.environ
channel, level, title, body = e["N_CHANNEL"], e["N_LEVEL"], e["N_TITLE"], e["N_BODY"]
TIMEOUT = 10
UA = "fluxer-ops-notify/1"


def dotenv(path):
    # Docker Compose .env syntax, just enough of it: KEY=value, optional quotes,
    # " #" starts a comment on an unquoted value.
    out = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                if k.startswith("export "):
                    k = k[7:].strip()
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                    v = v[1:-1]
                elif " #" in v:
                    v = v.split(" #", 1)[0].rstrip()
                out[k] = v
    except OSError:
        pass
    return out


def post(url, data, headers):
    headers = dict(headers, **{"User-Agent": UA})
    # urllib cannot take credentials in the URL (https://user:pass@host/...),
    # which is how a basic-auth ntfy or webhook is often written.
    u = urllib.parse.urlsplit(url)
    if u.username is not None:
        cred = f"{urllib.parse.unquote(u.username)}:{urllib.parse.unquote(u.password or '')}"
        headers.setdefault("Authorization", "Basic " + base64.b64encode(cred.encode()).decode())
        url = urllib.parse.urlunsplit(u._replace(netloc=u.netloc.rpartition("@")[2]))
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        if not 200 <= r.status < 300:
            raise RuntimeError(f"HTTP {r.status}")


def ntfy():
    prio, tags = {
        "alert": ("urgent", "rotating_light"),
        "recovered": ("default", "white_check_mark"),
    }.get(level, ("default", "information_source"))
    h = {"Title": title, "Priority": prio, "Tags": tags,
         "Content-Type": "text/plain; charset=utf-8"}
    if not title.isascii():
        h["Title"] = Header(title, "utf-8").encode()
    if e.get("NOTIFY_NTFY_TOKEN"):
        h["Authorization"] = "Bearer " + e["NOTIFY_NTFY_TOKEN"]
    # Over 4096 bytes ntfy turns the message into an attachment.
    post(e["NOTIFY_NTFY_URL"], body.encode("utf-8")[:3900], h)


def webhook():
    text = f"{title}\n{body}"
    if len(text) > 1900:  # Discord rejects content over 2000 characters
        text = text[:1900] + "\n[truncated]"
    # "content" for Fluxer and Discord, "text" for Slack; each ignores the other.
    data = json.dumps({"content": text, "text": text}).encode("utf-8")
    post(e["NOTIFY_WEBHOOK_URL"], data, {"Content-Type": "application/json"})


def email():
    env = dotenv(e["FLUXER_ENV_FILE"])

    def cfg(ours, theirs, default=""):
        return e.get(ours) or env.get(theirs) or default

    host = cfg("NOTIFY_SMTP_HOST", "FLUXER_EMAIL_SMTP_HOST")
    port = int(cfg("NOTIFY_SMTP_PORT", "FLUXER_EMAIL_SMTP_PORT", "0") or 0) or 587
    user = cfg("NOTIFY_SMTP_USERNAME", "FLUXER_EMAIL_SMTP_USERNAME")
    password = cfg("NOTIFY_SMTP_PASSWORD", "FLUXER_EMAIL_SMTP_PASSWORD")
    secure = cfg("NOTIFY_SMTP_SECURE", "FLUXER_EMAIL_SMTP_SECURE").lower() in ("true", "1", "yes")
    sender = cfg("NOTIFY_EMAIL_FROM", "FLUXER_EMAIL_FROM_EMAIL")
    name = env.get("FLUXER_EMAIL_FROM_NAME") or "Fluxer"
    to = [a.strip() for a in e["NOTIFY_EMAIL_TO"].split(",") if a.strip()]
    if not host:
        raise RuntimeError("no SMTP host (FLUXER_EMAIL_SMTP_HOST in .env, or NOTIFY_SMTP_HOST)")
    if not sender:
        raise RuntimeError("no sender (FLUXER_EMAIL_FROM_EMAIL in .env, or NOTIFY_EMAIL_FROM)")

    msg = EmailMessage()
    msg["Subject"] = title
    msg["From"] = formataddr((name, sender))
    msg["To"] = ", ".join(to)
    msg["Date"] = formatdate(usegmt=True)
    msg["Message-ID"] = make_msgid(domain=sender.rpartition("@")[2] or None)
    msg.set_content(body)

    ctx = ssl.create_default_context()
    # 465 is TLS from the first byte. Anything else upgrades with STARTTLS, which
    # SECURE=true makes mandatory: never hand credentials over in clear text.
    if port == 465:
        s = smtplib.SMTP_SSL(host, port, timeout=TIMEOUT, context=ctx)
    else:
        s = smtplib.SMTP(host, port, timeout=TIMEOUT)
    with s:
        s.ehlo()
        if port != 465:
            if s.has_extn("starttls"):
                s.starttls(context=ctx)
                s.ehlo()
            elif secure:
                raise RuntimeError(f"{host}:{port} does not offer STARTTLS and SMTP_SECURE is true")
        if user:
            s.login(user, password)
        s.send_message(msg, to_addrs=to)


try:
    {"ntfy": ntfy, "webhook": webhook, "email": email}[channel]()
except Exception as x:
    reason = f"{type(x).__name__}: {x}"
    for secret in (e.get("NOTIFY_NTFY_URL"), e.get("NOTIFY_NTFY_TOKEN"),
                   e.get("NOTIFY_WEBHOOK_URL"), e.get("NOTIFY_SMTP_PASSWORD"),
                   dotenv(e["FLUXER_ENV_FILE"]).get("FLUXER_EMAIL_SMTP_PASSWORD")):
        if secret and len(secret) >= 4:
            reason = reason.replace(secret, "<redacted>")
    print(reason[:300], file=sys.stderr)
    sys.exit(1)
PY
}

# send_all <level> <title> <message> - every configured channel. Returns 0 when
# at least one delivered, so a state change is recorded as notified.
send_all() {
	host=$(uname -n)
	domain=$(env_value FLUXER_DOMAIN)
	body=$(printf '%s\n\n%s (host %s), %s' "$3" "${domain:-unknown instance}" \
		"$host" "$(date -u '+%Y-%m-%d %H:%M UTC')")
	delivered=0
	for ch in $(channels); do
		if err=$(deliver "$ch" "$1" "$2" "$body" 2>&1); then
			delivered=$((delivered + 1))
		else
			warn "$ch: not delivered: $err"
		fi
	done
	[ "$delivered" -gt 0 ]
}

title() {
	domain=$(env_value FLUXER_DOMAIN)
	printf '%s %s on %s' "$1" "$2" "${domain:-$(uname -n)}"
}

# State file: line 1 = when it started failing, line 2 = when we last managed to
# tell someone (0 = not yet), rest = latest message. Written via rename so a
# concurrent reader never sees half a file.
save_state() {
	d=$(dirname "$1")
	if ! { mkdir -p "$d" && printf '%s\n%s\n%s\n' "$2" "$3" "$4" > "$1.tmp.$$" \
		&& mv -f "$1.tmp.$$" "$1"; } 2> /dev/null; then
		rm -f "$1.tmp.$$" 2> /dev/null || true
		# Carry on: an alert that repeats because it cannot be recorded is
		# annoying, one that is swallowed is the problem this script exists for.
		warn "cannot write state to $d; this alert will repeat until that is fixed"
	fi
}

cmd_alert() {
	key=$(clean_key "$1")
	msg=$2
	[ -n "$(channels)" ] || return 0
	f="$(state_dir)/$key"
	now=$(date +%s)
	since=$now
	sent=0
	if [ -f "$f" ]; then
		since=$(num "$(sed -n 1p "$f")")
		sent=$(num "$(sed -n 2p "$f")")
		[ "$since" -gt 0 ] || since=$now
	fi
	hours=$(num "${NOTIFY_REMIND_HOURS:-24}")

	if [ "$sent" -gt 0 ]; then
		if [ "$hours" -eq 0 ] || [ $((now - sent)) -lt $((hours * 3600)) ]; then
			save_state "$f" "$since" "$sent" "$msg"
			return 0
		fi
		t=$(title 'STILL FAILING' "$key")
		m=$(printf 'Failing for %s, since %s.\n\n%s' "$(span $((now - since)))" "$(utc "$since")" "$msg")
	else
		# New, or an earlier alert that no channel accepted: try (again).
		t=$(title ALERT "$key")
		m=$msg
	fi
	if send_all alert "$t" "$m"; then
		sent=$now
	fi
	save_state "$f" "$since" "$sent" "$msg"
}

cmd_ok() {
	key=$(clean_key "$1")
	f="$(state_dir)/$key"
	[ -f "$f" ] || return 0
	# A recovery nobody was alerted to (no channel took the alert) is noise.
	if [ -n "$(channels)" ] && [ "$(num "$(sed -n 2p "$f")")" -gt 0 ]; then
		since=$(num "$(sed -n 1p "$f")")
		m="Back to normal after $(span $(($(date +%s) - since)))."
		[ -n "${2:-}" ] && m=$(printf '%s\n\n%s' "$m" "$2")
		send_all recovered "$(title RECOVERED "$key")" "$m" || true
	fi
	# Cleared even if the recovery message did not go out: a key stuck at
	# "failing" would swallow the next real alert.
	rm -f "$f" || warn "cannot clear $f"
}

cmd_send() {
	case "$1" in
		alert) t=$(title ALERT "$(clean_key "$2")") ;;
		recovered) t=$(title RECOVERED "$(clean_key "$2")") ;;
		info) t=$(title INFO "$(clean_key "$2")") ;;
		*) usage ;;
	esac
	[ -n "$(channels)" ] || return 0
	send_all "$1" "$t" "$3" || true
}

cmd_test() {
	chs=$(channels)
	if [ -z "$chs" ]; then
		echo "Nothing configured. Copy notify.conf.example to $NOTIFY_CONF and set a channel." >&2
		exit 1
	fi
	host=$(uname -n)
	domain=$(env_value FLUXER_DOMAIN)
	body=$(printf 'Test message from fluxer-ops notify.sh. If you can read this, alerts reach you.\n\n%s (host %s), %s' \
		"${domain:-unknown instance}" "$host" "$(date -u '+%Y-%m-%d %H:%M UTC')")
	t=$(title TEST notify)
	fails=0
	for ch in $chs; do
		if err=$(deliver "$ch" info "$t" "$body" 2>&1); then
			printf 'ok    %s\n' "$ch"
		else
			fails=$((fails + 1))
			printf 'FAIL  %s  %s\n' "$ch" "$err"
		fi
	done
	[ "$fails" -eq 0 ]
}

cmd_status() {
	if [ -r "$NOTIFY_CONF" ]; then
		mode=$(stat -c %a "$NOTIFY_CONF" 2> /dev/null || echo '?')
		printf 'config     %s (mode %s)\n' "$NOTIFY_CONF" "$mode"
		case "$mode" in 600 | 400 | '?') ;; *) printf 'WARNING    it holds tokens: chmod 600 %s\n' "$NOTIFY_CONF" ;; esac
	else
		printf 'config     %s not found (environment only)\n' "$NOTIFY_CONF"
	fi

	if [ -n "${NOTIFY_NTFY_URL:-}" ]; then
		printf 'ntfy       %s%s\n' "$(mask_url "$NOTIFY_NTFY_URL")" \
			"$([ -n "${NOTIFY_NTFY_TOKEN:-}" ] && echo '  (token set)')"
	else
		printf 'ntfy       not configured\n'
	fi
	if [ -n "${NOTIFY_WEBHOOK_URL:-}" ]; then
		printf 'webhook    %s\n' "$(mask_url "$NOTIFY_WEBHOOK_URL")"
	else
		printf 'webhook    not configured\n'
	fi
	if [ -n "${NOTIFY_EMAIL_TO:-}" ]; then
		h=${NOTIFY_SMTP_HOST:-$(env_value FLUXER_EMAIL_SMTP_HOST)}
		p=${NOTIFY_SMTP_PORT:-$(env_value FLUXER_EMAIL_SMTP_PORT)}
		if [ -n "$h" ]; then
			printf 'email      to %s via %s:%s\n' "$NOTIFY_EMAIL_TO" "$h" "${p:-587}"
		else
			printf 'email      to %s, but NO SMTP HOST: set FLUXER_EMAIL_SMTP_HOST in .env or NOTIFY_SMTP_HOST\n' "$NOTIFY_EMAIL_TO"
		fi
	else
		printf 'email      not configured\n'
	fi
	hours=$(num "${NOTIFY_REMIND_HOURS:-24}")
	if [ "$hours" -eq 0 ]; then
		printf 'reminders  off\n'
	else
		printf 'reminders  every %sh while failing\n' "$hours"
	fi

	now=$(date +%s)
	failing=0
	seen=''
	for d in "$(state_dir)" "$ROOT_STATE_DIR" "$USER_STATE_DIR"; do
		case " $seen " in *" $d "*) continue ;; esac
		seen="$seen $d"
		[ -d "$d" ] || continue
		for f in "$d"/*; do
			[ -f "$f" ] || continue
			case "$f" in *.tmp.*) continue ;; esac
			failing=$((failing + 1))
			since=$(num "$(sed -n 1p "$f")")
			sent=$(num "$(sed -n 2p "$f")")
			if [ "$sent" -gt 0 ]; then n="last notified $(utc "$sent")"; else n='NOT YET DELIVERED'; fi
			printf 'FAILING    %s  for %s, since %s, %s  [%s]\n' "$(basename "$f")" \
				"$(span $((now - since)))" "$(utc "$since")" "$n" "$d"
			sed '1,2d' "$f" | head -n 5 | sed 's/^/             /'
		done
	done
	[ "$failing" -gt 0 ] || printf 'failing    nothing\n'
}

cmd=${1:-}
[ $# -gt 0 ] && shift || true
load_config

case "$cmd" in
	alert) { [ $# -ge 2 ] && [ -n "$1" ]; } || usage; cmd_alert "$1" "$2" ;;
	ok) { [ $# -ge 1 ] && [ -n "$1" ]; } || usage; cmd_ok "$1" "${2:-}" ;;
	send) { [ $# -ge 3 ] && [ -n "$2" ]; } || usage; cmd_send "$1" "$2" "$3" ;;
	test) cmd_test || exit 1 ;;
	status) cmd_status ;;
	*) usage ;;
esac
exit 0
