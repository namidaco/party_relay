# Namida Party Relay Protocol

Relay envelope version: **1** (`ev`). The relay is a dumb router: it knows rooms, members, who the host is, bans and
limits. It never parses data frames. All queue/playback/chat logic lives in the app (host-authoritative).

Two implementations must behave identically and pass the same conformance suite (`party_relay/dart/test/conformance`):

- `party_relay/worker` Cloudflare Worker + Durable Objects (one DO per room, WebSocket Hibernation API).
- `party_relay/dart` pure Dart package (`dart:io`), used in-app for LAN parties and as a standalone self-host binary.

All times are unix epoch milliseconds. All JSON keys are as written here. Unknown keys are ignored.

## HTTP

### `GET /v1/info`

```json
{"ev": 1, "name": "namida-party", "membership": true, "createPassword": false}
```

`membership`: room creation needs a namida membership proof. `createPassword`: room creation needs the server password
(self-host option). Both false = anyone can create.

### `POST /v1/rooms` create a room

Request:

```json
{
  "pv": 1,
  "name": "host display name",
  "did": "device id",
  "auth": {"kind": "patreon", "token": "<patreon access token>"},
  "opts": {"approval": false, "password": null}
}
```

`auth` variants: `{"kind":"patreon","token"}`, `{"kind":"supabase","id","email"}`, `{"kind":"password","password"}`, or
`null`.

- `pv` party (app protocol) version, integer >= 1. Stored on the room, joins must match exactly.
- `name` 1..32 chars after trim, control chars stripped. `did` 1..64 chars.
- `opts.password` null or 1..64 chars.

Response `200`:

```json
{"code": "K7Q2MXPD", "token": "<host token>", "max": 50, "tier": "cutie"}
```

`code`: 8 chars of `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (no I, O, 0, 1). Codes are case-insensitive on input, normalized
to upper case. `token`: 32 random bytes, base64url. `tier` is `cutie|pookie|patootie|owner|selfhost`.

Errors: HTTP `4xx` with `{"error": "<code>"}`:

| code | status | meaning |
|---|---|---|
| `bad_request` | 400 | malformed body / field limits |
| `membership_required` | 401 | `auth` missing or of a kind that is not accepted |
| `membership_invalid` | 403 | proof rejected, expired, or tier below cutie |
| `bad_password` | 403 | wrong create password (self-host) |
| `rooms_limit` | 429 | identity already owns its max number of open rooms |
| `rate_limited` | 429 | too many create attempts from this ip |
| `upstream` | 502 | patreon/supabase unreachable |

Tier limits (worker): cutie 50 members / 2 rooms, pookie 100 / 3, patootie 200 / 4, owner 500 / 10. Self-host: from
config, default 100 members, unlimited rooms.

Create attempts are limited to 10 per ip per 10 minutes.

### `GET /v1/room/<CODE>` websocket upgrade

`404 {"error":"not_found"}` if the room does not exist (no upgrade). Otherwise upgrade, then the client must send a
`join` text frame within 10s or the socket is closed with `error timeout`.

## Frames

Text frames are relay control messages (JSON object with `t`). Binary frames are data, opaque to the relay.

Every fatal error is `{"t":"error","code":"...","fatal":true}` followed by a websocket close (code 4000). Non fatal
errors omit `fatal` and keep the socket open.

### Join

Client, first frame:

```json
{"t": "join", "pv": 1, "name": "display name", "did": "device id", "token": null, "password": null}
```

- `token`: a token previously issued for this room (host token from create, or a member token from `welcome`). A valid
  token resumes the same member number `n`, skips password/approval/full checks, and closes any older socket of that
  member with `left r:"replaced"` not being broadcast (the member never left).
- An invalid token is treated as no token.

Server replies with one of:

```json
{"t": "welcome", "n": 3, "token": "<member token>", "host": 1, "hostOnline": true, "pv": 1, "max": 50, "now": 1790000000000,
 "opts": {"approval": false, "password": false, "locked": false},
 "members": [{"n": 1, "name": "host"}, {"n": 3, "name": "display name"}]}
