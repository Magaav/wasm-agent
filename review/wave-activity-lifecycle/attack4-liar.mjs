// ATTACK 4 (independent). Three third-party conditions, one expectation: the ownership and
// registry assertions still RUN and still DECIDE.
//   (a) orca genuinely absent from PATH                  -> refused, by name
//   (b) orca present but exiting nonzero / garbage        -> refused, by name
//   (c) orca present and LYING (exit 0, plausible JSON    -> refused, by name, and the lie is
//       that claims the unowned tree is a healthy card)      recorded as advisory only
// Then the offending tree is removed and the same assertions must PASS, so they are not vacuous.
// Everything runs in a private fixture; the harness's own cwd is the only thing NODE_OPTIONS needs.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {DatabaseSync} from 'node:sqlite';

const source = process.cwd();
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-review-liar-'));
let checks = 0;
const check = (v, label) => { assert.ok(v, label); checks++; };
const git = (repo, ...args) => { const r = spawnSync('git', ['-C', repo, ...args], {encoding: 'utf8', windowsHide: true}); assert.equal(r.status, 0, r.stderr); return r.stdout.trim(); };

const repo = path.join(root, 'canonical'), data = path.join(root, 'data'), poison = path.join(root, 'poison');
fs.mkdirSync(repo); fs.mkdirSync(data, {recursive: true}); fs.mkdirSync(poison);
git(repo, 'init', '-q', '-b', 'main'); git(repo, 'config', 'user.name', 'fixture'); git(repo, 'config', 'user.email', 'fixture@invalid');
fs.writeFileSync(path.join(repo, 'seed'), 'fixture\n'); git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'baseline');
const main = git(repo, 'rev-parse', 'HEAD');

const orphan = path.join(data, 'wa-worktree-orphan');
const parked = path.join(data, 'wa-worktree-parked');
git(repo, 'worktree', 'add', '--detach', orphan);
git(repo, 'worktree', 'add', '--detach', parked);
const db = new DatabaseSync(path.join(data, 'memory.db'));
db.exec(`CREATE TABLE sessions(id TEXT PRIMARY KEY,worktree TEXT NOT NULL DEFAULT '',workspace_required INTEGER NOT NULL DEFAULT 0,
  workspace_state TEXT NOT NULL DEFAULT 'unbound',workspace_branch TEXT NOT NULL DEFAULT '',workspace_base_commit TEXT NOT NULL DEFAULT '',
  workspace_source_path TEXT NOT NULL DEFAULT '',workspace_start_state TEXT NOT NULL DEFAULT '{}',parent_session_id TEXT,
  started_at REAL NOT NULL DEFAULT 0,ended_at REAL,updated_at REAL NOT NULL DEFAULT 0);
CREATE TABLE steering_runs(session_id TEXT PRIMARY KEY,owner TEXT NOT NULL DEFAULT '',run_id TEXT NOT NULL DEFAULT '',boot TEXT NOT NULL DEFAULT '',state TEXT NOT NULL,updated_at REAL NOT NULL);
CREATE TABLE child_completions(child_id TEXT PRIMARY KEY,target_id TEXT NOT NULL DEFAULT '',parent_session TEXT NOT NULL DEFAULT '',state TEXT NOT NULL,run_id TEXT NOT NULL DEFAULT '');`);
db.prepare("INSERT INTO sessions(id,worktree,workspace_required,workspace_state,workspace_branch,workspace_source_path,workspace_start_state,started_at,ended_at,updated_at) VALUES(?,?,1,'parked','',?,?,0,1,0)")
  .run('parked-session', parked.replaceAll('\\', '/'), repo.replaceAll('\\', '/'), JSON.stringify({executor: {owner_boot: 'boot-parked'}}));
db.close();

// (b)/(c): a real executable named orca.exe. As node.exe it exits nonzero with a stack trace for
// `worktree list --json`; with the relative --require it prints the lie instead.
fs.copyFileSync(process.execPath, path.join(poison, 'orca.exe'));
const orcaFree = String(process.env.PATH || '').split(path.delimiter).filter(e => e && !/orca/i.test(e)).join(path.delimiter);
const base = {...process.env, PATH: [poison, orcaFree].join(path.delimiter), WA_LIE_DIR: data, WA_LIE_HEAD: main};
const config = {repo, data, source_root: source, orca_view: true, process_probe: false};
const configFile = path.join(root, 'config.json'); fs.writeFileSync(configFile, JSON.stringify(config));

