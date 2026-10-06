# ChatServerConf — MongooseIM setup notes

Local dev environment for a MongooseIM XMPP server backed by an existing
MySQL container, authenticating against a custom HTTP backend
(`serverprojectx`, on `localhost:3000`). This file tracks what we've learned
configuring it so we don't have to re-derive it next time.

## Layout

- `docker-compose.yml` — runs `erlangsolutions/mongooseim:latest`.
- `conf/mongooseim.toml` — the live config, bind-mounted into the container.
- `db/mysql-schema.sql` — MongooseIM's official MySQL schema, loaded once
  into the `mongooseim` database (see below).
- `xmpp/` — a small Strophe.js WebSocket test client (`index.html`/`app.js`)
  that connects, logs every stanza in/out, and can request auth tokens.

## Docker image internals (erlangsolutions/mongooseim)

- Entrypoint is `/start.sh`. It expects a host directory mounted at
  `/member` (see the `volumes:` entry in `docker-compose.yml`:
  `./conf:/member`).
- On boot it symlinks whichever of `mongooseim.toml`, `app.config`,
  `vm.args`, `vm.dist.args` exist under `/member` into
  `/usr/lib/mongooseim/etc/`. We only supply `mongooseim.toml`; the rest use
  the image's defaults.
- Mnesia data lives in `/var/lib/mongooseim` — persisted via the
  `mongooseim_data` named volume.
- Module source is shipped in the image itself under
  `/usr/lib/mongooseim/lib/mongooseim-<version>/src/` — when TOML config
  syntax for a module isn't obvious from docs, `docker exec mongooseim cat
  .../src/mod_whatever.erl` and read its `config_spec/0` function directly;
  this has been more reliable than the docs site, which 404s a lot and gives
  inconsistent/summarized answers via WebFetch.
- `docker compose` (the plugin) is **not** registered on this machine — use
  the standalone `docker-compose` binary instead.

## MySQL backend

- Uses the existing `mysql-db` container (`mysql:8.0`, root password
  `qwerty`, already running for another project's `gameserver` DB) — did not
  spin up a separate MySQL container.
- Created a dedicated `mongooseim` database + `mongooseim` MySQL user
  (least-privilege, `ALL PRIVILEGES` scoped to that one DB only).
- Loaded the official schema from inside the image:
  `/usr/lib/mongooseim/lib/mongooseim-<version>/priv/mysql.sql` — copied out
  via `docker cp` into `db/mysql-schema.sql` and applied with
  `mysql -umongooseim -p... mongooseim < db/mysql-schema.sql`. Without this,
  MongooseIM boots but every RDBMS-backed call fails with
  `Table 'mongooseim.<x>' doesn't exist` (e.g. `mongoose_cluster_id`).
- `outgoing_pools.rdbms.default` connects via `driver = "mysql"`, `host =
  "host.docker.internal"`, `port = 3306` — the MongooseIM container reaches
  the *host's* published port rather than joining mysql-db's docker network,
  since mysql-db runs on the default bridge network (no service-name DNS
  resolution there anyway).

## HTTP auth backend (`auth.http`)

- `[outgoing_pools.http.auth]` → `host = "http://host.docker.internal:3000"`,
  `path_prefix = "/mongooseim/"` — same host-bridging pattern as MySQL,
  since `serverprojectx` publishes port 3000 on the host.
- Contract your HTTP backend must implement under that prefix:
  `check_password`, `user_exists`, `get_password`, `register`,
  `set_password`, `remove_user` (GET with query string / POST with
  url-encoded body: `user`, `server`, `pass`). **Every response must include
  a `Content-Length` header** or MongooseIM treats the auth call as failed.
- **Gotcha (cost real debugging time):** MongooseIM defaults
  `[auth.password] format` to `"scram"`. With SCRAM enabled, PLAIN-mechanism
  password checks never call your `check_password` endpoint at all — they
  call `get_password` and try to deserialize the response as SCRAM data,
  which fails (`scram_serialisation_corrupted` in logs) against any backend
  that returns a plain password/token. Since this backend only implements
  plaintext `check_password`, we set:
  ```toml
  [auth.password]
    format = "plain"
  ```
  This is the single most important setting for this auth backend to work
  at all — if login fails with `<not-authorized/>` despite `check_password`
  curling fine and returning `true`, check this first.
