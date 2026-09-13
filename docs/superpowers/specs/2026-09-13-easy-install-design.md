# Easy install: from a bare server to a running, operated Fluxer instance

Date: 2026-09-13
Status: approved design, pending implementation plan

## Goal

A newcomer with **a server and a domain** pastes one line and ends up, in a few
minutes, with a live Fluxer instance that is backed up, watched, and operable through
the `fluxer` command. Someone who already runs Fluxer pastes the same line and gets
fluxer-ops wired onto their existing instance, with nothing about it changed.

Success criteria:

- The README's install section is: "you need a server and a domain, then paste this".
- No script in the repo contains a hardcoded `/home/ubuntu` path.
- Every failure a newcomer can realistically hit before the stack is up (no Docker,
  DNS not pointing here, ports closed at the provider, not in the docker group,
  running as root) is caught or explained **before** the 3.5 GB pull, with the fix
  printed.
- Re-running the one-liner on a configured host changes nothing and says so.
- This host (`/home/ubuntu/Documents/fluxer`) keeps working with no config change.

Out of scope: macOS, Podman, `--tls proxy` layouts in the guided flow (the upstream
installer still supports them for anyone who runs it by hand), probing inbound ports
from outside the host (needs an external service), provisioning the server or the
DNS record itself.

## Entry point: `get.sh`

```sh
curl -fsSL https://raw.githubusercontent.com/kipavy/fluxer-ops/main/get.sh | sh
```

`get.sh` lives at the repo root, stays short (target under 60 lines) and readable, and
holds no logic that `setup.sh` also has. It:

1. Requires `git`; if missing, prints the package-manager command for the distro and
   exits 2. (Installing git unasked from a piped script is not acceptable.)
2. Finds an existing instance, in order: `$FLUXER_DIR` if set; `docker compose ls
   --format json` for a project whose config file path ends in `docker-compose.yml`
   and whose directory holds a `.env` with `FLUXER_DOMAIN=` (skipped silently if
   docker is absent or not permitted); `~/fluxer`; `/opt/fluxer`.
