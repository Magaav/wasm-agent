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
//   --reuse-tree <path>    the persistent tree to gate in, instead of a fresh clone per run (default:
//                          WA_MERGE_LANE_TREE, else ~/.wasm-agent/merge-lane-tree). Reused only when it
//                          is provably clean; any refusal is named, recorded, and falls back to a clone
//   --no-reuse-tree        never reuse: always clone. A fixture or a test uses this
//   --keep-clone           keep the clone even when the lane passes
//
// Retention is bounded, and the knob that bounds it is `WA_MERGE_LANE_KEEP` (a count, default 1).
// A passing run removes its own clone; a failing run keeps its own; a sweep keeps the newest N
// leftovers of the family and deletes the older ones. `all` keeps everything (the behaviour that
// filled a 477 GB disk) and `0` keeps nothing (a red gate with no tree to re-run). Both are named
// here because they are how the bound is falsified, not because they are settings to use.
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

import {checkWaveAdmission} from './lib/wave-guard.mjs';
import {findFullProof} from './lib/full-gate-proof.mjs';
import {evaluate} from './delivery-admission.mjs';
import {readRecord} from './lib/delivery-store.mjs';
const here = path.dirname(fileURLToPath(import.meta.url));
const AUDIT = process.env.WA_MERGE_LANE_AUDIT || path.join(here, '..', 'skills', 'git-orchestrator', 'scripts', 'audit.mjs');
// A named identity, because an automatic merge has to be attributable. It is not the
// operator's identity and does not claim to be: the candidate is not pushed by this script.
const IDENTITY = {name: 'merge lane', email: 'merge-lane@wasm-agent.invalid'};

const nowMs = () => Number(process.hrtime.bigint()) / 1e6;
const elapsedMs = start => Number((nowMs() - start).toFixed(3));
const note = text => process.stderr.write(`${text}\n`);
const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

// ---- BOUNDED RETENTION: a day of gates costs a fixed number of clones, not the disk ------------
// The clone is a disposable tree that a real gate fills to ~1.1 GB (the gate builds `rust/target`
// inside it), and this lane's rule for keeping one was "did this run pass?" - so every failed,
// interrupted or killed run left its clone in the temp root forever. 135 of them were measured there
// (sampled: 1114, 1105, 1104, 1104 MB) beside 278 gate homes, ~150 GB of a 477 GB disk, and a
// comment-only change's merged-tree gate then died in 10.6 s: `error: failed to build archive ...
// There is not enough space on the disk. (os error 112)`, its own clone named in the cargo errors
// (the run is `.wasm-agent/merge-lane-batch14.json.gate.log`). The gate home is the other half of
// the leak and is bounded the same way, in `scripts/test.sh`.
//
// THE POLICY, and why not the other two. Not "keep the most recent N runs' clones", because that
// keeps passes, and a pass needs no clone: its verdict line, its exit status, its skip count and the
// sha256-pinned log are the record, and the log is already copied beside `--json`. Not "delete
// unless a flag asks to keep", because then an unattended red gate leaves nothing to re-run and a
// 1.1 GB tree is replaced by a text file - the failure that matters is exactly the one nobody was
// watching. It is: **a passing run removes its own clone; a failing run keeps its own; every run
// sweeps the family, keeping the newest `WA_MERGE_LANE_KEEP` leftovers (default 1).** The newest
// failure keeps its exact merged tree, its gate log and everything it printed; older failures keep
// nothing; a day of gates costs one clone instead of one clone per failure.
//
// LIVENESS DECIDES WHAT MAY BE PRUNED, NOT AGE - and where liveness cannot be read out of the name,
// it is asked of the filesystem (`holderProbe` below). The clone's directory name carries the pid of
// the run that owns it (`wa-merge-lane-<pid>-XXXXXX`, the pid added to mktemp's template), and a
// directory whose owning pid is alive is never a candidate: a retainer that deleted a live
// sibling's tree would turn a passing neighbour into an unattributed red gate, which this repository
// has already paid for once (scripts/test.sh, "the plugin staging directory ... was missing").
//
// A NAME WITH THE PRE-CHANGE SHAPE HAS NO PID, and the first version of this sweep pruned that name
// once it was an hour old. The hour was SHORTER THAN THE GATE LANE'S OWN WAIT BUDGET
// (`WA_GATE_LANE_WAIT_SECONDS`, 7200 s by default) and the clone is made at the top of the run,
// BEFORE the slot is asked for - so a run that is merely QUEUED for the gate has a clone older than
// an hour, and a live run's clone was deleted by this rule (reproduced by an independent review, D1
// of `verify/REVIEW-disk-temp.md`, and by `verify/prelease-grace.mjs` here). The grace is therefore
// DERIVED from the two budgets a live run can spend while it still holds its clone, not chosen:
//
//   gate lane wait (7200) + this lane's gate timeout (`--timeout-seconds`, 3600) + 60 s slack
//     = 10860 s = 3 h 1 min     - the flat hour it replaces was 7260 s short of the wait alone.
//
// And the grace is the FALLBACK, not the test: before anything is deleted, this run asks the
// filesystem whether the directory is in use, and a directory that is held is kept whatever its age
// and whatever minted it. Residual limits, named rather than hidden: (1) an MSYS/Cygwin process that
// reached the directory by `cd` is invisible to that ask (measured, `verify/probe-msys-cwd.mjs`), so
// a clone older than the grace above and held only that way can still be pruned; (2) if this process
// is killed while its gate child keeps running, the lease reads as dead - the filesystem ask is what
// still protects that tree, and the gate lane's slot row, not this lease, is the authority on which
// gates are live.
const CLONE_PREFIX = 'wa-merge-lane-';
const CLONE_KEEP_VARIABLE = 'WA_MERGE_LANE_KEEP';
const cloneName = /^wa-merge-lane-(\d+)-[A-Za-z0-9]{6}$/;
const legacyCloneName = /^wa-merge-lane-[A-Za-z0-9]{6}$/;
// The arithmetic above, in one place, so the number cannot drift away from the budgets it is made of.
// Both terms are budgets of a run that is still alive: the wait for the gate lane's slot (mirrored
// from `waitSecondsOf` in scripts/gate-lane.mjs) and the gate's own timeout (mirrored from this
// file's `--timeout-seconds`). The slack covers releasing the slot and exiting after a gate that
// used its whole timeout.
const GATE_LANE_WAIT_DEFAULT_SECONDS = 7200;
const LANE_GATE_TIMEOUT_DEFAULT_SECONDS = 3600;
const LEGACY_GRACE_SLACK_SECONDS = 60;

