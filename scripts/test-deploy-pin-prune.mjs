#!/usr/bin/env node
// The deploy's pin directory is pruned to what this node still needs (`prune-pins`, and the prune inside
// `pin`, both in scripts/landing-queue.mjs; called by scripts/deploy.sh at step 3c and again at step 8b).
//
// WHY. A pinned worktree is a whole checkout of the repository - measured on avell 2026-11-22 with
// `du -sh /tmp/wa-deploy-pins/*`: 128 MB each - and nothing ever removed one. Nineteen of them (2.5 GB)
// had accumulated, /tmp is a 16 G tmpfs with a per-user quota, the quota was hit and the NEXT install
// refused with `deploy_pin_failed: cannot create a pinned worktree ...: No space left on device`
// (deploy.log 2026-11-22T16:29Z, commit 5ea23581). The deploy that was blocked could not clean up: the pin
// it needed was waiting for the room the old pins were holding.
//
// WHAT IS MEASURED HERE - on a real repository, a real bare origin and the real CLI, never a mock:
//   1. four deploys in a row leave EXACTLY TWO pins: the commit the node runs and the one before it;
//   2. a deploy never accumulates more than the kept set plus the pin it is creating - the prune runs
//      BEFORE the new tree, which is the half a full /tmp can no longer block;
//   3. an install record that cannot name a commit (`build_pin=unpinned`, the Lua fast path measured on
//      avell 22/11) is not read as naming one, and the kept set fills from the newest pins instead;
//   4. a pin a live process is inside is never removed, even when the keep set is full, and is named
//      with its pid;
//   5. a machine whose processes cannot be asked at all (no /proc) has nothing removed - an unknown is
//      not a yes;
//   6. a removal that FAILS is named and left in place, and the command still exits 0;
//   7. only a directory whose whole name is a commit is ever a candidate: a note, a file or a symlink in
//      the pin directory is never touched;
//   8. scripts/deploy.sh asks the same rule after its install (structurally: the call site sits after the
//      final `record_installed`, it hands over the install records, and a failure there is a `note`).
//
// A SCRATCH HOME, ALWAYS: the CLI runs with HOME and WASM_AGENT_HOME under this test's own temporary
// directory, and the test refuses to run when they resolve to the real ones.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CLI = path.join(REPO, 'scripts', 'landing-queue.mjs');
const DEPLOY = path.join(REPO, 'scripts', 'deploy.sh');

const WORK = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-deploy-pin-prune-'));
const HOME = path.join(WORK, 'home');
const AGENT_HOME = path.join(HOME, '.wasm-agent');
fs.mkdirSync(AGENT_HOME, {recursive: true});
const realHome = process.env.HOME ? path.resolve(process.env.HOME) : '';
const realAgentHome = process.env.WASM_AGENT_HOME
  ? path.resolve(process.env.WASM_AGENT_HOME) : path.join(realHome, '.wasm-agent');
if (path.resolve(HOME) === realHome || path.resolve(AGENT_HOME) === realAgentHome) {
  console.error(`FAIL this test would write into the real home (${HOME} / ${AGENT_HOME}); refusing to run`);
  process.exit(1);
}

const ORIGIN = path.join(WORK, 'origin.git');
const CANONICAL = path.join(WORK, 'canonical');
const PINS = path.join(WORK, 'pins');
const INSTALL = path.join(WORK, 'install');
fs.mkdirSync(INSTALL, {recursive: true});
const ENV = {
  ...process.env,
  HOME,
  WASM_AGENT_HOME: AGENT_HOME,
  XDG_CONFIG_HOME: path.join(HOME, '.config'),
  XDG_DATA_HOME: path.join(HOME, '.local', 'share'),
  XDG_STATE_HOME: path.join(HOME, '.local', 'state'),
  WA_LANDING_QUEUE_LEDGER: path.join(WORK, 'ledger.db'),
};
for (const name of ['WASM_AGENT_SESSION_ID', 'WA_SESSION_ID', 'WA_LANDING_QUEUE_DIR', 'WA_DEPLOY_PIN_DIR', 'WA_DEPLOY_ROOT']) delete ENV[name];

