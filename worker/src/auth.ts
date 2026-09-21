import type { Tier } from './types';
import { sha256hex } from './util';

const PATREON_URL =
  'https://www.patreon.com/api/oauth2/v2/identity?include=memberships.currently_entitled_tiers,memberships.campaign' +
  '&fields[user]=full_name&fields[member]=currently_entitled_amount_cents,patron_status,last_charge_status';
const PATREON_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';
const PATREON_OWNER_ID = '123565629';
const PATREON_CAMPAIGN_ID = '11979434';
const SUPABASE_URL = 'https://avmqoboauxrlzxduobsy.supabase.co/functions/v1/subs';

const CACHE_TTL = 600;
const TIER_NAMES = new Set<string>(['cutie', 'pookie', 'patootie', 'owner']);

export type AuthError = 'membership_invalid' | 'upstream';
export interface Identity {
  identity: string;
  tier: Tier;
}
export type AuthResult = Identity | { error: AuthError };

export function tierFromUsd(usd: number | null): Tier | null {
  if (usd == null || !Number.isFinite(usd)) return null;
  if (usd === 9999) return 'owner';
  if (usd <= 0) return null;
  if (usd <= 5) return 'cutie';
  if (usd <= 10) return 'pookie';
  return 'patootie';
}

export async function verifyPatreon(token: string): Promise<AuthResult> {
  const cached = await cacheGet('patreon', token);
  if (cached) return cached;

  let res: Response;
  try {
    res = await fetch(PATREON_URL, {
      headers: { authorization: `Bearer ${token}`, 'user-agent': PATREON_UA, accept: 'application/json' },
    });
  } catch {
    return { error: 'upstream' };
  }
  if (res.status === 401 || res.status === 403) return { error: 'membership_invalid' };
  if (!res.ok) return { error: 'upstream' };

  const body = await readJson(res);
  if (body == null) return { error: 'upstream' };

  const data = (body as Rec).data as Rec | undefined;
  const userId = data && data.id != null ? String(data.id) : null;
  if (!userId) return { error: 'membership_invalid' };

  const identity = `patreon:${userId}`;
  if (userId === PATREON_OWNER_ID) return await cachePut('patreon', token, { identity, tier: 'owner' });

  const included = (body as Rec).included;
  let usd: number | null = null;
  if (Array.isArray(included)) {
    for (const raw of included) {
      const item = raw as Rec;
      if (item == null || item.type !== 'member') continue;
      const rel = (item.relationships as Rec | undefined)?.campaign as Rec | undefined;
      const campaignId = (rel?.data as Rec | undefined)?.id;
      if (campaignId == null || String(campaignId) !== PATREON_CAMPAIGN_ID) continue;
      const attrs = (item.attributes ?? {}) as Rec;
      if (attrs.patron_status !== 'active_patron') continue;
      const cents = Number(attrs.currently_entitled_amount_cents);
      if (Number.isFinite(cents)) usd = Math.floor(cents / 100);
      break;
    }
  }

  const tier = tierFromUsd(usd);
  if (!tier) return { error: 'membership_invalid' };
  return await cachePut('patreon', token, { identity, tier });
}

export async function verifySupabase(id: string, email: string, did: string): Promise<AuthResult> {
  const proof = `${id}\u0000${email}`;
  const cached = await cacheGet('supabase', proof);
  if (cached) return cached;

  let res: Response;
  try {
    res = await fetch(SUPABASE_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ action: 'check', id, email, deviceId: did, os: 'party' }),
    });
  } catch {
    return { error: 'upstream' };
  }
  if (res.status >= 500) return { error: 'upstream' };

  const body = await readJson(res);
  if (body == null) return { error: 'upstream' };
  const rec = body as Rec;
  if (rec.error != null) return { error: 'membership_invalid' };

  const sub = rec.sub as Rec | undefined;
  if (sub == null || typeof sub !== 'object') return { error: 'membership_invalid' };
  if (!available(sub.available_till)) return { error: 'membership_invalid' };

  const identity = `supabase:${id}`;
  const typed = typeof sub.type === 'string' ? sub.type.toLowerCase() : null;
  if (typed && TIER_NAMES.has(typed)) return await cachePut('supabase', proof, { identity, tier: typed as Tier });

  const tier = tierFromUsd(typeof sub.usd === 'number' ? sub.usd : Number(sub.usd));
  if (!tier) return { error: 'membership_invalid' };
  return await cachePut('supabase', proof, { identity, tier });
}

type Rec = Record<string, unknown>;

function available(value: unknown): boolean {
  if (value == null) return true;
  const ms = typeof value === 'number' ? value : Date.parse(String(value));
  if (!Number.isFinite(ms)) return true;
  return ms > Date.now();
}

async function readJson(res: Response): Promise<unknown> {
  try {
    return await res.json();
  } catch {
    return null;
  }
}

async function cacheKey(kind: string, proof: string): Promise<string> {
  return `https://relay.invalid/mv/${kind}/${await sha256hex(proof)}`;
}

async function cacheGet(kind: string, proof: string): Promise<Identity | null> {
  try {
    const hit = await caches.default.match(new Request(await cacheKey(kind, proof)));
    if (!hit) return null;
    const value = (await hit.json()) as Identity;
    return value && typeof value.identity === 'string' ? value : null;
  } catch {
    return null;
  }
}

async function cachePut(kind: string, proof: string, value: Identity): Promise<Identity> {
  try {
    const res = new Response(JSON.stringify(value), {
      headers: { 'content-type': 'application/json', 'cache-control': `max-age=${CACHE_TTL}` },
    });
    await caches.default.put(new Request(await cacheKey(kind, proof)), res);
  } catch {
    /* cache is best effort */
  }
  return value;
}