function budgetSeconds(raw, fallback) {
  if (raw === null || raw === undefined || raw === '') return fallback;
  const value = Number(raw);
  return Number.isFinite(value) && value >= 0 ? value : fallback;
}

// With no knobs set: 7200 + 3600 + 60 = 10860 s. A pre-change name is left alone for that long, and
// kept for longer than that whenever the filesystem can still show that something holds it.
export function legacyGraceMs({waitSeconds = process.env.WA_GATE_LANE_WAIT_SECONDS,
  gateTimeoutSeconds = null} = {}) {
  const wait = budgetSeconds(waitSeconds, GATE_LANE_WAIT_DEFAULT_SECONDS);
  const gate = budgetSeconds(gateTimeoutSeconds, LANE_GATE_TIMEOUT_DEFAULT_SECONDS);
  return (wait + gate + LEGACY_GRACE_SLACK_SECONDS) * 1000;
}

function retentionKeep(raw, variable) {
  const text = String(raw ?? '').trim().toLowerCase();
  if (!text) return 1;
  if (text === 'all') return 'all';
  if (!/^\d+$/.test(text)) {
    throw Object.assign(Error(`${variable} must be a non-negative whole number or 'all' (got ${JSON.stringify(raw)})`), {exit: 4});
  }
  return Number(text);
}

// What is this directory's owner doing? The lease is the pid in the name; only a directory whose
// owner is gone is a candidate for deletion.
function cloneOwner(name) {
  const owned = cloneName.exec(name);
  if (owned) {
    const pid = Number(owned[1]);
    if (pid === process.pid) return {state: 'own', pid};
    try { process.kill(pid, 0); return {state: 'live', pid}; }
    catch (error) { return {state: error.code === 'EPERM' ? 'live' : 'dead', pid}; }
  }
  return {state: legacyCloneName.test(name) ? 'legacy' : 'not_this_family', pid: null};
}

// Is this directory in use? A lease - the pid in the name - answers that for a name that has one; a
// name from before the lease has none, so the filesystem is asked directly instead of the clock. The
// ask is a rename within the same parent, which on this machine is refused while a native process's
// working directory is this directory or one below it (EBUSY, EPERM measured) and while a native
// process holds an open file inside it (EPERM measured) - and `rm -rf` SUCCEEDS in every one of
// those cases, so nothing else would have stopped the deletion. A refused rename is therefore
// evidence of use and the directory is kept; an allowed rename is the evidence that lets it go.
// Measured blind spot, not hidden: an MSYS/Cygwin process that reached the directory by `cd` leaves
// the rename free (verify/probe-msys-cwd.mjs), while one spawned with the directory as its own
// working directory - the way this lane spawns its gate - is refused (EBUSY).
function holderProbe(dir) {
  const probePath = `${dir}.in-use-${process.pid}`;
  try {
    fs.renameSync(dir, probePath);
  } catch (error) {
    if (error.code === 'ENOENT') return {gone: true, in_use: false, evidence: 'gone'};
    return {gone: false, in_use: true, evidence: `rename refused (${error.code})`};
  }
  try {
    fs.renameSync(probePath, dir);
    return {gone: false, in_use: false, evidence: 'rename allowed'};
  } catch (error) {
    return {gone: false, in_use: true, probe_path: probePath,
      evidence: `rename allowed but the name could not be restored (${error.code})`};
  }
}

// The sweep. Best effort and never fatal: a directory it cannot remove is recorded, and the merge
// this run exists for is not failed by a temp root it does not own. `currentKept` says whether this
// run's own clone is one of the kept ones: the budget counts it, because it is the newest by
// construction, and a budget of 1 spent on somebody else's clone keeps two. Exported because the
// retention bound is a property worth testing on its own (scripts/test-merge-lane-retention.mjs).
export function sweepClones({keep = 1, tmp = os.tmpdir(), current = null, currentKept = false, now = Date.now(),
  waitSeconds = process.env.WA_GATE_LANE_WAIT_SECONDS, gateTimeoutSeconds = null} = {}) {
  const graceMs = legacyGraceMs({waitSeconds, gateTimeoutSeconds});
  const held = Boolean(current) && fs.existsSync(current);
  const record = {family: `${CLONE_PREFIX}*`, keep, current: current || null, current_kept: Boolean(currentKept && held),
    grace_ms: graceMs, grace_seconds: graceMs / 1000,
    policy: 'a passing run removes its own clone; a failing run keeps its own; the sweep keeps the newest `keep` prunable clones, and never prunes one whose owning pid is alive or that this machine can prove is in use',
    budget_for_others: null, removed: [], kept: [], live: [], in_use: [], recent_legacy: [], not_this_family: 0, errors: []};
  let entries;
  try { entries = fs.readdirSync(tmp, {withFileTypes: true}); }
  catch (error) { record.errors.push({path: tmp, error: error.message}); return record; }
  const candidates = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || !entry.name.startsWith(CLONE_PREFIX)) continue;
    const dir = path.join(tmp, entry.name);
    if (current && path.resolve(dir) === path.resolve(current)) continue;
    const owner = cloneOwner(entry.name);
    if (owner.state === 'live') { record.live.push(dir); continue; }
    if (owner.state === 'own' || owner.state === 'not_this_family') { record.not_this_family += owner.state === 'not_this_family' ? 1 : 0; continue; }
    let mtimeMs = 0;
    try { mtimeMs = fs.statSync(dir).mtimeMs; }
    catch (error) { record.errors.push({path: dir, error: error.message}); continue; }
    if (owner.state === 'legacy' && now - mtimeMs < graceMs) { record.recent_legacy.push(dir); continue; }
    candidates.push({dir, mtimeMs, lease: owner.state, pid: owner.pid});
  }
  candidates.sort((left, right) => right.mtimeMs - left.mtimeMs);
  const budget = keep === 'all' ? candidates.length
    : Math.max(0, Number(keep) - (record.current_kept ? 1 : 0));
  record.budget_for_others = budget;
  candidates.forEach((candidate, index) => {
    if (index < budget) { record.kept.push({path: candidate.dir, lease: candidate.lease, pid: candidate.pid}); return; }
    // The last question before anything is deleted, answered by the filesystem rather than the clock:
    // whatever minted this name, and however old it is, a directory that can be shown to be in use is
    // not this sweep's to remove.
    const probe = holderProbe(candidate.dir);
    if (probe.gone) return;                                  // it went away on its own; nothing to do
    if (probe.in_use) {
      record.in_use.push({path: candidate.dir, lease: candidate.lease, pid: candidate.pid, evidence: probe.evidence});
      if (probe.probe_path) record.errors.push({path: candidate.dir, error: probe.evidence});
      return;
    }
    try {
      fs.rmSync(candidate.dir, {recursive: true, force: true});
      record.removed.push({path: candidate.dir, lease: candidate.lease, pid: candidate.pid, evidence: probe.evidence});
    } catch (error) { record.errors.push({path: candidate.dir, error: error.message}); }
  });
  return record;
}

