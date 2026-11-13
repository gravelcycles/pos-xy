// Golden test: the JS segmenter must match Shared/Segmenter.swift on the fixture.
// Golden values were produced by the Swift implementation (type, first, last, metres).
// Regenerate the fixture with: python3 web/tests/make_fixture.py
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { decodePoints } from '../static/js/format.js';
import { clean, segments, totals, gapThreshold } from '../static/js/segmenter.js';

const SWIFT_GOLDEN = [["stationary", 0, 38, 185], ["walking", 38, 134, 980], ["driving", 134, 490, 21491], ["stationary", 490, 729, 1378], ["cycling", 729, 980, 8317], ["running", 980, 1220, 3492], ["stationary", 1220, 1250, 117], ["flying", 1250, 1251, 560725], ["stationary", 1251, 1269, 86], ["driving", 1269, 1360, 11692]];

test('sample day segments match the Swift implementation', async () => {
  const bytes = new Uint8Array(readFileSync(new URL('fixtures/sample-day.json', import.meta.url)));
  const segs = segments(clean(await decodePoints(bytes)));
  assert.deepEqual(segs.map((s) => [s.type, s.first, s.last, Math.round(s.distance)]), SWIFT_GOLDEN);
});

test('segments tile the day: shared boundaries, no holes', async () => {
  const bytes = new Uint8Array(readFileSync(new URL('fixtures/sample-day.json', import.meta.url)));
  const pts = clean(await decodePoints(bytes));
  const segs = segments(pts);
  assert.equal(segs[0].first, 0);
  assert.equal(segs.at(-1).last, pts.length - 1);
  for (let k = 1; k < segs.length; k++) assert.equal(segs[k - 1].last, segs[k].first);
  const types = totals(segs).map((t) => t.type);
  for (const t of ['stationary', 'walking', 'cycling', 'running', 'driving', 'flying']) assert.ok(types.includes(t), t);
});

// Same day recorded with the "Record a point every N" setting (fixtures made by
// thinning sample-day.json). Golden values from the Swift implementation.
const SPARSE_GOLDEN = {"sample-day-every-60s.json": [["stationary", 0, 15, 119], ["walking", 15, 27, 940], ["driving", 27, 55, 21041], ["stationary", 55, 215, 1499], ["cycling", 215, 238, 7941], ["running", 238, 258, 3630], ["stationary", 258, 279, 185], ["flying", 279, 280, 560725], ["stationary", 280, 292, 63], ["cycling", 292, 293, 9], ["driving", 293, 306, 11149]], "sample-day-every-300s.json": [["stationary", 0, 3, 65], ["walking", 3, 6, 899], ["driving", 6, 12, 20845], ["stationary", 12, 56, 884], ["cycling", 56, 60, 6613], ["running", 60, 64, 4119], ["stationary", 64, 70, 838], ["flying", 70, 71, 560724], ["stationary", 71, 73, 23], ["cycling", 73, 74, 15], ["driving", 74, 77, 11108]], "sample-day-every-900s.json": [["stationary", 0, 1, 55], ["walking", 1, 2, 843], ["driving", 2, 4, 19321], ["stationary", 4, 19, 1256], ["cycling", 19, 21, 6476], ["running", 21, 22, 1017], ["stationary", 22, 24, 1582], ["flying", 24, 25, 560710], ["cycling", 25, 26, 22], ["driving", 26, 27, 9456]], "sample-day-every-3600s.json": [["driving", 0, 1, 19504], ["stationary", 1, 6, 7597], ["flying", 6, 7, 560705]]};

for (const [file, golden] of Object.entries(SPARSE_GOLDEN)) {
  test(`${file} matches the Swift implementation`, async () => {
    const bytes = new Uint8Array(readFileSync(new URL(`fixtures/${file}`, import.meta.url)));
    const segs = segments(clean(await decodePoints(bytes)));
    assert.deepEqual(segs.map((s) => [s.type, s.first, s.last, Math.round(s.distance)]), golden);
  });
}

test('gap threshold adapts to sampling interval', () => {
  const pts = (dt) => Array.from({ length: 10 }, (_, i) => ({ t: i * dt, lat: 0, lon: 0 }));
  assert.equal(gapThreshold(pts(5)), 300);
  assert.equal(gapThreshold(pts(900)), 2250);
  assert.equal(gapThreshold(pts(36000)), 21600);
});

test('tiny inputs', () => {
  assert.deepEqual(segments([]), []);
  assert.deepEqual(segments([{ t: 0, lat: 1, lon: 1 }]), []);
});
