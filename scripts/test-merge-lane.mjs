#!/usr/bin/env node
// The merge lane's spine, against fixtures where every answer is known in advance.
//
// What this pins, in the order the spine decides it: which tips are accepted, skipped or blocked;
// that a blocked input is NAMED and the exit is nonzero; that a candidate is built in a clone and
// never in the source repository; that a conflict with the target is caught before a clone exists and
// a conflict between two inputs in the clone; that the gate runs on the MERGED tree and its own
// verdict line is what makes a pass; that a gate which exits 0 without saying so is not a pass; that
// a CRLF candidate stops before the gate; and that `--partial` gates the accepted subset while still
// refusing to call a batch with a blocked input a success.
//
// The gate is the seam (--gate-command), so this file costs seconds and needs no build. A real gate
// on real branches is a merge-lane run, not this test.
//
// Usage:  node scripts/test-merge-lane.mjs      (about 20 s, no network, no build)
// NOTE: scripts/test.sh discovers tests explicitly rather than by convention, so a file no gate names runs
// nowhere - this one ran nowhere until `bcdda53` wired `node scripts/test-merge-lane.mjs` into the gate's
// repository-tooling block, beside `test-gate-lane.cjs` and `test-delivery-admission.mjs`.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const LANE = path.join(path.dirname(fileURLToPath(import.meta.url)), 'merge-lane.mjs');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-merge-lane-test-'));
let checks = 0, failed = 0;
const ok = (condition, label, detail) => {
  checks += 1;
  if (condition) console.log(`  ok   ${label}`);
  else { failed += 1; console.log(`  FAIL ${label}${detail ? ` - ${detail}` : ''}`); }
};
function git(cwd, ...args) {
  const result = spawnSync('git', ['-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid', ...args],
    {cwd, encoding: 'utf8', windowsHide: true});
  if (result.status !== 0) throw Error(`git ${args.join(' ')}: ${result.stderr || result.stdout}`);
  return result.stdout.trim();
}
const write = (file, text) => fs.writeFileSync(file, text);
function lane(repo, args, environment = {}) {
  const result = spawnSync(process.execPath, [LANE, '--repo', repo, ...args],
    {cwd: repo, encoding: 'utf8', windowsHide: true, env: {...process.env, ...environment}});
  let json = null;
  try { json = JSON.parse(result.stdout.trim()); } catch { /* a refusal is JSON too */ }
  return {status: result.status, json, stderr: result.stderr, stdout: result.stdout};
}