- The `server` param sent to your HTTP backend is the XMPP domain
  (`general.hosts`), taken from the JID's domain part — not the WebSocket
  host/port. Changing `hosts` (see below) changes what your backend
  receives as `server`, and the backend needs to know about any new domain.
- SASL mechanism: MongooseIM advertises SCRAM-SHA-* and PLAIN by default;
  Strophe.js picks the strongest (SCRAM) unless told otherwise. Since this
  backend only supports plaintext, the `xmpp/` test client restricts SASL
  explicitly: `new Strophe.Connection(service, { mechanisms:
  [Strophe.SASLPlain] })`.

## Domain / `general.hosts`

- `general.hosts` is the list of served XMPP domains (what JIDs are
  `@`-suffixed with); `general.default_server_domain` is the fallback for
  host-less stanzas and should track it.
- Currently `hosts = ["jewelchat.net"]` (switched from `localhost`). When
  changing the domain, grep the whole `mongooseim.toml` for the old value —
  most listener/module settings use `"_"` wildcards or the `@HOST@` macro
  (e.g. `mod_vcard.host = "vjud.@HOST@"`) and don't need touching, but
  anything hardcoded does. Also remember your HTTP auth backend needs to
  accept the new `server` value (see above) — it's easy to switch the
  MongooseIM side and forget the backend still filters on the old domain.
- `host-unknown` stream error = the JID's domain doesn't match anything in
  `hosts`. Almost always means either the JID typed into a client has the
  wrong/no domain, or `hosts` doesn't (yet) include the domain you're
  testing against.

## mod_auth_token / mod_keystore (token-based auth)

- `mod_auth_token` signs tokens using a key served by `mod_keystore`; the
  key name is hardcoded in `mod_auth_token.erl` (`key_name/1`) to
  `token_secret` for both access and refresh tokens — `mod_keystore` must
  define a key with exactly that name or `mod_auth_token` can't start.
- `validity_period` is a section, not a scalar — `{value = <int>, unit =
  "minutes"|"hours"|"days"|"seconds"}` per token type:
  ```toml
  [modules.mod_keystore]
    ram_key_size = 32
    keys = [
      {name = "token_secret", type = "ram"}
    ]

  [modules.mod_auth_token]
    validity_period.access = {value = 5, unit = "minutes"}
    validity_period.refresh = {value = 5, unit = "minutes"}
  ```
- Key `type = "ram"` regenerates on every restart, invalidating all
  previously issued tokens — fine for dev, use `type = "file"` (with
  `path = ...`) if tokens need to survive restarts.
- `mod_auth_token`'s default `backend` is `"rdbms"`, which just works here
  since `db/mysql-schema.sql` already includes the `auth_token` table.
- Confirms it loaded successfully: the server starts advertising an
  `X-OAUTH` SASL mechanism in `<stream:features>` that isn't there without
  this module.
- Token request stanza (sent to your own bare JID once authenticated):
  ```xml
  <iq type='get' to='<user>@<domain>'>
    <query xmlns='erlang-solutions.com:xmpp:token-auth:0'/>
  </iq>
  ```

## mod_mam / mod_muc_light

- `mod_mam` is one module covering both 1:1 and group-chat archiving, split
  into two independently-optional subsections — neither is enabled unless
  its subsection is present:
  ```toml
  [modules.mod_mam]
    backend = "rdbms"
    full_text_search = false

    [modules.mod_mam.pm]

    [modules.mod_mam.muc]
      host = "muclight.@HOST@"
  ```
- `full_text_search` defaults to `true`, but the loaded MySQL schema has no
  `FULLTEXT` index on `mam_message`/`mam_muc_message.search_body` — left it
  `false` to avoid MAM text-search queries erroring against a schema that
  can't support them. Plain archiving/retrieval is unaffected either way.
