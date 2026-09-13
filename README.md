# fluxer-ops

Operational scripts for a self-hosted [Fluxer](https://github.com/fluxerapp/fluxer) instance.

Upstream ships `install.sh`, which handles **updates and rollback only**, and takes a
backup **only during an upgrade**. There is no upstream CLI for monitoring or for
scheduled backups. These scripts fill that gap.

Deployed at: `/home/ubuntu/Documents/fluxer` (scripts live in `ops/`).

## The `fluxer` command

One entry point, on `PATH` via a symlink in `~/.local/bin`, so it works from any
directory:

```
fluxer status              What is running, disk, last backup, health at a glance
fluxer check               Full health check: endpoints, WebSocket, containers
fluxer logs [svc] [-f]     Tail logs, all services or one
fluxer up | down | restart [svc] | ps

fluxer update [--check]    Update safely: preflight, plan, apply, verify
fluxer rollback            Go back to the previous release
fluxer premium <user>      Grant Plutonium + the Visionary badge (--off revokes)
fluxer badge-patch         Re-apply just the client-side badge patch

fluxer backup              Take a backup now
fluxer backups             List every backup, ours and the installer's
fluxer verify-backup       Prove the newest dump restores, into a scratch database
fluxer restore <dir>       Restore from a backup (destructive, asks first)
```

It is a **thin dispatcher**, not a rewrite: it delegates to the scripts below,
which are tested independently and are what cron calls directly. Nothing is
duplicated, so there is no second copy to drift.

`verify-backup` is the one worth knowing about. It restores the newest dump into a
throwaway `fluxer_verify` database, counts rows, compares against live, and drops
it. The live database is never touched. This is what turns "we have backups" into
"the backups demonstrably restore".

To install the symlink on a fresh host:

```sh
ln -sf /home/ubuntu/Documents/fluxer/ops/fluxer ~/.local/bin/fluxer
```

## Scripts

| Script | Run by | What it does |
| --- | --- | --- |
| `check.sh` | you, anytime | Verifies 6 public endpoints, the `/gateway` WebSocket upgrade, container health, and that every script the app shell names resolves. Exit 0 = healthy, 1 = broken. `--quiet` for failures only. |
| `watchdog.sh` | root cron, every 10 min | Restores Docker's iptables chain if firewalld wiped it, and brings the stack up if services are missing. |
| `backup.sh` | user cron, 03:00 daily | `pg_dump` + uploads + `.env` + configs + these scripts, into `../fluxer-backups/auto-<ts>/`, 14-day retention. |
| `update.sh` | you, when updating | iptables preflight, refreshes and verifies `install.sh`, shows the plan, asks, applies, then verifies. |
| `premium.sh` | you | Grants or revokes Plutonium on an account and applies the badge patch if needed. One command, start to finish. |
| `badge-patch.sh` | `update.sh`, `premium.sh`, and you | Patches the web bundle so the Plutonium badge renders on a self-hosted instance. `--revert` undoes it. |

## Install on a fresh host

```sh
# root cron - the watchdog needs iptables and systemctl
sudo crontab -e
*/10 * * * * /home/ubuntu/Documents/fluxer/ops/watchdog.sh >/dev/null 2>&1

# user cron - nightly backup
crontab -e
0 3 * * * /home/ubuntu/Documents/fluxer/ops/backup.sh >/dev/null 2>&1
```

## Why the watchdog exists

**firewalld reloads flush Docker's iptables chains.** When the `DOCKER` chain
disappears from the nat table, no container can publish a port, and the entire
stack dies. It fails with an opaque message:

```
iptables failed: ... --dport 7882 -j DNAT ...: No chain/target/match by that name
```

This took the instance down for **two weeks in September 2026** with nobody
noticing. The fix is `sudo systemctl restart docker`, which rebuilds the chains.
The watchdog does this automatically. It is also the first thing to check if the
stack is down or a container will not start:

```sh
sudo iptables -t nat -L -n | grep '^Chain DOCKER'   # no output = this bug
```

A permanent fix (making Docker survive firewalld reloads) has **not** been applied.

## Updating

```sh
cd /home/ubuntu/Documents/fluxer && ./ops/update.sh
```

`install.sh --update` refreshes only five stack files (`docker-compose.yml`,
`docker-compose.proxy.yml`, `tunnel.compose.yml`, `Caddyfile`, `.env.example`).
It **never updates itself**, so `update.sh` re-downloads and checksum-verifies it
first. Roll back with:

```sh
sh install.sh --rollback --dir /home/ubuntu/Documents/fluxer
```

Rollback needs the previous images still on disk, so do not run
`docker image prune -a` until you are confident in a release. Database schema
migrations are not reverted by a rollback.

## The Plutonium badge patch

On a fresh instance, from nothing to a badge:

```sh
fluxer premium <username>   # sets the account up and applies the patch
```

then reload the client. The rest of this section is why that second half is needed
at all, and what it does.

The premium badge is hidden on self-hosted instances by the **client**, not by the
API. `UserProfileBadges.tsx` reads:

```ts
if (!selfHosted && profile?.premiumType && profile.premiumType !== UserPremiumTypes.NONE)
```

so no amount of account state brings it back. Everything else is already in place:
the API serves `premium_type` to profile viewers on any instance (it is stripped
only for `BADGE_HIDDEN` or a restricted profile), and `/badges/plutonium.svg` ships
in the `fluxer-static` image. The same gate hides the Partner and Bug Hunter
badges; `STAFF` has no gate, which is why that one shows on a stock instance.

There is no setting for it, and flipping `FLUXER_SELF_HOSTED` is not an option --
it also drives the setup flow, registration and the Stripe paths. So
`badge-patch.sh` edits the shipped bundle:

1. Finds the one content-hashed chunk in the **app-proxy image** that names
   `plutonium.svg`, and copies it out along with `index.html` (from the image,
   never from the running container, so a re-run starts from pristine bytes).
2. Deletes `!selfHosted &&` from that single condition, matching on the *shape* of
   the minified expression rather than on a release's variable names.
3. Publishes the result under a **new, content-derived name**
   (`<chunk>.<sha8>.js`, plus `.br` and `.gz` -- app-proxy serves whichever
   precompressed sibling the browser asks for) and rewrites `index.html` to point
   at it. The stock chunk stays in the image and simply stops being loaded.
4. Bind-mounts those files through `docker-compose.override.yml` (auto-loaded,
   because `.env` sets no `COMPOSE_FILE`), then proves app-proxy serves the patched
   bytes in all three encodings and that both the origin and public HTML reference
   the new chunk.

The image is never modified. `fluxer badge-patch --revert` removes the override and
the patched files; the stock `index.html` then points back at the stock chunk.

### Why a new filename instead of overwriting the chunk

This is the part worth keeping. Bundle chunks are served
`cache-control: public, max-age=31536000, immutable`, so overwriting one in place
leaves browsers and CDN edges serving the pre-patch bytes from a URL that, by
contract, never revalidates. That was not theoretical here: with the origin
provably patched in every encoding, and Cloudflare's cache for that exact URL
purged and re-verified from this host, the badge still did not appear in the
browser -- including a fresh incognito window. The same patch published under a new
filename appeared immediately.

`index.html` is `no-cache` and comes back `cf-cache-status: DYNAMIC`, so a new
chunk name is picked up on the next page load, everywhere, with nothing to purge.
Note that app-proxy **templates `index.html` on every request** (it injects
`__FLUXER_CONFIG__`) and does not serve the precompressed HTML siblings, so the
mounted file is a template, not a served artifact.

One cosmetic consequence: `sw.js` still lists the stock chunk in its precache
manifest, so the service worker caches a file nothing loads.

### Keeping it applied

The mounted `index.html` names a release-specific chunk, so it must **not** stay
mounted while the app image changes underneath it. `install.sh --update` finishes
with `compose pull` and `compose up -d`, and the override joins every compose
command, so the new image would be served an `index.html` pointing at chunks it
does not have -- the page answers 200 and the app loads nothing. So:

- **`fluxer update`** reverts the patch before applying, re-applies after the
  health checks pass, and if the update itself fails leaves the patch off and says
  so. Off is a working app without the badge.
- **`fluxer rollback`** does the same around `install.sh --rollback`, for the mirror
  image of the problem: a patch built from the newer release names chunks the older
  one never had.
- **`fluxer check`** verifies every `<script src>` in the served shell resolves, so
  this breakage is caught however it arises -- including someone running
  `install.sh` directly, around the patch. That check is the reason it is in
  `check.sh` and not only in `update.sh`: the watchdog runs `check.sh` every ten
  minutes, so a broken shell surfaces on its own rather than waiting to be noticed.

Anything else that changes the app image needs `fluxer badge-patch` by hand. A
re-run on unchanged content republishes to the same URL, so it is safe any time.

Worth knowing: **app-proxy reads `index.html` once at startup** and templates it
per request from memory, so editing the mounted file changes nothing until the
container is recreated. `badge-patch.sh` always recreates it; a hand edit will look
like it did nothing.

### Granting it: `fluxer premium`

```sh
fluxer premium <username>               # Visionary badge (lifetime)
fluxer premium <username> --subscriber  # "subscriber since" badge instead
fluxer premium <username> --off         # revoke
fluxer premium --list                   # who has premium
```

That is the whole flow -- it applies the badge patch itself if it is not on yet, so
a fresh instance needs one command and a page reload.

It writes the row directly, which is not laziness: the badge renders off
`premium_type` (`1` subscription, `2` lifetime, plus `premium_lifetime_sequence`
for the Visionary `#N`), and there is **no API for that field** -- 
`/admin/users/:id/premium-flags` only toggles `PremiumFlags` bits. So the admin
panel's premium override gets you the perks with `premium_type` still at `0`: no
badge. Doing the override flag in the same statement also means you do not need the
`STAFF` flag on your own account to grant premium to yourself.

What a grant sets:

| Field | Value | Why |
| --- | --- | --- |
| `premium_type` | `2`, or `1` with `--subscriber` | what the badge renders from |
| `premium_lifetime_sequence` | next free number, existing one kept | the Visionary `#N` |
| `premium_flags` | `ENABLED_OVERRIDE` on; `PERKS_DISABLED`, `BADGE_HIDDEN`, `BADGE_MASKED` off | the perks, and nothing left suppressing or downgrading the badge |
| `premium_since` | now, if not already set | the "since" in the tooltip |
| `premium_until` | **removed** | absent means never expires to both the server (`checkHasActivePaidPremium`) and the client (`isPremiumExpiredLocally`), so no sweep strips it later |
| `version` | `+1` | the row's optimistic-concurrency counter, bumped as the app would |

Values go in using the KV store's own encoding -- dates as
`{"value": ..., "__fluxer_type": "date"}`, plain numbers bare. Rows are addressed by
numeric user id, never by an interpolated username, and usernames are validated
before they reach a query. Nothing caches user rows (the repository reads Postgres
per request), so a client reload is enough -- no restart.

`--off` mirrors the api's own `PREMIUM_CLEAR_FIELDS` and deliberately leaves
`premium_lifetime_sequence` alone: a Visionary ID is an identity, not an
entitlement. It also leaves the badge patch in place, since other accounts may be
using it.

## Restoring from a backup

> The database half is **verified**: `fluxer verify-backup` restores the newest dump
> into a scratch database and compares row counts against live. As of 2026-09-13 it
> restored 568,748 rows matching live exactly. The **uploads** half has still never
> been restored end to end, and `fluxer restore` itself has not been run in anger.

```sh
cd /home/ubuntu/Documents/fluxer
d=../fluxer-backups/auto-<timestamp>

# database
docker compose up -d postgres
docker compose exec -T postgres psql -U fluxer -d postgres \
  -c 'DROP DATABASE fluxer;' -c 'CREATE DATABASE fluxer OWNER fluxer;'
docker compose exec -T postgres pg_restore -U fluxer -d fluxer < "$d/fluxer.dump"

# uploads
docker compose down
docker run --rm -v fluxer_seaweedfs-data:/data -v "$PWD/$d:/backup" alpine:3.22 \
  sh -c 'rm -rf /data/* && tar xzf /backup/seaweedfs-data.tgz -C /data'
docker compose up -d
./ops/check.sh
```

`.env` is required for a restore: it holds the secrets that open the database and
the object store. It is included in every backup.

## Known gaps

- **Backups are on the same disk as the data** (`/dev/sda1`). They cover a bad
  upgrade; they cover nothing if the host or disk is lost. See *Backup strategy*
  below — decided, deliberately not built yet.
- No alerting. The watchdog logs to `/var/log/fluxer-watchdog.log` and repairs
  what it can, but nothing notifies you.
- No permanent fix for the firewalld/Docker interaction.

## Backup strategy (decided, not built)

`backup.sh` today takes a **full** copy of the database and the entire uploads
volume every night and keeps 14. That is fine at the current size (~24 MB/night,
~336 MB total) and **does not scale**: the cost is `total_size x 14`. Once uploads
reach, say, 20 GB, that is 280 GB of backups on a 146 GB disk. It breaks exactly
when there is finally data worth protecting.

Decided plan, deferred by choice:

1. Move to [`restic`](https://restic.net) — content-addressed dedup, incremental,
   encrypted. Nightly cost drops to roughly what actually changed.
2. Push the repo to **Cloudflare R2** (same account as the DNS proxy, S3-compatible,
   no egress fees, which matters on a restore).
3. Then cut local retention to **2 days** (`KEEP_DAYS=2` in `backup.sh`) as a
   fast-restore cache, with full history living off-box.

Until step 2 exists, local retention stays at 14 days: shortening it early would
just mean less protection with nothing replacing it.

**Trigger to revisit:** when `fluxer_seaweedfs-data` passes ~1 GB, or before any
serious user growth. Check it with:

```sh
docker run --rm -v fluxer_seaweedfs-data:/data:ro alpine:3.22 du -sh /data
```

## Notes on this instance

Public access is Cloudflare's **DNS proxy** (orange cloud), not a `cloudflared`
tunnel — there is no tunnel daemon anywhere on the host. Caddy (the `edge`
service) terminates TLS on the origin. Because of this, `FLUXER_EDGE_TRUSTED_PROXIES`
in `.env` must list Cloudflare's ranges: the shipped `Caddyfile` sets
`trusted_proxies_strict` and defaults to `private_ranges` only, so without them
every client IP resolves to Cloudflare's edge and rate limits and bans key off the
wrong address. Refresh the list from https://www.cloudflare.com/ips-v4 and
https://www.cloudflare.com/ips-v6.

Voice (LiveKit) uses 7881/tcp and 7882/udp **direct to the origin**, bypassing
Cloudflare entirely.
