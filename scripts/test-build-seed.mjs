#!/usr/bin/env node
// A NEW target dir is SEEDED from the newest sibling built by the same toolchain - and a seeded build is
// still the tree's own build.
//
// The day this answers for (21/11): every new worktree, landing tree and land gate compiled from cold,
// because ea_build_target gives every tree its own child of the one build root (docs/ONEROOT.md, rule 2).
// Measured on this node: cold wa-host release 144 s, the same build into a child seeded from a sibling
// 61 s (a tree at another commit) and 64 s (same commit, one crate changed).
//
// What a seed may NOT do is make a tree run code it does not have. This test builds two checkouts of one
// tiny two-member workspace whose library answers a DIFFERENT number in each tree, seeds the second from
// the first, and asserts the second prints ITS number, not the seed's. A seed that substituted its own
// artifacts for compiling the tree would print base=1 and go red here.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {treeName} from './codemode-build.mjs';

const REPO = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const RESOLVER = path.join(REPO, 'scripts', 'lib', 'build-target.sh');
const WORK = fs.mkdtempSync(path.join(process.env.WA_SEED_SCRATCH || os.homedir(), 'wa-seed-'));
const HOME = path.join(WORK, 'home');
const TARGET_ROOT = path.join(HOME, '.wasm-agent', 'build', 'target');
fs.mkdirSync(TARGET_ROOT, {recursive: true});
// tmpfs at /dev/shm is where reflink does NOT work: that is how the "no reflink, no full copy" rule is
// driven with a real filesystem answer instead of a hand-set flag.
const NO_REFLINK_ROOT = '/dev/shm';

let passed = 0;
function check(name, condition, detail = '') {
  if (!condition) {
    console.error('build-seed: assert failed - ' + name + (detail ? ': ' + detail : ''));
    process.exitCode = 1;
    throw new Error('check failed: ' + name);
  }
  passed += 1;
  console.log('ok - ' + name);
}

// Every row writes into this test's own home; the live node's build root is never touched.
if (HOME === path.join(os.homedir(), '.wasm-agent') || HOME.includes('/.wasm-agent/build/target/j')) {
  throw new Error('build-seed: refusing to run against a real home: ' + HOME);
}
const ENV = {...process.env, WASM_AGENT_HOME: HOME};
delete ENV.CARGO_TARGET_DIR;
delete ENV.WA_BUILD_SEED;

const bash = (script, extraEnv = {}, cwd = REPO) => spawnSync('bash', ['-c', script], {
  encoding: 'utf8', cwd, env: {...ENV, ...extraEnv}, timeout: 300000,
});

function makeTree(dir, value) {
  fs.mkdirSync(path.join(dir, 'base', 'src'), {recursive: true});
  fs.mkdirSync(path.join(dir, 'app', 'src'), {recursive: true});
  fs.mkdirSync(path.join(dir, 'rust', 'wa-host-support'), {recursive: true});
  fs.mkdirSync(path.join(dir, '.git'), {recursive: true});
  fs.writeFileSync(path.join(dir, 'Cargo.toml'), '[workspace]\nmembers = ["base", "app"]\nresolver = "2"\n');
  fs.writeFileSync(path.join(dir, 'base', 'Cargo.toml'), '[package]\nname = "base"\nversion = "0.1.0"\nedition = "2021"\n');
  fs.writeFileSync(path.join(dir, 'base', 'src', 'lib.rs'), 'pub fn v() -> i32 { ' + value + ' }\n');
  fs.writeFileSync(path.join(dir, 'app', 'Cargo.toml'),
    '[package]\nname = "app"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\nbase = { path = "../base" }\n');
  fs.writeFileSync(path.join(dir, 'app', 'src', 'main.rs'), 'fn main() { println!("base={}", base::v()); }\n');
  fs.writeFileSync(path.join(dir, 'rust', 'wa-host-support', 'Cargo.toml'),
    '[package]\nname = "wa-host-support"\nversion = "0.1.0"\nedition = "2021"\n');
  return dir;
}

const TREE_A = makeTree(path.join(WORK, 'wt-alpha'), 1);
const TREE_B = makeTree(path.join(WORK, 'wt-beta'), 2);

const build = (tree, extraEnv = {}) => bash(
  '. "' + RESOLVER + '"; wa_build_run "' + tree + '" cargo build --offline -q --manifest-path Cargo.toml',
  extraEnv);
