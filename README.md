# fluxer-ops

Run your own [Fluxer](https://github.com/fluxerapp/fluxer) chat server, and keep it
running: nightly backups, a watchdog, alerts, safe updates, and one `fluxer` command
for the rest.

## Quick start

You need:

- a Linux server with a public IP (any VPS: Oracle Cloud, Hetzner, AWS, DigitalOcean…)
- a domain or subdomain you can add a DNS record to

On the server, as a normal user who can `sudo`:

```sh
curl -fsSL https://raw.githubusercontent.com/kipavy/fluxer-ops/main/get.sh | sh
```

It checks everything before it changes anything, and asks before each change:

1. **Prerequisites**: installs Docker if it is missing, gives you access to it.
2. **Your instance**: uses the Fluxer already on the server, or installs one: it checks
   your domain points here, tells you which ports to open at your provider, then runs
   Fluxer's official installer (checksum-verified: the `.sha256` comes from the same
   place over the same TLS connection, so this catches a corrupted download, not a
   swapped one - it is not a signature).
3. **Wiring**: the `fluxer` command, nightly backups, the watchdog.
4. **Optional**: alerts to your phone or chat, encrypted off-site backups, fixes for
   firewalld and Cloudflare, each offered only when it applies.
5. **Checks**, then prints your instance's URL and what to do next.

Running it again is safe: whatever is already done shows ✓ and is left alone.
`fluxer setup --check` reports without changing anything.

Prefer to read before running anything? The same thing, without the pipe:

```sh
git clone https://github.com/kipavy/fluxer-ops ~/fluxer/ops
~/fluxer/ops/setup.sh
```