- **Gotcha:** `[modules.mod_mam.muc].host` defaults to *classic*
  `mod_muc`'s subdomain, not `mod_muc_light`'s. If you only enable
  `mod_muc_light` (as here) and leave MAM's `muc.host` on its default, MAM's
  archive-query IQ handler registers on a subdomain nothing actually serves
  — group-chat archive queries would resolve nowhere. Must explicitly set
  it to match `mod_muc_light`'s own `host` (`"muclight.@HOST@"` by default).
- `mod_muc_light` defaults to `backend = "mnesia"`; switched to `"rdbms"`
  to match everything else in this project — the `muc_light_rooms` /
  `muc_light_config` / `muc_light_occupants` / `muc_light_blocking` tables
  were already in `db/mysql-schema.sql`.
- Verifying modules loaded without a real login: `mongooseimctl muc_light
  createRoom --mucDomain muclight.<domain> --owner <bare-jid> ...` and
  `mongooseimctl stanza --help` (lists `getLastMessages`, MAM's admin
  surface). If the subdomain/module wiring is wrong you'll get a
  domain/routing error; if it's right but the *user* doesn't check out
  against the HTTP auth backend, you'll get `"Given user does not exist"` /
  `user_not_found` instead — that's the auth backend's `user_exists`
  rejecting, not a MongooseIM config problem. Good way to isolate "is my
  MongooseIM config right" from "is my auth backend right" without needing
  a working end-to-end client login.

## mod_roster

- Small config surface: `backend` (`mnesia` default → set to `"rdbms"` here,
  matching `rosterusers`/`rostergroups`/`roster_version` already in
  `db/mysql-schema.sql`), `versioning` (XEP-0237, default `false`, left off
  — the `xmpp/` test console doesn't implement it), `store_current_id`
  (only matters if `versioning = true`), `iqdisc` (left default).
  ```toml
  [modules.mod_roster]
    backend = "rdbms"
  ```
- **Gotcha:** without this module enabled, `jabber:iq:roster` IQs have no
  handler — the "Add to Roster" button in `xmpp/index.html` was built
  *before* this module existed, so it had been silently sending into a void
  (`service-unavailable`-type failure) until this was configured. If a
  feature's IQ/stanza type has no corresponding `[modules.mod_*]` section,
  MongooseIM won't process it even if the client-side code is correct —
  worth checking early if a stanza "does nothing."
- Verified with a real login: `mongooseimctl`-adjacent check was a live
  roster-set IQ (via the Node+jsdom harness) → got back an empty
  `type="result"` (correct success shape for a roster set) → confirmed the
  row actually landed in MySQL: `SELECT username, jid, nick, subscription
  FROM rosterusers;`.

## Presence requires an initial `<presence/>` first (not a bug)

Symptom: two roster contacts with `subscription = 'both'` (confirmed
correct in MySQL) still don't receive each other's presence/status updates
— stanzas vanish with no error at `loglevel = "warning"`, but bumping
visibility shows repeated `what=unknown_statem_event ...
event_content_event_tag=mod_roster` warnings from
`mongoose_c2s:handle_foreign_event/4`.

Root cause (confirmed by reading `mod_presence.erl` from inside the running
container): `mod_presence` keeps per-session presence/subscription state
(`#presences_state{}`) that is only initialized once that session sends its
own **initial bare `<presence/>`** (RFC 6121 "becoming available"). Until
then, `get_mod_state/1` returns `not_found`, so `mod_presence`'s
`foreign_event/3` clause for `event_tag := mod_roster` — the handler that's
supposed to turn a roster subscription change into an actual presence
broadcast to the live session — silently no-ops (`{ok, Acc}`), which is
exactly what falls through to the generic "unknown event" warning in
`mongoose_c2s`. This is **not** a MongooseIM bug; it's standard behavior
that every real XMPP client (Conversations, Gajim, etc.) satisfies
automatically and our test console didn't.

Fix: `xmpp/app.js` now sends a bare `$pres()` immediately on
`Strophe.Status.CONNECTED`, before any other action is available — matches
what a real client does on login. Confirmed with two live sessions
(A.9/A.10, `subscription = 'both'`): with initial presence sent by both
sides, subscribe/subscribed presence, status updates, and roster-triggered
availability broadcasts all deliver correctly; without it, everything
related to presence silently vanishes even though the roster/DB state is
completely correct.

Useful admin command for this class of bug:
`mongooseimctl server hostTypes` — lists every module actually loaded per
host type with its resolved options. Good first check for "is my config
even being applied" before chasing behavior deeper.

## WebSocket idle timeout (60s default) closes quiet test sessions

Symptom: "the websocket is closing unexpectedly" — no client-side error to
explain it, and server logs (`loglevel = "warning"`) show nothing either,
since a normal idle-timeout close isn't a warning/error.

Root cause: `mongoose_websocket_handler`'s `timeout` option (Cowboy's
`idle_timeout`) defaults to **60000 ms**. Cowboy closes the socket if it
sees *zero frames* — not just XMPP stanzas, any frame — for that long. Very
easy to hit while manually testing: connect, spend a minute reading the log
or filling in a form, and the socket's already gone by the time you click
send. Confirmed by reading the option default straight from
`mongoose_websocket_handler.erl`'s `config_spec/0` in the running
container, then proved it live: a connection with zero traffic died before
75s under the old default, survived past 75s once fixed.

