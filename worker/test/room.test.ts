import { describe, expect, it } from 'vitest';
import { alarmRoom, call, connect, evictRoom, inRoom, join, makeRoom, wait } from './helpers';

describe('join', () => {
  it('welcomes the creator with its token and keeps it host', async () => {
    const room = await makeRoom();
    const { welcome } = await join(room.code, { name: 'host', did: 'host-did', token: room.token });
    expect(welcome).toMatchObject({
      t: 'welcome',
      n: 1,
      host: 1,
      hostOnline: true,
      pv: 1,
      max: 100,
      opts: { approval: false, password: false, locked: false, public: false },
      members: [{ n: 1, name: 'host' }],
    });
    expect(welcome.token).toBe(room.token);
    expect(typeof welcome.now).toBe('number');
  });

  it('numbers guests and announces them', async () => {
    const room = await makeRoom();
    const host = await join(room.code, { token: room.token, name: 'host' });
    const guest = await join(room.code, { name: 'guest', did: 'g1' });
    expect(guest.welcome).toMatchObject({ n: 2, host: 1, hostOnline: true });
    expect(guest.welcome.members).toEqual([
      { n: 1, name: 'host' },
      { n: 2, name: 'guest' },
    ]);
    expect(await host.sock.next()).toEqual({ t: 'joined', n: 2, name: 'guest' });

    guest.sock.send({ t: 'leave' });
    expect(await host.sock.next()).toEqual({ t: 'left', n: 2, r: 'leave' });
    expect((await guest.sock.waitClosed()).code).toBe(1000);
  });

  it('reports a lost member', async () => {
    const room = await makeRoom();
    const host = await join(room.code, { token: room.token });
    const guest = await join(room.code, { name: 'g' });
    await host.sock.next();
    guest.sock.close();
    expect(await host.sock.next()).toEqual({ t: 'left', n: 2, r: 'lost' });
  });

  it('rejects a version mismatch', async () => {
    const room = await makeRoom({ pv: 3 });
    const { sock, welcome } = await join(room.code, { pv: 2 });
    expect(welcome).toEqual({ t: 'error', code: 'version_mismatch', fatal: true, pv: 3 });
    expect((await sock.waitClosed()).code).toBe(4000);
  });

  it('rejects a malformed join fatally', async () => {
    const room = await makeRoom();
    for (const frame of [{ t: 'join', pv: 1 }, { t: 'ping', c: 1 }, { t: 'join', pv: 1, name: 'a', did: 5 }]) {
      const sock = await connect(room.code);
      sock.send(frame);
      expect(await sock.next()).toEqual({ t: 'error', code: 'bad_request', fatal: true });
      await sock.waitClosed();
    }
  });

  it('times out a socket that never joins', async () => {
    const room = await makeRoom();
    const sock = await connect(room.code);
    expect(await sock.next(2000)).toEqual({ t: 'error', code: 'timeout', fatal: true });
    expect((await sock.waitClosed()).code).toBe(4000);
  });

  it('checks the room password', async () => {
    const room = await makeRoom({ opts: { password: 'hunter2' } });
    const bad = await join(room.code, { name: 'g', password: 'nope' });
    expect(bad.welcome).toEqual({ t: 'error', code: 'bad_password', fatal: true });
    const none = await join(room.code, { name: 'g' });
    expect(none.welcome.code).toBe('bad_password');
    const ok = await join(room.code, { name: 'g', password: 'hunter2' });
    expect(ok.welcome.t).toBe('welcome');
    expect(ok.welcome.opts.password).toBe(true);
  });

  it('honours locked, but lets a known token back in', async () => {
    const room = await makeRoom();
    const host = await join(room.code, { token: room.token });
    const guest = await join(room.code, { name: 'g' });
    await host.sock.next();
    host.sock.send({ t: 'opts', locked: true });
    expect(await host.sock.next()).toEqual({ t: 'opts', approval: false, password: false, locked: true, public: false });
    await guest.sock.next();

    const blocked = await join(room.code, { name: 'g2', did: 'g2' });
    expect(blocked.welcome).toEqual({ t: 'error', code: 'locked', fatal: true });

    guest.sock.close();
    await host.sock.next();
    const back = await join(room.code, { name: 'g', token: guest.sock.token });
    expect(back.welcome).toMatchObject({ t: 'welcome', n: 2 });
  });

  it('reports full', async () => {
    const room = await makeRoom({}, { SELFHOST_MAX_MEMBERS: '2' });
    expect(room.max).toBe(2);
    await join(room.code, { token: room.token });
    await join(room.code, { name: 'g1', did: 'g1' });
    const third = await join(room.code, { name: 'g2', did: 'g2' });
    expect(third.welcome).toEqual({ t: 'error', code: 'full', fatal: true });
  });

  it('resumes with a token, replacing the older socket', async () => {
    const room = await makeRoom();
    const host = await join(room.code, { token: room.token });
    const first = await join(room.code, { name: 'g', did: 'g' });
    await host.sock.next();

    const second = await join(room.code, { name: 'g renamed', did: 'g', token: first.sock.token });
    expect(second.welcome).toMatchObject({ n: 2, token: first.sock.token });
    expect(await first.sock.next()).toEqual({ t: 'left', n: 2, r: 'replaced' });
    expect((await first.sock.waitClosed()).code).toBe(1000);
    await host.sock.quiet();
    expect(host.sock.text).toEqual([]); // the member never left, nobody hears about it
  });

  it('treats an unknown token as no token', async () => {
    const room = await makeRoom();
    await join(room.code, { token: room.token });
    const guest = await join(room.code, { name: 'g', token: 'not-a-real-token' });
    expect(guest.welcome).toMatchObject({ t: 'welcome', n: 2 });
  });

  it('limits join attempts per ip', async () => {
    const room = await makeRoom();
    let limited = 0;
    for (let i = 0; i < 22; i++) {
      const res = await join(room.code, { name: `g${i}`, did: `g${i}`, pv: 9 }, '5.5.5.5');
      if (res.welcome.code === 'rate_limited') limited++;
      res.sock.close();
    }
    expect(limited).toBe(2);
    const other = await join(room.code, { name: 'ok', did: 'ok' }, '5.5.5.6');
    expect(other.welcome.t).toBe('welcome');
  });

  it('keeps a limited ip limited while other ips flood the join limiter', async () => {
    const room = await makeRoom();
    await inRoom(room.code, (instance: any) => {
      for (let i = 0; i < 511; i++) instance.joinRate(`2.0.${i >> 8}.${i & 255}`);
      for (let i = 0; i < 20; i++) instance.joinRate('2.1.0.1');
      expect(instance.joinRate('2.1.0.1')).toBe(false);
      for (let i = 0; i < 10; i++) instance.joinRate(`2.2.0.${i}`);
      expect(instance.joinRate('2.1.0.1')).toBe(false);
    });
  });

  it('refuses more than 8 sockets of one ip that have not joined yet', async () => {
    const room = await makeRoom();
    const idle = [];
    for (let i = 0; i < 8; i++) idle.push(await connect(room.code, '4.4.5.5'));
    const res = await call(`/v1/room/${room.code}`, { headers: { upgrade: 'websocket', 'cf-connecting-ip': '4.4.5.5' } });
    expect([res.status, await res.json()]).toEqual([429, { error: 'rate_limited' }]);
    (await connect(room.code, '4.4.5.6')).close();

    idle[0]!.send({ t: 'join', pv: 1, name: 'g', did: 'g', token: null, password: null });
    expect((await idle[0]!.next()).t).toBe('welcome');
    (await connect(room.code, '4.4.5.5')).close();
  });

  it('keeps at most 200 member records, dropping the oldest absent ones', { timeout: 30_000 }, async () => {
    const room = await makeRoom();
    await join(room.code, { token: room.token });
    const first = await join(room.code, { name: 'first', did: 'first' }, '3.0.0.1');
    first.sock.send({ t: 'leave' });
    await first.sock.waitClosed();
    for (let i = 0; i < 200; i++) {
      const guest = await join(room.code, { name: `g${i}`, did: `g${i}` }, `3.1.${i >> 8}.${i & 255}`);
      guest.sock.send({ t: 'leave' });
      await guest.sock.waitClosed();
    }

    await inRoom(room.code, async (_instance: any, state: DurableObjectState) => {
      const keys = [...(await state.storage.list({ prefix: 'm:' })).keys()];
      expect(keys).toHaveLength(200);
      expect(keys).toContain('m:1');
      expect(keys).not.toContain('m:2');
      expect(keys).not.toContain('m:3');
      expect(keys).toContain('m:4');
    });
    const back = await join(room.code, { name: 'first', did: 'first', token: first.sock.token }, '3.0.0.1');
    expect(back.welcome).toMatchObject({ t: 'welcome', n: 203 });
  });
});

