#!/usr/bin/env node
// The node's ONE build root's own evidence: scripts/lib/build-target.sh (the resolver every build uses)
// and the rules `docs/ONEROOT.md` states.
//
// The day it answers for (wa-desktop, 13/11): the distro grew to 246 GB and filled the Windows C: drive
// until WSL crashed. Cleanup removed 73 separate Rust build folders, ~196 GB - one `rust/target` per
// worktree, `rust/target-<name>` dirs in the canonical checkout, one-root islands
// `build/<tree>-<hash>` and a deploy cache. None of them was ever deleted, because each script invented
// its own directory and nothing owned the question "how much build space is this node using".
//
// What is proved here, with real cargo on real (tiny) trees:
//
//   1. TWO TREES BUILD INTO ONE BUILD ROOT - `<home>/.wasm-agent/build/target` - each as its own child,
//      and neither tree grows a `target/` of its own. "One build folder" is the fact, not a convention;
//   2. THE TWO TREES DO NOT SEE EACH OTHER'S ARTIFACTS (`base=1` for tree A, `base=2` for tree B). This
//      is the reason the children are per tree: one FLAT shared `CARGO_TARGET_DIR` hands one tree the
//      other's library (cargo gives a member the same metadata hash in both checkouts), so a tree is
//      compiled against a library that was never built from it. If someone "simplifies" the resolver to
//      a single flat directory, this row goes red - as it must;
//   3. A SECOND TREE HASH REPLACES THE FIRST ISLAND: a tree that moved (or was removed) leaves an island
//      nothing can reuse, and the sweep before the next build deletes it, printing what it reclaimed;
//      the island of a live tree is reused, never duplicated;
//   4. THE SWEEP KEEPS ONLY THE ONE ROOT: an old-layout island, the deploy cache from before this
//      layout, and a `rust/target` / `rust/target-<name>` beside a live checkout all go - and the
//      sweep says how many bytes it reclaimed. Source is untouched, and a foreign `target` (a directory
//      that is not this repository's checkout) is not a candidate at all;
//   5. THE CAP EVICTS THE OLDEST: over `WASM_AGENT_BUILD_CAP_BYTES`, the oldest build output goes first,
//      the tree being built is kept, and the run says what it deleted;
//   6. TWO BUILDS OF ONE TREE SERIALIZE on the target's lock and the WAIT IS PRINTED, because a build
//      that sat behind another one has to be attributable to the queue and not to the compiler;
//   7. A TREE THAT GOES TAKES ITS BUILD OUTPUT (`wa_build_forget`), and a symlink is refused rather than
//      followed - the same guard `wa clean` applies.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {treeName, buildTargetRoot} from './codemode-build.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const RESOLVER = path.join(REPO, 'scripts', 'lib', 'build-target.sh');
const WORK_STARTED = Date.now();
const WORK = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-onebuild-'));
const HOME = path.join(WORK, 'home');
const ROOT = path.join(HOME, '.wasm-agent');
const BUILD_ROOT = path.join(ROOT, 'build');
const TARGET_ROOT = path.join(BUILD_ROOT, 'target');
fs.mkdirSync(TARGET_ROOT, {recursive: true});

let passed = 0;
function check(name, condition, detail = '') {
  if (!condition) {
    console.error(`FAIL ${name}${detail ? `: ${detail}` : ''}`);
    process.exitCode = 1;
    throw new Error(`check failed: ${name}`);
  }
  passed += 1;
  console.log(`ok - ${name}`);
}
function say(line) { console.log(`note - ${line}`); }

// The child environment: its own home, so the resolver writes into this test's build root and never into
// the live node's. CARGO_TARGET_DIR is cleared: the resolver is what decides, and a value inherited from
// the caller would (correctly) win and quietly make this test prove nothing.
const ENV = {...process.env, WASM_AGENT_HOME: HOME, CARGO_TARGET_DIR: ''};
delete ENV.CARGO_TARGET_DIR;
for (const name of ['WASM_AGENT_BUILD_CAP_GB', 'WASM_AGENT_BUILD_CAP_BYTES']) delete ENV[name];

const bash = (script, extraEnv = {}, cwd = REPO) => spawnSync('bash', ['-c', script], {
  encoding: 'utf8', cwd, env: {...ENV, ...extraEnv}, timeout: 600000,
});

