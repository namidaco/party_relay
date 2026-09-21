import { verifyPatreon, verifySupabase } from './auth';
import { optString } from './envelope';
import {
  BODY_MAX,
  CREATE_RATE_MAX,
  CREATE_RATE_WINDOW,
  DID_MAX,
  DIR_NAME,
  LIST_RATE_MAX,
  NAME_MAX,
  PASSWORD_MAX,
  createPasswordOf,
  directoryOn,
  directoryTtl,
  listLimit,
  membershipOn,
  num,
  tierLimits,
  timers,
} from './limits';
import { EV, type RelayEnv, type Tier } from './types';
import { cleanText, clientIp, ctEq, json, normalizeCode, roomCode, sha256hex } from './util';

export { RoomDO } from './room';
export { OwnerDO } from './owner';
export { DirectoryDO } from './directory';

type Rec = Record<string, unknown>;

export default {
  async fetch(req: Request, env: RelayEnv): Promise<Response> {
    try {
      return await route(req, env);
    } catch {
      return json({ error: 'bad_request' }, 400);
    }
  },
} satisfies ExportedHandler<RelayEnv>;

async function route(req: Request, env: RelayEnv): Promise<Response> {
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      status: 204,
      headers: {
        allow: 'GET, POST, OPTIONS',
        'access-control-allow-origin': '*',
        'access-control-allow-methods': 'GET, POST, OPTIONS',
        'access-control-allow-headers': 'content-type',
        'access-control-max-age': '86400',
      },
    });
  }

  const path = new URL(req.url).pathname;

  if (path === '/v1/info') {
    if (req.method !== 'GET') return json({ error: 'bad_request' }, 400);
    return json({
      ev: EV,
      name: 'namida-party',
      membership: membershipOn(env),
      createPassword: createPasswordOf(env) != null,
      directory: directoryOn(env),
    });
  }

  if (path === '/v1/rooms') {
    if (req.method === 'GET') return await listRooms(req, env);
    if (req.method !== 'POST') return json({ error: 'bad_request' }, 400);
    return await createRoom(req, env);
  }

  if (path.startsWith('/v1/room/')) {
    const code = normalizeCode(decodeURIComponent(path.slice('/v1/room/'.length)));
    if (!code) return json({ error: 'not_found' }, 404);
    if (req.method !== 'GET') return json({ error: 'bad_request' }, 400);
    if ((req.headers.get('upgrade') ?? '').toLowerCase() !== 'websocket') {
      return new Response('expected a websocket upgrade', { status: 426, headers: { upgrade: 'websocket' } });
    }
    const stub = env.ROOM.get(env.ROOM.idFromName(code));
    return await stub.fetch(new Request(`https://room.invalid/ws?ip=${encodeURIComponent(clientIp(req))}`, req));
  }

  return json({ error: 'not_found' }, 404);
}

async function listRooms(req: Request, env: RelayEnv): Promise<Response> {
  if (!directoryOn(env)) return json({ error: 'not_found' }, 404);
  const q = new URL(req.url).searchParams;
  const res = await env.DIR.get(env.DIR.idFromName(DIR_NAME)).list({
    ip: clientIp(req),
    limit: listLimit(q.get('limit')),
    after: q.get('after'),
    ttlMs: directoryTtl(env),
    rateMax: num(env.LIST_RATE_MAX, LIST_RATE_MAX),
  });
  if (res.limited) return json({ error: 'rate_limited' }, 429);
  return json({ rooms: res.rooms, next: res.next });
}

