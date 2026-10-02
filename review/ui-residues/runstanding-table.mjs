#!/usr/bin/env node
// The decision table for `runStanding`, taken from the source that actually ships.
//
// Why this exists: the delivery's claim is that ONE function decides whether the run this window is
// watching is over, and that only `over` may end the stream. The claims that matter are therefore about
// *which inputs* map to `over`. Reading the function and reasoning about it is not evidence; this extracts
// the function bodies from `ui/app.js` byte for byte (and prints their sha256 so the extraction can be
// checked), evaluates them with the real semantics of `activeRun`/`threadOfRun`, and prints the verdict
// for every shape the review was asked to try.
//
// Nothing here re-implements the decision: the three functions are copied out of the delivered file.
import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const appPath = path.join(repo, 'ui', 'app.js');
const source = fs.readFileSync(appPath, 'utf8');
const sha = (text) => crypto.createHash('sha256').update(text, 'utf8').digest('hex');

// Extract one top-level `function name(...) {` on one header line ... the matching `}` in column 0.
// The header is taken to the end of its line deliberately: a default parameter (`view = {}`) contains a
// brace, so "the first brace after the name" is not the body.
function extract(name) {
  const start = source.indexOf(`function ${name}(`);
  if (start < 0) throw Error(`no function ${name} in ui/app.js`);
  const header = source.slice(start, source.indexOf('\n', start));
  if (!header.endsWith('{')) throw Error(`${name}: header is not one line ending in a brace: ${header}`);
  let depth = 0, index = start + header.length - 1;
  for (; index < source.length; index += 1) {
    const ch = source[index];
    if (ch === '{') depth += 1;
    else if (ch === '}') {
      depth -= 1;
      if (depth === 0) {
        const text = source.slice(start, index + 1);
        if (!text.endsWith('\n}') && !text.endsWith('}')) throw Error(`${name}: odd tail`);
        return text;
      }
    }
  }
  throw Error(`${name}: unbalanced`);
}

