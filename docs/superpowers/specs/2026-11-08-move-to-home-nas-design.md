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
| Public access | The existing Cloudflare Tunnel (its own LXC). `fluxer.kipavy.fr` becomes a public hostname of that tunnel pointing straight at the `fluxer` LXC's edge, not through the NAS's reverse proxy. The only ports opened on the home router are LiveKit's media ports (next row). |
| Voice | LiveKit stays the stack's bundled one, on the NAS. Its signalling goes through the tunnel like the rest (`/livekit` on the domain, a WebSocket); WebRTC media cannot, so the Livebox forwards **7881/tcp and 7882/udp** to the `fluxer` LXC. Decided 2026-11-08 instead of keeping LiveKit on the VM: an Always Free VM left running only LiveKit risks OCI's idle reclamation, and the home IP is already public (`enshrouded.kipavy.fr`, DNS only). Accepted cost: call participants see the home IP. |
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

voice:  users ──wss──▶ Cloudflare ──tunnel──▶ edge /livekit ──▶ livekit:7880 (signalling, as today)
        users ──UDP 7882 / TCP 7881──▶ home IP ──Livebox forward──▶ fluxer LXC: livekit (media)
```

The voice settings do not change: `FLUXER_LIVEKIT_URL` stays
`https://fluxer.kipavy.fr/livekit`, the internal URL `http://livekit:7880`, the key
and secret and the `voice_servers` row (`wss://fluxer.kipavy.fr/livekit`) come over
as they are. LiveKit finds the home IP over STUN (`use_external_ip`), as it found
the VM's. Behind the tunnel the edge serves plain HTTP for the domain
(`http://fluxer.kipavy.fr` as its site address): Cloudflare does TLS, and Caddy
could not get a certificate without ports 80/443 open anyway. The edge's trusted
proxies keep `private_ranges` so the tunnel's `Cf-Connecting-IP` is honoured.

Devices on the home LAN reach LiveKit at the home's public IP, which needs the
Livebox to loop it back (NAT loopback); a call from the LAN is part of the checks.

## The move

### Preparation (no downtime; the VM keeps serving)

1. Create the `fluxer` LXC (Debian, nesting for Docker), install Docker and rexctl,
   clone fluxer-ops.
2. Rehearse: a `rexctl backup` of the VM (one file: database, search data, uploads,
   settings; Fluxer pauses a few minutes while uploads are copied), restored on the
   LXC with no public route and stopped right after the checks. At 2.2 GB the file
   moves in minutes, so no pre-copy.
3. Prove the tunnel route on a temporary hostname, and set the Livebox forwards
   (7881/tcp, 7882/udp → the `fluxer` LXC); nothing listens there until the cutover.

### Cutover (downtime, estimated 30-60 min, mostly the slow VM)

1. On the VM: stop the stack (the data freezes) and disable its cron jobs
   (watchdog, backup, autoupdate, disk record).
2. Take a final `rexctl backup` and transfer it to the NAS.
3. On the NAS: restore, start, `fluxer check`.
4. Switch `fluxer.kipavy.fr` in Cloudflare to the tunnel.
5. Verify with the operator: existing session still logged in, a DM sends at once,
   an image upload, a two-client voice call from outside (mobile data) and one from
   the home LAN, the Ops panel, a Plutonium account and the Visionary badge, an
   invite link.

### Rollback

Until step 4 nothing public has changed: restart the stack on the VM. After step 5,
switching the record back and restarting the VM's stack works, but loses what was
posted on the NAS in between, so the go/no-go is decided within the first hour.
The VM's data stays untouched for two weeks after the move, then is deleted only
with the operator's agreement.

## Verification before the cutover

Each of these is checked during preparation; a "no" stops the move until resolved.

- A restore of the latest backup on the NAS LXC comes up and passes `fluxer check`
  (this also proves the uploads half of a restore, never run end to end before).
- The Livebox forwards 7881/tcp and 7882/udp to the `fluxer` LXC.
- The tunnel serves a test hostname to the `fluxer` LXC's edge with the real client
  IP seen by Caddy.

## Out of scope

- An off-NAS copy of the backups (the NAS's PBS is on the same pool; it covers a bad
  update and a failed disk, not the loss of the whole NAS).
- Hiding the home IP from call participants (a TURN relay elsewhere).
- What becomes of the VM after the 14 days (it may be reclaimed by OCI as idle).
- Any change to what users see.
