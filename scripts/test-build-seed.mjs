#!/usr/bin/env node
// A NEW target dir is SEEDED from a sibling built from THE SAME SOURCE - and a seeded build is still the
// tree's own build.
//
// The day this answers for (21/11): every new worktree, landing tree and land gate compiled from cold,
// because wa_build_target gives every tree its own child of the one build root (docs/ONEROOT.md, rule 2).
// Measured on this node: cold wa-host release 135 s, the same build into a child seeded from a sibling
// 61 s (a tree at another commit) and 64 s (one changed crate).
//
// WHY "THE SAME SOURCE" AND NOT "THE NEWEST SIBLING". Cargo decides an artifact is current by comparing
// mtimes, so a sibling built AFTER this tree's sources were written hands over artifacts cargo keeps - and
// the seeded tree ran the SIBLING's code. Measured here on 21/11: a tree whose library answered 2, seeded
// from a sibling answering 1, printed base=1. The condition a seed must meet is therefore that its
// artifacts were produced from the same source (commit + tracked rust/lua state). Identical source means a
// rebuild would produce exactly those bytes; anything else is a cold build, by name.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {treeName} from './codemode-build.mjs';

const REPO = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const RESOLVER = path.join(REPO, 'scripts', 'lib', 'build-target.sh');
// The build root must sit on a filesystem where reflink works (btrfs): os.tmpdir() is tmpfs on this node,
// where every copy would take the cold path and the test would prove nothing.
const WORK = fs.mkdtempSync(path.join(process.env.WA_SEED_SCRATCH || os.homedir(), 'wa-seed-'));
const HOME = path.join(WORK, 'home');
const ROOT = path.join(HOME, '.wasm-agent');
const TARGET_ROOT = path.join(ROOT, 'build', 'target');
fs.mkdirSync(TARGET_ROOT, {recursive: true});
if (HOME === path.join(os.homedir(), '.wasm-agent')) throw new Error('refusing to run against a real home');
const NO_REFLINK_ROOT = '/dev/shm';

let passed = 0;
function check(name, condition, detail) {
  if (!condition) {
    console.error('build-seed: assert failed - ' + name + (detail ? ': ' + detail : ''));
    process.exitCode = 1;
    throw new Error('check failed: ' + name);
  }
  passed += 1;
  console.log('ok - ' + name);
}
const ENV = {...process.env, WASM_AGENT_HOME: HOME, WA_BUILD_SWEEP: '0'}; // never sweep the real repo's worktrees (21/11)
delete ENV.CARGO_TARGET_DIR;
delete ENV.WA_BUILD_SEED;
delete ENV.WA_BUILD_SEED_IDENTITY;
const bash = (script, extraEnv = {}) => spawnSync('bash', ['-c', script], {encoding: 'utf8', env: {...ENV, ...extraEnv}, timeout: 300000});
const say = (r) => String(r.stdout || '') + String(r.stderr || '');
const NL = String.fromCharCode(10);

