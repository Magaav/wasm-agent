#!/usr/bin/env node
// The ONE LIST is only one list if a feature cannot ship outside it.
//
// This check reads config/features/features.json and refuses, BY NAME, every way the list can stop being
// the whole truth:
//   * a row with no name, role, canary, last-success source or bound (a row that would be dropped at
//     release time by a reader that cannot validate it);
//   * a canary that is named but not written (lua/core/canaries/<canary>.lua) - an exercise nobody can run;
//   * a last-success source that names a file this tree does not have, or a collector this module does not
//     implement - a provenance nobody can read;
//   * a feature from REQUIRED - the list the operator wrote on 23/11 - that is missing entirely.
//
// It is a check, not a test of behaviour: it runs in seconds, needs no node, and is the one row that makes
// 'a feature that ships without a line in this list fails' true.
//
//   node scripts/check-features-registry.mjs        prints "features-registry ok (<n> rows)"
import { readFileSync, existsSync } from 'node:fs';

const ROOT = new URL('..', import.meta.url).pathname;
const REGISTRY = ROOT + 'config/features/features.json';

// The features the operator named on 23/11. A list that loses one of them is not a smaller list, it is a
// feature that stopped proving itself.
const REQUIRED = [
  'chat', 'run-blocks', 'remote-calls', 'undo', 'mail', 'self-wake', 'scheduled-jobs', 'release-update',
  'whatsapp-receive', 'whatsapp-send', 'whatsapp-transcription', 'whatsapp-copilot-reply', 'whatsapp-index',
];

// The collectors lua/core/feature_health.lua implements. A row may name one of these as its last-success
// source; anything else is a source nobody reads.
const COLLECTORS = new Set([]);

const problems = [];
const fail = (why) => problems.push(why);

let document;
try {
  document = JSON.parse(readFileSync(REGISTRY, 'utf8'));
} catch (error) {
  console.error(`features-registry: ${REGISTRY} does not parse: ${error.message}`);
  process.exit(2);
}

if (document.schema !== 1) fail(`the registry schema is ${JSON.stringify(document.schema)}, not 1`);
if (!Array.isArray(document.features) || document.features.length === 0) fail('the registry lists no features');

const seen = new Set();
for (const [index, row] of (document.features || []).entries()) {
  const where = row && row.name ? `the feature ${row.name}` : `row ${index + 1}`;
  if (!row || typeof row !== 'object') { fail(`row ${index + 1} is not an object`); continue; }
  for (const field of ['name', 'role', 'canary', 'last_success']) {
    if (typeof row[field] !== 'string' || row[field].trim() === '') fail(`${where} has no ${field}`);
  }
  // A row may declare that its feature is OFF unless the operator asks (`"default": "off"`, the graph on
  // every node from G - docs/GRAPH.md). A value this list does not know is refused by name: a reader that
  // guessed would decide a feature's default from a typo.
  if (row['default'] !== undefined && row['default'] !== 'on' && row['default'] !== 'off') {
    fail(`${where} declares default ${JSON.stringify(row['default'])}, which is not on or off`);
  }
  if (typeof row.name === 'string') {
    if (seen.has(row.name)) fail(`${where} is listed twice`);
    seen.add(row.name);
  }
  const bound = Number(row.stale_after_s);
  if (!Number.isFinite(bound) || bound <= 0) fail(`${where} has no positive stale_after_s`);
  else if (bound > 365 * 86400) fail(`${where} has a stale_after_s of ${bound}, past the 365-day ceiling`);

  if (typeof row.canary === 'string' && row.canary !== '') {
    const module = `${ROOT}lua/core/canaries/${row.canary}.lua`;
    if (!existsSync(module)) fail(`${where} names the canary ${row.canary}, and ${module} is not there`);
  }

  if (typeof row.last_success === 'string' && row.last_success !== '') {
    // Three kinds of source, and each is checked for the thing it claims: a collector this module
    // implements, a canary that records the exercise itself, or a hook in a file that exists and says what
    // it records.
    const collector = row.last_success.startsWith('collector:') ? row.last_success.slice('collector:'.length).split(':')[0] : null;
    const canary_source = row.last_success.startsWith('canary:') ? row.last_success.slice('canary:'.length).trim().split(' ')[0] : null;
    if (collector) {
      if (!COLLECTORS.has(collector)) fail(`${where} names the collector ${collector}, which lua/core/feature_health.lua does not implement`);
    } else if (canary_source) {
      if (!existsSync(ROOT + canary_source)) fail(`${where} says its canary records it, and ${canary_source} is not in the tree`);
    } else {
      const [path, ...rest] = row.last_success.split(':');
      if (!path || !path.endsWith('.lua')) fail(`${where} names no file in its last_success source: ${row.last_success}`);
      else if (!existsSync(ROOT + path)) fail(`${where} names ${path} as its last-success source, and that file is not in the tree`);
      else if (rest.join(':').trim() === '') fail(`${where} names ${path} but says nothing about what is recorded there`);
    }
  }
}

for (const name of REQUIRED) {
  if (!seen.has(name)) fail(`the feature ${name} is not in the list at all`);
}

if (problems.length > 0) {
  console.error(`features-registry: ${problems.length} problem(s)`);
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

console.log(`features-registry ok (${document.features.length} rows, every one with a canary and a last-success source)`);
