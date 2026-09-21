import type { RelayEnv, Tier } from './types';

export const TEXT_MAX = 2048;
export const BIN_MAX_GUEST = 16 * 1024;
export const BIN_MAX_HOST = 1024 * 1024;

export const BURST_GUEST = 40;
export const REFILL_GUEST = 4;
export const BURST_HOST = 400;
export const REFILL_HOST = 60;

export const MAX_PENDING = 20;
export const MAX_BANS = 500;
export const MAX_SUCCESSORS = 64;

export const JOIN_RATE_MAX = 20;
export const JOIN_RATE_WINDOW = 60_000;
export const CREATE_RATE_MAX = 10;
export const CREATE_RATE_WINDOW = 600_000;

export const NAME_MAX = 32;
export const DID_MAX = 64;
export const PASSWORD_MAX = 64;
export const BODY_MAX = 8 * 1024;

export const TIER_LIMITS: Record<Exclude<Tier, 'selfhost'>, { max: number; rooms: number }> = {
  cutie: { max: 50, rooms: 2 },
  pookie: { max: 100, rooms: 3 },
  patootie: { max: 200, rooms: 4 },
  owner: { max: 500, rooms: 10 },
};

export function num(value: string | undefined, fallback: number): number {
  if (value == null) return fallback;
  const n = Number(value);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}

export function membershipOn(env: RelayEnv): boolean {
  return (env.MEMBERSHIP ?? 'on').toLowerCase() !== 'off';
}

export function createPasswordOf(env: RelayEnv): string | null {
  if (membershipOn(env)) return null;
  const p = env.CREATE_PASSWORD;
  return p != null && p.length > 0 ? p : null;
}

export interface Timers {
  join: number;
  pending: number;
  grace: number;
  idle: number;
  lifetime: number;
  dropClose: number;
}

export function timers(env: RelayEnv): Timers {
  return {
    join: num(env.JOIN_TIMEOUT_MS, 10_000),
    pending: num(env.PENDING_TIMEOUT_MS, 120_000),
    grace: num(env.HOST_GRACE_MS, 60_000),
    idle: num(env.IDLE_TIMEOUT_MS, 600_000),
    lifetime: num(env.ROOM_LIFETIME_MS, 86_400_000),
    dropClose: num(env.RATE_DROP_CLOSE, 200),
  };
}

export function selfhostMax(env: RelayEnv): number {
  return Math.max(1, Math.floor(num(env.SELFHOST_MAX_MEMBERS, 100)));
}

export function tierLimits(env: RelayEnv, tier: Tier): { max: number; rooms: number } {
  if (tier === 'selfhost') return { max: selfhostMax(env), rooms: Infinity };
  return TIER_LIMITS[tier];
}