const childOf = (tree) => path.join(TARGET_ROOT, treeName(tree));
const say = (r) => String(r.stdout || '') + String(r.stderr || '');

// ---- the seed itself --------------------------------------------------------------------------------
{
  const a = build(TREE_A);
  check('the first tree builds (cold: nothing to seed from)', a.status === 0, say(a).slice(-600));
  check('a cold build is not announced as seeded', !say(a).includes('seeded'), say(a).slice(-300));

  // A REAL worktree is checked out AFTER the sibling it seeds from (git worktree add writes every file
  // now). Give TREE_B fresh mtimes so this fixture has the ordering real use has: an artifact from the
  // future is refused by design and is exercised separately below.
  const later = new Date(Date.now() + 2000);
  for (const dir of [TREE_B]) {
    for (const f of fs.readdirSync(dir, {recursive: true})) {
      const p = path.join(dir, f.toString());
      if (fs.statSync(p, {throwIfNoEntry: false})?.isFile()) fs.utimesSync(p, later, later);
    }
  }
  const b = build(TREE_B);
  check('the second tree builds', b.status === 0, say(b).slice(-600));
  check('the second tree was SEEDED from the first', say(b).includes('onebuild: seeded '), say(b).slice(-400));
  check('the seed names the sibling it came from', say(b).includes(path.basename(childOf(TREE_A))), say(b).slice(-400));

  // THE POINT: the seeded build is still the tree's own build.
  const binB = path.join(childOf(TREE_B), 'debug', 'app');
  check('the seeded tree produced its own binary', fs.existsSync(binB), binB);
  const outB = String(spawnSync(binB, [], {encoding: 'utf8'}).stdout || '').trim();
  check('the seeded tree ran ITS OWN library (base=2, not the seed\'s base=1)', outB === 'base=2', outB);

  // And the tree it was seeded FROM is untouched by the copy.
  const outA = String(spawnSync(path.join(childOf(TREE_A), 'debug', 'app'), [], {encoding: 'utf8'}).stdout || '').trim();
  check('the tree it was seeded from still runs its own library (base=1)', outA === 'base=1', outA);
}

// ---- a changed crate is rebuilt, never served from the seed -----------------------------------------
{
  fs.writeFileSync(path.join(TREE_B, 'base', 'src', 'lib.rs'), 'pub fn v() -> i32 { 3 }\n');
  const r = build(TREE_B);
  check('a tree with one changed crate rebuilds', r.status === 0, say(r).slice(-600));
  const out = String(spawnSync(path.join(childOf(TREE_B), 'debug', 'app'), [], {encoding: 'utf8'}).stdout || '').trim();
  check('the rebuilt binary carries the change (base=3)', out === 'base=3', out);
}

// ---- an artifact from the future is refused, and an older sibling is used instead ---------------------
// The bug this catches was found by this test on 21/11: a tree older than the sibling it was seeded from
// ran the SIBLING's code (base=1 instead of base=2), because cargo compared mtimes and believed the
// seeded artifacts were current. The cutoff (the tree's newest source) is what refuses it.
{
  const TREE_F = makeTree(path.join(WORK, 'wt-zeta'), 5);
  const OLD = new Date(Date.now() - 600000);
  for (const f of fs.readdirSync(TREE_F, {recursive: true})) {
    const p = path.join(TREE_F, f.toString());
    if (fs.statSync(p, {throwIfNoEntry: false})?.isFile()) fs.utimesSync(p, OLD, OLD);
  }
  const r = build(TREE_F);
  check('a tree older than every sibling still builds', r.status === 0, say(r).slice(-600));
  check('it is NOT seeded from an artifact newer than its own sources', !say(r).includes('onebuild: seeded '), say(r).slice(-500));
  const out = String(spawnSync(path.join(childOf(TREE_F), 'debug', 'app'), [], {encoding: 'utf8'}).stdout || '').trim();
  check('and it runs ITS OWN library, never a newer sibling code (base=5)', out === 'base=5', out);
}

