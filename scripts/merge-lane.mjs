#!/usr/bin/env node
// The merge lane's deterministic spine: one candidate tree, one gate, one JSON verdict.
//
// WHAT THIS PROGRAM DECIDES, AND WHAT IT DOES NOT.
// It is the decidable part of landing a batch: fetch, state every input, prove mergeability
// against the current integration target, merge the accepted tips in order in a DISPOSABLE
// CLONE, run the gate on the merged tree, and print one JSON object. It never pushes, never
// moves `main` in the canonical checkout, never deletes a branch, and never resolves a
// conflict: a tip that does not merge cleanly is a NAMED BLOCKED INPUT and a nonzero exit,
// never a silent drop and never a success.
//
// The judgement stays with the reserved merger (docs/FACTORY.md, "The merge lane"): an
// ambiguous or unexpected conflict, a delivery whose review falsified its claim, and a
// failed merged-tree gate are decisions, not plumbing. This script reports them; it does not
// take them.
//
// Discovery is not re-implemented: `skills/git-orchestrator/scripts/audit.mjs` (the
// authoritative copy, from this tree) fetches, lists tips, runs `git merge-tree --write-tree`
// per tip and inspects worktrees. This file adds only what the audit does not do: build the
// candidate, gate the merged tree, and say so in one object.
//
// Usage:
//   node scripts/merge-lane.mjs --repo <path> [tip ...] [options]
//
//   --repo <path>          target repository (or WA_MERGE_LANE_REPO)
//   --base <ref>           integration target (default: origin/main)
//   --all-pending          take every pending tip discovery names (sorted by ref name)
//   --jobs <n|default>     WA_GATE_JOBS for the gate (default 2: the measured setting)
//   --gate-command <line>  gate to run in the clone (default: bash scripts/test.sh).
//                          A test seam: it is recorded verbatim in the output.
//   --timeout-seconds <n>  gate timeout (default 3600)
//   --clone <path>         use this directory as the disposable clone
//   --keep-clone           keep the clone even when the lane passes
//   --no-hooks             do not arm this tree's .githooks in the clone
//   --partial              on a conflict, continue with the independent inputs and gate
//                          the accepted subset (exit stays nonzero)
//   --json <path>          also write the JSON object to this path
//
// Exit codes: 0 pass; 2 a named blocked input; 3 the merged-tree gate failed;
//             4 usage or repository error; 5 discovery could not establish the base/inputs;
//             6 the gate lane granted no slot, so the merged tree was not gated (terminal: the
//               lane's record names the holder, its elapsed time and the depth it gave up at).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath, pathToFileURL} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const AUDIT = process.env.WA_MERGE_LANE_AUDIT || path.join(here, '..', 'skills', 'git-orchestrator', 'scripts', 'audit.mjs');
// A named identity, because an automatic merge has to be attributable. It is not the
// operator's identity and does not claim to be: the candidate is not pushed by this script.
const IDENTITY = {name: 'merge lane', email: 'merge-lane@wasm-agent.invalid'};

const nowMs = () => Number(process.hrtime.bigint()) / 1e6;
const elapsedMs = start => Number((nowMs() - start).toFixed(3));
const note = text => process.stderr.write(`${text}\n`);
const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

function run(program, args, options = {}) {
  const result = spawnSync(program, args, {encoding: 'utf8', windowsHide: true, maxBuffer: 64 * 1024 * 1024, ...options});
  return {status: result.status, stdout: result.stdout || '', stderr: result.error?.message || result.stderr || ''};
}
function git(cwd, ...args) {
  return run('git', ['-c', `user.name=${IDENTITY.name}`, '-c', `user.email=${IDENTITY.email}`, ...args], {cwd});
}
function requireGit(cwd, args, label) {
  const result = git(cwd, ...args);
  if (result.status !== 0) throw Error(`${label}: ${(result.stderr || result.stdout).trim()}`);
  return result.stdout.trim();
}
function resolveRef(cwd, ref) {
  const result = git(cwd, 'rev-parse', '--verify', `${ref}^{commit}`);
  return result.status === 0 ? result.stdout.trim() : null;
}

