# STAFF Ops panel: the `fluxer` CLI from inside the web app

Date: 2026-10-08. Status: design approved in conversation, awaiting spec review.

## Goal

Run the everyday account commands of this CLI (gift links, premium, users) and the
read-only health commands from the web app's STAFF menu, without opening a shell on
the host. Success: a STAFF account opens the menu, mints a one-week gift, copies the
redeemable link, and never touches SSH.

## Decisions taken

| Question | Decision |
| --- | --- |
| Scope | Accounts + read-only health. Nothing that can stop or reconfigure the stack. |
| UI | One "Ops…" item added to the STAFF (Developer tools) header menu, opening an overlay panel of our own. No patching of the minified menu code. |
| Who | Any account with the STAFF flag. Consequence, accepted: `users staff` is in scope, so a STAFF account can grant panel access to another one. Every such write is audited and alerted. |
| Backend | Approach A: a host-side bridge that runs the existing scripts. Rejected: a container with the Docker socket (same privilege, more moving parts) and re-implementing the SQL (a second copy of `gifts.sh`/`premium.sh` to drift). |
| Clients | Web app only. The desktop app renders from the signed `fluxer_renderer` module or a bundled renderer and never loads this instance's `index.html` (checked in `fluxer_desktop/src/main/LocalAppProtocol.ts`, `Bootstrap.ts`, and on a live Canary install). Mobile ships its own client too. |
| Custom sounds pushed per account | Dropped: same desktop limit, and upstream keeps custom sounds in local IndexedDB only. Recorded in the README's *Known gaps*. |

## Architecture

```
browser (web app)
  └─ /ops-panel.js   classic <script> placed in index.html BEFORE the bundle
       adds "Ops…" to the STAFF menu → overlay panel (Gifts / Premium / Users / Health)
       fetch('/ops-api/run', {Authorization: <session token>})
            │
edge (Caddy)  handle_path /ops-api/* → reverse_proxy unix//run/fluxer-ops/bridge.sock
              handle /ops-panel.js  → file_server (ops/panel/www, mounted read-only)
            │      (/run/fluxer-ops in edge is ops/panel/run on the host)
ops_bridge.py  (systemd unit, runs as the instance user, Python 3 stdlib only)
  1. token → GET /api/v1/users/@me via the local edge → user id      else 401
  2. STAFF bit (flags & 1) read from the database                     else 403
  3. action in the allowlist, every argument matched by its pattern   else 400
  4. run ops/<script>.sh with a fixed argv, no shell, stdin /dev/null, timeout
  5. answer {exit, stdout, stderr}; audit writes; notify.sh on writes
```

### Components

- **`ops_bridge.py`** (new, repository root like the other tools; underscore so the
  tests can import it). It holds the
  HTTP server on the Unix socket, auth, the allowlist, and the subprocess runner. The
  allowlist is a data table in the file: action name → script, argv template,
  argument patterns, timeout, read or write. The bridge holds no business logic. Every
  rule about gifts and premium stays in the scripts.
- **`ops-panel.js`** (new). It is plain JavaScript with no build step and no framework,
  and works through the DOM:
  - It captures the session token by wrapping `XMLHttpRequest.prototype.open` and
    `setRequestHeader`, and keeps the latest `Authorization` value the app sends to
    same-origin `/api/` URLs. Verified on the live app on 2026-10-08: the app sends
    its REST calls through XHR with an `Authorization` header (`/api/v1/...`). It
    deletes `window.localStorage` at start-up, so reading storage is not an option.
    The wrapper only works if it is installed before the bundle runs.
  - It watches for the STAFF menu: a `[role="menu"]` that contains an element whose
    `data-flx` starts with `channel.channel-header-components.developer-tools-context-menu.`.
    Those attributes ship in the production DOM, which was also checked live. It
    appends one "Ops…" item, cloning the class names of an existing item.
  - It renders the panel in a shadow root, so app CSS and ours never collide.
  - UI text is in English, like the CLI.
- **`panel.sh`** (new), dispatched as `fluxer panel on | off | status | refresh`. It
  installs and removes the systemd unit, the socket directory, the panel script and
  the Caddy route. `off` is the kill switch: it stops the bridge and removes the route
  and the script from `index.html`.
  - The socket directory is `ops/panel/run` on disk, mounted at `/run/fluxer-ops` in
    `edge`. It is not a host `/run` directory: after a reboot, docker starts `edge`
    before the bridge, and a missing bind source would be created root-owned.
  - `ops-panel.js` is served by `edge` itself (`file_server` on `ops/panel/www`), not
    by app-proxy. It needs no precompressed siblings, and it still loads when the
    bridge is down.
