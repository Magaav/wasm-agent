#!/usr/bin/env node
// The known-failures baseline's own evidence: scripts/lib/landing-baseline.mjs (the judge) and the
// queue that acts on it (scripts/landing-queue.mjs `land`, `baseline`).
//
// The day it answers for (wasm_the_first, 2026-11-10): main's fast path was red with twelve Lua
// checks nobody's branch caused, the queue refused every landing that was not green, and five sessions
// improvised their own judge - each paying 6-15 minutes for a pristine baseline re-run. What is proved
// here, in order:
//
//   1. the judge: the same failures pass, a new failing name is WORSE, a failure that stopped failing
//      is tolerated (the base moves while a landing waits), a stricter section is never excused, and an
//      environment-only failure is a RETRY - never a verdict on the code;
//   2. a landing with no recorded baseline measures ONE pristine tree, records it, and passes on the
//      failures main already has;
//   3. the NEXT landing on that main reuses the record and runs no pristine tree at all - the measured
//      cost this change removes;
//   4. a branch that adds a failing name is refused, named, and nothing is pushed;
//   5. a branch whose check only ever fails as the machine is refused as `environment_blocked` after
//      exactly one serial retry, not as bad code;
//   6. `baseline --record` primes the record from a saved log, and `baseline --show` reads it back.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';
import {fileURLToPath} from 'node:url';
import {parseCheckLog, baselineRecord, judgeRun} from './lib/landing-baseline.mjs';

const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CLI = path.join(REPO, 'scripts', 'landing-queue.mjs');
const SESSION = '33333333-4444-5555-6666-777777777777';
const WORK = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-landing-baseline-'));
const ORIGIN = path.join(WORK, 'origin.git');
const CANONICAL = path.join(WORK, 'canonical');
const LEDGER = path.join(WORK, 'ledger.db');
const COUNTER = path.join(WORK, 'check-runs');
const CHURN = path.join(WORK, 'churn');
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
const q = (args, options = {}) => spawnSync(process.execPath, [CLI, ...args, '--repo', CANONICAL, '--owner', SESSION], {
  encoding: 'utf8', env: {...ENV, ...(options.env || {})}, timeout: 180000,
});
const originMain = () => git(ORIGIN, 'rev-parse', 'refs/heads/main').trim();
const runCount = () => (fs.existsSync(COUNTER) ? fs.readFileSync(COUNTER, 'utf8').split('\n').filter(Boolean).length : 0);

// ---- 1. the judge, without a repository ----------------------------------------------------------
//
// The fixture log shape is scripts/fast.sh's own contract, so these cases are the real parser on the
// real format - including the summary line and the `, environment` marker a starved row carries.
const LOG_KNOWN = [
  'FAIL lua scripts/test-known-on-main.lua (exit 1): the machine\'s component set is behind the tree',
  'fast: lua 9/10 passed (0 excluded: scripts/fast-path.exclude)',
  'fast path FAILED (1 of 11 checks, 0 skipped, 3s)',
].join('\n');
const runOf = (text, exitCode = 1) => parseCheckLog(text, {exitCode});
const known = runOf(LOG_KNOWN);
const knownBaseline = baselineRecord({run: known, command: 'bash scripts/fast.sh', commit: 'a'.repeat(40), digest: 'd'.repeat(64)});

check('a failing run is parsed by name', known.verdict === 'failed' && known.failures.length === 1 && known.failures[0].name === 'lua scripts/test-known-on-main.lua',
  JSON.stringify(known.failures));
check('the summary counts are the run\'s own', known.failed_checks === 1 && known.total_checks === 11, JSON.stringify({failed: known.failed_checks, total: known.total_checks}));
check('a green run is ok', runOf('fast: lua 10/10 passed\nfast path ok (11 checks, 0 skipped, 3s)', 0).ok);

const same = judgeRun({baseline: knownBaseline, run: known});
check('the same failures as the base tree pass', same.verdict === 'pass' && same.tolerated.length === 1, JSON.stringify(same));

const worse = runOf(LOG_KNOWN + '\nFAIL lua scripts/test-branch-broke.lua (exit 1): an assertion the branch changed\nfast path FAILED (2 of 12 checks, 0 skipped, 3s)');
const worseJudged = judgeRun({baseline: knownBaseline, run: worse});
check('a new failing name is WORSE', worseJudged.verdict === 'worse' && worseJudged.new_failures.includes('lua scripts/test-branch-broke.lua'), JSON.stringify(worseJudged));

