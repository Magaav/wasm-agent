#!/usr/bin/env node
// One rule, one home.
//
// The instruction set used to state the landing procedure in three places, the merge trigger in two
// senses, and the authority over `main` in four - so a reader had to diff documents to find out which
// one was current, and the drift showed up as a human step in every landing. This check is the
// mechanical half of that refactor: a phrasing that was retired must not come back outside the one
// file that now owns the rule.
//
// What it is, exactly: a literal substring check over the instruction files, plus three structural
// assertions (each home still states its rule, each preserved rule still exists somewhere, and the
// injected file did not grow). It is NOT a semantic check and it does not read prose for meaning - a
// rule restated in different words passes. It fails on the phrasings this refactor retired, on a home
// that lost its rule, and on a preserved rule that disappeared.
//
// Three things are allowed, and each says why:
//   * a line carrying `instructions-check: allow` - for a document that must quote a retired phrasing
//     (a ledger, a changelog, this refactor's own record);
//   * the home file of a retired rule, which must still state it;
//   * the DEFERRED list below: duplicates in files this change does not own, each with its owner and
//     the edit it needs. They are printed every run, they never fail the check, and an entry that no
//     longer matches anything is reported as `resolved` so the list shrinks instead of rotting.
//
// Run: node scripts/check-instructions.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// The three homes. Every rule below belongs to exactly one of them.
const PROTOCOL = 'skills/git-orchestrator/SKILL.md'; // authority, lifecycle, lanes, landing steps
const PRODUCER = 'skills/parallel-evolution/SKILL.md'; // the per-turn producer loop
const RESERVATIONS = 'docs/CONCURRENCY.md'; // how many lanes fit, and what is serial

// AGENTS.md is injected into every request. Growing it is the regression this refactor removed, so the
// budget is the pre-refactor size (commit f962844: 10418 bytes) and it only goes down.
const INJECTED = 'AGENTS.md';
const INJECTED_BUDGET_BYTES = 10418;

// Each home must still state its rule, or the pointer that sends a reader there is a lie.
const HOMES = [
  { file: PROTOCOL, contains: [
    'The integration protocol', 'The authority statement', 'The lifecycle, stated once',
    'The lanes and what each may do', 'The landing steps', 'Manual entry points', 'merge lane'] },
  { file: PRODUCER, contains: ['#### Landing', 'skills/git-orchestrator/SKILL.md'] },
  { file: RESERVATIONS, contains: ['## Lane reservations and the serial gate', 'WA_GATE_JOBS'] },
  { file: INJECTED, contains: ['skills/git-orchestrator/SKILL.md', 'merge lane', 'The integration protocol'] },
  { file: 'AGENTS.orchestrator.md', contains: ['skills/git-orchestrator/SKILL.md'] },
  { file: 'docs/EVOLUTION.md', contains: ['skills/git-orchestrator/SKILL.md'] },
  { file: 'docs/ORCHESTRATION.md', contains: ['your branch is your deliverable'] },
  { file: 'docs/FACTORY.md', contains: [
    "An agent's report is evidence, not verification", 'No effect before its proof'] },
  { file: 'docs/MEMORY.md', contains: ['the only automatic injection'] },
];