- **Shared override generator** (refactor): `overlay.sh`. Today
  `docker-compose.override.yml` is written whole by `badge-patch.sh`. `overlay.sh`
  becomes its only writer and assembles the sections of each feature that is on:
  - badge: patched chunks;
  - panel: the rewritten `index.html`, the Caddyfile, `www/` and the socket directory.

  Both features rewrite `index.html`, so the generator builds it in one pass:
  stock → badge repointing → panel `<script>`. Turning either feature off rebuilds
  from stock. The marker and "someone else's file is never touched" rules are kept.
- **Caddyfile**. It is upstream's file, so it is never edited in place. The generator
  mounts a copy, upstream's plus one `handle_path /ops-api/*` block placed before the
  catch-all `handle`, over `/etc/caddy/Caddyfile` in `edge`. `update.sh` already
  reverts the overrides before updating and re-applies them afterwards, and it does the
  same here. If upstream's Caddyfile changed, the copy is rebuilt from the new one.
- **`fluxer` dispatcher, completion, help, `selftest.sh`, README**: the new `panel`
  command, plus a README section. That section repeats the web-only limit and points
  the *Known gaps* entry at the panel as well as the badge.

## Actions

| Tab | Action | Runs | Writes |
| --- | --- | --- | --- |
| Gifts | `gifts.create` | `gifts.sh create --duration D --count N` | yes |
| | `gifts.list` | `gifts.sh list [--unredeemed\|--redeemed\|--revoked]` | no |
| | `gifts.show` | `gifts.sh show <code>` | no |
| | `gifts.revoke` | `gifts.sh revoke <code>` | yes |
| | `gifts.rm` | `gifts.sh rm <code>` | yes |
| | `gifts.redeem` | `gifts.sh redeem <code> <user>` | yes |
| | `gifts.setup-lifetime` | `gifts.sh setup-lifetime --community C` (only from the lifetime flow below) | yes |
| Premium | `premium.grant` | `premium.sh <user> [--duration D \| --subscriber]` | yes |
| | `premium.revoke` | `premium.sh <user> --off` | yes |
| | `premium.list` | `premium.sh --list` | no |
| Users | `users.list` | `users.sh list --recent N` | no |
| | `users.show` | `users.sh show <user>` | no |
| | `users.stats` | `users.sh stats` | no |
| | `users.staff` | `users.sh staff <user> [--off]` | yes |
| | `users.verify-email` | `users.sh verify-email <user>` | yes |
| Health | `status`, `disk` | `fluxer status --json`, `fluxer disk --json` | no |
| | `check`, `doctor`, `errors`, `backups` | `fluxer check`, `doctor --quiet`, `errors --since 1h`, `backups` | no |

Argument patterns:
- D: `^([1-9][0-9]{0,3}[dwmy]|lifetime)$`
- N: `1..50`
- code: `^[A-Za-z0-9]{32}$`
- user: `^[A-Za-z0-9][A-Za-z0-9._-]{0,31}(#[0-9]{1,4})?$`. The scripts take a
  username, or `username#tag` when several accounts share the name. The first
  character may not be `-`, so a "user" can never be read as a flag such as `--off`.
- recent: `1..200`
- Every pattern is matched against the whole string (`fullmatch`), so a trailing
  newline cannot slip past a `$`. Unknown argument keys are refused.
- C: `^[0-9]{1,20}$` (a community id only; names are not accepted from the panel)

Excluded: `setup-lifetime` with `--role` or outside the lifetime flow, `badge-patch`,
and anything under Stack, Updates, Backups (beyond listing) or Host.

**Prompts.** The bridge runs every script with stdin on `/dev/null`, so a prompt fails
fast instead of hanging. `gifts.sh` asks nothing today. The one case that needs a
choice is the first lifetime gift on an instance with several communities:
- `create --duration lifetime` then exits 1, with the line `this instance has several
  communities; say which one with --community:` followed by `  <name>  (<id>)` lines
  on stderr.
- The bridge recognises that answer and returns the parsed list as `choices`.
- The panel shows them, warns that this restarts the gateway once (as `setup-lifetime`
  does when it creates the Visionary role), and on confirmation calls
  `gifts.setup-lifetime --community <id>`. It then retries the create.

