#!/usr/bin/env node
// scripts/test-discriminates.sh, judged by the only thing that matters about it: does it separate a test
// that would have caught a bug from one that would not?
//
// The fixture branch carries one GOOD test (it asserts on the value the fix changes) and one VACUOUS
// test (it prints and exits 0), plus the two outcomes that must NOT count as evidence: a test that dies
// on a missing symbol before reaching an assertion, and a test for a file the branch itself adds.
//
// Hermetic: a scratch Git repository, a scratch HOME, no node, no network, no binary. The subject needs
// no wa to judge a shell fixture, which is what keeps this check cheap enough for the land step.
//
// Where it runs: scripts/fast.sh (contract checks) and scripts/gate-checks.mjs ("discrimination").
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const SUBJECT = path.join(root, 'scripts/test-discriminates.sh');
assert.ok(fs.existsSync(SUBJECT), 'the subject is missing: ' + SUBJECT);

const home = fs.mkdtempSync(path.join(os.tmpdir(), 'disc-home-'));
const repo = path.join(home, 'fixture');
fs.mkdirSync(repo, {recursive: true});
const env = {...process.env, HOME: home, WASM_AGENT_HOME: home};
for (const k of ['WASM_AGENT_VAULT_URL', 'WASM_AGENT_VAULT_DIR', 'WASM_AGENT_DB', 'WASM_AGENT_RENDEZVOUS', 'WASM_AGENT_RELAY']) delete env[k];

const git = (...args) => execFileSync('git', args, {cwd: repo, env, encoding: 'utf8'});
const write = (rel, text) => {
  const full = path.join(repo, rel);
  fs.mkdirSync(path.dirname(full), {recursive: true});
  fs.writeFileSync(full, text);
};
const run = (...args) => spawnSync('bash', [SUBJECT, ...args], {cwd: home, env, encoding: 'utf8'});

// One row per test on stdout: <verdict>\t<path>\t<reason>. A line without two tabs is a runner line.
const rowsOf = out => Object.fromEntries(out.split('\n')
  .filter(l => l.split('\t').length >= 3 && !l.startsWith('test-discriminates:'))
  .map(l => { const [verdict, file, ...reason] = l.split('\t'); return [file, {verdict, reason: reason.join(' ')}]; }));

let failed = 0, checks = 0;
const ok = (condition, label) => { checks++; if (!condition) { failed++; console.error('FAIL ' + label); } };

