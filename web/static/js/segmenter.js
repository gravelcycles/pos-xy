// Port of Shared/Segmenter.swift. Keep the two in sync (web/tests/parity.mjs checks it).
// Points: { t (unix seconds), lat, lon, alt, acc, spd, crs, act }.
// Segments: { type, first, last, start, end, distance }; segments share boundary points.

export const ACTIVITY = {
  stationary: { label: 'Stay', color: 'rgb(140,92,217)' },
  walking: { label: 'Walk', color: 'rgb(46,179,89)' },
  running: { label: 'Run', color: 'rgb(242,140,26)' },
  cycling: { label: 'Bike', color: 'rgb(13,166,191)' },
  driving: { label: 'Drive', color: 'rgb(51,115,242)' },
  flying: { label: 'Flight', color: 'rgb(230,64,115)' },
  unknown: { label: 'Unknown', color: 'rgb(140,140,148)' },
};
export const ACTIVITY_ORDER = ['stationary', 'walking', 'running', 'cycling', 'driving', 'flying', 'unknown'];
export const isDashed = (type) => type === 'flying' || type === 'unknown';
export const MINIMUM_GAP = 5 * 60;

/** Same rule as Segmenter.gapThreshold in Swift: max(5 min, 2.5 × median spacing), capped at 6 h. */
export function gapThreshold(p) {
  if (p.length < 3) return MINIMUM_GAP;
  const dts = [];
  for (let i = 1; i < p.length; i++) dts.push(p[i].t - p[i - 1].t);
  dts.sort((a, b) => a - b);
  return Math.min(Math.max(MINIMUM_GAP, dts[Math.floor(dts.length / 2)] * 2.5), 6 * 3600);
}

export function distance(a, b) {
  const r = 6371000;
  const p1 = a.lat * Math.PI / 180, p2 = b.lat * Math.PI / 180;
  const dp = p2 - p1, dl = (b.lon - a.lon) * Math.PI / 180;
  const h = Math.sin(dp / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) ** 2;
  return 2 * r * Math.asin(Math.min(1, Math.sqrt(h)));
}

export function clean(raw) {
  const sorted = [...raw].sort((a, b) => a.t - b.t);
  const out = [];
  for (const p of sorted) {
    if (p.acc != null && p.acc > 250) continue;
    if (!(Math.abs(p.lat) <= 90 && Math.abs(p.lon) <= 180) || (p.lat === 0 && p.lon === 0)) continue;
    if (out.length && p.t - out[out.length - 1].t < 0.5) continue;
    out.push(p);
  }
  if (out.length < 3) return out;
  const keep = out.map(() => true);
  for (let i = 1; i < out.length - 1; i++) {
    const a = out[i - 1], b = out[i], c = out[i + 1];
    const ab = distance(a, b), bc = distance(b, c), ac = distance(a, c);
    const dtab = Math.max(b.t - a.t, 1), dtbc = Math.max(c.t - b.t, 1);
    if (ab / dtab > 80 && bc / dtbc > 80 && ac < 0.3 * Math.min(ab, bc)) keep[i] = false;
  }
  return out.filter((_, i) => keep[i]);
}

export function speeds(p, gap = gapThreshold(p)) {
  const n = p.length, s = new Array(n).fill(0);
  for (let i = 0; i < n; i++) {
    if (p[i].spd != null && p[i].spd >= 0) { s[i] = p[i].spd; continue; }
    let lo = i, hi = i;
    if (i > 0 && p[i].t - p[i - 1].t <= gap) lo = i - 1;
    if (i < n - 1 && p[i + 1].t - p[i].t <= gap) hi = i + 1;
    const dt = p[hi].t - p[lo].t;
    s[i] = dt > 0 ? distance(p[lo], p[hi]) / dt : 0;
  }
  return s;
}

export function speedClass(v, alt) {
  if (v >= 60 || (v >= 35 && (alt ?? 0) > 2000)) return 'flying';
  if (v < 0.6) return 'stationary';
  if (v < 2.3) return 'walking';
  if (v < 3.8) return 'running';
  if (v < 8.5) return 'cycling';
  return 'driving';
}

export function classifyBySpeed(list) {
  if (!list.length) return 'unknown';
  const s = [...list].sort((a, b) => a - b);
  const median = s[Math.floor(s.length / 2)];
  const p90 = s[Math.floor((s.length - 1) * 0.9)];
  if (p90 >= 60) return 'flying';
  if (median < 0.7 && p90 < 2) return 'stationary';
  if (p90 < 2.6) return 'walking';
  if (p90 < 4.2 && median >= 2.0) return 'running';
  if (p90 < 9.5) return 'cycling';
  return 'driving';
}