describe('approval', () => {
  it('queues, announces and approves', async () => {
    const room = await makeRoom({ opts: { approval: true } });
    const host = await join(room.code, { token: room.token });
    expect(host.welcome.opts.approval).toBe(true);

    const guest = await join(room.code, { name: 'guest', did: 'g1' });
    expect(guest.welcome).toEqual({ t: 'pending' });
    const req = await host.sock.next();
    expect(req).toMatchObject({ t: 'joinreq', name: 'guest', did: 'g1' });

    host.sock.send({ t: 'approve', r: req.r, ok: true });
    expect(await guest.sock.next()).toMatchObject({ t: 'welcome', n: 2 });
    expect(await host.sock.next()).toEqual({ t: 'joined', n: 2, name: 'guest' });
  });

  it('rejects', async () => {
    const room = await makeRoom({ opts: { approval: true } });
    const host = await join(room.code, { token: room.token });
    const guest = await join(room.code, { name: 'guest', did: 'g1' });
    const req = await host.sock.next();
    host.sock.send({ t: 'approve', r: req.r, ok: false });
    expect(await guest.sock.next()).toEqual({ t: 'error', code: 'rejected', fatal: true });
    await host.sock.quiet();
    expect(host.sock.text.find((f) => f.t === 'joinreqgone')).toBeUndefined();
  });

  it('times a pending request out', async () => {
    const room = await makeRoom({ opts: { approval: true } });
    const host = await join(room.code, { token: room.token });
    const guest = await join(room.code, { name: 'guest', did: 'g1' });
    const req = await host.sock.next();
    expect(await guest.sock.next(2000)).toEqual({ t: 'error', code: 'timeout', fatal: true });
    expect(await host.sock.next(2000)).toEqual({ t: 'joinreqgone', r: req.r });
  });

  it('tells the host when a pending socket drops', async () => {
    const room = await makeRoom({ opts: { approval: true } });
    const host = await join(room.code, { token: room.token });
    const guest = await join(room.code, { name: 'guest', did: 'g1' });
    const req = await host.sock.next();
    guest.sock.close();
    expect(await host.sock.next()).toEqual({ t: 'joinreqgone', r: req.r });
  });

  it('caps pending requests per ip', async () => {
    const room = await makeRoom({ opts: { approval: true } });
    await join(room.code, { token: room.token });
    for (let i = 0; i < 3; i++) {
      const guest = await join(room.code, { name: `g${i}`, did: `g${i}` }, '4.4.4.4');
      expect(guest.welcome).toEqual({ t: 'pending' });
    }
    const fourth = await join(room.code, { name: 'g3', did: 'g3' }, '4.4.4.4');
    expect(fourth.welcome).toEqual({ t: 'error', code: 'rate_limited', fatal: true });
    const other = await join(room.code, { name: 'h', did: 'h' }, '4.4.4.5');
    expect(other.welcome).toEqual({ t: 'pending' });
  });

  it('refuses to queue while the host is offline', async () => {
    const room = await makeRoom({ opts: { approval: true } });
    const guest = await join(room.code, { name: 'guest', did: 'g1' });
    expect(guest.welcome).toEqual({ t: 'error', code: 'host_offline', fatal: true });
  });
});

