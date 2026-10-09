#!/usr/bin/env python3
"""webhook_post.py - post a message (stdin) to a Fluxer or Discord webhook.

Fluxer lets a webhook post 4000 characters (users get 2000; webhooks and bots
get at least the premium length, fluxer_api MessageValidationService), so a
post is normally one message. A longer text is split at line boundaries into
up to MAX_MESSAGES messages, and a ``` block cut in two is closed and reopened
across the cut. (A Discord webhook keeps 2000: set WEBHOOK_LIMIT=1900.)

  WEBHOOK=<url> webhook_post.py < message

The URL is a credential, so it comes from the environment, not argv (ps shows
argv). Prints the id of each message posted, when the server returns one.
"""
import json
import os
import sys
import time
import urllib.request

LIMIT = int(os.environ.get("WEBHOOK_LIMIT") or 3900)
MAX_MESSAGES = 5


def chunk(text):
    chunks, cur, fence = [], "", False
    for line in text.splitlines():
        line = line[:LIMIT - 10]
        if cur and len(cur) + len(line) + 5 > LIMIT:
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
    return [c.rstrip("\n") for c in chunks if c.strip()]


def main(argv):
    if argv:
        sys.exit("usage: WEBHOOK=<url> webhook_post.py < message")
    url = os.environ["WEBHOOK"]
    url += ("&" if "?" in url else "?") + "wait=true"
    for c in chunk(sys.stdin.read()):
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
