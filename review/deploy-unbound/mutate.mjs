// Literal-replacement mutator used by this review: it refuses a pattern that is absent or
// not unique, so a mutation that did not land can never be reported as "the suite stayed
// green". Usage: node mutate.cjs <cwd> '<json spec>'  where spec is [{file,from,to}].
// Build patterns that contain a literal backslash or newline with
// String.fromCharCode(92) / String.fromCharCode(10) - see mutations.sh.
import fs from 'node:fs';
import path from 'node:path';
const cwd = process.argv[2];
const specs = JSON.parse(process.argv[3]);
let bad = 0;
for (const m of specs) {
  const p = path.join(cwd, m.file);
  const s = fs.readFileSync(p, 'utf8');
  const n = s.split(m.from).length - 1;
  if (n !== 1) { console.error(`NOT APPLIED (${n} occurrences) ${m.file}: ${JSON.stringify(m.from.slice(0, 80))}`); bad = 1; continue; }
  fs.writeFileSync(p, s.replace(m.from, m.to));
  console.log(`applied ${m.file}: ${JSON.stringify(m.from.slice(0, 60))} -> ${JSON.stringify(m.to.slice(0, 60))}`);
}
process.exit(bad);
