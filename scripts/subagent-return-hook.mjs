#!/usr/bin/env node
// The deterministic core of the `onSubagentReturn` hook: the one place that decides whether a settled
// child's work changes what a deploy installs, and the one place that writes the instruction block the
// orchestrator is woken with.
//
// WHY THIS IS DETERMINISTIC, AND WHY THAT IS THE POINT.
//
//   "once an agent replies back to you, you need a deterministic hook on each agent report back/failure,
//    it should wake you up and instruct you if it should deploy" - the owner's instruction.
//
// Every step below is decidable without judgement: read the node's recorded children, read the child's
// recorded branch and worktree, diff it against `origin/main`, match the paths against the set a deploy
// actually installs, print a block. None of it needs an opinion, so none of it costs a model turn
// (skills/automation-jobs/SKILL.md: "if a step can be decided without judgement, it must not cost a
// token"). The hook therefore *fires* on every settle in every state with no model call at all; the one
// message it causes is the wake to the orchestrator, which is the judgement half and is budgeted there.
//
// Two modes, one program, because the block and the verdict come from the same rule:
//
//   --observe   the job `subagent-return-observe`'s deterministic `run` step. Reads the node's own
//               record of every child (`POST /subagents {action:"list"}` plus one `status` per settled
//               child for its completion packet), measures each child's diff against origin/main in the
//               worktree the node recorded, and emits ONE `subagent.return` event per newly settled
//               child. The event id IS the child's id, so the job store's own dedupe
//               (UNIQUE(job_id,revision,event_id)) and the hook's wake-level dedupe both key on the same
//               fact: a poll that runs every 30 s cannot wake anyone twice for the same child, and a
//               definition re-put cannot either.
//
//   --compose   the `prepare` step of the `onSubagentReturn` job's wake action. Reads that event
//               (`WA_JOB_EVENT_FILE`) and prints the instruction block the sentinel injects into the
//               wake message. It makes no network call at all.
//
// THE THREE WAYS THIS MUST NOT LIE. "no install impact" is a claim about a measurement, so it may only
// be said when the measurement was taken:
//
//   * the shipped set comes from `scripts/deploy-shipped.json`, which is derived from what
//     `scripts/deploy.sh` and `scripts/upgrade.sh` actually install (`scripts/check-deploy-shipped.mjs`
//     fails when an installer copies something the manifest does not cover). A manifest that cannot be
//     read is `cannot be computed`, never "nothing is shipped";
//   * the diff is taken against the child's merge base with `origin/main`. No merge base (an unrelated
//     history, a shallow clone) is `cannot be computed` - a whole-tree two-dot diff answers a different
//     question and answered it "no install impact";
//   * the uncommitted half counts. A child whose tip equals main but whose worktree holds uncommitted
//     shipped changes has install impact, and a checkout that reports uncommitted work the pass could
//     not measure is `cannot be computed`.
//
// Exit codes: 0 a completed pass (including one that could not report anything, which says so in one
// line with the numbers it did see - a closed source is an answer, not a failure); 4 usage, a reachable
// source that answered something unusable, or a state this cannot be recorded from.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath, pathToFileURL} from 'node:url';

const SCHEMA = 1;
const TOPIC = 'subagent.return';
const BLOCK_HEADER = '[onSubagentReturn]';
const HOOK_JOB = 'onSubagentReturn';

// ---------------------------------------------------------------------------------------------
// THE DEPLOY RULE. One predicate, and one declaration of what a deploy installs.
//
// `scripts/deploy-shipped.json` is the single source of truth for the shipped set, and it is derived
// from the installers themselves - not maintained by hand beside them. The reason is a measured one:
// the first version of this predicate carried a hand-written list of `scripts/**` patterns and missed
// `jobs/**` (which `deploy.sh` installs into the job store) and `scripts/upgrade.sh` (which installs
// itself), so a child that changed what the node *runs* was reported as having no install impact. A
// hand list beside an installer drifts from it; a manifest with a check that fails when the installer
// copies something the manifest does not cover does not.
const MANIFEST_NAME = 'deploy-shipped.json';
const VERDICT = {
  required: "deploy required at the wave's end",
  none: 'no install impact',
  unknown: 'cannot be computed',
};

