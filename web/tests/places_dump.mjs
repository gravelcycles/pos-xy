// Prints detected places for a fixture (compare with the Swift output). Run with TZ set.
import { readFileSync } from 'node:fs';
import { decodePoints } from '../static/js/format.js';
import { clean, segments } from '../static/js/segmenter.js';
import { staysFromDay, detectPlaces } from '../static/js/places.js';

const pts = clean(await decodePoints(new Uint8Array(readFileSync(process.argv[2]))));
const byDay = new Map();
for (const p of pts) {
  const d = new Date(p.t * 1000); const k = `${d.getFullYear()}-${d.getMonth()}-${d.getDate()}`;
  if (!byDay.has(k)) byDay.set(k, []); byDay.get(k).push(p);
}
const stays = [];
for (const day of [...byDay.keys()].sort()) { const dp = clean(byDay.get(day)); stays.push(...staysFromDay(dp, segments(dp))); }
for (const p of detectPlaces(stays)) {
  console.log(`${p.name ?? '-'} ${p.lat.toFixed(5)} ${p.lon.toFixed(5)} visits=${p.visits} h=${(p.seconds / 3600).toFixed(2)} night=${(p.night / 3600).toFixed(2)} work=${(p.work / 3600).toFixed(2)} days=${p.days}`);
}
