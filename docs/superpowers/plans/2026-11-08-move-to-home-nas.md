# Move to the home NAS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the instance from a dedicated LXC on the home NAS behind the existing Cloudflare Tunnel, with LiveKit alone on the OCI VM, and nothing changed for users.

**Architecture:** The move rides on `rexctl backup` / `rexctl restore` (one file: database, search data, uploads, settings, restorable on a new machine). The NAS edge serves plain HTTP to the tunnel; Cloudflare does TLS. A small `voice/` kit in this repo runs LiveKit plus a TLS proxy on the VM once the rest of the stack there is stopped.

**Tech Stack:** Proxmox `pct`, Debian 12 LXC with Docker, rexctl, fluxer-ops (POSIX sh), Cloudflare Tunnel (remotely managed, its own LXC), LiveKit, Caddy.

**Spec:** `docs/superpowers/specs/2026-11-08-move-to-home-nas-design.md`

## Global Constraints

- No port is opened on the home router. Public traffic to the NAS arrives only through the Cloudflare Tunnel.
- Same domain `fluxer.kipavy.fr`, same release, same rexctl settings and secrets (`LIVEKIT_API_KEY`/`LIVEKIT_API_SECRET` included): nothing is regenerated.
- LXC `fluxer`: 2 cores, 4096 MiB RAM, 60 GB root disk on storage `tank`, unprivileged, `nesting=1,keyctl=1`, `onboot=1`.
- Voice: `FLUXER_LIVEKIT_URL` and `FLUXER_LIVEKIT_INTERNAL_URL` both `https://voice.kipavy.fr`; LiveKit media stays on 7881/tcp and 7882/udp of the VM.
- Healthchecks at 60 s (overlay.sh, PR #12) on the NAS too.
- This repo is public: no IP address, token, key or secret in any committed file, plan or commit message.
- Every change to Cloudflare, the router, Proxmox or the VM's live stack is announced to the operator before it is made; the cutover (Task 6) runs only with the operator present.
- The VM's data is kept untouched for 14 days after the cutover; deleting it needs the operator's agreement.

## Review Focus

- **The rehearsal instance acting on real users.** A restored copy on the NAS has the real database: its worker could send emails or push notifications, and its bundled LiveKit could re-register. Task 3 starts it with no public route and stops it as soon as it is checked; its test asserts nothing was sent (`docker logs fluxer-push-1` and `fluxer-worker-1` show no deliveries).
- **Sessions after the move.** A user already logged in must stay logged in. Task 6 checks an existing browser session without logging in again; Task 3 checks the restored settings hash matches the VM's (`rexctl config list` values, secrets compared by hash only).
- **Real client IPs behind the tunnel.** Rate limits and bans key off the client IP. Task 4 asserts Caddy's access log shows the test client's public IP, not the cloudflared LXC's.
- **Uploads larger than a chunk and old uploads.** Task 3 and Task 6 fetch one upload from before the move (an attachment URL taken from the VM) and Task 6 uploads a new image, both by HTTP status 200 and matching size.
- **Voice signalling vs media.** The signalling can work (HTTPS through Cloudflare) while the media is blocked (direct UDP). Task 5 and Task 6 hold a real two-client call with audio both ways, not just a joined room.

---

### Task 1: The `voice/` kit (LiveKit alone, with a TLS proxy)

**Files:**
- Create: `voice/compose.yml`, `voice/Caddyfile`, `voice/env.example`
- Create: `tests/voice_test.sh`
- Modify: `.gitignore` (add `voice/.env`)

**Interfaces:**
- Produces: `docker compose --env-file voice/.env -f voice/compose.yml up -d` on the VM runs services `livekit` and `proxy`; `proxy` serves `${VOICE_DOMAIN}` on 80/443 and reverse-proxies to `livekit:7880`; `livekit` publishes 7881/tcp and 7882/udp.
- `voice/env.example` keys: `VOICE_DOMAIN=voice.kipavy.fr`, `LIVEKIT_IMAGE=` (same image digest as the stack's), `LIVEKIT_KEYS=` (the `key: secret` line, filled from rexctl on the VM, never committed), `LIVEKIT_WEBHOOK_URL=https://fluxer.kipavy.fr/<path the bundled config uses>`.

- [ ] **Step 1: Read the bundled LiveKit service**

On the VM: `sed -n '/^  livekit:/,/^  [a-z]/p' ~/Documents/fluxer/.rexctl/generated/docker-compose.yml` and `docker inspect fluxer-livekit-1 -f '{{json .Config.Env}}'` (print key names only, mask values). Record: how the config reaches LiveKit (env `LIVEKIT_CONFIG` or a file), the webhook URL, whether a Redis/Valkey block is present, the ports, `GOMEMLIMIT`/memory limit.

- [ ] **Step 2: Write `tests/voice_test.sh`**

Assertions, with `voice/env.example` copied to a temp `.env` filled with dummy values:
- `docker compose --env-file "$tmp/.env" -f voice/compose.yml config --services` prints exactly `livekit` and `proxy`.
- the rendered config contains `7881:7881/tcp` and `7882:7882/udp` for `livekit`, and `80:80`, `443:443` for `proxy`.
- the rendered LiveKit configuration contains the webhook URL from `.env` and no `redis` block.
- `voice/Caddyfile` contains `{$VOICE_DOMAIN}` and `reverse_proxy livekit:7880`.
- `git check-ignore voice/.env` succeeds.

- [ ] **Step 3: Run it, expect FAIL** (`sh tests/voice_test.sh`: files missing).

- [ ] **Step 4: Write `voice/compose.yml`, `voice/Caddyfile`, `voice/env.example`, `.gitignore` line**

`livekit` copies the bundled service from Step 1 with three changes: no Redis block (single node), webhook URL from `LIVEKIT_WEBHOOK_URL`, no dependency on other stack services. `proxy` is `caddy:2.11-alpine` (the stack's edge image) with the Caddyfile mounted read-only and a named volume for its certificates. Header comment in each file: what it is for and that it runs only once the main stack is stopped.

- [ ] **Step 5: Run `sh tests/voice_test.sh`, expect all `ok`.** Run the whole suite on the VM (`for t in tests/*_test.sh; do sh "$t"; done`), expect 0 FAIL.

- [ ] **Step 6: Commit** `voice: run LiveKit alone with a TLS proxy`.

### Task 2: The `fluxer` LXC with Docker, rexctl and fluxer-ops

**Files:** none in the repo (host setup). Record the exact commands used; Task 7 writes them into the README.

**Interfaces:**
- Produces: LXC `fluxer` (next free CTID) reachable on the LAN as `fluxer.lan` (DNS entry in the NAS's AdGuard, same pattern as `docker.lan`), user `ubuntu` with sudo, Docker running, `rexctl` at the VM's version, fluxer-ops cloned to `~/Documents/fluxer/ops` on `main`.

- [ ] **Step 1: Create the LXC** with `pct create` from the Debian 12 template on storage `tank`, values from Global Constraints, network on the LAN bridge with DHCP. Verify: `pct config <id>` shows the cores, memory, `nesting=1,keyctl=1`, `onboot: 1`, rootfs on `tank`.
- [ ] **Step 2: Install Docker** (Debian's official Docker repository, same method as the `docker` LXC). Verify: `docker run --rm hello-world` succeeds and `docker info -f '{{.CgroupVersion}}'` prints `2`.
- [ ] **Step 3: Install rexctl and clone fluxer-ops**, then `ops/setup.sh --check`. Verify: `rexctl version` equals the VM's; `setup.sh --check` lists only "no instance yet".
- [ ] **Step 4: Add `fluxer.lan` in AdGuard.** Verify from the cloudflared LXC: `curl -sI http://fluxer.lan` gets a connection (refused is fine: nothing listens yet), not a DNS error.

### Task 3: Rehearsal restore on the NAS (private, then stopped)

**Interfaces:**
- Consumes: Task 2's LXC.
- Produces: a proven restore path, the backup file's size and the time each step took (for the cutover estimate), and the edge setting that makes Caddy serve plain HTTP.

- [ ] **Step 1: Announce a short pause to the operator**, then on the VM: `rexctl --dir ~/Documents/fluxer backup` (Fluxer pauses while uploads are copied) and `rexctl backup verify <file>`. Expect: `verify` passes; note the file's size and the pause duration.
- [ ] **Step 2: Transfer the file to the `fluxer` LXC** with Voltius `transfer_file`, or else `scp` over Tailscale with a temporary key removed afterwards. Verify: `sha256sum` equal on both sides.
- [ ] **Step 3: Restore, then stop delivery at once.** Run `rexctl restore <file> --confirm fluxer.kipavy.fr --dir ~/Documents/fluxer`. As soon as the containers exist, and within the first minute, run `docker stop fluxer-push-1 fluxer-worker-1`: these two send push notifications and emails, and the rehearsal must not reach users (Review Focus 1). Nothing public points at the LXC yet.
- [ ] **Step 4: Find and set the plain-HTTP edge.** Find the rexctl key behind `FLUXER_EDGE_SITE_ADDRESS` (`rexctl config list | grep -i -E 'site|edge'`) and set it to `http://fluxer.kipavy.fr` (Caddy then skips ACME and certificates). Verify from the LXC: `curl -s -H 'Host: fluxer.kipavy.fr' http://localhost/.well-known/fluxer` returns the instance's JSON, and edge logs show no ACME attempt.
- [ ] **Step 5: Check the data.**
  - `fluxer verify-backup` on the NAS: the row counts match the VM's.
  - The upload taken from the VM (Review Focus 4) answers 200 through `localhost`, with the same size.
  - The hash of each secret setting matches the VM's (Review Focus 2).
  - `docker logs` for push and worker show no deliveries.
- [ ] **Step 6: `rexctl stop` on the NAS.** Verify: `docker ps` shows no fluxer container running.

### Task 4: Tunnel route to the NAS edge, tested on a temporary hostname

**Interfaces:**
- Consumes: Task 3's plain-HTTP edge setting.
- Produces: in the tunnel's configuration (Cloudflare dashboard, through the operator's Chrome), the public hostname `fluxer-test.kipavy.fr` → `http://fluxer.lan:80` with HTTP Host header `fluxer.kipavy.fr`, removed at the end of this task.

- [ ] **Step 1: Ask the operator to confirm**, then add the public hostname. Start the NAS stack with push and worker stopped, as in Task 3.
- [ ] **Step 2: Verify.**
  - `curl -s https://fluxer-test.kipavy.fr/.well-known/fluxer` from the PC returns the JSON.
  - A WebSocket to the gateway path upgrades (101).
  - Caddy's access log shows the PC's public IP as the client (Review Focus 3); if it shows the cloudflared LXC, fix the trusted proxies before going further.
- [ ] **Step 3: Remove the temporary hostname, then `rexctl stop` on the NAS.** Verify: the hostname no longer resolves, and nothing of Fluxer runs on the NAS.

### Task 5: `voice.kipavy.fr` proven on the current LiveKit; VM ready for voice-only

**Interfaces:**
- Consumes: Task 1's kit.
- Produces: DNS `voice.kipavy.fr` (proxied) → the VM, answering through the current stack's edge until the cutover; `voice/.env` filled on the VM; `fluxer firewall-fix --apply` done on the VM.

- [ ] **Step 1: Add the DNS record** (operator confirms), and a drop-in `caddy.d/voice.caddy` on the VM: `voice.kipavy.fr { reverse_proxy livekit:7880 }`, applied with `rexctl start`. Verify: `curl -s https://voice.kipavy.fr` returns LiveKit's `OK`.
- [ ] **Step 2: Hold a two-client call against it.** Temporarily set the voice server endpoint to `wss://voice.kipavy.fr`. Verify: audio flows both ways (Review Focus 5). Then set it back to `wss://fluxer.kipavy.fr/livekit`.
- [ ] **Step 3: On the VM,** fill `voice/.env` from rexctl (`chmod 600`) and pull the images. Do not start anything. Run `fluxer firewall-fix --apply`. Verify: `docker compose ... config` renders, and `firewall-fix` reports applied.

### Task 6: Cutover (operator present)

**Interfaces:**
- Consumes: Tasks 2-5. Abort criteria: any verification failing before Step 6 → restart the VM stack (`rexctl start`), nothing public has changed.

- [ ] **Step 1: On the VM, stop the stack and disable cron.** Note the time, run `rexctl stop`, and comment out the watchdog, backup, disk and autoupdate cron lines (root and user crontabs). Keep the old lines in a comment.
- [ ] **Step 2: Final backup and transfer.** `rexctl backup` + `verify` on the VM, transfer, `sha256sum` check (Task 3 Steps 1-2).
- [ ] **Step 3: Restore on the NAS.** Wipe the rehearsal (`rexctl` on the same `--dir`, `restore` answers yes), restore, keep the plain-HTTP edge setting, set `FLUXER_LIVEKIT_URL` and `FLUXER_LIVEKIT_INTERNAL_URL` to `https://voice.kipavy.fr`. Start with push and worker running.
- [ ] **Step 4: Start voice on the VM.** Remove `caddy.d/voice.caddy`, then `docker compose --env-file voice/.env -f voice/compose.yml up -d`. Verify: `curl -s https://voice.kipavy.fr` returns `OK`.
- [ ] **Step 5: Check before going public.** On the NAS, `fluxer check` passes, and the `voice_servers` row's endpoint is `wss://voice.kipavy.fr` (if the API did not sync it from `FLUXER_LIVEKIT_URL`, update the row as the admin API does).
- [ ] **Step 6: Switch the domain.** Add the tunnel public hostname `fluxer.kipavy.fr` → `http://fluxer.lan:80`. Cloudflare replaces the A record pointing at the VM: the operator confirms that replacement.
- [ ] **Step 7: Verify with the operator.**
  - An existing session still logged in.
  - A DM: the API log shows `POST .../messages` under 300 ms.
  - A new image upload, and an old upload.
  - A two-client call.
  - The Ops panel, a Plutonium account, the Visionary badge, an invite link.
  - Go or no-go within the first hour. No-go: switch the record back, `rexctl start` on the VM, and stop the NAS stack.

### Task 7: Running on the NAS for good, and the procedure written down

**Files:**
- Modify: `README.md` (new section "Moving to another host", and "Voice on a separate host" next to it; *Known gaps* updated)

- [ ] **Step 1: Run `ops/setup.sh` on the NAS** to set up cron. Change the backup line to `KEEP_DAYS=3 .../backup.sh` (PBS keeps the history). Run `./overlay.sh apply`, which keeps healthchecks at 60 s and the panel. Verify: `setup.sh --check` exits 0, `crontab -l` shows `KEEP_DAYS=3`, and every service has a 60 s healthcheck.
- [ ] **Step 2: Watch the first nights.** The 21:00 PBS job lists the new CT, and the 03:00 `backup.sh` completes. Verify: `pvesh get /nodes/pve/tasks` shows the CT's vzdump task OK, and `backup.log` shows `complete`.
- [ ] **Step 3: Write the README sections** from the commands actually used in Tasks 2-6. Write them as a generic procedure (no IPs, no CTIDs), with this move as its first tested run. Update *Known gaps*: off-NAS backup still missing, and the uploads half of a restore now proven.
- [ ] **Step 4: Run the full test suite on the NAS, expect 0 FAIL. Commit** `docs: moving to another host, voice on a separate host`, open the PR for this branch and merge it on the operator's word.
- [ ] **Step 5: In 14 days, ask the operator** before deleting the VM's old instance data. LiveKit and `voice/` stay.