const run = (kind, env, extra = {}) => {
  const r = spawnSync(process.execPath, [path.join(source, 'scripts/wave-proof.mjs'), kind, configFile], {encoding: 'utf8', windowsHide: true, timeout: 180000, env: {...env, WA_WAVE_ID: 'liar', WA_WAVE_MAIN: main, ...extra}});
  let proof; try { proof = JSON.parse(r.stdout.trim()); } catch { throw Error(`${kind} wrote no verdict: ${JSON.stringify(r.stdout)} ${r.stderr}`); }
  return {status: r.status, proof};
};

try {
  // (the harness's own cwd must hold the liar for the relative --require to resolve)
  check(fs.existsSync(path.join(source, '.review-scratch', 'orca-lie.cjs')), 'the liar module is reachable from the harness cwd');

  const conditions = [
    ['orca absent', {PATH: orcaFree}, false],
    ['orca present but broken', base, false],
    ['orca present and lying', {...base, NODE_OPTIONS: '--require=./.review-scratch/orca-lie.cjs'}, true],
  ];
  for (const [label, env, lying] of conditions) {
    if (label === 'orca absent') {
      const probe = spawnSync('orca', ['--version'], {encoding: 'utf8', windowsHide: true, env});
      check(Boolean(probe.error) || probe.status !== 0, 'orca is genuinely unreachable on this PATH');
    } else if (lying) {
      const lied = spawnSync('orca', ['worktree', 'list', '--json'], {encoding: 'utf8', windowsHide: true, env});
      let value = null; try { value = JSON.parse(lied.stdout); } catch { /* reported below */ }
      check(lied.status === 0 && value?.ok === true && value.result.truncated === false,
        'the lying orca really exits 0 with a complete, well-formed inventory claiming the unowned tree is a card');
    } else {
      const broken = spawnSync('orca', ['worktree', 'list', '--json'], {encoding: 'utf8', windowsHide: true, env});
      check(broken.status !== 0, 'the broken orca really fails the registry invocation');
    }
    const r = run('registries', env);
    check(r.proof.ok === false, `registries REFUSES the unowned tree with ${label}`);
    check(r.proof.unresolved.some(u => u.reason === 'unowned_worktree_registration'), `registries names the unowned registration with ${label}`);
    check(r.proof.evidence.third_party === 'none', `registries names its own inventory as the only source with ${label}`);
    check(r.proof.evidence.runtime_bindings === 1 && r.proof.evidence.git_worktrees === 3, `registries really read Git and the node bindings with ${label}`);
    if (lying) {
      check(r.proof.evidence.orca_view.used === true && r.proof.evidence.orca_view.decision_input === false,
        'the lying viewer IS consulted (used:true) and is recorded as decision_input:false');
      check(r.proof.evidence.orca_view.worktrees.length === 2, 'the lie is recorded verbatim as advisory evidence');
    } else {
      check(r.proof.evidence.orca_view.used === false, `the viewer is simply unused (not an error) with ${label}`);
    }
    const owners = spawnSync(process.execPath, [path.join(source, 'scripts/wave-proof.mjs'), 'owners', configFile], {encoding: 'utf8', windowsHide: true, timeout: 180000, env: {...env, WA_WAVE_ID: 'liar', WA_WAVE_MAIN: main, WA_WAVE_ADMISSION: '1'}});
    const ownersProof = JSON.parse(owners.stdout.trim());
    check(ownersProof.ok === false && ownersProof.unresolved.some(u => u.reason === 'unowned_managed_worktree'), `owners REFUSES it too, by name, with ${label}`);
  }

  // THE SAME ASSERTIONS PASS ONCE THE TREE IS REALLY OWNED: not vacuous, still deciding.
  git(repo, 'worktree', 'remove', orphan);
  const clean = run('registries', conditions[2][1]);
  check(clean.proof.ok === true && clean.proof.complete === true && clean.proof.unresolved.length === 0,
    'with the unowned tree gone the same assertion PASSES, with the liar still on PATH');
  console.log(`liar attack ok (${checks} checks; absent, broken and LYING third parties all reach the same verdicts, the assertions still decide, and the lie is advisory evidence only)`);
  fs.rmSync(root, {recursive: true, force: true});
} catch (e) {
  console.error(`liar attack FAILED with fixtures retained at ${root}: ${e.message}`);
  process.exitCode = 1;
}