// ---- the fixtures: two checkouts of one tiny workspace ---------------------------------------------
// Two members, because that is what the real workspace is and what makes the shared-dir failure real:
// `app` links `base`, and a tree whose `base` came from the other tree prints the other tree's value.
function makeTree(dir, value, extra = '') {
  fs.mkdirSync(path.join(dir, 'base', 'src'), {recursive: true});
  fs.mkdirSync(path.join(dir, 'app', 'src'), {recursive: true});
  fs.writeFileSync(path.join(dir, 'Cargo.toml'), '[workspace]\nmembers = ["base", "app"]\nresolver = "2"\n');
  fs.writeFileSync(path.join(dir, 'base', 'Cargo.toml'), '[package]\nname = "base"\nversion = "0.1.0"\nedition = "2021"\n');
  fs.writeFileSync(path.join(dir, 'base', 'src', 'lib.rs'), `pub fn v() -> i32 { ${value} }\n${extra}`);
  fs.writeFileSync(path.join(dir, 'app', 'Cargo.toml'),
    '[package]\nname = "app"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\nbase = { path = "../base" }\n');
  fs.writeFileSync(path.join(dir, 'app', 'src', 'main.rs'), 'fn main() { println!("base={}", base::v()); }\n');
  // A checkout of THIS repository's shape is what the sweep recognises; the crate above is the fixture.
  fs.mkdirSync(path.join(dir, 'rust', 'wa-host-support'), {recursive: true});
  fs.writeFileSync(path.join(dir, 'rust', 'wa-host-support', 'Cargo.toml'), '[package]\nname = "wa-host-support"\nversion = "0.1.0"\nedition = "2021"\n');
  return dir;
}
const TREE_A = makeTree(path.join(WORK, 'trees', 'wt-alpha'), 1);
const TREE_B = makeTree(path.join(WORK, 'trees', 'wt-beta'), 2, 'pub fn g() -> i32 { 7 }\n');
for (const tree of [TREE_A, TREE_B]) fs.mkdirSync(path.join(tree, '.git'), {recursive: true});
// The sweep only considers checkouts of this repository (`rust/wa-host-support` is the marker) - the
// fixture carries it so the "rust/target beside a checkout" row has something real to delete.

// Build one tree the way a script does: through the resolver, never by setting CARGO_TARGET_DIR by hand.
function build(tree, env = {}) {
  const r = bash(`. "${RESOLVER}"; wa_build_run "${tree}" cargo build --offline -q --manifest-path Cargo.toml`, env);
  return {status: r.status, out: String(r.stdout || ''), err: String(r.stderr || '')};
}
const run = (bin) => {
  const r = spawnSync(bin, [], {encoding: 'utf8'});
  return String(r.stdout || '').trim();
};
const children = (dir = TARGET_ROOT) => (fs.existsSync(dir) ? fs.readdirSync(dir).sort() : []);
const sizeOf = (dir) => Number(String(spawnSync('du', ['-sb', dir], {encoding: 'utf8'}).stdout || '').split('\t')[0] || 0);

// ---- 7a (first, because it is the guard): a symlink is refused, not followed -----------------------
{
  const victim = path.join(WORK, 'symlink-victim');
  fs.mkdirSync(victim, {recursive: true});
  fs.writeFileSync(path.join(victim, 'keep.txt'), 'operator data\n');
  const link = path.join(BUILD_ROOT, 'linked-island');
  fs.symlinkSync(victim, link);
  const r = bash(`. "${RESOLVER}"; wa_build_deletable "${link}" island; echo "verdict=$?"`);
  check('a symlink in the build root is refused, not followed',
    (String(r.stdout) + String(r.stderr)).includes('symlink_not_followed') && String(r.stdout).includes('verdict=1'),
    r.stdout + r.stderr);
  check('the symlink target is untouched', fs.existsSync(path.join(victim, 'keep.txt')));
  fs.unlinkSync(link);
}

