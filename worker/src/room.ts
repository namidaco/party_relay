import { DurableObject } from 'cloudflare:workers';
import {
  BIN_MAX_GUEST,
  BIN_MAX_HOST,
  BURST_GUEST,
  BURST_HOST,
  JOIN_RATE_MAX,
  JOIN_RATE_WINDOW,
  MAX_BANS,
  MAX_PENDING,
  MAX_SUCCESSORS,
  PASSWORD_MAX,
  REFILL_GUEST,
  REFILL_HOST,
  num,
  timers,
  type Timers,
} from './limits';
import {
  HEADER_BYTES,
  ROUTE_BROADCAST,
  ROUTE_DIRECT,
  ROUTE_HOST,
  isNum,
  optString,
  parseControl,
  parseJoin,
  textTooLarge,
} from './envelope';
import type { Att, Ban, CreateInit, LeaveReason, MemberRec, RelayEnv, RoomState } from './types';
import { banId, ctEq, json, randomToken, reqId, sha256hex } from './util';

const HOST_ONLY = new Set(['kick', 'unban', 'approve', 'transfer', 'successors', 'opts', 'close']);

const TAKE_OK = 0;
const TAKE_DROP = 1;
const TAKE_CLOSE = 2;

interface Bucket {
  tokens: number;
  ts: number;
  warnedAt: number;
  drops: number;
  windowAt: number;
}

export class RoomDO extends DurableObject<RelayEnv> {
  private st: RoomState | null = null;
  private members: Map<number, MemberRec> | null = null;
  private idx: Map<number, WebSocket> | null = null;
  private atts = new WeakMap<WebSocket, Att>();
  private buckets = new WeakMap<WebSocket, Bucket>();
  private gone = new WeakSet<WebSocket>();
  private joinHits = new Map<string, number[]>();
  private alarmAt: number | null | undefined = undefined;
  private armPaused = false;
  private tmCache: Timers | null = null;

  private get tm(): Timers {
    return (this.tmCache ??= timers(this.env));
  }

  async create(init: CreateInit): Promise<{ ok: boolean; token?: string }> {
    if (await this.ctx.storage.get<RoomState>('st')) return { ok: false };
    const now = Date.now();
    const token = randomToken();
    const st: RoomState = {
      code: init.code,
      pv: init.pv,
      createdAt: now,
      maxMembers: init.maxMembers,
      tier: init.tier,
      ownerId: init.ownerId,
      hostN: 1,
      nextN: 2,
      approval: init.approval,
      pwHash: init.password != null ? await sha256hex(init.password) : null,
      locked: false,
      successors: [],
      bans: [],
      // the creator has not connected yet, the same grace as a host loss applies
      hostGraceUntil: now + this.tm.grace,
      idleSince: now,
    };
    const member: MemberRec = { n: 1, name: init.name, did: init.did, ip: init.ip, th: await sha256hex(token) };
    await this.ctx.storage.put({ st, 'm:1': member });
    this.st = st;
    this.members = new Map([[1, member]]);
    await this.arm();
    return { ok: true, token };
  }

  override async fetch(req: Request): Promise<Response> {
    const st = await this.load();
    if (!st) return json({ error: 'not_found' }, 404);
    const ip = new URL(req.url).searchParams.get('ip') ?? '0.0.0.0';
    const pair = new WebSocketPair();
    const server = pair[1]!;
    this.ctx.acceptWebSocket(server);
    this.setAtt(server, { ip, jd: Date.now() + this.tm.join });
    await this.arm();
    return new Response(null, { status: 101, webSocket: pair[0]! });
  }

  override async webSocketMessage(ws: WebSocket, message: ArrayBuffer | string): Promise<void> {
    try {
      await this.onMessage(ws, message);
    } catch {
      this.send(ws, { t: 'error', code: 'bad_request' });
    }
  }

  override async webSocketClose(ws: WebSocket): Promise<void> {
    await this.onGone(ws);
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    await this.onGone(ws);
  }

  private async onGone(ws: WebSocket): Promise<void> {
    try {
      await this.load();
      await this.drop(ws, 'lost');
    } catch {
      /* nothing to recover */
    }
  }