describe('host commands', () => {
  it('forbids them to guests', async () => {
    const room = await makeRoom();
    await join(room.code, { token: room.token });
    const guest = await join(room.code, { name: 'g' });
    for (const frame of [
      { t: 'kick', n: 1 },
      { t: 'unban', id: 'x' },
      { t: 'approve', r: 'x', ok: true },
      { t: 'transfer', n: 1 },
      { t: 'successors', ns: [1] },
      { t: 'opts', locked: true },
      { t: 'close' },
    ]) {
      guest.sock.send(frame);
      expect(await guest.sock.next()).toEqual({ t: 'error', code: 'forbidden' });
    }
  });

  it('kicks, bans, lists and unbans', async () => {
    const room = await makeRoom();
    const host = await join(room.code, { token: room.token });
    const a = await join(room.code, { name: 'a', did: 'did-a' }, '1.2.3.4');
    const b = await join(room.code, { name: 'b', did: 'did-b' }, '1.2.3.5');
    await host.sock.next();
    await host.sock.next();
    await a.sock.next();

    host.sock.send({ t: 'kick', n: 2, ban: false });
    expect(await a.sock.next()).toEqual({ t: 'error', code: 'kicked', fatal: true });
    expect(await host.sock.next()).toEqual({ t: 'left', n: 2, r: 'kick' });
    expect(await b.sock.next()).toEqual({ t: 'left', n: 2, r: 'kick' });

    const again = await join(room.code, { name: 'a', did: 'did-a', token: a.sock.token }, '1.2.3.4');
    expect(again.welcome).toMatchObject({ t: 'welcome', n: 4 });
    await host.sock.next();
    await b.sock.next();

    host.sock.send({ t: 'kick', n: 3, ban: true });
    expect(await b.sock.next()).toEqual({ t: 'error', code: 'banned', fatal: true });
    expect(await host.sock.next()).toEqual({ t: 'left', n: 3, r: 'ban' });
    const bans = await host.sock.next();
    expect(bans.t).toBe('bans');
    expect(bans.list).toHaveLength(1);
    expect(bans.list[0].name).toBe('b');

    const banned = await join(room.code, { name: 'b', did: 'did-b' }, '9.8.7.6');
    expect(banned.welcome).toEqual({ t: 'error', code: 'banned', fatal: true });
    const bannedByIp = await join(room.code, { name: 'b2', did: 'other' }, '1.2.3.5');
    expect(bannedByIp.welcome).toEqual({ t: 'error', code: 'banned', fatal: true });

    host.sock.send({ t: 'unban', id: bans.list[0].id });
    expect(await host.sock.next()).toEqual({ t: 'bans', list: [] });
    const back = await join(room.code, { name: 'b', did: 'did-b' }, '1.2.3.5');
    expect(back.welcome.t).toBe('welcome');
  });

  it('sends the ban list right after welcome', async () => {
    const room = await makeRoom();
    const host = await join(room.code, { token: room.token });
    const a = await join(room.code, { name: 'a', did: 'did-a' });
    await host.sock.next();
    host.sock.send({ t: 'kick', n: 2, ban: true });
    await host.sock.next();
    await host.sock.next();
    host.sock.close();
    await wait(30);

    const again = await join(room.code, { name: 'host', did: 'host-did', token: room.token });
    expect(again.welcome.t).toBe('welcome');
    const bans = await again.sock.next();
    expect(bans.t).toBe('bans');
    expect(bans.list).toHaveLength(1);
    await a.sock.waitClosed();
  });

  it('rejects a bogus kick', async () => {
    const room = await makeRoom();
    const host = await join(room.code, { token: room.token });
    host.sock.send({ t: 'kick', n: 99 });
    expect(await host.sock.next()).toEqual({ t: 'error', code: 'bad_request' });
    host.sock.send({ t: 'kick', n: 1 });
    expect(await host.sock.next()).toEqual({ t: 'error', code: 'bad_request' });
  });

  it('transfers the host role', async () => {
    const room = await makeRoom();
    const host = await join(room.code, { token: room.token });
    const guest = await join(room.code, { name: 'g' });
    await host.sock.next();

    host.sock.send({ t: 'transfer', n: 9 });
    expect(await host.sock.next()).toEqual({ t: 'error', code: 'bad_request' });

    host.sock.send({ t: 'transfer', n: 2 });
    expect(await host.sock.next()).toEqual({ t: 'host', n: 2, online: true });
    expect(await guest.sock.next()).toEqual({ t: 'host', n: 2, online: true });

    host.sock.send({ t: 'opts', locked: true });
    expect(await host.sock.next()).toEqual({ t: 'error', code: 'forbidden' });
    guest.sock.send({ t: 'opts', locked: true });
    expect(await guest.sock.next()).toMatchObject({ t: 'opts', locked: true });
  });

  it('updates opts partially', async () => {
    const room = await makeRoom({ opts: { password: 'a' } });
    const host = await join(room.code, { token: room.token });
    host.sock.send({ t: 'opts', approval: true });
    expect(await host.sock.next()).toEqual({ t: 'opts', approval: true, password: true, locked: false, public: false });
    host.sock.send({ t: 'opts', password: null });
    expect(await host.sock.next()).toEqual({ t: 'opts', approval: true, password: false, locked: false, public: false });
    host.sock.send({ t: 'opts', approval: 'yes' });
    expect(await host.sock.next()).toEqual({ t: 'error', code: 'bad_request' });
    host.sock.send({ t: 'opts', password: '' });
    expect(await host.sock.next()).toEqual({ t: 'error', code: 'bad_request' });
  });

  it('closes the room', async () => {
    const room = await makeRoom();
    const host = await join(room.code, { token: room.token });
    const guest = await join(room.code, { name: 'g' });
    await host.sock.next();
    host.sock.send({ t: 'close' });
    expect(await guest.sock.next()).toEqual({ t: 'closed', r: 'host' });
    expect(await host.sock.next()).toEqual({ t: 'closed', r: 'host' });
    await guest.sock.waitClosed();
    await expect(join(room.code, { token: room.token })).rejects.toThrow(/upgrade failed 404/);
  });
});