let passed = 0;
let skipped = 0;
function check(name, condition, detail = '') {
  if (!condition) {
    console.error(`FAIL ${name}${detail ? `: ${detail}` : ''}`);
    throw new Error(`check failed: ${name}`);
  }
  passed += 1;
  console.log(`ok - ${name}`);
}
function skip(name, why) {
  skipped += 1;
  console.log(`SKIP ${name}: ${why}`);
}

const git = (cwd, ...args) => {
  const result = spawnSync('git', ['-C', cwd, ...args], {encoding: 'utf8'});
  if (result.status !== 0) throw new Error(`git ${args.join(' ')} in ${cwd}: ${result.stderr || result.stdout}`);
  return String(result.stdout || '');
};
const q = (args, options = {}) => spawnSync(process.execPath, [CLI, ...args, '--repo', CANONICAL], {
  encoding: 'utf8', env: {...ENV, ...(options.env || {})}, timeout: 120000,
});
const short = sha => String(sha).slice(0, 12);

// ---- the fixture: a real repository, its bare origin, and one commit per "deploy" -----------------
function commit(message) {
  fs.writeFileSync(path.join(CANONICAL, 'NOTES.md'), `${message}\n`);
  git(CANONICAL, 'add', '-A');
  git(CANONICAL, '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-q', '-m', message);
  git(CANONICAL, 'push', '-q', 'origin', 'main');
  return git(CANONICAL, 'rev-parse', 'HEAD').trim();
}
fs.mkdirSync(ORIGIN, {recursive: true});
git(ORIGIN, 'init', '-q', '--bare', '--initial-branch=main');
git(WORK, 'clone', '-q', ORIGIN, CANONICAL);
const COMMITS = ["the first deploy's tree", "the second deploy's tree", 'a Lua-only deploy', "the fourth deploy's tree"]
  .map(commit);

// What an install record looks like - the keys scripts/lib/install-record.sh writes.
function writeRecord({commit: at, binary, pin}) {
  fs.writeFileSync(path.join(INSTALL, 'installed.txt'),
    `commit=${at}\nbranch=main\nbuild_pin=${pin}\nbinary_commit=${binary}\n`);
}
function keepPreviousRecord() {
  fs.mkdirSync(path.join(INSTALL, 'rollback'), {recursive: true});
  fs.copyFileSync(path.join(INSTALL, 'installed.txt'), path.join(INSTALL, 'rollback', 'installed.txt'));
}

const pins = dir => (fs.existsSync(dir) ? fs.readdirSync(dir, {withFileTypes: true})
  .filter(entry => entry.isDirectory() && /^[0-9a-f]{40}$/.test(entry.name)).map(entry => entry.name).sort() : []);

// One pin step, exactly as scripts/deploy.sh makes it, and one post-install step, exactly as 8b does.
function pinStep(at, pinDir = PINS) {
  const result = q(['pin', '--commit', at, '--pin-dir', pinDir, '--install-dir', INSTALL, '--json']);
  if (result.status !== 0) throw new Error(`pin ${short(at)} in ${pinDir} failed: ${result.stdout}${result.stderr}`);
  const answer = JSON.parse(result.stdout);
  if (answer.pin !== path.join(pinDir, at)) throw new Error(`pin named ${answer.pin}, not ${path.join(pinDir, at)}`);
  return answer;
}
function postInstallPrune(extra = []) {
  const result = q(['prune-pins', '--pin-dir', PINS, '--install-dir', INSTALL, ...extra]);
  return {code: result.status, out: `${result.stdout}${result.stderr}`};
}

