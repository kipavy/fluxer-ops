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
| `check.sh` | you, anytime | Verifies 6 public endpoints, the `/gateway` WebSocket upgrade, and container health. Exit 0 = healthy, 1 = broken. `--quiet` for failures only. |
| `watchdog.sh` | root cron, every 10 min | Restores Docker's iptables chain if firewalld wiped it, and brings the stack up if services are missing. |
| `backup.sh` | user cron, 03:00 daily | `pg_dump` + uploads + `.env` + configs + these scripts, into `../fluxer-backups/auto-<ts>/`, 14-day retention. |
| `update.sh` | you, when updating | iptables preflight, refreshes and verifies `install.sh`, shows the plan, asks, applies, then verifies. |

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
