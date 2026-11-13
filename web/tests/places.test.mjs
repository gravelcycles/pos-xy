// Places must match Shared/Places.swift. Golden lines produced by the Swift implementation with
// TZ=America/Los_Angeles (fixtures/week.json is a synthetic week in San Francisco).
process.env.TZ = 'America/Los_Angeles';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { decodePoints } from '../static/js/format.js';
import { clean, segments } from '../static/js/segmenter.js';
import { staysFromDay, detectPlaces, nearestPlace, windowSeconds } from '../static/js/places.js';

const SWIFT_GOLDEN = ["Home 37.75990 -122.41480 visits=14 h=106.99 night=55.75 work=0.00 days=7", "Work 37.78971 -122.39720 visits=5 h=47.47 night=0.00 work=40.00 days=5", "Place 1 37.76940 -122.48622 visits=2 h=5.93 night=0.00 work=0.00 days=2", "Place 2 37.77860 -122.41101 visits=2 h=1.93 night=0.00 work=0.00 days=2", "Place 3 37.76441 -122.42186 visits=3 h=1.21 night=0.00 work=0.00 days=3"];

const fmt = (p) => `${p.name ?? '-'} ${p.lat.toFixed(5)} ${p.lon.toFixed(5)} visits=${p.visits} h=${(p.seconds / 3600).toFixed(2)} night=${(p.night / 3600).toFixed(2)} work=${(p.work / 3600).toFixed(2)} days=${p.days}`;

async function weekPlaces() {
  const pts = clean(await decodePoints(new Uint8Array(readFileSync(new URL('fixtures/week.json', import.meta.url)))));
  const byDay = new Map();
  for (const p of pts) {
    const d = new Date(p.t * 1000); const k = d.toDateString();
    if (!byDay.has(k)) byDay.set(k, []); byDay.get(k).push(p);
  }
  const stays = [];
  for (const dp0 of byDay.values()) { const dp = clean(dp0); stays.push(...staysFromDay(dp, segments(dp))); }
  return detectPlaces(stays);
}

test('week: places match the Swift implementation', async () => {
  assert.deepEqual((await weekPlaces()).map(fmt), SWIFT_GOLDEN);
});

test('week: home, work and the café are found where they are', async () => {
  const places = await weekPlaces();
  assert.equal(nearestPlace(places, 37.7599, -122.4148)?.name, 'Home');
  assert.equal(nearestPlace(places, 37.7897, -122.3972)?.name, 'Work');
  assert.ok(nearestPlace(places, 37.7644, -122.4219)?.name?.startsWith('Place'));
  assert.equal(nearestPlace(places, 37.70, -122.30), null);
});

test('night / office-hours windows', () => {
  const wed = new Date(2025, 10, 12).getTime() / 1000;     // Wednesday 00:00 local
  const sat = new Date(2025, 10, 15).getTime() / 1000;
  assert.deepEqual(windowSeconds(wed + 20 * 3600, wed + 32 * 3600), { night: 8 * 3600, work: 0 });   // 20:00 → 08:00
  assert.deepEqual(windowSeconds(wed + 8 * 3600, wed + 18 * 3600), { night: 0, work: 8 * 3600 });
  assert.deepEqual(windowSeconds(sat + 8 * 3600, sat + 18 * 3600), { night: 0, work: 0 });          // weekend
});