  override async alarm(): Promise<void> {
    const st = await this.load();
    this.alarmAt = null;
    if (!st) return;
    const now = Date.now();
    if (now >= st.createdAt + this.tm.lifetime) return await this.closeRoom('expired');
    if (st.idleSince != null && now >= st.idleSince + this.tm.idle) return await this.closeRoom('idle');

    this.armPaused = true;
    try {
      for (const ws of this.ctx.getWebSockets()) {
        if (this.gone.has(ws)) continue;
        const att = this.attOf(ws);
        if (!att) continue;
        if ((att.jd != null && now >= att.jd) || (att.pd != null && now >= att.pd)) {
          await this.drop(ws, 'lost', 'timeout');
        }
      }
      if (st.hostGraceUntil != null && now >= st.hostGraceUntil) await this.promote(st);
    } finally {
      this.armPaused = false;
    }
    await this.arm();
  }

  // ---------------------------------------------------------------- messages

  private async onMessage(ws: WebSocket, message: ArrayBuffer | string): Promise<void> {
    const st = this.st ?? (await this.load());
    if (!st) return this.fatal(ws, 'not_found');
    const att = this.attOf(ws);
    if (!att) return this.fatal(ws, 'bad_request');
    const joined = att.n != null;
    const isHost = joined && att.n === st.hostN;

    if (typeof message === 'string') {
      if (textTooLarge(message)) {
        if (!joined) return this.fatal(ws, 'bad_request');
        return this.send(ws, { t: 'error', code: 'too_large' });
      }
      const textVerdict = this.take(ws, isHost);
      if (textVerdict !== TAKE_OK) {
        if (textVerdict === TAKE_CLOSE) return await this.drop(ws, 'lost', 'rate_limited');
        return;
      }
      const m = parseControl(message);
      if (!m) {
        if (!joined && att.p == null) return this.fatal(ws, 'bad_request');
        return this.send(ws, { t: 'error', code: 'bad_request' });
      }
      if (!joined) {
        if (att.p != null) return this.send(ws, { t: 'error', code: 'bad_request' });
        if (m.t !== 'join') return this.fatal(ws, 'bad_request');
        return await this.onJoin(ws, att, st, m);
      }
      return await this.onControl(ws, att, st, m, isHost);
    }

    if (!joined) return this.fatal(ws, 'bad_request');
    if (message.byteLength > (isHost ? BIN_MAX_HOST : BIN_MAX_GUEST)) {
      return this.send(ws, { t: 'error', code: 'too_large' });
    }
    const verdict = this.take(ws, isHost);
    if (verdict !== TAKE_OK) {
      if (verdict === TAKE_CLOSE) return await this.drop(ws, 'lost', 'rate_limited');
      return;
    }
    this.onData(ws, att.n!, st, isHost, message);
  }

  private onData(ws: WebSocket, from: number, st: RoomState, isHost: boolean, buf: ArrayBuffer): void {
    if (buf.byteLength < HEADER_BYTES) return this.send(ws, { t: 'error', code: 'bad_request' });
    const view = new DataView(buf);
    const route = view.getUint8(0);

    if (route === ROUTE_HOST) {
      if (isHost || st.hostN == null) return;
      const host = this.index().get(st.hostN);
      if (!host) return;
      view.setUint32(1, from, false);
      return this.raw(host, buf);
    }
    if (route === ROUTE_BROADCAST || route === ROUTE_DIRECT) {
      if (!isHost) return this.send(ws, { t: 'error', code: 'forbidden' });
      const target = view.getUint32(1, false);
      view.setUint32(1, from, false);
      if (route === ROUTE_DIRECT) {
        const sock = this.index().get(target);
        if (sock) this.raw(sock, buf);
        return;
      }
      for (const [n, sock] of this.index()) {
        if (n === from || n === target) continue;
        this.raw(sock, buf);
      }
      return;
    }
    this.send(ws, { t: 'error', code: 'bad_request' });
  }

  // ------------------------------------------------------------------- join

