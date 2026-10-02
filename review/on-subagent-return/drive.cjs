#!/usr/bin/env node
// Review probe: drive the REAL observe -> compose path of scripts/subagent-return-hook.mjs over hand-built
// child records, and print the verdict each one produces, with the exact command the verdict came from.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawn, spawnSync} = require('node:child_process');

const HOOK = process.argv[2];
const scratch = process.argv[3];
const probe = path.join(scratch, 'probe');
const runs = path.join(scratch, 'runs');
fs.rmSync(runs, {recursive: true, force: true});
fs.mkdirSync(runs, {recursive: true});

const git = (...args) => {
  const r = spawnSync('git', args, {encoding: 'utf8', timeout: 60000, windowsHide: true});
  if (r.status !== 0) throw new Error(`git ${args.join(' ')}: ${r.stderr}`);
  return r.stdout.trim();
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function checkout(name, changedPath, {commit = true, dirty = null} = {}) {
  const dir = path.join(scratch, 'checkouts', name);
  fs.mkdirSync(dir, {recursive: true});
  git('init', '-q', '-b', 'main', dir);
  git('-C', dir, 'config', 'user.email', 'probe@example.invalid');
  git('-C', dir, 'config', 'user.name', 'probe');
  fs.writeFileSync(path.join(dir, 'README.md'), 'base\n');
  git('-C', dir, 'add', '-A'); git('-C', dir, 'commit', '-qm', 'base');
  git('-C', dir, 'update-ref', 'refs/remotes/origin/main', 'HEAD');
  const mainHead = git('-C', dir, 'rev-parse', 'HEAD');
  git('-C', dir, 'checkout', '-qb', `change/${name}`);
  if (changedPath) {
    const target = path.join(dir, changedPath);
    fs.mkdirSync(path.dirname(target), {recursive: true});
    fs.writeFileSync(target, `changed by ${name}\n`);
    if (commit) { git('-C', dir, 'add', '-A'); git('-C', dir, 'commit', '-qm', `work from ${name}`); }
  }
  if (dirty) {
    const target = path.join(dir, dirty);
    fs.mkdirSync(path.dirname(target), {recursive: true});
    fs.writeFileSync(target, `uncommitted\n`);
  }
  return {worktree: dir, branch: `change/${name}`, head: git('-C', dir, 'rev-parse', 'HEAD'), mainHead};
}

const fixtures = {};
fixtures.equals_main = checkout('equals-main', null);
fixtures.equals_main_dirty = checkout('equals-main-dirty', null, {dirty: 'ui/app.js'});
fixtures.shipped_script = checkout('shipped-script', 'scripts/whatsapp-read.mjs');
fixtures.test_file = checkout('test-file', 'tests/probe.cjs');
fixtures.job_definition = checkout('job-definition', 'jobs/on-subagent-return.json');
fixtures.wave_script = checkout('wave-script', 'scripts/wave-probe.sh');
fixtures.ship_wave = checkout('ship-wave', 'scripts/ship-wave.mjs');
fixtures.only_lib = checkout('only-lib', 'scripts/lib/probe.cjs');
fixtures.only_lib_nested = checkout('only-lib-nested', 'scripts/lib/nested/probe.cjs');
fixtures.only_deploy = checkout('only-deploy', 'scripts/deploy.sh');
// An orphan branch: a commit with no merge base against origin/main at all.
{
  const dir = fixtures.equals_main.worktree;
  git('-C', dir, 'checkout', '-q', '--orphan', 'orphan');
  fs.rmSync(path.join(dir, 'README.md'));
  fs.writeFileSync(path.join(dir, 'unrelated.txt'), 'orphan\n');
  git('-C', dir, 'add', '-A'); git('-C', dir, 'commit', '-qm', 'orphan root');
  fixtures.orphan = {worktree: dir, branch: 'orphan', head: git('-C', dir, 'rev-parse', 'HEAD')};
  git('-C', dir, 'checkout', '-q', 'change/equals-main');
}

function artifactsFor(f) {
  if (f === null) return {available: false, reason: 'artifact_facts_failed: no session record'};
  if (f.raw) return f.raw;
  return {available: true, managed: true, state: 'clean', worktree: f.worktree, recorded_branch: f.branch,
    branch: f.branch, head: f.head, ahead: 1, behind: 0, pushed: false, dirty: f.dirty || 0, untracked: 0};
}

const CASES = [
  ['c1_no_branch_no_worktree', 'child with no recorded branch and no worktree',
    {raw: {available: true, managed: true, state: 'clean', worktree: '', branch: '', head: ''}}],
  ['c2_no_completion_packet', 'child whose completion packet is absent (artifacts unreadable)', null],
  ['c3_worktree_gone', 'child whose recorded worktree no longer exists',
    {raw: {available: true, managed: true, worktree: path.join(scratch, 'gone-repo'), branch: 'change/gone',
      head: 'a'.repeat(40), ahead: 1, dirty: 0}}],
  ['c4_tip_equals_main', 'child whose tip equals main (branch created at main, no commits)', fixtures.equals_main],
  ['c4b_tip_equals_main_dirty', 'tip equals main but the worktree holds an uncommitted ui/** change',
    {...fixtures.equals_main_dirty, dirty: 1}],
  ['c5_tip_unreachable_from_main', 'tip not reachable from origin/main (orphan commit)', fixtures.orphan],
  ['c6_only_shipped_script', 'changed ONLY scripts/whatsapp-read.mjs', fixtures.shipped_script],
  ['c7_only_test_file', 'changed ONLY tests/probe.cjs', fixtures.test_file],
  ['c8_only_job_definition', 'changed ONLY jobs/on-subagent-return.json (a deploy DOES copy it)', fixtures.job_definition],
  ['c9_only_wave_script', 'changed ONLY scripts/wave-probe.sh', fixtures.wave_script],
  ['c10_ship_wave_mjs', 'changed ONLY scripts/ship-wave.mjs', fixtures.ship_wave],
  ['c11_only_lib_module', 'changed ONLY scripts/lib/probe.cjs', fixtures.only_lib],
  ['c12_only_lib_nested', 'changed ONLY scripts/lib/nested/probe.cjs', fixtures.only_lib_nested],
  ['c13_only_deploy_sh', 'changed ONLY scripts/deploy.sh', fixtures.only_deploy],
];

(async () => {
  for (const [id, description, fixture] of CASES) {
    const run = path.join(runs, id);
    fs.mkdirSync(path.join(run, 'emit'), {recursive: true});
    const artifacts = artifactsFor(fixture);
    const task = {subagent_id: id, state: 'completed', settled: true, session_id: `session-${id}`,
      profile: 'task-worker', parent_session_id: 'session-orchestrator', execution_node: 'local'};
    const spec = [{task, completion: fixture === null ? undefined
      : {child_id: id, state: 'completed', detail: '{}', packet: JSON.stringify({
          child: {id, state: 'completed', profile: 'task-worker'},
          session: {id: `session-${id}`, parent: 'session-orchestrator'}, artifacts})}}];
    const specFile = path.join(run, 'spec.json');
    const portFile = path.join(run, 'port');
    fs.writeFileSync(specFile, JSON.stringify(spec));
    const node = spawn(process.execPath, [path.join(probe, 'fake-node.cjs'), specFile, portFile],
      {stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
    let port = '';
    for (let i = 0; i < 100 && !port; i += 1) { await sleep(50); if (fs.existsSync(portFile)) port = fs.readFileSync(portFile, 'utf8').trim(); }
    const observe = spawnSync(process.execPath, [HOOK, '--observe', '--node', `http://127.0.0.1:${port}`,
      '--state', path.join(run, 'state.json'), '--emit-command', path.join(probe, 'fake-emit.sh')],
      {encoding: 'utf8', windowsHide: true, timeout: 60000, env: {...process.env, PROBE_EMIT_DIR: path.join(run, 'emit')}});
    node.kill();
    const payloadFile = path.join(run, 'emit', `${id}.json`);
    const report = JSON.parse(observe.stdout);
    let payload = null;
    let composed = null;
    if (fs.existsSync(payloadFile)) {
      payload = JSON.parse(fs.readFileSync(payloadFile, 'utf8'));
      const composedRun = spawnSync(process.execPath, [HOOK, '--compose', '--event', payloadFile],
        {encoding: 'utf8', windowsHide: true});
      composed = JSON.parse(composedRun.stdout);
    }
    console.log(`### ${id} - ${description}`);
    console.log(`observed=${report.observed} settled=${report.settled} emitted=${report.emitted} unreadable=[${report.unreadable}] errors=[${report.errors}]`);
    if (payload) {
      console.log(`changed_paths=${payload.changed_paths ? JSON.stringify(payload.changed_paths) : 'ABSENT'}`);
      console.log(`changed_paths_error=${payload.changed_paths_error || '-'}`);
      console.log(`changed_paths_source=${payload.changed_paths_source || '-'}`);
    }
    console.log(`VERDICT: ${composed ? composed.verdict : '(no event emitted)'}${composed && composed.reason ? ' (' + composed.reason + ')' : ''}`);
    console.log('');
  }
})().catch((error) => { console.error(error.stack); process.exitCode = 1; });
