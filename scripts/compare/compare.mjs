#!/usr/bin/env node
// Compare a Google Maps Timeline / Takeout export with Pos XY data and report what Pos XY dropped.
//
//   node scripts/compare/compare.mjs --google Timeline.json --posxy export.pxy [--posxy more.json …]
//        [--diag "PosXY diagnostics 2026-11-17.txt"] [--tz America/Los_Angeles]
//        [--from 2026-11-10] [--to 2026-11-16] [--out report.md]
//
// Locked .pxy files: put the passphrase in PXY_PASSPHRASE. Everything runs locally; nothing is sent.
//
// What it measures, inside the period both sources cover:
//   • Each Google trip (activity segment): how much of it has a Pos XY point within ±3 min.
//   • Each Pos XY gap > 10 min: what Google says you were doing (moving = a real loss).
//   • Per day: movement time / distance in both, plus an hour-of-day histogram of missed movement.
//   • With --diag: the app's diagnostics log lines around each missed trip (app state, wake-ups, GPS mode).
import { readFileSync, writeFileSync, statSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const args = { posxy: [] };
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  const v = process.argv[i + 1];
  if (a === '--google') { args.google = v; i++; }
  else if (a === '--posxy') { args.posxy.push(v); i++; }
  else if (a === '--diag') { args.diag = v; i++; }
  else if (a === '--tz') { args.tz = v; i++; }
  else if (a === '--from') { args.from = v; i++; }
  else if (a === '--to') { args.to = v; i++; }
  else if (a === '--out') { args.out = v; i++; }
  else if (a === '-h' || a === '--help') { console.log(readFileSync(new URL(import.meta.url), 'utf8').split('\n').slice(1, 16).join('\n')); process.exit(0); }
  else { console.error(`Unknown argument ${a}`); process.exit(2); }
}
if (!args.google || args.posxy.length === 0) {
  console.error('Usage: compare.mjs --google <Google export> --posxy <Pos XY export or folder> [--diag log] [--tz Area/City]');
  process.exit(2);
}