// What the orchestrator is told to do, per verdict. Fixed text: the verdict is measured, the
// instruction is approved policy, and the two are joined here rather than being improvised per wake.
const OPERATING_INSTRUCTION = {
  [VERDICT.required]:
    "This child touched something a deploy ships, so the wave owes exactly ONE deploy at its end - not one per child, and never from this child's branch. Evaluate the child's work first (read its session evidence and the diff above): a child's branch is a proposal, not a release. Deploy only after the wave's work is reviewed and integrated as one delivery, by the lane that owns that act, and only when the tree to deploy is the tree that was gated. Do not restart the node or hand-run a deploy from here on this notification alone.",
  [VERDICT.none]:
    'Nothing this child changed is copied by a deploy, so no deploy is owed for it and there is nothing to install. Evaluate the child\'s work on its own terms; do not spend the wave\'s single deploy on documentation or tests, and do not treat "no install impact" as "no review needed".',
  [VERDICT.unknown]:
    'Artifacts could not be read, so "no install impact" is NOT established for this child - do not deploy on this evidence and do not record a verdict you could not measure. Open the child\'s session and its checkout, find the branch and tip it actually left, and decide from that. Report the unmeasured artifact as unmeasured; an unreadable checkout is a blocker to name, not a clean result.',
};

const SETTLED_STATES = new Set(['completed', 'failed', 'cancelled', 'refused', 'unknown']);
const MAX_PATHS = 200;

export function manifestPath(scriptDir = path.dirname(fileURLToPath(import.meta.url))) {
  return path.join(scriptDir, MANIFEST_NAME);
}

/// The shipped set, read from the manifest beside this script. `error` is explicit so a caller cannot
/// mistake "could not read the rule" for "nothing is shipped".
export function loadShipped(file = manifestPath()) {
  try {
    const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (manifest.schema !== SCHEMA || !Array.isArray(manifest.directories) || !Array.isArray(manifest.files) || !Array.isArray(manifest.globs)) {
      return {error: `shipped_manifest_malformed: ${file}`};
    }
    return {manifest, file};
  } catch (error) {
    return {error: `shipped_manifest_unreadable: ${file}: ${String(error.message || error)}`};
  }
}