const fixed = runOf('FAIL lua scripts/test-known-on-main.lua (exit 1): still red\nfast path FAILED (1 of 11 checks, 0 skipped, 3s)');
check('a failure that stopped failing is tolerated, not a failure', judgeRun({baseline: knownBaseline, run: fixed}).verdict === 'pass');

const green = runOf('fast: lua 11/11 passed\nfast path ok (12 checks, 0 skipped, 3s)', 0);
check('a green candidate passes against a RED base', judgeRun({baseline: knownBaseline, run: green}).verdict === 'pass');

const strict = runOf('FAIL rust wa-term (exit 101): a crate that will not compile\nfast path FAILED (2 of 12 checks, 0 skipped, 3s)');
check('a section main passed is never excused by another section main failed',
  judgeRun({baseline: knownBaseline, run: strict}).verdict === 'worse');

const environment = runOf([
  'fast: ENVIRONMENT lua scripts/test-needs-a-process.lua (exit 126: cannot fork) - retrying once, serially',
  'FAIL lua scripts/test-needs-a-process.lua (exit 126, environment): cannot fork: Resource temporarily unavailable',
  'fast path could not run: 1 check(s) were the machine (fork/spawn, retried serially once), 0 skipped, 3s',
].join('\n'), 3);
const environmentJudged = judgeRun({baseline: knownBaseline, run: environment});
check('an environment-only failure is a retry, not a verdict', environmentJudged.verdict === 'environment' && environmentJudged.environment.length === 1,
  JSON.stringify(environmentJudged));
check('the marker is parsed, so the queue does not have to guess from the text', environment.failures[0].environment === true && environment.verdict === 'failed');

const unnamed = parseCheckLog('Something went wrong\n', {exitCode: 1});
check('a check command that names no failure is unproven, not passed', judgeRun({baseline: knownBaseline, run: unnamed}).verdict === 'unproven');

const moreFailures = parseCheckLog(['FAIL lua scripts/test-known-on-main.lua (exit 1): x', 'fast path FAILED (3 of 11 checks, 0 skipped, 1s)'].join('\n'), {exitCode: 1});
check('more failing checks than the base is WORSE even with the same names',
  judgeRun({baseline: knownBaseline, run: moreFailures}).verdict === 'worse');