// One line per run that actually pruned something, because a bound that acts silently is a bound
// nobody can tell from a bug. The full record is in the JSON (`retention.sweeps`).
function retentionNotice(retention) {
  for (const sweep of retention.sweeps) {
    if (sweep.removed.length) {
      note(`merge-lane: retention: removed ${sweep.removed.length} clone(s) beyond the newest ${sweep.keep}`
        + ` (${CLONE_KEEP_VARIABLE}=${retention.keep}); kept ${sweep.kept.length}`
        + (sweep.live.length ? `, left ${sweep.live.length} live clone(s) alone` : '')
        + (sweep.in_use.length ? `, left ${sweep.in_use.length} clone(s) in use alone` : ''));
    }
    for (const error of sweep.errors) note(`merge-lane: retention: could not remove ${error.path}: ${error.error}`);
  }
}

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
    timeoutSeconds: 3600, clone: null, keepClone: false, hooks: true, partial: false, json: null, repo: null, deliveryStore: null,
    keepClones: retentionKeep(process.env[CLONE_KEEP_VARIABLE], CLONE_KEEP_VARIABLE),
    reuse: true, reuseTreeNamed: false,
    reuseTree: String(process.env.WA_MERGE_LANE_TREE || '').trim() || path.join(os.homedir(), '.wasm-agent', 'merge-lane-tree')};
  if (String(process.env.WA_MERGE_LANE_TREE || '').trim()) options.reuseTreeNamed = true;
  const needs = new Set(['--repo', '--base', '--jobs', '--gate-command', '--timeout-seconds', '--clone', '--json', '--reuse-tree', '--delivery-store']);
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (needs.has(arg)) {
      const value = argv[index + 1];
      if (value === undefined) throw Error(`${arg} needs a value`);
      index += 1;
      if (arg === '--delivery-store') options.deliveryStore=value;
      else if (arg === '--repo') options.repo = value;
      else if (arg === '--base') options.base = value;
      else if (arg === '--jobs') options.jobs = value;
      else if (arg === '--gate-command') options.gateCommand = value;
      else if (arg === '--timeout-seconds') options.timeoutSeconds = Number(value);
      else if (arg === '--clone') options.clone = value;
      else if (arg === '--reuse-tree') { options.reuseTree = value; options.reuseTreeNamed = true; }
      else options.json = value;
    } else if (arg === '--all-pending') options.allPending = true;
    else if (arg === '--keep-clone') options.keepClone = true;
    else if (arg === '--no-reuse-tree') options.reuse = false;
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
  // The pid in the name is the lease that a later sweep reads before it deletes anything (see
  // "BOUNDED RETENTION" above): a clone whose owner is still running is never a candidate.
  const dir = options.clone ? path.resolve(options.clone)
    : fs.mkdtempSync(path.join(os.tmpdir(), `${CLONE_PREFIX}${process.pid}-`));
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
  return {dir, git_dir: gitDirAbs(dir) || path.join(dir, '.git'), clone_ms: cloneMs, core_autocrlf: autocrlf, reused: false};
}

// ---- THE PERSISTENT TREE THE GATE RUNS IN ------------------------------------------------------
// A fresh `git clone --local` costs under a second, but it also hands the gate an EMPTY `rust/target`,
// and the gate is where a landing's wall time goes: this lane's own records put the gate at 96.6% of
// lane wall time (median 15.0 min of which clone+merge is ~2 s), and the repository's measurement is
// that ~620 s of a solo cold gate is recompilation - 253.0 CPU-s charged inside the cold gate's own
// process tree against 11.2 CPU-s warm, on the same tree (docs/EVOLUTION.md, "Gate parallelism"). A
// disposable tree is therefore always cold, and this lane paid that once per landing.
//
// So the tree the gate runs in is persistent: one path per node, reused across runs with `git fetch` +
// a forced reset instead of a fresh clone. Its `rust/target` stays warm because cargo's fingerprints are
// keyed by the source path, which no longer changes between runs.
//
// WHAT GUARANTEES CLEANLINESS. Reuse is REFUSED, named, and falls back to a disposable clone (cold
// gate, correct result, recorded as `clone.reuse_refused`) unless every one of these holds:
//   * the directory is a git checkout whose toplevel is exactly that directory (not a linked worktree);
//   * its `origin` resolves to the repository being landed, and its owner record names that repository -
//     so a tree is never reused for another repository, which is also what keeps a test fixture from
//     ever creating or resetting the node's tree (a fixture's repository lives under the temp directory
//     and the default tree is never created for one);
//   * the reuse lock is free, or held by a process that is provably dead;
//   * after `git clean -xdf -e target`, a pinned `core.autocrlf`, `git switch --detach --force` and
//     `git reset --hard` onto the integration target, `git status --porcelain` is EMPTY - so what is
//     left is exactly the committed content plus cargo's own output directories, nothing else. What the
//     reset discarded (another run's leftovers, or an operator's stray edit) is NAMED in the log and in
//     `clone.reuse_dirt_discarded`: the guarantee is the reset, and the record is what it was applied to.
//
// THE RISK IT CARRIES, AND THE RECOVERY: stale state surviving in the tree, and a cargo output
// directory poisoned by a different toolchain. Two answers, both mechanical:
//   * stale state is what the checks above refuse on, and the falsification is deliberate - a candidate
//     that MUST fail is run through the reused tree (a failing test, a CRLF tree) and reported red;
//   * the toolchain is recorded in the owner file when the tree is created, and if `rustc -vV` differs
//     on reuse, every cargo output directory under the tree is removed before the gate runs, by name in
//     the record (`toolchain_cleared`). That is the poisoning answer, and it costs one cold gate rather
//     than risking an artifact built by another compiler.
// A tree that is wedged for any other reason (a foreign lock, a stolen directory, a filesystem error) is
// reported with its own reason, and the recovery is named in the log: `rm -rf <dir>`.
const REUSE_OWNER_FILE = 'wa-merge-lane-tree.json';
const REUSE_LOCK_FILE = 'wa-merge-lane-tree.lock';