function normalize(candidate) {
  return String(candidate || '').replace(/\\/g, '/').replace(/^\.\//, '');
}

/// A glob here is the deploy's own glob shape: one `*` standing for a file name inside one directory
/// (no `/`), which is what `for source in "$ROOT"/scripts/lib/*` and the `./lib/<name>` grep mean. A
/// nested path is therefore *not* covered by `scripts/lib/*`, matching the installer.
function matchesGlob(file, glob) {
  const pattern = normalize(glob);
  if (!pattern.includes('*')) return file === pattern;
  const [head, tail] = pattern.split('*');
  if (tail !== '') return false;
  if (!file.startsWith(head)) return false;
  const rest = file.slice(head.length);
  return rest !== '' && !rest.includes('/');
}

export function shipsToDeploy(candidate, manifest) {
  const file = normalize(candidate);
  if (file === '' || !manifest) return false;
  if ((manifest.directories || []).some((directory) => file.startsWith(normalize(directory)))) return true;
  if ((manifest.files || []).some((entry) => file === normalize(entry))) return true;
  // The wave closure: files `scripts/ship-wave.mjs` writes because a shipped wave script imports them,
  // which the check re-derives from ship-wave itself on every gate run.
  if ((manifest.wave_closure_files || []).some((entry) => file === normalize(entry))) return true;
  return (manifest.globs || []).some((glob) => matchesGlob(file, glob));
}

export function deployVerdict(paths, manifest) {
  const list = (paths || []).map((entry) => String(entry));
  const shipped = list.filter((entry) => shipsToDeploy(entry, manifest));
  return {
    verdict: shipped.length > 0 ? VERDICT.required : VERDICT.none,
    shipped: shipped.slice(0, MAX_PATHS),
    shipped_count: shipped.length,
    paths: list.length,
  };
}

// ---------------------------------------------------------------------------------------------
// The block. Every fact in it is a measurement or an explicit absence; nothing is inferred.
function artifactLine(artifacts) {
  if (!artifacts || typeof artifacts !== 'object') return 'artifacts: NOT REPORTED by the child record';
  if (artifacts.available === false) return `artifacts: UNREADABLE (${artifacts.reason || 'no reason reported'})`;
  const branch = artifacts.branch || artifacts.recorded_branch || '';
  const tip = artifacts.head || '';
  const worktree = artifacts.worktree || '';
  const parts = [];
  parts.push(`branch: ${branch || 'NOT REPORTED'}`);
  parts.push(`tip: ${tip || 'NOT REPORTED'}`);
  parts.push(`worktree: ${worktree || (artifacts.managed === false ? 'none (unmanaged checkout)' : 'NOT REPORTED')}`);
  if (artifacts.ahead !== undefined) parts.push(`ahead_of_origin_main: ${artifacts.ahead}`);
  if (artifacts.dirty !== undefined) parts.push(`dirty: ${artifacts.dirty}`);
  if (artifacts.untracked !== undefined) parts.push(`untracked: ${artifacts.untracked}`);
  if (Array.isArray(artifacts.unmeasured) && artifacts.unmeasured.length > 0) {
    parts.push(`unmeasured: ${artifacts.unmeasured.join(', ')}`);
  }
  return parts.join('  ');
}

/// The notification half: the same measured facts the completion outbox's own notice carries, so that
/// this message IS the notification and the outbox one is redundant (the sentinel writes the marker the
/// outbox reads while this hook is enabled).
function notificationLine(event) {
  const child = event.notification && event.notification.child ? event.notification.child : {};
  const session = event.notification && event.notification.session ? event.notification.session : {};
  const parts = [];
  const model = child.served_model || child.model;
  if (model) parts.push(`model: ${model}`);
  if (child.provider) parts.push(`provider: ${child.provider}`);
  if (child.reasoning) parts.push(`reasoning: ${child.reasoning}`);
  if (child.profile) parts.push(`profile: ${child.profile}`);
  if (child.error) parts.push(`child_error: ${child.error}`);
  if (session.duration_s !== undefined) parts.push(`duration_s: ${session.duration_s}`);
  if (event.notification && event.notification.usage) parts.push(`usage: ${JSON.stringify(event.notification.usage)}`);
  if (event.notification && event.notification.review) parts.push(`outbox_review: ${JSON.stringify(event.notification.review)}`);
  return parts.length > 0 ? parts.join('  ') : 'model/usage NOT REPORTED by the child record';
}

function changedLine(event) {
  const source = event.changed_paths_source ? ` (${event.changed_paths_source})` : '';
  if (Array.isArray(event.changed_paths)) {
    const shown = event.changed_paths.slice(0, MAX_PATHS).join(', ');
    const more = event.changed_paths.length > MAX_PATHS ? `, ... +${event.changed_paths.length - MAX_PATHS} more` : '';
    const uncommitted = Array.isArray(event.uncommitted_paths) && event.uncommitted_paths.length > 0
      ? `  uncommitted: ${event.uncommitted_paths.slice(0, MAX_PATHS).join(', ')}`
      : '';
    return `changed paths vs origin/main: ${event.changed_paths.length}${source}: ${shown}${more}${uncommitted}`;
  }
  return `changed paths vs origin/main: NOT MEASURED${source}: ${event.changed_paths_error || 'not reported'}`;
}

function headLine(event) {
  if (!event.worktree_head) return null;
  if (event.head_moved && event.head_moved.recorded && event.head_moved.current) {
    return `worktree head: ${event.head_moved.current} (moved since the settle: recorded ${event.head_moved.recorded})`;
  }
  return `worktree head: ${event.worktree_head}`;
}

/// The verdict for one recorded child, and why. The unmeasurable cases are named one by one rather than
/// collapsed into "no install impact".
export function childReturnVerdict(event, shipped) {
  const manifest = shipped && shipped.manifest ? shipped.manifest : shipped;
  const manifestError = shipped && shipped.error;
  if (!event || typeof event !== 'object') {
    return {verdict: VERDICT.unknown, reason: 'no_child_record', shipped: [], shipped_count: 0, paths: 0};
  }
  if (manifestError) {
    return {verdict: VERDICT.unknown, reason: manifestError, shipped: [], shipped_count: 0, paths: 0};
  }
  const artifacts = event.artifacts;
  if (!artifacts || artifacts.available === false) {
    return {
      verdict: VERDICT.unknown,
      reason: `artifacts_unreadable: ${(artifacts && artifacts.reason) || 'the child record carries no artifacts'}`,
      shipped: [], shipped_count: 0, paths: 0,
    };
  }
  if (!Array.isArray(event.changed_paths)) {
    return {
      verdict: VERDICT.unknown,
      reason: `changed_paths_unmeasured: ${event.changed_paths_error || 'not reported'}`,
      shipped: [], shipped_count: 0, paths: 0,
    };
  }
  return deployVerdict(event.changed_paths, manifest);
}

export function instructionBlock(event, shipped = loadShipped()) {
  const facts = event || {};
  const state = String(facts.state || 'unknown');
  const decided = childReturnVerdict(facts, shipped);
  const lines = [
    `${BLOCK_HEADER} deterministic child-return hook (no model call fires it; this block is measured).`,
    `child: ${facts.child_id || 'NOT REPORTED'}   state: ${state}   settled: ${facts.settled === false ? 'no' : 'yes'}`,
    `notification: ${notificationLine(facts)}`,
    `session: ${facts.session || 'NOT REPORTED'}   parent: ${facts.parent_session || 'NOT REPORTED'}`,
    artifactLine(facts.artifacts),
    changedLine(facts),
  ];
  const head = headLine(facts);
  if (head) lines.push(head);
  lines.push(`DEPLOY VERDICT: ${decided.verdict}${decided.reason ? ` (${decided.reason})` : ''}`);
  lines.push(`OPERATING INSTRUCTION: ${OPERATING_INSTRUCTION[decided.verdict]}`);
  return {instruction: lines.join('\n'), verdict: decided.verdict, reason: decided.reason || null,
    shipped_count: decided.shipped_count, child_id: facts.child_id || null, state};
}

// ---------------------------------------------------------------------------------------------
// Measuring a child's own tree.
//
// Three measurements, and all three are load-bearing:
//   * the merge base with the integration branch - without one the diff below cannot be taken, and the
//     answer is `cannot be computed` rather than a whole-tree diff of two unrelated histories;
//   * `git diff --name-only <merge-base> <tip>` - what the child's own commits would add to main;
//   * `git status --porcelain` - the uncommitted half, which a tip-only diff cannot see. A child whose
//     tip equals main and whose worktree holds an uncommitted shipped change has install impact.
function parseStatus(text) {
  const paths = [];
  for (const line of String(text).split(/\r?\n/)) {
    if (line.trim() === '') continue;
    let entry = line.slice(3).trim();
    const rename = entry.split(' -> ');
    entry = rename[rename.length - 1];
    if (entry.startsWith('"') && entry.endsWith('"')) entry = entry.slice(1, -1);
    if (entry !== '') paths.push(entry);
    if (paths.length >= 2000) break;
  }
  return paths;
}

export function measureChangedPaths(worktree, tip) {
  if (!worktree) return {error: 'no_worktree_recorded'};
  const target = tip || 'HEAD';
  const run = (args) => spawnSync('git', ['-C', worktree, ...args], {encoding: 'utf8', timeout: 60000, windowsHide: true});
  let mainRef = 'refs/remotes/origin/main';
  if (run(['rev-parse', '--verify', '--quiet', mainRef]).status !== 0) {
    mainRef = 'refs/heads/main';
    if (run(['rev-parse', '--verify', '--quiet', mainRef]).status !== 0) {
      return {error: 'no_main_ref_in_child_worktree'};
    }
  }
  const mergeBase = run(['merge-base', mainRef, target]);
  if (mergeBase.status !== 0 || mergeBase.stdout.trim() === '') {
    // No common ancestor: the three-dot diff has no base to stand on. A two-dot whole-tree diff would
    // answer "what is different between two unrelated trees", which is not what a deploy verdict is
    // about - it reported "no install impact" for exactly this case, which is why there is no fallback.
    return {error: 'no_merge_base_with_origin_main'};
  }
  const base = mergeBase.stdout.trim();
  const committed = run(['diff', '--name-only', base, target]);
  if (committed.status !== 0) {
    return {error: `git_diff_failed: ${String(committed.stderr || '').trim().slice(0, 200)}`};
  }
  // `--untracked-files=all`: a brand-new directory is otherwise reported as `?? dir/`, which names a
  // directory the verdict has to guess about instead of the files the deploy would install.
  const status = run(['status', '--porcelain', '--untracked-files=all']);
  if (status.status !== 0) {
    return {error: `git_status_failed: ${String(status.stderr || '').trim().slice(0, 200)}`};
  }
  const head = run(['rev-parse', 'HEAD']);
  const committedPaths = committed.stdout.split(/\r?\n/).filter(Boolean);
  const uncommittedPaths = parseStatus(status.stdout);
  const union = [...new Set([...committedPaths, ...uncommittedPaths])];
  return {
    paths: union,
    committed_paths: committedPaths,
    uncommitted_paths: uncommittedPaths,
    merge_base: base,
    head: head.status === 0 ? head.stdout.trim() : null,
    source: `git -C ${worktree} diff --name-only ${base}...${target} + git -C ${worktree} status --porcelain`,
  };
}

// ---------------------------------------------------------------------------------------------
function nodeBaseUrl(options) {
  if (options.node) return options.node.replace(/\/$/, '');
  // The same default the sentinel itself uses (`node_port()` in rust/wa-sentinel/src/main.rs).
  const port = process.env.WASM_AGENT_PORT || '8799';
  return `http://127.0.0.1:${port}`;
}

async function callNode(options, body) {
  const response = await fetch(`${nodeBaseUrl(options)}/subagents`, {
    method: 'POST',
    headers: {'content-type': 'application/json', 'x-wa-session': process.env.WA_SENTINEL_AUTH_SESSION || ''},
    body: JSON.stringify(body),
  });
  const text = await response.text();
  return {status: response.status, text};
}

function statePath(options) {
  if (options.state) return options.state;
  if (process.env.WA_SENTINEL_RETURN_STATE) return process.env.WA_SENTINEL_RETURN_STATE;
  // The same directory the sentinel keeps its own state in (`config_dir()` in rust/wa-sentinel/src/main.rs
  // is `home()/.wasm-agent`, and `sentinel_dir()` is `sentinel` under it), so the cursor sits beside the
  // job store it is a cursor for.
  const home = process.env.WASM_AGENT_HOME || process.env.USERPROFILE || os.homedir();
  return path.join(home, '.wasm-agent', 'sentinel', 'subagent-return-reported.json');
}

function emptyState() {
  return {schema: SCHEMA, reported: {}, pending: {}};
}

function readState(file) {
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (!parsed || typeof parsed !== 'object') return emptyState();
    return {schema: SCHEMA, reported: parsed.reported || {}, pending: parsed.pending || {}};
  } catch {
    return emptyState();
  }
}

