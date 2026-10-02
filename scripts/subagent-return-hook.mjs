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
// recorded branch and worktree, diff it against `origin/main`, match the paths against the deploy's own
// shipped set, print a block. None of it needs an opinion, so none of it costs a model turn
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
//               child. The event id is the child's own id, so the job store's own dedupe
//               (UNIQUE(job_id,revision,event_id)) is what makes "one wake per settle" true - a poll
//               that runs every 30 s cannot wake anyone twice for the same child.
//
//   --compose   the `prepare` step of the `onSubagentReturn` job's wake action. Reads that event
//               (`WA_JOB_EVENT_FILE`) and prints the instruction block the sentinel injects into the
//               wake message. It makes no network call at all.
//
// Exit codes: 0 a completed pass (including one that could not report anything, which says so in one
// line with the numbers it did see - a closed source is an answer, not a failure); 4 usage, a
// reachable source that answered something unusable, or a state this cannot be recorded from.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

const SCHEMA = 1;
const TOPIC = 'subagent.return';
const BLOCK_HEADER = '[onSubagentReturn]';

// ---------------------------------------------------------------------------------------------
// THE DEPLOY RULE. One predicate, one place. A path is shipped when a deploy would install it.
//
// Derived from scripts/deploy.sh, which is the only thing that decides what a deploy copies:
//   * ui/**, rust/**, lua/**, skills/** are installed (the window, the node and supervisor binaries
//     built from rust/**, the embedded Lua core, and the skills the installed node loads);
//   * of scripts/**, a deploy copies `scripts/deploy.sh` and `scripts/lib/service-target.sh` (the
//     copies that perform the next deploy), every `scripts/whatsapp-*` file, the `scripts/lib/**`
//     modules those import, the `scripts/wave-*` continuation scripts (shipped by
//     scripts/ship-wave.mjs with their literal import closure), and this hook's own
//     `scripts/subagent-return-*` files, which are shipped for the `onSubagentReturn` job below.
//
// `scripts/lib/**` is included as a whole rather than as the exact import closure: the closure is
// computed by grep in deploy.sh (and by ship-wave.mjs for the wave scripts), so encoding it here
// would be a second, silently diverging copy of that rule. Over-inclusion errs toward "deploy
// required", which is the safe direction - the cost of a needless deploy is a deploy, the cost of a
// missed one is a node that runs code the deliverable does not contain.
const DEPLOY_SHIPPED_DIRECTORIES = ['ui/', 'rust/', 'lua/', 'skills/'];
const DEPLOY_SHIPPED_SCRIPTS = ['scripts/deploy.sh', 'scripts/lib/service-target.sh'];
const DEPLOY_SHIPPED_SCRIPT_PATTERNS = [
  /^scripts\/whatsapp-[^/]+$/,
  /^scripts\/lib\/[^/]+$/,
  /^scripts\/wave-[^/]+$/,
  /^scripts\/subagent-return-[^/]+$/,
];

// The verdicts. `unknown` is not a third flavour of "nothing to do": it exists so that a child whose
// artifacts could not be read can never be reported as having no install impact. "We could not look"
// and "we looked and there was nothing" are different answers, and only one of them is evidence.
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

