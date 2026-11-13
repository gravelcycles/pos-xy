// Places: clusters stays from all days into places and names them (Home, Work, Place 1…).
// Port of Shared/Places.swift. Keep the two in sync (web/tests/places.test.mjs checks it).
import { distance } from './segmenter.js';

export const PLACE_RADIUS = 150;        // metres: stays closer than this to a place belong to it
export const MIN_STAY = 5 * 60;         // shorter stops aren't places
const NIGHT_MIN = 4 * 3600;             // total night-time needed to call somewhere Home
const WORK_MIN = 4 * 3600;              // total weekday 9–5 time needed to call somewhere Work

/** Stays (stationary segments ≥ MIN_STAY) of one day, as { lat, lon, start, end }. */
export function staysFromDay(points, segments) {
  const out = [];
  for (const s of segments) {
    if (s.type !== 'stationary' || s.end - s.start < MIN_STAY) continue;
    let lat = 0, lon = 0;
    for (let i = s.first; i <= s.last; i++) { lat += points[i].lat; lon += points[i].lon; }
    const n = s.last - s.first + 1;
    out.push({ lat: lat / n, lon: lon / n, start: s.start, end: s.end });
  }
  return out;
}

const overlap = (a0, a1, b0, b1) => Math.max(0, Math.min(a1, b1) - Math.max(a0, b0));

/** Seconds of [s, e] that fall in local night (22:00–06:00) and weekday office hours (Mon–Fri 9–17). */
export function windowSeconds(s, e) {
  let night = 0, work = 0;
  const d = new Date(s * 1000);
  d.setHours(0, 0, 0, 0);
  while (d.getTime() / 1000 < e) {
    const y = d.getFullYear(), m = d.getMonth(), day = d.getDate();
    const t = (h) => new Date(y, m, day, h).getTime() / 1000;
    const next = new Date(y, m, day + 1).getTime() / 1000;
    night += overlap(s, e, t(0), t(6)) + overlap(s, e, t(22), next);
    const wd = d.getDay();
    if (wd >= 1 && wd <= 5) work += overlap(s, e, t(9), t(17));
    d.setTime(next * 1000);
  }
  return { night, work };
}

function dayKey(t) {
  const d = new Date(t * 1000);
  return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
}

/**
 * Clusters stays into places. Returns places sorted by total time (most first), each:
 * { lat, lon, visits, seconds, night, work, days, label: 'home'|'work'|null, name }
 * `name` is 'Home', 'Work', 'Place N', or null for places too minor to name.
 */
export function detectPlaces(stays) {
  const places = [];
  for (const s of [...stays].sort((a, b) => a.start - b.start)) {
    let best = null, bestD = Infinity;
    for (const p of places) {
      const d = distance(p, s);
      if (d <= PLACE_RADIUS && d < bestD) { best = p; bestD = d; }
    }
    const w = Math.max(s.end - s.start, 1);
    const win = windowSeconds(s.start, s.end);
    if (best) {
      best.lat = (best.lat * best.weight + s.lat * w) / (best.weight + w);
      best.lon = (best.lon * best.weight + s.lon * w) / (best.weight + w);
      best.weight += w;
    } else {
      best = { lat: s.lat, lon: s.lon, weight: w, visits: 0, seconds: 0, night: 0, work: 0, dayKeys: new Set() };
      places.push(best);
    }
    best.visits += 1;
    best.seconds += s.end - s.start;
    best.night += win.night;
    best.work += win.work;
    best.dayKeys.add(dayKey(s.start));
  }

  places.sort((a, b) => b.seconds - a.seconds);
  let home = null, work = null;
  for (const p of places) if (p.night >= NIGHT_MIN && (!home || p.night > home.night)) home = p;
  for (const p of places) {
    if (p === home || p.work < WORK_MIN || p.dayKeys.size < 2) continue;
    if (!work || p.work > work.work) work = p;
  }
  let rank = 0;
  return places.map((p) => {
    const label = p === home ? 'home' : p === work ? 'work' : null;
    const significant = p.seconds >= 30 * 60 || p.visits >= 2;
    const name = label === 'home' ? 'Home' : label === 'work' ? 'Work' : significant ? `Place ${++rank}` : null;
    return { lat: p.lat, lon: p.lon, visits: p.visits, seconds: p.seconds, night: p.night, work: p.work,
             days: p.dayKeys.size, label, name };
  });
}

/** The named place within PLACE_RADIUS of (lat, lon), or null. */
export function nearestPlace(places, lat, lon) {
  let best = null, bestD = Infinity;
  for (const p of places) {
    if (!p.name) continue;
    const d = distance(p, { lat, lon });
    if (d <= PLACE_RADIUS && d < bestD) { best = p; bestD = d; }
  }
  return best;
}
