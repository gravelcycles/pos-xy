// Runs the JS segmenter on a fixture and prints one line per segment (compare with Swift output).
import { readFileSync } from 'node:fs';
import { decodePoints } from '../static/js/format.js';
import { clean, segments } from '../static/js/segmenter.js';

const bytes = new Uint8Array(readFileSync(process.argv[2]));
const pts = clean(await decodePoints(bytes));
for (const s of segments(pts)) {
  console.log(`${s.type} ${s.first} ${s.last} ${Math.round(s.distance)}`);
}