Fixed two ways (belt and suspenders):
- `conf/mongooseim.toml`, both `[[listen.http.handlers.mongoose_websocket_handler]]`
  blocks (ports 5280 and 5285): added `timeout = 600_000` (10 min).
- `xmpp/app.js`: sends an XEP-0199 ping IQ (`<iq type="get"><ping
  xmlns="urn:xmpp:ping"/></iq>`) to the server every 30s while connected
  (`startKeepAlive`/`stopKeepAlive`, tied to `Strophe.Status.CONNECTED` /
  disconnect-family statuses) — same thing a real client would do, and it
  shows up in the stanza log so you can see liveness directly.

## Testing without a browser

No Chrome/browser automation tool is available in this environment. The
approach that worked: drive the *actual* browser-targeted Strophe.js bundle
(`node_modules/strophe.js/dist/strophe.esm.js` — same code as the CDN
`strophe.umd.min.js` used in `xmpp/index.html`) inside plain Node, with
`jsdom` shimming `document`/`DOMParser`/`XMLSerializer` (Node 26+ has a
native `WebSocket` global already, which the bundle uses directly). This
gives a faithful end-to-end test — real WebSocket to the real MongooseIM
container, real SASL negotiation — without needing an actual browser:

```js
import { JSDOM } from 'jsdom';
const dom = new JSDOM('<!doctype html><html><body></body></html>');
globalThis.window = dom.window;
globalThis.document = dom.window.document;
globalThis.DOMParser = dom.window.DOMParser;
globalThis.XMLSerializer = dom.window.XMLSerializer;
await import('./node_modules/strophe.js/dist/strophe.esm.js');
// window.Strophe / $iq / $pres / $msg are now real globals
```

For testing UI logic in `app.js` itself (e.g. button enable/disable, exact
IQ built on click) independent of a real/working auth backend, stub
`Strophe.Connection.prototype.connect` and `.send` before `eval`-ing
`app.js`'s source in the same realm, to simulate a successful login and
capture what gets sent — see prior session scratch work for the pattern
(not checked into the repo; recreate as needed in
`/private/tmp/.../scratchpad/`).

## Strophe.js version pinned

`xmpp/index.html` loads `strophe.js@4.1.2` from jsDelivr
(`dist/strophe.umd.min.js`). That build sets `globalThis.Strophe`, `$build`,
`$iq`, `$msg`, `$pres`, `stx`, `toStanza` directly (despite the UMD
wrapper's factory arg looking like it'd nest everything under
`Strophe.Strophe` — it doesn't; the bundle overwrites `globalThis.Strophe`
with the real flat namespace at the end, restoring the classic 1.x-style
API). `Strophe.Connection` accepts a second `options` arg, notably
`{ mechanisms: [...] }` to restrict SASL mechanisms.