  private async onJoin(ws: WebSocket, att: Att, st: RoomState, m: Record<string, unknown>): Promise<void> {
    if (!this.joinRate(att.ip)) return this.fatal(ws, 'rate_limited');
    const f = parseJoin(m);
    if (!f) return this.fatal(ws, 'bad_request');
    if (f.pv !== st.pv) return this.fatal(ws, 'version_mismatch', { pv: st.pv });

    // a ban revokes the member token, so a live token always belongs to a member that was not banned
    let n: number | null = null;
    if (f.token != null) n = await this.memberByToken(f.token);

    if (n == null) {
      if (this.banned(st, f.did, att.ip)) return this.fatal(ws, 'banned');
      if (st.locked) return this.fatal(ws, 'locked');
      if (st.pwHash != null) {
        const given = f.password != null ? await sha256hex(f.password) : '';
        if (!ctEq(given, st.pwHash)) return this.fatal(ws, 'bad_password');
      }
      if (this.index().size >= st.maxMembers) return this.fatal(ws, 'full');
      if (st.approval) {
        const host = st.hostN != null ? this.index().get(st.hostN) : undefined;
        if (!host) return this.fatal(ws, 'host_offline');
        if (this.pendingCount() >= MAX_PENDING) return this.fatal(ws, 'rate_limited');
        const r = reqId();
        this.setAtt(ws, { ip: att.ip, name: f.name, did: f.did, p: r, pd: Date.now() + this.tm.pending });
        this.send(host, { t: 'joinreq', r, name: f.name, did: f.did });
        this.send(ws, { t: 'pending' });
        return await this.arm();
      }
    }
    await this.admit(ws, st, n, f.name, f.did, att.ip, f.token);
  }

  private async admit(
    ws: WebSocket,
    st: RoomState,
    known: number | null,
    name: string,
    did: string,
    ip: string,
    presented: string | null,
  ): Promise<void> {
    const members = await this.ensureMembers();
    let n = known;
    let token = presented;
    let rec = n != null ? members.get(n) : undefined;
    if (n == null || rec == null || token == null) {
      n = st.nextN++;
      token = randomToken();
      rec = { n, name, did, ip, th: await sha256hex(token) };
    } else {
      rec = { ...rec, name, did, ip };
    }
    members.set(n, rec);

    const prev = this.index().get(n);
    const replacing = prev != null && prev !== ws;
    const prevHostN = st.hostN;
    const wasHostOnline = prevHostN != null && this.index().has(prevHostN);
    if (replacing) await this.drop(prev, 'replaced');

    if (st.hostN == null) st.hostN = n;
    const isHost = st.hostN === n;
    if (isHost) st.hostGraceUntil = null;
    st.idleSince = null;

    this.setAtt(ws, { ip, n, name, did });
    this.index().set(n, ws);
    await this.ctx.storage.put({ st, [`m:${n}`]: rec });

    const list: { n: number; name: string }[] = [];
    for (const [mn, sock] of this.index()) list.push({ n: mn, name: this.attOf(sock)?.name ?? '' });
    list.sort((a, b) => a.n - b.n);

    this.send(ws, {
      t: 'welcome',
      n,
      token,
      host: st.hostN,
      hostOnline: st.hostN != null && this.index().has(st.hostN),
      pv: st.pv,
      max: st.maxMembers,
      now: Date.now(),
      opts: this.opts(st),
      members: list,
    });
    if (isHost && st.bans.length > 0) this.sendBans(ws, st);
    // replacing a live socket is not a join, the member never left
    if (!replacing) this.broadcast({ t: 'joined', n, name }, n);
    if (isHost && (st.hostN !== prevHostN || !wasHostOnline)) this.broadcast({ t: 'host', n, online: true }, n);
    await this.arm();
  }

  // ---------------------------------------------------------------- control

  private async onControl(
    ws: WebSocket,
    att: Att,
    st: RoomState,
    m: Record<string, unknown>,
    isHost: boolean,
  ): Promise<void> {
    const t = m.t as string;
    if (t === 'ping') {
      if (typeof m.c !== 'number') return this.send(ws, { t: 'error', code: 'bad_request' });
      return this.send(ws, { t: 'pong', c: m.c, s: Date.now() });
    }
    if (t === 'leave') return await this.drop(ws, 'leave');
    if (!HOST_ONLY.has(t)) return this.send(ws, { t: 'error', code: 'bad_request' });
    if (!isHost) return this.send(ws, { t: 'error', code: 'forbidden' });

    switch (t) {
      case 'kick':
        return await this.onKick(ws, att, st, m);
      case 'unban':
        return await this.onUnban(ws, st, m);
      case 'approve':
        return await this.onApprove(ws, st, m);
      case 'transfer':
        return await this.onTransfer(ws, st, m);
      case 'successors':
        return await this.onSuccessors(ws, st, m);
      case 'opts':
        return await this.onOpts(ws, st, m);
      case 'close':
        return await this.closeRoom('host');
      default:
        return;
    }
  }