// Retired phrasings. `home` is the one file allowed to keep the words (null = nowhere). Every other
// occurrence fails, unless it is declared DEFERRED below. `wasHome` records where it used to live, so
// the FAIL line says what moved.
const RETIRED = [
  { id: 'landing-actor', phrase: 'orchestrator session lands in the canonical checkout',
    home: null, wasHome: 'AGENTS.md',
    why: 'a session was the landing actor; the merge lane is, and it is a role a run takes' },
  { id: 'child-cannot-move-main', phrase: 'may not move `main` at all',
    home: null, wasHome: 'AGENTS.md',
    why: 'the rule is a lane rule, not a session-type rule' },
  { id: 'old-landing-section', phrase: 'Landing on `main`',
    home: null, wasHome: 'skills/parallel-evolution/SKILL.md',
    why: 'the landing procedure now lives under "The landing steps" in the protocol home' },
  { id: 'landing-procedure-name', phrase: 'The landing procedure',
    home: PROTOCOL, wasHome: 'docs/FACTORY.md',
    why: 'of three landing procedures, one survives' },
  { id: 'human-reviews', phrase: 'a human reviews the branch and merges',
    home: null, wasHome: 'docs/EVOLUTION.md',
    why: 'integration is a lane and runs without a human step' },
  { id: 'human-merges', phrase: 'the human merges',
    home: null, wasHome: 'docs/ORCHESTRATION.md',
    why: 'handoff is a push; the merge lane lands it' },
  { id: 'landing-procedure-pointer', phrase: 'The landing procedure is in',
    home: null, wasHome: 'AGENTS.md',
    why: 'the pointer names the protocol home' },
  { id: 'merge-trigger-owner', phrase: 'or the owner asks for integration',
    home: null, wasHome: 'skills/git-orchestrator/SKILL.md',
    why: '/merge is an entry point, not the trigger; the lane lands ready deliveries' },
  { id: 'merge-trigger-command', phrase: 'when /merge is invoked',
    home: null, wasHome: 'skills/git-orchestrator/SKILL.md',
    why: 'same' },
  { id: 'merge-permission', phrase: 'not grant permission to merge',
    home: null, wasHome: 'AGENTS.orchestrator.md',
    why: 'merging is standing authority; a completion notice is still not verification' },
  { id: 'staging-branch', phrase: 'to a clean staging branch',
    home: null, wasHome: 'skills/git-orchestrator/SKILL.md',
    why: 'the reviewed tips are merged onto the sanctioned tree, which is the tree that is pushed' },
  { id: 'own-checkout', phrase: 'Use your own clean integration checkout',
    home: null, wasHome: 'skills/git-orchestrator/SKILL.md', why: 'same' },
  { id: 'candidate-branch', phrase: 'short-lived candidate branch',
    home: null, wasHome: 'skills/git-orchestrator/SKILL.md', why: 'same' },
  { id: 'integrator-only', phrase: 'Only the integrator directly commits',
    home: null, wasHome: 'skills/parallel-evolution/SKILL.md',
    why: 'the authority statement is the one place this is said' },
  { id: 'hot-file-batch', phrase: 'one hot-file editor unlanded at a time',
    home: null, wasHome: 'docs/FACTORY.md',
    why: 'one unlanded editor per HOT FILE, not one per batch; everything else runs in parallel' },
  { id: 'human-promotion', phrase: 'Promotion is a human step',
    home: null, wasHome: 'docs/EVOLUTION.md',
    why: 'promotion is the deploy lane, through the sentinel' },
  { id: 'hook-refusal-session', phrase: 'the orchestrator merges it',
    home: null, wasHome: '.githooks/pre-commit',
    why: 'the hook cannot know the lane; it says the branch is the deliverable' },
  { id: 'hook-refusal-human', phrase: 'let the human merge',
    home: null, wasHome: '.githooks/commit-msg', why: 'same' },
  { id: 'factory-land-step', phrase: 'merge, gate the MERGED tree, push main, delete, prune',
    home: null, wasHome: 'docs/FACTORY.md',
    why: 'the pipeline points at the protocol instead of restating the landing' },
];

// Duplicates in files this change does not own, or must not edit. Printed, never fatal; an entry whose
// phrase is gone is reported `resolved` and should then be deleted from this list.
const DEFERRED = [
  { phrase: 'The landing procedure', file: 'docs/FACTORY.md', lineStartsWith: '##',
    owner: 'docs/FACTORY.md (another worker is adding its merge-lane section right now)',
    edit: 'replace "## The landing procedure" (7 steps) with a pointer to the protocol home' },
  { phrase: 'one hot-file editor unlanded at a time', file: 'docs/FACTORY.md',
    owner: 'docs/FACTORY.md',
    edit: 'say "one unlanded editor per hot file", and point at the protocol home' },
  { phrase: 'merge, gate the MERGED tree, push main, delete, prune', file: 'docs/FACTORY.md',
    owner: 'docs/FACTORY.md', edit: 'the `land` pipeline step points at the protocol home' },
  { phrase: 'the human merges', file: '.githooks/commit-msg',
    owner: '.githooks (a hard constraint of this change: do not edit the hooks)',
    edit: 'the header comment says AGENTS.md says "the human merges"' },
  { phrase: 'the orchestrator merges it', file: '.githooks/pre-commit',
    owner: '.githooks', edit: 'the refusal text should name the merge lane, not the orchestrator' },
  { phrase: 'the orchestrator merges it', file: '.githooks/commit-msg',
    owner: '.githooks', edit: 'the refusal text should name the merge lane, not the orchestrator' },
  { phrase: 'let the human merge', file: '.githooks/commit-msg',
    owner: '.githooks', edit: 'the refusal text should name the merge lane' },
  { phrase: 'the landing procedure in skills/parallel-evolution',
    file: 'scripts/test-main-guard.sh',
    owner: 'scripts/test-main-guard.sh (a test another worker may be editing)',
    edit: 'the comment names the old landing home; it is now skills/git-orchestrator/SKILL.md' },
];

