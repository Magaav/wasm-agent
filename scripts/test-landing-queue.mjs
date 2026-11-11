#!/usr/bin/env node
// The landing queue's own evidence (scripts/landing-queue.mjs). Five behaviours, each measured on a
// real repository with a real bare remote and real processes - no mocks of the thing under test:
//
//   1. two concurrent landers serialize on one canonical checkout, and the waiting one is told its
//      position and the holder;
//   2. a holder that is killed is reclaimed with a logged reason (never silently, never by a timeout);
//   3. an upstream move is classified: a docs-only move skips the branch's retest, a Lua/Rust move
//      forces it, and the proof that decides is keyed by the tree's test inputs;
//   4. a dirty canonical checkout with no lease is refused, naming the files;
//   5. the owner is a harness session id, proven against the node's ledger, never a directory name.
//
// Plus the two drift guards: the compiled-inputs classifier agrees with scripts/lib/node-binaries.sh
// (the authority), and CHECK_INPUTS covers every document the fast path's checks actually read.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawn, spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {fileURLToPath} from 'node:url';
import {compiledInput, treeDigest, CHECK_INPUTS, testRelevant} from './lib/landing-queue.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CLI = path.join(REPO, 'scripts', 'landing-queue.mjs');
const SESSION = '11111111-2222-3333-4444-555555555555';
const OTHER = '22222222-3333-4444-5555-666666666666';
const WORK = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-landing-queue-'));
const ORIGIN = path.join(WORK, 'origin.git');
const CANONICAL = path.join(WORK, 'canonical');
const SIDE = path.join(WORK, 'side');
const LEDGER = path.join(WORK, 'ledger.db');
const ENV = {...process.env, WA_LANDING_QUEUE_LEDGER: LEDGER};
delete ENV.WASM_AGENT_SESSION_ID;
delete ENV.WA_SESSION_ID;
delete ENV.WA_LANDING_QUEUE_DIR;

let passed = 0;
const started = Date.now();
function check(name, condition, detail = '') {
  if (!condition) {
    console.error(`FAIL ${name}${detail ? `: ${detail}` : ''}`);
    process.exitCode = 1;
    throw new Error(`check failed: ${name}`);
  }
  passed += 1;
  console.log(`ok - ${name}`);
}
const git = (cwd, ...args) => {
  const result = spawnSync('git', ['-C', cwd, ...args], {encoding: 'utf8'});
  if (result.status !== 0) throw new Error(`git ${args.join(' ')} in ${cwd}: ${result.stderr || result.stdout}`);
  return String(result.stdout || '');
};
const q = (args, options = {}) => spawnSync(process.execPath, [CLI, ...args, '--repo', CANONICAL], {
  encoding: 'utf8', env: {...ENV, ...(options.env || {})}, timeout: 120000,
});
const qJson = args => {
  const result = q([...args, '--json']);
  if (result.status !== 0) throw new Error(`landing-queue ${args.join(' ')} failed: ${result.stderr}`);
  return JSON.parse(result.stdout);
};
const rowIdOf = text => {
  const match = /#(\d+)/.exec(text || '');
  if (!match) throw new Error(`no row id in: ${text}`);
  return Number(match[1]);
};

// A lander in another PROCESS, which is the only way to test a lease: it must outlive this script's
// own call. Output is captured line by line so a test can wait for a specific claim.
function lander(args) {
  const child = spawn(process.execPath, [CLI, ...args, '--repo', CANONICAL], {env: ENV});
  child.out = '';
  child.stdout.on('data', chunk => { child.out += String(chunk); });
  child.stderr.on('data', chunk => { child.out += String(chunk); });
  child.ended = new Promise(resolve => child.on('close', code => { child.code = code; resolve(code); }));
  return child;
}
async function waitFor(child, pattern, label, timeout = 30000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (pattern.test(child.out)) return child.out;
    if (child.exitCode !== null && child.exitCode !== undefined) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  if (pattern.test(child.out)) return child.out;
  throw new Error(`timed out waiting for ${label}; output was:\n${child.out}`);
}
const release = id => {
  const result = q(['release', '--id', String(id), '--owner', SESSION, '--evidence', 'fixture released its claim']);
  if (result.status !== 0) throw new Error(`release #${id} failed: ${result.stderr}`);
  return result;
};

