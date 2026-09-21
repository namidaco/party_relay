const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const CODE_LEN = 8;
const CONTROL = /[\u0000-\u001f\u007f-\u009f]/g;
const encoder = new TextEncoder();

export function roomCode(): string {
  // 256 % 32 == 0, the bound is kept generic so the alphabet can change without introducing bias.
  const bound = 256 - (256 % ALPHABET.length);
  let out = '';
  const buf = new Uint8Array(CODE_LEN * 2);
  while (out.length < CODE_LEN) {
    crypto.getRandomValues(buf);
    for (let i = 0; i < buf.length && out.length < CODE_LEN; i++) {
      const b = buf[i]!;
      if (b < bound) out += ALPHABET[b % ALPHABET.length];
    }
  }
  return out;
}

export function normalizeCode(raw: string): string | null {
  if (typeof raw !== 'string' || raw.length !== CODE_LEN) return null;
  const up = raw.toUpperCase();
  for (let i = 0; i < up.length; i++) {
    if (!ALPHABET.includes(up[i]!)) return null;
  }
  return up;
}

export function randomToken(): string {
  return b64url(crypto.getRandomValues(new Uint8Array(32)));
}

export function reqId(): string {
  return b64url(crypto.getRandomValues(new Uint8Array(9)));
}

export function banId(): string {
  return b64url(crypto.getRandomValues(new Uint8Array(6)));
}

export function b64url(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]!);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export async function sha256hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(input));
  const bytes = new Uint8Array(digest);
  let out = '';
  for (let i = 0; i < bytes.length; i++) out += bytes[i]!.toString(16).padStart(2, '0');
  return out;
}

/** Constant time compare of two fixed length hex digests. */
export function ctEq(a: string, b: string): boolean {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function cleanText(value: unknown, max: number): string | null {
  if (typeof value !== 'string') return null;
  if (value.length > max * 4) return null;
  const s = value.replace(CONTROL, '').trim();
  if (s.length < 1 || s.length > max) return null;
  return s;
}

export function utf8Len(s: string): number {
  return encoder.encode(s).byteLength;
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  });
}

export function clientIp(req: Request): string {
  const cf = req.headers.get('cf-connecting-ip');
  if (cf) return cf.slice(0, 45);
  const xff = req.headers.get('x-forwarded-for');
  if (xff) {
    const first = xff.split(',')[0]!.trim();
    if (first) return first.slice(0, 45);
  }
  return '127.0.0.1';
}