function writeState(file, state) {
  fs.mkdirSync(path.dirname(file), {recursive: true});
  const temporary = `${file}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(state, null, 2));
  fs.renameSync(temporary, file);
}

function sentinelCli(options, args) {
  const result = spawnSync(options.emitCommand, ['job', ...args], {encoding: 'utf8', timeout: 60000, windowsHide: true});
  if (result.status !== 0) {
    return {error: String(result.stderr || result.stdout || result.error?.message || 'sentinel job call failed').trim()};
  }
  try {
    return {value: JSON.parse(result.stdout)};
  } catch (error) {
    return {error: `sentinel answered nothing usable: ${String(result.stdout).trim().slice(0, 200)}`};
  }
}

function eventIdFor(childId) {
  // The child's own id, and nothing else: the store's dedupe is UNIQUE(job_id,revision,event_id), and a
  // per-pass component here would make every pass a new event. The suite pins this by deleting the cursor
  // and requiring the second pass to emit nothing.
  return String(childId);
}

function emitEvent(options, childId, payload) {
  const file = path.join(os.tmpdir(), `subagent-return-${process.pid}-${Date.now()}.json`);
  fs.writeFileSync(file, JSON.stringify(payload));
  try {
    const answer = sentinelCli(options, ['emit', TOPIC, eventIdFor(childId), file]);
    if (answer.error) return {queued: 0, error: answer.error};
    return {queued: Number(answer.value.queued || 0)};
  } finally {
    fs.rmSync(file, {force: true});
  }
}

/// Ask the store whether the effect for this exact (job, revision, event) already exists. This is what
/// makes the pass converge: a crash between the emit and the cursor write leaves an intent, and the next
/// pass observes the effect instead of emitting again for ever.
function effectExists(options, revision, childId, payload) {
  const file = path.join(os.tmpdir(), `subagent-return-receipt-${process.pid}-${Date.now()}.json`);
  fs.writeFileSync(file, JSON.stringify(payload));
  try {
    const answer = sentinelCli(options, ['receipt', HOOK_JOB, String(revision), eventIdFor(childId), file]);
    if (answer.error) return {error: answer.error};
    const receipt = answer.value.receipt || {};
    return {acknowledged: receipt.acknowledged === true, current: answer.value.current === true,
      reason: receipt.reason || null, state: receipt.state || null};
  } finally {
    fs.rmSync(file, {force: true});
  }
}

function completionOf(view, listed) {
  const raw = (view && view.completion) || (listed && listed.completion);
  if (!raw) return null;
  if (typeof raw === 'object') return raw;
  try { return JSON.parse(String(raw)); } catch { return null; }
}

function packetOf(completion) {
  const packet = completion && completion.packet;
  if (!packet) return null;
  if (typeof packet === 'object') return packet;
  try { return JSON.parse(String(packet)); } catch { return null; }
}

/// Build the event for one settled child: the recorded facts (what the node wrote down when it settled),
/// the measured facts (what the pass could see in the child's own checkout), and nothing invented.
function childEvent(task, view, completion) {
  const packet = packetOf(completion);
  const artifacts = packet && packet.artifacts ? packet.artifacts : {available: false, reason: 'completion_packet_absent'};
  const measured = artifacts && artifacts.available !== false
    ? measureChangedPaths(artifacts.worktree, artifacts.head)
    : {error: 'artifacts_unreadable'};
  const recordedDirty = Number(artifacts.dirty || 0) + Number(artifacts.untracked || 0);
  const event = {
    schema: SCHEMA,
    child_id: String(task.subagent_id || task.id || ''),
    state: String(task.state || 'unknown'),
    settled: true,
    session: (packet && packet.session && packet.session.id) || view.session_id || task.session_id || '',
    parent_session: (packet && packet.session && packet.session.parent) || view.parent_session_id || task.parent_session_id || '',
    profile: view.profile || task.profile || '',
    execution_node: view.execution_node || task.execution_node || 'local',
    child_completion_state: completion ? completion.state : null,
    artifacts,
    notification: {
      child: (packet && packet.child) || {},
      session: (packet && packet.session) || {},
      usage: (packet && packet.usage) || null,
      review: (packet && packet.review) || null,
    },
  };
  if (Array.isArray(measured.paths)) {
    event.changed_paths = measured.paths;
    event.committed_paths = measured.committed_paths;
    event.uncommitted_paths = measured.uncommitted_paths;
    event.changed_paths_source = measured.source;
    event.merge_base = measured.merge_base;
    event.worktree_head = measured.head;
    if (measured.head && artifacts.head && measured.head !== artifacts.head) {
      event.head_moved = {recorded: artifacts.head, current: measured.head};
    }
    // The recorded checkout said there was uncommitted work, and this pass could not see any: the two
    // facts disagree, and the disagreement is a refusal to answer rather than an answer.
    if (recordedDirty > 0 && measured.uncommitted_paths.length === 0) {
      delete event.changed_paths;
      event.changed_paths_error = `uncommitted_work_reported_but_not_measurable: recorded dirty+untracked=${recordedDirty}`;
    }
  } else {
    event.changed_paths_error = measured.error;
  }
  return event;
}

async function observe(options) {
  const file = statePath(options);
  const state = readState(file);
  const report = {schema: SCHEMA, observed: 0, settled: 0, emitted: 0, duplicates: 0, reconciled: 0,
    known: 0, unreadable: [], errors: [], source: nodeBaseUrl(options)};
  let listing;
  try {
    listing = await callNode(options, {action: 'list'});
  } catch (error) {
    report.reason = `node_unreachable: ${String(error.message || error)}`;
    return report;
  }
  if (listing.status !== 200) {
    report.reason = `node_refused_the_child_list: HTTP ${listing.status} ${listing.text.slice(0, 200)}`;
    return report;
  }
  let parsed;
  try {
    parsed = JSON.parse(listing.text);
  } catch (error) {
    throw Object.assign(new Error(`the node's child list is not JSON: ${String(error.message)}`), {code: 4});
  }
  if (parsed.error) {
    report.reason = `node_refused_the_child_list: ${parsed.error}`;
    return report;
  }
  const tasks = Array.isArray(parsed.subagents) ? parsed.subagents : null;
  if (!tasks) throw Object.assign(new Error('the node answered /subagents without a subagents list'), {code: 4});
  report.observed = tasks.length;
  // The hook job's own revision, resolved once per pass and before any intent is written: the store's
  // receipt is scoped to a revision, and an intent that carried `null` could never be reconciled (it made
  // a child sit in `pending` for ever, reporting `receipt_unavailable: invalid digit found in string`).
  let hookRevision;
  const revisionOf = () => {
    if (hookRevision === undefined) {
      const listed = sentinelCli(options, ['list']);
      const hook = listed.value && Array.isArray(listed.value) ? listed.value.find((job) => job.id === HOOK_JOB) : null;
      hookRevision = hook && Number.isInteger(hook.revision) ? hook.revision : null;
      if (hookRevision === null) report.errors.push(`hook_revision_unavailable: ${listed.error || 'the job is not in the store'}`);
    }
    return hookRevision;
  };
  for (const task of tasks.slice(0, options.limit)) {
    const childId = String(task.subagent_id || task.id || '');
    const state_name = String(task.state || 'unknown');
    const settled = task.settled === true || SETTLED_STATES.has(state_name);
    if (!childId || !settled) continue;
    report.settled += 1;
    if (state.reported[childId]) {
      report.known += 1;
      continue;
    }
    let view = task;
    try {
      const answer = await callNode(options, {action: 'status', id: childId});
      if (answer.status === 200) view = JSON.parse(answer.text);
    } catch (error) {
      report.errors.push(`${childId}: status_unavailable: ${String(error.message || error)}`);
    }
    const event = childEvent(task, view, completionOf(view, task));
    if (!event.session || !event.artifacts || event.artifacts.available === false) report.unreadable.push(childId);
    // Reconcile an intent from an earlier pass before emitting anything for this child again.
    const pending = state.pending[childId];
    if (pending) {
      const revision = Number.isInteger(pending.revision) ? pending.revision : revisionOf();
      if (revision === null) {
        report.errors.push(`${childId}: intent_revision_unavailable; emitting again`);
      } else {
        // The receipt compares the payload that was actually emitted, not the one this pass just
        // recomputed: a measurement that moved between the two (a child's worktree gains a file) would make
        // `payload_match` false, and the intent would be re-emitted on every tick for ever - deduped, so no
        // extra wake, but never settled.
        const receipt = effectExists(options, revision, childId, pending.payload || event);
        if (receipt.acknowledged) {
          state.reported[childId] = {state: state_name, at: new Date().toISOString(), via: 'receipt', revision};
          delete state.pending[childId];
          report.reconciled += 1;
          continue;
        }
        if (receipt.error) report.errors.push(`${childId}: receipt_unavailable: ${receipt.error}`);
      }
    }
    // A durable intent precedes the emission, so a crash between the two is recoverable.
    const revision = Number.isInteger(pending && pending.revision) ? pending.revision : revisionOf();
    state.pending[childId] = {event_id: eventIdFor(childId), at: new Date().toISOString(), revision, payload: event};
    writeState(file, state);
    const emitted = emitEvent(options, childId, event);
    if (emitted.queued > 0) {
      report.emitted += emitted.queued;
      state.reported[childId] = {state: state_name, at: new Date().toISOString(), via: 'emit', revision};
      delete state.pending[childId];
    } else if (emitted.error) {
      report.errors.push(`${childId}: ${emitted.error}`);
    } else {
      // The store answered "this exact event already exists" (queued 0). Confirm it through the receipt
      // so the cursor converges instead of re-emitting this child on every tick for ever.
      report.duplicates += 1;
      if (revision === null) {
        report.errors.push(`${childId}: receipt_unavailable: the hook's revision could not be read`);
      } else {
        const receipt = effectExists(options, revision, childId, event);
        if (receipt.acknowledged) {
          state.reported[childId] = {state: state_name, at: new Date().toISOString(), via: 'receipt', revision};
          delete state.pending[childId];
          report.reconciled += 1;
        } else if (receipt.error) {
          report.errors.push(`${childId}: receipt_unavailable: ${receipt.error}`);
        }
      }
    }
    writeState(file, state);
  }
  writeState(file, state);
  return report;
}

