// Importers for Google Takeout / Timeline and GPX (web/static/js/importers.js).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { decodePoints } from '../static/js/format.js';
import { parseLatLng, googleActivity, toGPX, fromGPX } from '../static/js/importers.js';

const read = (name) => new Uint8Array(readFileSync(new URL(`fixtures/import/${name}`, import.meta.url)));

test('Google Takeout Records.json', async () => {
  const info = {};
  const pts = await decodePoints(read('google-records.json'), undefined, info);
  assert.equal(info.kind, 'Google Takeout (Records.json)');
  assert.equal(pts.length, 3);                                  // the one without a time is dropped
  assert.equal(pts[0].t, Date.parse('2019-06-01T08:00:00Z') / 1000);
  assert.equal(pts[0].lat, 37.7749295);
  assert.equal(pts[0].lon, -122.4194155);
  assert.equal(pts[0].act, 'stationary');
  assert.equal(pts[1].t, 1559376060);                           // timestampMs
  assert.equal(pts[1].act, 'walking');
  assert.equal(pts[1].alt, 20);
  assert.equal(pts[2].act, null);                               // 30 % confidence is ignored
});

test('Google Maps Timeline (Android/web on-device export)', async () => {
  const info = {};
  const pts = await decodePoints(read('google-timeline.json'), undefined, info);
  assert.equal(info.kind, 'Google Maps Timeline');
  assert.equal(pts.length, 1 + 2 + 2 + 2);                       // raw signal + path + visit + activity
  const raw = pts.find((p) => p.acc === 9);
  assert.equal(raw.spd, 1.3);
  assert.equal(raw.t, Date.parse('2024-03-10T09:49:00Z') / 1000);
  const visit = pts.filter((p) => p.act === 'stationary');
  assert.equal(visit.length, 2);
  assert.equal(visit[0].lat, 52.5200066);
  assert.equal(pts.filter((p) => p.act === 'walking').length, 2);
});

test('Google Maps Timeline (iPhone export)', async () => {
  const info = {};
  const pts = await decodePoints(read('google-ios.json'), undefined, info);
  assert.equal(info.kind, 'Google Maps Timeline (iPhone)');
  assert.equal(pts.length, 2 + 2 + 2);
  assert.equal(pts.filter((p) => p.act === 'driving').length, 2);   // "in passenger vehicle"
  const path = pts.filter((p) => p.act == null).sort((a, b) => a.t - b.t);
  assert.equal(path[0].t, Date.parse('2024-05-02T15:40:00Z') / 1000);   // 08:30-07:00 + 10 min
});

test('GPX', async () => {
  const info = {};
  const pts = await decodePoints(read('track.gpx'), undefined, info);
  assert.equal(info.kind, 'GPX');
  assert.equal(pts.length, 3);                                   // waypoint without time ignored
  assert.deepEqual([pts[1].lat, pts[1].lon, pts[1].alt], [46.0215, 7.7502, 1612]);  // attribute order
  assert.equal(pts[2].t, Date.parse('2025-07-04T13:00:20.500Z') / 1000);
});

test('GPX round trip', () => {
  const pts = [{ t: 1700000000, lat: 1.5, lon: -2.25, alt: 10 }, { t: 1700000010.5, lat: 1.6, lon: -2.2 }];
  const back = fromGPX(toGPX(pts, 'A <test> & "quotes"'));
  assert.deepEqual(back.map((p) => [p.t, p.lat, p.lon, p.alt ?? null]), [[1700000000, 1.5, -2.25, 10], [1700000010.5, 1.6, -2.2, null]]);
  assert.match(toGPX(pts, 'A <b>'), /<name>A &lt;b&gt;<\/name>/);
});

test('helpers', () => {
  assert.deepEqual(parseLatLng('52.52°, 13.40°'), [52.52, 13.4]);
  assert.deepEqual(parseLatLng('geo:-33.8,151.2'), [-33.8, 151.2]);
  assert.equal(parseLatLng('nope'), null);
  assert.equal(googleActivity('in passenger vehicle'), 'driving');
  assert.equal(googleActivity('IN_SUBWAY'), 'driving');
  assert.equal(googleActivity('ON_BICYCLE'), 'cycling');
  assert.equal(googleActivity('something new'), 'unknown');
});
