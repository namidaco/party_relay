import { describe, expect, it } from 'vitest';
import { header, join, makeRoom, parseHeader } from './helpers';

async function room() {
  const created = await makeRoom();
  const host = await join(created.code, { token: created.token, name: 'host' });
  const a = await join(created.code, { name: 'a', did: 'a' });
  const b = await join(created.code, { name: 'b', did: 'b' });
  await host.sock.next();
  await host.sock.next();
  await a.sock.next();
  return { created, host: host.sock, a: a.sock, b: b.sock };
}

describe('data frames', () => {
  it('routes a guest frame to the host with the sender number', async () => {
    const { host, a } = await room();
    a.sendBin(header(0, 999, [1, 2, 3, 250]));
    expect(parseHeader(await host.nextBin())).toEqual({ route: 0, n: 2, payload: [1, 2, 3, 250] });
  });

  it('drops route 0 from the host and while the host is offline', async () => {
    const { created, host, a, b } = await room();
    host.sendBin(header(0, 0, [9]));
    await a.quiet();
    expect(a.bin).toHaveLength(0);
    expect(b.bin).toHaveLength(0);

    host.close();
    await a.next();
    await a.next();
    a.sendBin(header(0, 0, [9]));
    await a.quiet();
    expect(a.text.filter((f) => f.t === 'error')).toHaveLength(0);
    expect(created.code).toBeTruthy();
  });

  it('broadcasts route 1 and honours the skip', async () => {
    const { host, a, b } = await room();
    host.sendBin(header(1, 0, [7, 7]));
    expect(parseHeader(await a.nextBin())).toEqual({ route: 1, n: 1, payload: [7, 7] });
    expect(parseHeader(await b.nextBin())).toEqual({ route: 1, n: 1, payload: [7, 7] });

    host.sendBin(header(1, 2, [8]));
    expect(parseHeader(await b.nextBin())).toEqual({ route: 1, n: 1, payload: [8] });
    await a.quiet();
    expect(a.bin).toHaveLength(0);
  });

  it('sends route 2 to one member', async () => {
    const { host, a, b } = await room();
    host.sendBin(header(2, 3, [4, 5]));
    expect(parseHeader(await b.nextBin())).toEqual({ route: 2, n: 1, payload: [4, 5] });
    await a.quiet();
    expect(a.bin).toHaveLength(0);

    host.sendBin(header(2, 77, [4]));
    await a.quiet();
    expect(host.text).toHaveLength(0);
  });

  it('forbids route 1 and 2 to guests and rejects unknown routes', async () => {
    const { host, a } = await room();
    a.sendBin(header(1, 0, [1]));
    expect(await a.next()).toEqual({ t: 'error', code: 'forbidden' });
    a.sendBin(header(2, 1, [1]));
    expect(await a.next()).toEqual({ t: 'error', code: 'forbidden' });
    a.sendBin(header(5, 0, [1]));
    expect(await a.next()).toEqual({ t: 'error', code: 'bad_request' });
    a.sendBin(new Uint8Array([0, 1]));
    expect(await a.next()).toEqual({ t: 'error', code: 'bad_request' });
    await host.quiet();
    expect(host.bin).toHaveLength(0);
  });

  it('enforces the binary size limits', async () => {
    const { host, a } = await room();
    a.sendBin(header(0, 0, new Array(16 * 1024 - 5).fill(1)));
    expect((await host.nextBin()).byteLength).toBe(16 * 1024);

    a.sendBin(header(0, 0, new Array(16 * 1024).fill(1)));
    expect(await a.next()).toEqual({ t: 'error', code: 'too_large' });

    host.sendBin(header(1, 0, new Array(64 * 1024).fill(2)));
    expect((await a.nextBin()).byteLength).toBe(64 * 1024 + 5);

    host.sendBin(header(1, 0, new Array(1024 * 1024).fill(2)));
    expect(await host.next()).toEqual({ t: 'error', code: 'too_large' });
  });

  it('enforces the text size limit', async () => {
    const { a } = await room();
    a.send({ t: 'ping', c: 1, pad: 'x'.repeat(2100) });
    expect(await a.next()).toEqual({ t: 'error', code: 'too_large' });
    a.send({ t: 'ping', c: 1 });
    expect((await a.next()).t).toBe('pong');
  });

  it('rate limits a guest burst', async () => {
    const { host, a } = await room();
    for (let i = 0; i < 60; i++) a.sendBin(header(0, 0, [i]));
    await a.quiet(300);
    expect(host.bin.length).toBeGreaterThanOrEqual(39); // the join frame took one token
    expect(host.bin.length).toBeLessThan(55);
    const errors = a.text.filter((f) => f.t === 'error' && f.code === 'rate_limited');
    expect(errors.length).toBeGreaterThanOrEqual(1);
    expect(errors.length).toBeLessThanOrEqual(2);
    expect(a.closed).toBeNull();
  });

  it('closes a socket that keeps overflowing', async () => {
    const created = await makeRoom();
    const host = await join(created.code, { token: created.token });
    const a = await join(created.code, { name: 'a', did: 'a' });
    await host.sock.next();
    for (let i = 0; i < 260; i++) a.sock.sendBin(header(0, 0, [i & 255]));
    const closed = await a.sock.waitClosed();
    expect(closed.code).toBe(4000);
    expect(a.sock.text.pop()).toEqual({ t: 'error', code: 'rate_limited', fatal: true });
  });
});
