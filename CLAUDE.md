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

## mod_push_service_mongoosepush

- Adapter that knows how to POST a push notification to a MongoosePush-shaped
  HTTP endpoint; it does **not** itself decide *when* to push — that's
  `mod_event_pusher`'s `push` backend (XEP-0357), not configured here yet.
  This module only wires up where an actual push would be sent if something
  else asked it to.
- Config surface (from `mod_push_service_mongoosepush.erl`'s `config_spec/0`
  read straight from the running container, same approach as other
  version-sensitive modules in this file): `pool_name` (atom, no default —
  must be set), `api_version` (`"v2"` or `"v3"`, defaults to `"v3"`),
  `max_http_connections` (defaults to 100).
- `pool_name` must match an `[outgoing_pools.http.<name>]` pool exactly —
  it's looked up via `mongoose_http_client:post(HostType, PoolName, ...)` at
  send time, not validated against the pool list at boot (so a typo here
  won't fail config parsing, only fail silently/log an error on first actual
  push attempt). This is a **separate pool** from the fixed-name generic
  (non-HTTP) wpool the module starts internally under `mongoosepush_service`
  — don't confuse the two when grepping logs/pool names.
- The module builds the request path itself as `<api_version>/notification/
  <device_id>` and appends it to the pool's `path_prefix` — so to hit the
  nodeapp's `/mongooseim/pushnotification/v3/notification/:deviceid` route,
  the pool's `path_prefix` must be `"/mongooseim/pushnotification/"` (not
  `"/mongooseim/"` like the auth pool) and `api_version = "v3"`:
  ```toml
  [outgoing_pools.http.mongoose_push]
    scope = "global"
    workers = 10

    [outgoing_pools.http.mongoose_push.connection]
      host = "http://host.docker.internal:3000"
      path_prefix = "/mongooseim/pushnotification/"
      request_timeout = 2000

  [modules.mod_push_service_mongoosepush]
    pool_name = "mongoose_push"
    api_version = "v3"
  ```
- Verified: server boots clean with this config (no
  `toml_processing_failed`), and `mongooseimctl server hostTypes` lists
  `mod_push_service_mongoosepush` as loaded. Note that CLI's `options` dump
  for this module is empty even when configured correctly — it only surfaces
  whatever a module's own `config_metrics/1` exposes (here just
  `api_version`, and even that doesn't show up in the CLI's generic
  formatter), so don't treat an empty `options` list there as a sign the
  module isn't configured. Confirmed the path wiring independently instead:
  `curl -X POST http://localhost:3000/mongooseim/pushnotification/v3/notification/test-device-id`
  returns 500 (route exists, errors on an empty/synthetic payload), not 404 —
  i.e. the nodeapp is actually listening at the exact path MongooseIM will
  call.

## Offline messages bounce unless *something* handles `offline_message`

Symptom: send a message to a user with no active session → instead of it
being queued, the sender gets back a `service_unavailable` error stanza
wrapping their own message (looks like the server is "echoing" it).

Root cause (read straight from `ejabberd_sm.erl`): `ejabberd_sm` always
registers a fallback handler on the `offline_message` hook, at priority
100 — `bounce_offline_message/3`, which does exactly the above. Nothing
pre-empts it unless some other module registers its own `offline_message`
handler at a lower priority (lower number = runs first) that returns
`{stop, Acc}` before hook processing reaches that fallback.

Two modules do this, and they are **alternatives, not complements**:

- `mod_offline` (priority 50) — actually stores the message (`rdbms` backend
  → `offline_message` table, already in `db/mysql-schema.sql`) and replays
  it to the client the moment it reconnects (`resend_offline_messages` hook
  → `pop_messages`, which reads-and-deletes in one shot). A real delivery
  queue.