// ---- the fixture --------------------------------------------------------------------------------
function fixture() {
  fs.mkdirSync(WORK, {recursive: true});
  spawnSync('git', ['init', '-q', '--bare', ORIGIN]);
  fs.mkdirSync(CANONICAL, {recursive: true});
  git(CANONICAL, 'init', '-q', '-b', 'main');
  git(CANONICAL, 'config', 'user.name', 'Magaav');
  git(CANONICAL, 'config', 'user.email', '73175452+Magaav@users.noreply.github.com');
  git(CANONICAL, 'config', 'core.autocrlf', 'false');
  for (const dir of ['lua/core', 'docs', 'scripts', 'rust/wa-host/src']) fs.mkdirSync(path.join(CANONICAL, dir), {recursive: true});
  fs.writeFileSync(path.join(CANONICAL, 'lua/core/x.lua'), 'return 1\n');
  fs.writeFileSync(path.join(CANONICAL, 'docs/a.md'), '# a\n');
  fs.writeFileSync(path.join(CANONICAL, 'scripts/foo.sh'), 'echo hi\n');
  fs.writeFileSync(path.join(CANONICAL, 'rust/wa-host/src/lib.rs'), 'pub fn nothing() {}\n');
  // The release step a landing runs (docs/COMPONENTS.md "How a landed commit gets its binary"): a stub,
  // so this test measures THAT the landing calls the publisher with the right arguments and records its
  // answer, without a compiler or a network. WA_TEST_PUBLISH_FAIL makes it fail on purpose.
  fs.writeFileSync(path.join(CANONICAL, 'scripts/publish-node-binaries.sh'), [
    '#!/usr/bin/env bash',
    `printf '%s\n' "$*" >> "${WORK}/publisher-args"`,
    'if [ "${WA_TEST_PUBLISH_FAIL:-}" = 1 ]; then echo "publish-node-binaries: publish_tool_missing: gh is not on PATH" >&2; exit 2; fi',
    'echo "publish-node-binaries: covered: node-fixture covers the compiled inputs of $6 for aarch64-unknown-linux-gnu; nothing to build or publish"',
    'echo "publish-node-binaries ok: node-fixture"',
    '',
  ].join('\n'));
  fs.chmodSync(path.join(CANONICAL, 'scripts/publish-node-binaries.sh'), 0o755);
  git(CANONICAL, 'add', '-A');
  git(CANONICAL, 'commit', '-q', '-m', 'base');
  git(CANONICAL, 'remote', 'add', 'origin', ORIGIN);
  git(CANONICAL, 'push', '-q', 'origin', 'main');
  git(ORIGIN, 'symbolic-ref', 'HEAD', 'refs/heads/main');
  spawnSync('git', ['clone', '-q', ORIGIN, SIDE]);
  git(SIDE, 'config', 'user.name', 'Magaav');
  git(SIDE, 'config', 'user.email', '73175452+Magaav@users.noreply.github.com');
  // The ledger is the node's own database shape: resolveOwner reads `sessions`, nothing else.
  const db = new DatabaseSync(LEDGER);
  db.exec('CREATE TABLE sessions(id TEXT PRIMARY KEY, started_at REAL, ended_at REAL, updated_at REAL);');
  const now = Math.floor(Date.now() / 1000);
  db.prepare('INSERT INTO sessions VALUES(?,?,?,?)').run(SESSION, now - 60, null, now);
  db.close();
}
// A branch of the canonical repository: committed, then back to a clean main.
function branch(name, file, content) {
  git(CANONICAL, 'checkout', '-q', '-b', name, 'main');
  fs.mkdirSync(path.dirname(path.join(CANONICAL, file)), {recursive: true});
  fs.writeFileSync(path.join(CANONICAL, file), content);
  git(CANONICAL, 'add', '-A');
  git(CANONICAL, 'commit', '-q', '-m', `${name}: ${file}`);
  git(CANONICAL, 'checkout', '-q', 'main');
}
// Another lander's move of main, from a different checkout: the case the queue exists for.
function upstreamMove(file, content, message) {
  fs.mkdirSync(path.dirname(path.join(SIDE, file)), {recursive: true});
  fs.writeFileSync(path.join(SIDE, file), content);
  git(SIDE, 'add', '-A');
  git(SIDE, 'commit', '-q', '-m', message);
  git(SIDE, 'push', '-q', 'origin', 'main');
  git(CANONICAL, 'fetch', '-q', 'origin');
}

