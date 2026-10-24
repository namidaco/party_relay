import { describe, expect, it } from 'vitest';
import { sha256hex } from '../src/util';
import {
  type CreateBody,
  Sock,
  call,
  clearDirectory,
  connect,
  directory,
  evictRoom,
  inRoom,
  join,
  list,
  makeRoom,
  wait,
} from './helpers';

/** mirrors `DIRECTORY_REFRESH_MS` in vitest.config.ts */
const REFRESH = 400;

interface Room {
  code: string;
  host: Sock;
}

async function openRoom(extra: Partial<CreateBody> = {}): Promise<Room> {
  const room = await makeRoom({ opts: { public: true }, ...extra });
  const { sock } = await join(room.code, { token: room.token, name: 'host' });
  return { code: room.code, host: sock };
}

/** waits until the room handled everything sent so far, draining whatever it broadcast meanwhile. */
async function settle(sock: Sock): Promise<void> {
  sock.send({ t: 'ping', c: 7 });
  for (;;) {
    const frame = await sock.next();
    if (frame.t === 'pong' && frame.c === 7) return;
    if (frame.t === 'error') throw new Error(`unexpected ${JSON.stringify(frame)}`);
  }
}

async function summary(sock: Sock, frame: Record<string, unknown>): Promise<void> {
  sock.send({ t: 'summary', ...frame });
  await settle(sock);
}

function codes(res: { body: any }): string[] {
  return res.body.rooms.map((r: any) => r.code);
}

/** Points the room's directory calls at `dir`. */
async function fakeDirectory(code: string, dir: Record<string, (...args: any[]) => Promise<unknown>>): Promise<void> {
  await inRoom(code, (instance: any) => {
    instance.env = { ...instance.env, DIR: { idFromName: () => null, get: () => dir } };
    instance.dirStub = null;
  });
}

async function storedHid(code: string): Promise<string> {
  let hid = '';
  await inRoom(code, async (_instance: any, state: DurableObjectState) => {
    hid = (await state.storage.get<{ hid: string }>('st'))!.hid;
  });
  return hid;
}