async function createRoom(req: Request, env: RelayEnv): Promise<Response> {
  const body = await readBody(req);
  if (!body) return json({ error: 'bad_request' }, 400);

  if (!Number.isInteger(body.pv) || (body.pv as number) < 1) return json({ error: 'bad_request' }, 400);
  const pv = body.pv as number;
  const name = cleanText(body.name, NAME_MAX);
  const did = cleanText(body.did, DID_MAX);
  if (name == null || did == null) return json({ error: 'bad_request' }, 400);

  let approval = false;
  let pub = false;
  let password: string | null = null;
  if (body.opts != null) {
    if (typeof body.opts !== 'object' || Array.isArray(body.opts)) return json({ error: 'bad_request' }, 400);
    const opts = body.opts as Rec;
    if (opts.approval != null) {
      if (typeof opts.approval !== 'boolean') return json({ error: 'bad_request' }, 400);
      approval = opts.approval;
    }
    if (opts.public != null) {
      if (typeof opts.public !== 'boolean') return json({ error: 'bad_request' }, 400);
      pub = opts.public;
    }
    const p = optString(opts.password, PASSWORD_MAX);
    if (p === undefined) return json({ error: 'bad_request' }, 400);
    password = p;
  }

  let auth: Rec | null = null;
  if (body.auth != null) {
    if (typeof body.auth !== 'object' || Array.isArray(body.auth)) return json({ error: 'bad_request' }, 400);
    auth = body.auth as Rec;
    if (typeof auth.kind !== 'string') return json({ error: 'bad_request' }, 400);
  }

  const ip = clientIp(req);
  const on = membershipOn(env);

  // Abuse guard for the hosted relay only, a self-host instance serves a single lan.
  const rateMax = num(env.CREATE_RATE_MAX, on ? CREATE_RATE_MAX : 0);
  if (rateMax > 0) {
    const ok = await env.OWNER.get(env.OWNER.idFromName(`rate:${ip}`)).hit(rateMax, CREATE_RATE_WINDOW);
    if (!ok) return json({ error: 'rate_limited' }, 429);
  }

  let tier: Tier;
  let identity: string;
  if (on) {
    const kind = auth?.kind;
    if (kind === 'patreon') {
      const token = optString(auth!.token, 8192);
      if (token == null) return json({ error: 'membership_required' }, 401);
      const res = await verifyPatreon(token);
      if ('error' in res) return json({ error: res.error }, res.error === 'upstream' ? 502 : 403);
      tier = res.tier;
      identity = res.identity;
    } else if (kind === 'supabase') {
      const id = idOf(auth!.id);
      const email = optString(auth!.email, 320);
      if (id == null || email == null) return json({ error: 'membership_required' }, 401);
      const res = await verifySupabase(id, email, did);
      if ('error' in res) return json({ error: res.error }, res.error === 'upstream' ? 502 : 403);
      tier = res.tier;
      identity = res.identity;
    } else {
      return json({ error: 'membership_required' }, 401);
    }
  } else {
    const required = createPasswordOf(env);
    if (required != null) {
      if (auth?.kind !== 'password') return json({ error: 'membership_required' }, 401);
      const given = optString(auth.password, 256);
      if (given == null) return json({ error: 'bad_password' }, 403);
      if (!ctEq(await sha256hex(given), await sha256hex(required))) return json({ error: 'bad_password' }, 403);
    }
    tier = 'selfhost';
    identity = `ip:${ip}`;
  }

  const { max, rooms } = tierLimits(env, tier);
  const ownerId = Number.isFinite(rooms) ? identity : null;
  const lifetime = timers(env).lifetime;
  // stable per creator, a self-host relay has only the device to hash
  const hid = (await sha256hex(on ? identity : did)).slice(0, 8);

  const owner = ownerId != null ? env.OWNER.get(env.OWNER.idFromName(ownerId)) : null;
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = roomCode();
    if (owner) {
      if (!(await owner.claim(code, rooms, lifetime))) return json({ error: 'rooms_limit' }, 429);
    }
    const res = await env.ROOM.get(env.ROOM.idFromName(code)).create({
      code,
      pv,
      name,
      did,
      ip,
      approval,
      password,
      pub,
      maxMembers: max,
      tier,
      ownerId,
      hid,
    });
    if (res.ok) return json({ code, token: res.token, max, tier });
    if (owner) await owner.release(code);
  }
  return json({ error: 'upstream' }, 502);
}

function idOf(value: unknown): string | null {
  if (typeof value === 'string') return value.length >= 1 && value.length <= 128 ? value : null;
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  return null;
}

async function readBody(req: Request): Promise<Rec | null> {
  const len = req.headers.get('content-length');
  if (len != null && Number(len) > BODY_MAX) return null;
  let text: string;
  try {
    text = await req.text();
  } catch {
    return null;
  }
  if (text.length > BODY_MAX) return null;
  try {
    const v = JSON.parse(text);
    if (v == null || typeof v !== 'object' || Array.isArray(v)) return null;
    return v as Rec;
  } catch {
    return null;
  }
}