// Rules this refactor only RELOCATED. Each must still exist in the file that now owns it: the point of
// the refactor was "one home per rule", never "a rule fewer".
const PRESERVED = [
  { rule: 'never touch the old plugin', home: 'AGENTS.md', phrase: 'Never touch the old plugin' },
  { rule: 'keep LF, and the hook is the contract', home: 'AGENTS.md', phrase: 'Keep LF' },
  { rule: 'the pre-commit hook enforces the stored bytes', home: '.githooks/pre-commit',
    phrase: 'Refuse a commit that stores CRLF' },
  { rule: 'install only through the gate, never from inside a run', home: 'AGENTS.md',
    phrase: 'Install only through the gate' },
  { rule: 'the sentinel verbs', home: 'AGENTS.md', phrase: 'wa-sentinel request upgrade' },
  { rule: 'never hand a POSIX path to a native Windows process', home: 'AGENTS.md',
    phrase: 'Never hand a POSIX path to a native Windows process' },
  { rule: 'never restart or replace the window', home: 'AGENTS.md',
    phrase: 'Never restart or replace the window' },
  { rule: 'memory is on demand', home: 'docs/MEMORY.md', phrase: 'the only automatic injection' },
  { rule: 'raw over compacted unless the loss is proven harmless', home: 'AGENTS.md',
    phrase: 'Raw over compacted' },
  { rule: 'know how you are risking', home: 'AGENTS.md', phrase: 'Know how you are risking' },
  { rule: 'verify before claiming', home: 'AGENTS.md', phrase: 'Verify before claiming' },
  { rule: 'a skipped test is reported as skipped', home: 'AGENTS.md',
    phrase: 'skipped test is reported as skipped' },
  { rule: "an agent's report is evidence, not verification", home: 'docs/FACTORY.md',
    phrase: "An agent's report is evidence, not verification" },
  { rule: 'no effect before its proof', home: 'docs/FACTORY.md', phrase: 'No effect before its proof' },
  { rule: "a child's branch is its deliverable", home: 'skills/git-orchestrator/SKILL.md',
    phrase: 'never moves `main`' },
  { rule: 'the merge lane is the only actor that moves `main`',
    home: PROTOCOL, phrase: 'the merge lane, and only the merge lane' },
];

const SKIP_DIRS = new Set(['.git', 'node_modules', 'target', 'graph', 'operations', 'tmp']);

function walk(dir, out = []) {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    const rel = path.relative(root, full).split(path.sep).join('/');
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name) || rel === 'releases') continue;
      walk(full, out);
    } else out.push(rel);
  }
  return out;
}

function scanSet() {
  const all = walk(root);
  const pick = file =>
    (/^AGENTS[^/]*\.md$/.test(file)) ||
    (/^docs\/.*\.md$/.test(file)) ||
    (/^skills\/[^/]+\/SKILL\.md$/.test(file)) ||
    (/^\.githooks\/[^/]+$/.test(file)) ||
    (file === 'scripts/test-main-guard.sh');
  return all.filter(pick).sort();
}

const files = scanSet();
const sources = new Map();
for (const file of files) {
  const bytes = fs.readFileSync(path.join(root, file));
  sources.set(file, { text: bytes.toString('utf8'), bytes: bytes.length });
}

const failures = [];
const allowed = [];
let checks = 0;
const ok = (label, detail = '') => { checks++; console.log(`  ok   ${label}${detail ? ' - ' + detail : ''}`); };
const fail = (label, detail = '') => { checks++; failures.push(label); console.log(`  FAIL ${label}${detail ? ' - ' + detail : ''}`); };

function occurrences(phrase) {
  const hits = [];
  for (const [file, { text }] of sources) {
    text.split('\n').forEach((line, index) => {
      if (!line.includes(phrase)) return;
      if (line.includes('instructions-check: allow')) { allowed.push({ file, line: index + 1, phrase }); return; }
      hits.push({ file, line: index + 1 });
    });
  }
  return hits;
}