// ---- 2. a real queue, a real repository, a check that runs once per tree ---------------------------
function fixture() {
  fs.mkdirSync(WORK, {recursive: true});
  spawnSync('git', ['init', '-q', '--bare', ORIGIN]);
  fs.mkdirSync(CANONICAL, {recursive: true});
  git(CANONICAL, 'init', '-q', '-b', 'main');
  git(CANONICAL, 'config', 'user.name', 'Magaav');
  git(CANONICAL, 'config', 'user.email', '73175452+Magaav@users.noreply.github.com');
  git(CANONICAL, 'config', 'core.autocrlf', 'false');
  for (const dir of ['lua/core', 'scripts', 'marker']) fs.mkdirSync(path.join(CANONICAL, dir), {recursive: true});
  fs.writeFileSync(path.join(CANONICAL, 'lua/core/x.lua'), 'return 1\n');
  fs.writeFileSync(path.join(CANONICAL, 'scripts/foo.sh'), 'echo hi\n');
  fs.writeFileSync(path.join(CANONICAL, 'scripts/publish-node-binaries.sh'), [
    '#!/usr/bin/env bash',
    'echo "publish-node-binaries: covered: node-fixture covers the compiled inputs; nothing to build or publish"',
    'echo "publish-node-binaries ok: node-fixture"', '',
  ].join('\n'));
  fs.chmodSync(path.join(CANONICAL, 'scripts/publish-node-binaries.sh'), 0o755);
  git(CANONICAL, 'add', '-A');
  git(CANONICAL, 'commit', '-q', '-m', 'base');
  git(CANONICAL, 'remote', 'add', 'origin', ORIGIN);
  git(CANONICAL, 'push', '-q', 'origin', 'main');
  git(ORIGIN, 'symbolic-ref', 'HEAD', 'refs/heads/main');
  // The check command: main's own known failure, plus one the branch adds when it carries the marker
  // file (a real regression, because it travels with the branch and is absent from main), plus one the
  // whole MACHINE fails while a flag outside the repository is set (churn: it fails on main and on the
  // branch, which is what the re-check has to tell apart from a regression). Every run appends to one
  // counter, so "did this landing measure an extra tree?" is a number, not an impression. FAST_ONLY is
  // honoured the way scripts/fast.sh honours it, because the queue's re-check runs a named row.
  const checks = path.join(WORK, 'fixture-checks.sh');
  // The rows the queue's A-B-A re-check runs DIRECTLY (not through the check command), so they are real
  // Lua tests: one main always fails (the machine's), one fails only while the churn flag exists, and
  // one the branch adds - and a row a tree does not have cannot fail there.
  const posix = value => value.split(String.fromCharCode(92)).join('/');
  fs.writeFileSync(path.join(CANONICAL, 'scripts/test-known-on-main.lua'),
    "error('the machine component set is behind the tree')\n");
  fs.writeFileSync(path.join(CANONICAL, 'scripts/test-churn.lua'),
    "local flag = '" + posix(CHURN) + "'\nif host.read_file(flag) then error('this machine fails it for any tree') end\nprint('churn: ok')\n");
  // The check command: main's own known failure, plus one the branch adds when it carries the marker
  // file, plus one the whole MACHINE fails while a flag outside the repository is set. Every run appends
  // to one counter, so "how many times did the suite run for this landing?" is a number.
  fs.writeFileSync(checks, [
    '#!/usr/bin/env bash',
    "printf 'run\n' >> '" + posix(COUNTER) + "'",
    '[ -f marker/broken ] && echo "FAIL lua scripts/test-branch-broke.lua (exit 1): an assertion the branch changed"',
    '[ -f "' + posix(CHURN) + '" ] && echo "FAIL lua scripts/test-churn.lua (exit 1): this machine fails it for any tree"',
    '[ -f marker/env ] && {',
    '  echo "fast: ENVIRONMENT lua scripts/test-needs-a-process.lua (exit 126: cannot fork) - retrying once, serially"',
    '  echo "FAIL lua scripts/test-needs-a-process.lua (exit 126, environment): cannot fork: Resource temporarily unavailable"',
    '  echo "fast path could not run: 1 check(s) were the machine (fork/spawn, retried serially once), 0 skipped, 1s"',
    '  exit 3',
    '}',
    'echo "FAIL lua scripts/test-known-on-main.lua (exit 1): the machine component set is behind the tree"',
    'echo "fast: lua 9/10 passed (0 excluded: scripts/fast-path.exclude)"',
    'echo "fast path FAILED (1 of 11 checks, 0 skipped, 1s)"',
    'exit 1', '',
  ].join('\n'));
  fs.chmodSync(checks, 0o755);
  const db = new DatabaseSync(LEDGER);
  db.exec('CREATE TABLE sessions(id TEXT PRIMARY KEY, started_at REAL, ended_at REAL, updated_at REAL);');
  const now = Math.floor(Date.now() / 1000);
  db.prepare('INSERT INTO sessions VALUES(?,?,?,?)').run(SESSION, now - 60, null, now);
  db.close();
  return checks;
}

function branch(name, file, content) {
  git(CANONICAL, 'checkout', '-q', '-b', name, 'main');
  fs.mkdirSync(path.dirname(path.join(CANONICAL, file)), {recursive: true});
  fs.writeFileSync(path.join(CANONICAL, file), content);
  git(CANONICAL, 'add', '-A');
  git(CANONICAL, 'commit', '-q', '-m', `${name}: ${file}`);
  git(CANONICAL, 'checkout', '-q', 'main');
}

const checks = fixture();
const baselineCommand = `bash ${checks.replace(/\\/g, '/')}`;
const land = (name, extra = {}) => q(['land', '--branch', name, '--checks', baselineCommand, '--wait-timeout', '60'], extra);

// ---- 2. the first landing measures one pristine tree, and passes on main's own failures ----------
branch('change/one', 'lua/core/x.lua', 'return 1 -- one\n');
const first = land('change/one');
check('a landing on a red main passes when it adds no failure', first.status === 0, first.stdout + first.stderr);
check('and it says so by name, not by silence', /only the 1 failure\(s\) the base tree already has/.test(first.stdout || ''), first.stdout);
check('the first landing measured ONE baseline plus its own candidate', runCount() === 2, `${runCount()} run(s)`);
check('the measurement is reported as measured, once', /baseline measured on [0-9a-f]{12}/.test(first.stdout || ''), first.stdout);
const firstMain = originMain();
check('the first landing is on origin/main', /readback origin refs\/heads\/main/.test(first.stdout || '') && git(CANONICAL, 'rev-parse', 'HEAD').trim() === firstMain, firstMain);