const parts = ['activeRun', 'threadOfRun', 'runStanding'].map((name) => {
  const text = extract(name);
  return {name, text, sha256: sha(text), lines: text.split('\n').length};
});
if (/function\s+\w+\(/.test(parts[2].text.slice(parts[2].text.indexOf('\n')))) throw Error('runStanding extraction ran past its end');

const sandbox = new Function(`${parts[0].text}\n${parts[1].text}\n${parts[2].text}\nreturn {activeRun, threadOfRun, runStanding};`);
const {runStanding} = sandbox();

const S = 'conversation-mine';
const OTHER = 'conversation-other';
const health = (extra) => ({ok: true, queue: 0, stalled_ms: 0, current: null, node_threads: [], run_ids: [], ...extra});
const busyThreadElsewhere = {label: 'POST /chat', busy_ms: 9100, session: OTHER};
const myThread = {label: 'POST /chat', busy_ms: 9100, session: S, run_id: 771001};
const view = (extra) => ({session: S, runId: null, submitted: new Set(), finished: false, ...extra});

// Kept: the stream and the notice this window owns stay alive. Over: the notice is printed and the
// stream is aborted. `finished` is silent (the caller already returned before the decision).
const keeps = (verdict) => verdict === 'running' || verdict === 'busy-unknown';

const cases = [
  // ---- claim 1, the incident itself -------------------------------------------------------------
  {name: 'incident: busy node, a thread it cannot match to this conversation, no run id',
    health: health({worker: 'busy', node_threads: [busyThreadElsewhere]}), view: view(),
    expect: 'busy-unknown', expectKeep: true,
    note: 'the owner\'s shape: the fix must keep waiting'},
  {name: 'negative control (non-vacuity): idle node, no thread, no run of this conversation',
    health: health({worker: 'alive'}), view: view(),
    expect: 'over', expectKeep: false, note: 'a genuinely over run must still be reported'},
  {name: 'finished: this window watched the run end',
    health: health({worker: 'busy', node_threads: [busyThreadElsewhere]}), view: view({finished: true}),
    expect: 'finished', expectKeep: false, note: 'silent: nothing to say about an answered run'},

  // ---- the same incident one beat later ---------------------------------------------------------
  {name: 'INCIDENT + worker "alive" (the same node inside a host call: the aggregate is the beat age)',
    health: health({worker: 'alive', node_threads: [busyThreadElsewhere]}), view: view(),
    expect: null, expectKeep: null,
    note: 'a node-thread is executing POST /chat for another conversation right now; worker "alive" is the aggregate for a thread that beat inside the last second (serve.rs health_body), so the SAME run answers "busy" or "alive" depending on which side of the beat the poll lands'},
  {name: 'INCIDENT + worker "alive" + no node_threads at all (a member-less /health body)',
    health: health({worker: 'alive'}), view: view({session: S}),
    expect: null, expectKeep: null, note: 'indistinguishable from the negative control: the check cannot be non-vacuous and safe here'},
  {name: 'INCIDENT + worker missing (a node older than the field)', health: health({node_threads: [busyThreadElsewhere]}),
    view: view(), expect: null, expectKeep: null, note: 'the last branch treats "no word" as idle'},
  {name: 'INCIDENT + worker "stalled"', health: health({worker: 'stalled', node_threads: [busyThreadElsewhere]}),
    view: view(), expect: 'busy-unknown', expectKeep: true, note: 'keeps waiting'},

  // ---- identification paths the fix relies on ---------------------------------------------------
  {name: 'a node-thread on this conversation', health: health({worker: 'busy', node_threads: [myThread]}),
    view: view(), expect: 'running', expectKeep: true, note: 'activeRun'},
  {name: 'no thread on this conversation, but a thread carrying the accepted run id',
    health: health({worker: 'busy', node_threads: [{label: 'POST /chat', busy_ms: 9, session: OTHER, run_id: 42}]}),
    view: view({runId: 42}), expect: 'running', expectKeep: true, note: 'threadOfRun'},
  {name: 'the accepted run id is on current, not on a node_thread',
    health: health({worker: 'busy', current: {label: 'POST /chat', ms: 9, session: OTHER, run_id: 42}}),
    view: view({runId: 42}), expect: 'running', expectKeep: true, note: 'threadOfRun reads current too'},
  {name: 'the accepted run is in run_ids as running', health: health({worker: 'busy', run_ids: [{conversation: S, run_id: 42, state: 'running'}]}),
    view: view({runId: 42}), expect: 'running', expectKeep: true, note: 'the node\'s own record'},
  {name: 'the accepted run is in run_ids as not_started', health: health({worker: 'busy', run_ids: [{conversation: S, run_id: 42, state: 'not_started'}]}),
    view: view({runId: 42}), expect: 'running', expectKeep: true, note: 'queued counts as live'},
  {name: 'the accepted run is in run_ids as completed', health: health({worker: 'busy', run_ids: [{conversation: S, run_id: 42, state: 'completed'}]}),
    view: view({runId: 42}), expect: 'over', expectKeep: false, note: 'correct: this run ended'},
  {name: 'the accepted run is in run_ids as unknown (evidence lost)',
    health: health({worker: 'busy', run_ids: [{conversation: S, run_id: 42, state: 'unknown'}]}),
    view: view({runId: 42}), expect: 'over', expectKeep: false, note: 'the recovery notice\'s real job'},
  {name: 'a live run of this conversation the window did not submit',
    health: health({worker: 'busy', run_ids: [{conversation: S, run_id: 42, state: 'running'}]}),
    view: view({submitted: new Set([41])}), expect: 'running', expectKeep: true, note: 'the third `running` route'},
  {name: 'the SAME live run, but it was in the pre-submit baseline (`submitted`)',
    health: health({worker: 'alive', run_ids: [{conversation: S, run_id: 42, state: 'running'}]}),
    view: view({submitted: new Set([42])}), expect: null, expectKeep: null,
    note: 'the baseline exists to tell its queued id from an older run; a RESUMED run (send with resumeSeq) is itself in the baseline, so the node\'s list saying "running" is discarded and the worker word decides'},
  {name: 'the same, worker busy', health: health({worker: 'busy', run_ids: [{conversation: S, run_id: 42, state: 'running'}]}),
    view: view({submitted: new Set([42])}), expect: 'busy-unknown', expectKeep: true, note: 'saved only by the worker word'},

  // ---- id / thread identity ---------------------------------------------------------------------
  {name: 'run id reuse: a FOREIGN conversation\'s run carries the accepted number, terminal',
    health: health({worker: 'busy', run_ids: [{conversation: OTHER, run_id: 42, state: 'completed'}]}),
    view: view({runId: 42}), expect: null, expectKeep: null,
    note: 'the lookup matches the number only, not the conversation; run ids come from the journal (or, with no journal, from a counter that restarts at 0 per process), so a number is not proof of ownership across a restart'},
  {name: 'run id reuse, the foreign run live', health: health({worker: 'busy', run_ids: [{conversation: OTHER, run_id: 42, state: 'running'}]}),
    view: view({runId: 42}), expect: 'running', expectKeep: true, note: 'safe direction'},
  {name: 'thread id reused: the busy thread carries a stale session (not this conversation)',
    health: health({worker: 'busy', node_threads: [{id: 0, label: 'POST /chat', busy_ms: 20000, session: OTHER, run_id: 7}]}),
    view: view({runId: 7}), expect: 'running', expectKeep: true, note: 'threadOfRun ignores the session, so this is saved by the run id alone'},
  {name: 'two conversations of the same window: watching B, A is busy',
    health: health({worker: 'busy', node_threads: [{label: 'POST /chat', busy_ms: 500, session: 'A'}]}),
    view: view({session: 'B'}), expect: 'busy-unknown', expectKeep: true, note: 'the fix\'s own design case'},
  {name: 'two conversations of the same window: watching B, A is busy, worker alive',
    health: health({worker: 'alive', node_threads: [{label: 'POST /chat', busy_ms: 500, session: 'A'}]}),
    view: view({session: 'B'}), expect: null, expectKeep: null, note: 'the same hole as the incident row'},
  {name: 'a stalled worker, this conversation\'s thread present and carrying the run id',
    health: health({worker: 'stalled', node_threads: [myThread]}), view: view(),
    expect: 'running', expectKeep: true,
    note: 'the old code treated stalled+my-thread as NOT running and printed the notice; now a run the node calls stalled is never reported over by this check'},
  {name: 'a stalled worker, this conversation\'s thread present, no run id, run_ids live',
    health: health({worker: 'stalled', node_threads: [{label: 'POST /chat', session: S}], run_ids: [{conversation: S, run_id: 42, state: 'running'}]}),
    view: view(), expect: 'running', expectKeep: true, note: 'same narrowing'},
  {name: 'no run_ids at all (an older node), worker busy, no thread',
    health: health({worker: 'busy'}), view: view(), expect: 'busy-unknown', expectKeep: true, note: 'safe'},
  {name: 'no run_ids at all (an older node), worker alive, no thread',
    health: health({worker: 'alive'}), view: view(), expect: null, expectKeep: null, note: 'the negative control again'},
];

let failures = 0, misses = 0;
console.log(`ui/app.js sha256 ${sha(source)}  (${source.split('\n').length} lines)`);
for (const part of parts) console.log(`  ${part.name}: ${part.lines} line(s), sha256 ${part.sha256}`);
console.log('');
for (const item of cases) {
  const verdict = runStanding(item.health, item.view);
  const keepsStream = keeps(verdict);
  const marked = item.expect === null ? 'OBSERVED' : (verdict === item.expect ? 'matches-expected' : 'UNEXPECTED');
  if (item.expect !== null && verdict !== item.expect) failures += 1;
  if (item.expectKeep !== null && keepsStream !== item.expectKeep) failures += 1;
  if (item.expect === null && !keepsStream) misses += 1;
  console.log(`${verdict.padEnd(12)} ${marked.padEnd(17)} ${item.name}`);
  console.log(`             -> ${keepsStream ? 'KEEPS the stream' : 'ENDS the stream'}; ${item.note}`);
}
console.log('');
console.log(`${cases.length} shapes: ${failures} disagreed with their stated expectation, ${misses} of them END a stream the page cannot contradict`);
process.exitCode = failures ? 1 : 0;