  private async onKick(ws: WebSocket, att: Att, st: RoomState, m: Record<string, unknown>): Promise<void> {
    const target = m.n;
    if (!isNum(target) || target === att.n) return this.send(ws, { t: 'error', code: 'bad_request' });
    const members = await this.ensureMembers();
    const rec = members.get(target);
    const sock = this.index().get(target);
    if (!rec && !sock) return this.send(ws, { t: 'error', code: 'bad_request' });
    const ban = m.ban === true;

    if (ban) {
      const entry: Ban = {
        id: banId(),
        name: rec?.name ?? (sock ? (this.attOf(sock)?.name ?? '') : ''),
        did: rec?.did ?? '',
        ip: rec?.ip ?? '',
      };
      st.bans.push(entry);
      while (st.bans.length > MAX_BANS) st.bans.shift();
    }
    if (rec) {
      members.delete(target);
      await this.ctx.storage.delete(`m:${target}`);
    }
    await this.ctx.storage.put('st', st);
    if (sock) await this.drop(sock, ban ? 'ban' : 'kick', ban ? 'banned' : 'kicked');
    if (ban) this.sendBans(ws, st);
  }

  private async onUnban(ws: WebSocket, st: RoomState, m: Record<string, unknown>): Promise<void> {
    const id = m.id;
    if (typeof id !== 'string' || id.length < 1 || id.length > 64) {
      return this.send(ws, { t: 'error', code: 'bad_request' });
    }
    st.bans = st.bans.filter((b) => b.id !== id);
    await this.ctx.storage.put('st', st);
    this.sendBans(ws, st);
  }

  private async onApprove(ws: WebSocket, st: RoomState, m: Record<string, unknown>): Promise<void> {
    const r = m.r;
    if (typeof r !== 'string') return this.send(ws, { t: 'error', code: 'bad_request' });
    let target: WebSocket | null = null;
    for (const sock of this.ctx.getWebSockets()) {
      if (this.gone.has(sock)) continue;
      if (this.attOf(sock)?.p === r) {
        target = sock;
        break;
      }
    }
    if (!target) return this.send(ws, { t: 'error', code: 'bad_request' });
    const att = this.attOf(target)!;
    // resolved by the host, no `joinreqgone` for it
    this.setAtt(target, { ip: att.ip, name: att.name, did: att.did });
    if (m.ok !== true) return await this.drop(target, 'lost', 'rejected');
    if (this.index().size >= st.maxMembers) return await this.drop(target, 'lost', 'full');
    await this.admit(target, st, null, att.name ?? '', att.did ?? '', att.ip, null);
  }

  private async onTransfer(ws: WebSocket, st: RoomState, m: Record<string, unknown>): Promise<void> {
    const target = m.n;
    if (!isNum(target)) return this.send(ws, { t: 'error', code: 'bad_request' });
    if (!this.index().has(target)) return this.send(ws, { t: 'error', code: 'bad_request' });
    st.hostN = target;
    st.hostGraceUntil = null;
    await this.ctx.storage.put('st', st);
    this.broadcast({ t: 'host', n: target, online: true });
    await this.arm();
  }

  private async onSuccessors(ws: WebSocket, st: RoomState, m: Record<string, unknown>): Promise<void> {
    const ns = m.ns;
    if (!Array.isArray(ns) || ns.length > MAX_SUCCESSORS || !ns.every(isNum)) {
      return this.send(ws, { t: 'error', code: 'bad_request' });
    }
    st.successors = ns as number[];
    await this.ctx.storage.put('st', st);
  }

  private async onOpts(ws: WebSocket, st: RoomState, m: Record<string, unknown>): Promise<void> {
    if ('approval' in m) {
      if (typeof m.approval !== 'boolean') return this.send(ws, { t: 'error', code: 'bad_request' });
    }
    if ('locked' in m) {
      if (typeof m.locked !== 'boolean') return this.send(ws, { t: 'error', code: 'bad_request' });
    }
    let pwHash: string | null | undefined;
    if ('password' in m) {
      const p = optString(m.password, PASSWORD_MAX);
      if (p === undefined) return this.send(ws, { t: 'error', code: 'bad_request' });
      pwHash = p == null ? null : await sha256hex(p);
    }
    if ('approval' in m) st.approval = m.approval as boolean;
    if ('locked' in m) st.locked = m.locked as boolean;
    if (pwHash !== undefined) st.pwHash = pwHash;
    await this.ctx.storage.put('st', st);
    this.broadcast({ t: 'opts', ...this.opts(st) });
  }

  // ------------------------------------------------------------- membership