describe('host loss', () => {
  it('promotes the lowest member after the grace period', async () => {
    const room = await makeRoom();
    const host = await join(room.code, { token: room.token });
    const a = await join(room.code, { name: 'a', did: 'a' });
    const b = await join(room.code, { name: 'b', did: 'b' });
    await host.sock.next();
    await host.sock.next();
    await a.sock.next();

    host.sock.close();
    await wait(600);
    expect(a.sock.text).toEqual([
      { t: 'left', n: 1, r: 'lost' },
      { t: 'host', n: 1, online: false },
      { t: 'host', n: 2, online: true },
    ]);
    expect(b.sock.text).toEqual(a.sock.text);
  });

  it('prefers successors', async () => {
    const room = await makeRoom();
    const host = await join(room.code, { token: room.token });
    const a = await join(room.code, { name: 'a', did: 'a' });
    const b = await join(room.code, { name: 'b', did: 'b' });
    await host.sock.next();
    await host.sock.next();
    host.sock.send({ t: 'successors', ns: [9, 3] });
    await wait(30);
    host.sock.close();

    expect(await a.sock.next()).toEqual({ t: 'joined', n: 3, name: 'b' });
    expect(await a.sock.next()).toEqual({ t: 'left', n: 1, r: 'lost' });
    expect(await a.sock.next()).toEqual({ t: 'host', n: 1, online: false });
    expect(await a.sock.next(2000)).toEqual({ t: 'host', n: 3, online: true });
    expect(b.welcome.n).toBe(3);
  });

  it('lets the host resume within the grace period', async () => {
    const room = await makeRoom();
    const host = await join(room.code, { token: room.token });
    const a = await join(room.code, { name: 'a', did: 'a' });
    await host.sock.next();
    host.sock.close();
    await a.sock.next();
    await a.sock.next();

    const back = await join(room.code, { name: 'host', did: 'host-did', token: room.token });
    expect(back.welcome).toMatchObject({ n: 1, host: 1, hostOnline: true });
    expect(await a.sock.next()).toEqual({ t: 'joined', n: 1, name: 'host' });
    expect(await a.sock.next()).toEqual({ t: 'host', n: 1, online: true });
    await a.sock.quiet(500);
    expect(a.sock.text).toEqual([]);
  });

  it('hands a room whose creator never connected to the first joiner', async () => {
    const room = await makeRoom();
    await wait(600);
    const guest = await join(room.code, { name: 'g', did: 'g' });
    expect(guest.welcome).toMatchObject({ n: 2, host: 2, hostOnline: true });
    guest.sock.send({ t: 'opts', locked: true });
    expect(await guest.sock.next()).toMatchObject({ t: 'opts', locked: true });
  });

  it('goes hostless with nobody connected and hands the role to the next joiner', async () => {
    const room = await makeRoom();
    const host = await join(room.code, { token: room.token });
    host.sock.close();
    await wait(600);

    const guest = await join(room.code, { name: 'g', did: 'g' });
    expect(guest.welcome).toMatchObject({ n: 2, host: 2, hostOnline: true });

    const old = await join(room.code, { name: 'host', did: 'host-did', token: room.token });
    expect(old.welcome).toMatchObject({ n: 1, host: 2, hostOnline: true });
  });
});