// ---------------------------------------------------------------------------------------------
// The predicate.
function shipsToDeploy(candidate) {
  const file = String(candidate || '').replace(/\\/g, '/').replace(/^\.\//, '');
  if (file === '') return false;
  if (DEPLOY_SHIPPED_DIRECTORIES.some((directory) => file.startsWith(directory))) return true;
  if (DEPLOY_SHIPPED_SCRIPTS.includes(file)) return true;
  return DEPLOY_SHIPPED_SCRIPT_PATTERNS.some((pattern) => pattern.test(file));
}

function deployVerdict(paths) {
  const list = (paths || []).map((entry) => String(entry));
  const shipped = list.filter(shipsToDeploy);
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
  if (Array.isArray(artifacts.unmeasured) && artifacts.unmeasured.length > 0) {
    parts.push(`unmeasured: ${artifacts.unmeasured.join(', ')}`);
  }
  return parts.join('  ');
}

function changedLine(event) {
  const source = event.changed_paths_source ? ` (${event.changed_paths_source})` : '';
  if (Array.isArray(event.changed_paths)) {
    const shown = event.changed_paths.slice(0, MAX_PATHS).join(', ');
    const more = event.changed_paths.length > MAX_PATHS ? `, ... +${event.changed_paths.length - MAX_PATHS} more` : '';
    return `changed paths vs origin/main: ${event.changed_paths.length}${source}: ${shown}${more}`;
  }
  return `changed paths vs origin/main: NOT MEASURED${source}: ${event.changed_paths_error || 'not reported'}`;
}

/// The verdict for one recorded child, and why. The three unmeasurable cases are named one by one
/// rather than collapsed into "no install impact".
export function childReturnVerdict(event) {
  if (!event || typeof event !== 'object') {
    return {verdict: VERDICT.unknown, reason: 'no_child_record', shipped: [], shipped_count: 0, paths: 0};
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
  return deployVerdict(event.changed_paths);
}

export function instructionBlock(event) {
  const facts = event || {};
  const state = String(facts.state || 'unknown');
  const decided = childReturnVerdict(facts);
  const lines = [
    `${BLOCK_HEADER} deterministic child-return hook (no model call fires it; this block is measured).`,
    `child: ${facts.child_id || 'NOT REPORTED'}   state: ${state}   settled: ${facts.settled === false ? 'no' : 'yes'}`,
    `session: ${facts.session || 'NOT REPORTED'}   parent: ${facts.parent_session || 'NOT REPORTED'}`,
    artifactLine(facts.artifacts),
    changedLine(facts),
    `DEPLOY VERDICT: ${decided.verdict}${decided.reason ? ` (${decided.reason})` : ''}`,
    `OPERATING INSTRUCTION: ${OPERATING_INSTRUCTION[decided.verdict]}`,
  ];
  return {instruction: lines.join('\n'), verdict: decided.verdict, reason: decided.reason || null,
    shipped_count: decided.shipped_count, child_id: facts.child_id || null, state};
}

// ---------------------------------------------------------------------------------------------
// Measuring a child's own tree. `git diff --name-only origin/main...HEAD` is the child's side of the
// split since its merge base with the integration branch - what it would add to it. Both endpoints
// come from the child's *record*, never from a branch someone else may have moved on.
export function measureChangedPaths(worktree, tip) {
  if (!worktree) return {error: 'no_worktree_recorded'};
  const target = tip || 'HEAD';
  const run = (args) => spawnSync('git', ['-C', worktree, ...args], {encoding: 'utf8', timeout: 60000, windowsHide: true});
  const probe = run(['rev-parse', '--verify', '--quiet', 'refs/remotes/origin/main']);
  const base = probe.status === 0 ? 'refs/remotes/origin/main' : 'main';
  if (probe.status !== 0) {
    const local = run(['rev-parse', '--verify', '--quiet', 'refs/heads/main']);
    if (local.status !== 0) return {error: 'no_main_ref_in_child_worktree'};
  }
  const diff = run(['diff', '--name-only', `${base}...${target}`]);
  if (diff.status !== 0) {
    const retry = run(['diff', '--name-only', `${base}`, `${target}`]);
    if (retry.status !== 0) return {error: `git_diff_failed: ${String(diff.stderr || retry.stderr || '').trim().slice(0, 200)}`};
    return {paths: retry.stdout.split(/\r?\n/).filter(Boolean), source: `git -C ${worktree} diff --name-only ${base} ${target}`};
  }
  return {paths: diff.stdout.split(/\r?\n/).filter(Boolean), source: `git -C ${worktree} diff --name-only ${base}...${target}`};
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

function readState(file) {
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    return parsed && typeof parsed === 'object' && parsed.reported ? parsed : {reported: {}};
  } catch {
    return {reported: {}};
  }
}

function writeState(file, state) {
  fs.mkdirSync(path.dirname(file), {recursive: true});
  const temporary = `${file}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(state, null, 2));
  fs.renameSync(temporary, file);
}

/// One `wa-sentinel job emit`. The event id is the child's own id: the store's UNIQUE(job_id,
/// revision, event_id) is the dedupe, so a second pass over the same child enqueues nothing.
function emitEvent(options, childId, payload) {
  const file = path.join(os.tmpdir(), `subagent-return-${process.pid}-${Date.now()}.json`);
  fs.writeFileSync(file, JSON.stringify(payload));
  try {
    const result = spawnSync(options.emitCommand, ['job', 'emit', TOPIC, childId, file], {
      encoding: 'utf8', timeout: 60000, windowsHide: true,
    });
    if (result.status !== 0) {
      return {queued: 0, error: String(result.stderr || result.stdout || result.error?.message || 'emit failed').trim()};
    }
    try {
      return {queued: Number(JSON.parse(result.stdout).queued || 0)};
    } catch (error) {
      return {queued: 0, error: `emit answered nothing usable: ${String(result.stdout).trim().slice(0, 200)}`};
    }
  } finally {
    fs.rmSync(file, {force: true});
  }
}

function completionOf(view, listed) {
  const fromStatus = view && view.completion;
  const fromList = listed && listed.completion;
  const raw = fromStatus || fromList;
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

async function observe(options) {
  const seen = readState(statePath(options));
  const report = {schema: SCHEMA, observed: 0, settled: 0, emitted: 0, duplicates: 0, unreadable: [], errors: [], source: nodeBaseUrl(options)};
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
  for (const task of tasks.slice(0, options.limit)) {
    const childId = String(task.subagent_id || task.id || '');
    const state = String(task.state || 'unknown');
    const settled = task.settled === true || SETTLED_STATES.has(state);
    if (!childId || !settled) continue;
    report.settled += 1;
    if (seen.reported[childId]) continue;
    let view = task;
    try {
      const answer = await callNode(options, {action: 'status', id: childId});
      if (answer.status === 200) view = JSON.parse(answer.text);
    } catch (error) {
      report.errors.push(`${childId}: status_unavailable: ${String(error.message || error)}`);
    }
    const completion = completionOf(view, task);
    const packet = packetOf(completion);
    const artifacts = packet && packet.artifacts ? packet.artifacts : {available: false, reason: 'completion_packet_absent'};
    const worktree = artifacts && artifacts.available !== false ? artifacts.worktree : '';
    const tip = artifacts && artifacts.available !== false ? artifacts.head : '';
    const measured = worktree ? measureChangedPaths(worktree, tip) : {error: 'artifacts_unreadable'};
    const session = (packet && packet.session && packet.session.id) || view.session_id || task.session_id || '';
    const parent = (packet && packet.session && packet.session.parent) || view.parent_session_id || task.parent_session_id || '';
    const payload = {
      schema: SCHEMA,
      child_id: childId,
      state,
      settled: true,
      session,
      parent_session: parent,
      profile: view.profile || task.profile || '',
      execution_node: view.execution_node || task.execution_node || 'local',
      child_completion_state: completion ? completion.state : null,
      artifacts,
      recorded_report: completion ? completion.detail : null,
    };
    if (Array.isArray(measured.paths)) {
      payload.changed_paths = measured.paths;
      payload.changed_paths_source = measured.source;
    } else {
      payload.changed_paths_error = measured.error;
    }
    if (!payload.session || !worktree) report.unreadable.push(childId);
    const emitted = emitEvent(options, childId, payload);
    if (emitted.queued > 0) {
      report.emitted += emitted.queued;
      seen.reported[childId] = {state, at: new Date().toISOString()};
    } else if (emitted.error) {
      report.errors.push(`${childId}: ${emitted.error}`);
    } else {
      report.duplicates += 1;
    }
  }
  if (report.emitted > 0) writeState(statePath(options), seen);
  return report;
}

function compose(options) {
  const file = options.event || process.env.WA_JOB_EVENT_FILE;
  if (!file) throw Object.assign(new Error('--compose needs --event <file> (or WA_JOB_EVENT_FILE)'), {code: 4});
  const event = JSON.parse(fs.readFileSync(file, 'utf8'));
  const block = instructionBlock(event);
  return {schema: SCHEMA, ...block};
}

// ---------------------------------------------------------------------------------------------
function parse(argv) {
  const options = {
    mode: null, event: null, node: null, limit: 64, state: null,
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

async function main() {
  const options = parse(process.argv.slice(2));
  if (options.mode === 'verdict') {
    print({schema: SCHEMA, ...deployVerdict(options.paths)}, options);
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

main().then((code) => { process.exitCode = code; }).catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = error.code === 4 ? 4 : 1;
});
