import { fetchMock } from 'cloudflare:test';
import { beforeAll, describe, expect, it } from 'vitest';
import { join, post } from './helpers';

const ON = { MEMBERSHIP: 'on', CREATE_RATE_MAX: '1000' };

beforeAll(() => {
  fetchMock.activate();
  fetchMock.disableNetConnect();
});

let seq = 0;
function token(): string {
  return `tok-${++seq}-${Math.random()}`;
}

/** Interceptors are matched on the proof, so a leftover from another test can never answer. */
function patreonFor(tok: string) {
  return fetchMock.get('https://www.patreon.com').intercept({
    method: 'GET',
    path: (p) => p.startsWith('/api/oauth2/v2/identity'),
    headers: { authorization: `Bearer ${tok}` },
  });
}

function patreon(tok: string, body: unknown, status = 200): string {
  patreonFor(tok)
    .reply(status, body as any)
    .persist();
  return tok;
}

function patreonError(tok: string): string {
  patreonFor(tok).replyWithError(new Error('offline')).persist();
  return tok;
}

function supabase(id: string, body: unknown, status = 200): string {
  fetchMock
    .get('https://avmqoboauxrlzxduobsy.supabase.co')
    .intercept({
      method: 'POST',
      path: '/functions/v1/subs',
      body: (raw: string) => {
        try {
          return (JSON.parse(raw) as { id?: unknown }).id === id;
        } catch {
          return false;
        }
      },
    })
    .reply(status, body as any)
    .persist();
  return id;
}

function identity(userId: string, cents: number | null, status = 'active_patron', campaign = '11979434'): unknown {
  const included: unknown[] = [
    { type: 'campaign', id: campaign, attributes: {} },
    {
      type: 'member',
      id: 'other',
      attributes: { currently_entitled_amount_cents: 999900, patron_status: 'active_patron' },
      relationships: { campaign: { data: { id: '42', type: 'campaign' } } },
    },
  ];
  if (cents != null) {
    included.push({
      type: 'member',
      id: 'me',
      attributes: { currently_entitled_amount_cents: cents, patron_status: status, last_charge_status: 'Paid' },
      relationships: { campaign: { data: { id: campaign, type: 'campaign' } } },
    });
  }
  return { data: { type: 'user', id: userId, attributes: { full_name: 'tester' } }, included };
}

function body(auth: unknown): unknown {
  return { pv: 1, name: 'host', did: 'device', auth };
}

describe('membership: patreon', () => {
  it('requires an accepted auth kind', async () => {
    expect((await post(body(null), ON)).status).toBe(401);
    expect((await post(body({ kind: 'password', password: 'x' }), ON)).status).toBe(401);
    expect((await post(body({ kind: 'patreon' }), ON)).status).toBe(401);
    expect((await post(body({ kind: 'nope', token: 'x' }), ON)).status).toBe(401);
  });

  it('gives the owner the owner tier', async () => {
    const tok = patreon(token(), identity('123565629', null));
    const res = await post(body({ kind: 'patreon', token: tok }), ON);
    expect(res.status).toBe(200);
    expect(res.body.tier).toBe('owner');
    expect(res.body.max).toBe(500);
  });

  it('maps entitled cents to tiers', async () => {
    const cases: [number, string, number][] = [
      [300, 'cutie', 50],
      [500, 'cutie', 50],
      [1000, 'pookie', 100],
      [2500, 'patootie', 200],
    ];
    for (const [cents, tier, max] of cases) {
      const tok = patreon(token(), identity(`u${cents}`, cents));
      const res = await post(body({ kind: 'patreon', token: tok }), ON);
      expect([res.status, res.body.tier, res.body.max]).toEqual([200, tier, max]);
    }
  });

  it('rejects an inactive patron, a foreign campaign and no membership', async () => {
    const cases: unknown[] = [
      identity('u1', 500, 'former_patron'),
      identity('u2', 500, 'active_patron', '999'),
      identity('u3', null),
      identity('u4', 0),
    ];
    for (const value of cases) {
      const tok = patreon(token(), value);
      const res = await post(body({ kind: 'patreon', token: tok }), ON);
      expect([res.status, res.body.error]).toEqual([403, 'membership_invalid']);
    }
  });

  it('maps 401 to membership_invalid and 5xx to upstream', async () => {
    const unauth = await post(body({ kind: 'patreon', token: patreon(token(), { errors: [] }, 401) }), ON);
    expect([unauth.status, unauth.body.error]).toEqual([403, 'membership_invalid']);

    const down = await post(body({ kind: 'patreon', token: patreon(token(), 'oops', 500) }), ON);
    expect([down.status, down.body.error]).toEqual([502, 'upstream']);

    const garbage = await post(body({ kind: 'patreon', token: patreon(token(), '<html>nope</html>') }), ON);
    expect([garbage.status, garbage.body.error]).toEqual([502, 'upstream']);
  });

  it('maps a network failure to upstream', async () => {
    const res = await post(body({ kind: 'patreon', token: patreonError(token()) }), ON);
    expect([res.status, res.body.error]).toEqual([502, 'upstream']);
  });
});