describe('GET /v1/rooms', () => {
  it('is 404 with the directory off', async () => {
    const res = await call('/v1/rooms', undefined, { DIRECTORY: 'off' });
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: 'not_found' });
    expect((await (await call('/v1/info', undefined, { DIRECTORY: 'off' })).json<any>()).directory).toBe(false);
  });

  it('lists a public room once the host sends a summary', async () => {
    await clearDirectory();
    const room = await openRoom();
    expect((await list()).body).toEqual({ rooms: [], next: null });

    const before = Date.now();
    await summary(room.host, { name: ' chill \u0000room ' });
    const res = await list();
    expect(res.status).toBe(200);
    expect(res.body.next).toBeNull();
    expect(res.body.rooms).toHaveLength(1);

    const entry = res.body.rooms[0];
    expect(entry).toMatchObject({
      code: room.code,
      name: 'chill room',
      members: 1,
      max: 100,
      pv: 1,
      approval: false,
      password: false,
    });
    expect(entry.hid).toMatch(/^[0-9a-f]{8}$/);
    expect(entry.at).toBeGreaterThanOrEqual(before);
    expect('title' in entry).toBe(false);
    expect('artist' in entry).toBe(false);
  });

  it('never lists an unlisted room', async () => {
    await clearDirectory();
    const room = await openRoom({ opts: {} });
    expect((await join(room.code, { name: 'g', did: 'g' })).welcome.opts.public).toBe(false);
    await summary(room.host, { name: 'secret' });
    expect(codes(await list())).toEqual([]);
  });

  it('follows public, locked and the last member leaving', async () => {
    await clearDirectory();
    const room = await openRoom();
    await summary(room.host, { name: 'party' });
    expect(codes(await list())).toEqual([room.code]);

    for (const [frame, listed] of [
      [{ public: false }, false],
      [{ public: true }, true],
      [{ locked: true }, false],
      [{ locked: false }, true],
    ] as const) {
      room.host.send({ t: 'opts', ...frame });
      await settle(room.host);
      expect([frame, codes(await list())]).toEqual([frame, listed ? [room.code] : []]);
    }

    room.host.close();
    await wait(150);
    expect(codes(await list())).toEqual([]);
  });

  it('drops the entry when the room closes', async () => {
    await clearDirectory();
    const room = await openRoom();
    await summary(room.host, { name: 'bye' });
    room.host.send({ t: 'close' });
    await room.host.waitClosed();
    await wait(100);
    expect(codes(await list())).toEqual([]);
  });

  it('expires entries after the ttl, pruning them for good', async () => {
    await clearDirectory();
    const room = await openRoom();
    await summary(room.host, { name: 'ghost' });
    await wait(5);
    expect(codes(await list())).toEqual([room.code]);
    expect(codes(await list('', { DIRECTORY_TTL_MS: '0' }))).toEqual([]);
    expect(codes(await list())).toEqual([]);
  });

  it('coalesces member changes into the next refresh', async () => {
    await clearDirectory();
    const room = await openRoom();
    await summary(room.host, { name: 'throttled' });
    expect((await list()).body.rooms[0].members).toBe(1);

    await join(room.code, { name: 'g', did: 'g' });
    await settle(room.host);
    expect((await list()).body.rooms[0].members).toBe(1);

    // nothing else is sent to the room: it owes a push and flushes it on its own
    await wait(REFRESH + 300);
    expect((await list()).body.rooms[0].members).toBe(2);
  });

  it('orders by members, then refresh, then code, and pages', async () => {
    await clearDirectory();
    const rooms: Room[] = [];
    for (let i = 0; i < 3; i++) {
      const room = await openRoom();
      for (let g = 0; g < i; g++) await join(room.code, { name: `g${g}`, did: `g${i}-${g}` });
      await summary(room.host, { name: `room ${i}` });
      rooms.push(room);
    }

    const all = await list();
    expect(all.body.rooms.map((r: any) => r.members)).toEqual([3, 2, 1]);
    expect(codes(all)).toEqual([rooms[2]!.code, rooms[1]!.code, rooms[0]!.code]);

    const first = await list('?limit=2');
    expect(codes(first)).toEqual([rooms[2]!.code, rooms[1]!.code]);
    expect(typeof first.body.next).toBe('string');

    const second = await list(`?limit=2&after=${encodeURIComponent(first.body.next)}`);
    expect(codes(second)).toEqual([rooms[0]!.code]);
    expect(second.body.next).toBeNull();
  });

  it('breaks a tie with the newest refresh', async () => {
    await clearDirectory();
    const older = await openRoom();
    await summary(older.host, { name: 'older' });
    await wait(5);
    const newer = await openRoom();
    await summary(newer.host, { name: 'newer' });
    expect(codes(await list())).toEqual([newer.code, older.code]);
  });

  it('clamps limit and ignores a cursor it did not issue', async () => {
    await clearDirectory();
    const room = await openRoom();
    await summary(room.host, { name: 'only' });
    for (const query of ['?limit=0', '?limit=999', '?limit=abc', '?after=nonsense', '?after=1-2-3']) {
      const res = await list(query);
      expect([query, res.status]).toEqual([query, 200]);
      expect([query, codes(res)]).toEqual([query, [room.code]]);
    }
  });

  it('derives a stable hid from the creator that a plain hash can not reproduce', async () => {
    await clearDirectory();
    const one = await openRoom({ did: 'same-device' });
    const two = await openRoom({ did: 'same-device' });
    const other = await openRoom({ did: 'other-device' });
    await summary(one.host, { name: 'one' });
    await summary(two.host, { name: 'two' });
    await summary(other.host, { name: 'other' });

    const hids = new Map((await list()).body.rooms.map((r: any) => [r.code, r.hid]));
    expect(hids.get(one.code)).toMatch(/^[0-9a-f]{8}$/);
    expect(hids.get(one.code)).not.toBe((await sha256hex('same-device')).slice(0, 8));
    expect(hids.get(one.code)).toBe(await directory().hid('same-device'));
    expect(hids.get(two.code)).toBe(hids.get(one.code));
    expect(hids.get(other.code)).not.toBe(hids.get(one.code));
  });

  it('leaves the hid empty with the directory off or not answering', async () => {
    const off = await makeRoom({}, { DIRECTORY: 'off' });
    const down = await makeRoom({}, {
      DIR: {
        idFromName: () => null,
        get: () => ({
          hid: async () => {
            throw new Error('down');
          },
        }),
      } as any,
    });
    expect(await storedHid(off.code)).toBe('');
    expect(await storedHid(down.code)).toBe('');
  });

  it('serves a repeated page from the cache, past the rate limit', async () => {
    await clearDirectory();
    const room = await openRoom();
    await summary(room.host, { name: 'cached' });
    const overrides = { LIST_CACHE_MS: '5000', LIST_RATE_MAX: '1' };
    expect(codes(await list('?limit=41', overrides, '8.8.6.1'))).toEqual([room.code]);
    // spellings of the same page share its entry, a cursor that does not parse included
    for (const query of ['?limit=41', '?limit=041', '?limit=41&after=nonsense']) {
      const res = await list(query, overrides, '8.8.6.1');
      expect([query, res.status, codes(res)]).toEqual([query, 200, [room.code]]);
    }
    // a miss still counts against the limit, and its 429 is never cached
    expect((await list('?limit=42', overrides, '8.8.6.1')).status).toBe(429);
    expect((await list('?limit=42', overrides, '8.8.6.2')).status).toBe(200);
  });

  it('rate limits listing per ip', async () => {
    await clearDirectory();
    const overrides = { LIST_RATE_MAX: '3' };
    for (let i = 0; i < 3; i++) expect((await list('', overrides, '8.8.4.4')).status).toBe(200);
    const blocked = await list('', overrides, '8.8.4.4');
    expect(blocked.status).toBe(429);
    expect(blocked.body).toEqual({ error: 'rate_limited' });
    expect((await list('', overrides, '8.8.4.5')).status).toBe(200);
  });
});