  private async drop(ws: WebSocket, reason: LeaveReason, fatalCode?: string, extra?: object): Promise<void> {
    if (this.gone.has(ws)) return;
    const idx = this.index(); // built before the socket is marked gone
    this.gone.add(ws);
    const st = this.st ?? (await this.load());
    const att = this.attOf(ws);
    let dirty = false;

    if (att) {
      if (att.p != null && st) this.notifyHost(st, { t: 'joinreqgone', r: att.p });
      if (att.n != null && idx.get(att.n) === ws) {
        idx.delete(att.n);
        if (reason === 'replaced') {
          this.send(ws, { t: 'left', n: att.n, r: reason });
        } else {
          this.broadcast({ t: 'left', n: att.n, r: reason });
          if (st && st.hostN === att.n) {
            st.hostGraceUntil = Date.now() + this.tm.grace;
            dirty = true;
            this.broadcast({ t: 'host', n: att.n, online: false });
          }
          if (st && this.index().size === 0) {
            st.idleSince = Date.now();
            dirty = true;
          }
        }
      }
    }
    this.atts.delete(ws);

    if (fatalCode) this.send(ws, { t: 'error', code: fatalCode, fatal: true, ...extra });
    try {
      ws.close(fatalCode ? 4000 : 1000, fatalCode ?? reason);
    } catch {
      /* already gone */
    }
    if (dirty && st) await this.ctx.storage.put('st', st);
    await this.arm();
  }

  private async promote(st: RoomState): Promise<void> {
    st.hostGraceUntil = null;
    const idx = this.index();
    let next: number | null = null;
    for (const n of st.successors) {
      if (idx.has(n)) {
        next = n;
        break;
      }
    }
    if (next == null) {
      for (const n of idx.keys()) if (next == null || n < next) next = n;
    }
    st.hostN = next;
    await this.ctx.storage.put('st', st);
    if (next != null) this.broadcast({ t: 'host', n: next, online: true });
  }

  private async closeRoom(reason: 'host' | 'idle' | 'expired'): Promise<void> {
    const st = this.st ?? (await this.load());
    const frame = JSON.stringify({ t: 'closed', r: reason });
    for (const ws of this.ctx.getWebSockets()) {
      this.gone.add(ws);
      try {
        ws.send(frame);
      } catch {
        /* already gone */
      }
      try {
        ws.close(1000, 'closed');
      } catch {
        /* already gone */
      }
    }
    this.st = null;
    this.members = null;
    this.idx = null;
    this.alarmAt = null;
    await this.ctx.storage.deleteAll();
    await this.ctx.storage.deleteAlarm();
    if (st?.ownerId) {
      try {
        await this.env.OWNER.get(this.env.OWNER.idFromName(st.ownerId)).release(st.code);
      } catch {
        /* the owner entry expires on its own */
      }
    }
  }

  // ----------------------------------------------------------------- limits

  private take(ws: WebSocket, isHost: boolean): number {
    const now = Date.now();
    const cap = isHost ? BURST_HOST : BURST_GUEST;
    let b = this.buckets.get(ws);
    if (!b) {
      b = { tokens: cap, ts: now, warnedAt: 0, drops: 0, windowAt: now };
      this.buckets.set(ws, b);
    }
    const refill = isHost ? REFILL_HOST : REFILL_GUEST;
    const tokens = Math.min(cap, b.tokens + ((now - b.ts) / 1000) * refill);
    b.ts = now;
    if (tokens >= 1) {
      b.tokens = tokens - 1;
      return TAKE_OK;
    }
    b.tokens = tokens;
    if (now - b.windowAt >= 60_000) {
      b.windowAt = now;
      b.drops = 0;
    }
    if (++b.drops >= this.tm.dropClose) return TAKE_CLOSE;
    if (now - b.warnedAt >= 1000) {
      b.warnedAt = now;
      this.send(ws, { t: 'error', code: 'rate_limited' });
    }
    return TAKE_DROP;
  }

  private joinRate(ip: string): boolean {
    const max = num(this.env.JOIN_RATE_MAX, JOIN_RATE_MAX);
    if (max <= 0) return true;
    const now = Date.now();
    if (this.joinHits.size > 512) this.joinHits.clear();
    const hits = (this.joinHits.get(ip) ?? []).filter((t) => now - t < JOIN_RATE_WINDOW);
    const allowed = hits.length < max;
    if (allowed) hits.push(now);
    this.joinHits.set(ip, hits);
    return allowed;
  }