## mod_muc_light group chat

- Config actually applied:
  ```toml
  [modules.mod_muc_light]
    backend = "rdbms"
    allow_multiple_owners = true
  ```
  `allow_multiple_owners = true` because test accounts here are peers, not a
  fixed admin — any owner can promote another occupant to co-owner.
  `all_can_invite`/`all_can_configure` left at their `false` defaults
  (owner-only), `rooms_in_rosters` left at its `false` default (the
  in-app room dropdown, not the roster, is the source of truth for
  membership).
- **Gotcha:** the module docs page mentions a `promote_on_last_owner_leave`
  option. It does **not exist** in this MongooseIM version (6.6.0) — setting
  it crashes the boot with `toml_processing_failed reason=unexpected_key`.
  The error message usefully dumps the *actual* accepted key set for the
  section (`items_*` in the log line), which is the fastest way to check
  whether an option a doc page mentions is real for the version actually
  running. Don't trust the docs pages for the exact key set on a
  version-sensitive module without a fast way to double-check like this.
- Every room-management stanza is an IQ addressed to either the room's bare
  JID (`<room-id>@muclight.<domain>`) or the service JID (`muclight.<domain>`
  itself, for create-with-auto-ID, disco, and blocking). Confirmed live:
  - **Create** (`set` to `muclight.<domain>` with no room ID → server
    generates one, e.g. `1788-849373-282797@muclight.jewelchat.net`):
    `query` xmlns `urn:xmpp:muclight:0#create`, with
    `configuration/roomname` and an `occupants` list of
    `<user affiliation='member'>jid</user>`.
  - Every occupant (including the creator) gets a `<message type='groupchat'
    from='<room-jid>'>` with `<x xmlns='urn:xmpp:muclight:0#affiliations'>`
    listing affected users — **this, not the IQ result, is the only way to
    learn the room JID when it was auto-generated**. The IQ result itself is
    empty.
  - **Get config/affiliations**: `get` IQ, `query` xmlns `#configuration` /
    `#affiliations`, no `<version>` child → server always returns full
    state (version-diffing is opt-in, not required).
  - **Rename** (`set`, `#configuration`, `<roomname>`) also fires a
    `#configuration` notification `<x>` (`prev-version`/`version`/
    `roomname`) to occupants, separate from the affiliations one.
  - **Destroy** (`set`, `#destroy`, empty query) makes the server send a
    message with *two* `<x>` children: `#destroy` (empty) and
    `#affiliations` with every occupant's JID set to `affiliation='none'` —
    the affiliations one is what the app's live room-list sync keys off of;
    the destroy one is just informational.
  - **Blocking** (`muclight.<domain>`, `#blocking`, `<user
    action='deny'|'allow'>jid</user>` or `<room action=...>jid</room>`) works
    exactly as documented; `get` with empty query returns the current list.
- Client-side (`xmpp/app.js`) keeps its room dropdown in sync entirely by
  listening for `type='groupchat'` messages containing an `#affiliations` `x`
  child (registered once per connection via `connection.addHandler(...,
  null, 'message', 'groupchat', null, null)`, matched manually inside the
  handler rather than via Strophe's `ns` argument — simpler and avoids
  relying on exactly how Strophe's built-in namespace matching walks child
  elements). If our own bare JID shows up with `affiliation='none'` the room
  is removed from the dropdown; any other affiliation change adds/keeps it.
  This one mechanism covers create (learns the JID), invite, kick, promote,
  and destroy — no separate handling needed per action.