describe('directory calls', () => {
  it('never writes back a room closed while a call was out', async () => {
    await clearDirectory();
    const room = await openRoom();
    await summary(room.host, { name: 'slow' });
    await fakeDirectory(room.code, { put: () => wait(200), remove: () => wait(200) });
    room.host.send({ t: 'opts', public: false });
    room.host.send({ t: 'close' });
    await room.host.waitClosed();
    await wait(300);
    await expect(connect(room.code)).rejects.toThrow(/upgrade failed 404/);
  });

  it('waits for the next refresh after a failed push', async () => {
    await clearDirectory();
    const room = await openRoom();
    await summary(room.host, { name: 'flaky' });
    let puts = 0;
    await fakeDirectory(room.code, {
      put: async () => {
        puts++;
        throw new Error('down');
      },
      remove: async () => {},
    });
    await wait(REFRESH + 50);
    for (let i = 0; i < 5; i++) await settle(room.host);
    expect(puts).toBe(1);
  });
});

describe('summary', () => {
  it('is host only and validated', async () => {
    await clearDirectory();
    const room = await openRoom();
    const guest = await join(room.code, { name: 'g', did: 'g' });
    expect(await room.host.next()).toMatchObject({ t: 'joined', n: 2 });
    guest.sock.send({ t: 'summary', name: 'nope' });
    expect(await guest.sock.next()).toEqual({ t: 'error', code: 'forbidden' });

    for (const frame of [
      { t: 'summary' },
      { t: 'summary', name: '   ' },
      { t: 'summary', name: 5 },
      { t: 'summary', name: 'x'.repeat(49) },
      { t: 'summary', name: 'ok', title: 't'.repeat(81) },
      { t: 'summary', name: 'ok', artist: 5 },
    ]) {
      room.host.send(frame);
      const answer = await room.host.next();
      expect([frame, answer]).toEqual([frame, { t: 'error', code: 'bad_request' }]);
    }
    expect(codes(await list())).toEqual([]);
  });

  it('keeps the latest one and clears title and artist', async () => {
    await clearDirectory();
    const room = await openRoom();
    await join(room.code, { name: 'g', did: 'g' });
    await summary(room.host, { name: 'x'.repeat(48), title: 'song', artist: 'band' });
    expect((await list()).body.rooms[0]).toMatchObject({
      name: 'x'.repeat(48),
      title: 'song',
      artist: 'band',
      members: 2,
    });

    await summary(room.host, { name: 'renamed', title: '', artist: null });
    const entry = (await list()).body.rooms[0];
    expect(entry.name).toBe('renamed');
    expect('title' in entry).toBe(false);
    expect('artist' in entry).toBe(false);
  });

  it('survives an eviction', async () => {
    await clearDirectory();
    const room = await openRoom();
    await summary(room.host, { name: 'remembered', title: 'song' });
    await evictRoom(room.code);
    await clearDirectory();

    room.host.send({ t: 'opts', public: false });
    await settle(room.host);
    room.host.send({ t: 'opts', public: true });
    await settle(room.host);

    expect((await list()).body.rooms[0]).toMatchObject({
      code: room.code,
      name: 'remembered',
      title: 'song',
      members: 1,
    });
  });
});