```

```json
{"t": "pending"}
```

`pending`: the room needs host approval, the socket stays open and gets `welcome` or a fatal `error rejected` later.
Pending requests time out after 120s (`error timeout`). If the host is offline, `error host_offline`.

`members` lists currently connected members only (including the receiver). `opts.password` is a bool (is one set).

Fatal join errors: `not_found`, `version_mismatch` (carries `"pv": <room pv>`), `full`, `banned`, `bad_password`,
`rejected`, `locked`, `timeout`, `host_offline`, `rate_limited`, `bad_request`.

Member numbers `n` start at 1 (the creator) and only grow, never reused.

Join attempts are limited to 20 per ip per minute per relay (wrong password attempts count).

### Control, any member -> relay

| frame | reply |
|---|---|
| `{"t":"ping","c":<client ms>}` | `{"t":"pong","c":<same>,"s":<server ms>}` |
| `{"t":"leave"}` | socket closed, others get `left r:"leave"` |

### Control, host -> relay

Anyone else sending these gets a non fatal `error forbidden`.

| frame | effect |
|---|---|
| `{"t":"kick","n":3,"ban":false}` | target gets fatal `error kicked` (or `banned`), others get `left` with `r` `kick`/`ban`. its token is revoked. with `ban` its `did` and ip are added to the room ban list |
| `{"t":"unban","id":"<ban id>"}` | removes a ban |
| `{"t":"approve","r":"<req id>","ok":true}` | resolves a pending join |
| `{"t":"transfer","n":3}` | makes a connected member the host. everyone gets `host` |
| `{"t":"successors","ns":[3,5]}` | ordered preference for automatic promotion |
| `{"t":"opts","approval":true,"password":"x","locked":false}` | partial update, `password: null` clears. everyone gets `opts` |
| `{"t":"close"}` | everyone gets `closed r:"host"`, sockets closed, room deleted |

After `kick` with ban / `unban`, the host gets `{"t":"bans","list":[{"id":"..","name":".."}]}`. The host also gets it
right after its `welcome` when the list is not empty.

### Control, relay -> members

| frame | when |
|---|---|
| `{"t":"joined","n":3,"name":".."}` | a member got welcomed (sent to everyone else). also sent when a lost member resumes |
| `{"t":"left","n":3,"r":"leave"}` | `r`: `leave`, `lost` (socket dropped), `kick`, `ban` |
| `{"t":"host","n":1,"online":true}` | host changed, or host connectivity changed |
| `{"t":"opts", ...}` | same shape as `welcome.opts` |
| `{"t":"joinreq","r":"<req id>","name":"..","did":".."}` | host only, a pending join |
| `{"t":"joinreqgone","r":"<req id>"}` | host only, pending join went away (socket closed / timed out) |
| `{"t":"closed","r":".."}` | `r`: `host`, `idle`, `expired` |

### Host loss

When the host socket drops: everyone gets `host n online:false`. The host can resume with its token within **60s**.
After that the relay promotes the first connected member of `successors`, else the connected member with the lowest `n`,
and everyone gets `host <new n> online:true`. With nobody connected the room stays hostless, the first member to
(re)join becomes host. The old host resuming later is a normal member.

### Room lifetime

- closed by host `close`.
- `idle`: no connected members for 10 minutes.
- `expired`: 24h after creation.

### Data frames (binary)

5 byte header, then the opaque payload:

```
[route u8][n u32 big endian][payload...]
```

Client -> relay:

| route | who | meaning |
|---|---|---|
| 0 | anyone | to host. `n` ignored |
| 1 | host | broadcast to every connected member except the host. `n` = a member to skip, 0 for none |
| 2 | host | to member `n` |

Relay -> client: same header with `n` replaced by the **sender's** member number, `route` unchanged.

A non host sending route 1/2 gets `error forbidden`, the frame is dropped. Route 0 sent while the host is offline is
dropped silently. Route 0 from the host itself is dropped. Unknown routes get `error bad_request`.

### Limits

- text frame max 2 KiB.
- binary frame max: 16 KiB for non hosts, 1 MiB for the host. bigger gets non fatal `error too_large`, dropped.
- token bucket per socket: non host burst 40, refill 4/s. host burst 400, refill 60/s. over the limit gets non fatal
  `error rate_limited` (at most once per second) and the frame is dropped. 200 drops within a minute closes the socket
  with fatal `error rate_limited`.
- `ping` is part of the bucket.
