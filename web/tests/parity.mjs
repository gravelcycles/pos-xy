// Runs the JS segmenter on a fixture and prints one line per segment (compare with Swift output).
import { readFileSync } from 'node:fs';
import { decodeFile } from '../static/js/format.js';
import { clean, segments, normalizeSpans } from '../static/js/segmenter.js';

const bytes = new Uint8Array(readFileSync(process.argv[2]));
const { points, motion } = await decodeFile(bytes);
const pts = clean(points);
for (const s of segments(pts, normalizeSpans(motion))) {
  console.log(`${s.type} ${s.first} ${s.last} ${Math.round(s.distance)}`);
}