// ---- 1, 2, 3. four deploys in a row leave exactly the two trees a retry or a rollback needs --------
function fourDeploys() {
  for (const [index, sha] of COMMITS.entries()) {
    const before = pins(PINS).length;
    pinStep(sha); // step 3c: the prune inside it runs BEFORE the new tree is created
    const created = pins(PINS);
    check(`deploy ${index + 1}: the pin exists at ${short(sha)}`, created.includes(sha), created.join(' '));
    check(`deploy ${index + 1}: the pin directory holds at most the kept set plus the new tree`,
      created.length === Math.min(before + 1, 3), `${before} before, ${created.length} after: ${created.map(short).join(' ')}`);
    // Step 8 records the install; step 8b prunes. Deploy 3 is the Lua fast path: the binary is unchanged
    // and the record says `build_pin=unpinned`, which is not a commit and must not be read as one.
    if (index === 2) writeRecord({commit: sha, binary: COMMITS[1], pin: 'unpinned'});
    else writeRecord({commit: sha, binary: sha, pin: sha});
    if (index > 0) keepPreviousRecord();
    const pruned = postInstallPrune();
    check(`deploy ${index + 1}: the post-install prune exits 0`, pruned.code === 0, pruned.out);
    check(`deploy ${index + 1}: it never leaves more than two pins behind`, pins(PINS).length <= 2, pins(PINS).join(' '));
  }
  const left = pins(PINS);
  check('after four deploys exactly two pins remain', left.length === 2, `${left.length}: ${left.join(' ')}`);
  check('they are the commit this node runs and the one before it',
    left.includes(COMMITS[3]) && left.includes(COMMITS[2]),
    `left ${left.map(short).join(' ')}; expected ${short(COMMITS[2])} and ${short(COMMITS[3])}`);
  check('the pin two deploys old is gone', !left.includes(COMMITS[1]));
  check("the first deploy's pin is gone", !left.includes(COMMITS[0]));
  check('the record that names no commit (build_pin=unpinned) put nothing in the keep set', !left.includes('unpinned'));
  for (const name of left) {
    check(`the kept pin ${short(name)} is still a real worktree at that commit`,
      git(path.join(PINS, name), 'rev-parse', 'HEAD').trim() === name);
  }
  const registered = git(CANONICAL, 'worktree', 'list', '--porcelain');
  check('the removed pins are no longer registered as worktrees',
    !registered.includes(path.join(PINS, COMMITS[0])) && !registered.includes(path.join(PINS, COMMITS[1])), registered);
}

// ---- 4. a pin a live process is inside is never removed, even with the keep set full --------------
async function pinInUse() {
  const dir = path.join(WORK, 'pins-in-use');
  for (const sha of [COMMITS[0], COMMITS[1], COMMITS[2]]) pinStep(sha, dir);
  const before = pins(dir);
  check('the in-use fixture holds three pins', before.length === 3, before.map(short).join(' '));
  const busy = path.join(dir, COMMITS[0]); // the oldest: the one the keep set would drop
  // A live process whose working directory is inside it - what a running build looks like.
  const child = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 60000)'], {cwd: busy, stdio: 'ignore'});
  await new Promise(resolve => setTimeout(resolve, 300));
  try {
    const result = q(['prune-pins', '--pin-dir', dir, '--json']);
    check('the command with a pin in use exits 0', result.status === 0, result.stdout + result.stderr);
    const answer = JSON.parse(result.stdout);
    check('a pin a live process is inside is not removed', fs.existsSync(busy), JSON.stringify(answer.removed));
    const kept = answer.kept.find(entry => entry.name === COMMITS[0]);
    check('it is kept, and the reason names the pid', Boolean(kept) && kept.why.includes(String(child.pid)),
      JSON.stringify(answer.kept));
    check('it is not in the removed list', !answer.removed.some(entry => entry.name === COMMITS[0]),
      JSON.stringify(answer.removed));
  } finally {
    child.kill('SIGTERM'); // only the pid this test started
    await new Promise(resolve => child.on('exit', resolve));
  }
  // Without the live process the same command removes it - the rule is the process, not the directory.
  const after = q(['prune-pins', '--pin-dir', dir, '--json']);
  check('with nothing inside it the same pin is removed',
    JSON.parse(after.stdout).removed.some(entry => entry.name === COMMITS[0]), after.stdout);
}

