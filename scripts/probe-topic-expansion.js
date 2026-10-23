// Focused probe: ONLY thinking topics print expanded.
//
// Operator's rule (2026-10-23): a thinking topic (`wa-reasoning`) stays open unless the reader folds it;
// EVERY other topic - a tool-call step, a decision step, commentary, `wa-diff`, `wa-summary`,
// `wa-steering` - is created collapsed and stays collapsed until the reader opens it. The final answer
// is exempt (it is not a topic). A failed tool call may open its topic once so the error is visible.
//
// WHY IT IS CARRIED BY A FACT, NOT A TAG NAME. A decision step and the calls it chose live in the SAME
// `<wa-trace>` element (`addDecision`/`addTool`), so "is this a decision topic?" cannot be answered by
// looking at the element's name - the element is also what a step that ONLY called a tool looks like.
// The element carries `data-decision="true"` when it took a decision; that fact labels the step
// ("deciding…") and is never used to open it. `markDecision`, the `addTool` promotion and `finish` all
// leave `open` alone; only the reader's toggle (and the one failed-call opening in `settle`) moves it.
//
// Run with the disposable observer (it serves a copy of ui/ with test-fixtures.js injected, in real
// headless Chrome, and writes screenshot.png + dom.html):
//
//   node scripts/agent-benchmark-ui-observe.mjs --out "$TEMP/ui-topics" \
//     --probe scripts/probe-topic-expansion.js
//
// The probe ends with a live stage: thinking open; commentary, decision and tool-call topics collapsed;
// a failed tool topic open once. The main-chat route is exercised through `handleEvent`, the child-pane
// route through `withChildRenderer` - the same renderer and the same component.
(async function () {
  var report = document.createElement('pre');
  report.id = 'wa-probe';
  report.style.display = 'none';
  document.body.append(report);
  var checks = 0;
  function check(ok, label) { if (!ok) throw Error(label); checks++; }
  function tick() { return Promise.resolve(); }
  try {
    await window.rendererLoaded;
    for (var i = 0; i < 200 && !transcriptReady; i++) await tick();
    check(transcriptReady, 'startup ready');
    var now = Date.now();
    var run = 'collapse-run';
    busy = false; activeRunId = null; observedRun = { session: chatSession, run_id: 911 };
    repaintMessages([], { active: true, notify: false });

    // ---- A. THE LIVE MAIN CHAT: EVERY TOOL/DECISION STEP STARTS AND STAYS COLLAPSED -------------
    // 1. A step that only calls a tool: collapsed at spawn, through the result, and at finish.
    handleEvent({ type: 'round', n: 1, run_id: run });
    handleEvent({ type: 'reasoning', text: 'Weighing the options before deciding.', chars: 37 });
    handleEvent({ type: 'tool', call_id: 'plain-call', name: 'bash', arguments: { command: 'ls' } });
    var bubble = runBubble;
    check(!!bubble, 'the live run has a bubble');
    function traceOf(callId) {
      return Array.prototype.slice.call(bubble.querySelectorAll('wa-trace')).filter(function (node) {
        return !!node.querySelector('[data-call-id="' + callId + '"]');
      })[0] || null;
    }
    var thinking = bubble.querySelector('wa-reasoning');
    check(!!thinking && thinking.open === true,
      'a thinking topic prints expanded and only the reader closes it, saw open=' + (thinking && thinking.open));
    var plain = traceOf('plain-call');
    check(!!plain && plain.dataset.decision !== 'true',
      'a plain tool-call topic carries no decision fact, saw data-decision=' + (plain && JSON.stringify(plain.dataset.decision)));
    check(!!plain && plain.open === false,
      'a live tool-call topic is created COLLAPSED, saw open=' + (plain && plain.open));
    handleEvent({ type: 'tool_result', name: 'bash', result: { code: 0, stdout: 'done' } });
    check(!!plain && plain.open === false,
      'a tool-call topic stays collapsed through tool_result, saw open=' + (plain && plain.open));
    handleEvent({ type: 'round', n: 2, run_id: run });
    check(!!plain && plain.open === false,
      'a tool-call topic stays collapsed through finish, saw open=' + (plain && plain.open));
    check(!!plain && plain._userToggled !== true,
      'no automatic opening pretends to be the reader choice on a tool topic');

    // 2. A decision step: prose, the provider's `decision` event, then the call it chose. The same
    // element is promoted from "forming" to "running"; none of those events may open it.
    handleEvent({ type: 'commentary', text: 'Checking the ledger first.', message_id: 'commentary-1' });
    handleEvent({ type: 'decision', call_id: 'chosen-call', name: 'read',
      arguments_text: '{"path":"review/ledger.json"}', complete: false });
    var decision = bubble.querySelector('wa-trace[data-decision="true"]');
    check(!!decision, 'the decision step carries the fact on the element, saw none');
    check(decision !== plain, 'a decision after a settled step is a topic of its own');
    check(decision.open === false,
      'a decision topic is created COLLAPSED, saw open=' + decision.open);
    handleEvent({ type: 'decision', call_id: 'chosen-call', name: 'read',
      arguments_text: '{"path":"review/ledger.json"}', complete: true });
    check(decision.open === false,
      'a second decision event for the same call does not open it, saw open=' + decision.open);
    handleEvent({ type: 'tool', call_id: 'chosen-call', name: 'read',
      arguments: { path: 'review/ledger.json' } });
    check(decision.open === false,
      'promoting the chosen call to a running one does not open the decision topic, saw open=' + decision.open);
    handleEvent({ type: 'tool_result', name: 'read', result: { code: 0, stdout: 'ok' } });
    check(decision.open === false,
      'a decision topic stays collapsed through tool_result, saw open=' + decision.open);
    handleEvent({ type: 'round', n: 3, run_id: run });
    check(decision.open === false,
      'a decision topic stays collapsed through finish, saw open=' + decision.open);

    // 3. A decision event with no tool call: it is still a collapsed topic, before and after finish.
    handleEvent({ type: 'decision', call_id: 'decision-only', name: 'bash',
      arguments_text: '{"command":"true"}', complete: true });
    var decisionOnly = traceOf('decision-only');
    check(!!decisionOnly && decisionOnly !== decision,
      'a decision event with no tool call is a topic of its own');
    check(decisionOnly.dataset.decision === 'true',
      'a decision-only step still carries its decision fact');
    check(decisionOnly.open === false,
      'a decision event with no tool call does not auto-open its topic, saw open=' + decisionOnly.open);
    handleEvent({ type: 'round', n: 4, run_id: run });
    check(decisionOnly.open === false,
      'a decision-only topic stays collapsed through finish, saw open=' + decisionOnly.open);

    // 4. The one automatic opening left: a failed call makes its own error visible once. It is shared
    // by the main chat and a child pane because both call this same `settle`; the reader still wins,
    // and finish() does not re-open anything.
    handleEvent({ type: 'tool', call_id: 'failed-call', name: 'bash', arguments: { command: 'false' } });
    var failed = traceOf('failed-call');
    check(!!failed && failed.open === false, 'a failed call starts as a collapsed tool topic');
    handleEvent({ type: 'tool_result', name: 'bash', result: { code: 1, stderr: 'boom' }, failed: true });
    check(!!failed && failed.open === true,
      'a failed tool opens its topic once so the error is visible, saw open=' + (failed && failed.open));
    handleEvent({ type: 'round', n: 5, run_id: run });
    check(!!failed && failed.open === true,
      'finish keeps a failed topic open, saw open=' + (failed && failed.open));

    // ---- B. THE READER'S OWN CHOICE, IN BOTH DIRECTIONS, THROUGH LATER PASSES -------------------
    plain.toggle();
    check(plain.open === true, 'the reader can open a tool-call topic');
    handleEvent({ type: 'status', text: 'model' });
    handleEvent({ type: 'round', n: 6, run_id: run });
    check(plain.open === true,
      'a later pass keeps the tool topic the reader opened open, saw open=' + plain.open);
    decision.toggle();
    check(decision.open === true, 'the reader can open a decision topic');
    handleEvent({ type: 'status', text: 'model' });
    handleEvent({ type: 'round', n: 7, run_id: run });
    check(decision.open === true,
      'a later pass keeps the decision topic the reader opened open, saw open=' + decision.open);
    decisionOnly.toggle();
    check(decisionOnly.open === true, 'the reader can open a decision-only topic');
    decisionOnly.toggle();
    check(decisionOnly.open === false, 'the reader can close a decision-only topic');
    failed.toggle();
    check(failed.open === false, 'the reader can close the failed topic');

    // ---- B2. THE OTHER TOPICS THE RULE NAMES ARE CREATED COLLAPSED ------------------------------
    handleEvent({ type: 'steering', id: 'steer-1', state: 'queued', text: 'Use the corrected requirement' });
    var steering = bubble.querySelector('wa-steering');
    check(!!steering && steering.open === false,
      'a steering receipt is created collapsed, saw open=' + (steering && steering.open));
    handleEvent({ type: 'run_counts', counts: { kind: 'run_counts', version: 1, run_id: run,
      model_calls: 2, tool_calls: 2,
      summary_step: { version: 1, id: 'summary-1', started_at: now / 1000, state: 'running', model: 'fixture' } } });
    var summary = bubble.querySelector('wa-summary');
    check(!!summary && summary.open === false,
      'a summarizing topic is created collapsed, saw open=' + (summary && summary.open));
    var diff = renderDiff(bubble, { files: [{ path: 'ui/app.js', added: 2, removed: 1 }] });
    check(!!diff && diff.open === false,
      'a change topic is created collapsed, saw open=' + (diff && diff.open));

    // The fold at the answer is the pass that used to open everything it swallowed (`reveal()`).
    handleEvent({ type: 'delta', text: 'The answer.' });
    handleEvent({ type: 'reply', text: 'The answer.', message_id: 'collapse-answer' });
    handleEvent({ type: 'done' });
    var runTopic = bubble.querySelector('wa-run');
    check(!!runTopic && runTopic.open === false, 'the run topic itself still folds at the answer');
    check(plain.open === true,
      'the fold does not close the tool topic the reader opened, saw open=' + plain.open);
    check(decision.open === true,
      'the fold does not close the decision topic the reader opened, saw open=' + decision.open);
    check(decisionOnly.open === false,
      'the fold does not reopen a decision topic the reader closed, saw open=' + decisionOnly.open);
    check(failed.open === false,
      'the fold does not reopen a failed topic the reader closed, saw open=' + failed.open);
    var commentary = bubble.querySelector('wa-commentary');
    check(!!commentary && commentary.open === false,
      'a commentary is created COLLAPSED and stays collapsed, saw open=' + (commentary && commentary.open));
    check(!!thinking && thinking.open === true,
      'and the thinking is still open after the fold, saw open=' + (thinking && thinking.open));

    // ---- C. A REPAINT: THE ROWS REBUILD THE TOPICS, THE READER KEEPS THEIR CHOICE ----------------
    busy = false; activeRunId = null; observedRun = null;
    var rows = [
      { id: 'u1', seq: 1, role: 'user', content: 'read the ledger', created_at: now / 1000, trace: [] },
      { id: 'a1', seq: 2, role: 'assistant', content: '',
        tool_calls: [{ id: 'replay-call', type: 'function',
          function: { name: 'read', arguments: '{"path":"review/ledger.json"}' } }],
        created_at: now / 1000, trace: [] },
      { id: 't1', seq: 3, role: 'tool', tool_call_id: 'replay-call', tool_name: 'read', ok: 1,
        content: 'ok', created_at: now / 1000, trace: [] },
      { id: 'a2', seq: 4, role: 'assistant', content: 'Done.', created_at: now / 1000, trace: [] }
    ];
    repaintMessages(rows, { state: 'answered', notify: false });
    var replayed = transcript.querySelector('wa-trace');
    check(!!replayed, 'a stored tool call is drawn as a tool topic');
    check(replayed.open === false, 'and a repaint draws that tool topic collapsed');
    replayed.toggle();
    check(replayed.open === true, 'the reader opens it on the replayed transcript');
    repaintMessages(rows, { state: 'answered', notify: false });
    var reopened = transcript.querySelector('wa-trace');
    check(!!reopened && reopened.open === true,
      'a later repaint keeps a tool topic the reader opened, saw open=' + (reopened && reopened.open));
    reopened.toggle();
    repaintMessages(rows, { state: 'answered', notify: false });
    var closed = transcript.querySelector('wa-trace');
    check(!!closed && closed.open === false,
      'and keeps a tool topic the reader closed closed, saw open=' + (closed && closed.open));
  } catch (error) {
    report.dataset.status = 'fail';
    report.textContent = 'TOPIC-EXPANSION FAIL: ' + String(error && error.stack ? error.stack : error) +
      ' (checks passed before the failure: ' + checks + ')';
    return;
  }

  // ---- D. THE STAGE THE IMAGE IS READ FROM -----------------------------------------------------
  // Main chat is section A (the real `handleEvent` route); this stage draws the same events through
  // the child-pane renderer (`withChildRenderer`). Both use the same <wa-trace> component and the
  // same decision event leaves the topic collapsed in both. Live, so the picture shows the rule rather
  // than a folded run: thinking open; commentary, decision and tool-call topics collapsed; the failed
  // tool topic open once.
  try {
    var stage = document.createElement('div');
    stage.id = 'wa-stage';
    stage.style.cssText = 'position:fixed;left:0;right:0;bottom:0;z-index:900;max-height:62vh;' +
      'overflow:auto;background:#0b0d12;border-top:1px solid #2a3040;padding:8px 12px;' +
      'color:#cfd6e4;font:12px/1.5 ui-monospace,monospace;';
    document.documentElement.append(stage);
    function caption(text) {
      var line = document.createElement('div');
      line.style.cssText = 'margin:6px 0 2px;color:#8bbcff;';
      line.textContent = text;
      stage.append(line);
    }
    function stamp(node) {
      var box = node.getBoundingClientRect();
      return Math.round(box.width) + 'x' + Math.round(box.height);
    }
    var pane = document.createElement('div');
    stage.append(pane);
    withChildRenderer(pane, { session_id: 'probe-topics', subagent_id: 'topics', state: 'running', settled: false },
      function () {
        var events = [
          { type: 'round', n: 1, run_id: 'stage-run' },
          { type: 'reasoning', text: 'Weighing the options before deciding.', chars: 37 },
          { type: 'commentary', text: 'Checking the ledger first.', message_id: 'stage-commentary' },
          { type: 'decision', call_id: 'stage-chosen', name: 'read',
            arguments_text: '{"path":"review/ledger.json"}', complete: true },
          { type: 'tool', call_id: 'stage-chosen', name: 'read', arguments: { path: 'review/ledger.json' } },
          { type: 'tool_result', name: 'read', result: { code: 0, stdout: 'ok' } },
          { type: 'round', n: 2, run_id: 'stage-run' },
          { type: 'decision', call_id: 'stage-only', name: 'bash',
            arguments_text: '{"command":"true"}', complete: true },
          { type: 'round', n: 3, run_id: 'stage-run' },
          { type: 'tool', call_id: 'stage-plain', name: 'bash', arguments: { command: 'ls' } },
          { type: 'round', n: 4, run_id: 'stage-run' },
          { type: 'tool', call_id: 'stage-failed', name: 'bash', arguments: { command: 'false' } },
          { type: 'tool_result', name: 'bash', result: { code: 1, stderr: 'boom' }, failed: true }
        ];
        for (var index = 0; index < events.length; index++) window.handleEvent(events[index]);
      });
    var stageThinking = pane.querySelector('wa-reasoning');
    var stageCommentary = pane.querySelector('wa-commentary');
    var stageTraces = Array.prototype.slice.call(pane.querySelectorAll('wa-trace'));
    var stageDecisions = stageTraces.filter(function (node) { return node.dataset.decision === 'true'; });
    var stagePlain = stageTraces.filter(function (node) { return node.dataset.decision !== 'true'; })[0] || null;
    var stageFailed = null;
    for (var t = 0; t < stageTraces.length; t++) {
      if (stageTraces[t].querySelector('[data-call-id="stage-failed"]')) stageFailed = stageTraces[t];
    }
    check(!!stageThinking && stageThinking.open === true,
      'stage: the thinking is drawn open');
    check(stageDecisions.length === 2,
      'stage: both decision steps carry the fact in the child pane, saw ' + stageDecisions.length);
    check(stageDecisions.every(function (node) { return node.open === false; }),
      'stage: the child pane leaves every decision topic COLLAPSED');
    check(!!stagePlain && stagePlain.open === false,
      'stage: the tool-call topic is drawn collapsed');
    check(!!stageCommentary && stageCommentary.open === false,
      'stage: the commentary is drawn collapsed');
    // Collapsed means only the header is shown: every decision body and the plain tool body are hidden.
    var collapsedBodies = stageDecisions.map(function (node) { return node.querySelector('.trace-body'); });
    collapsedBodies.push(stagePlain && stagePlain.querySelector('.trace-body'));
    check(collapsedBodies.every(function (body) { return !!body && body.hidden === true; }),
      'stage: collapsed topics show their header and hide their body');
    // The one automatic opening is shared: the child pane's failed tool topic is open once, and its
    // body is really visible, not merely an `open` attribute on a hidden body.
    var stageFailedBody = stageFailed && stageFailed.querySelector('.trace-body');
    check(!!stageFailed && stageFailed.open === true && !!stageFailedBody && stageFailedBody.hidden === false,
      'stage: the child pane opens a failed tool topic once so its error is visible');
    // Same component, same reader choice: opening a child decision topic does not fold it again.
    var stageReader = stageDecisions[0];
    stageReader.toggle();
    check(stageReader.open === true, 'stage: the reader can open a child decision topic');
    caption('thinking ' + stamp(stageThinking) + ' open \u00b7 commentary ' + stamp(stageCommentary) +
      ' collapsed \u00b7 decision ' + stamp(stageDecisions[0]) + ' collapsed \u00b7 tool-call topic ' +
      stamp(stagePlain) + ' collapsed \u00b7 failed tool ' + stamp(stageFailed) + ' open once');
  } catch (error) {
    report.dataset.status = 'fail';
    report.textContent = 'TOPIC-EXPANSION FAIL (stage): ' + String(error && error.stack ? error.stack : error) +
      ' (checks passed before the stage failure: ' + checks + ')';
    return;
  }
  report.dataset.status = 'pass';
  report.textContent = JSON.stringify({ checks: checks, skipped: 0 });
})();
