import { describe, expect, it } from 'vitest';
import { call, connect, makeRoom, post } from './helpers';

describe('GET /v1/info', () => {
  it('reports the relay config', async () => {
    const off = await (await call('/v1/info')).json<any>();
    expect(off).toEqual({ ev: 1, name: 'namida-party', membership: false, createPassword: false, directory: true });

    const on = await (await call('/v1/info', undefined, { MEMBERSHIP: 'on' })).json<any>();
    expect(on.membership).toBe(true);
    expect(on.createPassword).toBe(false);

    const pw = await (await call('/v1/info', undefined, { CREATE_PASSWORD: 'x' })).json<any>();
    expect(pw).toEqual({ ev: 1, name: 'namida-party', membership: false, createPassword: true, directory: true });
  });

  it('answers OPTIONS', async () => {
    const res = await call('/v1/info', { method: 'OPTIONS' });
    expect(res.status).toBe(204);
    expect(res.headers.get('allow')).toContain('POST');
  });
});

describe('POST /v1/rooms', () => {
  it('creates a room', async () => {
    const room = await makeRoom();
    expect(room.code).toMatch(/^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$/);
    expect(room.token.length).toBeGreaterThanOrEqual(43);
    expect(room.max).toBe(100);
    expect(room.tier).toBe('selfhost');
  });

  it('honours SELFHOST_MAX_MEMBERS', async () => {
    const room = await makeRoom({}, { SELFHOST_MAX_MEMBERS: '7' });
    expect(room.max).toBe(7);
  });

  it('rejects malformed bodies', async () => {
    const cases: unknown[] = [
      {},
      { pv: 0, name: 'a', did: 'b' },
      { pv: 1.5, name: 'a', did: 'b' },
      { pv: '1', name: 'a', did: 'b' },
      { pv: 1, name: '', did: 'b' },
      { pv: 1, name: '   ', did: 'b' },
      { pv: 1, name: 'a'.repeat(33), did: 'b' },
      { pv: 1, name: 'a', did: '' },
      { pv: 1, name: 'a', did: 'b'.repeat(65) },
      { pv: 1, name: 'a', did: 'b', opts: [] },
      { pv: 1, name: 'a', did: 'b', opts: { approval: 'yes' } },
      { pv: 1, name: 'a', did: 'b', opts: { password: '' } },
      { pv: 1, name: 'a', did: 'b', opts: { password: 'p'.repeat(65) } },
      { pv: 1, name: 'a', did: 'b', auth: 'patreon' },
      { pv: 1, name: 'a', did: 'b', auth: { token: 'x' } },
    ];
    for (const body of cases) {
      const res = await post(body);
      expect([res.status, JSON.stringify(body)]).toEqual([400, JSON.stringify(body)]);
      expect(res.body.error).toBe('bad_request');
    }
  });

  it('rejects a body that is not json', async () => {
    const res = await call('/v1/rooms', { method: 'POST', body: 'nope' });
    expect(res.status).toBe(400);
  });

  it('strips control characters from names', async () => {
    const room = await makeRoom({ name: ' ho\u0000st\u001b ' });
    const sock = await connect(room.code);
    sock.send({ t: 'join', pv: 1, name: ' gu\u0000es\u001bt ', did: 'g', token: null, password: null });
    const welcome = await sock.next();
    expect(welcome.members).toEqual([{ n: 2, name: 'guest' }]);
    sock.close();
  });

  it('requires the create password when configured', async () => {
    const overrides = { CREATE_PASSWORD: 'sesame' };
    expect((await post({ pv: 1, name: 'a', did: 'b', auth: null }, overrides)).status).toBe(401);
    expect((await post({ pv: 1, name: 'a', did: 'b', auth: { kind: 'patreon', token: 'x' } }, overrides)).status).toBe(
      401,
    );
    const wrong = await post({ pv: 1, name: 'a', did: 'b', auth: { kind: 'password', password: 'nope' } }, overrides);
    expect(wrong.status).toBe(403);
    expect(wrong.body.error).toBe('bad_password');
    const ok = await post({ pv: 1, name: 'a', did: 'b', auth: { kind: 'password', password: 'sesame' } }, overrides);
    expect(ok.status).toBe(200);
    expect(ok.body.tier).toBe('selfhost');
  });

  it('limits create attempts per ip when the rate limiter is on', async () => {
    const overrides = { CREATE_RATE_MAX: '3' };
    for (let i = 0; i < 3; i++) {
      expect((await post({ pv: 1, name: 'a', did: 'b' }, overrides, '9.9.9.9')).status).toBe(200);
    }
    const blocked = await post({ pv: 1, name: 'a', did: 'b' }, overrides, '9.9.9.9');
    expect(blocked.status).toBe(429);
    expect(blocked.body.error).toBe('rate_limited');
    expect((await post({ pv: 1, name: 'a', did: 'b' }, overrides, '9.9.9.8')).status).toBe(200);
  });
});

describe('GET /v1/room/<code>', () => {
  it('404s unknown and malformed codes without a websocket', async () => {
    for (const code of ['AAAAAAAA', 'AAAA', 'AAAAAAA0', 'AAAAAAAI', '../../etc']) {
      const res = await call(`/v1/room/${code}`, { headers: { upgrade: 'websocket' } });
      expect(res.status).toBe(404);
      expect(await res.json<any>()).toEqual({ error: 'not_found' });
    }
  });

  it('426s a plain GET on an existing room', async () => {
    const room = await makeRoom();
    const res = await call(`/v1/room/${room.code}`);
    expect(res.status).toBe(426);
  });

  it('accepts a lower case code', async () => {
    const room = await makeRoom();
    const res = await call(`/v1/room/${room.code.toLowerCase()}`, { headers: { upgrade: 'websocket' } });
    expect(res.status).toBe(101);
    res.webSocket?.accept();
    res.webSocket?.close();
  });

  it('404s unknown paths', async () => {
    expect((await call('/nope')).status).toBe(404);
  });
});