describe('membership: supabase', () => {
  it('accepts a live subscription', async () => {
    const id = supabase('s1', { sub: { id: 's1', usd: 7, available_till: null } });
    const res = await post(body({ kind: 'supabase', id, email: 'a@b.c' }), ON);
    expect([res.status, res.body.tier, res.body.max]).toEqual([200, 'pookie', 100]);
  });

  it('prefers the declared type', async () => {
    const id = supabase('s2', { sub: { id: 's2', usd: 3, type: 'Patootie', available_till: Date.now() + 100000 } });
    const res = await post(body({ kind: 'supabase', id, email: 'a@b.c' }), ON);
    expect(res.body.tier).toBe('patootie');
  });

  it('rejects an expired subscription and an error answer', async () => {
    const expiredId = supabase('s3', { sub: { id: 's3', usd: 7, available_till: '2001-01-01T00:00:00Z' } });
    const expired = await post(body({ kind: 'supabase', id: expiredId, email: 'a@b.c' }), ON);
    expect([expired.status, expired.body.error]).toEqual([403, 'membership_invalid']);

    const errId = supabase('s4', { error: 'no such sub' });
    const err = await post(body({ kind: 'supabase', id: errId, email: 'a@b.c' }), ON);
    expect([err.status, err.body.error]).toEqual([403, 'membership_invalid']);
  });

  it('maps a 5xx to upstream', async () => {
    const id = supabase('s5', { sub: {} }, 503);
    const res = await post(body({ kind: 'supabase', id, email: 'a@b.c' }), ON);
    expect([res.status, res.body.error]).toEqual([502, 'upstream']);
  });

  it('needs an id and an email', async () => {
    expect((await post(body({ kind: 'supabase', id: 's6' }), ON)).status).toBe(401);
    expect((await post(body({ kind: 'supabase', email: 'a@b.c' }), ON)).status).toBe(401);
  });
});

describe('rooms limit', () => {
  it('counts open rooms per identity and releases them on close', async () => {
    const auth = { kind: 'patreon', token: patreon(token(), identity('limited', 500)) };

    const first = await post(body(auth), ON);
    const second = await post(body(auth), ON);
    expect([first.status, second.status]).toEqual([200, 200]);
    expect(first.body.tier).toBe('cutie');

    const third = await post(body(auth), ON);
    expect([third.status, third.body.error]).toEqual([429, 'rooms_limit']);

    const host = await join(first.body.code, { token: first.body.token });
    host.sock.send({ t: 'close' });
    await host.sock.waitClosed();

    const fourth = await post(body(auth), ON);
    expect(fourth.status).toBe(200);
  });

  it('keeps identities apart', async () => {
    const a = { kind: 'patreon', token: patreon(token(), identity('solo-a', 500)) };
    expect((await post(body(a), ON)).status).toBe(200);
    expect((await post(body(a), ON)).status).toBe(200);
    expect((await post(body(a), ON)).status).toBe(429);

    const b = { kind: 'patreon', token: patreon(token(), identity('solo-b', 500)) };
    expect((await post(body(b), ON)).status).toBe(200);
  });
});