const googleText = readFileSync(args.google, 'utf8');
const rawGoogle = JSON.parse(googleText);
// Time zone: explicit, else guess a fixed offset from the Google file's own timestamps.
if (args.tz) process.env.TZ = args.tz;
else {
  const m = googleText.slice(0, 200000).match(/T\d\d:\d\d:\d\d(?:\.\d+)?([+-])(\d\d):(\d\d)"/);
  if (m) {
    const hours = Number(m[2]) + Number(m[3]) / 60;
    if (Number.isInteger(hours)) process.env.TZ = `Etc/GMT${m[1] === '+' ? '-' : '+'}${hours}`;
  }
}

const { importForeign, googleActivity } = await import('../../web/static/js/importers.js');
const { decodeFile } = await import('../../web/static/js/format.js');
const seg = await import('../../web/static/js/segmenter.js');

// ---------- helpers ----------
const pad = (n) => String(n).padStart(2, '0');
const dayKey = (t) => { const d = new Date(t * 1000); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`; };
const hm = (t) => { const d = new Date(t * 1000); return `${pad(d.getHours())}:${pad(d.getMinutes())}`; };
const when = (t) => `${dayKey(t)} ${hm(t)}`;
const mins = (s) => (s >= 5400 ? `${(s / 3600).toFixed(1)} h` : `${Math.round(s / 60)} min`);
const km = (m) => (m >= 1000 ? `${(m / 1000).toFixed(1)} km` : `${Math.round(m)} m`);
const isoTime = (s) => { const ms = Date.parse(s); return Number.isFinite(ms) ? ms / 1000 : null; };
const pct = (x) => `${Math.round(x * 100)}%`;
const MOVING = new Set(['walking', 'running', 'cycling', 'driving', 'train', 'bus', 'boat', 'flying']);

function lowerBound(arr, t) {   // first index with arr[i].t >= t
  let lo = 0, hi = arr.length;
  while (lo < hi) { const mid = (lo + hi) >> 1; if (arr[mid].t < t) lo = mid + 1; else hi = mid; }
  return lo;
}
function nearestGap(arr, t) {   // seconds to the nearest point
  const i = lowerBound(arr, t);
  let best = Infinity;
  if (i < arr.length) best = Math.min(best, arr[i].t - t);
  if (i > 0) best = Math.min(best, t - arr[i - 1].t);
  return best;
}
/** Fraction of [a, b] that has a point within ±window seconds. */
function coverage(arr, a, b, window = 180) {
  if (b <= a) return nearestGap(arr, a) <= window ? 1 : 0;
  const step = Math.max(15, (b - a) / 400);
  let hit = 0, n = 0;
  for (let t = a; t <= b; t += step) { n++; if (nearestGap(arr, t) <= window) hit++; }
  return n ? hit / n : 0;
}
function spanCoverage(spans, a, b) {   // fraction of [a, b] inside any moving motion span
  let covered = 0;
  for (const s of spans) {
    if (!MOVING.has(s.act)) continue;
    const lo = Math.max(a, s.start), hi = Math.min(b, s.end);
    if (hi > lo) covered += hi - lo;
  }
  return b > a ? Math.min(1, covered / (b - a)) : 0;
}

// ---------- Google ----------
const googleImport = importForeign('', rawGoogle);
if (!googleImport) { console.error('That Google file is not a format I recognise.'); process.exit(1); }
const gPoints = seg.clean(googleImport.points);

/** Google trips and visits: from semantic segments when present, else from our segmenter on its points. */
const gTrips = [], gVisits = [];
const semantic = Array.isArray(rawGoogle) ? rawGoogle : rawGoogle.semanticSegments ?? [];
for (const s of semantic) {
  const start = isoTime(s.startTime), end = isoTime(s.endTime);
  if (start == null || end == null) continue;
  if (s.activity) {
    const a = s.activity;
    gTrips.push({ start, end, type: googleActivity(a.topCandidate?.type), distance: Number(a.distanceMeters ?? a.distance ?? 0) || 0 });
  } else if (s.visit) {
    gVisits.push({ start, end });
  }
}
let tripSource = 'Google\'s own trip segments';
if (gTrips.length === 0) {
  tripSource = 'trips found by the Pos XY segmenter in Google\'s points';
  for (const s of seg.segments(gPoints)) {
    if (MOVING.has(s.type)) gTrips.push({ start: s.start, end: s.end, type: s.type, distance: s.distance });
    else if (s.type === 'stationary') gVisits.push({ start: s.start, end: s.end });
  }
}
gTrips.sort((a, b) => a.start - b.start);

// ---------- Pos XY ----------
const passphrase = process.env.PXY_PASSPHRASE;
const files = args.posxy.flatMap((p) => (statSync(p).isDirectory()
  ? readdirSync(p).filter((f) => /\.(pxy|json|jsonl)$/i.test(f)).map((f) => join(p, f)) : [p]));
let pRaw = [], motion = [], corrections = [];
for (const f of files) {
  const r = await decodeFile(new Uint8Array(readFileSync(f)), passphrase);
  pRaw = pRaw.concat(r.points);
  motion = motion.concat(r.motion);
  corrections = corrections.concat(r.corrections);
}
const seen = new Set();
pRaw = pRaw.filter((p) => (seen.has(p.t) ? false : (seen.add(p.t), true)));
const pPoints = seg.clean(pRaw);
const spans = seg.normalizeSpans(motion);
if (!pPoints.length) { console.error('No Pos XY points.'); process.exit(1); }

// ---------- Diagnostics ----------
const diag = [];
if (args.diag) {
  const re = /^(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d\.\d{3}) ([+-]\d\d:\d\d|Z) \[([^\]]+)\] (\S+)\s+(.*)$/;
  for (const line of readFileSync(args.diag, 'utf8').split('\n')) {
    const m = line.match(re);
    if (!m) continue;
    const t = isoTime(`${m[1]}T${m[2]}${m[3]}`);
    if (t != null) diag.push({ t, state: m[4], cat: m[5], msg: m[6] });
  }
  diag.sort((a, b) => a.t - b.t);
}
const diagAround = (a, b, limit = 14) => {
  const lines = diag.filter((d) => d.t >= a - 20 * 60 && d.t <= b + 20 * 60);
  if (lines.length <= limit) return lines;
  // Keep the interesting ones first.
  const key = /launch|gap|geofence|visit|STOPPED|terminate|Memory|permission|PAUSED|power|Standing|Moving|scene|error/i;
  const strong = lines.filter((d) => key.test(d.cat + ' ' + d.msg));
  return (strong.length ? strong : lines).slice(0, limit);
};

// ---------- Window ----------
const dayStart = (s) => new Date(`${s}T00:00:00`).getTime() / 1000;
let from = Math.max(pPoints[0].t, gPoints.length ? gPoints[0].t : -Infinity);
let to = Math.min(pPoints[pPoints.length - 1].t, gPoints.length ? gPoints[gPoints.length - 1].t : Infinity);
if (args.from) from = Math.max(from, dayStart(args.from));
if (args.to) to = Math.min(to, dayStart(args.to) + 86400);
if (!(to > from)) {
  console.error(`The two sources don't overlap in time. Pos XY: ${when(pPoints[0].t)} – ${when(pPoints.at(-1).t)}; `
    + `Google: ${gPoints.length ? `${when(gPoints[0].t)} – ${when(gPoints.at(-1).t)}` : 'no points'}.`);
  process.exit(1);
}
const inWindow = (x) => x.end > from && x.start < to;

