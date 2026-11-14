// Manual activity corrections (e.g. a drive that was really a train).
// Golden values from Shared/Corrections.swift (fixtures/sample-day-corrected.json, made by make_corrected_fixture.py).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { decodeFile } from '../static/js/format.js';
import { clean, segments, applyCorrections, removeCorrections, normalizeCorrections } from '../static/js/segmenter.js';

const SWIFT_GOLDEN = [["stationary", 0, 38, 185], ["walking", 38, 134, 980], ["train", 134, 490, 21491], ["stationary", 490, 729, 1378], ["cycling", 729, 980, 8317], ["running", 980, 1220, 3492], ["stationary", 1220, 1250, 117], ["flying", 1250, 1251, 560725], ["stationary", 1251, 1269, 86], ["driving", 1269, 1360, 11692]];

test('corrections relabel segments like the Swift implementation (later wins, < half ignored)', async () => {
  const bytes = new Uint8Array(readFileSync(new URL('fixtures/sample-day-corrected.json', import.meta.url)));
  const { points, corrections } = await decodeFile(bytes);
  assert.equal(corrections.length, 3);
  const segs = applyCorrections(segments(clean(points)), normalizeCorrections(corrections));
  assert.deepEqual(segs.map((s) => [s.type, s.first, s.last, Math.round(s.distance)]), SWIFT_GOLDEN);
  assert.ok(segs.some((s) => s.type === 'train'));
  assert.ok(!segs.some((s) => s.type === 'bus'));
  assert.ok(segs.some((s) => s.type === 'running'));
});

test('neighbours with the same corrected activity merge', () => {
  const segs = [
    { type: 'driving', first: 0, last: 5, start: 0, end: 100, distance: 1000 },
    { type: 'stationary', first: 5, last: 6, start: 100, end: 120, distance: 5 },
    { type: 'driving', first: 6, last: 9, start: 120, end: 200, distance: 800 },
  ];
  const out = applyCorrections(segs, [{ start: 0, end: 200, act: 'train' }]);
  assert.deepEqual(out.map((s) => [s.type, s.first, s.last, s.distance]), [['train', 0, 9, 1805]]);
});

test('back to automatic removes corrections covering the segment', () => {
  const cs = [{ start: 0, end: 100, act: 'train' }, { start: 500, end: 600, act: 'bus' }];
  assert.deepEqual(removeCorrections(cs, 0, 100), [cs[1]]);
  assert.deepEqual(removeCorrections(cs, 0, 1000), cs);            // 100 s of 1000 s: not "covering"
});