// One tiny two-member workspace: app links base, so a tree that runs another tree's library prints the
// other tree's value.
function makeTree(dir, value) {
  fs.mkdirSync(path.join(dir, 'base', 'src'), {recursive: true});
  fs.mkdirSync(path.join(dir, 'app', 'src'), {recursive: true});
  fs.mkdirSync(path.join(dir, 'rust', 'wa-host-support'), {recursive: true});
  fs.writeFileSync(path.join(dir, 'Cargo.toml'), '[workspace]' + NL + 'members = ["base", "app"]' + NL + 'resolver = "2"' + NL);
  fs.writeFileSync(path.join(dir, 'base', 'Cargo.toml'), '[package]' + NL + 'name = "base"' + NL + 'version = "0.1.0"' + NL + 'edition = "2021"' + NL);
  fs.writeFileSync(path.join(dir, 'base', 'src', 'lib.rs'), 'pub fn v() -> i32 { ' + value + ' }' + NL);
  fs.writeFileSync(path.join(dir, 'app', 'Cargo.toml'), '[package]' + NL + 'name = "app"' + NL + 'version = "0.1.0"' + NL + 'edition = "2021"' + NL + '[dependencies]' + NL + 'base = { path = "../base" }' + NL);
  fs.writeFileSync(path.join(dir, 'app', 'src', 'main.rs'), 'fn main() { println!("base={}", base::v()); }' + NL);
  fs.writeFileSync(path.join(dir, 'rust', 'wa-host-support', 'Cargo.toml'), '[package]' + NL + 'name = "wa-host-support"' + NL + 'version = "0.1.0"' + NL + 'edition = "2021"' + NL);
  // A real repository: the seed rule is the SOURCE, which is the commit plus the state of the tracked
  // rust/lua trees, so a fixture without git can never be a seed (and says so by name).
  spawnSync('git', ['init', '-q'], {cwd: dir, encoding: 'utf8'});
  spawnSync('git', ['add', '-A'], {cwd: dir, encoding: 'utf8'});
  spawnSync('git', ['-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'fixture'], {cwd: dir, encoding: 'utf8'});
  return dir;
}
const build = (tree, extraEnv = {}) => bash(
  '. "' + RESOLVER + '"; wa_build_run "' + tree + '" cargo build --offline -q --manifest-path Cargo.toml', extraEnv);
const childOf = (tree) => path.join(TARGET_ROOT, treeName(tree));
const runOne = (bin) => String(spawnSync(bin, [], {encoding: 'utf8'}).stdout || '').trim().split(NL)[0];

// ---- 1. the same source at another path: seeded, and the seed is the tree's own build ---------------
const TREE_A = makeTree(path.join(WORK, 'wt-alpha'), 1);
// TREE_B is a real git worktree of TREE_A at the same commit and clean, which is exactly what a landing
// tree or a mission worktree of one commit is.
const TREE_B = path.join(WORK, 'wt-beta');
spawnSync('git', ['worktree', 'add', '-q', '--detach', TREE_B, 'HEAD'], {cwd: TREE_A, encoding: 'utf8'});
{
  const a = build(TREE_A);
  check('the first tree builds (cold: nothing to seed from)', a.status === 0, say(a).slice(-600));
  check('a cold build is not announced as seeded', !say(a).includes('onebuild: seeded '), say(a).slice(-300));

  const b = build(TREE_B);
  check('the second tree builds', b.status === 0, say(b).slice(-600));
  check('the second tree was SEEDED from the first', say(b).includes('onebuild: seeded '), say(b).slice(-400));
  check('the seed names the sibling it came from', say(b).includes(path.basename(childOf(TREE_A))), say(b).slice(-400));
  const binB = path.join(childOf(TREE_B), 'debug', 'app');
  check('the seeded tree produced its own binary', fs.existsSync(binB), binB);
  check('and it runs the code of this source (base=1)', runOne(binB) === 'base=1', runOne(binB));
  check('the child records the source identity it was built from',
    fs.readFileSync(path.join(childOf(TREE_B), 'identity'), 'utf8').trim().length > 20);
}

// ---- 2. a changed crate is REBUILT, never served from the seed --------------------------------------
{
  // The change lands after the seed was made, as a developer's edit does, and carries a marker that exists
  // only in this tree: the rebuilt binary must contain it.
  fs.writeFileSync(path.join(TREE_B, 'base', 'src', 'lib.rs'),
    'pub fn v() -> i32 { 3 }' + NL + 'pub const TAG: &str = "gatespeed-seed-7c1e";' + NL);
  fs.writeFileSync(path.join(TREE_B, 'app', 'src', 'main.rs'),
    'fn main() { println!("base={}", base::v()); println!("{}", base::TAG); }' + NL);
  const r = build(TREE_B);
  check('a tree with one changed crate rebuilds', r.status === 0, say(r).slice(-600));
  const bin = path.join(childOf(TREE_B), 'debug', 'app');
  check('the rebuilt binary carries the change (base=3)', runOne(bin) === 'base=3', runOne(bin));
  const marker = 'gatespeed-seed-7c1e';
  check('the marker string from the change is IN the built binary', fs.readFileSync(bin).includes(Buffer.from(marker)), marker);
  check('the origin binary does NOT carry this tree marker',
    !fs.readFileSync(path.join(childOf(TREE_A), 'debug', 'app')).includes(Buffer.from(marker)));
}

// ---- 3. a DIFFERENT source is never a seed ---------------------------------------------------------
{
  // The same commit plus an uncommitted edit is a different source, so its artifacts must not be reused.
  // This is the bug found by this test on 21/11 (a tree older than its sibling ran the sibling's code).
  const TREE_C = path.join(WORK, 'wt-gamma');
  spawnSync('git', ['worktree', 'add', '-q', '--detach', TREE_C, 'HEAD'], {cwd: TREE_A, encoding: 'utf8'});
  fs.writeFileSync(path.join(TREE_C, 'base', 'src', 'lib.rs'), 'pub fn v() -> i32 { 7 }' + NL);
  const r = build(TREE_C);
  check('a tree with an uncommitted edit still builds', r.status === 0, say(r).slice(-600));
  check('it is NOT seeded from a tree with a different source', !say(r).includes('onebuild: seeded '), say(r).slice(-500));
  check('and it runs its own edit (base=7)', runOne(path.join(childOf(TREE_C), 'debug', 'app')) === 'base=7');
}

// ---- 4. what is never a seed, and the deliberate cold build -----------------------------------------
{
  const TREE_D = makeTree(path.join(WORK, 'wt-delta'), 4);
  const other = path.join(TARGET_ROOT, 'wt-othertool-aaaaaaaaaaaa');
  fs.mkdirSync(path.join(other, 'debug'), {recursive: true});
  fs.writeFileSync(path.join(other, 'toolchain'), 'not-this-compiler');
  const rd = build(TREE_D);
  check('a tree with no same-source sibling still builds', rd.status === 0, say(rd).slice(-600));
  check('a child of another toolchain is never a seed', !say(rd).includes(other), say(rd).slice(-400));

  const noMarker = path.join(TARGET_ROOT, 'wt-nomarker-aaaaaaaaaaaa');
  fs.mkdirSync(path.join(noMarker, 'debug'), {recursive: true});
  const TREE_E = makeTree(path.join(WORK, 'wt-epsilon'), 5);
  const re = build(TREE_E);
  check('a child with no toolchain/identity record is never a seed', !say(re).includes(noMarker), say(re).slice(-400));

  const TREE_F = makeTree(path.join(WORK, 'wt-zeta'), 6);
  const rf = build(TREE_F, {WA_BUILD_SEED: '0'});
  check('WA_BUILD_SEED=0 builds cold on purpose', rf.status === 0 && !say(rf).includes('onebuild: seeded '), say(rf).slice(-400));
}

// ---- 5. reflink unsupported: cold, never a full copy ------------------------------------------------
{
  const probe = spawnSync('bash', ['-c', 'echo x > ' + NO_REFLINK_ROOT + '/rl-probe-$$ && cp --reflink=always ' + NO_REFLINK_ROOT + '/rl-probe-$$ ' + NO_REFLINK_ROOT + '/rl-probe2-$$'], {encoding: 'utf8'});
  if (!fs.existsSync(NO_REFLINK_ROOT) || probe.status === 0) {
    console.log('skip - reflink works on ' + NO_REFLINK_ROOT + ', so the no-reflink path cannot be driven there');
  } else {
    // The HOME (and so the child, and so where the copy lands) must be on the non-reflink filesystem.
    const tmpHome = fs.mkdtempSync(path.join(NO_REFLINK_ROOT, 'wa-seed-home-'));
    fs.mkdirSync(path.join(tmpHome, '.wasm-agent', 'build', 'target'), {recursive: true});
    const g = makeTree(path.join(WORK, 'wt-shmroot'), 2);
    const tA = path.join(WORK, 'wt-shmA');
    spawnSync('git', ['worktree', 'add', '-q', '--detach', tA, 'HEAD'], {cwd: g, encoding: 'utf8'});
    const tB = path.join(WORK, 'wt-shmB');
    spawnSync('git', ['worktree', 'add', '-q', '--detach', tB, 'HEAD'], {cwd: g, encoding: 'utf8'});
    const envT = {WASM_AGENT_HOME: tmpHome};
    const rA = bash('. "' + RESOLVER + '"; wa_build_run "' + tA + '" cargo build --offline -q --manifest-path Cargo.toml', envT);
    check('the non-reflink first tree builds', rA.status === 0, say(rA).slice(-500));
    const rB = bash('. "' + RESOLVER + '"; wa_build_run "' + tB + '" cargo build --offline -q --manifest-path Cargo.toml', envT);
    check('without reflink the build says it starts cold instead of being seeded',
      say(rB).includes('reflink is not supported'), say(rB).slice(-400));
    const dirA = path.join(tmpHome, '.wasm-agent', 'build', 'target', treeName(tA));
    const dirB = path.join(tmpHome, '.wasm-agent', 'build', 'target', treeName(tB));
    const sizeA = Number(String(spawnSync('du', ['-sb', dirA], {encoding: 'utf8'}).stdout || '').split('\t')[0] || 0);
    const sizeB = Number(String(spawnSync('du', ['-sb', dirB], {encoding: 'utf8'}).stdout || '').split('\t')[0] || 0);
    check('it was never a full copy (no seed blocks were paid for)', sizeB < sizeA * 2, 'A=' + sizeA + ' B=' + sizeB);
    const bin = path.join(dirB, 'debug', 'app');
    check('the cold tree still produced its own binary', fs.existsSync(bin) && runOne(bin) === 'base=2', bin);
  }
}

console.log('build-seed ok (' + passed + ' checks)');