// ---- 5. a machine that cannot be asked which processes are alive removes nothing ------------------
function livenessUnknown() {
  const before = pins(PINS);
  const noProc = path.join(WORK, 'no-such-proc');
  const result = q(['prune-pins', '--pin-dir', PINS, '--install-dir', INSTALL, '--proc-root', noProc, '--json']);
  check('a prune whose liveness is unknown still exits 0', result.status === 0, result.stdout + result.stderr);
  const answer = JSON.parse(result.stdout);
  check('it reports the liveness as unknown', answer.liveness === 'unknown', JSON.stringify(answer.liveness));
  check('it removed nothing', answer.removed.length === 0, JSON.stringify(answer.removed));
  check('every pin is still there', pins(PINS).length === before.length, `${before.length} -> ${pins(PINS).length}`);
  const human = q(['prune-pins', '--pin-dir', PINS, '--install-dir', INSTALL, '--proc-root', noProc]);
  check('the human summary says nothing was removed, and why',
    /nothing was removed: .*cannot be read/.test(human.stdout), human.stdout + human.stderr);
}

// ---- 6. a removal that fails is named, left in place, and never fatal -----------------------------
function removalFails() {
  if (process.getuid && process.getuid() === 0) {
    skip('a removal that fails is named and the command still exits 0',
      'running as root: directory permissions cannot refuse a removal');
    return;
  }
  const dir = path.join(WORK, 'pins-stuck');
  for (const sha of [COMMITS[0], COMMITS[1], COMMITS[2]]) pinStep(sha, dir);
  const before = pins(dir);
  check('the stuck fixture holds three pins', before.length === 3, before.map(short).join(' '));
  fs.chmodSync(dir, 0o555); // the trees cannot be unlinked out of a directory nobody may write
  try {
    const result = q(['prune-pins', '--pin-dir', dir, '--json']);
    check('a failed removal still exits 0', result.status === 0, result.stdout + result.stderr);
    const answer = JSON.parse(result.stdout);
    check('the failure is named in the answer, with the pin it is about',
      answer.failed.length === 1 && answer.failed[0].name === COMMITS[0],
      JSON.stringify({failed: answer.failed, removed: answer.removed, kept: answer.kept}));
    check('the tree is left in place', fs.existsSync(path.join(dir, COMMITS[0])));
    const human = q(['prune-pins', '--pin-dir', dir]);
    check('the human output names the pin it could not remove and says the deploy goes on',
      /could not remove .*left in place, and the deploy goes on/.test(human.stdout), human.stdout + human.stderr);
  } finally {
    fs.chmodSync(dir, 0o755);
  }
}

// ---- 7. only a name that is a whole commit is a candidate -----------------------------------------
function nameAllowList() {
  const dir = path.join(WORK, 'pins-names');
  fs.mkdirSync(dir, {recursive: true});
  const keep = ['a-note.txt', 'b'.repeat(40), 'not-a-commit', 'c'.repeat(40)];
  fs.writeFileSync(path.join(dir, 'a-note.txt'), 'do not remove me\n');
  fs.writeFileSync(path.join(dir, 'b'.repeat(40)), 'a FILE named like a commit\n');
  fs.writeFileSync(path.join(dir, 'not-a-commit'), 'neither is this\n');
  fs.symlinkSync(path.join(dir, 'a-note.txt'), path.join(dir, 'c'.repeat(40)));
  const result = q(['prune-pins', '--pin-dir', dir, '--json']);
  check('a pin directory of things that are not trees is a no-op', result.status === 0, result.stdout + result.stderr);
  const answer = JSON.parse(result.stdout);
  for (const name of keep) {
    check(`${name.slice(0, 20)} was not removed`, fs.lstatSync(path.join(dir, name), {throwIfNoEntry: false}) !== undefined);
  }
  check('none of them counted as a pin', answer.kept.length === 0 && answer.removed.length === 0 && answer.failed.length === 0,
    result.stdout);
  // The cap is a number a caller states: a bad one is refused by name, not read as 'no cap'.
  const bad = q(['prune-pins', '--pin-dir', dir, '--keep-max', '0']);
  check('a keep-max of zero is refused by name', bad.status === 75 && /--keep-max must be a positive integer, not '0'/.test(bad.stderr),
    bad.stdout + bad.stderr);
}

