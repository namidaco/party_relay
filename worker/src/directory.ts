import { DurableObject } from 'cloudflare:workers';
import { DIR_MAX_ENTRIES, DIR_TTL_MS, LIST_RATE_IPS, LIST_RATE_WINDOW, num } from './limits';
import type { DirEntry, ListQuery, ListResult, PublicRoom, RelayEnv } from './types';
import { IpLimiter, hmacHex, normalizeCode } from './util';

const PREFIX = 'r:';
const SECRET = 'hidkey';

interface SortKey {
  members: number;
  at: number;
  code: string;
}

/**
 * The single directory instance (`idFromName("global")`): one entry per listed public room, pushed by its room.
 * Entries are pruned on read, so a room that dies without unlisting itself falls out after the ttl.
 * It also keeps the secret behind every `hid`, generated on first use and never handed out.
 */
export class DirectoryDO extends DurableObject<RelayEnv> {
  private entries: Map<string, DirEntry> | null = null;
  private sorted: DirEntry[] | null = null;
  private hits = new IpLimiter(LIST_RATE_WINDOW, LIST_RATE_IPS);
  private secret: Promise<CryptoKey> | null = null;

  /** First 8 hex of the hmac of a creator identity: stable per creator, and not reversible without the secret. */
  async hid(identity: string): Promise<string> {
    const secret = (this.secret ??= this.loadSecret().catch((e: unknown) => {
      this.secret = null;
      throw e;
    }));
    const key = await secret;
    const mac = await hmacHex(key, identity);
    return mac.slice(0, 8);
  }

  async put(entry: DirEntry): Promise<void> {
    const entries = await this.ensure();
    if (!entries.has(entry.code) && entries.size >= DIR_MAX_ENTRIES) {
      await this.prune(entries, num(this.env.DIRECTORY_TTL_MS, DIR_TTL_MS));
      if (entries.size >= DIR_MAX_ENTRIES) return;
    }
    entries.set(entry.code, entry);
    this.sorted = null;
    await this.ctx.storage.put(PREFIX + entry.code, entry);
  }

  async remove(code: string): Promise<void> {
    const entries = await this.ensure();
    if (!entries.delete(code)) return;
    this.sorted = null;
    await this.ctx.storage.delete(PREFIX + code);
  }

  async list(q: ListQuery): Promise<ListResult> {
    if (!this.hits.hit(q.ip, q.rateMax)) return { limited: true, rooms: [], next: null };
    const entries = await this.ensure();
    await this.prune(entries, q.ttlMs);

    const sorted = (this.sorted ??= [...entries.values()].sort(order));
    const after = parseCursor(q.after);
    let from = 0;
    if (after) while (from < sorted.length && order(sorted[from]!, after) <= 0) from++;
    const page = sorted.slice(from, from + q.limit);
    const last = page[page.length - 1];
    const more = last != null && from + page.length < sorted.length;
    return { limited: false, rooms: page.map(publicOf), next: more ? cursorOf(last) : null };
  }

  private async prune(entries: Map<string, DirEntry>, ttlMs: number): Promise<void> {
    const now = Date.now();
    const stale: string[] = [];
    for (const e of entries.values()) {
      if (now - e.at > ttlMs) stale.push(e.code);
    }
    if (stale.length === 0) return;
    for (const code of stale) entries.delete(code);
    this.sorted = null;
    await this.ctx.storage.delete(stale.map((code) => PREFIX + code));
  }

  private async ensure(): Promise<Map<string, DirEntry>> {
    if (this.entries) return this.entries;
    const map = new Map<string, DirEntry>();
    for (const e of (await this.ctx.storage.list<DirEntry>({ prefix: PREFIX })).values()) map.set(e.code, e);
    this.entries = map;
    this.sorted = null;
    return map;
  }

  private async loadSecret(): Promise<CryptoKey> {
    let raw = await this.ctx.storage.get<Uint8Array>(SECRET);
    if (!raw) {
      raw = crypto.getRandomValues(new Uint8Array(32));
      await this.ctx.storage.put(SECRET, raw);
    }
    return await crypto.subtle.importKey('raw', raw, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  }
}

/** members desc, then at desc, then code asc. */
function order(a: SortKey, b: SortKey): number {
  if (a.members !== b.members) return b.members - a.members;
  if (a.at !== b.at) return b.at - a.at;
  return a.code < b.code ? -1 : a.code > b.code ? 1 : 0;
}

function cursorOf(e: SortKey): string {
  return `${e.members}-${e.at}-${e.code}`;
}

/** The one spelling of a cursor, null for anything that pages from the start. */
export function normalizeCursor(raw: string | null): string | null {
  const key = parseCursor(raw);
  return key ? cursorOf(key) : null;
}

function parseCursor(raw: string | null): SortKey | null {
  if (raw == null || raw.length > 64) return null;
  const parts = raw.split('-');
  if (parts.length !== 3) return null;
  const members = Number(parts[0]);
  const at = Number(parts[1]);
  const code = normalizeCode(parts[2]!);
  if (!Number.isInteger(members) || !Number.isInteger(at) || code == null) return null;
  return { members, at, code };
}

function publicOf(e: DirEntry): PublicRoom {
  const room: PublicRoom = {
    code: e.code,
    name: e.name,
    hid: e.hid,
    members: e.members,
    max: e.max,
    pv: e.pv,
    approval: e.approval,
    password: e.password,
    at: e.at,
  };
  if (e.title != null) room.title = e.title;
  if (e.artist != null) room.artist = e.artist;
  return room;
}