// ---------- Trips ----------
const trips = gTrips.filter(inWindow).map((g) => {
  const n = lowerBound(pPoints, g.end + 0.001) - lowerBound(pPoints, g.start);
  const cov = coverage(pPoints, g.start, g.end);
  const mcov = spanCoverage(spans, g.start, g.end);
  return { ...g, n, cov, mcov, verdict: cov >= 0.75 ? 'ok' : cov >= 0.25 ? 'partial' : 'missed' };
});
const movingTime = trips.reduce((s, g) => s + (g.end - g.start), 0);
const coveredTime = trips.reduce((s, g) => s + (g.end - g.start) * g.cov, 0);
const motionOnlyTime = trips.reduce((s, g) => s + (g.end - g.start) * Math.max(0, Math.min(g.mcov, 1) - g.cov), 0);

// ---------- Pos XY gaps ----------
const gaps = [];
for (let i = 1; i < pPoints.length; i++) {
  const a = pPoints[i - 1].t, b = pPoints[i].t;
  if (b - a < 10 * 60 || b < from || a > to) continue;
  const moving = gTrips.filter((g) => g.end > a && g.start < b);
  const movingSecs = moving.reduce((s, g) => s + Math.max(0, Math.min(b, g.end) - Math.max(a, g.start)), 0);
  const dist = moving.reduce((s, g) => {
    const f = g.end > g.start ? (Math.min(b, g.end) - Math.max(a, g.start)) / (g.end - g.start) : 1;
    return s + g.distance * Math.max(0, f);
  }, 0);
  const gHas = lowerBound(gPoints, b) - lowerBound(gPoints, a) > 0 || gVisits.some((v) => v.end > a && v.start < b) || moving.length > 0;
  const moved = seg.distance(pPoints[i - 1], pPoints[i]);
  gaps.push({ a, b, movingSecs, dist, moved, types: [...new Set(moving.map((g) => g.type))],
    kind: movingSecs >= 120 ? 'moving' : gHas ? 'still' : 'both-silent' });
}

// ---------- Per day ----------
const days = new Map();
const day = (k) => days.get(k) ?? days.set(k, { gMove: 0, gCovered: 0, gDist: 0, trips: 0, missed: 0, pts: 0, pDist: 0, maxGap: 0 }).get(k);
for (const g of trips) {
  const d = day(dayKey(g.start));
  d.gMove += g.end - g.start; d.gCovered += (g.end - g.start) * g.cov; d.gDist += g.distance; d.trips++;
  if (g.verdict === 'missed') d.missed++;
}
const pIn = pPoints.filter((p) => p.t >= from && p.t <= to);
for (const p of pIn) day(dayKey(p.t)).pts++;
for (let i = 1; i < pIn.length; i++) {
  const d = day(dayKey(pIn[i].t));
  d.maxGap = Math.max(d.maxGap, pIn[i].t - pIn[i - 1].t);
}
for (const s of seg.segments(pIn, spans)) if (MOVING.has(s.type)) day(dayKey(s.start)).pDist += s.distance;

// ---------- Hour histogram of missed moving time ----------
const hourMissed = new Array(24).fill(0), hourMoving = new Array(24).fill(0);
for (const g of trips) {
  for (let t = g.start; t < g.end; t += 60) {
    const h = new Date(t * 1000).getHours();
    hourMoving[h] += 60;
    if (nearestGap(pPoints, t) > 180) hourMissed[h] += 60;
  }
}

// ---------- Report ----------
const out = [];
const w = (s = '') => out.push(s);
w(`# Pos XY vs Google: what's being dropped`);
w();
w(`Period compared: **${when(from)} → ${when(to)}** (${process.env.TZ ?? 'local time'}).`);
w(`Google: ${googleImport.kind}, ${gPoints.length.toLocaleString()} points, ${gTrips.filter(inWindow).length} trips (${tripSource}).`);
w(`Pos XY: ${files.length} file(s), ${pIn.length.toLocaleString()} points in the period, ${spans.length} motion spans.`);
w();
w(`## Summary`);
w();
w(`- Google says you were moving for **${mins(movingTime)}**. Pos XY has GPS points for **${pct(movingTime ? coveredTime / movingTime : 1)}** of that time.`);
if (spans.length) w(`- Motion history (no GPS) labels a further **${pct(movingTime ? motionOnlyTime / movingTime : 0)}**, so viewers can still say "Drive 8:10–8:40", but without a route.`);
const byVerdict = (v) => trips.filter((g) => g.verdict === v).length;
w(`- Trips: **${byVerdict('ok')} fully recorded**, ${byVerdict('partial')} partly, **${byVerdict('missed')} missed** (under 25% covered).`);
const movingGaps = gaps.filter((g) => g.kind === 'moving');
w(`- Pos XY gaps over 10 min: ${gaps.length}. **${movingGaps.length} while Google shows you moving** (${mins(movingGaps.reduce((s, g) => s + g.movingSecs, 0))}, ~${km(movingGaps.reduce((s, g) => s + g.dist, 0))}), `
  + `${gaps.filter((g) => g.kind === 'still').length} while you were at a place (expected: nothing to record), ${gaps.filter((g) => g.kind === 'both-silent').length} where Google has nothing either.`);