  private banned(st: RoomState, did: string, ip: string): boolean {
    for (const b of st.bans) {
      if ((b.did !== '' && b.did === did) || (b.ip !== '' && b.ip === ip)) return true;
    }
    return false;
  }

  private pendingCount(): number {
    let count = 0;
    for (const ws of this.ctx.getWebSockets()) {
      if (this.gone.has(ws)) continue;
      if (this.attOf(ws)?.p != null) count++;
    }
    return count;
  }

  private async memberByToken(token: string): Promise<number | null> {
    const th = await sha256hex(token);
    let found: number | null = null;
    for (const rec of (await this.ensureMembers()).values()) {
      if (ctEq(rec.th, th)) found = rec.n;
    }
    return found;
  }

  // ------------------------------------------------------------------ state

  private async load(): Promise<RoomState | null> {
    if (this.st) return this.st;
    const st = await this.ctx.storage.get<RoomState>('st');
    if (!st) return null;
    this.st = st;
    return st;
  }

  private async ensureMembers(): Promise<Map<number, MemberRec>> {
    if (this.members) return this.members;
    const map = new Map<number, MemberRec>();
    for (const rec of (await this.ctx.storage.list<MemberRec>({ prefix: 'm:' })).values()) map.set(rec.n, rec);
    this.members = map;
    return map;
  }

  private index(): Map<number, WebSocket> {
    if (this.idx) return this.idx;
    const map = new Map<number, WebSocket>();
    for (const ws of this.ctx.getWebSockets()) {
      if (this.gone.has(ws)) continue;
      const att = this.attOf(ws);
      if (att?.n != null) map.set(att.n, ws);
    }
    this.idx = map;
    return map;
  }

  private attOf(ws: WebSocket): Att | null {
    const cached = this.atts.get(ws);
    if (cached) return cached;
    let att: Att | null = null;
    try {
      att = (ws.deserializeAttachment() as Att | null) ?? null;
    } catch {
      return null;
    }
    if (att) this.atts.set(ws, att);
    return att;
  }

  private setAtt(ws: WebSocket, att: Att): void {
    this.atts.set(ws, att);
    try {
      ws.serializeAttachment(att);
    } catch {
      /* the socket is going away anyway */
    }
  }

  private async arm(): Promise<void> {
    if (this.armPaused) return;
    const st = this.st;
    if (!st) return;
    let next = st.createdAt + this.tm.lifetime;
    if (st.idleSince != null) next = Math.min(next, st.idleSince + this.tm.idle);
    if (st.hostGraceUntil != null) next = Math.min(next, st.hostGraceUntil);
    for (const ws of this.ctx.getWebSockets()) {
      if (this.gone.has(ws)) continue;
      const att = this.attOf(ws);
      if (!att) continue;
      if (att.jd != null) next = Math.min(next, att.jd);
      if (att.pd != null) next = Math.min(next, att.pd);
    }
    if (this.alarmAt === undefined) this.alarmAt = await this.ctx.storage.getAlarm();
    if (this.alarmAt === next) return;
    await this.ctx.storage.setAlarm(next);
    this.alarmAt = next;
  }

  // ------------------------------------------------------------------- send

  private opts(st: RoomState): { approval: boolean; password: boolean; locked: boolean } {
    return { approval: st.approval, password: st.pwHash != null, locked: st.locked };
  }

  private sendBans(ws: WebSocket, st: RoomState): void {
    this.send(ws, { t: 'bans', list: st.bans.map((b) => ({ id: b.id, name: b.name })) });
  }

  private fatal(ws: WebSocket, code: string, extra?: object): Promise<void> {
    return this.drop(ws, 'lost', code, extra);
  }

  private send(ws: WebSocket, frame: object): void {
    try {
      ws.send(JSON.stringify(frame));
    } catch {
      /* already gone */
    }
  }

  private raw(ws: WebSocket, buf: ArrayBuffer): void {
    try {
      ws.send(buf);
    } catch {
      /* already gone */
    }
  }

  private notifyHost(st: RoomState, frame: object): void {
    if (st.hostN == null) return;
    const ws = this.index().get(st.hostN);
    if (ws) this.send(ws, frame);
  }

  private broadcast(frame: object, exceptN?: number): void {
    const text = JSON.stringify(frame);
    for (const [n, ws] of this.index()) {
      if (n === exceptN) continue;
      try {
        ws.send(text);
      } catch {
        /* already gone */
      }
    }
  }
}