// Compare two paths as the same location. Windows is case-insensitive and `git clone --local` records
// the path it was given, so a real path and a spelled-differently one are the same tree.
function samePath(left, right) {
  const norm = value => {
    let resolved = path.resolve(String(value));
    for (const resolve of [fs.realpathSync.native, fs.realpathSync].filter(item => typeof item === 'function')) {
      try { resolved = resolve(path.resolve(String(value))); break; } catch { /* keep what we have */ }
    }
    const folded = path.resolve(resolved).replace(/\\/g, '/').replace(/\/+$/, '');
    return process.platform === 'win32' ? folded.toLowerCase() : folded;
  };
  if (!left || !right) return false;
  return norm(left) === norm(right);
}

function gitDirAbs(dir) {
  const result = git(dir, 'rev-parse', '--absolute-git-dir');
  return result.status === 0 ? result.stdout.trim() : null;
}

function insideTemp(value) {
  const norm = item => path.resolve(String(item)).replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase();
  const parent = norm(os.tmpdir());
  const child = norm(value);
  return child === parent || child.startsWith(`${parent}/`);
}

function rustcFingerprint() {
  const result = run('rustc', ['-vV']);
  if (result.status !== 0) return null;
  return (result.stdout.trim().split('\n')[0] || '').trim() || null;
}

// A live pid, or provably gone. `process.kill(pid, 0)` answers this on Windows too (ESRCH when gone);
// EPERM means it exists and belongs to someone else.
function processAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; }
}

// Every cargo output directory in the tree, by cargo's own marker, so clearing them is a measurement
// and not a guess at the layout.
function cargoTargetDirs(root) {
  const found = [];
  const walk = (dir, level) => {
    if (level > 4) return;
    let entries = [];
    try { entries = fs.readdirSync(dir, {withFileTypes: true}); } catch { return; }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      if (entry.name === 'target') {
        if (fs.existsSync(path.join(dir, entry.name, 'CACHEDIR.TAG'))) found.push(path.join(dir, entry.name));
        continue;
      }
      if (entry.name === '.git' || entry.name === 'node_modules') continue;
      walk(path.join(dir, entry.name), level + 1);
    }
  };
  walk(root, 0);
  return found;
}

// The lock is what stops two lane runs resetting one tree under each other's gate. A crashed holder is
// proof-of-death, not a timeout: its lease dies with its pid, so a stale lock cannot disable reuse.
function holdReuseLock(lockPath) {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      const fd = fs.openSync(lockPath, 'wx');
      fs.writeSync(fd, `${JSON.stringify({pid: process.pid, started_at: new Date().toISOString()})}\n`);
      const lock = {fd, path: lockPath, reclaimed: attempt > 0};
      process.once('exit', () => { try { fs.closeSync(fd); } catch {} try { fs.rmSync(lockPath, {force: true}); } catch {} });
      return {ok: true, lock};
    } catch (error) {
      if (error.code !== 'EEXIST') return {ok: false, reason: `its lock could not be taken: ${error.message}`};
      let holder = null;
      try { holder = JSON.parse(fs.readFileSync(lockPath, 'utf8')); } catch { holder = null; }
      if (holder && processAlive(holder.pid)) {
        return {ok: false, reason: `it is in use by pid ${holder.pid}`
          + `${holder.started_at ? ` (holding since ${holder.started_at})` : ''}`};
      }
      note(`merge-lane: the reuse lock ${lockPath} was held by pid ${holder?.pid ?? 'an unrecorded process'},`
        + ' which is gone; taking it over (proof of death, not a timeout).');
      try { fs.rmSync(lockPath, {force: true}); } catch { /* the retry reports it */ }
    }
  }
  return {ok: false, reason: 'its lock could not be settled: a holder kept taking it'};
}

function releaseReuseLock(lock) {
  if (!lock || lock.released) return;
  lock.released = true;
  try { fs.closeSync(lock.fd); } catch {}
  try { fs.rmSync(lock.path, {force: true}); } catch {}
}

// Bring the persistent tree to exactly the state the clone path would have produced for this candidate.
function prepareReusedTree(dir, repo, base, options, laneBranch) {
  const started = nowMs();
  const failures = [];
  // What the tree held before the reset, so discarding another run's leftovers is REPORTED rather than
  // silent. The reset is the guarantee; this is the record of what it was applied to.
  const before = git(dir, 'status', '--porcelain');
  const dirt = before.status === 0 ? before.stdout.trim().split('\n').filter(Boolean) : [];
  const step = (label, args) => {
    const result = git(dir, ...args);
    if (result.status !== 0) failures.push(`${label}: ${(result.stderr || result.stdout).trim() || `exit ${result.status}`}`);
    return result;
  };
  const source = git(repo, 'config', '--get', 'core.autocrlf');
  const autocrlf = source.status === 0 && source.stdout.trim() ? source.stdout.trim() : 'false';
  // Ignored files go too, EXCEPT cargo's output directories: `-e target` is what keeps the warmth, and it
  // is also why the tree holds nothing a previous candidate left behind except build output.
  step('clearing untracked and ignored files', ['clean', '-xdf', '-e', 'target']);
  step('fetching the repository', ['fetch', '--no-tags', '--quiet', repo]);
  if (git(dir, 'cat-file', '-e', `${base}^{commit}`).status !== 0) {
    step('fetching every branch', ['fetch', '--no-tags', '--quiet', repo, '+refs/heads/*:refs/remotes/origin/*']);
  }
  if (!failures.length && git(dir, 'cat-file', '-e', `${base}^{commit}`).status !== 0) {
    failures.push(`the tree does not have the integration target ${base} after fetching; the repository must have it`);
  }
  if (!failures.length) {
    // Pin line-ending handling to the source's BEFORE anything is re-materialised, exactly as the clone
    // path does: a worktree whose bytes do not match the pinned value reads as dirty, and a dirty tree is
    // what a merge and the deploy gate both refuse.
    step('pinning line-ending handling', ['config', 'core.autocrlf', autocrlf]);
    step('checking out the integration target', ['switch', '--detach', '--force', base]);
    step('re-materialising the worktree', ['reset', '--hard', base]);
  }
  if (failures.length) return {refused: failures.join('; ')};
  const status = git(dir, 'status', '--porcelain');
  if (status.status !== 0 || status.stdout.trim()) {
    return {refused: `its worktree is not clean after a forced reset: ${(status.stdout.trim() || status.stderr.trim()).slice(0, 200)}`};
  }
  // This tree's own lane branches, from earlier runs: never pushed, never reused, and a long-lived tree
  // should not accumulate one ref per landing.
  const stale = git(dir, 'for-each-ref', '--format=%(refname:short)', 'refs/heads/lane/');
  if (stale.status === 0) {
    for (const ref of stale.stdout.trim().split('\n').filter(Boolean)) git(dir, 'update-ref', '-d', `refs/heads/${ref}`);
  }
  step('candidate branch', ['switch', '--create', laneBranch, base]);
  step('pinning origin/main', ['update-ref', 'refs/remotes/origin/main', base]);
  if (options.hooks) step('arming hooks', ['config', 'core.hooksPath', '.githooks']);
  else step('disarming hooks', ['config', 'core.hooksPath', '']);
  if (failures.length) return {refused: failures.join('; ')};
  return {clone_ms: elapsedMs(started), core_autocrlf: autocrlf, dirt_discarded: dirt.slice(0, 10),
    dirt_discarded_count: dirt.length};
}