Already running Fluxer somewhere else than `~/fluxer`? It is found through Docker, or
point at it: `FLUXER_DIR=/path/to/fluxer` before either command. That is enough for
`fluxer setup`, `check`, `backup` and the rest, but `fluxer badge-patch` (and
`update`'s re-apply of it) and backups including `ops/` itself still expect this
checkout at `<instance>/ops`; `setup.sh` says so if it is not.

### If the first install does not come up

| Symptom | Fix |
| --- | --- |
| "does not point at this server yet" | Add the `A` record setup shows at your DNS provider. It can take a few minutes; press Enter to re-check. |
| Installer stops with "the stack did not come up" | Almost always ports 80/443 closed at the provider (security list / security group / cloud firewall), or DNS. Open them and run `fluxer setup` again. |
| Behind Cloudflare and no certificate | Set the record to "DNS only" until the certificate is issued, then back to proxied with SSL mode "Full (strict)". |
| "cannot use Docker" or `setup --check` says "this login is not yet" | Log out and back in once: the docker group applies to new logins. (On a first run `setup.sh` usually works around this itself via `sg`, without a fresh login.) |
| Voice calls connect but no audio | Ports 7881/tcp and 7882/udp at the provider. `fluxer voice` checks them. |

## This deployment

Upstream ships `install.sh`, which handles **installs, updates and rollback**, and
takes a backup **only during an upgrade**. There is no upstream CLI for monitoring or
for scheduled backups. These scripts fill that gap. They started on an Oracle Cloud
host with firewalld, which is where several of them (watchdog, firewall-fix) come
from.

## The `fluxer` command

One entry point, on `PATH` via a symlink in `~/.local/bin`, with tab completion, so
it works from any directory. `fluxer help` is the full list; the shape of it:

```
Health    status [--json]  check  doctor  errors  top  voice
Stack     logs  up  down  ps  restart  psql  valkey  sh <svc>
Updates   changelog  update  rollback  prune
Accounts  users  premium  gifts  badge-patch
Backups   backup  backups  verify-backup  restore  offsite
Host      notify  disk  env  cf-ips  firewall-fix  setup
```

It is a **thin dispatcher**, not a rewrite: it delegates to the scripts below,
which are tested independently and are what cron calls directly. Nothing is
duplicated, so there is no second copy to drift. `./selftest.sh` (`--lint` adds
shellcheck) proves the wiring: every script parses, every command in the help is
dispatched and completes, and nothing secret is tracked. Run it after touching
`fluxer`.

Three commands are worth knowing before you need them:

- **`verify-backup`** restores the newest dump into a throwaway `fluxer_verify`
  database, counts rows, compares against live, and drops it. The live database is
  never touched. This is what turns "we have backups" into "the backups
  demonstrably restore".
- **`doctor`** is the other half of `check`. `check` asks "is it serving right now";
  `doctor` asks "will it still be serving, and recoverable, next week" (see below).
- **`prune`**, because on this deployment even a plain `docker image prune` breaks
  rollback (see *Updating*).

## Scripts

| Script | Run by | What it does |
| --- | --- | --- |
| `check.sh` | you, anytime | Verifies 6 public endpoints, the `/gateway` WebSocket upgrade, container health, and that every script the app shell names resolves. Exit 0 = healthy, 1 = broken. `--quiet` for failures only. |
| `watchdog.sh` | root cron, every 10 min | Restores Docker's iptables chain if firewalld wiped it, and brings the stack up if services are missing. |
| `backup.sh` | user cron, 03:00 daily | `pg_dump` + uploads + `.env` + configs + these scripts, into `../fluxer-backups/auto-<ts>/`, 14-day retention. |
| `update.sh` | you, when updating | iptables preflight, refreshes and verifies `install.sh`, shows the plan, asks, applies, then verifies. |
| `premium.sh` | you | Grants or revokes Plutonium on an account and applies the badge patch if needed. One command, start to finish. |
| `badge-patch.sh` | `update.sh`, `premium.sh`, and you | Patches the web bundle so the Plutonium badge renders on a self-hosted instance. `--revert` undoes it. |
| `notify.sh` | `watchdog.sh`, `backup.sh`, `offsite.sh`, you | Alerts through ntfy, a webhook and/or email, on state changes only. |
| `offsite.sh` | `backup.sh`, and you | restic (from its Docker image) to Cloudflare R2: push, snapshots, check, restore into a local dir. A no-op until configured. |
| `doctor.sh` | you | Read-only drift checks: cron, backups, off-site, alerts, certs, Cloudflare ranges, badge patch, rollback images. |
| `firewall-fix.sh` | you, once | Diagnoses Docker vs firewalld on this host; `--apply` installs the systemd drop-in that fixes it. |
| `cf-ips.sh` | you, `doctor.sh` | Compares `FLUXER_EDGE_TRUSTED_PROXIES` with Cloudflare's published ranges; `--apply` rewrites that line. |
| `users.sh` | you | List and inspect accounts, set STAFF, mark an email verified, instance counts. |
| `gifts.sh` | you | Plutonium gift codes. |
| `debug.sh` | you | psql / valkey-cli / shell shortcuts, grouped error scan, per-service memory, voice reachability. |
| `prune.sh` | you | Frees image space while keeping every image a container, the compose file or the newest 2 installer records needs. Lists by default. |
| `disk.sh` | you; user cron `--record` daily | Filesystem, volumes, backups, images; keeps `../fluxer-backups/disk-history.tsv` for growth and days-until-full. |
| `env.sh` | you | `keys`/`get`/`set`/`diff` on `.env`; secrets masked, backup before every change. |
| `changelog.sh` | you, before updating | Per-component running version vs what `v1` points at now, and the commits in between. |
| `setup.sh` | you, or `get.sh` | Prerequisites, the instance (installing it if needed), the `fluxer` symlink, completion, cron jobs, optional extras. Idempotent; `--check` only reports. |
| `get.sh` | `curl \| sh` | Clones this repository next to the instance and runs `setup.sh`. |
| `lib.sh` | every script | Finds the instance (`FLUXER_DIR`) and backups (`BACKUP_ROOT`); nothing is hardcoded. |
| `install-host.sh` | old habits | Same as `setup.sh --no-extras`. |
| `selftest.sh` | you, after editing these | Checks the tooling itself. Touches nothing. |

## Cron jobs

`fluxer setup` adds them, and never rewrites a line already there:

- `watchdog.sh` every 10 minutes in **root's** crontab (it needs iptables and systemctl)
- `backup.sh` at 03:00 and `disk.sh --record` at 03:30 in the user's

Each line carries `FLUXER_DIR=`, since cron starts with an empty environment.
`fluxer setup --check` exits 1 if one is missing, which is also what `fluxer doctor`
looks at.

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

The watchdog now also **tells you** (see *Alerting*), and retries a failing health
check once, 30 seconds later, before it does.

### The root cause, and `fluxer firewall-fix`

It is not an nft-vs-legacy split: iptables and firewalld both drive nftables here.
It is this: firewalld wipes every iptables table when it **starts** (not only on a
reload). Docker is meant to rebuild its chains when it hears firewalld come back,
but it hears that over a D-Bus connection that it opens once and never reopens if
the bus itself restarts ([moby `firewalld.go`](https://github.com/moby/moby/blob/v26.0.1/libnetwork/iptables/firewalld.go)).

That is what the journal shows. On 2026-08-12 11:25 a batch of service restarts
bounced `dbus.service`; firewalld, which lives on D-Bus, died with it and started
fresh, wiping the tables. The same dockerd kept running with a dead connection and
never heard. Running containers do not need the chain, so nothing broke until the
next container start, which then failed on `No chain/target/match by that name`.
(The log shows that dockerd running `iptables --wait -t nat -A DOCKER` directly; a
connected dockerd goes through firewalld instead.)

`fluxer firewall-fix` with no flags shows that evidence live: backends, whether
dockerd currently holds a D-Bus connection, and every time firewalld or dbus
started outside boot. `--apply` installs

```ini
# /etc/systemd/system/firewalld.service.d/50-fluxer-restart-docker.conf
[Service]
ExecStartPost=-/usr/bin/systemctl --no-block try-restart docker.service
```

so any start of firewalld under a running Docker restarts Docker, which rebuilds
its chains. `try-restart` is a no-op at boot, when Docker is not up yet.
`--no-block` is load-bearing: Docker is ordered after firewalld, so waiting for it
there deadlocks (reproduced with throwaway units). `PartOf=` was rejected: it
misses a crash-then-start, which is exactly what happened, and would stop the stack
whenever firewalld stops. The cost is one stack restart per firewalld start outside
boot -- two in the three months of journal. `--test` prints how to verify it by
hand; `--revert` removes it. **Not applied yet**: that is your call, and the
verification restarts the stack.

Separately, Docker 26 does not fully restore its rules even on a clean
`firewall-cmd --reload` (CVE-2025-54410, bridge isolation rules). Docker >= 28 fixes
that part.

## Alerting

The watchdog repaired things and wrote to `/var/log/fluxer-watchdog.log`, which
nobody reads. That is how the instance stayed down for two weeks unnoticed. Now
every problem also goes to `notify.sh`, which reaches a human through
[ntfy](https://ntfy.sh), a webhook (Fluxer, Discord or Slack) and/or email.

```sh
cp ops/notify.conf.example ops/notify.conf && chmod 600 ops/notify.conf   # set a channel
fluxer notify test      # per-channel ok/FAIL
fluxer notify status    # what is configured, what is failing right now
```

It alerts on **state changes, not on every run**: once when something starts
failing, a reminder every `NOTIFY_REMIND_HOURS` (24) while it stays broken, once
when it recovers. A channel that pings every ten minutes gets muted, and a muted
channel is no channel. Keys: `docker-chain`, `stack-down`, `health` (watchdog),
`backup`, `offsite`. An alert no channel accepted is retried on the next run.

It never breaks cron: unconfigured it is a no-op, network calls give up after
10 s, and a failed delivery is logged while the caller carries on. Failure state
lives per runner (`/var/lib/fluxer-notify` for the root watchdog,
`~/.local/state/fluxer-notify` for the rest), so root and the user never fight over
a file; `status` reads both.

Email reuses the SMTP settings in `.env` -- which today has **no SMTP host**, so
email alerts need one set first. `notify.conf` holds webhook URLs and tokens, which
are credentials, so it is gitignored. Configure two channels if you can, and do not
make a webhook into *this* instance the only one: it goes down with the thing it is
meant to report.

## Will it still work next week: `fluxer doctor`

`fluxer check` asks whether the instance is serving now. `fluxer doctor` checks
everything that fails silently until the day it matters: the DOCKER chain and the
firewall fix, whether dockerd can still hear firewalld, both crontabs, the `fluxer`
symlink, backup age, contents and last run, free disk and where 14-day retention is
heading, uploads size against the 1 GB restic trigger, off-site backups,
notification channels, Cloudflare ranges, the badge patch against the app-proxy
image it was built from, the Cloudflare edge and Caddy origin certificates (warn
under 14 days, FAIL under 3), and whether rollback's recorded images are still on
disk.

Each line is `ok`, `warn` or `FAIL` with a one-line fix; any FAIL exits 1. It is
read-only, skips what it lacks tools or permission for, takes a couple of seconds,
and `--quiet` shows only what needs attention. As of 2026-09-13: 0 FAIL, 3 warn
(firewall fix not applied, no off-site, no alert channel).

## Updating

```sh
fluxer changelog     # what it would bring
fluxer update        # preflight, plan, ask, apply, verify
```

Upstream publishes no release notes: each component is tagged separately
(`fluxer-api@2026.913.183320`) and a release body is only a compare link.
`fluxer changelog` works from what does exist -- the commit each running image was
built from (its `org.opencontainers.image.revision` label) and what `v1` points at
in the registry now -- and prints, per component, running vs available and the
commit subjects in between, plus any third-party image the refreshed
`docker-compose.yml` would change. It uses a throwaway blobless clone rather than the
GitHub API, which allows 60 unauthenticated requests an hour.

`install.sh --update` refreshes only five stack files (`docker-compose.yml`,
`docker-compose.proxy.yml`, `tunnel.compose.yml`, `Caddyfile`, `.env.example`).
It **never updates itself**, so `update.sh` re-downloads and checksum-verifies it
first. Roll back with:

```sh
sh install.sh --rollback --dir /path/to/fluxer   # on this deployment, /home/ubuntu/Documents/fluxer
```

Rollback needs the previous images still on disk, and on the moving `v1` tag those
images are **untagged** after an update. Docker calls that dangling, so **even a
plain `docker image prune`** -- not just `-a` -- deletes exactly what rollback needs
(right after the last update: 13 images, 3.5 GB, all of which `docker system df`
calls "reclaimable"). Use `fluxer prune`: it keeps every image a container (running
or stopped), the compose file, or the newest two installer records refers to, lists
by default, and removes by ID without `-f` only after you confirm. Other projects'
images on this host are listed and never touched.

Database schema migrations are not reverted by a rollback.

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
| `premium_until`, `premium_gift_extension_ends_at` | **removed** | the server takes the later of the two as the end; with both absent it never expires to the server (`checkHasActivePaidPremium`) or the client (`isPremiumExpiredLocally`), so nothing strips it later -- including a redeemed gift's end date |
| `version` | `+1` | the row's optimistic-concurrency counter, bumped as the app would |

Values go in using the KV store's own encoding -- dates as
`{"value": ..., "__fluxer_type": "date"}`, plain numbers bare. Rows are addressed by
numeric user id, never by an interpolated username, and usernames are validated
before they reach a query. The api reads user rows from Postgres per request, so a
client reload is enough -- no restart. The `users` service does cache them for 30 s
(`FLUXER_SVC_CACHE_TTL_MS`), so how *other people* see the account can lag that long.

`--off` mirrors the api's own `PREMIUM_CLEAR_FIELDS` and deliberately leaves
`premium_lifetime_sequence` alone: a Visionary ID is an identity, not an
entitlement. It also leaves the badge patch in place, since other accounts may be
using it.

## Plutonium gift codes: `fluxer gifts`

```sh
fluxer gifts create --duration 1m --count 5   # Nd, Nw, Nm, Ny; at most 100
fluxer gifts list [--unredeemed | --redeemed | --revoked]
fluxer gifts show <code>
fluxer gifts revoke <code>                    # only while unredeemed
fluxer gifts redeem <code> <user>             # user or user#tag
```

Upstream has Plutonium gift codes, but **a self-hosted instance can neither mint
nor redeem them**. `POST /admin/gift-codes` throws
`FeatureNotAvailableSelfHostedError` (`admin/controllers/CodesAdminController.ts`),
the admin panel's gift page redirects away, and the redeem routes live in
`StripeController`, which `app/ControllerRegistry.ts` mounts only when
`self_hosted` is off -- this instance answers them with a bare `NOT_FOUND`. So a
`/gift/<code>` link opens in the app and reports an unknown gift. Hand out the
**code**, and redeem it here. Making the in-app flow work would take an **api**
patch (mounting those routes); a client patch alone cannot.

Both halves write what the api would have, checked field by field by running
upstream's own `AdminCodeGenerationService`, `GiftCodeRepository` and
`StripeGiftService` against a scratch database:

- **create**: a `gift_codes` row (32 characters of A-Za-z0-9 from a CSPRNG, created
  by the system user, version 1) plus its `gift_codes_by_creator` row. The whole
  batch is one transaction.
- **redeem**: upstream's refusals (revoked or redeemed code, unclaimed account,
  unverified email, `PURCHASE_DISABLED`, bot, lifetime account); then
  `redeemed_by`/`redeemed_at`, a `gift_codes_by_redeemer` row, and on the account
  `premium_gift_extension_ends_at` = latest of (now, `premium_until`, that field) +
  duration (months clamp to month end), grace cleared, `premium_type` 1 and
  `premium_since` only if it had no premium, `version + 1`. One transaction, where
  the api does two writes and undoes the first on failure.

A gift sets an **end date**, unlike `fluxer premium`. When it passes, the api strips
premium on the user's next session or profile view, badge included; nothing has to
run. That is why `redeem` also refuses an account holding open-ended premium from
`fluxer premium --subscriber`: the gift would put an end date on a grant that had
none. Lifetime gifts are not offered: upstream mints those only from a Stripe
checkout, and `fluxer premium <user>` is the lifetime path here.

In the self-hosted default `premium_mode` of `everyone`, every account already has
the perks, so a gift mostly means the badge -- which needs the badge patch; `redeem`
says so if it is off rather than recreating app-proxy as a side effect.

Tested against a synthetic database only; it has not yet run against this instance.

## Accounts from a shell: `fluxer users`

```sh
fluxer users list --recent 20
fluxer users show alice            # email and last IP masked; --reveal shows them
fluxer users show 'bob#0002'       # names are not unique; the tag picks one
fluxer users staff alice [--off]
fluxer users verify-email alice
fluxer users stats [--messages]    # --messages reads every message row, so opt-in
```

Reads go straight to the KV table; `show` never selects the password hash, TOTP
secret or Stripe ids, and "created" is decoded from the snowflake id. The admin API
could do the same, but it needs an admin API key made in the panel first.

The two writes mirror what the api does for the same action, field for field, plus
what `UserDataRepository.patchUser` does around it (`row_data || patch`,
`version + 1`, `updated_at = now()`, one statement):

| Command | Mirrors (`fluxer_api/src/api/`) | Writes |
| --- | --- | --- |
| `staff` | `admin/services/AdminUserSecurityService.updateUserFlags` | `flags` bit 0, as `{"__fluxer_type":"bigint","value":"..."}` |
| `verify-email` | `admin/services/AdminUserProfileService.verifyUserEmail` | `email_verified` true, `email_bounced` false, the email bits (243, `auth/AuthEmail.ts`) cleared from `suspicious_activity_flags` |

If an account still carries legacy flag bits, both refuse: the api rewrites those on
every write, and a one-statement edit would come out different. A row edit also
skips the gateway push (open clients see it after a reload), the `users` service
cache (others see it within ~30 s), the search reindex and the audit log.

Deliberately **not** here: disable, ban, unban. The api's `tempBanUser` also ends
every session and emails the user; a row marked banned while its sessions stay live
is worse than no command. Use the admin panel.

## Debugging: `errors`, `top`, `voice`, shells

`fluxer psql`, `fluxer valkey` and `fluxer sh <svc>` are shells with the right
credentials already in place.

`fluxer errors [--since 1h] [svc]` exists because the stack logs in six formats --
pino JSON (api, worker), Rust tracing JSON (media-proxy, users, messages), Erlang
reports (gateway), Go console (livekit), Postgres, glog (seaweedfs). Grepping for
"error" finds mostly INFO lines that mention one and misses Erlang reports, whose
level sits on a separate header line. It reads each format's real level, and
replaces ids, IPs, timestamps and numbers with placeholders so one failure repeated
a thousand times is one line with a count. `--warn` includes warnings.

`fluxer top` sorts services by memory against their compose limit.

`fluxer voice` exists because `check` cannot see voice: LiveKit media uses
7881/tcp and 7882/udp direct to the origin, and 7882/udp is the DNAT rule the
firewalld bug removes first. Each line says what it proves, and the honest answer is
"less than you would like": the TCP connect runs from the host to its own public
IP, so it does not prove the OCI security list lets the internet in; LiveKit does
not answer a bare STUN request, so UDP cannot be proven from the host at all. The
real proof is a client that connected, which it looks for in LiveKit's logs. From
another network, `nc -vz <ip> 7881` proves TCP.

## Restoring from a backup

> The database half is **verified**: `fluxer verify-backup` restores the newest dump
> into a scratch database and compares row counts against live. As of 2026-09-13 it
> restored 568,748 rows matching live exactly. The **uploads** half has still never
> been restored end to end, and `fluxer restore` itself has not been run in anger.

```sh
cd /path/to/fluxer   # on this deployment, /home/ubuntu/Documents/fluxer
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

From off-site, restore into a local directory first -- `offsite.sh` never writes to
a live volume -- then apply it the same way:

```sh
fluxer offsite restore latest /tmp/r
fluxer restore /tmp/r/backup
```

## Known gaps

- **Off-site backups are built but not configured.** Until `ops/offsite.conf`
  exists every backup is on the same disk as the data (`/dev/sda1`): it covers a bad
  upgrade and nothing if the host or disk is lost.
- **No alert channel configured**, so alerting is wired but silent.
- **The firewalld fix is written but not applied** (`fluxer firewall-fix --apply`).
- The **uploads** half of a restore has never been run end to end.

## Off-site backups

`backup.sh` takes a **full** copy every night and keeps 14, on the same disk as the
data. That covers a bad upgrade and nothing else, and costs `total_size x 14`: at
20 GB of uploads that is 280 GB on a 146 GB disk. It breaks exactly when there is
finally data worth protecting.

`offsite.sh` fixes both. After each nightly backup, `backup.sh` pushes it into a
[restic](https://restic.net) repository on **Cloudflare R2**: content-addressed
dedup, so a night costs roughly what changed; encrypted before it leaves the host;
and no egress fees, which is the bill that matters on the day you restore. restic
runs from its pinned official image (`restic/restic:0.19.1`), so nothing is
installed on the host. Until `ops/offsite.conf` exists the cron call is a silent
no-op.

```sh
fluxer offsite status                       # configured? reachable? last push age
fluxer offsite push                         # what cron does after backup.sh
fluxer offsite check --read-data-subset=5%  # plain `check` misses corrupt data packs
fluxer offsite snapshots
```

What goes up is **not** the backup directory as-is. `seaweedfs-data.tgz` is a gzip
stream, which differs from its first changed byte onward, so a 99%-identical tarball
uploads 100% new every night and defeats dedup. Instead restic reads the uploads
**volume** directly (read-only), next to the dump, `.env`, configs and `ops/`.
SeaweedFS blobs live in append-only `.dat` files, so a night uploads roughly the new
tail (a volume vacuum rewrites them; expect one large push then). `offsite.conf`
itself is excluded: the key to the repo is no use inside it.

Retention off-box: 14 daily, 8 weekly, 12 monthly (configurable), `forget --prune`
after each push. `status` exits 1 when the last push is older than 36 h; a failed
push alerts under `offsite`.

> **`RESTIC_PASSWORD` is the only key to every snapshot.** Lose it and the
> repository is unrecoverable. Keep a copy somewhere that is not this host.

Setup, once:

1. In R2, create a private bucket, and an API token with *Object Read & Write*
   scoped to that bucket only.
2. `cp ops/offsite.conf.example ops/offsite.conf && chmod 600 ops/offsite.conf`, fill
   it in with a generated `RESTIC_PASSWORD`, and put that password in a password
   manager.
3. `fluxer offsite init && fluxer offsite push && fluxer offsite status`.
4. Do one real `fluxer offsite restore latest <dir>` and `verify-backup` it before
   trusting it.

Only after that works:

1. Cut local retention to **2 days** (`KEEP_DAYS=2` in `backup.sh`) as a fast-restore
   cache.
2. Dump with `--format=custom -Z0`: restic compresses anyway, and an uncompressed
   dump dedups about 4x better on a typical night (measured on synthetic data:
   0.8 MiB vs 3.1 MiB). It is ~6.5x larger on local disk, which is why it waits for
   step 1.

Known limit: the R2 token on this host can also delete the repository, so a
compromised host can take the off-site copies with it. Closing that needs
append-only storage (R2 bucket lock rules).

## Disk, `.env`, and Cloudflare ranges

**`fluxer disk`** breaks usage down (filesystem, each volume, scheduled vs
installer backups, images) and, from the daily `--record` line cron writes to
`../fluxer-backups/disk-history.tsv`, prints growth per day and a straight-line
"full in N days". Sizes come from `docker system df -v`, so a cron run starts no
helper containers.

**`fluxer env`** exists so a one-line change does not mean putting every secret on
screen, or writing a line compose reads differently than it looks (`a #b` is `a`;
`$x` expands). `get` masks secret-looking keys unless `--reveal`; `set` backs up
`.env` to `.env.bak-<ts>` (mode 600), rewrites that single line atomically, quotes
only what compose would misread, and prints which services use the variable and the
exact `docker compose up -d` to run -- it never recreates anything itself. It
refuses `POSTGRES_PASSWORD` (postgres reads it only when the volume is created, so a
new value locks the stack out) and duplicate keys (`install.sh` reads the first,
compose the last). `diff` shows keys new in `.env.example`, never values.

**`fluxer cf-ips`**: Caddy trusts only the ranges in `FLUXER_EDGE_TRUSTED_PROXIES`
(see *Notes on this instance*). A Cloudflare range missing from it makes every
visitor through it look like Cloudflare, so rate limits and bans hit a whole PoP.
It fetches `ips-v4`/`ips-v6`, validates every line and the count (otherwise changes
nothing, exit 2), and prints what was added and removed (exit 0 in sync, 1 drift).
`--apply` backs up `.env`, swaps just that line keeping `private_ranges` and private
CIDRs, and offers `docker compose up -d edge`, since Caddy reads it only at creation.
Note it treats any public range that is not Cloudflare's as retired, so a
hand-added public proxy would be dropped.

## Notes on this instance

Public access is Cloudflare's **DNS proxy** (orange cloud), not a `cloudflared`
tunnel — there is no tunnel daemon anywhere on the host. Caddy (the `edge`
service) terminates TLS on the origin. Because of this, `FLUXER_EDGE_TRUSTED_PROXIES`
in `.env` must list Cloudflare's ranges: the shipped `Caddyfile` sets
`trusted_proxies_strict` and defaults to `private_ranges` only, so without them
every client IP resolves to Cloudflare's edge and rate limits and bans key off the
wrong address. `fluxer cf-ips` checks the list against Cloudflare's (`doctor` runs
it too).

Voice (LiveKit) uses 7881/tcp and 7882/udp **direct to the origin**, bypassing
Cloudflare entirely.

Found while building `firewall-fix`, not acted on:

- `netfilter-persistent` is enabled alongside firewalld, and its
  `/etc/iptables/rules.v4` is dead weight: firewalld wipes it at start. What actually
  controls access is firewalld's `public` zone, which opens a long list: 80, 9090,
  5000, 8888, 1001-1006, 1011-1016, 5076, 6881. Worth a review.
- Every container stopped on 2026-08-25 13:28 ("ShouldRestart failed" in the Docker
  log), cause not determined. That, more than the 08-12 chain wipe, is likely when
  the two-week outage actually began.
