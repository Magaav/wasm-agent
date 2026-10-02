// Column-by-column comparison of two logical store dumps.
import fs from 'node:fs';

const [a, b] = process.argv.slice(2);
const A = JSON.parse(fs.readFileSync(a, 'utf8'));
const B = JSON.parse(fs.readFileSync(b, 'utf8'));
const cols = t => {
  const rows = [...(A.data[t] || []), ...(B.data[t] || [])];
  return [...new Set(rows.flatMap(r => Object.keys(r)))].sort();
};
let differences = 0;
for (const t of [...new Set([...Object.keys(A.data), ...Object.keys(B.data)])].sort()) {
  const ra = A.data[t] || [], rb = B.data[t] || [];
  console.log(`table ${t}: rows ${ra.length} -> ${rb.length}`);
  const ids = [...new Set([...ra, ...rb].map(r => String(r.id ?? r.sequence ?? r.child_id ?? JSON.stringify(r))))];
  for (const id of ids) {
    const x = ra.find(r => String(r.id ?? r.sequence ?? JSON.stringify(r)) === id);
    const y = rb.find(r => String(r.id ?? r.sequence ?? JSON.stringify(r)) === id);
    if (!x) { console.log(`  + ADDED   ${id}`); differences++; continue; }
    if (!y) { console.log(`  - REMOVED ${id}`); differences++; continue; }
    for (const c of cols(t)) {
      if (JSON.stringify(x[c] ?? null) !== JSON.stringify(y[c] ?? null)) {
        console.log(`  ~ ${id} .${c}: ${JSON.stringify(x[c] ?? null).slice(0, 120)} -> ${JSON.stringify(y[c] ?? null).slice(0, 120)}`);
        differences++;
      }
    }
  }
}
const ia = A.schema.filter(r => r.type === 'index').map(r => `${r.name}:${r.sql}`).sort();
const ib = B.schema.filter(r => r.type === 'index').map(r => `${r.name}:${r.sql}`).sort();
console.log('indexes', JSON.stringify(ia) === JSON.stringify(ib) ? 'IDENTICAL' : 'DIFFER');
for (const i of ia) if (!ib.includes(i)) console.log(`  - index ${i}`);
for (const i of ib) if (!ia.includes(i)) console.log(`  + index ${i}`);
console.log(`TOTAL_DIFFERENCES=${differences}`);