// The tree to gate in: the persistent one when it is provably safe to reuse, and a disposable clone
// otherwise. Every refusal is named and recorded; none of them is silent, and none of them decides
// anything about the candidate - the gate still runs on a tree that is correct.
function openIntegrationTree(repo, base, options, laneBranch) {
  const fallback = (reason, extra = {}) => {
    note(`merge-lane: the persistent tree at ${path.resolve(options.reuseTree)} was NOT reused: ${reason}`);
    note('merge-lane: this run gates in a disposable clone instead - cold, correct, and slower.'
      + ` Recovery for a tree that stays unusable: rm -rf "${path.resolve(options.reuseTree)}"`);
    return {...cloneRepo(repo, base, options, laneBranch), reused: false,
      reuse_path: path.resolve(options.reuseTree), reuse_refused: reason, ...extra};
  };
  if (options.clone) return cloneRepo(repo, base, options, laneBranch);
  if (!options.reuse) {
    return {...cloneRepo(repo, base, options, laneBranch), reused: false,
      reuse_refused: 'reuse was not requested (--no-reuse-tree)'};
  }
  const dir = path.resolve(options.reuseTree);
  if (!options.reuseTreeNamed && insideTemp(repo)) {
    return fallback('the repository being landed is inside the temp directory, which is where a'
      + ' disposable fixture lives; the default tree is never created or reset for one', {reuse_created: false});
  }
  // A path the RETENTION sweep would own must never be the persistent tree. The sweep enumerates the
  // temp root for `wa-merge-lane-*` entries whose lease is gone, asks a rename probe, and deletes what
  // the probe allows - and a tree idle between two landings is a directory nobody holds, which is
  // exactly what the probe allows. The default tree (WA_MERGE_LANE_TREE, else ~/.wasm-agent/
  // merge-lane-tree) is outside the temp root and is not in that family, so it is never enumerated.
  // This check is deliberately STRICTER than today's candidate regexes: any in-temp path whose own name
  // carries the clone prefix is refused by name, because a name this lane cannot see a reason to prune
  // today is not a promise about tomorrow's sweep. The cost of refusing is a named cold clone, visible
  // in `clone.reuse_refused` - never a silent one, and never a tree something else may delete.
  if (insideTemp(dir) && path.basename(dir).startsWith(CLONE_PREFIX)) {
    return fallback(`it is inside the temp root and named like this lane's disposable clones`
      + ` (${CLONE_PREFIX}*), which is the family the retention sweep prunes; a tree idle between`
      + ' landings holds nothing a rename probe can see, so the sweep would be entitled to delete it.'
      + ' Name a tree outside the temp root (the default is outside it), or let this run clone',
    {reuse_created: false});
  }
  if (!fs.existsSync(dir)) {
    const started = nowMs();
    fs.mkdirSync(path.dirname(dir), {recursive: true});
    const fresh = cloneRepo(repo, base, {...options, clone: dir}, laneBranch);
    const owner = {schema: 1, repo: path.resolve(repo), created_at: new Date().toISOString(),
      created_by_pid: process.pid, toolchain: rustcFingerprint(), runs: 1};
    fs.writeFileSync(path.join(fresh.git_dir, REUSE_OWNER_FILE), `${JSON.stringify(owner, null, 2)}\n`);
    note(`merge-lane: created the persistent tree ${dir} (first run: this gate is cold); it is reused from here on`);
    return {...fresh, reused: false, reuse_created: true, disposable: false, owner, reuse_path: dir,
      clone_ms: elapsedMs(started), core_autocrlf: fresh.core_autocrlf};
  }
  const top = git(dir, 'rev-parse', '--show-toplevel');
  if (top.status !== 0) return fallback(`it is not a git checkout (${(top.stderr || top.stdout).trim() || `exit ${top.status}`})`);
  if (!samePath(top.stdout.trim(), dir)) {
    return fallback(`it is a linked worktree of ${top.stdout.trim()}, not a tree of its own at ${dir}`);
  }
  const gitDir = gitDirAbs(dir);
  if (!gitDir) return fallback('its git directory could not be resolved');
  const origin = git(dir, 'config', '--get', 'remote.origin.url');
  if (origin.status !== 0 || !samePath(origin.stdout.trim(), repo)) {
    return fallback(`its origin is ${origin.stdout.trim() || 'unset'}, not the repository being landed`
      + ` (${path.resolve(repo)})`);
  }
  let owner = null;
  try { owner = JSON.parse(fs.readFileSync(path.join(gitDir, REUSE_OWNER_FILE), 'utf8')); } catch { owner = null; }
  if (!owner || !owner.repo || !samePath(owner.repo, repo)) {
    return fallback(`its owner record (${path.join(gitDir, REUSE_OWNER_FILE)}) is missing or names`
      + ` ${owner?.repo ? path.resolve(owner.repo) : 'nothing'}; this lane only reuses a tree it created`
      + ' for the repository being landed');
  }
  const held = holdReuseLock(path.join(gitDir, REUSE_LOCK_FILE));
  if (!held.ok) return fallback(held.reason);
  const toolchain = rustcFingerprint();
  const cleared = [];
  if (owner.toolchain && toolchain && owner.toolchain !== toolchain) {
    // The poisoning answer: an output directory built by another compiler is not trusted, it is removed.
    // The cost is one cold gate, and it is named here rather than paid silently.
    for (const target of cargoTargetDirs(dir)) {
      try { fs.rmSync(target, {recursive: true, force: true}); cleared.push(path.relative(dir, target).replace(/\\/g, '/')); }
      catch (error) { note(`merge-lane: could not remove ${target}: ${error.message}; NOT reusing the tree`); }
    }
    note(`merge-lane: rustc changed since this tree was built (${owner.toolchain} -> ${toolchain});`
      + ` removed ${cleared.length} cargo output director${cleared.length === 1 ? 'y' : 'ies'}: ${cleared.join(', ') || 'none'}`);
    if (cleared.length === 0) { releaseReuseLock(held.lock); return fallback('the recorded toolchain changed and no cargo output directory could be cleared'); }
  }
  const prepared = prepareReusedTree(dir, repo, base, options, laneBranch);
  if (prepared.refused) { releaseReuseLock(held.lock); return fallback(prepared.refused); }
  if (prepared.dirt_discarded_count) {
    note(`merge-lane: the persistent tree held ${prepared.dirt_discarded_count} modified or untracked path(s)`
      + ` from an earlier run; the forced reset to ${base.slice(0, 12)} discarded them:`
      + ` ${prepared.dirt_discarded.join(', ')}${prepared.dirt_discarded_count > prepared.dirt_discarded.length ? ', ...' : ''}`);
  }
  fs.writeFileSync(path.join(gitDir, REUSE_OWNER_FILE), `${JSON.stringify({...owner, repo: path.resolve(repo),
    toolchain, last_used_at: new Date().toISOString(), last_used_pid: process.pid, runs: (owner.runs || 1) + 1}, null, 2)}\n`);
  note(`merge-lane: reusing the persistent tree ${dir} (warm build, no clone); lock pid ${process.pid}`);
  return {dir, git_dir: gitDir, clone_ms: prepared.clone_ms, core_autocrlf: prepared.core_autocrlf, reused: true,
    disposable: false, reuse_path: dir, owner, lock: held.lock, toolchain_cleared: cleared,
    reuse_dirt_discarded: prepared.dirt_discarded, reuse_dirt_discarded_count: prepared.dirt_discarded_count};
}