function compose(options) {
  const file = options.event || process.env.WA_JOB_EVENT_FILE;
  if (!file) throw Object.assign(new Error('--compose needs --event <file> (or WA_JOB_EVENT_FILE)'), {code: 4});
  const event = JSON.parse(fs.readFileSync(file, 'utf8'));
  const shipped = loadShipped(options.manifest || manifestPath());
  const block = instructionBlock(event, shipped);
  return {schema: SCHEMA, ...block, shipped_manifest: shipped.error || shipped.file};
}

// ---------------------------------------------------------------------------------------------
function parse(argv) {
  const options = {
    mode: null, event: null, node: null, limit: 64, state: null, manifest: null,
    emitCommand: process.env.WA_SENTINEL_BIN || 'wa-sentinel', paths: [], json: null,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === '--observe') options.mode = 'observe';
    else if (token === '--compose') options.mode = 'compose';
    else if (token === '--verdict') options.mode = 'verdict';
    else if (token === '--event') options.event = argv[++index];
    else if (token === '--node') options.node = argv[++index];
    else if (token === '--limit') options.limit = Number(argv[++index]);
    else if (token === '--state') options.state = argv[++index];
    else if (token === '--manifest') options.manifest = argv[++index];
    else if (token === '--emit-command') options.emitCommand = argv[++index];
    else if (token === '--path') options.paths.push(argv[++index]);
    else if (token === '--json') options.json = argv[++index];
    else if (token === '--paths-file') options.paths.push(...JSON.parse(fs.readFileSync(argv[++index], 'utf8')));
    else throw Object.assign(new Error(`unknown option ${token}`), {code: 4});
  }
  if (!options.mode) throw Object.assign(new Error('one of --observe, --compose or --verdict is required'), {code: 4});
  return options;
}