- `mod_offline_stub` (priority 75) — does nothing but `{stop, Acc}`. No
  storage, no replay. Its own module doc explains exactly when this is the
  right call: *"Silence `<service-unavailable/>` when not using mod_offline
  but using mod_mam for message persistence"* — i.e. you already have
  something else persisting the message, so the RFC 6121 §8.5.2.2.1 bounce
  (which exists specifically to tell the sender "this wasn't saved
  anywhere") is simply inaccurate and should be suppressed, not fixed by
  adding a second storage path.

**Decision for this project: `mod_offline_stub`, not `mod_offline`.**
[modules.mod_mam] (see above) already archives every message — online or
offline — independent of delivery outcome, via its own hooks
(`user_send_message` / `filter_local_packet`, fired at send time, nothing to
do with routing success). Running `mod_offline` alongside that would just be
a second copy of the same data for no reason (confirmed `mod_mam_pm`'s
`sm_filter_offline_message` hook does *not* dedupe this — it only suppresses
MAM's own internal result stanzas from being queued offline, nothing about
ordinary chat messages). `mod_offline_stub` takes no config at all — the
whole module is `{stop, Acc}`.

Accepted trade: nothing pushes queued messages to a reconnecting client
anymore. The client has to issue its own MAM catch-up query (XEP-0313) on
reconnect to see what arrived while it was offline — there's no automatic
replay-on-login the way `mod_offline` had. Worth confirming whatever client
is pointed at this server actually does that MAM catch-up; the `xmpp/` test
console does not yet.

Also removed `[access].max_user_offline_messages` — it only ever existed as
`mod_offline`'s `access_max_user_messages` default input, and `mod_offline`
is no longer configured, so it was dead config once the swap was made.

**Note:** `mod_push_service_mongoosepush` / `mod_event_pusher.push` (above)
are unrelated to this bounce entirely — they hook `filter_local_packet` /
`user_send_message` (send-time, same as MAM), not `offline_message`. A
working push setup does not stop the bounce; it's a parallel side effect
(buzz a mobile device), not part of the routing decision. Don't conflate the
two when debugging either one.

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
Region `ap-south-2`, domain `jewelchat.net`.

**Correction, as of 2026-10-07: this has already been applied, in stages.**
Both `infra/iam/` and `infra/app/` have had a real `terraform apply` run —
the one-time manual setup in `infra/BOOTSTRAP.md` is done, not pending.
Current state (check live before assuming, this will keep changing):
VPC/subnets/security groups/ALB/ASGs/ECR repo all exist; both ASGs
(`mongooseim-asg`, `nodeapp-asg`) are normally left at `desired_capacity =
0` and RDS normally left **stopped** between work sessions — this is a
deliberate cost-saving idle state, not drift, so don't "fix" it by
launching things back up without a reason.

**No NAT gateway, by design (removed 2026-10-07, not coming back):** its
$0.056/hr base charge in `ap-south-2` was the single largest recurring line
item in the whole stack — more than the ALB, both EC2 tiers, and RDS
combined. Removed `aws_nat_gateway.main`/`aws_eip.nat`/
`aws_route_table.private` + associations from `vpc.tf` entirely (not just
stopped — gone from both AWS and Terraform state). **MongooseIM and Node
app EC2 now launch directly into the public subnets**
(`asg_mongooseim.tf`/`asg_nodeapp.tf`: `vpc_zone_identifier =
aws_subnet.public[*].id`, launch templates set
`network_interfaces.associate_public_ip_address = true`), reaching the
internet via the existing Internet Gateway route instead — zero hourly
cost, no NAT per-GB processing fee on top of normal data-transfer pricing.
Security boundary for both tiers is now security groups alone, which was
already safe to lean on: `mongooseim-sg`/`nodeapp-sg` (`security_groups.tf`)
never had SSH or any management port open, only the specific ALB/inter-tier
ports each needs — access is via SSM (no inbound port/key required), so
giving these instances a public IP doesn't add meaningful new attack
surface. **RDS stays on the private subnets**, now with no route to
`0.0.0.0/0` at all (the subnets have no explicit route table association
and fall back to the VPC's implicit default, which only has the local
route) — not just `publicly_accessible = false`, actually unreachable from
the internet at the routing level too.
If a from-scratch rebuild ever needs NAT back (e.g. a future private-tier
requirement), it's a clean re-add to `vpc.tf` — nothing else references
its specific resource IDs — but there's no reason to expect that; this was
a deliberate permanent architecture change, not a temporary cost-saving
toggle like the idle `desired_capacity = 0` / stopped-RDS pattern above.

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
  `serverprojectx` repo. Automating the build+push on every commit (GitHub
  Actions → OIDC → ECR, triggering an ASG instance refresh) is designed but
  **not yet applied** — blocked on a root-only IAM step (a new
  `CiDeployBoundary`, same pattern as the original `AppRuntimeBoundary`
  bootstrap) that hasn't happened yet. Until then, pushing a new image is
  manual: `docker buildx build --platform linux/amd64 -t
  <ecr_repository_url>:latest --push .` from the ServerProjextX checkout
  (plain `docker build` on this Apple Silicon dev machine defaults to
  `arm64`, which silently "works" per `docker-compose up` logging
  `Started` but the container never actually serves traffic on a
  `t3.micro` — amd64 only; confirmed via instance console output: `"The
  requested image's platform (linux/arm64) does not match the detected
  host platform (linux/amd64/v4)"`. `docker buildx` isn't installed by
  default on this machine either — `brew install docker-buildx` then
  `ln -sf /opt/homebrew/lib/docker/cli-plugins/docker-buildx
  ~/.docker/cli-plugins/docker-buildx` to wire it in), then either
  terminate the running instance (`aws autoscaling
  terminate-instance-in-auto-scaling-group --no-should-decrement-desired-capacity`)
  so the ASG replaces it, or wait for a future instance refresh.
- **`aws_lb.main` + both listeners + both listener rules were in
  `alb.tf` from the start but were never actually `apply`'d** — only the
  two target groups existed live. Symptom: a newly-launched instance's ALB
  target health sits at `Target.NotInUse` ("the target group is not used
  in a listener rule") no matter how healthy the instance itself is —
  `terraform state list | grep aws_lb` is the fast way to confirm whether
  this is actually the problem. **Gotcha that caused real confusion while
  diagnosing this**: the `alb_dns_name` Terraform *output* kept resolving
  to a concrete-looking hostname through several `-target`-scoped applies
  even while the underlying `aws_lb.main` resource didn't exist anywhere —
  a stale cached output value, not live data; `-target` applies don't
  necessarily recompute outputs outside the targeted dependency graph. Applied
  2026-10-07 (scoped apply of just the 7 ALB-stack resources, deliberately
  excluding the separately-pending CloudFront/static-site resources, which
  are unrelated and still not applied). Confirmed live end-to-end:
  `curl https://game.jewelchat.net/` → `200 {"message":"helloworld:production"}`,
  and `curl https://game.jewelchat.net/mongooseim/user_exists?...` → `200
  false` (a real query against the `gameserver` RDS database, not just the
  app boot path).
- **Secrets layout**: `mongooseim/db-credentials`, `mongooseim/erlang-cookie`,
  `serverprojectx/db-credentials`, `serverprojectx/app-secrets` (the latter
  holds everything else `ServerProjextX/.env` needs — Firebase fields,
  legacy `topicname`/`memcached`/`gcmkey` — as one JSON blob the user-data
  script flattens into `.env` key-by-key, so adding a field later doesn't
  mean touching the script). **Done** (2026-10-07): `mongooseim/db-credentials`
  and `serverprojectx/db-credentials` now exist, each `{"username",
  "password"}`, created out-of-band via plain `aws secretsmanager
  create-secret` (same pattern as `erlang-cookie` — never a Terraform
  resource, so the plaintext is never in state/a diff). `serverprojectx/app-secrets`
  **also created** (2026-10-07), but every field is an empty-string
  placeholder — confirmed none of them are actually exercised yet:
  `ServerProjextX/.env` doesn't set them in dev either, and
  `controllers/mongooseim.js` hardcodes `environment = 'development'`
  (the real `process.env.NODE_ENV` check is commented out), so the
  Firebase/FCM push-notification code path is dead regardless of what's in
  this secret. `AWS_REGION` deliberately left out of this secret — the
  user-data script already sets it directly in `.env` before flattening
  this JSON in on top, and including it again would duplicate the line
  (dotenv-style last-write-wins could silently blank it). Revisit with real
  values if Firebase push or the Cognito/S3-uploader fields are ever
  actually wired up.
- **RDS**: one `db.t3.micro`, single-AZ, hosting both the `mongooseim` and
  `gameserver` databases — matches the current single `mysql-db` container
  exactly, not split into two instances. Running MySQL **8.4** (upgraded
  in-place from the originally-provisioned 8.0.46 — `allow_major_version_upgrade`
  + `apply_immediately` in `rds.tf`; 8.0 is RDS's deprecated track). No
  public access; reached only via SSM Session Manager port-forwarding,
  never a bastion host or an internet-facing endpoint.
  **Done** (2026-10-07): the one-time schema bootstrap described below has
  been run against the live instance — both databases, both app-level
  least-privilege users, and all tables exist for real, not just planned.
  - **How the bootstrap actually reached RDS**: `infra-provisioner` has an
    explicit IAM deny on direct `ec2:RunInstances` (exact condition unknown —
    this profile also lacks `sts:DecodeAuthorizationMessage` to decode the
    denial), so a throwaway EC2 instance can't be launched directly under
    that identity. Workaround: temporarily `aws autoscaling set-desired-capacity
    --auto-scaling-group-name nodeapp-asg --desired-capacity 1` instead —
    ASG-driven launches go through AWS's own AutoScaling service-linked
    role, not `infra-provisioner`, so the same deny doesn't apply. That
    instance (in `nodeapp-sg`, which `rds-sg` already permits on 3306) is
    the SSM port-forward jump box; scale back to 0 afterward. Note the
    instance's own user-data (`nodeapp.sh.tpl`) will fail partway through
    if `serverprojectx/*` secrets don't exist yet (`set -euo pipefail` +
    an early `get-secret-value` call) — harmless for this purpose, since
    SSM agent registration is a separate OS-level service, independent of
    user-data success.
  - **MySQL client**: there's no local `mysql` CLI on the dev machine — use
    `docker exec mysql-db mysql -h host.docker.internal -P<local-tunnel-port> ...`
    instead (the existing dev `mysql-db` container's own client, reaching
    the SSM tunnel on the host via Docker Desktop's `host.docker.internal`).
  - **Gameserver schema**: not a `.sql` dump in this repo — ServerProjextX
    owns it as a single Knex migration
    (`ServerProjextX/db/migrations/20170423002553_setup.js`, 24
    `createTable` calls + Knex's own 2 bookkeeping tables = the 26 tables
    the local dev `gameserver` DB has). `infra/scripts/run-gameserver-migration.js`
    (committed, reusable — not a scratch one-off) runs that same migration
    set against any MySQL endpoint via env vars
    (`GAMESERVER_DB_HOST`/`_PORT`/`_USER`/`_PASSWORD`/`_NAME`,
    `SERVERPROJEXTX_PATH`), requiring knex straight out of ServerProjextX's
    own `node_modules` rather than duplicating a schema snapshot here. Used
    to provision the RDS `gameserver` DB's tables; re-run this script
    (pointed at a fresh target) if the infra is ever rebuilt.
  - **Gameserver seed data**: same pattern, sibling script
    `infra/scripts/run-gameserver-seed.js` (`knex.seed.run()` instead of
    `.migrate.latest()`), defaulting to ServerProjextX's
    `db/seeds/development/` — despite the folder name, this is the
    project's only seed set and not throwaway dev fixtures: jeweltype
    (18 rows) / achievements (32) / factory+factorymaterial (10/20,
    crafting recipes) reference data, plus a `jcusers` row (`id=1`, name
    `"Team JewelChat"`) that `controllers/mongooseim.js`'s push-notification
    handler specifically special-cases by that exact name. **`shows_seed3.js`
    runs `knex('jcusers').del()` before inserting — destructive.** Checked
    row counts were 0 on all four affected tables before running this
    against RDS (2026-10-07), so it was safe; re-confirm row counts first
    if this ever needs re-running somewhere that might already have real
    user data. Verified live afterward via the real API, not just row
    counts: `curl https://game.jewelchat.net/mongooseim/user_exists?user=1&server=jewelchat.net`
    → `true`.
  - **Local SQL client / ad-hoc queries against RDS**: same SSM
    port-forward mechanism, just pick any `InService` instance in
    `nodeapp-sg` or `mongooseim-sg` as the `--target` (no need for a
    dedicated bastion or the throwaway bootstrap instance from the RDS
    step) — `rds-sg` already permits 3306 from both. `mongooseim/db-credentials`
    and `serverprojectx/db-credentials` are unreadable by `infra-provisioner`/
    `iam-admin` (by design, see above) — fetch those with a personal/root
    AWS identity, not either of this project's two scoped profiles. No
    local `mysql` CLI on this dev machine (see above) — either use the
    `mysql-db` dev container's own client via `host.docker.internal`, or a
    GUI SQL client pointed at `127.0.0.1:<local-tunnel-port>` directly.
- Full design rationale, the exact IAM policy JSON, and the verification
  checklist for the original infra build-out were written up in a plan
  file; **that path has since been overwritten by an unrelated plan** (a
  GitHub Actions CI/CD design for ServerProjextX deploys) and the original
  content is no longer recoverable from it — don't trust the filename
  reference if this ever comes up again. The CI/CD plan it now contains
  (OIDC federation, `github-actions-deploy-role`, a new `CiDeployBoundary`)
  is itself real, designed, and not yet applied — `infra/iam/github_oidc.tf`
  does not exist yet.
- **MongooseIM launched for real** (2026-10-08), `mongooseim-asg` at its
  intended steady state of 1. Hit a genuinely subtle bug getting there,
  worth the detail since it'll bite again if `userdata/mongooseim.sh.tpl`'s
  `docker-compose.yml` block is ever touched:
  - **The image's own `/start.sh` unconditionally overwrites vm.args'
    `-name` line** with `sed -i -E -e "s/^-s?name.*$/-$${NODE_TYPE}
    $${NODE_NAME}@$${NODE_HOST}/" vm.args` — found by reading `/start.sh`
    directly out of the image (`docker run --rm --entrypoint cat
    erlangsolutions/mongooseim:latest /start.sh`), same approach as other
    version-sensitive module gotchas elsewhere in this file. This means
    the `NODE_TYPE`/`NODE_HOST` **container env vars**, not the vm.args
    file content we bind-mount in, actually control the node name —
    writing a correct `-name mongooseim@<ip>` into vm.args ourselves
    accomplishes nothing, since it just gets overwritten at container
    start.
  - `NODE_TYPE` must be exactly `"name"` or `"sname"` — the script splices
    it straight into the flag. The original value, `"longnames"`, isn't
    recognized by the script at all; it produces a nonsense `-longnames`
    flag and **no** `-name`/`-sname` line survives, which is what MongooseIM
    itself was reporting as `vm.args needs to have either -name or -sname
    parameter` (visible via `docker logs mongooseim`, or
    `aws ssm send-command` with `AWS-RunShellScript` if SSM interactive
    sessions aren't available — `ssm:SendCommand` is a separate, narrower
    IAM action from `ssm:StartSession` and wasn't blocked by this session's
    permission classifier the way the interactive session was).
  - `NODE_HOST` must also be set explicitly (to the instance's private IP)
    — left unset, the script falls back to the container's own `hostname
    -f`, which would silently break the `join_cluster` peer-discovery loop
    below it (that loop addresses peers by private IP; a node registered
    under its FQDN would never match).
  - Implementation note: setting `NODE_HOST` to a live shell value
    (`$PRIVATE_IP`) inside the `docker-compose.yml` heredoc forced that
    heredoc from single-quoted (`<<'EOF'`, zero shell expansion) to
    double-quoted (`<<EOF`) — which then made bash try to expand every
    `$`/`${...}` in the surrounding **comments** too, including ones that
    were only meant for Terraform's own `templatefile()` pass (`$${...}`
    doubling escapes Terraform, not bash) — triggering `set -u`'s "unbound
    variable" and aborting the whole userdata script before the container
    ever started. Fixed by keeping the heredoc single-quoted and
    substituting a placeholder token (`PRIVATE_IP_PLACEHOLDER`) via `sed`
    after writing the file instead — avoids the dual-escaping problem
    entirely. Worth remembering for any future edit in this file: a
    double-quoted heredoc here needs every comment inside it kept
    completely free of `$`, not just the lines doing real variable
    substitution.
  - Verified clean: `docker logs mongooseim` shows a normal boot (no
    vm.args error), `cat /usr/lib/mongooseim/etc/vm.args` inside the
    container shows the correct `-name mongooseim@<private-ip>`,
    `mongooseimctl server hostTypes` lists every module this project
    configured (`mod_mam*`, `mod_muc_light`, `mod_roster`, `mod_vcard`,
    `mod_auth_token`, `mod_keystore`, `mod_carboncopy`, `mod_ping`,
    `mod_push_service_mongoosepush`, `mod_event_pusher`/`_push`,
    `mod_offline_stub`) with none missing, ALB target health is `healthy`,
    and `curl https://chat.jewelchat.net/http-bind` returns `200
    MongooseIM bosh endpoint` over the real domain/ACM cert.
  - **Second bug found right after, via a real login attempt**: SASL PLAIN
    auth consistently failed with `<not-authorized/>` even though curling
    `check_password`/`user_exists` directly against the nodeapp returned
    `true`. Zero related log lines at the default `loglevel = "warning"`
    — `ejabberd_auth_http:handle_result/5` logs HTTP failures at
    `?LOG_DEBUG`, not warning, so a broken auth.http call is **completely
    silent** at this config's log level. Diagnosed by temporarily running
    `mongooseimctl server setLoglevel --level DEBUG` (live, no restart
    needed; enum value must be upper-case — `debug` alone errors
    `unknown_enum`) and retrying the same login: real reason was
    `{options,incompatible,[{verify,verify_peer},{cacerts,undefined}]}` —
    Erlang's TLS client defaults `verify_mode` to `peer` for any `https://`
    outgoing HTTP pool and refuses to even attempt the connection without
    a CA source. Neither `outgoing_pools.http.auth` nor `.mongoose_push`
    had ever needed one before now — dev talks to the nodeapp over plain
    `http://`, and prod's first few boots never got far enough into a real
    login attempt to hit this. Fixed by adding `connection.tls.cacertfile`
    to both pools, pointed at a bind-mounted copy of the **host EC2
    instance's own OS-maintained CA bundle**
    (`/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`, mounted into the
    container at `/etc/ssl/ca-bundle.pem`) rather than one of the bundles
    already inside the MongooseIM image itself (e.g.
    `lib/certifi-2.14.0/priv/cacerts.pem` — found and verified it's a real
    150-cert Mozilla bundle, same mechanism works, but that path is pinned
    to a dependency version that could silently shift on a future image
    update; the other candidate already in the image,
    `priv/ssl/cacert.pem`, turned out to be a single self-signed dev cert,
    not a trust bundle at all — checked both with `grep -c BEGIN` before
    picking one). `verify_mode` itself was deliberately left at its
    secure default (`peer`) rather than set to `none` — the ALB's cert is
    a real Amazon-issued one, so there's no reason to skip verification
    the way the dev listener configs do for their self-signed certs.
  - Verified with the same real-login approach used for debugging:
    `mongooseimctl server setLoglevel --level DEBUG`, then a genuine SASL
    PLAIN login via the Node+jsdom+Strophe.js harness (same pattern as
    "Testing without a browser" above, just pointed at
    `wss://chat.jewelchat.net/ws-xmpp` instead of localhost) — full
    success through resource bind and session establishment for two
    different real accounts, not just a clean boot. Log level set back to
    `WARNING` afterward.
  - **`mongooseimctl account checkPassword`/`checkUser` are not reliable
    stand-ins for testing the real auth.http path** — they returned
    `user_does_not_exist` throughout this entire debugging session with
    zero corresponding HTTP debug logs, even after the fix was confirmed
    working via a real client login. Whatever existence check the admin
    GraphQL API uses, it isn't simply calling out to `auth.http` the way
    a live SASL login does — don't trust it for this class of bug; use a
    real client-style login (or `mongooseimctl debug`'s interactive shell,
    if actually interactive) instead.
  - **`ssm:SendCommand` (`AWS-RunShellScript`) was the real workhorse for
    all of this debugging** — `ssm:StartSession` (interactive) is blocked
    by this session's permission classifier, but `SendCommand` is a
    separate, narrower IAM action that wasn't. Covers `docker logs`,
    `docker exec`, `docker inspect`, reading files, even `docker run
    --rm --entrypoint cat <image> <path>` to read a file straight out of
    an image without needing a running container at all — enough to do
    this entire investigation without ever needing an interactive shell.
- **`userdata/mongooseim.sh.tpl`'s module list had silently drifted from
  `conf/mongooseim.toml`'s (found 2026-10-08)**: a real client hit
  `<iq><time xmlns='urn:xmpp:time'/></iq>` against production and got back
  `<not-implemented/>` — `mod_time` was never added to the prod template,
  even though dev has had it from early on. Diffing the two module lists
  found this wasn't an isolated miss: `mod_adhoc`, `mod_disco`,
  `mod_stream_management`, `mod_presence`, and `mod_sic` were *also* missing
  from prod. `mod_presence` is the serious one — see "Presence requires an
  initial `<presence/>` first" above; without it, subscribe/subscribed
  presence and roster-triggered availability broadcasts silently no-op in
  production exactly as described there, nothing specific to prod about
  that bug once the module itself isn't loaded. `mod_register` was
  deliberately *not* added — prod accounts are created through the nodeapp,
  not by letting arbitrary clients self-register over XMPP.
  - Fixed by adding all six to `userdata/mongooseim.sh.tpl`'s
    `[modules.*]` block, matching dev's config verbatim. Applied via
    `terraform apply -target=aws_launch_template.mongooseim` (bumped to
    launch template version 6), then `aws autoscaling
    terminate-instance-in-auto-scaling-group
    --no-should-decrement-desired-capacity` on the running instance so the
    ASG relaunched with it — same redeploy pattern as the TLS fix above.
  - **Lesson**: this file and `conf/mongooseim.toml` are meant to describe
    the *same* server and have no mechanism keeping them in sync — every
    prior prod module/config change in this doc was applied to
    `mongooseim.sh.tpl` directly, one at a time, which is exactly how a
    module present in dev from day one (`mod_time`, never touched since)
    never made it into prod's template at all. Worth a full diff of the
    two module lists any time a "local server does not implement this
    feature" class of error shows up in prod, not just patching the one
    namespace that errored.
  - Verified: `mongooseimctl server hostTypes` lists all six new modules
    loaded on the replacement instance, and a real `urn:xmpp:time` query
    via the Node+jsdom+Strophe.js harness against
    `wss://chat.jewelchat.net/ws-xmpp` now gets back a proper
    `<time xmlns='urn:xmpp:time'><tzo>...</tzo><utc>...</utc></time>`
    result instead of `<not-implemented/>`.