describe('liveness', () => {
  it('arms the alarm for the silence deadline of the members', async () => {
    const room = await makeRoom();
    const before = Date.now();
    await join(room.code, { token: room.token });
    await inRoom(room.code, async (_instance: any, state: DurableObjectState) => {
      const at = await state.storage.getAlarm();
      expect(at).toBeGreaterThanOrEqual(before + 150_000);
      expect(at).toBeLessThanOrEqual(Date.now() + 150_000);
    });
  });

  it('drops a silent host as lost, also after a hibernation, and promotes after the grace', async () => {
    const room = await makeRoom();
    const host = await join(room.code, { token: room.token });
    const a = await join(room.code, { name: 'a', did: 'a' });
    await host.sock.next();
    await inRoom(room.code, (instance: any) => {
      const ws = instance.index().get(1);
      instance.setAtt(ws, { ...instance.attOf(ws), ls: Date.now() - 1_000_000 });
    });
    await evictRoom(room.code);

    expect(await alarmRoom(room.code)).toBe(true);
    expect(await a.sock.next()).toEqual({ t: 'left', n: 1, r: 'lost' });
    expect(await a.sock.next()).toEqual({ t: 'host', n: 1, online: false });
    expect((await host.sock.waitClosed()).code).toBe(1000);
    expect(await a.sock.next(2000)).toEqual({ t: 'host', n: 2, online: true });
  });
});

describe('ping and lifetime', () => {
  it('answers ping with the server clock', async () => {
    const room = await makeRoom();
    const host = await join(room.code, { token: room.token });
    host.sock.send({ t: 'ping', c: 42 });
    const pong = await host.sock.next();
    expect(pong.t).toBe('pong');
    expect(pong.c).toBe(42);
    expect(typeof pong.s).toBe('number');
    host.sock.send({ t: 'ping' });
    expect(await host.sock.next()).toEqual({ t: 'error', code: 'bad_request' });
    host.sock.send({ t: 'nope' });
    expect(await host.sock.next()).toEqual({ t: 'error', code: 'bad_request' });
    host.sock.send('not json');
    expect(await host.sock.next()).toEqual({ t: 'error', code: 'bad_request' });
  });

  it('closes an idle room', async () => {
    const room = await makeRoom();
    const host = await join(room.code, { token: room.token });
    host.sock.close();
    await wait(1900);
    await expect(join(room.code, { token: room.token })).rejects.toThrow(/upgrade failed 404/);
  });
});