// ---- 8. deploy.sh asks the same rule, after its install, and never fatally ------------------------
function deployWiring() {
  const text = fs.readFileSync(DEPLOY, 'utf8');
  const record = text.indexOf('\nrecord_installed\necho "deploy: installed');
  check('deploy.sh records the final install (record_installed)', record > 0);
  const call = text.indexOf('landing-queue.mjs prune-pins --pin-dir "$PIN_DIR" --install-dir "$INSTALL_DIR"');
  check('deploy.sh prunes the pins after that record', call > record && call > 0, `record at ${record}, call at ${call}`);
  check('the pin step hands the same records to the pin, so the prune before it knows them',
    text.includes('--install-dir "$INSTALL_DIR" --wait-timeout "$PIN_WAIT" --json'));
  const block = text.slice(Math.max(0, call - 2500), call + 2000);
  check('a failed prune is a note, never a fail', /else\n\s*note "pin prune:/.test(block));
  check('a machine without node says so by name instead of keeping every tree',
    /node is not on PATH, so this deploy cannot tell which pins/.test(block));
}

// ---- 9. the step every path reaches, run for real under set -u -------------------------------------
// The defect this section exists for (measured 23/11 on avell, deploys of 44479b7f / 3665b1b7 / e9a42d20):
// scripts/deploy.sh keeps its block bodies at column 0, so `PIN_DIR` sat inside the `else` of
// `if [ "$LUA_FAST" = 1 ]` - a branch a Lua fast-path deploy never enters - while step 8b, which every path
// reaches, read it. Every fast-path deploy therefore ended
//   deploy.sh: line 2422: PIN_DIR: unbound variable
// after "deploy: recorded in .../installed.txt", its wa-deploy-* unit was marked failed, and no pin was
// pruned. Two things are asserted, and both fail on that code:
//   a. the declaration is on every path: its line comes BEFORE the Lua fast-path branch (structural, on the
//      real file - a placement is what the bug was);
//   b. the step itself runs under `set -u` with no pin directory named (a named note, exit 0), with a pin
//      directory whose command cannot run (a named note, exit 0), and with a real one (the prune actually
//      happens) - the real block, extracted from scripts/deploy.sh between its own markers.
function fastPathBlock() {
  const text = fs.readFileSync(DEPLOY, 'utf8');
  // Extracted by its own markers. The code before this change carries none, so the same extraction falls
  // back to its unmarked step there: the runs below must reproduce what the real deploy did, not skip the
  // row because a comment is missing.
  const begin = text.indexOf('# wa-deploy-pin-prune: begin');
  const end = text.indexOf('# wa-deploy-pin-prune: end');
  const marked = begin > 0 && end > begin;
  let block = '';
  if (marked) block = text.slice(text.indexOf('\n', begin) + 1, end);
  else {
    const open = text.indexOf('if [ -d "$PIN_DIR" ];');
    const stop = text.indexOf('echo "deploy: /health -> ', open);
    if (open > 0 && stop > open) block = text.slice(open, stop);
  }
  check('the prune step can be extracted from deploy.sh on its own', /prune-pins --pin-dir/.test(block),
    block.slice(0, 200));

  const harness = path.join(WORK, 'step8b.sh');
  const write = (pinDir, sourceRoot) => {
    fs.writeFileSync(harness, [
      '#!/usr/bin/env bash',
      'set -uo pipefail',   // the deploy's own strictness: an unset variable is fatal
      'note() { printf \'NOTE [%s]\\n\' "$*"; }',
      `INSTALL_DIR=${JSON.stringify(INSTALL)}`,
      `SOURCE_ROOT=${JSON.stringify(sourceRoot)}`,
      pinDir === null ? 'unset PIN_DIR 2>/dev/null || true' : `PIN_DIR=${JSON.stringify(pinDir)}`,
      block,
      'printf \'STEP-8B-REACHED-THE-END\\n\'',
    ].join('\n') + '\n');
  };
  const run = () => spawnSync('bash', [harness], {encoding: 'utf8', env: {...ENV}});

  // a. no pin directory named on this path: the step says so and the deploy goes on. Under `set -u` the
  //    code before this change dies here instead, which is exactly what the real deploy was doing.
  write(null, CANONICAL);
  const unnamed = run();
  check('step 8b survives a path that names no pin directory', unnamed.status === 0,
    `exit ${unnamed.status}: ${unnamed.stderr}`);
  check('it does not die on an unset variable', !/unbound variable/.test(`${unnamed.stdout}${unnamed.stderr}`),
    unnamed.stderr);
  check('it names the hole instead of passing silently',
    /NOTE \[pin prune: this path names no pin directory/.test(unnamed.stdout), unnamed.stdout);
  check('it reaches its end', /STEP-8B-REACHED-THE-END/.test(unnamed.stdout), unnamed.stdout);

  // b. a pin directory whose command cannot run: a named note, never a failure of the install.
  const broken = path.join(WORK, 'no-scripts-here');
  fs.mkdirSync(broken, {recursive: true});
  write(PINS, broken);
  const fails = run();
  check('a prune that cannot run does not fail the step', fails.status === 0, `exit ${fails.status}: ${fails.stderr}`);
  check('the failure is named, and says the install stands',
    /NOTE \[pin prune: .*the install stands; the trees under .* are left as they are\]/.test(fails.stdout), fails.stdout);

  // c. a real pin directory, through the real command: the prune happens.
  const blockPins = path.join(WORK, 'pins-block');
  for (const sha of [COMMITS[0], COMMITS[1], COMMITS[2]]) pinStep(sha, blockPins);
  const before = pins(blockPins);
  check('the block fixture holds three pins', before.length === 3, before.map(short).join(' '));
  // The block runs the command out of $SOURCE_ROOT, so the fixture repository is given one (the real
  // scripts, unchanged) - nothing else about the run is different from a deploy's.
  const scripts = path.join(CANONICAL, 'scripts');
  const hadScripts = fs.existsSync(scripts);
  if (!hadScripts) fs.symlinkSync(path.join(REPO, 'scripts'), scripts);
  try {
    write(blockPins, CANONICAL);
    const pruned = run();
  check('step 8b carries the markers this test extracts it by', marked,
    'deploy.sh has no # wa-deploy-pin-prune: begin/end pair');
    check('the real block prunes through the real command', pruned.status === 0 &&
      /pin prune: removed|pin prune: \d+ removed/.test(pruned.stdout), `exit ${pruned.status}: ${pruned.stdout}${pruned.stderr}`);
    check('it leaves the kept set behind, and nothing more', pins(blockPins).length === 2,
      pins(blockPins).map(short).join(' '));
  } finally {
    if (!hadScripts) fs.rmSync(scripts, {recursive: true, force: true});
  }

  // The placement last, because it is the structure behind the runs above: this file writes its block bodies
  // at column 0, so the line's LINE say nothing - what decides is which branch it sits in.
  const declared = text.indexOf('PIN_DIR="${WA_DEPLOY_PIN_DIR:-');
  const branch = text.indexOf('if [ "$LUA_FAST" = 1 ]; then');
  check('deploy.sh still has the Lua fast-path branch this rule is about', branch > 0);
  check('the pin directory is declared on EVERY path, not inside the build branch',
    declared > 0 && declared < branch, `PIN_DIR at ${declared}, the Lua fast-path branch at ${branch}`);
}

// ---- main ----------------------------------------------------------------------------------------
(async () => {
  const started = Date.now();
  // The behaviour first, the deploy's wiring last: on the code before this change the behaviour is
  // what fails, so the failure names the missing rule and not a missing line of shell.
  fourDeploys();
  await pinInUse();
  livenessUnknown();
  removalFails();
  nameAllowList();
  fastPathBlock();
  deployWiring();
  const seconds = Math.round((Date.now() - started) / 1000);
  console.log(`deploy-pin-prune: ${passed} check(s) ok, ${skipped} skipped in ${seconds}s (scratch ${WORK})`);
  if (skipped === 0) fs.rmSync(WORK, {recursive: true, force: true});
})().catch(error => {
  console.error(`FAIL ${error.message}`);
  console.error(`     left behind for inspection: ${WORK}`);
  process.exitCode = 1;
});