function print(value, options) {
  const text = JSON.stringify(value, null, 2);
  if (options.json) fs.writeFileSync(options.json, `${text}\n`);
  process.stdout.write(`${text}\n`);
}

export async function main(argv = process.argv.slice(2)) {
  const options = parse(argv);
  if (options.mode === 'verdict') {
    const shipped = loadShipped(options.manifest || manifestPath());
    if (shipped.error) {
      print({schema: SCHEMA, verdict: VERDICT.unknown, reason: shipped.error, shipped: [], shipped_count: 0, paths: options.paths.length}, options);
      return 0;
    }
    print({schema: SCHEMA, ...deployVerdict(options.paths, shipped.manifest), shipped_manifest: shipped.file}, options);
    return 0;
  }
  if (options.mode === 'compose') {
    print(compose(options), options);
    return 0;
  }
  const report = await observe(options);
  print(report, options);
  if (report.errors.length > 0) {
    // A child whose record could not be read is reported in the wake itself (the block says
    // "artifacts unreadable"); the pass still completed, so it exits 0 and `job history` stays readable.
    process.stderr.write(`${report.errors.length} child record(s) could not be read in full: ${report.errors.join(' | ')}\n`);
  }
  return 0;
}

// Importable by `scripts/check-deploy-shipped.mjs` and the suite: the module does work only when it is
// the program that was started.
if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().then((code) => { process.exitCode = code; }).catch((error) => {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = error.code === 4 ? 4 : 1;
  });
}