// ---- 1. two concurrent landers serialize; the waiter is told its position ------------------------
async function serialization() {
  const first = lander(['acquire', '--branch', 'change/serial-one', '--owner', SESSION, '--wait-seconds', '60']);
  const firstOut = await waitFor(first, /GRANTED/, 'the first lander to be granted');
  const firstId = rowIdOf(firstOut);
  check('a lander is granted the canonical checkout', /GRANTED/.test(firstOut), firstOut);

  const second = lander(['acquire', '--branch', 'change/serial-two', '--owner', SESSION, '--wait-timeout', '60']);
  const position = await waitFor(second, /waiting: position 1 of 2/, 'the second lander to report its position');
  check('the second lander reports its position and the holder',
    /position 1 of 2/.test(position) && /holder #\d+/.test(position), position);
  check('the second lander names the current holder\'s branch', /change\/serial-one/.test(position), position);

  const state = qJson(['status']);
  check('status names the holder', state.holder && state.holder.branch === 'change/serial-one', JSON.stringify(state.holder));
  check('status reports the waiting lander at position 1',
    state.waiting.length === 1 && state.waiting[0].position === 1 && state.waiting[0].branch === 'change/serial-two',
    JSON.stringify(state.waiting));
  check('the second lander has not been granted while the first holds', !/GRANTED/.test(second.out), second.out);

  release(firstId);
  const granted = await waitFor(second, /GRANTED/, 'the lease to be handed over in order');
  check('the lease is handed to the waiting lander in order', /change\/serial-two/.test(granted), granted);
  check('the handover names the wait', /after waiting \d+s/.test(granted), granted);
  const secondId = rowIdOf(granted);
  release(secondId);
  await second.ended;
  await first.ended;
  check('both landers ended cleanly', first.code === 0 && second.code === 0, `first=${first.code} second=${second.code}`);
}

// ---- 2. a dead holder is reclaimed, with a logged reason ----------------------------------------
async function deadHolder() {
  const doomed = lander(['acquire', '--branch', 'change/doomed', '--owner', SESSION, '--wait-seconds', '120']);
  const out = await waitFor(doomed, /GRANTED/, 'the doomed holder to be granted');
  const id = rowIdOf(out);
  doomed.kill('SIGKILL');
  await doomed.ended;
  const state = qJson(['status']);
  const reclaimed = state.reclaimed.find(entry => entry.id === id);
  check('a killed holder is reclaimed rather than blocking the queue', Boolean(reclaimed), JSON.stringify(state.reclaimed));
  check('the reclaim names the pid, the dead process and the free lease',
    /reclaimed after \d+s/.test(reclaimed.reason) && /pid \d+ is gone/.test(reclaimed.reason) && /lease .* not held/.test(reclaimed.reason),
    reclaimed.reason);
  const history = q(['history', '--limit', '20']);
  check('the reclaim is in the durable log, not only in the answer',
    /#\d+ reclaimed: reclaimed after \d+s: holder pid \d+ is gone, lease .* not held/.test(history.stdout), history.stdout);
  const holder = qJson(['status']).holder;
  check('the queue is free again after the reclaim', holder === null, JSON.stringify(holder));
}

// ---- 3. the upstream delta decides what is retested ---------------------------------------------
async function deltaClassification() {
  branch('change/proven', 'lua/core/z.lua', 'return 7\n');
  const record = q(['record', '--tree', 'change/proven', '--owner', SESSION, '--command', 'fixture focused checks']);
  check('a producer can record what its checks proved, keyed by the tree', record.status === 0, record.stderr);
  const proof = JSON.parse(q(['record', '--tree', 'change/proven', '--owner', SESSION, '--json']).stdout);
  check('the proof is a digest over the tree\'s test inputs', /^[0-9a-f]{64}$/.test(proof.digest) && proof.inputs > 0, JSON.stringify(proof));

  // Hold the lease so the branch has to WAIT while main moves: the measured situation.
  const holder = lander(['acquire', '--branch', 'change/holder', '--owner', SESSION, '--wait-seconds', '60']);
  const holderId = rowIdOf(await waitFor(holder, /GRANTED/, 'the fixture holder'));
  const landerProcess = lander(['land', '--branch', 'change/proven', '--owner', SESSION, '--dry-run']);
  await waitFor(landerProcess, /waiting: position 1 of 2/, 'the branch to queue behind the holder');

  upstreamMove('docs/extra.md', '# extra\n', 'docs: an extra page');
  release(holderId);
  const skipped = await waitFor(landerProcess, /(retest skipped|RETEST REQUIRED)/, 'the delta to be classified');
  check('a docs-only upstream move is classified as docs-only', /docs-only: \d+ path\(s\) moved, none of them read by a check/.test(skipped), skipped);
  check('a docs-only upstream move skips the branch suite', /retest skipped/.test(skipped) && !/RETEST REQUIRED/.test(skipped), skipped);
  check('the skip is by digest identity, and it says so',
    /already proven by 11111111-2222-3333-4444-555555555555/.test(skipped), skipped);
  await landerProcess.ended;
  check('the lander exits 0 for a skipped retest (dry run)', landerProcess.code === 0, String(landerProcess.code));

  // The same queue, the same branch, a Lua move instead: the lander is queued first, so the delta it
  // meets is the one that names the changed input.
  const forcedHolder = lander(['acquire', '--branch', 'change/holder-two', '--owner', SESSION, '--wait-seconds', '60']);
  const forcedHolderId = rowIdOf(await waitFor(forcedHolder, /GRANTED/, 'the second fixture holder'));
  const forcedLander = lander(['land', '--branch', 'change/proven', '--owner', SESSION]);
  await waitFor(forcedLander, /waiting: position 1 of 2/, 'the branch to queue behind the second holder');
  upstreamMove('lua/core/w.lua', 'return 4\n', 'lua: add w');
  release(forcedHolderId);
  const forced = await waitFor(forcedLander, /retest_required/, 'the Lua move to force a retest');
  await forcedLander.ended;
  check('a Lua move of upstream refuses to land without a retest', forcedLander.code === 75, forced);
  check('the refusal is named retest_required and lists the changed input',
    /retest_required/.test(forced) && /lua\/core\/w\.lua/.test(forced), forced);
  check('the forced retest says which class moved', /can change a check result \(lua\)/.test(forced), forced);

  // With the checks supplied the same landing runs them on the merged tree and publishes.
  const landed = q(['land', '--branch', 'change/proven', '--owner', SESSION, '--checks', 'echo fixture-checks-ran']);
  check('a forced retest lands once its checks pass', landed.status === 0, landed.stdout + landed.stderr);
  check('the forced retest ran the checks on the merged tree', /checks passed/.test(landed.stdout) && /fixture-checks-ran/.test(landed.stdout), landed.stdout);
  const originMain = git(ORIGIN, 'rev-parse', 'refs/heads/main').trim();
  const canonicalHead = git(CANONICAL, 'rev-parse', 'HEAD').trim();
  check('the landing is on origin/main and read back', originMain === canonicalHead && /readback origin refs\/heads\/main/.test(landed.stdout), landed.stdout);
  // A landing is the moment a commit becomes installable, so it publishes the aarch64 release for what
  // it just pushed - or says why not. Measured 2026-11-10: neither of that day's landings published one,
  // and the release had to be made by hand afterwards.
  const publisherArgs = fs.existsSync(path.join(WORK, 'publisher-args')) ? fs.readFileSync(path.join(WORK, 'publisher-args'), 'utf8').trim() : '';
  check('the landing publishes the aarch64 release for the landed commit',
    publisherArgs.includes('--ensure --publish --target aarch64-unknown-linux-gnu --commit ' + originMain), publisherArgs);
  check('and records the publisher answer in its own line',
    /release covered \(aarch64-unknown-linux-gnu\)/.test(landed.stdout), landed.stdout);

  const after = q(['classify', '--from', 'HEAD~1', '--to', 'HEAD', '--json']);
  const delta = JSON.parse(after.stdout);
  check('classify reports the moved paths with their classes',
    delta.paths.length > 0 && delta.paths.every(entry => typeof entry.class === 'string'), JSON.stringify(delta.paths));
  check('classify says a code move is test-relevant', delta.retest.required === true, JSON.stringify(delta.retest));

  // A publisher that cannot run is a fact about the release, never a rollback of a landing that
  // happened: main stays where it was pushed and the row says why no binary was published.
  fs.rmSync(path.join(WORK, 'publisher-args'), {force: true});
  branch('change/no-release', 'docs/no-release.md', '# no release\n');
  const unreleased = q(['land', '--branch', 'change/no-release', '--owner', SESSION, '--checks', 'echo fixture-checks-ran'],
    {env: {WA_TEST_PUBLISH_FAIL: '1'}});
  check('a landing whose release could not be published still lands', unreleased.status === 0, unreleased.stdout + unreleased.stderr);
  check('and the row records why the release was not published',
    /release failed \(aarch64-unknown-linux-gnu\): .*publish_tool_missing/.test(unreleased.stdout), unreleased.stdout);
  check('main is the same commit the landing pushed',
    git(ORIGIN, 'rev-parse', 'refs/heads/main').trim() === git(CANONICAL, 'rev-parse', 'HEAD').trim());
}

// ---- 6. a dead lander's unpushed merge is finished or rolled back, recorded ----------------------
function deadMergeRecovery() {
  const made = (name) => {
    git(CANONICAL, 'checkout', '-q', '-b', name, 'main');
    fs.writeFileSync(path.join(CANONICAL, 'docs', `${name.replace(/\//g, '-')}.md`), '# dead lander\n');
    git(CANONICAL, 'add', '-A');
    git(CANONICAL, 'commit', '-q', '-m', `${name}: a change`);
    git(CANONICAL, 'checkout', '-q', 'main');
    git(CANONICAL, 'merge', '-q', '--no-ff', '-m', `merge(${name}): a merge the lander never pushed`, name);
    return git(CANONICAL, 'rev-parse', 'HEAD').trim();
  };
  const before = git(ORIGIN, 'rev-parse', 'refs/heads/main').trim();
  const merged = made('change/dead-lander');
  check('the fixture has an unpushed landing merge and no holder', merged !== before && qJson(['status']).holder === null);
  const reported = qJson(['status']);
  check('status reports the unpushed merge without touching it',
    reported.recovery && reported.recovery.action === 'would_push' && reported.recovery.branch === 'change/dead-lander',
    JSON.stringify(reported.recovery));
  check('status did not push anything', git(ORIGIN, 'rev-parse', 'refs/heads/main').trim() === before);
  const next = q(['acquire', '--branch', 'change/after-dead', '--owner', SESSION, '--no-wait']);
  check('the next acquire finishes the dead holder\'s push', /NOT granted/.test(next.stdout), next.stdout + next.stderr);
  check('the push is the dead holder\'s merge, read back', git(ORIGIN, 'rev-parse', 'refs/heads/main').trim() === merged);
  const history = q(['history', '--limit', '20']);
  check('the recovery is recorded with the reason and the commit',
    /recovered: finished the push of a dead holder's landing merge: change\/dead-lander at [0-9a-f]{12}/.test(history.stdout), history.stdout);

  // The same residue, a push that cannot be made: roll back and keep the commit reachable.
  const rolled = made('change/dead-unpushed');
  const remote = git(CANONICAL, 'remote', 'get-url', 'origin').trim();
  git(CANONICAL, 'remote', 'set-url', 'origin', path.join(WORK, 'missing-origin.git'));
  const after = q(['acquire', '--branch', 'change/after-rollback', '--owner', SESSION, '--no-wait']);
  git(CANONICAL, 'remote', 'set-url', 'origin', remote);
  check('an unpushable merge is rolled back rather than left blocking the tree',
    /rolled back a dead holder's unpushed landing merge/.test(after.stdout), after.stdout + after.stderr);
  check('the rollback puts the tree back on origin/main',
    git(CANONICAL, 'rev-parse', 'HEAD').trim() === git(ORIGIN, 'rev-parse', 'refs/heads/main').trim());
  check('the rolled-back merge is kept on a rescue ref, never destroyed',
    git(CANONICAL, 'rev-parse', `refs/wa/recovered/${rolled.slice(0, 12)}`).trim() === rolled);
  check('the rollback is in the durable log',
    /recovered: rolled back a dead holder's unpushed landing merge/.test(q(['history', '--limit', '10']).stdout));
  git(CANONICAL, 'checkout', '-q', 'main');
}

// ---- 7. a deploy pins the commit it builds; a landing can move on afterwards --------------------
async function deployPin() {
  // A lander in progress first: the pin must wait for it, not resolve under it.
  const holder = lander(['acquire', '--branch', 'change/pin-holder', '--owner', SESSION, '--wait-seconds', '60']);
  const holderId = rowIdOf(await waitFor(holder, /GRANTED/, 'the pin fixture holder'));
  const pinner = lander(['pin', '--commit', 'HEAD', '--owner', SESSION, '--pin-dir', path.join(WORK, 'pins')]);
  const waiting = await waitFor(pinner, /waiting: position 1 of 2/, 'the deploy pin to queue behind the landing');
  check('a deploy pin names the landing it waits for', /holder #\d+ .*change\/pin-holder/.test(waiting), waiting);
  check('the pin has not resolved while the landing holds', !/pinned/.test(pinner.out), pinner.out);
  release(holderId);
  const granted = await waitFor(pinner, /pinned [0-9a-f]{12} at/, 'the pin to be granted after the landing');
  check('the pin ends its own lease and says the canonical tree is free again',
    /the lease is released and a landing may proceed/.test(granted), granted);
  await pinner.ended;
  check('the pin exits 0', pinner.code === 0, String(pinner.code));

  const pinned = JSON.parse((q(['pin', '--commit', 'HEAD', '--owner', SESSION, '--pin-dir', path.join(WORK, 'pins'), '--json']).stdout));
  check('a second pin reports its path and commit', /^[0-9a-f]{40,64}$/.test(pinned.commit) && fs.existsSync(pinned.pin), JSON.stringify(pinned));
  check('the pinned tree is detached at exactly the commit',
    git(pinned.pin, 'rev-parse', 'HEAD').trim() === pinned.commit,
    git(pinned.pin, 'rev-parse', 'HEAD').trim());
  // A landing after the pin moves main. The pin must not move with it: that is the whole point.
  fs.writeFileSync(path.join(CANONICAL, 'docs', 'after-pin.md'), '# after pin\n');
  git(CANONICAL, 'add', '-A');
  git(CANONICAL, 'commit', '-q', '-m', 'docs: a landing after the pin');
  git(CANONICAL, 'push', '-q', 'origin', 'main');
  check('a landing moved main after the pin', git(ORIGIN, 'rev-parse', 'refs/heads/main').trim() !== pinned.commit);
  check('the pinned build tree still holds the commit it was pinned at',
    git(pinned.pin, 'rev-parse', 'HEAD').trim() === pinned.commit);
  check('the pin is recorded as a deploy row, not a landing',
    /deploy-pin branch deploy\/[0-9a-f]{12}/.test(q(['history', '--limit', '20']).stdout), q(['history', '--limit', '20']).stdout);
}

// ---- 4. a dirty canonical checkout with no lease is refused, naming the files --------------------
function dirtyCanonical() {
  fs.writeFileSync(path.join(CANONICAL, 'docs', 'stray-edit.md'), '# edited in the wrong tree\n');
  const refused = q(['acquire', '--branch', 'change/anyone', '--owner', SESSION, '--no-wait']);
  check('an unleased dirty canonical checkout is refused', refused.status === 75, refused.stdout + refused.stderr);
  check('the refusal is named dirty_canonical and names the file',
    /dirty_canonical/.test(refused.stderr) && /docs\/stray-edit\.md/.test(refused.stderr), refused.stderr);
  const state = qJson(['status']);
  check('status flags the tree as dirty and lists the files',
    state.canonical_dirt.dirty === true && state.canonical_dirt.files.includes('docs/stray-edit.md'),
    JSON.stringify(state.canonical_dirt));
  fs.rmSync(path.join(CANONICAL, 'docs', 'stray-edit.md'));
  const clean = q(['acquire', '--branch', 'change/anyone', '--owner', SESSION, '--no-wait']);
  check('the same queue accepts the tree once it is clean', clean.status === 0 || /NOT granted/.test(clean.stdout), clean.stdout + clean.stderr);
}

// ---- 5. the owner is a harness session, proven against the ledger -------------------------------
function ownerIdentity() {
  const directory = q(['acquire', '--branch', 'change/x', '--owner', 'wt-queue', '--no-wait']);
  check('a directory name is refused as an owner', directory.status === 75 && /owner_not_a_session_id/.test(directory.stderr), directory.stderr);
  const guess = q(['acquire', '--branch', 'change/x', '--owner', 'deadbeef', '--no-wait']);
  check('a scratch-directory-shaped id is refused', guess.status === 75 && /owner_not_a_session_id/.test(guess.stderr), guess.stderr);
  const unknown = q(['acquire', '--branch', 'change/x', '--owner', OTHER, '--no-wait']);
  check('a uuid the harness does not know is refused', unknown.status === 75 && /owner_unknown_to_harness/.test(unknown.stderr), unknown.stderr);
  const known = q(['acquire', '--branch', 'change/known-owner', '--owner', SESSION, '--no-wait']);
  check('a live session id from the ledger is accepted, with its provenance',
    /ledger-live-session/.test(known.stdout) && /NOT granted/.test(known.stdout), known.stdout + known.stderr);
  const fromEnv = q(['acquire', '--branch', 'change/env-owner', '--no-wait'], {env: {WASM_AGENT_SESSION_ID: SESSION}});
  check('the harness marker wins when it is in the environment', /\(harness-env\)/.test(fromEnv.stdout), fromEnv.stdout);
  const mismatch = q(['acquire', '--branch', 'change/env-owner', '--owner', OTHER, '--no-wait'], {env: {WASM_AGENT_SESSION_ID: SESSION}});
  check('an owner that contradicts the harness marker is refused', /owner_mismatch/.test(mismatch.stderr), mismatch.stderr);
}

// ---- drift guards: the classifier and the checked-document list ---------------------------------
function classifierParity() {
  const paths = [
    'lua/core/agent.lua', 'lua/vendor/json.lua', 'docs/MEMORY.md', 'docs/ENVELOPE.md', 'tests/foo.rs',
    'ui/app.js', 'modules/x.wasm', 'skills/git-orchestrator/SKILL.md', 'skills/clean-disk/scripts/report.sh',
    'jobs/one.lua', 'benchmarks/x.mjs', 'review/notes.md', 'review-evidence/x.json', 'fixtures/data.json',
    'vault/keys.json', 'scripts/foo.sh', 'scripts/codemode-bundle.mjs', 'scripts/build-window.sh',
    'scripts/provision-codemode.sh', 'rust/wa-host/src/lib.rs', 'rust/Cargo.toml', 'wit/host.wit',
    'AGENTS.md', 'README.md', 'LICENSE', 'lane-policy.json', 'DESIGN.md', 'config/node.json',
  ];
  const script = `source "${path.join(REPO, 'scripts/lib/node-binaries.sh')}"; while read -r p; do if wa_compiled_input "$p"; then echo "$p 1"; else echo "$p 0"; fi; done`;
  const shell = spawnSync('bash', ['-c', script], {input: paths.join('\n') + '\n', encoding: 'utf8'});
  check('the shell authority answered', shell.status === 0 && shell.stdout.trim().split('\n').length === paths.length, shell.stderr);
  const disagreements = [];
  for (const line of shell.stdout.trim().split('\n')) {
    const [file, answer] = line.split(' ');
    if (compiledInput(file) !== (answer === '1')) disagreements.push(`${file}: shell=${answer} js=${compiledInput(file) ? 1 : 0}`);
  }
  check('the compiled-inputs classifier agrees with scripts/lib/node-binaries.sh', disagreements.length === 0, disagreements.join(', '));

  const promptDocs = fs.readFileSync(path.join(REPO, 'scripts/sync-prompt-docs.lua'), 'utf8');
  const instructions = fs.readFileSync(path.join(REPO, 'scripts/check-instructions.mjs'), 'utf8');
  const named = new Set();
  for (const match of promptDocs.matchAll(/"([A-Za-z0-9_./-]+\.md)"/g)) named.add(match[1]);
  for (const match of instructions.matchAll(/'([A-Za-z0-9_./-]+\.md)'/g)) named.add(match[1]);
  const unchecked = [...named].filter(file => !CHECK_INPUTS.has(file) && !/^(node_modules|docs\/reviews)/.test(file));
  check('every document a check reads is classified as able to change a check result',
    unchecked.length === 0, `missing from CHECK_INPUTS: ${unchecked.join(', ')}`);
  check('the checked-document list is itself test-relevant', [...CHECK_INPUTS].every(file => testRelevant(file)), '');

  const docsOnly = {before: treeDigest(REPO, 'HEAD~5'), after: treeDigest(REPO, 'HEAD')};
  check('the digest is a fact about the tree, not about the diff (stable across re-reads)',
    treeDigest(REPO, 'HEAD').retest === treeDigest(REPO, 'HEAD').retest, '');
  check('the digest resolves to a tree', /^[0-9a-f]{40,64}$/.test(docsOnly.after.tree), docsOnly.after.tree);
}

// ---- run ---------------------------------------------------------------------------------------
try {
  fixture();
  await serialization();
  await deadHolder();
  await deltaClassification();
  dirtyCanonical();
  deadMergeRecovery();
  await deployPin();
  ownerIdentity();
  classifierParity();
  console.log(`landing queue: ${passed} checks passed in ${Math.round((Date.now() - started) / 1000)}s`);
  console.log(`fixture kept for evidence: ${WORK}`);
} catch (error) {
  console.error(`landing queue: FAILED after ${passed} checks: ${error.message}`);
  console.error(`fixture for diagnosis: ${WORK}`);
  process.exitCode = 1;
}