const byType = {};
for (const g of trips) { const b = byType[g.type] ??= { t: 0, c: 0 }; b.t += g.end - g.start; b.c += (g.end - g.start) * g.cov; }
w(`- By activity: ${Object.entries(byType).sort((a, b) => b[1].t - a[1].t).map(([k, v]) => `${k} ${pct(v.t ? v.c / v.t : 1)} of ${mins(v.t)}`).join(', ')}.`);
w();
w(`## Days`);
w();
w(`| Day | Google moving | Pos XY covered | Google dist | Pos XY dist | Trips | Missed | Pos XY points | Longest gap |`);
w(`|---|---|---|---|---|---|---|---|---|`);
for (const [k, d] of [...days.entries()].sort()) {
  w(`| ${k} | ${mins(d.gMove)} | ${pct(d.gMove ? d.gCovered / d.gMove : 1)} | ${km(d.gDist)} | ${km(d.pDist)} | ${d.trips} | ${d.missed} | ${d.pts} | ${mins(d.maxGap)} |`);
}
w();
w(`## When movement is missed (hour of day)`);
w();
w('```');
for (let h = 0; h < 24; h++) {
  if (!hourMoving[h]) continue;
  const f = hourMissed[h] / hourMoving[h];
  w(`${pad(h)}:00  ${'█'.repeat(Math.round(f * 30)).padEnd(30, '·')}  ${pct(f)} of ${mins(hourMoving[h])} missed`);
}
w('```');
w();
w(`## Missed and partial trips`);
w();
const bad = trips.filter((g) => g.verdict !== 'ok').sort((a, b) => (b.end - b.start) * (1 - b.cov) - (a.end - a.start) * (1 - a.cov));
if (!bad.length) w('None.');
for (const g of bad.slice(0, 40)) {
  w(`- **${when(g.start)}–${hm(g.end)}** ${g.type}, ${mins(g.end - g.start)}, ${km(g.distance)}: Pos XY covered ${pct(g.cov)} (${g.n} points)`
    + (spans.length ? `, motion history ${pct(g.mcov)}` : '') + '.');
  for (const d of diag.length ? diagAround(g.start, g.end) : []) w(`  - \`${hm(d.t)} [${d.state}] ${d.cat} ${d.msg}\``);
}
if (bad.length > 40) w(`- … and ${bad.length - 40} more.`);
w();
w(`## Pos XY gaps while Google shows movement`);
w();
if (!movingGaps.length) w('None.');
for (const g of movingGaps.sort((x, y) => y.movingSecs - x.movingSecs).slice(0, 30)) {
  w(`- **${when(g.a)} → ${when(g.b)}** (${mins(g.b - g.a)}): Google ${g.types.join('/')} for ${mins(g.movingSecs)}, ~${km(g.dist)}; `
    + `Pos XY jumped ${km(g.moved)} across the gap.`);
  for (const d of diag.length ? diagAround(g.a, g.b) : []) w(`  - \`${hm(d.t)} [${d.state}] ${d.cat} ${d.msg}\``);
}
if (diag.length) {
  w();
  w(`## Diagnostics overview`);
  w();
  const count = (re) => diag.filter((d) => d.t >= from && d.t <= to && re.test(d.msg)).length;
  w(`- Launches by iOS in the background: ${count(/Launched BY iOS/)}; normal launches: ${count(/Launched normally/)}.`);
  w(`- Runs that ended without warning: ${count(/STOPPED WITHOUT WARNING/)}; will-terminate: ${count(/Will terminate/)}; memory warnings: ${count(/Memory warning/)}.`);
  w(`- Geofence wake-ups: ${count(/Left the .* geofence/)}; visits reported: ${count(/reported a visit/)}; GPS resting: ${count(/GPS resting/)}.`);
  w(`- Gaps logged by the app: ${count(/No location updates for/)}.`);
}
const report = out.join('\n') + '\n';
if (args.out) { writeFileSync(args.out, report); console.error(`Wrote ${args.out}`); } else process.stdout.write(report);