function contains(file, phrase) {
  const source = sources.get(file);
  return Boolean(source && source.text.includes(phrase));
}

function deferredHits(entry) {
  return occurrences(entry.phrase).filter(hit => {
    if (hit.file !== entry.file) return false;
    if (!entry.lineStartsWith) return true;
    return sources.get(hit.file).text.split('\n')[hit.line - 1].startsWith(entry.lineStartsWith);
  });
}

console.log(`check-instructions: one rule, one home`);
console.log(`  root: ${root}`);
console.log(`  injected: ${INJECTED} (${sources.get(INJECTED)?.bytes ?? '?'} B, budget ${INJECTED_BUDGET_BYTES} B)`);
console.log(`  protocol home: ${PROTOCOL}`);
console.log(`  scanned ${files.length} instruction files:`);
for (const file of files) console.log(`    ${file} (${sources.get(file).bytes} B)`);

console.log('\n1. every home still states its rule');
for (const { file, contains: phrases } of HOMES) {
  const missing = phrases.filter(phrase => !contains(file, phrase));
  if (missing.length) fail(`home ${file}`, `missing ${missing.map(p => JSON.stringify(p)).join(', ')}`);
  else ok(`home ${file}`, `${phrases.length} statements present`);
}

console.log('\n2. a retired phrasing stays retired (outside its home)');
for (const rule of RETIRED) {
  const hits = occurrences(rule.phrase);
  const wrong = hits.filter(hit => hit.file !== rule.home &&
    !DEFERRED.some(entry => entry.file === hit.file && entry.phrase === rule.phrase));
  const homeKeeps = rule.home ? hits.some(hit => hit.file === rule.home) : true;
  const deferred = hits.length - wrong.length - (rule.home ? hits.filter(h => h.file === rule.home).length : 0);
  const suffix = deferred > 0 ? ` (${deferred} deferred)` : '';
  if (wrong.length)
    fail(`retired "${rule.phrase}"`, `${wrong.map(h => `${h.file}:${h.line}`).join(', ')} - it was ${rule.wasHome}'s; ${rule.why}`);
  else if (!homeKeeps)
    fail(`retired "${rule.phrase}"`, `the home ${rule.home} no longer states it`);
  else ok(`retired "${rule.phrase}"`, (rule.home ? `only in ${rule.home}` : 'nowhere') + suffix);
}

console.log('\n3. a relocated rule did not become a missing rule');
for (const { rule, home, phrase } of PRESERVED) {
  if (contains(home, phrase)) ok(`preserved "${rule}"`, `home ${home}`);
  else fail(`preserved "${rule}"`, `not found in its home ${home} (${JSON.stringify(phrase)})`);
}

console.log('\n4. the injected file did not grow');
{
  const bytes = sources.get(INJECTED).bytes;
  if (bytes <= INJECTED_BUDGET_BYTES) ok(`${INJECTED} within budget`, `${bytes} <= ${INJECTED_BUDGET_BYTES} B`);
  else fail(`${INJECTED} grew`, `${bytes} > ${INJECTED_BUDGET_BYTES} B - move detail to a doc that loads on demand`);
}

console.log('\n5. known duplicates in files this change does not own (not fatal, printed every run)');
let deferred = 0;
for (const entry of DEFERRED) {
  const where = deferredHits(entry);
  if (!where.length) { console.log(`  resolved  ${entry.file} "${entry.phrase}"`); continue; }
  deferred++;
  for (const hit of where)
    console.log(`  DEFERRED  ${hit.file}:${hit.line} "${entry.phrase}"\n              owner: ${entry.owner}\n              edit:  ${entry.edit}`);
}
if (allowed.length) {
  console.log('\n6. lines exempted by `instructions-check: allow`');
  for (const hit of allowed) console.log(`  allowed   ${hit.file}:${hit.line} "${hit.phrase}"`);
}
if (!deferred) console.log('  (none)');

console.log(`\ncheck-instructions: ${failures.length ? 'FAIL' : 'PASS'} (${checks} checks, ${files.length} files, ${deferred} deferred, ${allowed.length} allowed)`);
if (failures.length) { for (const failure of failures) console.log(`  failed: ${failure}`); process.exitCode = 1; }
