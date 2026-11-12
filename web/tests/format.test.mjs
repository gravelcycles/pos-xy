// Checks web/static/js/format.js against docs/test-vectors (made by an independent Python impl).
// Run: node --test web/tests/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { decodePoints, parseHeader, isLocked } from '../static/js/format.js';

const dir = new URL('../../docs/test-vectors/', import.meta.url);
const vectors = JSON.parse(readFileSync(new URL('vectors.json', dir)));
const plain = JSON.parse(readFileSync(new URL('plaintext.json', dir)));
const read = (name) => new Uint8Array(readFileSync(new URL(name, dir)));
const hex = (u8) => Buffer.from(u8).toString('hex');

for (const v of vectors) {
  test(`${v.file}: header fields`, () => {
    const h = parseHeader(read(v.file));
    assert.equal(hex(h.salt), v.salt_hex);
    assert.equal(h.iterations, v.iterations);
    assert.equal(hex(h.nonce), v.nonce_hex);
    assert.equal(hex(h.header), v.header_hex);
  });

  test(`${v.file}: decrypts to the plaintext`, async () => {
    const pts = await decodePoints(read(v.file), v.passphrase);
    assert.equal(pts.length, plain.points.length);
    assert.equal(pts[1].act, 'walking');
    assert.equal(pts[2].alt, null);
    assert.equal(pts[0].lat, plain.points[0].lat);
  });

  test(`${v.file}: decomposed (NFD) passphrase also works`, async () => {
    const pts = await decodePoints(read(v.file), v.passphrase.normalize('NFD'));
    assert.equal(pts.length, 3);
  });

  test(`${v.file}: wrong passphrase rejected`, async () => {
    await assert.rejects(decodePoints(read(v.file), 'nope'), { code: 'wrong-passphrase' });
  });

  test(`${v.file}: tampered header rejected (header is authenticated)`, async () => {
    const b = read(v.file);
    b[9] ^= 0x01;   // flip a salt bit
    await assert.rejects(decodePoints(b, v.passphrase), { code: 'wrong-passphrase' });
  });
}

test('locked file without passphrase asks for one', async () => {
  await assert.rejects(decodePoints(read('vector-2.pxy')), { code: 'passphrase' });
});

test('plain export, bare array, JSON Lines', async () => {
  const enc = (s) => new TextEncoder().encode(s);
  assert.equal(isLocked(read('plaintext.json')), false);
  assert.equal((await decodePoints(read('plaintext.json'))).length, 3);
  assert.equal((await decodePoints(enc(JSON.stringify(plain.points)))).length, 3);
  const jsonl = plain.points.map((p) => JSON.stringify(p)).join('\n') + '\n{broken\n';
  assert.equal((await decodePoints(enc(jsonl))).length, 3);
});

test('unknown activity and unknown fields are tolerated; bad points dropped', async () => {
  const enc = (s) => new TextEncoder().encode(s);
  const pts = await decodePoints(enc(JSON.stringify([
    { t: 1, lat: 1, lon: 2, act: 'teleporting', future: { x: 1 } },
    { t: 2, lat: 95, lon: 2 },            // invalid latitude
    { t: 'x', lat: 1, lon: 2 },           // invalid time
  ])));
  assert.equal(pts.length, 1);
  assert.equal(pts[0].act, 'unknown');
});
