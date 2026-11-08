# Move to the home NAS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the whole instance, voice included, from a dedicated LXC on the home NAS behind the existing Cloudflare Tunnel, with nothing changed for users.

**Architecture:** The move rides on `rexctl backup` / `rexctl restore` (one file: database, search data, uploads, settings, restorable on a new machine). The NAS edge serves plain HTTP to the tunnel; Cloudflare does TLS. LiveKit stays the stack's bundled one: signalling through the tunnel, media through two ports the Livebox forwards to the LXC.

**Tech Stack:** Proxmox `pct`, Debian 12 LXC with Docker, rexctl, fluxer-ops (POSIX sh), Cloudflare Tunnel (remotely managed, its own LXC), Livebox port forwarding.

**Spec:** `docs/superpowers/specs/2026-11-08-move-to-home-nas-design.md`

## Global Constraints

- Public HTTP(S) to the NAS arrives only through the Cloudflare Tunnel. The only router ports opened are 7881/tcp and 7882/udp, forwarded to the `fluxer` LXC.
- Same domain `fluxer.kipavy.fr`, same release, same rexctl settings and secrets: nothing is regenerated, and no voice setting changes.
- LXC `fluxer`: 2 cores, 4096 MiB RAM, 200 GB root disk on storage `tank`, unprivileged, `nesting=1,keyctl=1`, `onboot=1`, static LAN IP, user `ubuntu` so paths match the VM.
- Healthchecks at 60 s (overlay.sh, PR #12) on the NAS too.
- This repo is public: no IP address, token, key or secret in any committed file, plan or commit message.
- Every change to Cloudflare, the router, Proxmox or the VM's live stack is announced to the operator before it is made; the cutover (Task 6) runs only with the operator present.
- The VM's data is kept untouched for 14 days after the cutover; deleting it needs the operator's agreement.

## Review Focus

- **The rehearsal instance acting on real users.** A restored copy on the NAS has the real database: its worker could send emails, push could notify phones, and LiveKit could hold rooms. Task 3 starts it with no public route and stops push and worker at once; its checks assert nothing was sent (`docker logs` of push and worker).
- **Sessions after the move.** A user already logged in must stay logged in. Task 3 compares each secret setting by hash with the VM's; Task 6 checks an existing browser session without logging in again.
- **Real client IPs behind the tunnel.** Rate limits and bans key off the client IP. Task 4 asserts Caddy's access log shows the test client's public IP, not the cloudflared LXC's.
- **Old and new uploads.** Task 3 and Task 6 fetch an upload from before the move (an attachment URL taken from the VM) and Task 6 uploads a new image: HTTP 200 and matching size.
- **Voice from outside and from the home LAN.** Signalling can work (tunnel) while media is blocked (forward missing, or no NAT loopback on the Livebox for LAN clients). Task 6 holds a real call with audio both ways from mobile data, and one from a device on the home LAN.

---

### Task 1: (dropped) the `voice/` kit

Written, then reverted the same day when voice moved to the NAS too (spec, Voice row). Nothing to do.

### Task 2: The `fluxer` LXC with Docker, rexctl and fluxer-ops

**Interfaces:**
- Produces: LXC `fluxer` (CT 107) on a static LAN IP, user `ubuntu` with sudo and the docker group, Docker running, `rexctl` at the VM's version in `~/.local/bin`, fluxer-ops cloned.

- [x] **Step 1: Create the LXC** with `pct create` from `debian-12-standard` on `tank`, values from Global Constraints. Verify: `pct config 107`.
- [x] **Step 2: Install Docker** from Docker's Debian repository; create `ubuntu` (uid 1000) with passwordless sudo and the docker group. Verify: `docker run --rm hello-world`, cgroup v2.
- [ ] **Step 3: Install rexctl at the VM's version** (`rexctl version` on the VM): the binary from that release's `rexctl_<version>_linux_amd64.tar.gz`, checked against the release's published SHA-256, into `~/.local/bin`. The installer script execs `rexctl` afterwards, which can wait on a terminal: run the download by hand rather than through it. Verify: `rexctl version` equals the VM's.

### Task 3: Rehearsal restore on the NAS (private, then stopped)

**Interfaces:**
- Consumes: Task 2's LXC.
- Produces: a proven restore path, the backup size and step timings, and the edge settings that make Caddy serve plain HTTP.

- [ ] **Step 1: Announce a short pause to the operator.** On the VM, run `rexctl --dir ~/Documents/fluxer backup` (Fluxer pauses while uploads are copied), then `rexctl backup verify <file>`. Expect `verify` to pass. Note the size and the pause.
- [ ] **Step 2: Transfer the file to the LXC** (Voltius `transfer_file`, or else `scp` over Tailscale with a temporary key removed afterwards). Verify: `sha256sum` equal on both sides.
- [ ] **Step 3: Restore, then stop delivery at once.** Run `rexctl restore <file> --confirm fluxer.kipavy.fr --dir ~/Documents/fluxer`. Within the first minute, run `docker stop fluxer-push-1 fluxer-worker-1`.
- [ ] **Step 4: Plain-HTTP edge.** Find the rexctl keys behind `FLUXER_EDGE_SITE_ADDRESS` and `FLUXER_EDGE_TLS_DIRECTIVE` (`rexctl config list | grep -i -E 'site|tls|edge'`), and set the site address to `http://fluxer.kipavy.fr`. Verify:
  - `curl -s -H 'Host: fluxer.kipavy.fr' http://localhost/.well-known/fluxer` returns the instance's JSON;
  - the edge logs show no ACME attempt.
- [ ] **Step 5: Check the data.**
  - `fluxer verify-backup`: the row counts match the VM's.
  - The upload taken from the VM answers 200 through `localhost`, with the same size.
  - The hash of each secret setting matches the VM's.
  - The push and worker logs show no deliveries.
- [ ] **Step 6: `rexctl stop` on the NAS.** Verify: no fluxer container running.

### Task 4: Tunnel route to the NAS edge, tested on a temporary hostname

- [ ] **Step 1: Operator confirms, then add the route.** In the tunnel's configuration (Cloudflare dashboard), add public hostname `fluxer-test.kipavy.fr` → `http://<LXC IP>:80` with HTTP Host header `fluxer.kipavy.fr`. Start the NAS stack with push and worker stopped, as in Task 3.
- [ ] **Step 2: Verify.**
  - `/.well-known/fluxer` answers through `fluxer-test.kipavy.fr`.
  - The gateway WebSocket upgrades (101).
  - Caddy's access log shows the PC's public IP as the client.
- [ ] **Step 3: Clean up.** Remove the temporary hostname, then run `rexctl stop` on the NAS.

### Task 5: Livebox forwards for LiveKit media

- [ ] **Step 1: Operator confirms; forward 7881/tcp and 7882/udp** from the Livebox to the LXC's IP (the operator logs in to the Livebox; changes are saved only after they confirm). Verify: both rules listed in the Livebox's NAT/PAT page. Nothing listens yet; the media test is in Task 6.

### Task 6: Cutover (operator present)

Abort before Step 4 → `rexctl start` on the VM; nothing public has changed.

- [ ] **Step 1: On the VM,** note the time, `rexctl stop`, and comment out the watchdog, backup, disk and autoupdate cron lines (root and user), keeping them in comments.
- [ ] **Step 2: Final backup and transfer:** Task 3 Steps 1-2.
- [ ] **Step 3: On the NAS,** restore over the rehearsal (same `--dir`), keep the plain-HTTP edge setting, start everything (push and worker included). Verify: `fluxer check` passes, and every service is healthy.
- [ ] **Step 3b: Carry fluxer-ops' local state**, which is in neither git nor the rexctl backup.
  - From the VM's `ops/`: `notify.conf` (alert channels, the changelog webhook and the OpenRouter key of the nightly Haiku summary) and `panel/` (enabled flag, `route.caddy`, `www/`).
  - `~/.local/state/fluxer-autoupdate/`.
  - Then run `fluxer panel refresh` and `./overlay.sh apply` on the NAS.
  - Verify: `autoupdate.sh status` shows the channel and the summary configured, `notify.sh` lists the same channels, and the Ops panel answers.
- [ ] **Step 4: Switch the domain.** Tunnel public hostname `fluxer.kipavy.fr` → `http://<LXC IP>:80`; Cloudflare replaces the A record pointing at the VM (the operator confirms that replacement).
- [ ] **Step 5: Verify with the operator.**
  - An existing session still logged in.
  - A DM, with `POST .../messages` under 300 ms in the API log.
  - A new upload, and an old one.
  - A two-client call from mobile data, and one from the home LAN, with audio both ways.
  - The Ops panel, a Plutonium account, the Visionary badge, an invite link.
  - Go or no-go within the first hour. No-go: switch the record back, `rexctl start` on the VM, and stop the NAS stack.

### Task 7: Running on the NAS for good, and the procedure written down

**Files:**
- Modify: `README.md` (new section "Moving to another host"; *Known gaps* and *Notes on this instance* updated: tunnel, home IP, Livebox forwards)

- [ ] **Step 1: Run `ops/setup.sh` on the NAS** to set up cron. Change the backup line to `KEEP_DAYS=3 .../backup.sh`, then run `./overlay.sh apply`. Verify:
  - `setup.sh --check` exits 0;
  - `crontab -l` shows `KEEP_DAYS=3`;
  - every service has a 60 s healthcheck.
- [ ] **Step 2: Remove what only served the old voice plan.** Delete the DNS record `voice.kipavy.fr`, and on the VM delete `caddy.d/sites/voice.caddy` and `ops/voice/.env`. Verify: the record is gone and `.env` no longer exists.
- [ ] **Step 3: Watch the first nights.** The 21:00 PBS job includes CT 107 with status OK, and the 03:00 `backup.sh` logs `complete`.
- [ ] **Step 4: Write the README sections** from the commands actually used. Make them a generic procedure: no IPs, no CTIDs.
- [ ] **Step 5: Run the full suite on the NAS (0 FAIL). Commit**, open the PR, and merge it on the operator's word.
- [ ] **Step 6: In 14 days, ask the operator** before deleting the VM's old instance data.
