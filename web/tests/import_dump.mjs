// Prints imported points (compare with the Swift importer output).
import { readFileSync } from 'node:fs';
import { importForeign } from '../static/js/importers.js';
for (const path of process.argv.slice(2)) {
  const text = readFileSync(path, 'utf8');
  let parsed; try { parsed = JSON.parse(text); } catch {}
  const r = importForeign(text, parsed);
  const pts = [...r.points].sort((a, b) => a.t - b.t);
  console.log(`== ${r.kind} ${pts.length}`);
  for (const p of pts) console.log(`${p.t.toFixed(3)} ${p.lat.toFixed(7)} ${p.lon.toFixed(7)} ${p.act ?? '-'} ${p.spd ?? '-'} ${p.alt ?? '-'}`);
}