try {
  git('init', '-q', '-b', 'main', '.');
  git('config', 'user.email', 'fixture@example.invalid');
  git('config', 'user.name', 'fixture');
  write('lua/knob.txt', 'VALUE=old\n');
  write('scripts/test-existing.sh', 'echo ok\n');
  git('add', '-A'); git('commit', '-qm', 'base');

  git('checkout', '-qb', 'change/fix');
  write('lua/knob.txt', 'VALUE=new\n');
  // GOOD: fails on the old value, for the reason the fix exists.
  write('scripts/test-good.sh', 'grep -q VALUE=new lua/knob.txt || { echo "FAIL: the knob is still old"; exit 1; }\n');
  // VACUOUS: green whatever the code does.
  write('scripts/test-vacuous.sh', 'echo everything is fine\n');
  // DIES BEFORE ITS ASSERTIONS: a missing symbol is not evidence about the change.
  write('scripts/test-loaderror.sh', 'source lua/does-not-exist.sh\n');
  git('add', '-A'); git('commit', '-qm', 'the fix');

  // 1. FIX MODE. The good test discriminates, the vacuous one is named as not discriminating, and the
  //    script says so through its exit code (a check whose failure is a printout is not a check).
  {
    const r = run('main', '--repo', repo);
    const rows = rowsOf(r.stdout);
    ok(r.status === 1, 'fix mode exits 1 when a test does not discriminate, got ' + r.status);
    ok(rows['scripts/test-good.sh']?.verdict === 'discriminates', 'the good test discriminates: ' + JSON.stringify(rows['scripts/test-good.sh']));
    ok(rows['scripts/test-vacuous.sh']?.verdict === 'does-not', 'the vacuous test does not discriminate: ' + JSON.stringify(rows['scripts/test-vacuous.sh']));
    ok(/passed on the reverted code/.test(rows['scripts/test-vacuous.sh']?.reason ?? ''), 'the vacuous row says why');
    ok(rows['scripts/test-loaderror.sh']?.verdict === 'does-not', 'a load error is not evidence: ' + JSON.stringify(rows['scripts/test-loaderror.sh']));
    ok(/No such file|does-not-exist/.test(rows['scripts/test-loaderror.sh']?.reason ?? ''), 'the load-error row names the missing thing');
    ok(!Object.keys(rows).includes('lua/knob.txt'), 'a changed non-test path is not reported as a test');
    ok(fs.readdirSync(home).every(n => !n.startsWith('.discriminates-')), 'the scratch worktree is removed after a run');
  }

  // 2. JSON is what a consumer parses: one object per test, not a formatter's best guess.
  {
    const r = run('main', '--repo', repo, '--json');
    const line = r.stdout.split('\n').find(l => l.startsWith('{"rows"'));
    let parsed;
    try { parsed = JSON.parse(line); } catch (e) { parsed = null; }
    ok(parsed !== null, 'the --json line parses as JSON: ' + line);
    ok(parsed?.rows?.length === 3, 'the JSON carries every test row, got ' + parsed?.rows?.length);
    ok(parsed?.rows?.some(x => x.verdict === 'discriminates' && x.test === 'scripts/test-good.sh'), 'the JSON keeps the verdict and the file');
  }

  // 3. A REFACTOR-ONLY branch is exempt from discriminating, and must instead keep its tests green: the
  //    same vacuous test is the evidence here, and the good test (which fails on old code) is the blocker.
  git('checkout', '-qB', 'change/refactor', 'main');
  write('lua/knob.txt', 'VALUE=old\n');
  write('scripts/test-good.sh', 'grep -q VALUE=new lua/knob.txt || { echo "FAIL: the knob is still old"; exit 1; }\n');
  write('scripts/test-vacuous.sh', 'echo everything is fine\n');
  write('docs/missions/reports/fixture.md', 'Refactor-only: the value moves, nothing else changes\n');
  git('add', '-A'); git('commit', '-qm', 'a refactor');
  {
    const r = run('main', '--repo', repo);
    const rows = rowsOf(r.stdout);
    ok(/refactor-only/.test(r.stdout), 'the refactor declaration is echoed');
    ok(rows['scripts/test-vacuous.sh']?.verdict === 'green', 'a green test is the evidence on a refactor: ' + JSON.stringify(rows['scripts/test-vacuous.sh']));
    ok(rows['scripts/test-good.sh']?.verdict === 'does-not', 'a test that is red on the refactored code blocks: ' + JSON.stringify(rows['scripts/test-good.sh']));
    ok(r.status === 1, 'fix mode and refactor mode agree on the exit code: got ' + r.status);
  }

  // 4. A TEST FOR NEW CODE cannot discriminate by construction: the base has no behaviour to tell apart.
  //    Its subject must be a path the branch ADDS, and it is reported as such, never as a pass.
  git('checkout', '-qB', 'change/new-tool', 'main');
  write('scripts/new-tool.sh', 'echo tool\n');
  write('scripts/test-new-tool.sh', 'bash scripts/new-tool.sh | grep -q tool || { echo "FAIL: the tool prints nothing"; exit 1; }\n');
  git('add', '-A'); git('commit', '-qm', 'a new tool with its test');
  {
    const r = run('main', '--repo', repo);
    const rows = rowsOf(r.stdout);
    ok(rows['scripts/test-new-tool.sh']?.verdict === 'not-applicable', 'a test for an added file is not-applicable: ' + JSON.stringify(rows['scripts/test-new-tool.sh']));
    ok(/scripts\/new-tool.sh/.test(rows['scripts/test-new-tool.sh']?.reason ?? ''), 'and its reason names the file it tests');
    ok(r.status === 0, 'nothing blocks on a spec for new code, got ' + r.status);
  }

  // 5. A BRANCH WITH NO NEW TEST says so and does not pretend to have checked anything.
  git('checkout', '-qB', 'change/no-test', 'main');
  write('lua/knob.txt', 'VALUE=changed\n');
  git('add', '-A'); git('commit', '-qm', 'no test');
  {
    const r = run('main', '--repo', repo);
    ok(r.status === 0, 'a branch with no new test does not block with a verdict it cannot give, got ' + r.status);
    ok(/adds or changes no test/.test(r.stdout), 'and it says why it had nothing to check: ' + r.stdout);
  }

  // 6. UNKNOWN IS NOT YES. A base that is not a commit is a refusal with a code, never a green run.
  {
    const r = run('no-such-ref', '--repo', repo);
    ok(r.status === 76, 'an unreadable base refuses with 76, got ' + r.status);
    ok(/refused/.test(r.stdout + r.stderr), 'and the refusal is named');
  }

  // 7. The real home is never the fixture: the script runs with the home it is given and creates its
  //    worktree beside the repository, so a broken fixture cannot reach the operator's tree.
  ok(env.WASM_AGENT_HOME === home && home !== os.homedir(), 'this check runs against a scratch home');
} finally {
  fs.rmSync(home, {recursive: true, force: true});
}

if (failed > 0) { console.error('test-discriminates: ' + failed + ' of ' + checks + ' checks failed'); process.exit(1); }
console.log('test-discriminates: ' + checks + ' checks ok');
