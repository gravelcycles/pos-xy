// Pos XY file format: reading plain and passphrase-locked exports in the browser.
// Spec: docs/FORMAT.md. Uses only Web Crypto + DecompressionStream (no libraries, no network).

export const MAGIC = 'PXYENC01';
import { importForeign } from './importers.js';

const HEADER_LEN = 8 + 16 + 4;   // magic + salt + iterations
const ACTIVITIES = new Set(['stationary', 'walking', 'running', 'cycling', 'driving', 'flying', 'unknown']);

export class FormatError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

export function isLocked(bytes) {
  if (bytes.length < MAGIC.length) return false;
  for (let i = 0; i < MAGIC.length; i++) if (bytes[i] !== MAGIC.charCodeAt(i)) return false;
  return true;
}

export function parseHeader(bytes) {
  if (!isLocked(bytes) || bytes.length < HEADER_LEN + 12 + 16) {
    throw new FormatError('unreadable', "This doesn't look like a Pos XY file.");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const iterations = view.getUint32(24, false);
  if (iterations < 1000 || iterations > 50_000_000) throw new FormatError('unreadable', 'Bad iteration count.');
  return {
    header: bytes.slice(0, HEADER_LEN),
    salt: bytes.slice(8, 24),
    iterations,
    nonce: bytes.slice(HEADER_LEN, HEADER_LEN + 12),
    sealed: bytes.slice(HEADER_LEN + 12),   // ciphertext || 16-byte tag (Web Crypto wants them joined)
  };
}

export async function deriveKey(passphrase, salt, iterations) {
  const pw = new TextEncoder().encode(passphrase.normalize('NFC'));
  if (pw.length === 0) throw new FormatError('passphrase', 'Enter the passphrase.');
  const base = await crypto.subtle.importKey('raw', pw, 'PBKDF2', false, ['deriveKey']);
  return crypto.subtle.deriveKey(
    { name: 'PBKDF2', hash: 'SHA-256', salt, iterations },
    base, { name: 'AES-GCM', length: 256 }, false, ['decrypt']);
}

async function inflateRaw(bytes) {
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

export async function decrypt(bytes, passphrase) {
  const h = parseHeader(bytes);
  const key = await deriveKey(passphrase, h.salt, h.iterations);
  let compressed;
  try {
    compressed = new Uint8Array(await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: h.nonce, additionalData: h.header, tagLength: 128 }, key, h.sealed));
  } catch {
    throw new FormatError('wrong-passphrase', 'Wrong passphrase (or the file is damaged).');
  }
  return inflateRaw(compressed);
}

/** Normalises one point; returns null if it's unusable. Unknown fields are ignored. */
export function normalizePoint(o) {
  if (!o || typeof o !== 'object') return null;
  const t = Number(o.t), lat = Number(o.lat), lon = Number(o.lon);
  if (!Number.isFinite(t) || !Number.isFinite(lat) || !Number.isFinite(lon)) return null;
  if (Math.abs(lat) > 90 || Math.abs(lon) > 180 || Math.abs(t) > 1e11) return null;
  const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
  const act = typeof o.act === 'string' ? (ACTIVITIES.has(o.act) ? o.act : 'unknown') : null;
  return { t, lat, lon, alt: num(o.alt), acc: num(o.acc), spd: num(o.spd), crs: num(o.crs), act };
}

/**
 * Reads a locked .pxy, an export JSON object, a bare JSON array, JSON Lines, or a foreign format
 * (Google Takeout / Timeline, GPX — see importers.js). Pass `info` to learn which format it was.
 */
export async function decodePoints(bytes, passphrase, info = {}) {
  return (await decodeFile(bytes, passphrase, info)).points;
}

const SPAN_ACTS = new Set(['stationary', 'walking', 'running', 'cycling', 'driving', 'flying']);
/** Motion span ({ start, end, act }) or null if unusable. */
export function normalizeSpan(o) {
  if (!o || typeof o !== 'object') return null;
  const start = Number(o.start), end = Number(o.end);
  if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start || !SPAN_ACTS.has(o.act)) return null;
  return { start, end, act: o.act };
}

/** Like decodePoints, but returns { points, motion } (motion spans, unsorted; see segmenter.normalizeSpans). */
export async function decodeFile(bytes, passphrase, info = {}) {
  if (isLocked(bytes)) {
    if (!passphrase) throw new FormatError('passphrase', 'This file is locked. Enter its passphrase.');
    bytes = await decrypt(bytes, passphrase);
  }
  const text = new TextDecoder().decode(bytes);
  info.kind = 'Pos XY';
  let raw = null;
  let motionRaw = [];
  let parsed;
  try { parsed = JSON.parse(text); } catch { /* maybe JSON Lines or GPX */ }
  const foreign = importForeign(text, parsed);
  if (foreign) {
    info.kind = foreign.kind;
    raw = foreign.points;
  } else if (Array.isArray(parsed)) {
    raw = parsed;
  } else if (parsed && parsed.format === 'pos-xy' && Array.isArray(parsed.points)) {
    if (Number(parsed.version) > 1) console.warn('Newer pos-xy version; reading what we understand.');
    raw = parsed.points;
    if (Array.isArray(parsed.motion)) motionRaw = parsed.motion;
  }
  if (raw === null) {
    raw = [];
    for (const line of text.split('\n')) {
      if (!line.trim()) continue;
      try { raw.push(JSON.parse(line)); } catch { /* skip bad line */ }
    }
  }
  const points = raw.map(normalizePoint).filter(Boolean);
  const motion = motionRaw.map(normalizeSpan).filter(Boolean);
  if (points.length === 0) {
    throw new FormatError('unreadable', "No location points found. Supported: Pos XY, Google Takeout / Timeline, GPX.");
  }
  return { points, motion };
}