Phase 0 checked every allowlisted command for prompts: there are none.

**Timeouts.** 60 s, and 300 s for `check` and `doctor`. On timeout the process group
is killed and the answer says so.

## Panel behaviour

- One tab per row of the table, with forms for the arguments. Output appears in a
  monospace block, with the exit status shown.
- `gifts.create`: every `https://<domain>/gift/<code>` in the output becomes a row with
  a **Copy** button, plus **Copy all**.
- Confirmation step before `gifts.rm`, `gifts.revoke`, `premium.revoke` and
  `users.staff --off`.
- The item and panel only appear for an account whose client reports STAFF. This is
  cosmetic: the bridge enforces access on its own.

## Security

- **Token**: sent in the `Authorization` header and never in a cookie, so there is no
  CSRF. The bridge also rejects any request whose `Origin` is present and is not
  `https://<FLUXER_DOMAIN>`.
- **Identity**: `GET /api/v1/users/@me` through the edge on 127.0.0.1:443 with SNI =
  domain, not through Cloudflare. Checked on 2026-10-08: it answers 401 without a
  token, and the origin certificate verifies. A token → user result may be cached
  for 60 s, for read actions only.
- **Authorisation**: the STAFF bit is read from the database on every request.
  Revoking STAFF cuts access at once.
- **Rate limit**: 30 writes per minute per user, in memory.
- **Exposure**: no TCP port. The socket lives in `ops/panel/run/` with mode 0660, is
  owned by the instance user, and is mounted into `edge` only (`edge` runs as root).
- **No privilege**: the unit runs as the instance user with `NoNewPrivileges=yes`, so
  nothing the bridge starts can `sudo`. Checks that need sudo (the iptables chain in
  `status`, parts of `doctor`) report skipped or false from the panel. That is the
  intended trade.
- **Logging**: tokens are never logged. Every write logs user id, action, arguments
  and exit status to the journal, and goes to `notify.sh` under key `ops-panel`.
- **Kill switch**: `fluxer panel off`.

## Phase 0 (done 2026-10-08, on the live instance)

1. **Token**: captured from the app's own XHR `Authorization` header (see
   Components). The stored session is out of reach: `window.localStorage` is
   `undefined` once the app has started.
2. **Menu hook**: `data-flx` attributes are in the production DOM. The STAFF menu is
   a `[role="menu"]` whose items carry generic `ui.action-menu.context-menu.*` values,
   and it contains icons with
   `channel.channel-header-components.developer-tools-context-menu.*`.
3. **Socket**: `edge` runs as root (uid 0), so it can open a socket owned by the
   instance user. The directory mount survives bridge restarts because the directory
   is mounted, not the socket file.
4. **Identity**: the bridge needs only `id` and `username` from `/api/v1/users/@me`.
   STAFF comes from the database, the same way `users.sh` reads `flags`.
5. **Prompts**: no allowlisted command reads stdin. The only `read` in the
   dispatcher is in `restore`, which is excluded. `<user>` is a username or
   `username#tag` in all three scripts.

## Testing

- **Unit** (Python `unittest`, no Docker): allowlist lookup, every argument pattern
  with injection attempts (`;`, `$( )`, newlines, `--flag` smuggling), argv
  building, 400/401/403 paths with a stubbed identity and database.
- **Integration**: the real HTTP server on a real Unix socket, running stub scripts
  that echo their argv. This proves the transport, the argv and the exit codes. The
  scripts themselves are already exercised by their own use. Real
  `gifts create/rm` runs only in the end-to-end check.
- **`selftest.sh`**: the bridge parses and its unit tests pass. The new command is in
  help, dispatch and completion. The generated override and `index.html` contain both
  features when both are on, and only one when either is off.
- **`doctor`**: every file the override mounts exists. The bridge answers on its
  socket. The panel's Caddyfile, with its marked block removed, is byte-for-byte
  upstream's.
- **End to end**, in a real browser on the instance:
  1. STAFF account opens the menu.
  2. "Ops…" → Gifts → create 1 × `1w`.
  3. Open the copied link and check that it shows the gift.
  4. `rm` it.
  5. A non-STAFF account gets 403 from the bridge, checked with `curl` and its token.

## Out of scope

- Desktop and mobile apps (see Decisions).
- Stack, update, backup, restore and host commands.
- Pre-filling the panel from a user's context menu. Possible later, not needed now.
