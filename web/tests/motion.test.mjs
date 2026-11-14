// Motion-history backfill: spans from the phone's motion coprocessor label gaps with no points
// (e.g. while iOS had the app suspended) and points without an activity tag.
// Golden values from Shared/Segmenter.swift (fixtures/sample-day-gap-motion.json, made by make_gap_fixture.py).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { decodeFile } from '../static/js/format.js';
import { clean, segments, normalizeSpans, activityAt, dominantMoving, fillActivities } from '../static/js/segmenter.js';

const SWIFT_GOLDEN = [["stationary", 0, 38, 185], ["walking", 38, 134, 980], ["driving", 134, 189, 20283], ["stationary", 189, 428, 1378], ["cycling", 428, 679, 8317], ["running", 679, 919, 3492], ["stationary", 919, 949, 117], ["flying", 949, 950, 560725], ["stationary", 950, 968, 86], ["driving", 968, 1059, 11692]];

async function load() {
  const bytes = new Uint8Array(readFileSync(new URL('fixtures/sample-day-gap-motion.json', import.meta.url)));
  const { points, motion } = await decodeFile(bytes);
  return { pts: clean(points), motion: normalizeSpans(motion) };
}

test('gap during a drive is a drive when motion history covers it (matches Swift)', async () => {
  const { pts, motion } = await load();
  assert.ok(motion.length > 0);
  const segs = segments(pts, motion);
  assert.deepEqual(segs.map((s) => [s.type, s.first, s.last, Math.round(s.distance)]), SWIFT_GOLDEN);
  assert.ok(!segs.some((s) => s.type === 'unknown'));
});

test('without motion history the same gap is unknown', async () => {
  const { pts } = await load();
  assert.ok(segments(pts).some((s) => s.type === 'unknown'));
});

test('span helpers', () => {
  const spans = normalizeSpans([
    { start: 100, end: 200, act: 'walking' },
    { start: 0, end: 100, act: 'stationary' },
    { start: 200, end: 1000, act: 'driving' },
    { start: 0, end: 100, act: 'stationary' },        // duplicate
  ]);
  assert.equal(spans.length, 3);
  assert.equal(activityAt(150, spans), 'walking');
  assert.equal(activityAt(1000, spans), null);       // end is exclusive
  assert.equal(dominantMoving(50, 900, spans), 'driving');
  assert.equal(dominantMoving(0, 99, spans), null);  // only stationary
  // Movement must cover min(3 min, 20 % of the gap): 30 s of 70 s is enough, 30 s of 2000 s isn't.
  assert.equal(dominantMoving(190, 260, [{ start: 200, end: 230, act: 'driving' }]), 'driving');
  assert.equal(dominantMoving(0, 2000, [{ start: 200, end: 230, act: 'driving' }]), null);
});

test('untagged points take the activity of the span covering them', () => {
  const out = fillActivities([{ t: 150, lat: 0, lon: 0 }, { t: 150, lat: 0, lon: 0, act: 'cycling' }],
    [{ start: 100, end: 200, act: 'walking' }]);
  assert.deepEqual(out.map((p) => p.act), ['walking', 'cycling']);
});