// ---- 1. two trees, one build root ------------------------------------------------------------------
{
  const a = build(TREE_A);
  check('tree A builds through the resolver', a.status === 0, a.err.slice(-600));
  const b = build(TREE_B);
  check('tree B builds through the resolver', b.status === 0, b.err.slice(-600));

  const dirs = children();
  check('both trees wrote into the ONE build root', dirs.length === 2, JSON.stringify(dirs));
  for (const tree of [TREE_A, TREE_B]) {
    const expected = `${path.basename(tree)}-${treeName(tree).split('-').pop()}`;
    check(`tree ${path.basename(tree)} has its own child of the one root`, dirs.includes(expected), JSON.stringify({dirs, expected}));
    check(`tree ${path.basename(tree)} grew no target/ of its own`,
      !fs.existsSync(path.join(tree, 'target')) && !fs.existsSync(path.join(tree, 'rust', 'target')));
    check(`tree ${path.basename(tree)} built its binary inside the one root`,
      fs.existsSync(path.join(TARGET_ROOT, expected, 'debug', 'app')));
  }

  // ---- 2. and they do not see each other's artifacts -------------------------------------------
  const valueA = run(path.join(TARGET_ROOT, `${treeName(TREE_A)}`, 'debug', 'app'));
  const valueB = run(path.join(TARGET_ROOT, `${treeName(TREE_B)}`, 'debug', 'app'));
  check('tree A ran ITS OWN library (base=1)', valueA === 'base=1', valueA);
  check('tree B ran ITS OWN library (base=2)', valueB === 'base=2', valueB);

  // The failure this shape exists to prevent, shown once so the reason is a measurement and not a
  // claim: one flat directory, tree B built into it, tree A rebuilt - and A ran B's library. Not an
  // assertion (cargo may one day key artifacts by checkout path); printed, so the next reader sees the
  // number this rule was written from.
  // The failure this shape exists to prevent, shown once so the reason is a measurement and not a
  // claim. Two fresh trees, one flat directory: tree A builds, tree B's library source is edited and B
  // builds into the same directory, then A builds again. Not an assertion (cargo may one day key its
  // artifacts by checkout path); printed, so the next reader sees the number this rule was written from.
  const flat = path.join(WORK, 'flat-shared');
  const FLAT_A = makeTree(path.join(WORK, 'flat', 'a'), 1);
  const FLAT_B = makeTree(path.join(WORK, 'flat', 'b'), 1);
  const flatBuild = (tree) => bash(`cd "${tree}" && CARGO_TARGET_DIR="${flat}" cargo build --offline -q --manifest-path Cargo.toml`);
  flatBuild(FLAT_A);
  fs.writeFileSync(path.join(FLAT_B, 'base', 'src', 'lib.rs'), 'pub fn v() -> i32 { 2 }\npub fn g() -> i32 { 7 }\n');
  flatBuild(FLAT_B);
  const flatRebuild = flatBuild(FLAT_A);
  const flatValue = flatRebuild.status === 0 ? run(path.join(flat, 'debug', 'app')) : `build failed (${flatRebuild.stderr.trim().split('\n').pop()})`;
  const sharedBase = (fs.existsSync(path.join(flat, 'debug', 'deps')) ? fs.readdirSync(path.join(flat, 'debug', 'deps')) : [])
    .filter((name) => name.startsWith('libbase-') && name.endsWith('.rlib'));
  say(`one FLAT shared CARGO_TARGET_DIR for two trees: ${sharedBase.length} libbase rlib for both of them (${sharedBase.join(', ')})`);
  say(`tree A rebuilt in that shared dir and printed "${flatValue}"` +
    `${flatValue === 'base=2' ? ' - it ran tree B\'s library, which is why the islands are per tree' : ' (this cargo keyed them apart; the collision above is what the rule stands on)'}`);
}

// ---- 3. a second tree hash replaces the first island ------------------------------------------------
let TREE_A_MOVED = TREE_A;
{
  const before = children();
  const islandA = path.join(TARGET_ROOT, treeName(TREE_A));
  check('tree A\'s island exists before the move', fs.existsSync(islandA), islandA);
  // The tree moves: a new path, a new name, and the old island now belongs to nobody.
  const moved = path.join(WORK, 'trees', 'wt-alpha-moved');
  fs.renameSync(TREE_A, moved);
  fs.rmSync(path.join(moved, '.git'), {recursive: true, force: true});
  fs.mkdirSync(path.join(moved, '.git'), {recursive: true});
  const r = build(moved, {});
  check('the moved tree builds', r.status === 0, r.err.slice(-600));
  check('the island the old path owned is deleted', !fs.existsSync(islandA));
  const after = children();
  check('the moved tree reuses an island when the path matches, and only one of it',
    after.includes(treeName(moved)) && after.filter((name) => name.startsWith('wt-alpha-')).length === 1,
    JSON.stringify({before, after}));
  const again = build(moved, {});
  check('a second build of the same tree creates no new island', again.status === 0 && children().length === after.length,
    JSON.stringify({after, now: children()}));
  TREE_A_MOVED = moved;
}