export function parseArgs(argv) {
  const options = {tips: [], base: 'origin/main', allPending: false, jobs: '2', gateCommand: 'bash scripts/test.sh',
    timeoutSeconds: 3600, clone: null, keepClone: false, hooks: true, partial: false, json: null, repo: null};
  const needs = new Set(['--repo', '--base', '--jobs', '--gate-command', '--timeout-seconds', '--clone', '--json']);
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (needs.has(arg)) {
      const value = argv[index + 1];
      if (value === undefined) throw Error(`${arg} needs a value`);
      index += 1;
      if (arg === '--repo') options.repo = value;
      else if (arg === '--base') options.base = value;
      else if (arg === '--jobs') options.jobs = value;
      else if (arg === '--gate-command') options.gateCommand = value;
      else if (arg === '--timeout-seconds') options.timeoutSeconds = Number(value);
      else if (arg === '--clone') options.clone = value;
      else options.json = value;
    } else if (arg === '--all-pending') options.allPending = true;
    else if (arg === '--keep-clone') options.keepClone = true;
    else if (arg === '--no-hooks') options.hooks = false;
    else if (arg === '--partial') options.partial = true;
    else if (arg.startsWith('-')) throw Error(`unknown option ${arg}`);
    else options.tips.push(arg);
  }
  if (!options.repo) options.repo = process.env.WA_MERGE_LANE_REPO || '';
  if (!options.repo) throw Error('--repo <path> is required (or WA_MERGE_LANE_REPO); this lane refuses to guess which repository it is landing into');
  if (options.base.startsWith('-')) throw Error('invalid --base');
  if (!(options.tips.length || options.allPending)) options.allPending = true;
  if (options.allPending && options.tips.length) throw Error('name tips or use --all-pending, not both');
  return options;
}

// The gate prints its own verdict as the last line; a gate that exits 0 without it did not pass.
export function parseGateVerdict(log) {
  const match = /(?:^|\n)smoke ok(?: \((\d+) skipped\))?\r?\n?$/.exec(log);
  return {found: Boolean(match), line: match ? match[0].trim() : null, skipped: match ? Number(match[1] || 0) : null};
}

function mergeTree(cwd, base, tip) {
  const result = git(cwd, 'merge-tree', '--write-tree', base, tip);
  const text = `${result.stdout}\n${result.stderr}`.trim();
  const conflicts = [...text.matchAll(/^CONFLICT \(([^)]+)\): (.*)$/gm)].map(match => `${match[1]}: ${match[2]}`);
  if (result.status === 0) return {state: 'clean', tree: result.stdout.trim().split('\n')[0], conflicts, detail: null};
  if (result.status === 1 && text.includes('CONFLICT')) return {state: 'conflict', tree: null, conflicts, detail: text};
  return {state: 'error', tree: null, conflicts, detail: text};
}

async function auditRepo(repo, base) {
  const module = await import(pathToFileURL(AUDIT).href);
  return module.audit(repo, {target: base});
}

function cloneRepo(repo, base, options, laneBranch) {
  const started = nowMs();
  const dir = options.clone ? path.resolve(options.clone) : fs.mkdtempSync(path.join(os.tmpdir(), 'wa-merge-lane-'));
  if (options.clone && fs.existsSync(dir) && fs.readdirSync(dir).length) throw Error(`--clone ${dir} is not empty`);
  const cloned = run('git', ['clone', '--quiet', '--local', repo, dir]);
  if (cloned.status !== 0) throw Error(`clone failed: ${(cloned.stderr || cloned.stdout).trim()}`);
  const cloneMs = elapsedMs(started);
  // A clone does not inherit the source's local config, and the machine-wide `core.autocrlf` is
  // `true` here (the repository sets `false` locally). Pin it to the source's effective value BEFORE
  // anything is materialised, then re-materialise: the clone's first checkout already wrote files
  // under the inherited value, and a worktree whose bytes do not match the pinned handling reads as
  // dirty - which is what a merge refuses. The gate reads files, not only blobs, so "the merged tree"
  // has to mean one thing.
  const inherited = git(repo, 'config', '--get', 'core.autocrlf');
  const autocrlf = inherited.status === 0 && inherited.stdout.trim() ? inherited.stdout.trim() : 'false';
  requireGit(dir, ['config', 'core.autocrlf', autocrlf], 'match line-ending handling');
  requireGit(dir, ['reset', '--hard'], 're-materialise the worktree');
  const clean = git(dir, 'status', '--porcelain');
  if (clean.status !== 0 || clean.stdout.trim()) {
    throw Error(`the clone is not clean after pinning core.autocrlf=${autocrlf}: ${clean.stdout.trim().slice(0, 200)}`);
  }
  // The lane's own branch, never `main`: merges happen on a candidate named for the lane.
  requireGit(dir, ['switch', '--create', laneBranch, base], 'candidate branch');
  // The clone's notion of main is the exact integration target this run proved against, so a
  // later re-read cannot silently mean a different commit.
  requireGit(dir, ['update-ref', 'refs/remotes/origin/main', base], 'pin origin/main');
  // A merge does not run `pre-commit`, so the one hook that must still judge the candidate is
  // `commit-msg` (it is what refuses a merge whose subject names nothing). Arm this tree's copy
  // rather than whatever the clone inherited: `core.hooksPath` is relative, so a clone has none.
  if (options.hooks) requireGit(dir, ['config', 'core.hooksPath', '.githooks'], 'arm hooks');
  else requireGit(dir, ['config', 'core.hooksPath', ''], 'disarm hooks');
  return {dir, clone_ms: cloneMs, core_autocrlf: autocrlf};
}

