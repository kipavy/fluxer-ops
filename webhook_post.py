#!/usr/bin/env python3
"""webhook_post.py - post a message (stdin) to a Fluxer or Discord webhook.

Messages are capped at 2000 characters, so a long text is split at line
boundaries into up to MAX_MESSAGES messages. A ``` block cut in two is closed
and reopened across the cut.

--hidden wraps each message in a block spoiler (a line "||" before and after):
the client shows it collapsed until clicked. Used for the changelog details,
so the channel shows only the short summary. A stray "||" inside the text
would end the spoiler early, so it is broken up.

  WEBHOOK=<url> webhook_post.py [--hidden] < message

The URL is a credential, so it comes from the environment, not argv (ps shows
argv). Prints the id of each message posted, when the server returns one.
"""
import json
import os
import sys
import time
import urllib.request

LIMIT = 1900
MAX_MESSAGES = 5
SPOILER_OPEN, SPOILER_CLOSE = "||\n", "\n||"


def chunk(text, hidden=False):
    budget = LIMIT - (len(SPOILER_OPEN) + len(SPOILER_CLOSE) if hidden else 0)
    chunks, cur, fence = [], "", False
    for line in text.splitlines():
        if hidden:
            line = line.replace("||", "| |")
        line = line[:budget - 10]
        if cur and len(cur) + len(line) + 5 > budget:
            chunks.append(cur + ("```\n" if fence else ""))
            cur = "```\n" if fence else ""
        cur += line + "\n"
        if line.startswith("```"):
            fence = not fence
    if cur.strip():
        chunks.append(cur)
    if len(chunks) > MAX_MESSAGES:
        chunks = chunks[:MAX_MESSAGES]
        chunks[-1] += "… (la suite : `fluxer changelog`)\n"
    chunks = [c.rstrip("\n") for c in chunks if c.strip()]
    if hidden:
        chunks = [SPOILER_OPEN + c + SPOILER_CLOSE for c in chunks]
    return chunks


def main(argv):
    if argv not in ([], ["--hidden"]):
        sys.exit("usage: WEBHOOK=<url> webhook_post.py [--hidden] < message")
    url = os.environ["WEBHOOK"]
    url += ("&" if "?" in url else "?") + "wait=true"
    for c in chunk(sys.stdin.read(), hidden=bool(argv)):
        req = urllib.request.Request(url, json.dumps({"content": c}).encode(),
                                     {"Content-Type": "application/json", "User-Agent": "fluxer-ops"})
        with urllib.request.urlopen(req, timeout=15) as r:
            body = r.read()
        try:
            print(json.loads(body)["id"])
        except (ValueError, KeyError, TypeError):
            pass
        time.sleep(1)


if __name__ == "__main__":
    main(sys.argv[1:])