// The gate's phase table (scripts/lib/gate-phases.sh), read from the file this lane told the gate to
// write, and from the line it printed into its own log when that file is missing (a holder that died
// mid-gate). Absent is reported as absent: this lane never invents a duration, and a missing table is
// NOT a gate failure - the verdict line is what decides that.
function gatePhases(phasesPath, log) {
  let parsed = null;
  let source = null;
  try { parsed = JSON.parse(fs.readFileSync(phasesPath, 'utf8')); source = 'file'; } catch { parsed = null; }
  if (!parsed || !Array.isArray(parsed.phases)) {
    const match = /^gate phases json: (\{.*\})$/m.exec(log);
    if (match) { try { parsed = JSON.parse(match[1]); source = 'log'; } catch { parsed = null; } }
  }
  if (!parsed || !Array.isArray(parsed.phases)) return null;
  return {source, phases: parsed.phases, total_ms: parsed.total_ms ?? null, skipped: parsed.skipped ?? null,
    cargo_jobs: parsed.cargo_jobs ?? null, test_threads: parsed.test_threads ?? null};
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
    let origin;
    try { origin=JSON.parse(process.env.GATE_LANE_ORIGIN || ''); } catch {}
    const validation=origin && LANE_HELD===`slot:${origin.id}`
      ? spawnSync(process.execPath,[LANE_SCRIPT,'validate','--dir',origin.dir,'--id',String(origin.id),
        '--lease',origin.lease,'--holder-pid',String(process.pid)],
      {encoding:'utf8',windowsHide:true,timeout:20000}) : null;
    if (!validation || validation.status !== 0) {
      record.mode='refused';record.reason=`invalid_inheritance: ${LANE_HELD} has no verified live ancestor lease`;
      laneNotice(`gate lane: ${record.reason}`);
      return {obtained:false,refused:true,marker:null,record};
    }
    record.mode='inherited';record.request=origin.id;record.dir=origin.dir;
    record.reason=`inherited ${LANE_HELD}: verified live ancestor lease`;
    laneNotice(`gate lane: ${record.reason}; no second slot is requested`);
    return {obtained:false,refused:false,marker:LANE_HELD,origin,record};
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
    laneNotice(`gate lane: ${record.reason}; the merged tree was not gated.`);
    return {obtained: false, refused: true, marker: null, record};
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
    return {obtained: true, refused: false, marker: `slot:${outcome.grant.id}`, origin:outcome.grant.inheritance, child, record};
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
  record.mode='unavailable';record.reason=words;
  laneNotice(`gate lane: could not be consulted (${words}); the merged tree was not gated.`);
  return {obtained:false,refused:true,marker:null,record};
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
  // Every sweep this run performs, kept in the JSON: a bound that acts is a bound that says so.
  const retention = {variable: CLONE_KEEP_VARIABLE, keep: options.keepClones, prefix: CLONE_PREFIX, sweeps: [],
    policy: 'a passing run removes its own clone; a failing run keeps its own; a sweep keeps the newest `keep` prunable clones (a clone whose owning pid is alive is never pruned)'};

  const top = run('git', ['-C', repo, 'rev-parse', '--show-toplevel']);
  if (top.status !== 0) throw Object.assign(Error(`not a git repository: ${repo}`), {exit: 4});
  const gitDir = top.stdout.trim();
  const wave=checkWaveAdmission(gitDir,{phase:'land'});
  if(!wave.ok)throw Object.assign(Error(wave.reason),{exit:2});

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
    if (options.deliveryStore) {
      const delivery=readRecord(options.deliveryStore,input.name.replace(/^origin\//,''));
      if (!delivery) { record.state='blocked';record.reason='delivery admission record missing';blocked.push(record);inputs.push(record);continue; }
      record.admission=evaluate({repo:gitDir,record:delivery});
      if(record.admission.decision==='refused'||record.admission.observed.tip!==input.sha) {
        record.state='blocked';record.reason=record.admission.refusal||'admitted tip moved';blocked.push(record);inputs.push(record);continue;
      }
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
    // Bounded retention, before anything new is made. A previous run that was killed - or whose
    // supervisor died - never reached the removal below, and its clone is what fills the disk.
    // ORDER, and why the sweep still goes first: the sweep reads the temp root, and the tree this lane
    // reuses is not in it ("THE PERSISTENT TREE IS NOT IN THE SWEEP'S FAMILY", below). Sweeping before the
    // tree is opened keeps the retention rule's own ordering: the sweep does not wait on a reuse
    // decision, and a run that refuses the tree and clones instead sweeps exactly as it did before.
    retention.sweeps.push(sweepClones({keep: options.keepClones, gateTimeoutSeconds: options.timeoutSeconds,
      current: options.clone ? path.resolve(options.clone) : null}));
    clone = openIntegrationTree(gitDir, baseSha, options, laneBranch);
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
  const existingFull = clone && options.gateCommand==='bash scripts/test.sh'
    ? findFullProof(gitDir,candidateTree) : {verified:false,reason:'no candidate or custom gate command'};
  if (existingFull.verified) {
    gate={...gate,reused:true,exit:0,ms:0,log:existingFull.log,log_sha256:existingFull.log_sha256,
      skipped:existingFull.skipped,verdict_line:existingFull.verdict_line,verdict_found:true,proof:existingFull};
    note(`merge-lane: complete identical-tree gate evidence reused from ${existingFull.receipt}; no new gate run`);
  }
  if (!gate.reused && clone && crlf.state !== 'offenders' && (!blocked.length || options.partial)) {
    // Inside `.git`, not the worktree: the gate asks for a clean tree (scripts/test-deploy-downgrade.sh
    // refuses on dirt), so the lane's own log must not be the dirt it reports.
    const logPath = path.join(clone.git_dir, 'wa-merge-lane-gate.log');
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
      environment.GATE_LANE_ORIGIN = slot.origin ? JSON.stringify(slot.origin) : "";
      // Phase timing is the gate's own instrumentation (scripts/lib/gate-phases.sh); this lane only names
      // where the machine-readable copy goes and reads it back. The file is removed first, because a
      // previous run's table must never be read as this run's - the same reason
      // scripts/test-node-instances.sh deletes its verdict file before it runs the suite.
      const phasesPath = path.join(clone.git_dir, 'wa-merge-lane-phases.json');
      fs.rmSync(phasesPath, {force: true});
      environment.GATE_PHASES_JSON = phasesPath;
      const gateStarted = nowMs();
      // The gate's own words are streamed to the file as they arrive, the way
      // `skills/parallel-evolution/scripts/finish.mjs` already does it: a holder that dies mid-gate then
      // leaves the evidence of how far it got, instead of an empty buffer. That partial log is not a
      // receipt - only a complete run with the verdict line is - but it is what reconciliation reads.
      const descriptor = fs.openSync(logPath, 'w');
      let spawned;
      try {
        spawned = spawnSync(process.platform==='win32' ? path.join(process.env.ProgramFiles || 'C:/Program Files','Git','bin','bash.exe') : 'bash', ['-c', options.gateCommand], {cwd: clone.dir, env: environment,
          timeout: options.timeoutSeconds * 1000, windowsHide: true, stdio: ['ignore', descriptor, descriptor]});
      } finally { fs.closeSync(descriptor); }
      gate.ms = elapsedMs(gateStarted);
      gate.ran = true;
      gate.exit = spawned.status === null ? 'timeout_or_spawn_error' : spawned.status;
      gate.detail = spawned.error ? spawned.error.message : null;
      if(spawned.error && slot.obtained) {
        const deferred=spawnSync(process.execPath,[LANE_SCRIPT,'defer','--id',String(slot.record.request),
          '--gate-pid',String(spawned.pid||0),'--detail',`merge gate execution error: ${spawned.error.message}; descendant drain required`],
          {encoding:'utf8',windowsHide:true,timeout:20000});
        gate.drain_required=true;
        if(deferred.status!==0) {
          laneNotice(`gate lane: could not persist drain uncertainty: ${deferred.stderr||deferred.error?.message}; retaining owner`);
          await new Promise(()=>{setInterval(()=>{},1000);});
        }
        slot.child?.unref();slot.child?.stdout?.destroy();slot.child?.stderr?.destroy();
      } else {await laneRelease(slot, spawned.status, `merge-lane gate in ${clone.dir} exited ${gate.exit}`);}
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
      gate.phases_file = phasesPath;
      gate.phases = gatePhases(phasesPath, log);
      gate.phases_total_ms = gate.phases ? gate.phases.total_ms : null;
    }
    gate.environment_dropped = dropped;
  }
  timings.gate_ms = gate.ms;
  // Re-read the integration target itself: "main did not move" is a claim about the ref the candidate
  // is based on, not about one particular remote-tracking spelling of it.
  const targetRefAfter = resolveRef(gitDir, options.base);
  const mainMoved = targetRefAfter === null ? null : targetRefAfter !== baseSha;
  timings.total_ms = elapsedMs(started);

  if(clone && (gate.ran || gate.reused)) {
    const postHead=resolveRef(clone.dir,'HEAD');
    const postTree=git(clone.dir,'rev-parse','HEAD^{tree}');
    const postStatus=git(clone.dir,'status','--porcelain','--untracked-files=all');
    gate.source_observation={head:postHead,tree:postTree.status===0?postTree.stdout.trim():null,
      status:postStatus.status===0?postStatus.stdout.trim():null};
    gate.source_verified=postHead===candidateHead&&gate.source_observation.tree===candidateTree
      &&postStatus.status===0&&gate.source_observation.status==='';
    if(!gate.source_verified)gate.source_error='candidate HEAD/tree or tracked/untracked cleanliness changed during gate; no source-bound proof';
  }
  const gatePassed = (gate.ran || gate.reused) && gate.exit === 0 && gate.verdict_found && gate.source_verified===true;
  if (gatePassed && options.gateCommand==='bash scripts/test.sh') {
    // Persist in this lane's Git metadata, before its disposable tree is removed.
    // Only the identical combined source tree can reuse this; focused checks never enter here.
    const metadata=requireGit(gitDir,['rev-parse','--git-path','wa-combined-gate.json'],'combined receipt path');
    const durableLog=path.resolve(gitDir,metadata+'.log');
    if(path.resolve(gate.log)!==durableLog)fs.copyFileSync(gate.log,durableLog);
    const receipt={schema:1,kind:'full',repo:gate.reused?gate.proof.tested_repo:clone.dir,owner_repo:path.resolve(gitDir),
      head:gate.reused?gate.proof.head:candidateHead,candidate_head:candidateHead,tree:candidateTree,passed:true,
      gate_exit:0,gate_runs:1,gate_ms:gate.reused?gate.proof.gate_ms:gate.ms,skipped:gate.skipped,
      log:durableLog,log_sha256:gate.log_sha256,at:new Date().toISOString()};
    gate.full_receipt=path.resolve(gitDir,metadata);
    fs.writeFileSync(gate.full_receipt,JSON.stringify(receipt,null,2)+'\n');
  }
  const verdict = blocked.length ? 'blocked'
    : !candidateMerges && !accepted.length ? 'nothing_to_merge'
    : (gate.ran || gate.reused) ? (gatePassed ? 'pass' : 'gate_failed')
    : gate.refused ? 'gate_refused'
    : 'merge_only';
  // A refused slot is neither a pass nor a gate failure: the merged tree was never gated, so the run
  // exits nonzero (6) and names the holder it gave up behind - never `merge_only`, which reads as
  // "merged, gate not needed" and exits 0.
  const exitCode = verdict === 'pass' || verdict === 'nothing_to_merge' || verdict === 'merge_only' ? 0
    : verdict === 'blocked' ? 2 : verdict === 'gate_refused' ? 6 : 3;

  // A persistent tree is NEVER removed by this lane, whether it was just created or reused: it is the
  // thing that makes the next gate warm, and a lane that deletes its own cache on success is a lane that
  // pays the cold gate forever. A disposable clone follows the retention bound instead: a failing run
  // keeps its own (unless WA_MERGE_LANE_KEEP=0 says otherwise), a passing run does not.
  const retainClone = Boolean(clone) && (clone.disposable === false || options.keepClone
    || (exitCode !== 0 && options.keepClones !== 0));
  const result = {
    schema: 1, lane: 'merge-lane', verdict, exit_code: exitCode, wave,
    repo: gitDir, base: {ref: options.base, sha: baseSha},
    base_ref_before: baseSha, base_ref_after: targetRefAfter,
    main_moved_by_this_run: mainMoved,
    pushed: false,
    inputs, blocked: blocked.map(record => ({name: record.name, sha: record.sha, reason: record.reason,
      conflicts: record.conflicts || record.merge?.conflicts || []})),
    skipped: skipped.map(record => ({name: record.name, sha: record.sha, reason: record.reason})),
    candidate: {branch: laneBranch, head: candidateHead, tree: candidateTree, merges: candidateMerges,
      gated: Boolean(gate.ran || gate.reused), gate_run_count: gate.ran ? 1 : 0, gate_reused: Boolean(gate.reused), stopped_before_merge: Boolean(accepted.length && !clone), steps},
    checks: {crlf, merge_subjects_judged_by: options.hooks && clone ? `${clone.dir}/.githooks` : null},
    gate, clone: clone ? {path: clone.dir, git_dir: clone.git_dir, clone_ms: clone.clone_ms,
      core_autocrlf: clone.core_autocrlf, reused: clone.reused === true, reuse_created: clone.reuse_created === true,
      reuse_path: clone.reuse_path || null, reuse_refused: clone.reuse_refused || null, owner: clone.owner || null,
      toolchain_cleared: clone.toolchain_cleared || [],
      reuse_dirt_discarded: clone.reuse_dirt_discarded || [], retained: retainClone,
      cleanup: clone.disposable === false ? null : retainClone ? `rm -rf "${clone.dir}"` : null} : null,
    discovery: {complete: discovery.discovery_complete, errors: discovery.errors, warnings,
      pending_tips: discovery.pending_tips, counts: discovery.counts, timings_ms: discovery.timings_ms},
    identity: IDENTITY,
    push_precondition: {
      can_push: verdict === 'pass' && mainMoved === false,
      base_ref_unchanged: mainMoved === false,
      requires: 'the reserved merger, holding the lane, re-reads origin/main, re-runs `audit.mjs verify <repo> origin/main`, and pushes this exact candidate tree; never a force-push',
    },
    timings_ms: timings,
    retention,
    note: 'The spine never pushes and never moves main. A blocked input is named, and the exit is nonzero: no silent drop and no success.',
  };
  if (clone && clone.reused === true) releaseReuseLock(clone.lock);
  if (clone && !retainClone && clone.disposable !== false) {
    fs.rmSync(clone.dir, {recursive: true, force: true});
    result.clone.removed = true;
    result.clone.path = null;
  }
  // The bound, applied to what this run is leaving behind. Run after the decision above so the
  // clone this run keeps is counted in its own budget - and never a candidate for deletion.
  // The bound, applied to what this run is leaving behind. Run after the decision above so the
  // clone this run keeps is counted in its own budget - and never a candidate for deletion.
  //
  // ONE TERM KEPT FROM THE REUSE MECHANISM, and why: `currentKept` spends part of the budget on the
  // tree THIS run is keeping, because that tree is the newest by construction. A persistent tree is not
  // one of the sweep's own family (it is outside the temp root, and the check above refuses an in-temp
  // path that is in it), so counting it would spend the budget on a path the sweep cannot even see and
  // prune the newest leftover anyway - i.e. a passing WARM landing would delete the newest failing
  // run's clone, which is exactly the tree the retention rule keeps so a red gate can be re-run.
  // Counting only a disposable clone keeps both rules whole: the sweep's budget is spent on clones it
  // can prune, and the persistent tree is never a candidate. `current` still names the persistent tree,
  // because the record should say which tree the run gated in.
  retention.sweeps.push(sweepClones({keep: options.keepClones, currentKept: retainClone && clone.disposable !== false,
    gateTimeoutSeconds: options.timeoutSeconds,
    current: clone ? clone.dir : (options.clone ? path.resolve(options.clone) : null)}));
  retentionNotice(retention);
  if (options.json) fs.writeFileSync(path.resolve(options.json), `${JSON.stringify(result, null, 2)}\n`);
  note(`merge-lane: ${verdict} (exit ${exitCode}); candidate ${candidateTree}; gate ${gate.ran
    ? `exit ${gate.exit}, ${gate.skipped ?? '?'} skipped${gate.lane?.waited_ms >= 1000 ? ` after waiting ${(gate.lane.waited_ms / 1000).toFixed(0)}s for slot #${gate.lane.request}` : ''}`
    : gate.reused ? 'identical-tree full proof reused; zero new runs' : gate.refused ? 'not run, the gate lane granted no slot' : 'not run'}`);
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