// ---- 3. the next landing reuses it: no pristine run at all ---------------------------------------
branch('change/two', 'lua/core/x.lua', 'return 2\n');
const before = runCount();
const second = land('change/two');
check('a second landing on the same main lands too', second.status === 0, second.stdout + second.stderr);
check('it reused the recorded baseline instead of measuring a pristine tree', /baseline reused/.test(second.stdout || '') && !/baseline measured on [0-9a-f]{12}/.test(second.stdout || ''), second.stdout);
check('so exactly one check run happened: the candidate\'s own', runCount() === before + 1, `${runCount() - before} run(s) for the second landing`);
check('and it recorded the baseline for the main it landed', /baseline recorded for the new main/.test(second.stdout || ''), second.stdout);
const status = JSON.parse(q(['status', '--json', '--command', baselineCommand]).stdout || '{}');
check('status answers "what would a landing tolerate here?" without landing once',
  status.baseline && status.baseline.names.includes('lua scripts/test-known-on-main.lua'), JSON.stringify(status.baseline));
check('the status answer says where it came from', status.baseline.source === 'candidate' && status.baseline.measured_on === originMain(), JSON.stringify(status.baseline));

// ---- 4. a failure this machine has for ANY tree is not charged to the branch ----------------------
// The measured 2026-11-10 case: the suite's red set moves between two runs minutes apart. The check
// fails `test-churn.lua` for every tree while the flag exists, and the queue must not read that as the
// branch's doing - it re-checks on main and finds the same failure there.
branch('change/churn', 'lua/core/x.lua', 'return 3\n');
fs.writeFileSync(CHURN, 'on\n');
const churned = land('change/churn');
fs.rmSync(CHURN, {force: true});
check('a failure main also has right now does not refuse the landing', churned.status === 0, churned.stdout + churned.stderr);
check('and the queue says it checked main, by name', /fails on main too, so not this branch's: lua scripts\/test-churn\.lua/.test(churned.stdout || ''), churned.stdout);
const history = q(['history', '--limit', '60']).stdout || '';
check('the tolerated churn is in the durable log, not only in the answer',
  history.includes('unstable on this machine): lua scripts/test-churn.lua'), history.slice(-600));
check('the re-check runs the named rows, not the suite (the check command ran once for the landing)',
  runCount() === before + 2, `${runCount() - before} run(s): landing two, then the churn landing`);

// ---- 5. a branch that adds a failing name is refused, and nothing is pushed ----------------------
branch('change/broken', 'marker/broken', 'x\n');
// The branch also ADDS a failing test of its own, which is what a regression looks like: main has no
// such row (so it cannot fail there), the merged tree fails it.
git(CANONICAL, 'checkout', '-q', 'change/broken');
fs.writeFileSync(path.join(CANONICAL, 'scripts/test-branch-broke.lua'), "error('an assertion the branch changed')\n");
git(CANONICAL, 'add', '-A');
git(CANONICAL, 'commit', '-q', '-m', 'change/broken: a test that fails');
git(CANONICAL, 'checkout', '-q', 'main');
const mainBeforeBroken = originMain();
const broken = land('change/broken');
check('a new failing name refuses the landing', broken.status === 75, `${broken.status}: ${broken.stdout}${broken.stderr}`);
check('the refusal names the new failure and the rollback', /checks_failed/.test(broken.stderr || '') && /lua scripts\/test-branch-broke\.lua/.test(broken.stderr || '') && /rolled back/.test(broken.stderr || ''), broken.stderr);
check('and it says the new failure passes on main twice and fails on the merged tree', /pass on main twice and fail on the merged tree/.test(broken.stderr || ''), broken.stderr);
check('origin/main did not move', originMain() === mainBeforeBroken, `${originMain()} vs ${mainBeforeBroken}`);
check('the canonical tree was rolled back clean', git(CANONICAL, 'status', '--porcelain').trim() === '' && git(CANONICAL, 'rev-parse', 'HEAD').trim() === mainBeforeBroken);
check('a refused landing still costs one suite run: the attribution is measured per row',
  runCount() === before + 3, `${runCount() - before} run(s) including the refused landing`);

// ---- 6. a machine that cannot run the check is a retry, never a code verdict ---------------------
branch('change/starved', 'marker/env', 'x\n');
const mainBeforeStarved = originMain();
const runsBeforeStarved = runCount();
const starved = land('change/starved');
check('an environment-only failure is refused as environment_blocked', starved.status === 75 && /environment_blocked/.test(starved.stderr || ''), `${starved.status}: ${starved.stderr}`);
check('the refusal says the code was never judged and no change is needed', /not a verdict on/.test(starved.stderr || '') && /no code change is needed/.test(starved.stderr || ''), starved.stderr);
check('it retried the check exactly once, serially', /retrying .* once, serially/.test(starved.stdout || '') && runCount() === runsBeforeStarved + 2,
  `${runCount() - runsBeforeStarved} run(s): ${starved.stdout}`);
check('origin/main did not move for a machine failure', originMain() === mainBeforeStarved);

// ---- 7. the record can be primed from a saved log, and read back ---------------------------------
fs.writeFileSync(path.join(WORK, 'saved.log'), [
  'FAIL lua scripts/test-known-on-main.lua (exit 1): measured elsewhere',
  'fast path FAILED (1 of 11 checks, 0 skipped, 1s)', '',
].join('\n'));
const recorded = q(['baseline', '--command', baselineCommand, '--record', path.join(WORK, 'saved.log'), '--json']);
check('a saved log can be recorded as the baseline', recorded.status === 0, recorded.stderr);
const shown = JSON.parse(q(['baseline', '--command', baselineCommand, '--json']).stdout || '{}');
check('and read back by name', shown.baseline && shown.baseline.names.includes('lua scripts/test-known-on-main.lua'), JSON.stringify(shown.baseline));
check('the record says where it came from', shown.baseline.source === 'recorded', JSON.stringify(shown.baseline));
const human = q(['baseline', '--command', baselineCommand]);
check('the human view names each known failure', /known: lua scripts\/test-known-on-main\.lua/.test(human.stdout || ''), human.stdout);

// ---- 8. `baseline --measure` answers the question on demand --------------------------------------
//
// The command string is the record's key, so a different spelling is a different question - which is
// exactly the position a session is in when it wants to know what main already fails under ITS check
// command. Before this, the command could only read a record: a session with no record either landed
// once (paying for a pristine run it did not want) or improvised its own judge.
const measureCommand = `${baselineCommand} --on-demand`;
const beforeMeasure = runCount();
const measured = q(['baseline', '--command', measureCommand, '--measure', '--json']);
check('baseline --measure measures when nobody has recorded one', measured.status === 0, measured.stdout + measured.stderr);
check('it ran the check command exactly once', runCount() === beforeMeasure + 1, `${runCount() - beforeMeasure} run(s)`);
const measuredJson = JSON.parse(measured.stdout || '{}');
check('and recorded what main itself fails',
  (measuredJson.baseline && measuredJson.baseline.names || []).includes('lua scripts/test-known-on-main.lua'),
  JSON.stringify(measuredJson.baseline));
check('the canonical checkout is back on main afterwards', git(CANONICAL, 'rev-parse', '--abbrev-ref', 'HEAD').trim() === 'main');
const reread = q(['baseline', '--command', measureCommand, '--measure', '--json']);
check('a second call reuses the record and measures nothing',
  reread.status === 0 && runCount() === beforeMeasure + 1, `${runCount() - beforeMeasure} run(s): ${reread.stdout}`);
const humanMeasured = q(['baseline', '--command', `${baselineCommand} --human`, '--measure']);
check('the human view says the answer was measured now, and names what main fails',
  humanMeasured.status === 0 && /known failure\(s\) MEASURED now/.test(humanMeasured.stdout || '')
  && /  known: lua scripts\/test-known-on-main\.lua/.test(humanMeasured.stdout || ''), humanMeasured.stdout);
check('and that measurement ran the command once too', runCount() === beforeMeasure + 2, `${runCount() - beforeMeasure} run(s)`);

console.log(`landing-baseline: ${passed} checks passed in ${Math.round((Date.now() - started) / 1000)}s`);
try { fs.rmSync(WORK, {recursive: true, force: true}); } catch { /* windows may still hold a lock */ }