// ---- 4. the sweep keeps only the one root, and never touches source --------------------------------
{
  // An island an older layout wrote (child of <root>/build), the deploy cache from before this layout,
  // and `rust/target` + `rust/target-ops` beside a live checkout.
  const oldIsland = path.join(BUILD_ROOT, 'graphdb-baseline');
  const deployCache = path.join(ROOT, 'build-cache', 'target');
  for (const dir of [oldIsland, deployCache, path.join(TREE_B, 'rust', 'target'), path.join(TREE_B, 'rust', 'target-ops')]) {
    fs.mkdirSync(dir, {recursive: true});
    fs.writeFileSync(path.join(dir, 'blob'), Buffer.alloc(64 * 1024, 7));
    // Stale by an hour: a legacy dir written to moments ago belongs to a build that may still be running,
    // and the sweep leaves it (the next row proves that half).
    spawnSync('touch', ['-d', '-1 hour', dir]);
    spawnSync('touch', ['-d', '-1 hour', path.dirname(dir)]);
  }
  // ... and one that IS fresh, which the sweep must leave alone: another session's build in flight.
  const fresh = path.join(TREE_B, 'rust', 'target-fresh');
  fs.mkdirSync(fresh, {recursive: true});
  fs.writeFileSync(path.join(fresh, 'blob'), 'live\n');
  const source = path.join(TREE_B, 'base', 'src', 'lib.rs');
  const sourceText = fs.readFileSync(source, 'utf8');
  const sourceMtime = fs.statSync(source).mtimeMs;
  const foreign = path.join(HOME, 'foreign-project');
  fs.mkdirSync(path.join(foreign, 'target'), {recursive: true});
  fs.mkdirSync(path.join(foreign, 'src'), {recursive: true});
  fs.writeFileSync(path.join(foreign, 'src', 'main.rs'), 'fn main() {}\n');
  fs.writeFileSync(path.join(foreign, '.git'), 'gitdir: nowhere\n');
  fs.writeFileSync(path.join(foreign, 'target', 'keep'), 'not ours\n');

  const r = bash(`. "${RESOLVER}"; wa_build_sweep`);
  check('the sweep ran', r.status === 0, r.err);
  for (const [label, dir] of [['an old-layout island', oldIsland], ['the pre-one-root deploy cache', path.join(ROOT, 'build-cache')],
    ['rust/target beside a checkout', path.join(TREE_B, 'rust', 'target')], ['rust/target-ops beside a checkout', path.join(TREE_B, 'rust', 'target-ops')]]) {
    check(`${label} is gone`, !fs.existsSync(dir), dir);
  }
  check('the sweep printed the bytes it reclaimed',
    /onebuild: reclaimed [0-9.]+[kMG]? from 4 build dir\(s\)/.test(String(r.stderr)), String(r.stderr));
  check('a legacy dir a build wrote to moments ago is left alone, and said so',
    fs.existsSync(fresh) && /onebuild: leaving .*target-fresh alone: written to [0-9]+s ago/.test(String(r.stderr)),
    String(r.stderr));
  check('source is untouched', fs.readFileSync(source, 'utf8') === sourceText && fs.statSync(source).mtimeMs === sourceMtime);
  check('a foreign project\'s target/ is not a candidate', fs.existsSync(path.join(foreign, 'target', 'keep')));
  check('the live tree kept its own island', fs.existsSync(path.join(TARGET_ROOT, treeName(TREE_B))));
}

