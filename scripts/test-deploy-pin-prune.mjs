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

// ---- main ----------------------------------------------------------------------------------------
(async () => {
  const started = Date.now();
  deployWiring();
  fourDeploys();
  await pinInUse();
  livenessUnknown();
  removalFails();
  nameAllowList();
  const seconds = Math.round((Date.now() - started) / 1000);
  console.log(`deploy-pin-prune: ${passed} check(s) ok, ${skipped} skipped in ${seconds}s (scratch ${WORK})`);
  if (skipped === 0) fs.rmSync(WORK, {recursive: true, force: true});
})().catch(error => {
  console.error(`FAIL ${error.message}`);
  console.error(`     left behind for inspection: ${WORK}`);
  process.exitCode = 1;
});
