import { DID_MAX, NAME_MAX, PASSWORD_MAX, TEXT_MAX } from './limits';
import { cleanText, utf8Len } from './util';

export const HEADER_BYTES = 5;
export const ROUTE_HOST = 0;
export const ROUTE_BROADCAST = 1;
export const ROUTE_DIRECT = 2;

export function textTooLarge(s: string): boolean {
  if (s.length > TEXT_MAX) return true;
  if (s.length * 3 <= TEXT_MAX) return false;
  return utf8Len(s) > TEXT_MAX;
}

export function parseControl(s: string): Record<string, unknown> | null {
  let v: unknown;
  try {
    v = JSON.parse(s);
  } catch {
    return null;
  }
  if (v == null || typeof v !== 'object' || Array.isArray(v)) return null;
  const rec = v as Record<string, unknown>;
  return typeof rec.t === 'string' ? rec : null;
}

export interface JoinFrame {
  pv: number;
  name: string;
  did: string;
  token: string | null;
  password: string | null;
}

export function parseJoin(m: Record<string, unknown>): JoinFrame | null {
  if (!Number.isInteger(m.pv) || (m.pv as number) < 1) return null;
  const name = cleanText(m.name, NAME_MAX);
  if (name == null) return null;
  const did = cleanText(m.did, DID_MAX);
  if (did == null) return null;
  const token = optString(m.token, 128);
  if (token === undefined) return null;
  const password = optString(m.password, PASSWORD_MAX);
  if (password === undefined) return null;
  return { pv: m.pv as number, name, did, token, password };
}

/** `undefined` means invalid, `null` means absent. */
export function optString(v: unknown, max: number): string | null | undefined {
  if (v == null) return null;
  if (typeof v !== 'string') return undefined;
  if (v.length < 1 || v.length > max) return undefined;
  return v;
}

export function isNum(v: unknown): v is number {
  return Number.isInteger(v) && (v as number) >= 1 && (v as number) <= 0xffffffff;
}
