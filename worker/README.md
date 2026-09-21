# namida party relay — Cloudflare Worker

WebSocket relay for namida parties, implementing [`../PROTOCOL.md`](../PROTOCOL.md) (envelope version 1).
One SQLite backed Durable Object per room (`RoomDO`, WebSocket Hibernation API), one per membership identity
(`OwnerDO`, room limit + create rate limit). The relay never parses data frames: it rewrites the 4 header bytes in
place and forwards the same buffer.

```
src/index.ts     http routing, create validation, membership dispatch
src/auth.ts      patreon / supabase verification, 10 min cache keyed by the hash of the proof
src/room.ts      RoomDO: join, control frames, data routing, alarms
src/owner.ts     OwnerDO: rooms per identity, create attempts per ip
src/envelope.ts  frame parsing and validation
src/limits.ts    tiers, sizes, buckets, timers from config
src/util.ts      room codes, tokens, sha-256, constant time compare
```

## Develop

```sh
npm install
npm run typecheck      # tsc --noEmit
npm test               # vitest + @cloudflare/vitest-pool-workers
npm run dev            # wrangler dev, membership on
npm run dev:conformance # wrangler dev on :8787 with the conformance timers
```

The Dart conformance suite runs against it black box:

```sh
npm run dev:conformance              # terminal 1
cd ../dart && RELAY_URL=http://127.0.0.1:8787 dart test test/conformance   # terminal 2
```

## Deploy (maintainer)

1. `npx wrangler login` (once, on your machine).
2. `npx wrangler deploy` — the first deploy applies the `v1` migration that creates `RoomDO` and `OwnerDO` as
   SQLite classes.
3. Bind the custom domain `party.namida.app`: dashboard → the worker → Settings → Domains & Routes → Add custom
   domain, or uncomment the `routes` entry in `wrangler.jsonc` and redeploy. The zone must be on the same account.
4. Leave `MEMBERSHIP` at `on`. Nothing else is required: patreon and supabase are verified with the caller's own
   proof, so the worker holds no secrets.

Checks after a deploy: `curl https://party.namida.app/v1/info` → `{"ev":1,...,"membership":true}`.

### Config vars

All optional, all strings (`wrangler.jsonc` `vars`, or `--var K:V` in dev).

| var | default | meaning |
|---|---|---|
| `MEMBERSHIP` | `on` | `off` turns room creation into a self-host relay (tier `selfhost`) |
| `CREATE_PASSWORD` | unset | when `MEMBERSHIP=off`, room creation needs `auth {kind:"password"}` |
| `SELFHOST_MAX_MEMBERS` | `100` | member cap when `MEMBERSHIP=off` |
| `HOST_GRACE_MS` | `60000` | host may resume before the relay promotes a successor |
| `PENDING_TIMEOUT_MS` | `120000` | approval request lifetime |
| `JOIN_TIMEOUT_MS` | `10000` | time to send the `join` frame after the upgrade |
| `IDLE_TIMEOUT_MS` | `600000` | room close after the last member leaves |
| `ROOM_LIFETIME_MS` | `86400000` | hard room expiry |
| `RATE_DROP_CLOSE` | `200` | dropped frames within a minute before the socket is closed |
| `JOIN_RATE_MAX` | `20` | join attempts per ip per minute per room, `0` disables |
| `CREATE_RATE_MAX` | `10` on, `0` off | create attempts per ip per 10 minutes |

## Deploy your own

A self-host relay needs no membership backend:

```jsonc
"vars": {
  "MEMBERSHIP": "off",
  // optional, otherwise anyone who can reach the worker can open a room
  "CREATE_PASSWORD": "pick-something",
  "SELFHOST_MAX_MEMBERS": "100"
}
```

Then `npx wrangler deploy` on your own account and point the app at `https://<worker>.<subdomain>.workers.dev`.
With `MEMBERSHIP=off` there is no rooms-per-identity limit and no create rate limit, so use `CREATE_PASSWORD`
if the url is public. For a lan party prefer `../dart`, it needs no account at all.

## Expected cost

The free plan covers a small relay, the design keeps it there:

- **Durable Object requests**: a websocket message is a request, but hibernatable sockets bill at **20 incoming
  messages per request**, so a 5 member party at 4 frames/s costs roughly one request per second. Free plan:
  1M requests/month.
- **Duration**: hibernation means an idle room (no frames) is evicted from memory and bills nothing. Rooms keep
  exactly one alarm armed (the nearest of join / pending / host grace / idle / expiry), so an idle room wakes at
  most once — not periodically.
- **Storage**: one row for the room plus one per member; nothing is written on the data path. Rate buckets live in
  memory only, so an eviction resets them to full, which is harmless because eviction implies the socket was idle
  long enough to refill anyway.
- **Rooms** close themselves: host `close`, 10 minutes with nobody connected, or 24h after creation, and the
  `OwnerDO` entry is released at the same time.

Rough figures: a room with a host and 4 guests, one hour of playback with chat, sits well under 100k DO requests.
The practical ceiling on the free plan is the 1M requests and 1000 concurrent DO limit, not storage.