3. Found: target is `<dir>/ops`. Not found: asks for the directory to install into,
   default `~/fluxer` (the upstream installer's default), target `<dir>/ops`.
4. Target already a fluxer-ops clone: `git pull --ff-only`. Refuses (exit 3, clear
   message) if the target exists and is not one, or if the pull is not fast-forward.
   Otherwise `git clone`.
5. `exec sh <target>/setup.sh --fluxer-dir <dir>`, with stdin reattached to `/dev/tty`
   so prompts work under `curl | sh`. No tty (CI): passes through `--yes` only if
   `FLUXER_OPS_YES=1` is set, otherwise exits 2 explaining the non-piped form.

The README also documents the no-pipe form for those who read before running:
`git clone https://github.com/kipavy/fluxer-ops <dir>/ops && <dir>/ops/setup.sh`.

## Path resolution: `lib.sh`

One sourced file replaces the per-script `FLUXER_DIR=${FLUXER_DIR:-/home/ubuntu/...}`
and `BACKUP_ROOT=...` defaults in every script and in `completion.bash`.

`lib.sh` sets `OPS`, `FLUXER_DIR`, `BACKUP_ROOT`:

- `OPS`: the real directory of the calling script, symlinks resolved (`readlink -f`
  on Linux), so `~/.local/bin/fluxer -> .../ops/fluxer` resolves to `.../ops`.
- `FLUXER_DIR`, first match wins:
  1. the environment variable, if set;
  2. the parent of `OPS`, if it contains `docker-compose.yml`;
  3. a single fluxer project from `docker compose ls` (same rule as `get.sh`);
  4. otherwise it is left empty, and scripts that need an instance call
     `need_instance`, which exits 2 with: where it looked, and
     `FLUXER_DIR=/path fluxer ...` or `fluxer setup` as the fix.
- `BACKUP_ROOT`: the environment variable, else `$(dirname "$FLUXER_DIR")/fluxer-backups`
  (what this host uses today).

Scripts source it with `. "$(dirname "$(readlink -f "$0")")/lib.sh"`. `completion.bash`
resolves the same way from `BASH_SOURCE`. `lib.sh` is not executable and is not a
command; `selftest.sh` treats it as a library (parses it, does not require `+x`).

`offsite.conf.example` uses `$HOME/.config/fluxer-restic-password`.

## `setup.sh`

Replaces `install-host.sh`, which becomes a two-line wrapper
(`exec setup.sh --no-extras "$@"`) so existing habits and `fluxer doctor` keep
working. Dispatched as `fluxer setup`, completed, and listed in the help.

Flags: `--fluxer-dir <dir>`, `--check` (report, change nothing, exit 1 if anything
core is missing), `--yes` (accept defaults, skip every optional extra),
`--no-extras`, `--domain`, `--email` (passed to the upstream installer).

Every step prints a status line (`✓` done / already present, `→` doing, `✗` failed,
`–` skipped) and is idempotent: already-configured steps show `✓` and do nothing.

### Phase 1: prerequisites (before anything is downloaded)

1. **Root.** Running as root prints a warning that the upstream installer refuses
   root by default, and asks whether to continue; yes passes `--allow-root` through.
   `--yes` as root continues with the warning.
2. **Docker.** Missing: offers to install it with Docker's official convenience
   script (`https://get.docker.com`), after printing that URL and asking. Declined:
   prints `fluxer_docker_hint`-style instructions and exits 2. Present but the user
   is not in the `docker` group and not root: offers `sudo usermod -aG docker $USER`,
   then re-execs the rest of setup under `sg docker` so no re-login is needed.
3. **Compose plugin** ≥ 2.24.4 (the upstream overlay minimum), `curl`, `python3`,
   `sha256sum`: missing ones are listed with the install command for the detected
   package manager; exits 2. Not installed automatically.
4. **sudo.** Probed with `sudo -v` (prompts for a password, which is fine
   interactively). Unavailable: the root-only steps (watchdog cron, firewall-fix) are marked `–` with one line on what that costs, and setup
   continues.

### Phase 2: the instance

Existing instance (`FLUXER_DIR` has `docker-compose.yml` and `.env`): `✓ Fluxer found
at <dir> (https://<domain>)`, nothing touched, go to phase 3.

No instance: guided install.

1. **Domain and email**: `--domain`/`--email` or prompted, validated with the same
   rules as upstream (a hostname, an address).
2. **DNS check.** Public IPv4 of this host from `https://1.1.1.1/cdn-cgi/trace`
   (fallback `https://api.ipify.org`). Domain resolved with `getent ahostsv4`.
   - Resolves to this IP: `✓`.
   - Resolves into Cloudflare's published ranges: `✓ proxied through Cloudflare`,
     with a note that the SSL mode must be "Full (strict)" once the certificate is
     issued; cf-ips is then offered in phase 4.
   - Does not resolve, or resolves elsewhere: prints the exact record
     (`A  <domain>  <ip>`), then loops "Press Enter to re-check, or type skip".
     Skip continues with a warning that the certificate will not be issued until it
     is fixed. `--yes` with a wrong record exits 2.
3. **Ports on the host: not touched.** Docker publishes the stack's ports ahead of
   ufw and firewalld (its own nat and forward rules), so a host firewall is not what
   blocks a first install. Setup says so in one line instead of editing it.
4. **Ports at the cloud provider.** Detected from `/sys/class/dmi/id/sys_vendor` and
   `chassis_asset_tag` (Oracle Cloud, Amazon EC2, Google, Microsoft/Azure, Hetzner,
   DigitalOcean, Scaleway; unknown otherwise). Prints the four ports and where they
   are opened for that provider (e.g. Oracle: VCN security list), with its docs URL,
   then asks for confirmation that they are open. This cannot be verified from the
   host, and says so.
5. **Upstream installer.** Downloads `https://fluxer.dev/install.sh` and its
   `.sha256`, verifies with `sha256sum -c` (the same check `update.sh` does), refuses
   on mismatch (exit 4), saves it as `<dir>/install.sh`, and runs
   `sh install.sh --dir <dir> --domain <d> --email <e> --non-interactive
   [--allow-root]`. Its output streams through unchanged; its exit code is reported
   with the upstream meaning (2 prerequisite, 3 refused to overwrite, 4 download,
   6 stack did not come up, …) and, for 6, the DNS/ports reminder.

### Phase 3: core wiring (always)

What `install-host.sh` does today, unchanged in behaviour:

- `~/.local/bin/fluxer` symlink, bash completion link, PATH note if needed.
- User crontab: `backup.sh` 03:00, `disk.sh --record` 03:30.
- Root crontab: `watchdog.sh` every 10 minutes (via `sudo`, not `sudo -n`; skipped
  with a note if sudo is unavailable).
- Existing crontab lines are never rewritten or removed.

Cron lines now carry `FLUXER_DIR=<dir>` explicitly, so a non-default layout survives
cron's empty environment.

### Phase 4: optional extras (interactive only; skipped by `--yes` and `--no-extras`)

Each is one prompt, Enter skips, and each is only offered when it applies. Already
configured ones show `✓` and are not offered again.

- **Alerts** (always offered): asks which channel (ntfy / webhook / email), asks only
  that channel's values, writes `notify.conf` mode 600 from `notify.conf.example`,
  runs `notify.sh test`, shows the result.
- **Off-site backups** (always offered): asks for the R2 bucket endpoint and token
  pair, generates a `RESTIC_PASSWORD` if none is given and prints it once with the
  instruction to store it off the host, writes `offsite.conf` mode 600, runs
  `offsite.sh init`.
- **firewalld fix** (only if firewalld is active and sudo works): runs
  `firewall-fix.sh`, and `--apply` on yes.
- **Cloudflare ranges** (only if the domain resolves into Cloudflare): runs
  `cf-ips.sh`, and `--apply` on yes.

### Phase 5: finish

1. `fluxer check --quiet`; failures are printed, and setup still exits 0 if phase 2
   and 3 succeeded (the stack may still be warming up), with "run `fluxer check`
   in a minute".
2. `fluxer doctor --quiet`.
3. The closing block:

```
Your instance is live: https://<domain>

Next:
  1. Open it and create your account.
  2. fluxer users staff <your username>     make yourself an admin
  3. fluxer status                          any time; fluxer help for the rest
```

For an existing instance, step 1 and 2 are omitted.

## README

- Opens with **Quick start**: what you need (a server with a public IP, a domain),
  the one-liner, a five-line description of what it does, the no-pipe alternative.
- A short **Troubleshooting a first install** section: DNS, cloud firewall, docker
  group, each with the symptom and the fix, matching what setup prints.
- "Deployed at: /home/ubuntu/Documents/fluxer" and the hardcoded install-host path are
  removed. Details specific to this deployment (Oracle, firewalld outage history)
  stay, framed as "why these scripts exist" rather than as install instructions.

## Testing

- `selftest.sh` gains:
  - no tracked script contains `/home/ubuntu`;
  - every executable script that uses `FLUXER_DIR` sources `lib.sh`;
  - `lib.sh` resolution, in a scratch directory: env var wins; parent of `ops/`
    with `docker-compose.yml` is found; through a symlink to `fluxer` it is found;
    nothing found → `need_instance` exits 2;
  - `setup.sh` and `get.sh` parse, and `setup` is dispatched, in the help, and
    completed.
- `setup.sh --check` on this host reports everything `✓` and exits 0.
- `get.sh` in a throwaway `ubuntu:24.04` container with git and no docker: asks for a
  directory, clones, hands off to `setup.sh`, which stops at the Docker prerequisite
  with the install offer. Re-run: `git pull`, no second clone.
- Guided-install path up to the installer, in the same container with a stubbed
  `install.sh` that records its arguments: DNS mismatch prints the record and loops;
  the stub receives `--dir --domain --email --non-interactive`.
- A full real install on a fresh VPS with a real domain is not automated; it is the
  manual acceptance check before announcing the one-liner.