- The roster (`jabber:iq:roster` `get`) and MUC room list
  (`disco#items` to `muclight.<domain>`) are both fetched via
  `connection.sendIQ()` (not the fire-and-forget `connection.send()` used
  for most of the console's other actions) specifically because their
  *responses* are needed to populate dropdowns — `sendIQ` auto-injects an id
  and wires a result/error handler; plain `send()` never has and doesn't
  need one for this app's other one-shot stanzas.
- Verified this entire flow live end-to-end (create → get config → get
  affiliations → rename → group message → disco#items → block/unblock user →
  destroy → self affiliation-none notification) against the real running
  server with a Node+jsdom harness (see "Testing without a browser" above)
  using a single account. Cross-account flows (inviting a second real user,
  promote, and the 1:1 delivery/read receipts) need two working accounts to
  exercise for real — see the note below.

## 1:1 message delivery/read receipts

No server module needed — both are just plain `<message>` stanzas with an
extension child, routed like any other message:
- XEP-0184 delivery receipt: sender adds
  `<request xmlns='urn:xmpp:receipts'/>` alongside the `<body>`; recipient
  replies with `<message><received xmlns='urn:xmpp:receipts'
  id='<original-id>'/></message>`.
- XEP-0333 chat marker (used here for "read"): recipient sends
  `<message><displayed xmlns='urn:xmpp:chat-markers:0'
  id='<original-id>'/></message>`.
Outgoing chat messages in `xmpp/app.js` now always carry an id (tester-typed
via the new "Message ID" field, or `connection.getUniqueId('msg')` if left
blank) specifically so the other session has something to reference in its
"Ack message ID" field when sending these back.

## Test account credentials can silently expire/rotate on the auth backend

`test-credentials.md` describes `username`/`password` as "stable, reusable"
— that held until it didn't: as of 2026-09-08, `A.9`'s saved password
started failing `<not-authorized/>` on login, traced (via `curl
http://localhost:3000/mongooseim/check_password?user=A.9&server=jewelchat.net&pass=...`)
to the *auth backend itself* now returning `false` for that exact
user/password pair — `A.10`'s identical-shape credential still returned
`true`. MongooseIM/mod_muc_light config was not the problem here; this
`check_password` curl (already documented above under "HTTP auth backend")
is the fastest way to tell "my config broke" from "the backend's opinion of
this credential changed under me" before chasing the wrong layer.

## Production AWS infrastructure (`infra/`)

Terraform under `infra/` provisions a real production deployment of this
same stack — MongooseIM + the Node.js app ("ServerProjextX") each on their
own EC2 Auto Scaling Group, behind one AWS ALB, MySQL migrated to RDS.
Region `ap-south-2`, domain `jewelchat.net`. Code has been written and
`terraform validate`-checked; **nothing has been applied yet** — see
`infra/BOOTSTRAP.md` for the required one-time manual setup before any
`terraform apply` can run.

- **Two Terraform states, two IAM identities, deliberately separated**:
  `infra/iam/` (run under the `iam-admin` AWS CLI profile) owns IAM only —
  it creates the two EC2 runtime roles and can never touch EC2/RDS/ALB.
  `infra/app/` (run under `infra-provisioner`) owns all the actual
  infrastructure and can never create/modify IAM — it only gets
  `iam:PassRole`, scoped to exactly the two role ARNs `iam-admin` created.
  `infra/app/asg_*.tf` reference those roles via `data
  "aws_iam_instance_profile"` lookups, never `resource` blocks — this is
  what keeps the separation real rather than just stated.
  Every role `iam-admin` creates is forced (via an `iam:PermissionsBoundary`
  condition in `iam-admin`'s own policy) to carry a boundary policy
  (`AppRuntimeBoundary`) that only root can edit — without this, IAM-create
  permissions alone would let `iam-admin` mint itself a new, more powerful
  identity and route around the whole split.
- **Why this got complicated**: the first design used self-managed NGINX
  instead of an ALB. That meant no free target-group registration when an
  ASG replaces an instance, so NGINX would need Route53 self-registration +
  DNS-based upstream resolution just to not proxy to dead IPs, plus
  Certbot for TLS (ACM only attaches to ALB/CloudFront, not a bare EC2).
  Switched to ALB specifically to avoid building and operating that — ALB
  gets WebSocket support, target-group registration, TLS via ACM, and
  sticky sessions all for free. Worth remembering if NGINX ever comes back
  up as an option: that whole service-discovery problem is the real cost
  of choosing it over ALB.
- **MongooseIM starts at one instance but is built for Mnesia clustering
  from day one** (`infra/app/asg_mongooseim.tf`, user-data in
  `infra/app/userdata/mongooseim.sh.tpl`) — the user explicitly wants to
  add nodes as load grows without a later redesign. Mechanism: a shared
  Erlang cookie in Secrets Manager (`mongooseim/erlang-cookie`, generated
  once in `BOOTSTRAP.md`, never in Terraform state); each instance sets
  `-name mongooseim@<its own private IP>` and `-setcookie <fetched
  cookie>` in a templated `vm.args` at boot; peer discovery queries
  `autoscaling:DescribeAutoScalingGroups`/`ec2:DescribeInstances` for other
  `InService` members of `mongooseim-asg` and runs `mongooseimctl mnesia
  join_cluster` against one of them (empty peer list = seed node, nothing
  to join). This reuses read-only EC2/ASG describe permissions rather than
  reintroducing the Route53 self-registration machinery dropped along with
  NGINX. **Known sharp edge, not yet solved in code**: simultaneous joins
  race — when actually raising `desired_capacity` above 1, do it one
  instance at a time. RDS-backed data (roster/MAM/muc_light/auth_token) is
  already shared across nodes regardless of clustering; clustering only
  makes Mnesia's internal session/routing table consistent, which is what
  makes it safe for the ALB to send different clients to different nodes.
- **MongooseIM's `auth.http` → Node app call, in production**: points at
  the ALB's own DNS name with `path_prefix = "/mongooseim/"`
  (`mongooseim.sh.tpl`), not at `host.docker.internal` like dev. Traffic
  stays inside the VPC since the call never leaves AWS's network; this
  reuses the ALB as the one stable address instead of inventing a second
  internal discovery mechanism. `nodeapp-sg` has an explicit inbound rule
  from `mongooseim-sg` on port 3000 for this.
- **Node app tier deploys from ECR, not git+build-on-boot**
  (`infra/app/ecr.tf`, `userdata/nodeapp.sh.tpl`) — building from source at
  boot would need git credentials for the private ServerProjextX repo as
  yet another secret, and is slow/fragile to do on every instance launch.
  `nodeapp-runtime-role` gets pull-only ECR access to exactly the
  `serverprojectx` repo. **Pushing the image to ECR is a separate deploy
  step this Terraform doesn't do** — expected to happen from the other
  Claude Code session that owns ServerProjextX's own code.
- **Secrets layout**: `mongooseim/db-credentials`, `mongooseim/erlang-cookie`,
  `serverprojectx/db-credentials`, `serverprojectx/app-secrets` (the latter
  holds everything else `ServerProjextX/.env` needs — Firebase fields,
  legacy `topicname`/`memcached`/`gcmkey` — as one JSON blob the user-data
  script flattens into `.env` key-by-key, so adding a field later doesn't
  mean touching the script). The `mongooseim`/`serverprojectx` *app-level*
  DB users (as opposed to the RDS master user, which is AWS-managed via
  `manage_master_user_password`) get created manually during the RDS
  bootstrap step in `BOOTSTRAP.md`/plan, at the same time their credentials
  go into the two `*/db-credentials` secrets.
- **RDS**: one `db.t3.micro`, single-AZ, hosting both the `mongooseim` and
  `gameserver` databases — matches the current single `mysql-db` container
  exactly, not split into two instances. No public access; reached only via
  SSM Session Manager port-forwarding for the one-time schema bootstrap
  (loading this repo's own `db/mysql-schema.sql`), never a bastion host or
  an internet-facing endpoint.
- Full design rationale, the exact IAM policy JSON, and the verification
  checklist live in the plan file this was built from
  (`~/.claude/plans/recursive-meandering-newell.md` as of this writing) —
  worth reading before changing the IAM split or the clustering mechanism,
  since both went through several rounds of deliberate tradeoff discussion
  (NGINX vs ALB, one IAM identity vs two, single vs clustered MongooseIM).