// ---- 5. the cap evicts the oldest ------------------------------------------------------------------
{
  // Two build outputs with distinct ages, and a cap small enough that one of them has to go. The tree
  // about to build is the newest, so it is the one that survives.
  const keep = path.join(TARGET_ROOT, treeName(TREE_B));
  const oldest = path.join(TARGET_ROOT, 'deploy-0000000000aa');
  const middle = path.join(TARGET_ROOT, 'deploy-0000000000bb');
  for (const dir of [oldest, middle]) {
    fs.mkdirSync(dir, {recursive: true});
    fs.writeFileSync(path.join(dir, 'blob'), Buffer.alloc(512 * 1024, 3));
  }
  spawnSync('touch', ['-d', '2020-01-01T00:00:00Z', oldest]);
  spawnSync('touch', ['-d', '2021-01-01T00:00:00Z', middle]);
  // One byte under the total, so exactly one build output has to go - and it must be the oldest.
  const total = sizeOf(TARGET_ROOT);
  const cap = Math.max(sizeOf(keep), total - 1);
  const r = bash(`. "${RESOLVER}"; wa_build_cap_enforce "${keep}"`, {WASM_AGENT_BUILD_CAP_BYTES: String(cap)});
  check('the cap run says what it deleted', /over the [0-9.]+[kMG]? build cap: deleted deploy-0000000000aa/.test(String(r.stderr)), String(r.stderr));
  check('the oldest build output went first', !fs.existsSync(oldest) && fs.existsSync(middle));
  check('the cap reports the bytes it freed', /[0-9]+ build output\(s\) went/.test(String(r.stderr)) && Number(String(r.stdout).trim()) > 0,
    `stdout=${r.stdout} stderr=${r.stderr}`);
  fs.rmSync(middle, {recursive: true, force: true});
}

// ---- 6. two builds of one tree serialize, and the wait is printed ----------------------------------
{
  const tree = TREE_B;
  const hold = `. "${RESOLVER}"; wa_build_run "${tree}" bash -c 'sleep 3'`;
  const started = Date.now();
  const first = spawn('bash', ['-c', hold], {cwd: REPO, env: ENV, stdio: 'pipe'});
  const firstDone = new Promise((resolve) => first.on('exit', resolve));
  // Give the first build the lock before the second asks for it.
  await new Promise((resolve) => setTimeout(resolve, 500));
  const second = spawnSync('bash', ['-c', `. "${RESOLVER}"; wa_build_run "${tree}" bash -c 'true'`],
    {cwd: REPO, env: ENV, encoding: 'utf8', timeout: 120000});
  await firstDone;
  const elapsed = Date.now() - started;
  check('the second build of the same tree succeeded', second.status === 0, second.stderr);
  check('the second build waited for the first', elapsed >= 2800, `${elapsed}ms`);
  check('the wait is printed with its length',
    /onebuild: waited [0-9.]+s for the build lock on .* \(another build of this tree was running\)/.test(String(second.stderr)),
    String(second.stderr));
}

// ---- 7. a tree that goes takes its build output with it --------------------------------------------
{
  const tree = TREE_A_MOVED;
  const island = path.join(TARGET_ROOT, treeName(tree));
  check('the tree has build output to lose', fs.existsSync(island));
  const r = bash(`. "${RESOLVER}"; wa_build_forget "${tree}"`);
  check('forget deletes the tree\'s build output', !fs.existsSync(island) && Number(String(r.stdout).trim()) > 0,
    `stdout=${r.stdout} stderr=${r.stderr}`);
  check('forget says what it freed', /went with its tree, freeing [0-9.]+[kMG]?/.test(String(r.stderr)), String(r.stderr));
}

// ---- the name the three implementations compute is one name ----------------------------------------
{
  const shellName = String(bash(`. "${RESOLVER}"; wa_build_tree_name "${TREE_B}"`).stdout || '').trim();
  check('the shell and the node resolver name a tree\'s island the same',
    shellName === treeName(TREE_B), `${shellName} != ${treeName(TREE_B)}`);
  check('both resolve the one build root the node owns', buildTargetRoot(ENV) === TARGET_ROOT,
    `${buildTargetRoot(ENV)} != ${TARGET_ROOT}`);
}

console.log(`onebuild: ${passed} checks passed in ${((Date.now() - WORK_STARTED) / 1000).toFixed(1)}s`);
fs.rmSync(WORK, {recursive: true, force: true});