export function pointLabel(p, v) {
  const s = speedClass(v, p.alt);
  if (s === 'flying') return 'flying';
  const m = p.act;
  if (!m || m === 'unknown') return s;
  switch (m) {
    case 'stationary': return v > 3 ? s : 'stationary';
    case 'walking': case 'running': return v > 6 ? s : m;
    case 'cycling': return v > 17 ? 'driving' : 'cycling';
    case 'driving': return 'driving';
    case 'flying': return 'flying';
    default: return s;
  }
}

export function smooth(labels, p, windowSec = 60) {
  const out = [...labels];
  const counts = new Map();
  let lo = 0, hi = 0;
  for (let i = 0; i < p.length; i++) {
    while (hi < p.length && p[hi].t - p[i].t <= windowSec) { counts.set(labels[hi], (counts.get(labels[hi]) ?? 0) + 1); hi++; }
    while (p[i].t - p[lo].t > windowSec) { counts.set(labels[lo], counts.get(labels[lo]) - 1); lo++; }
    const mine = counts.get(labels[i]) ?? 0;
    // Ties go to the first type in ACTIVITY_ORDER (same as the Swift version).
    let bestKey = labels[i], bestVal = -1;
    for (const k of ACTIVITY_ORDER) { const c = counts.get(k); if (c !== undefined && c > bestVal) { bestVal = c; bestKey = k; } }
    if (bestVal > mine) out[i] = bestKey;
  }
  return out;
}

function runs(edges) {
  const result = [];
  edges.forEach((t, i) => {
    const last = result[result.length - 1];
    if (last && last.type === t) last.hi = i; else result.push({ type: t, lo: i, hi: i });
  });
  return result;
}

export function segments(p) {
  const n = p.length;
  if (n < 2) return [];
  const gap = gapThreshold(p);
  const v = speeds(p, gap);
  const labels = smooth(p.map((pt, i) => pointLabel(pt, v[i])), p);
  const edge = new Array(n - 1), isGap = new Array(n - 1).fill(false), edgeDist = new Array(n - 1);
  for (let i = 0; i < n - 1; i++) {
    const dt = p[i + 1].t - p[i].t, d = distance(p[i], p[i + 1]);
    edgeDist[i] = d;
    if (dt > gap) {
      isGap[i] = true;
      edge[i] = d < 300 ? 'stationary' : (d / dt > 50 ? 'flying' : 'unknown');
    } else {
      edge[i] = labels[i + 1];
    }
  }
  const duration = (r) => p[r.hi + 1].t - p[r.lo].t;
  const minDuration = (t) => (t === 'stationary' ? 180 : t === 'flying' ? 0 : 90);

  let rs = runs(edge);
  while (rs.length > 1) {
    let victim = -1, shortest = Infinity;
    rs.forEach((r, k) => { const d = duration(r); if (d < minDuration(r.type) && d < shortest) { victim = k; shortest = d; } });
    if (victim < 0) break;
    const left = victim > 0 ? rs[victim - 1] : null, right = victim < rs.length - 1 ? rs[victim + 1] : null;
    let target;
    if (left && right) target = duration(left) >= duration(right) ? left.type : right.type;
    else if (left) target = left.type;
    else if (right) target = right.type;
    else break;
    for (let e = rs[victim].lo; e <= rs[victim].hi; e++) edge[e] = target;
    rs = runs(edge);
  }

  let changed = false;
  for (const r of rs) {
    if (r.type === 'flying' || r.type === 'unknown') continue;
    let withMotion = 0;
    for (let i = r.lo; i <= r.hi + 1; i++) if (p[i].act && p[i].act !== 'unknown') withMotion++;
    if (withMotion >= 0.5 * (r.hi + 2 - r.lo)) continue;
    const moving = [];
    for (let e = r.lo; e <= r.hi; e++) if (!isGap[e]) moving.push(e);
    if (!moving.length) continue;
    const t = classifyBySpeed(moving.map((e) => v[e + 1]));
    if (t !== r.type) { for (const e of moving) edge[e] = t; changed = true; }
  }
  if (changed) rs = runs(edge);

  return rs.map((r) => {
    let dist = 0;
    for (let e = r.lo; e <= r.hi; e++) dist += edgeDist[e];
    return { type: r.type, first: r.lo, last: r.hi + 1, start: p[r.lo].t, end: p[r.hi + 1].t, distance: dist };
  });
}

export function totals(segs) {
  const map = new Map();
  for (const s of segs) {
    const cur = map.get(s.type) ?? { type: s.type, distance: 0, duration: 0 };
    cur.distance += s.distance; cur.duration += s.end - s.start;
    map.set(s.type, cur);
  }
  return ACTIVITY_ORDER.filter((t) => map.has(t)).map((t) => map.get(t));
}