function crlfCheck(cwd) {
  const result = git(cwd, 'grep', '--cached', '-I', '-l', '\r');
  if (result.status === 0) return {state: 'offenders', files: result.stdout.trim().split('\n').filter(Boolean)};
  if (result.status === 1) return {state: 'clean', files: []};
  return {state: 'unreadable', files: [], detail: (result.stderr || result.stdout).trim()};
}

// ---- THE GATE LANE: one CPU-heavy gate at a time per node --------------------------------------
// The gate on the merged tree is the serial resource (~15 min at WA_GATE_JOBS=2, docs/FACTORY.md),
// and until now nothing coordinated two of them: the same four-tree candidate passed alone (`exit 0`,
// `smoke ok (2 skipped)`) and failed twice while four children competed. The lane is
// `scripts/gate-lane.mjs`; this is its second consumer.
//
// It decides *when*, never *what*: the command stays `options.gateCommand`, the verdict line and the
// skip count are still read here out of this run's own log, and this process stays the supervisor of
// the gate process in its own clone. `acquire` grants a slot, prints the row that names it and then
// blocks while holding it; `release --id` ends the claim. `run` is not used for exactly that reason:
// it spawns the command itself, which would make the lane a second supervisor.
const LANE_SCRIPT = path.join(here, 'gate-lane.mjs');
const LANE_OFF = String(process.env.WA_GATE_LANE ?? '').trim().toLowerCase() === 'off';
// The gate runs `scripts/test.sh`, which runs `scripts/test-parallel-finish.mjs`, which runs
// `finish.mjs gate` on fixture trees. Those nested gates are inside CPU this process has already
// paid for, so they inherit this admission decision instead of asking for a slot of their own - a
// second request there would wait behind the slot its own parent holds, and the parent would wait
// for it.
//
// The marker is spelled `GATE_LANE_HELD` and not `WA_GATE_LANE_HELD` because the gate fences its own
// environment before it runs anything: scripts/test.sh unsets every `WA_*` and `WASM_AGENT_*`
// variable (its `compgen -e` loop, letting only WASM_AGENT_SKIP_UI_TESTS, WASM_AGENT_IN_TURN and
// WA_GATE_JOBS through) so no caller's runtime state leaks into the gate - which is also why this
// lane drops its own switches from the gate's environment below, on the same principle.
const LANE_HELD = process.env.GATE_LANE_HELD || '';
const laneNotice = text => note(text);

