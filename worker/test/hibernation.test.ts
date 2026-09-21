import { describe, expect, it } from 'vitest';
import { evictRoom as evict, header, join, makeRoom, parseHeader, wait } from './helpers';

describe('hibernation safety', () => {
  it('keeps routing, membership and host state across an eviction', async () => {
    const created = await makeRoom();
    const host = await join(created.code, { token: created.token, name: 'host' });
    const a = await join(created.code, { name: 'a', did: 'a' }, '7.0.0.1');
    const b = await join(created.code, { name: 'b', did: 'b' }, '7.0.0.2');
    await host.sock.next();
    await host.sock.next();
    await a.sock.next();

    await evict(created.code);

    a.sock.sendBin(header(0, 0, [1, 2, 3]));
    expect(parseHeader(await host.sock.nextBin())).toEqual({ route: 0, n: 2, payload: [1, 2, 3] });

    host.sock.sendBin(header(2, 3, [4]));
    expect(parseHeader(await b.sock.nextBin())).toEqual({ route: 2, n: 1, payload: [4] });

    await evict(created.code);

    host.sock.send({ t: 'opts', approval: true });
    expect(await a.sock.next()).toMatchObject({ t: 'opts', approval: true });
    expect(await b.sock.next()).toMatchObject({ t: 'opts', approval: true });
    expect(await host.sock.next()).toMatchObject({ t: 'opts', approval: true });

    await evict(created.code);

    host.sock.send({ t: 'kick', n: 3, ban: true });
    expect(await b.sock.next()).toEqual({ t: 'error', code: 'banned', fatal: true });
    expect(await a.sock.next()).toEqual({ t: 'left', n: 3, r: 'ban' });
    expect(await host.sock.next()).toEqual({ t: 'left', n: 3, r: 'ban' });
    expect((await host.sock.next()).t).toBe('bans');
  });

  it('keeps the room after an eviction and still resumes tokens', async () => {
    const created = await makeRoom();
    const host = await join(created.code, { token: created.token, name: 'host' });
    const guest = await join(created.code, { name: 'g', did: 'g' });
    await host.sock.next();
    guest.sock.close();
    await host.sock.next();

    await evict(created.code);

    const back = await join(created.code, { name: 'g', did: 'g', token: guest.sock.token });
    expect(back.welcome).toMatchObject({ t: 'welcome', n: 2, host: 1, hostOnline: true });
    expect(back.welcome.members).toEqual([
      { n: 1, name: 'host' },
      { n: 2, name: 'g' },
    ]);
  });

  it('still promotes through the alarm after an eviction', async () => {
    const created = await makeRoom();
    const host = await join(created.code, { token: created.token });
    const a = await join(created.code, { name: 'a', did: 'a' });
    await host.sock.next();

    host.sock.close();
    await wait(30);
    await evict(created.code);
    await wait(600);

    expect(a.sock.text).toEqual([
      { t: 'left', n: 1, r: 'lost' },
      { t: 'host', n: 1, online: false },
      { t: 'host', n: 2, online: true },
    ]);
  });
});
