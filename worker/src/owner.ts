import { DurableObject } from 'cloudflare:workers';
import type { RelayEnv } from './types';

/**
 * One instance per membership identity (`patreon:<id>`, `supabase:<id>`, `ip:<ip>`) tracking its open rooms,
 * and one instance per ip (`rate:<ip>`) used as the create attempt limiter.
 */
export class OwnerDO extends DurableObject<RelayEnv> {
  async claim(code: string, maxRooms: number, lifetimeMs: number): Promise<boolean> {
    const now = Date.now();
    const rooms = (await this.ctx.storage.get<Record<string, number>>('rooms')) ?? {};
    for (const [c, at] of Object.entries(rooms)) {
      if (now - at > lifetimeMs) delete rooms[c];
    }
    if (!(code in rooms) && Object.keys(rooms).length >= maxRooms) {
      await this.ctx.storage.put('rooms', rooms);
      return false;
    }
    rooms[code] = now;
    await this.ctx.storage.put('rooms', rooms);
    return true;
  }

  async release(code: string): Promise<void> {
    const rooms = await this.ctx.storage.get<Record<string, number>>('rooms');
    if (!rooms || !(code in rooms)) return;
    delete rooms[code];
    if (Object.keys(rooms).length === 0) await this.ctx.storage.deleteAll();
    else await this.ctx.storage.put('rooms', rooms);
  }

  /** The alarm lands when the newest hit leaves the window, so a quiet ip leaves no record behind. */
  async hit(max: number, windowMs: number): Promise<boolean> {
    const now = Date.now();
    const kept = ((await this.ctx.storage.get<number[]>('hits')) ?? []).filter((t) => now - t < windowMs);
    const allowed = kept.length < max;
    if (allowed) kept.push(now);
    await this.ctx.storage.put('hits', kept);
    if (allowed) await this.ctx.storage.setAlarm(now + windowMs);
    return allowed;
  }

  override async alarm(): Promise<void> {
    await this.ctx.storage.delete('hits');
  }
}