// ---- what is never a seed ---------------------------------------------------------------------------
{
  // A child with no toolchain record: unknown is not yes.
  const TREE_C = makeTree(path.join(WORK, 'wt-gamma'), 1);
  const lonely = path.join(TARGET_ROOT, 'wt-nomarker-aaaaaaaaaaaa');
  fs.mkdirSync(path.join(lonely, 'debug'), {recursive: true});
  const r = build(TREE_C, {WA_BUILD_SEED: '1'});
  check('a tree with no sibling still builds', r.status === 0, say(r).slice(-600));
  check('a child with no toolchain record is never a seed', !say(r).includes(lonely), say(r).slice(-400));

  // A different toolchain: an artifact another rustc made is not reusable.
  const other = path.join(TARGET_ROOT, 'wt-othertool-aaaaaaaaaaaa');
  fs.mkdirSync(path.join(other, 'debug'), {recursive: true});
  fs.writeFileSync(path.join(other, 'toolchain'), 'not-this-compiler');
  const TREE_D = makeTree(path.join(WORK, 'wt-delta'), 1);
  const rd = build(TREE_D);
  check('a child of another toolchain is never a seed', !say(rd).includes(other), say(rd).slice(-400));

  // WA_BUILD_SEED=0 is the deliberate cold build.
  const TREE_E = makeTree(path.join(WORK, 'wt-epsilon'), 1);
  const re = build(TREE_E, {WA_BUILD_SEED: '0'});
  check('WA_BUILD_SEED=0 builds cold on purpose', re.status === 0 && !say(re).includes('seeded'), say(re).slice(-400));
}

// ---- reflink unsupported: cold, never a full copy ---------------------------------------------------
{
  if (!fs.existsSync(NO_REFLINK_ROOT) || spawnSync('bash', ['-c', 'cp --reflink=always /etc/hostname ' + NO_REFLINK_ROOT + '/rl-probe-$$ 2>/dev/null'], {encoding: 'utf8'}).status === 0) {
    console.log('skip - reflink is supported on ' + NO_REFLINK_ROOT + ', so the no-reflink path cannot be driven there');
  } else {
    // The HOME (and so the build root, and so both the seed candidate and the copy) must be on the
    // non-reflink filesystem: reflink is a property of where the copy LANDS, not of the tree.
    const tmpHome = fs.mkdtempSync(path.join(NO_REFLINK_ROOT, 'wa-seed-home-'));
    fs.mkdirSync(path.join(tmpHome, '.wasm-agent', 'build', 'target'), {recursive: true});
    const tA = makeTree(path.join(WORK, 'wt-shmA'), 1);
    const tB = makeTree(path.join(WORK, 'wt-shmB'), 2);
    const envT = {WASM_AGENT_HOME: tmpHome};
    const rA = bash('. "' + RESOLVER + '"; wa_build_run "' + tA + '" cargo build --offline -q --manifest-path Cargo.toml', envT);
    // Checked out after the sibling, as a real worktree is: the seed must be older than this tree.
    const laterShm = new Date(Date.now() + 2000);
    for (const f of fs.readdirSync(tB, {recursive: true})) {
      const p = path.join(tB, f.toString());
      if (fs.statSync(p, {throwIfNoEntry: false})?.isFile()) fs.utimesSync(p, laterShm, laterShm);
    }
    check('the tmpfs first tree builds', rA.status === 0, say(rA).slice(-500));
    const rB = bash('. "' + RESOLVER + '"; wa_build_run "' + tB + '" cargo build --offline -q --manifest-path Cargo.toml', envT);
    const out = say(rB);
    check('without reflink the build says it starts cold instead of being seeded', out.includes('reflink is not supported'), out.slice(-400));
    const seededDir = path.join(tmpHome, '.wasm-agent', 'build', 'target', treeName(tB));
    const sizeA = Number(String(spawnSync('du', ['-sb', path.join(tmpHome, '.wasm-agent', 'build', 'target', treeName(tA))], {encoding: 'utf8'}).stdout || '').split('\t')[0] || 0);
    const sizeB = Number(String(spawnSync('du', ['-sb', seededDir], {encoding: 'utf8'}).stdout || '').split('\t')[0] || 0);
    check('it was never a full copy (no seed blocks were paid for)', sizeB < sizeA * 2, 'A=' + sizeA + ' B=' + sizeB);
    const bin = path.join(seededDir, 'debug', 'app');
    check('the cold tree still produced its own binary', fs.existsSync(bin) && String(spawnSync(bin, [], {encoding: 'utf8'}).stdout || '').trim() === 'base=2', bin);
  }
}

console.log('build-seed ok (' + passed + ' checks)');