// Ask the lane for a slot. Never throws: a lane that cannot be consulted is reported, not fatal.
async function laneAcquire({cwd, label}) {
  const record = {lane: 'gate', mode: 'slot', request: null, label: label || null, dir: null, waited_ms: 0, reason: null};
  if (LANE_OFF) {
    record.mode = 'off';
    record.reason = 'WA_GATE_LANE=off: the gate runs with no slot, by name';
    laneNotice(`gate lane: ${record.reason}`);
    return {obtained: false, refused: false, marker: 'off', record};
  }
  if (LANE_HELD) {
    record.mode = 'inherited';
    record.reason = `inherited ${LANE_HELD}: this gate runs inside a gate that already has its admission`;
    laneNotice(`gate lane: ${record.reason}; no second slot is requested`);
    return {obtained: false, refused: false, marker: LANE_HELD, record};
  }
  const started = Date.now();
  let child;
  try {
    child = spawn(process.execPath, [LANE_SCRIPT, 'acquire', '--cwd', path.resolve(cwd),
      ...(label ? ['--label', label] : []), '--holder-pid', String(process.pid)],
    {cwd: path.resolve(cwd), windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'], env: process.env});
  } catch (error) {
    record.mode = 'unavailable';
    record.reason = `could not start ${LANE_SCRIPT}: ${error.message}`;
    laneNotice(`gate lane: ${record.reason}; the merged tree is gated WITHOUT a slot - gates are not serialized for this run.`);
    return {obtained: false, refused: false, marker: 'unavailable', record};
  }
  const outcome = await new Promise(resolve => {
    let out = '', err = '', settled = false;
    const settle = value => { if (!settled) { settled = true; resolve(value); } };
    child.stdout.on('data', chunk => {
      out += chunk;
      const start = out.indexOf('{');
      if (start < 0) return;
      try { settle({grant: JSON.parse(out.slice(start))}); } catch { /* the receipt is still arriving */ }
    });
    // The lane narrates its wait while it holds this process: those lines are this gate's queue
    // position and the holder's name, so they are passed through, not swallowed.
    child.stderr.on('data', chunk => { err += chunk; process.stderr.write(chunk); });
    child.on('error', error => settle({error}));
    child.on('close', code => settle({code, out, err}));
  });
  record.waited_ms = Date.now() - started;
  if (outcome.grant) {
    record.request = outcome.grant.id;
    record.dir = outcome.grant.dir;
    record.label = outcome.grant.label || label || null;
    record.reason = `slot #${outcome.grant.id} granted`
      + (record.waited_ms >= 1000 ? ` after waiting ${(record.waited_ms / 1000).toFixed(1)}s` : ' at once');
    laneNotice(`gate lane: ${record.reason}; this process gates the merged tree and releases the slot when it ends.`);
    return {obtained: true, refused: false, marker: `slot:${outcome.grant.id}`, child, record};
  }
  const words = String(outcome.error?.message || outcome.err || '').trim().split('\n').filter(Boolean).pop()
    || 'no reason given';
  if (!outcome.error && outcome.code === 75) {
    // The lane was reached and made a decision, and it is terminal by design: it waited its own
    // budget (WA_GATE_LANE_WAIT_SECONDS, 2 h by default) and its record names the holder, how long
    // that holder has held the slot and the depth it gave up at. The candidate is therefore NOT
    // gated and this run says so instead of putting a second CPU-heavy gate on a node whose holder
    // has been busy for hours - the condition under which these merged-tree gates failed.
    record.mode = 'refused';
    record.reason = words;
    laneNotice(`gate lane: no slot was granted and this is terminal, not a retry: ${words}`);
    return {obtained: false, refused: true, marker: null, record};
  }
  // Not a decision: the lane could not be consulted at all (no script, an unreadable store, a
  // version skew that rejected the call) or the acquirer died before it settled. The gate is what
  // proves the merge, so it runs and says so, loudly. Refusing here would turn one unreadable store
  // into a factory that can land nothing, which is worse than the contention this lane removes;
  // `WA_GATE_LANE=off` produces this same outcome deliberately, by name.
  record.mode = 'unavailable';
  record.reason = words;
  laneNotice(`gate lane: could not be consulted (${words}); the merged tree is gated WITHOUT a slot -`);
  laneNotice('gate lane: gates are not serialized for this run. Set WA_GATE_LANE=off to say so on purpose.');
  return {obtained: false, refused: false, marker: 'unavailable', record};
}

// Give the slot back and record what the gate did with it. Best effort: the row is the lane's, the
// verdict is this lane's, and a release that fails is reported rather than allowed to fail the merge.
async function laneRelease(slot, exit, detail) {
  if (!slot.obtained) return;
  const request = slot.record?.request ?? null;
  if (!request) {
    laneNotice('gate lane: a slot was granted without a request id; nothing can be released, so the'
      + ' lane will settle that row by proof of death, not by a timeout.');
    return;
  }
  const args = [LANE_SCRIPT, 'release', '--id', String(request), '--detail', detail];
  if (Number.isInteger(exit)) args.push('--exit', String(exit));
  const released = spawnSync(process.execPath, args, {encoding: 'utf8', windowsHide: true, timeout: 60000, env: process.env});
  if (released.status !== 0) {
    laneNotice(`gate lane: releasing slot #${request} reported:`
      + ` ${(released.stderr || released.stdout || '').trim() || `exit ${released.status}`}`
      + ' - the lane row is still the record of it.');
  }
  // The acquirer holds the claim in its own process and stops once its row ends; if it cannot (a
  // lane that could not settle the row), it is stopped here. A lease dies with the process that
  // holds it, so the slot is freed either way and is never left looking held.
  const child = slot.child;
  if (!child || child.exitCode !== null || child.signalCode) return;
  await new Promise(resolve => {
    const timer = setTimeout(() => {
      laneNotice(`gate lane: the acquirer for slot #${request} did not stop after its row ended;`
        + ' terminating it - its lease dies with it, so the slot is freed.');
      try { child.kill('SIGKILL'); } catch {}
      resolve();
    }, 5000);
    child.once('close', () => { clearTimeout(timer); resolve(); });
  });
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const repo = path.resolve(options.repo);
  const started = nowMs();
  const timings = {};
  const blocked = [];
  const skipped = [];

  const top = run('git', ['-C', repo, 'rev-parse', '--show-toplevel']);
  if (top.status !== 0) throw Object.assign(Error(`not a git repository: ${repo}`), {exit: 4});
  const gitDir = top.stdout.trim();

  // 1. Discovery: the skill's audit, not a second one. It fetches, lists every tip, proves each
  // pending tip's mergeability against the target, and inspects worktrees.
  const discoveryStarted = nowMs();
  let discovery;
  try {
    discovery = await auditRepo(gitDir, options.base);
  } catch (error) {
    throw Object.assign(Error(`discovery failed (audit): ${error.message}`), {exit: 5});
  }
  timings.discovery_ms = elapsedMs(discoveryStarted);
  const baseSha = discovery.target_sha;
  if (!baseSha) throw Object.assign(Error('discovery did not resolve the integration target'), {exit: 5});
  const stateOfBase = resolveRef(gitDir, options.base);
  if (stateOfBase !== baseSha) throw Object.assign(Error(`the integration target moved during discovery: ${stateOfBase} != ${baseSha}`), {exit: 5});

  // A discovery error is fatal when it touches the base or a named input. Anything else (a
  // sibling's branch moving while this run reads the world) is reported and does not block a
  // candidate whose own inputs are proven below - the merge lane does not claim completion.
  const namedInputs = options.allPending
    ? discovery.candidates.filter(item => item.state === 'pending')
        .sort((left, right) => (left.sources[0]?.ref || '').localeCompare(right.sources[0]?.ref || ''))
        .map(item => ({name: item.sources[0]?.ref, sha: item.sha}))
    : options.tips.map(name => ({name, sha: resolveRef(gitDir, name)}));
  const warnings = (discovery.errors || []).slice();
  if (options.allPending && discovery.errors?.length) {
    throw Object.assign(Error(`discovery is the input list here, so its errors are fatal: ${discovery.errors.join('; ')}`), {exit: 5});
  }
  if (options.allPending && !namedInputs.length) {
    throw Object.assign(Error('no pending tip to merge; nothing to gate'), {exit: 4});
  }

  // 2. Per input: state, and mergeability proven against the current target.
  const inputs = [];
  for (const input of namedInputs) {
    const record = {name: input.name, sha: input.sha, state: 'unknown', reason: null, ahead: null, behind: null,
      subject: null, merge: null, merged: false, identity_checked_in_clone: false};
    if (!input.sha || !/^[a-f0-9]{40,64}$/.test(input.sha)) {
      record.state = 'blocked'; record.reason = `cannot resolve ${input.name} to a commit in ${gitDir}`;
      blocked.push(record); inputs.push(record); continue;
    }
    const counts = git(gitDir, 'rev-list', '--left-right', '--count', `${baseSha}...${input.sha}`);
    if (counts.status !== 0) {
      record.state = 'blocked'; record.reason = `cannot compare with the target: ${counts.stderr.trim()}`;
      blocked.push(record); inputs.push(record); continue;
    }
    [record.behind, record.ahead] = counts.stdout.trim().split(/\s+/).map(Number);
    record.subject = requireGit(gitDir, ['log', '-1', '--format=%s', `${input.sha}^{commit}`], 'subject');
    if (record.ahead === 0) {
      // Already integrated. Not an error, not a merge: counted as a skip so the arithmetic is visible.
      record.state = 'contained'; record.reason = 'ancestry proves this tip is already in the target';
      skipped.push(record); inputs.push(record); continue;
    }
    const proofStarted = nowMs();
    record.merge = mergeTree(gitDir, baseSha, input.sha);
    record.proof_ms = elapsedMs(proofStarted);
    if (record.merge.state === 'clean') record.state = 'accepted';
    else {
      record.state = 'blocked';
      record.reason = record.merge.state === 'conflict'
        ? 'does not merge cleanly against the current target'
        : 'merge-tree could not prove mergeability (a real discovery error)';
      blocked.push(record);
      if (record.merge.state === 'error') warnings.push(`merge proof failed for ${input.sha}: ${record.merge.detail}`);
    }
    inputs.push(record);
  }
  // A tip the audit could not prove is blocked even when it was named, because an unproven input
  // is not an accepted one.
  const accepted = inputs.filter(record => record.state === 'accepted');

  // 3. The candidate, in a disposable clone. Merges happen where nothing canonical can be touched.
  const laneBranch = `lane/merge-${new Date().toISOString().replace(/[:.]/g, '-')}`;
  const cloneStarted = nowMs();
  let clone = null;
  const steps = [];
  const conflictStops = blocked.length && !options.partial;
  if (accepted.length && !conflictStops) {
    clone = cloneRepo(gitDir, baseSha, options, laneBranch);
    for (const record of accepted) {
      const stepStarted = nowMs();
      const step = {name: record.name, sha: record.sha, state: 'merged', ms: null, conflicts: [], detail: null};
      // Identity proof: the object merged here is the exact commit that was proven, not a ref that
      // may have moved since. A tip that moved is blocked, never merged on trust.
      let present = git(clone.dir, 'cat-file', '-e', `${record.sha}^{commit}`).status === 0;
      if (!present && record.name) {
        git(clone.dir, 'fetch', '--no-tags', gitDir, `+${record.name}:refs/merge-lane/${record.name.replace(/[^\w./-]/g, '_')}`);
        present = git(clone.dir, 'cat-file', '-e', `${record.sha}^{commit}`).status === 0;
      }
      if (!present) {
        step.state = 'blocked'; step.detail = `the clone does not have ${record.sha}; the tip moved or was never fetched`;
        record.state = 'blocked'; record.reason = step.detail; blocked.push(record);
      } else {
        const before = requireGit(clone.dir, ['rev-parse', 'HEAD'], 'candidate HEAD');
        const merge = git(clone.dir, 'merge', '--no-ff', '-m', `merge(${record.name}): ${record.sha.slice(0, 12)} ${record.subject}`, record.sha);
        if (merge.status === 0) {
          const head = requireGit(clone.dir, ['rev-parse', 'HEAD'], 'candidate HEAD');
          step.state = head === before ? 'already_contained' : 'merged';
          step.head = head;
          record.identity_checked_in_clone = true;
          record.merge_commit = head;
          record.merged = step.state === 'merged';
          if (step.state === 'already_contained') { record.state = 'contained'; skipped.push(record); }
        } else {
          const conflicts = git(clone.dir, 'diff', '--name-only', '--diff-filter=U').stdout.trim().split('\n').filter(Boolean);
          git(clone.dir, 'merge', '--abort');
          step.state = 'conflict'; step.conflicts = conflicts;
          step.detail = (merge.stderr || merge.stdout).trim().split('\n').slice(0, 12).join('\n');
          record.state = 'blocked'; record.reason = 'git refused the merge in the candidate (conflict or hook refusal)';
          record.conflicts = conflicts;
          blocked.push(record);
        }
      }
      step.ms = elapsedMs(stepStarted);
      steps.push(step);
      if (step.state === 'conflict' && !options.partial) break;
    }
  }
  const candidateHead = clone ? resolveRef(clone.dir, 'HEAD') : baseSha;
  const candidateTree = clone ? requireGit(clone.dir, ['rev-parse', 'HEAD^{tree}'], 'candidate tree') : requireGit(gitDir, ['rev-parse', `${baseSha}^{tree}`], 'base tree');
  const candidateMerges = steps.filter(step => step.state === 'merged').length;
  timings.merge_ms = clone ? elapsedMs(cloneStarted) : 0;

  // The candidate tree must still be LF-only. A merge does not run `pre-commit`, which is the hook
  // that enforces this for every other commit, so the one invariant it protects would be unpoliced on
  // exactly the path this lane exists for. Same check the gate runs under "Line endings are an
  // invariant, not a preference" (scripts/test.sh), and by the same command it runs there:
  // `git grep --cached -I -l <CR>`, earlier. It is named by its words and its command rather than by a
  // line number: the line this comment used to carry (1454) was already wrong when it was written
  // (that check is at 1478 on the same tree) and every edit to the gate moves it again - a pointer
  // whose truth depends on an unrelated file's length cannot be kept true by reading it.
  const crlf = clone ? crlfCheck(clone.dir) : {state: 'not_run', files: []};
  if (clone && crlf.state === 'offenders') {
    blocked.push({name: 'merged candidate tree', sha: candidateTree, files: crlf.files,
      reason: 'the merged tree stores CRLF, which the pre-commit hook refuses and a merge does not run'});
  }

  // 4. The gate, on the MERGED tree. Invariant 2: a branch's receipt never covers the merge.
  let gate = {command: options.gateCommand, ran: false, refused: false, exit: null, ms: null, log: null, log_sha256: null,
    skipped: null, verdict_line: null, verdict_found: false, lane: null};
  if (clone && crlf.state !== 'offenders' && (!blocked.length || options.partial)) {
    // Inside `.git`, not the worktree: the gate asks for a clean tree (scripts/test-deploy-downgrade.sh
    // refuses on dirt), so the lane's own log must not be the dirt it reports.
    const logPath = path.join(clone.dir, '.git', 'wa-merge-lane-gate.log');
    const environment = {...process.env};
    const dropped = [];
    // The gate is the repository's, and it must run in the environment it was written for. This lane's
    // own switches must not ride into it: `MSYS_NO_PATHCONV=1` - which a caller may set to keep its own
    // arguments intact - inverts MSYS path conversion for every native process the gate spawns, and a
    // `/tmp/...` path then reaches a Windows binary as `C:\tmp\...`. Measured: the node-instances
    // suite failed 10 of 62 with both sentinels started but not answering, its own artifact showing
    // `starting /tmp/wa-instances-...\.wasm-agent\instances\op\install\wa.exe`, and the nested verdict
    // read failed with ENOENT on `C:\tmp\...`. That failure was this lane's environment, not the merged
    // tree, so the lane drops its own switches and records what it dropped.
    for (const name of ['MSYS_NO_PATHCONV', 'MSYS2_ARG_CONV_EXCL', 'WASM_AGENT_PROVENANCE']) {
      if (environment[name] !== undefined) { delete environment[name]; dropped.push(name); }
    }
    for (const name of Object.keys(environment)) {
      if (name.startsWith('WA_MERGE_LANE_')) { delete environment[name]; dropped.push(name); }
    }
    if (options.jobs === 'default') {
      if (environment.WA_GATE_JOBS !== undefined) { delete environment.WA_GATE_JOBS; dropped.push('WA_GATE_JOBS'); }
    } else environment.WA_GATE_JOBS = String(options.jobs);
    // The lane's own switches are not the gate's either, for the same reason: the gate must run in
    // the environment it was written for (and scripts/test.sh unsets `WA_*` itself anyway). The one
    // lane variable the gate does see is the admission marker set from the slot below - deliberately
    // not a `WA_` name, so the gate's own environment fence leaves it alone - because that is what a
    // nested gate (the `finish.mjs gate` runs inside scripts/test-parallel-finish.mjs) reads to
    // inherit this decision instead of asking again.
    for (const name of ['WA_GATE_LANE', 'WA_GATE_LANE_DIR', 'WA_GATE_LANE_CAPACITY',
      'WA_GATE_LANE_WAIT_SECONDS', 'WA_GATE_LANE_SAMPLE_SECONDS']) {
      if (environment[name] !== undefined) { delete environment[name]; dropped.push(name); }
    }
    // The slot is asked for before the gate's own clock starts: `gate.ms` measures the gate on the
    // merged tree, and the wait for a free node is the lane's record of it (`gate.lane.waited_ms`),
    // not part of that measurement - the retained durations have to stay comparable.
    const slot = await laneAcquire({cwd: clone.dir, label: `merge-lane ${candidateTree.slice(0, 12)}`});
    gate.lane = slot.record;
    if (slot.refused) {
      // Terminal and named: the merged tree was not gated, and this run records which holder it gave
      // up behind instead of putting a second CPU-heavy gate on a node that has been busy for hours.
      gate.refused = true;
      gate.detail = `the merged tree was not gated: the gate lane granted no slot (${slot.record.reason})`;
      note(`merge-lane: the merged tree was NOT gated - the gate lane granted no slot: ${slot.record.reason}`);
    } else {
      environment.GATE_LANE_HELD = slot.marker;
      const gateStarted = nowMs();
      // The gate's own words are streamed to the file as they arrive, the way
      // `skills/parallel-evolution/scripts/finish.mjs` already does it: a holder that dies mid-gate then
      // leaves the evidence of how far it got, instead of an empty buffer. That partial log is not a
      // receipt - only a complete run with the verdict line is - but it is what reconciliation reads.
      const descriptor = fs.openSync(logPath, 'w');
      let spawned;
      try {
        spawned = spawnSync('bash', ['-c', options.gateCommand], {cwd: clone.dir, env: environment,
          timeout: options.timeoutSeconds * 1000, windowsHide: true, stdio: ['ignore', descriptor, descriptor]});
      } finally { fs.closeSync(descriptor); }
      gate.ms = elapsedMs(gateStarted);
      gate.ran = true;
      gate.exit = spawned.status === null ? 'timeout_or_spawn_error' : spawned.status;
      gate.detail = spawned.error ? spawned.error.message : null;
      await laneRelease(slot, spawned.status, `merge-lane gate in ${clone.dir} exited ${gate.exit}`);
      const log = fs.readFileSync(logPath, 'utf8');
      fs.writeFileSync(logPath, log);
      const verdict = parseGateVerdict(log);
      gate.log = logPath;
      if (options.json) {
        // The clone is disposable; the gate's own words are not. Keep a copy beside the JSON.
        gate.log = `${path.resolve(options.json)}.gate.log`;
        fs.writeFileSync(gate.log, log);
      }
      gate.log_sha256 = sha256(Buffer.from(log));
      gate.skipped = verdict.skipped;
      gate.verdict_line = verdict.line;
      gate.verdict_found = verdict.found;
    }
    gate.environment_dropped = dropped;
  }
  timings.gate_ms = gate.ms;
  // Re-read the integration target itself: "main did not move" is a claim about the ref the candidate
  // is based on, not about one particular remote-tracking spelling of it.
  const targetRefAfter = resolveRef(gitDir, options.base);
  const mainMoved = targetRefAfter === null ? null : targetRefAfter !== baseSha;
  timings.total_ms = elapsedMs(started);

  const gatePassed = gate.ran && gate.exit === 0 && gate.verdict_found;
  const verdict = blocked.length ? 'blocked'
    : !candidateMerges && !accepted.length ? 'nothing_to_merge'
    : gate.ran ? (gatePassed ? 'pass' : 'gate_failed')
    : gate.refused ? 'gate_refused'
    : 'merge_only';
  // A refused slot is neither a pass nor a gate failure: the merged tree was never gated, so the run
  // exits nonzero (6) and names the holder it gave up behind - never `merge_only`, which reads as
  // "merged, gate not needed" and exits 0.
  const exitCode = verdict === 'pass' || verdict === 'nothing_to_merge' || verdict === 'merge_only' ? 0
    : verdict === 'blocked' ? 2 : verdict === 'gate_refused' ? 6 : 3;

  const retainClone = Boolean(clone) && (options.keepClone || exitCode !== 0);
  const result = {
    schema: 1, lane: 'merge-lane', verdict, exit_code: exitCode,
    repo: gitDir, base: {ref: options.base, sha: baseSha},
    base_ref_before: baseSha, base_ref_after: targetRefAfter,
    main_moved_by_this_run: mainMoved,
    pushed: false,
    inputs, blocked: blocked.map(record => ({name: record.name, sha: record.sha, reason: record.reason,
      conflicts: record.conflicts || record.merge?.conflicts || []})),
    skipped: skipped.map(record => ({name: record.name, sha: record.sha, reason: record.reason})),
    candidate: {branch: laneBranch, head: candidateHead, tree: candidateTree, merges: candidateMerges,
      gated: gate.ran, stopped_before_merge: Boolean(accepted.length && !clone), steps},
    checks: {crlf, merge_subjects_judged_by: options.hooks && clone ? `${clone.dir}/.githooks` : null},
    gate, clone: clone ? {path: clone.dir, clone_ms: clone.clone_ms, core_autocrlf: clone.core_autocrlf,
      retained: retainClone, cleanup: retainClone ? `rm -rf "${clone.dir}"` : null} : null,
    discovery: {complete: discovery.discovery_complete, errors: discovery.errors, warnings,
      pending_tips: discovery.pending_tips, counts: discovery.counts, timings_ms: discovery.timings_ms},
    identity: IDENTITY,
    push_precondition: {
      can_push: verdict === 'pass' && mainMoved === false,
      base_ref_unchanged: mainMoved === false,
      requires: 'the reserved merger, holding the lane, re-reads origin/main, re-runs `audit.mjs verify <repo> origin/main`, and pushes this exact candidate tree; never a force-push',
    },
    timings_ms: timings,
    note: 'The spine never pushes and never moves main. A blocked input is named, and the exit is nonzero: no silent drop and no success.',
  };
  if (clone && !retainClone) {
    fs.rmSync(clone.dir, {recursive: true, force: true});
    result.clone.removed = true;
    result.clone.path = null;
  }
  if (options.json) fs.writeFileSync(path.resolve(options.json), `${JSON.stringify(result, null, 2)}\n`);
  note(`merge-lane: ${verdict} (exit ${exitCode}); candidate ${candidateTree}; gate ${gate.ran
    ? `exit ${gate.exit}, ${gate.skipped ?? '?'} skipped${gate.lane?.waited_ms >= 1000 ? ` after waiting ${(gate.lane.waited_ms / 1000).toFixed(0)}s for slot #${gate.lane.request}` : ''}`
    : gate.refused ? 'not run, the gate lane granted no slot' : 'not run'}`);
  process.stdout.write(`${JSON.stringify(result)}\n`);
  return exitCode;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    process.exitCode = await main();
  } catch (error) {
    const code = error.exit || 4;
    process.stdout.write(`${JSON.stringify({schema: 1, lane: 'merge-lane', verdict: 'refused', exit_code: code, error: error.message})}\n`);
    process.exitCode = code;
  }
}
