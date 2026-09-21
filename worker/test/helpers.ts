import { env } from 'cloudflare:test';
import worker from '../src/index';
import type { RelayEnv } from '../src/types';

export const ENV = env as unknown as RelayEnv;

export function wait(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

export function call(path: string, init?: RequestInit, overrides?: Partial<RelayEnv>): Promise<Response> {
  const req = new Request(`http://relay.test${path}`, init);
  return worker.fetch(req, { ...ENV, ...overrides } as RelayEnv);
}

export interface CreateBody {
  pv?: unknown;
  name?: unknown;
  did?: unknown;
  auth?: unknown;
  opts?: unknown;
}

export async function post(
  body: unknown,
  overrides?: Partial<RelayEnv>,
  ip = '10.0.0.1',
): Promise<{ status: number; body: any }> {
  const res = await call(
    '/v1/rooms',
    {
      method: 'POST',
      body: JSON.stringify(body),
      headers: { 'content-type': 'application/json', 'cf-connecting-ip': ip },
    },
    overrides,
  );
  return { status: res.status, body: await res.json() };
}

export async function makeRoom(
  extra: Partial<CreateBody> = {},
  overrides?: Partial<RelayEnv>,
): Promise<{ code: string; token: string; max: number; tier: string }> {
  const { status, body } = await post({ pv: 1, name: 'host', did: 'host-did', auth: null, ...extra }, overrides);
  if (status !== 200) throw new Error(`create failed ${status} ${JSON.stringify(body)}`);
  return body;
}

export class Sock {
  readonly text: any[] = [];
  readonly bin: ArrayBuffer[] = [];
  closed: { code: number; reason: string } | null = null;
  n = 0;
  token = '';

  constructor(private ws: WebSocket) {
    ws.addEventListener('message', (e: MessageEvent) => {
      if (typeof e.data === 'string') this.text.push(JSON.parse(e.data));
      else this.bin.push(e.data as ArrayBuffer);
    });
    ws.addEventListener('close', (e: CloseEvent) => {
      this.closed = { code: e.code, reason: e.reason };
    });
    ws.accept();
  }

  send(frame: unknown): void {
    this.ws.send(JSON.stringify(frame));
  }

  sendBin(buf: ArrayBuffer | Uint8Array): void {
    this.ws.send(buf instanceof Uint8Array ? (buf.buffer.slice(0) as ArrayBuffer) : buf);
  }

  close(): void {
    try {
      this.ws.close(1000, 'bye');
    } catch {
      /* already closed */
    }
  }

  async next(timeoutMs = 3000): Promise<any> {
    const start = Date.now();
    while (this.text.length === 0) {
      if (this.closed) throw new Error(`socket closed ${this.closed.code} ${this.closed.reason}`);
      if (Date.now() - start > timeoutMs) throw new Error('timeout waiting for a text frame');
      await wait(5);
    }
    return this.text.shift();
  }

  async nextBin(timeoutMs = 3000): Promise<ArrayBuffer> {
    const start = Date.now();
    while (this.bin.length === 0) {
      if (this.closed) throw new Error(`socket closed ${this.closed.code} ${this.closed.reason}`);
      if (Date.now() - start > timeoutMs) throw new Error('timeout waiting for a binary frame');
      await wait(5);
    }
    return this.bin.shift()!;
  }

  async waitClosed(timeoutMs = 3000): Promise<{ code: number; reason: string }> {
    const start = Date.now();
    while (!this.closed) {
      if (Date.now() - start > timeoutMs) throw new Error('timeout waiting for close');
      await wait(5);
    }
    return this.closed;
  }

  async quiet(ms = 120): Promise<void> {
    await wait(ms);
  }
}

export async function connect(code: string, ip = '10.0.0.1', overrides?: Partial<RelayEnv>): Promise<Sock> {
  const res = await call(`/v1/room/${code}`, { headers: { upgrade: 'websocket', 'cf-connecting-ip': ip } }, overrides);
  if (res.status !== 101 || !res.webSocket) throw new Error(`upgrade failed ${res.status}`);
  return new Sock(res.webSocket);
}

export async function join(
  code: string,
  frame: Record<string, unknown>,
  ip = '10.0.0.1',
): Promise<{ sock: Sock; welcome: any }> {
  const sock = await connect(code, ip);
  sock.send({ t: 'join', pv: 1, name: 'x', did: 'd', token: null, password: null, ...frame });
  const welcome = await sock.next();
  if (welcome.t === 'welcome') {
    sock.n = welcome.n;
    sock.token = welcome.token;
  }
  return { sock, welcome };
}

export function header(route: number, n: number, payload: number[] = []): Uint8Array {
  const buf = new Uint8Array(5 + payload.length);
  const view = new DataView(buf.buffer);
  view.setUint8(0, route);
  view.setUint32(1, n, false);
  buf.set(payload, 5);
  return buf;
}

export function parseHeader(buf: ArrayBuffer): { route: number; n: number; payload: number[] } {
  const view = new DataView(buf);
  return {
    route: view.getUint8(0),
    n: view.getUint32(1, false),
    payload: [...new Uint8Array(buf).slice(5)],
  };
}
