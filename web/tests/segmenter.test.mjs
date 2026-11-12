// Golden test: the JS segmenter must match Shared/Segmenter.swift on the fixture.
// Golden values were produced by the Swift implementation (type, first, last, metres).
// Regenerate the fixture with: python3 web/tests/make_fixture.py
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { decodePoints } from '../static/js/format.js';
import { clean, segments, totals } from '../static/js/segmenter.js';

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

test('tiny inputs', () => {
  assert.deepEqual(segments([]), []);
  assert.deepEqual(segments([{ t: 0, lat: 1, lon: 1 }]), []);
});
