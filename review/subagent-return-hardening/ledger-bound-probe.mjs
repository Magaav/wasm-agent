#!/usr/bin/env node
// The ledger-bound probe of review/subagent-return-hardening/VERDICT.md, section 5.
//
//   node review/subagent-return-hardening/ledger-bound-probe.mjs [delivered-tree]
//
// Writes `<tree>/scripts/zz-review-ledger-tie.cjs`, a copy of the delivered
// scripts/test-subagent-return-hook.cjs whose only change is the ledger seeding: 512 keys written with
// the *current* second as their `at` (so they tie with the key the pass is about to write) and names
// that sort before the child id in the JSON map's order, plus a diagnostic print instead of the
// delivered assertions about the seeded names. It answers one question: can the bound drop the key it
// just wrote, which would re-wake a child whose settle the ledger is supposed to dedupe?
//
// Observed twice on a68dfed: the new key was strictly newest (`child_at = seed second + 1`) and
// survived, with 511 seeds kept - the tie is not reachable at this node's wake rates. The probe is kept
// because it is the evidence for that statement, not because it is red.
import fs from 'node:fs';
import path from 'node:path';

const tree = path.resolve(process.argv[2] || path.join(path.dirname(new URL(import.meta.url).pathname.slice(1)), '..', '..'));
const source = fs.readFileSync(path.join(tree, 'scripts', 'test-subagent-return-hook.cjs'), 'utf8');

const seedOld = `  const seedAt = Math.floor(Date.now() / 1000);
  for (let index = 0; index < 520; index += 1) {
    ledgerSeeded.keys[\`synthetic-old-\${index}\`] = { at: seedAt - 100000 + index, delivery: 0 };
  }`;
const seedNew = `  const seedAt = Math.floor(Date.now() / 1000);
  for (let index = 0; index < 512; index += 1) {
    ledgerSeeded.keys[\`aaa-\${String(index).padStart(3, "0")}\`] = { at: seedAt, delivery: 0 };
  }`;
const checksOld = `  const pruned = Object.keys(JSON.parse(fs.readFileSync(ledgerFile, "utf8")).keys);
  check(pruned.length <= 512, \`the ledger is bounded after a wake (\${pruned.length} keys)\`);
  check(pruned.includes(reworkChild), "the key just written survives the bound");
  check(!pruned.includes("synthetic-old-0"), "the oldest key is dropped");
  check(pruned.includes("synthetic-old-519"), "the newest seeded key survives");
  check(pruned.filter((key) => key.startsWith("synthetic-old-")).length === 512 - CHILDREN.length,
    "and the bound keeps the newest by the time they were woken");`;
const checksNew = `  const raw = JSON.parse(fs.readFileSync(ledgerFile, "utf8")).keys;
  const pruned = Object.keys(raw);
  const seedAts = Object.entries(raw).filter(([key]) => key.startsWith("aaa-")).map(([, value]) => value.at);
  process.stdout.write(\`REVIEW-LEDGER keys=\${pruned.length} child_key_present=\${pruned.includes(reworkChild)} child_at=\${raw[reworkChild]?.at} seed_at_min=\${Math.min(...seedAts)} seed_at_max=\${Math.max(...seedAts)} kept_aaa=\${pruned.filter((key) => key.startsWith("aaa-")).length}\\\\n\`);
  check(pruned.length <= 512, \`the ledger is bounded after a wake (\${pruned.length} keys)\`);`;

if (!source.includes(seedOld) || !source.includes(checksOld)) {
  console.error('the delivered test no longer carries the anchors this probe mutates; re-read it');
  process.exit(4);
}
const variant = path.join(tree, 'scripts', 'zz-review-ledger-tie.cjs');
fs.writeFileSync(variant, source.replace(seedOld, seedNew).replace(checksOld, checksNew));
console.log(`wrote ${variant} - run it (twice, the second boundary is a timing question):`);
console.log(`  node ${path.relative(tree, variant).replace(/\\/g, '/')}`);
console.log('then delete it: it is a probe, not a suite.');