try {
  // ---- fixture: one repository, seven branches, no network and no remote -------------------------
  const repo = path.join(root, 'repo');
  fs.mkdirSync(repo);
  git(root, 'init', '-q', '--initial-branch=main', repo);
  // The machine-wide core.autocrlf here is `true` and this repository sets `false` locally; a fixture
  // that inherited the machine default would store LF whatever the test writes, and a CRLF case that
  // cannot store CRLF proves nothing. The fixture states the same setting the repository states.
  git(repo, 'config', 'core.autocrlf', 'false');
  write(path.join(repo, 'a.txt'), 'base\n');
  write(path.join(repo, 'd.txt'), 'd-base\n');
  write(path.join(repo, 'keep.txt'), 'keep\n');
  git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'fixture: base');
  const baseSha = git(repo, 'rev-parse', 'main');

  git(repo, 'switch', '-q', '-c', 'change/one', 'main');
  write(path.join(repo, 'a.txt'), 'base\none\n'); write(path.join(repo, 'one.txt'), 'one\n');
  git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'feat(one): a line and a file');
  const oneSha = git(repo, 'rev-parse', 'HEAD');

  git(repo, 'switch', '-q', '-c', 'change/two', 'main');
  write(path.join(repo, 'two.txt'), 'two\n');
  git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'feat(two): another file');
  const twoSha = git(repo, 'rev-parse', 'HEAD');

  // Conflicts with change/one, but not with the target: this is the in-clone conflict.
  git(repo, 'switch', '-q', '-c', 'change/clash', 'main');
  write(path.join(repo, 'a.txt'), 'clash\n');
  git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'feat(clash): the same line as change/one');
  const clashSha = git(repo, 'rev-parse', 'HEAD');

  git(repo, 'switch', '-q', '-c', 'change/crlf', 'main');
  write(path.join(repo, 'crlf.txt'), 'a\r\nb\r\n');
  git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'feat(crlf): a stored CRLF');
  const crlfSha = git(repo, 'rev-parse', 'HEAD');

  git(repo, 'switch', '-q', '-c', 'change/old', 'main'); // no commit: ancestry already contains it
  const oldSha = git(repo, 'rev-parse', 'HEAD');

  // Conflicts with the TARGET: fork, then let main change the same line. This is the case the proof
  // against `origin/main` sees before any clone exists.
  git(repo, 'switch', '-q', '-c', 'change/diverge', 'main');
  write(path.join(repo, 'd.txt'), 'diverge\n');
  git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'feat(diverge): the line main will change');
  const divergeSha = git(repo, 'rev-parse', 'HEAD');
  git(repo, 'switch', '-q', 'main');
  write(path.join(repo, 'd.txt'), 'main moved\n');
  git(repo, 'add', '-A'); git(repo, 'commit', '-q', '-m', 'main: the line change/diverge also changed');
  git(repo, 'switch', '-q', 'main');
  const targetSha = git(repo, 'rev-parse', 'main');

  // The audit is the skill's, not the spine's; a fixture stands in for it here (the real one needs a
  // remote and gh), and WA_MERGE_LANE_AUDIT is the documented seam for that substitution.
  const auditFixture = path.join(root, 'audit-fixture.mjs');
  write(auditFixture, `import {spawnSync} from 'node:child_process';
const git=(repo,...a)=>{const r=spawnSync('git',a,{cwd:repo,encoding:'utf8',windowsHide:true});return r.status===0?r.stdout.trim():null;};
export function audit(repo,{target='main'}={}) {
  const targetSha=git(repo,'rev-parse',target+'^{commit}');
  const candidates=[];
  for(const line of (git(repo,'for-each-ref','--format=%(refname)%00%(objectname)','refs/heads')||'').split('\\n').filter(Boolean)) {
    const [ref,sha]=line.split('\\0');
    const [behind,ahead]=(git(repo,'rev-list','--left-right','--count',targetSha+'...'+sha)||'0\\t0').split(/\\s+/).map(Number);
    const item={sha,ahead,behind,state:ahead===0?'contained':'pending',sources:[{kind:'branch',ref}]};
    if(item.state==='pending') {
      const p=spawnSync('git',['merge-tree','--write-tree',targetSha,sha],{cwd:repo,encoding:'utf8',windowsHide:true});
      item.merge=p.status===0?'clean':((p.stdout||'').includes('CONFLICT')?'conflict':'error');
    }
    candidates.push(item);
  }
  const pending=candidates.filter(c=>c.state==='pending');
  return {schema_version:1,repo,target,target_sha:targetSha,discovery_complete:true,integration_complete:!pending.length,
    pending_tips:pending.length,errors:[],candidates,worktrees:[],
    counts:{candidate_tips:candidates.length,pending_tips:pending.length,gate_run_count:0,worktrees:0,dirty_worktrees:0},
    timings_ms:{total_ms:0}};
}
`);
  const env = {WA_MERGE_LANE_AUDIT: auditFixture};
  const gatePass = 'echo "fixture gate"; echo "smoke ok (2 skipped)"';

  // ---- 0. the fixture itself stores what it says --------------------------------------------------
  console.log('0. the fixture');
  ok(git(repo, 'show', 'change/crlf:crlf.txt').includes('\r'), 'change/crlf stores a real CRLF blob');
  const divergeProof = spawnSync('git', ['merge-tree', '--write-tree', 'main', 'change/diverge'],
    {cwd: repo, encoding: 'utf8', windowsHide: true});
  ok(divergeProof.status === 1 && divergeProof.stdout.includes('CONFLICT'),
    'change/diverge conflicts with the target', `${divergeProof.status} ${divergeProof.stdout.split('\n')[1] || ''}`);

  // ---- 1. two clean tips, one gate, one candidate -------------------------------------------------
  console.log('1. two clean tips');
  const pass = lane(repo, ['--base', 'main', 'change/one', 'change/two', '--gate-command', gatePass,
    '--keep-clone', '--json', path.join(root, 'pass.json')], env);
  ok(pass.status === 0, 'exit 0', `exit ${pass.status}`);
  ok(pass.json?.verdict === 'pass', 'verdict pass', pass.json?.verdict);
  ok(pass.json?.inputs.every(input => input.state === 'accepted'), 'both tips accepted');
  ok(pass.json?.candidate.merges === 2, 'two merge commits in the candidate', String(pass.json?.candidate.merges));
  ok(pass.json?.candidate.tree !== git(repo, 'rev-parse', 'main^{tree}'), 'the candidate tree is not the base tree');
  ok(pass.json?.gate.ran === true && pass.json?.gate.exit === 0 && pass.json?.gate.skipped === 2,
    'the gate ran on the merged tree and its skip count was read', JSON.stringify(pass.json?.gate));
  ok(pass.json?.checks.crlf.state === 'clean', 'the merged tree is LF-only');
  ok(pass.json?.pushed === false && pass.json?.main_moved_by_this_run === false && pass.json?.base_ref_after === targetSha,
    'nothing was pushed and the target ref did not move',
    JSON.stringify({pushed: pass.json?.pushed, moved: pass.json?.main_moved_by_this_run, after: pass.json?.base_ref_after}));
  ok(pass.json?.push_precondition.can_push === true, 'the push precondition is reported for the merger');
  ok(pass.json?.clone?.core_autocrlf === 'false', 'the clone checks out bytes the way the source tree does',
    String(pass.json?.clone?.core_autocrlf));
  const clone = pass.json?.clone?.path;
  ok(Boolean(clone) && fs.existsSync(clone), 'the clone is retained when asked');
  ok(clone && git(clone, 'rev-parse', 'HEAD^{tree}') === pass.json.candidate.tree,
    'the reported candidate tree is the clone HEAD tree');
  ok(clone && git(clone, 'merge-base', '--is-ancestor', oneSha, 'HEAD') === '' && git(clone, 'rev-parse', 'HEAD') !== targetSha,
    'the merged tip is an ancestor of the candidate');
  ok(clone && git(clone, 'log', '-1', '--format=%s', 'HEAD').startsWith('merge(change/two):'),
    'the merge subject names the branch it merged', clone ? git(clone, 'log', '-1', '--format=%s') : 'no clone');
  ok(clone && git(clone, 'show', '-s', '--format=%P', 'HEAD').split(/\s+/).length === 2,
    'the candidate commit is a real merge (two parents)');
  ok(clone && git(clone, 'rev-parse', 'refs/remotes/origin/main') === targetSha,
    'origin/main inside the clone is pinned to the proved base');
  ok(clone && git(clone, 'config', '--get', 'core.hooksPath') === '.githooks',
    "the candidate tree's own commit-msg hook judged the merges");
  const gateLog = pass.json?.gate.log;
  ok(Boolean(gateLog) && fs.existsSync(gateLog) &&
    crypto.createHash('sha256').update(fs.readFileSync(gateLog)).digest('hex') === pass.json.gate.log_sha256,
    'the retained gate log matches its recorded hash');
  ok(fs.existsSync(path.join(root, 'pass.json')), 'the JSON object was written to --json');

  // ---- 2. a gate that fails ------------------------------------------------------------------------
  console.log('2. the merged-tree gate fails');
  const gateFail = lane(repo, ['--base', 'main', 'change/one', '--gate-command', 'echo "boom" >&2; exit 1'], env);
  ok(gateFail.status === 3, 'exit 3 (a gate failure is not a pass)', `exit ${gateFail.status}`);
  ok(gateFail.json?.verdict === 'gate_failed', 'verdict gate_failed', gateFail.json?.verdict);
  ok(gateFail.json?.gate.exit === 1 && gateFail.json?.gate.ran === true, 'the gate exit is reported as it was');
  ok(gateFail.json?.blocked.length === 0 && gateFail.json?.candidate.merges === 1,
    'the candidate is reported even though the gate failed');
  ok(Boolean(gateFail.json?.gate.log) && fs.readFileSync(gateFail.json.gate.log, 'utf8').includes('boom'),
    'the gate log is streamed to a file, so a holder that dies mid-gate still leaves evidence');

  // ---- 3. a gate that exits 0 without saying so -----------------------------------------------------
  console.log('3. a gate that exits 0 without a verdict');
  const silent = lane(repo, ['--base', 'main', 'change/one', '--gate-command', 'echo done'], env);
  ok(silent.status === 3, 'exit 3: an unproven pass is not a pass', `exit ${silent.status}`);
  ok(silent.json?.gate.verdict_found === false && silent.json?.gate.exit === 0,
    'exit 0 with no verdict line is recorded as exactly that');

  // ---- 3b. a gate that never finishes ------------------------------------------------------------------
  console.log('3b. a gate that is killed at its timeout');
  const timeout = lane(repo, ['--base', 'main', 'change/one', '--timeout-seconds', '1',
    '--gate-command', 'echo starting; sleep 30; echo "smoke ok"'], env);
  ok(timeout.status === 3 && timeout.json?.gate.exit === 'timeout_or_spawn_error',
    'a gate that did not exit is not a pass', JSON.stringify({exit: timeout.status, gate: timeout.json?.gate?.exit}));
  ok(Boolean(timeout.json?.gate.log) && fs.readFileSync(timeout.json.gate.log, 'utf8').includes('starting'),
    'and its partial output survived the kill');

  // ---- 3c. the lane's own environment does not ride into the gate --------------------------------------
  console.log('3c. the lane does not leak its own switches into the gate');
  const leak = lane(repo, ['--base', 'main', 'change/one', '--json', path.join(root, 'leak.json'),
    '--gate-command', 'echo "leak=${MSYS_NO_PATHCONV-unset}"; echo "smoke ok"'],
    {...env, MSYS_NO_PATHCONV: '1', WA_MERGE_LANE_TIPS: 'must-not-arrive'});
  ok(leak.status === 0 && leak.json?.gate.exit === 0, 'the run itself still passes', `exit ${leak.status}`);
  ok(Boolean(leak.json?.gate.log) && fs.readFileSync(leak.json.gate.log, 'utf8').includes('leak=unset'),
    'MSYS_NO_PATHCONV does not reach the gate: it inverts path conversion for the gate\'s own native calls',
    leak.json?.gate.log ? fs.readFileSync(leak.json.gate.log, 'utf8').split('\n')[0] : 'no log');
  ok((leak.json?.gate.environment_dropped || []).includes('MSYS_NO_PATHCONV') &&
    (leak.json?.gate.environment_dropped || []).includes('WA_MERGE_LANE_TIPS'),
    'and what was dropped is recorded', JSON.stringify(leak.json?.gate.environment_dropped));

  // ---- 4. a conflict with the target, caught before a clone exists ----------------------------------
  console.log('4. a tip that does not merge with the target');
  const diverge = lane(repo, ['--base', 'main', 'change/one', 'change/diverge'], env);
  ok(diverge.status === 2, 'exit 2 (a blocked input is not a success)', `exit ${diverge.status}`);
  ok(diverge.json?.verdict === 'blocked', 'verdict blocked', diverge.json?.verdict);
  ok(diverge.json?.blocked.length === 1 && diverge.json.blocked[0].name === 'change/diverge',
    'the blocked input is named', JSON.stringify(diverge.json?.blocked));
  ok((diverge.json?.blocked[0].conflicts || []).some(entry => entry.includes('d.txt')),
    'the conflicted path is reported', JSON.stringify(diverge.json?.blocked[0]?.conflicts));
  ok(diverge.json?.inputs.find(input => input.name === 'change/diverge')?.merge.state === 'conflict',
    'the state comes from the proof against the target');
  ok(diverge.json?.clone === null && diverge.json?.candidate.stopped_before_merge === true,
    'no clone was made for a batch that cannot contain its input');
  ok(diverge.json?.inputs.find(input => input.name === 'change/one')?.merged === false,
    'an accepted tip that was not merged says so');
  ok(diverge.json?.gate.ran === false && diverge.json?.checks.crlf.state === 'not_run',
    'no gate was spent and no merged tree was claimed');

  // ---- 5. a conflict between two inputs, inside the clone -------------------------------------------
  console.log('5. a tip that does not merge with another input');
  const clash = lane(repo, ['--base', 'main', 'change/one', 'change/clash'], env);
  ok(clash.status === 2 && clash.json?.verdict === 'blocked', 'exit 2, blocked',
    JSON.stringify({exit: clash.status, verdict: clash.json?.verdict}));
  ok(clash.json?.blocked.length === 1 && clash.json.blocked[0].name === 'change/clash',
    'only the tip that lost the merge is blocked', JSON.stringify(clash.json?.blocked?.map(entry => entry.name)));
  ok((clash.json?.blocked[0].conflicts || []).length === 1 && clash.json.blocked[0].conflicts[0] === 'a.txt',
    'the conflicted path is named from the merge itself', JSON.stringify(clash.json?.blocked[0]?.conflicts));
  ok(clash.json?.inputs.find(input => input.name === 'change/one')?.merged === true,
    'the input merged before it is still counted as merged');
  ok(clash.json?.candidate.merges === 1 && clash.json?.gate.ran === false,
    'the candidate stops at the conflict and is not gated');

  // ---- 6. a tip that is already integrated -----------------------------------------------------------
  console.log('6. a tip ancestry already contains');
  const contained = lane(repo, ['--base', 'main', 'change/old'], env);
  ok(contained.status === 0 && contained.json?.verdict === 'nothing_to_merge',
    'a contained tip is not an error and nothing is gated', JSON.stringify({exit: contained.status, verdict: contained.json?.verdict}));
  ok(contained.json?.skipped.length === 1 && contained.json.skipped[0].name === 'change/old',
    'it is counted as a skip, with its reason');
  ok(contained.json?.gate.ran === false, 'no gate was spent on a candidate with no new merge');

  // ---- 7. a candidate that would store CRLF -----------------------------------------------------------
  console.log('7. a candidate that would store CRLF');
  const crlf = lane(repo, ['--base', 'main', 'change/crlf', '--gate-command', gatePass], env);
  ok(crlf.status === 2 && crlf.json?.verdict === 'blocked', 'CRLF in the merged tree blocks before the gate',
    JSON.stringify({exit: crlf.status, verdict: crlf.json?.verdict}));
  ok(crlf.json?.checks.crlf.state === 'offenders' && crlf.json.checks.crlf.files.includes('crlf.txt'),
    'the offending file is named', JSON.stringify(crlf.json?.checks.crlf));
  ok(crlf.json?.gate.ran === false, 'the gate is not spent on a tree that violates an invariant');

  // ---- 8. discovery is the input list when --all-pending is used --------------------------------------
  console.log('8. --all-pending');
  const all = lane(repo, ['--base', 'main', '--all-pending', '--gate-command', gatePass], env);
  ok(all.status === 2 && all.json?.verdict === 'blocked', 'one unmergeable tip stops the batch', `exit ${all.status}`);
  ok(all.json?.inputs.length === 5, 'every pending tip discovery named is an input',
    JSON.stringify(all.json?.inputs?.map(input => input.name)));
  ok(new Set((all.json?.inputs || []).map(input => input.sha)).size === 5 &&
    (all.json?.inputs || []).every(input => [clashSha, crlfSha, divergeSha, oneSha, twoSha].includes(input.sha)),
    'each input is one of the five pending tips, by exact SHA');
  ok(all.json?.blocked.length === 1 && all.json.blocked[0].name === 'refs/heads/change/diverge',
    'exactly the tip that conflicts with the target is blocked',
    JSON.stringify(all.json?.blocked?.map(entry => entry.name)));
  ok(all.json?.clone === null, 'the default is to stop rather than gate a candidate missing an input');

  // ---- 9. --partial: gate the accepted subset, still refuse to call it a success ----------------------
  console.log('9. --partial');
  const partial = lane(repo, ['--base', 'main', 'change/one', 'change/clash', 'change/two', '--partial',
    '--gate-command', gatePass], env);
  ok(partial.status === 2 && partial.json?.verdict === 'blocked',
    'a gated subset with a blocked input is still not a success',
    JSON.stringify({exit: partial.status, verdict: partial.json?.verdict}));
  ok(partial.json?.gate.ran === true && partial.json?.gate.exit === 0 && partial.json?.gate.skipped === 2,
    'the accepted subset was gated on the merged tree', JSON.stringify(partial.json?.gate));
  ok(partial.json?.candidate.merges === 2, 'the two independent tips are in the candidate',
    String(partial.json?.candidate.merges));
  ok(partial.json?.push_precondition.can_push === false, 'and the push precondition refuses it');

  // ---- 10. a repository the lane cannot identify -------------------------------------------------------
  console.log('10. no repository named');
  const noRepo = spawnSync(process.execPath, [LANE, 'change/one'], {encoding: 'utf8', windowsHide: true,
    env: {...process.env, WA_MERGE_LANE_AUDIT: auditFixture, WA_MERGE_LANE_REPO: ''}});
  ok(noRepo.status === 4, 'exit 4: the lane refuses to guess which repository it is landing into', `exit ${noRepo.status}`);
  ok(String(noRepo.stdout).includes('refuses to guess'), 'and says so in its JSON', noRepo.stdout.trim().slice(0, 160));

  // ---- 11. the source repository is intact --------------------------------------------------------------
  console.log('11. the source repository is intact');
  ok(git(repo, 'rev-parse', 'main') === targetSha, 'main still points where the fixture left it');
  ok(git(repo, 'rev-parse', 'change/one') === oneSha && git(repo, 'rev-parse', 'change/two') === twoSha &&
    git(repo, 'rev-parse', 'change/clash') === clashSha, 'every input branch kept its exact tip');
  ok(git(repo, 'rev-parse', 'change/crlf') === crlfSha && git(repo, 'rev-parse', 'change/old') === oldSha &&
    git(repo, 'rev-parse', 'change/diverge') === divergeSha, 'and so did the CRLF, contained and diverged tips');
  ok(git(repo, 'rev-parse', 'main^{commit}') === targetSha && baseSha !== targetSha,
    'the fixture target really moved after the fork');
  ok(git(repo, 'status', '--porcelain') === '', 'the source worktree is clean');
  ok(git(repo, 'for-each-ref', '--format=%(refname)', 'refs/heads').split('\n').length === 7,
    'no branch was created in the source repository');
  ok(git(repo, 'stash', 'list') === '', 'nothing was stashed');
} catch (error) {
  failed += 1;
  console.log(`  FAIL harness - ${error.message}`);
} finally {
  if (!process.env.WA_MERGE_LANE_TEST_KEEP) fs.rmSync(root, {recursive: true, force: true});
  else console.log(`fixture retained: ${root}`);
  console.log(failed ? `merge-lane spine: ${checks - failed}/${checks} ok, ${failed} FAILED` : `merge-lane spine ok (${checks} checks)`);
  process.exitCode = failed ? 1 : 0;
}
