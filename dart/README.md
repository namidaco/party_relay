# namida_party_relay

Pure Dart implementation of the namida party relay (`../PROTOCOL.md`). `dart:io` only, no Flutter, no runtime
dependencies. Used two ways:

- imported by the app to host a LAN party in process (`PartyRelayServer.start` + `createRoom`).
- run standalone as a self hosted relay (`bin/relay.dart`, or the compiled exe).

Membership proofs are not implemented here: `/v1/info` reports `"membership": false`, `auth` of kind `patreon` or
`supabase` is ignored, and every room is created with tier `selfhost`. Access control for a self host is the create
password.

## Run it

```sh
dart run bin/relay.dart --port 8787 --host 0.0.0.0
dart run bin/relay.dart --create-password hunter2 --max-members 50 --max-rooms 20
dart compile exe bin/relay.dart -o relay && ./relay --port 8787
```

| flag | env | default |
|---|---|---|
| `--port <n>` | `PORT` | 8787 |
| `--host <addr>` | `HOST` | 0.0.0.0 |
| `--create-password <s>` | `CREATE_PASSWORD` | none (anyone can create) |
| `--max-members <n>` | `MAX_MEMBERS` | 100 |
| `--max-rooms <n>` | `MAX_ROOMS` | unlimited |
| `--trust-proxy` | `TRUST_PROXY_HEADERS` | false |
| `--no-directory` | `DIRECTORY` | directory on (`GET /v1/rooms` served) |

Timers and limits, for tests and tuning: `HOST_GRACE_MS` (60000), `PENDING_TIMEOUT_MS` (120000), `JOIN_TIMEOUT_MS`
(10000), `IDLE_TIMEOUT_MS` (600000), `ROOM_LIFETIME_MS` (86400000), `CREATE_LIMIT` (10 per ip per 10 min),
`JOIN_LIMIT` (20 per ip per min), `LIST_LIMIT` (60 per ip per `LIST_WINDOW_MS`, 60000), `DIRECTORY_REFRESH_MS`
(60000, how stale a listed room's `members`/`at` may be), `DIRECTORY_TTL_MS` (900000, an entry not refreshed for
that long stops being listed), `RATE_DROP_CLOSE` (200 dropped frames per minute closes the socket).

## Public rooms

`GET /v1/rooms` lists the rooms created with `opts.public` whose host has sent a `summary` frame, have at least one
connected member and are not locked. The rest, including every unlisted room, is invisible, so a code can never be
guessed from it. The listing is derived from the live rooms, an entry refreshes at most once per
`DIRECTORY_REFRESH_MS` (becoming public, unlisted or closed applies at once) and `hid` is the first 8 hex of the
sha-256 of the creator `did`.

## In the app

```dart
final relay = await PartyRelayServer.start(port: 8787);
final room = relay.createRoom(name: 'my party', did: deviceId, approval: true);
// room.code, room.token -> hand the token to the local client, it joins like any other member
await relay.close();
```

`lib/src/envelope.dart` is exported for clients too: route constants, `encodeDataFrame`, header accessors,
error/control frame name constants, room code helpers.

## Docker

```sh
docker build -t namida-relay .
docker run --rm -p 8787:8787 -e CREATE_PASSWORD=hunter2 namida-relay
```

The image is `scratch` plus the dart runtime deps and the compiled exe.

## TLS / wss

The relay speaks plain http/ws unless a `SecurityContext` is passed to `PartyRelayServer.start`. For a public deploy
put it behind a reverse proxy (caddy, nginx, cloudflare) that terminates TLS and forwards the websocket upgrade, then
clients use `wss://`. Only then start it with `--trust-proxy`, so the client ip is read from the first hop of
`X-Forwarded-For` (or `CF-Connecting-IP`) instead of the socket; without a proxy in front, leave it off or every
client shares the proxy ip for rate limits and bans.

nginx:

```nginx
location / {
  proxy_pass http://127.0.0.1:8787;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "upgrade";
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_read_timeout 1h;
}
```

## Tests

```sh
dart test                      # everything, relay started in process
dart test test/conformance     # protocol conformance only
```

The conformance suite is black box, http + websocket only. To run it against another implementation (the worker, or
a deployed relay):

```sh
RELAY_URL=http://127.0.0.1:8787 dart test test/conformance
```

The target must run with short timers and lifted per ip limits, otherwise the timing tests are slow and the whole
suite (one ip) trips the create/join limits:

```
HOST_GRACE_MS=1500 PENDING_TIMEOUT_MS=1500 JOIN_TIMEOUT_MS=1000 MAX_MEMBERS=4 CREATE_LIMIT=100000 JOIN_LIMIT=100000
LIST_LIMIT=100000 DIRECTORY=true DIRECTORY_REFRESH_MS=0
```

plus no membership and no create password. `RATE_DROP_CLOSE` (default 200) may be lowered to make the rate limit test
shorter; the suite reads the same env var to size its burst.
