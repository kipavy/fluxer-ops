# Moving the instance from the OCI VM to the home NAS

Date: 2026-11-08. Status: design approved in conversation, awaiting spec review.

## Goal

Run the instance on the home NAS instead of the 2-vCPU OCI A1 VM, with nothing lost
and nothing different for users or for the operator: same domain, same accounts,
messages, uploads, sessions, invites, Plutonium/Visionary, same `fluxer` CLI. Success:
after the switch, a DM sends at once, an upload works, a voice call connects, nobody
has to log in again, and the move itself is written down as a procedure that can be
replayed to the next host.

## Why

The VM freezes in bursts. On 2026-11-08 DMs took 15-38 s, load sat at 30-80 and CPU
pressure (`/proc/pressure/cpu`) around 92 %. `perf` put about 80 % of the CPU in TLB
invalidation; creating a process cost from 1.6 ms to 225 ms of kernel time depending
on the hour, with nothing changed on our side. A CPU-only benchmark took 2.5-3.2 s on
this VM against 0.74 s on another A1 VM. A reboot did not help; an OCI stop/start
(new physical host) helped for a few hours. Slowing the healthchecks (PR #12) cut the
load but not the latency. The cause is the host, which we cannot fix from the guest.

## Decisions taken

| Question | Decision |
| --- | --- |
| Where | A new dedicated Debian LXC `fluxer` on the Proxmox NAS, not the existing shared Docker LXC: own CPU/RAM/disk limits, own ZFS snapshots, one unit to back up or move, failures isolated both ways. |
| Size | 2 cores, 4 GiB RAM, ~60 GB root disk on the mirrored ZFS pool (`tank`), not on the single-disk `local-lvm`. Measured need: ~1.5-2 GiB RAM steady, near-idle CPU, 2.2 GB uploads + ~3-4 GB images, uploads growing ~70 MB/day. |
| Stack | Unchanged: rexctl + fluxer-ops, same release, same images (all published for linux/amd64 and linux/arm64, checked). Healthchecks stay at 60 s (PR #12). |
| Public access | The existing Cloudflare Tunnel (its own LXC). `fluxer.kipavy.fr` becomes a public hostname of that tunnel pointing straight at the `fluxer` LXC's edge, not through the NAS's reverse proxy. **No port is opened on the home router**, by the operator's rule. |
| Voice | LiveKit cannot go through a Cloudflare Tunnel (WebRTC media is UDP/TCP, not HTTP). It **stays on the OCI VM**, alone: the rest of the stack there is stopped. Fluxer on the NAS points at it. The VM already has 7881/tcp and 7882/udp open. |
| Identity | The rexctl settings (`.rexctl/state.json`) move with the data, secrets included, so sessions, signed URLs and the LiveKit key/secret stay valid. Nothing is regenerated. |
| Backups on the NAS | Covered without extra work by the Proxmox job (all guests, daily 21:00, to the NAS's PBS, snapshot mode) plus fluxer-ops' own nightly `backup.sh` inside the LXC, with local retention cut down since PBS keeps the history. Off-NAS copies are out of scope here. |
| Re-migration | This move uses the stock backup/restore path, and the steps go into the README as "Moving to another host", tested by this very move. |

## Architecture after the move

```
users ──https/wss──▶ Cloudflare ──tunnel──▶ cloudflared LXC ──http──▶ fluxer LXC
                                                                     edge (Caddy)
                                                                       ├ app-proxy, static-proxy, media-proxy
                                                                       ├ api, worker, gateway, messages, users, …
                                                                       └ postgres, valkey, nats, meilisearch, seaweedfs

voice:  users ──wss──▶ Cloudflare ──▶ voice.kipavy.fr ──▶ OCI VM: TLS proxy ──▶ livekit:7880 (signalling)
        users ──UDP 7882 / TCP 7881──────────────────────▶ OCI VM: livekit (media, direct)
        NAS api ──▶ https://voice.kipavy.fr (LiveKit's control API, same port, key-signed)
        livekit webhooks ──▶ https://fluxer.kipavy.fr (through the tunnel)
```

Settings involved on the NAS (rexctl config): `FLUXER_LIVEKIT_URL` and
`FLUXER_LIVEKIT_INTERNAL_URL` both `https://voice.kipavy.fr` (LiveKit serves its
control API on the signalling port, signed with the API key, so no Tailscale is
needed in the LXC), `LIVEKIT_API_KEY`/`LIVEKIT_API_SECRET` unchanged, and the
`voice_servers` row in `fluxer_kv` (today `wss://fluxer.kipavy.fr/livekit`), which
must name `wss://voice.kipavy.fr`. Behind the tunnel the edge serves plain HTTP for
the domain (`http://fluxer.kipavy.fr` as its site address): Cloudflare does TLS, and
Caddy could not get a certificate without an open port anyway. The edge's trusted
proxies keep `private_ranges` so the tunnel's `Cf-Connecting-IP` is honoured. On the
VM, `fluxer firewall-fix --apply` replaces the watchdog's chain repair, which no
longer runs there.

## The move

### Preparation (no downtime; the VM keeps serving)

1. Create the `fluxer` LXC (Debian, nesting for Docker), install Docker and rexctl,
   clone fluxer-ops.
2. Rehearse: a `rexctl backup` of the VM (one file: database, search data, uploads,
   settings; Fluxer pauses a few minutes while uploads are copied), restored on the
   LXC with no public route and stopped right after the checks. At 2.2 GB the file
   moves in minutes, so no pre-copy.
3. Prove the tunnel route on a temporary hostname, and `voice.kipavy.fr` on the
   current LiveKit through the VM's edge. Prepare, not start, a standalone LiveKit
   on the VM: same image, same key/secret, same config as the bundled one, plus a
   TLS proxy for `voice.kipavy.fr`.

### Cutover (downtime, estimated 30-60 min, mostly the slow VM)

1. On the VM: stop the stack (the data freezes) and disable its cron jobs
   (watchdog, backup, autoupdate, disk record).
2. Take a final clean backup (database dump, uploads tail, settings, configs, ops/)
   and transfer it to the NAS.
3. On the NAS: restore, start, `fluxer check`.
4. Start the standalone LiveKit on the VM; point the NAS instance at it (settings
   above and the voice server endpoint in the database).
5. Switch `fluxer.kipavy.fr` in Cloudflare to the tunnel.
6. Verify with the operator: existing session still logged in, a DM sends at once,
   an image upload, a voice call between two clients, the Ops panel, a Plutonium
   account and the Visionary badge, an invite link.

### Rollback

Until step 5 nothing public has changed: restart the stack on the VM. After step 5,
switching the record back and restarting the VM's stack works, but loses what was
posted on the NAS in between, so the go/no-go is decided within the first hour.
The VM's data stays untouched for two weeks after the move, then is deleted only
with the operator's agreement.

## Verification before the cutover

Each of these is checked during preparation; a "no" stops the move until resolved.

- A restore of the latest backup on the NAS LXC comes up and passes `fluxer check`
  (this also proves the uploads half of a restore, never run end to end before).
- `voice.kipavy.fr` carries a real two-client call (signalling and media) before
  the cutover, through the VM's current LiveKit.
- Whether the API syncs the `voice_servers` row from `FLUXER_LIVEKIT_URL` on start,
  or the row has to be updated as the admin API does.
- The tunnel serves a test hostname to the `fluxer` LXC's edge with the real client
  IP seen by Caddy.

## Out of scope

- An off-NAS copy of the backups (the NAS's PBS is on the same pool; it covers a bad
  update and a failed disk, not the loss of the whole NAS).
- Moving LiveKit itself off the VM.
- Any change to what users see.
