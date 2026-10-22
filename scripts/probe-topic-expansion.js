// Focused probe: ONLY thinking and decision topics print expanded.
//
// Operator's rule: a thinking topic (`wa-reasoning`) stays open unless the reader folds it, a DECISION
// topic - a step whose prose ended in a tool call - prints expanded, and EVERY other topic (tool-call
// topics, commentary, `wa-diff`, `wa-summary`, `wa-steering`) is created collapsed and stays collapsed
// unless the reader opens it. The reader's own fold wins in both directions, in every later pass.
//
// WHY IT IS CARRIED BY A FACT, NOT A TAG NAME. A decision and the calls it chose live in the SAME
// `<wa-trace>` element (`addDecision`/`addTool`), so "is this a decision topic?" cannot be answered by
// looking at the element's name - the element is also what a step that ONLY called a tool looks like.
// The element carries `data-decision="true"` when it took a decision; `addTool`, `settle` and `finish`
// read that fact, and a repaint re-applies the reader's own choice.
//
// Run with the disposable observer (it serves a copy of ui/ with test-fixtures.js injected, in real
// headless Chrome, and writes screenshot.png + dom.html):
//
//   node scripts/agent-benchmark-ui-observe.mjs --out "$TEMP/ui-topics" \
//     --probe scripts/probe-topic-expansion.js
//
// The probe ends with a live stage, so the image shows the rule itself: thinking open, commentary
// collapsed, decision topic expanded, tool-call topic collapsed.
(async function () {
  var report = document.createElement('pre');
  report.id = 'wa-probe';
  report.style.display = 'none';
  document.body.append(report);
  var checks = 0;
  function check(ok, label) { if (!ok) throw Error(label); checks++; }
  function topics(node, selector) { return Array.prototype.slice.call(node.querySelectorAll(selector)); }
  try {
    await window.rendererLoaded;
    for (var i = 0; i < 200 && !transcriptReady; i++) await new Promise(function (resolve) { setTimeout(resolve, 10); });
    check(transcriptReady, 'startup ready');
    var now = Date.now();
    var run = 'expansion-run';
    busy = false; activeRunId = null; observedRun = { session: chatSession, run_id: 911 };
    repaintMessages([], { active: true, notify: false });

    // ---- A. THE LIVE RUN: ONE STEP OF EACH KIND ------------------------------------------------
    // A step that streams thinking and then calls a tool with NO decision before it: this is the
    // tool-call topic the rule is about, and the FIRST thing this probe asks about it.
    handleEvent({ type: 'round', n: 1, run_id: run });
    handleEvent({ type: 'reasoning', text: 'Weighing the options before deciding.', chars: 37 });
    handleEvent({ type: 'tool', call_id: 'plain-call', name: 'bash', arguments: { command: 'ls' } });
    var bubble = runBubble;
    check(!!bubble, 'the live run has a bubble');
    var thinking = bubble.querySelector('wa-reasoning');
    var plain = bubble.querySelector('wa-trace');
    check(!!thinking && thinking.open === true,
      'a thinking topic prints expanded and only the reader closes it, saw open=' + (thinking && thinking.open));
    check(!!plain && plain.dataset.decision !== 'true',
      'a tool-call topic carries no decision fact, saw data-decision=' + (plain && JSON.stringify(plain.dataset.decision)));
    check(!!plain && plain.open === false,
      'a live tool-call topic is created COLLAPSED, saw open=' + (plain && plain.open));
    handleEvent({ type: 'tool_result', name: 'bash', result: { code: 0, stdout: 'done' } });
    // The step ends (a round boundary flushes the trace): it is still collapsed.
    handleEvent({ type: 'round', n: 2, run_id: run });
    check(!!plain && plain.open === false,
      'a tool-call topic stays collapsed when its step ends, saw open=' + (plain && plain.open));

    // A decision: prose, then the call the step chose. The call is promoted from "forming" to
    // "running" in the SAME element - it must not flip the topic closed.
    handleEvent({ type: 'commentary', text: 'Checking the ledger first.', message_id: 'commentary-1' });
    handleEvent({ type: 'decision', call_id: 'chosen-call', name: 'read',
      arguments_text: '{"path":"review/ledger.json"}', complete: false });
    handleEvent({ type: 'decision', call_id: 'chosen-call', name: 'read',
      arguments_text: '{"path":"review/ledger.json"}', complete: true });
    handleEvent({ type: 'tool', call_id: 'chosen-call', name: 'read',
      arguments: { path: 'review/ledger.json' } });
    var commentary = bubble.querySelector('wa-commentary');
    var decision = bubble.querySelector('wa-trace[data-decision="true"]');
    check(!!commentary && commentary.open === false,
      'a commentary is created COLLAPSED, saw open=' + (commentary && commentary.open));
    check(!!decision, 'the decision topic carries the fact on the element, saw none');
    check(decision !== plain, 'a decision after a settled step is a topic of its own');
    check(!!decision && decision.open === true,
      'a decision topic prints expanded, saw open=' + (decision && decision.open));
    handleEvent({ type: 'tool_result', name: 'read', result: { code: 0, stdout: 'ok' } });
    check(!!decision && decision.open === true,
      'promoting the chosen call to a running one does not close the decision topic');
    // The step ends (a round boundary flushes the trace): the decision topic stays expanded.
    handleEvent({ type: 'round', n: 3, run_id: run });
    check(!!decision && decision.open === true,
      'a decision topic stays expanded when its step ends, saw open=' + (decision && decision.open));

    // ---- B. THE READER'S OWN CHOICE, IN BOTH DIRECTIONS, THROUGH LATER PASSES -------------------
    plain.toggle();
    check(plain.open === true, 'the reader can open a tool-call topic');
    handleEvent({ type: 'status', text: 'model' });
    handleEvent({ type: 'round', n: 4, run_id: run });
    check(plain.open === true,
      'a later pass keeps the tool topic the reader opened open, saw open=' + plain.open);
    decision.toggle();
    check(decision.open === false, 'the reader can close a decision topic');

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
    handleEvent({ type: 'reply', text: 'The answer.', message_id: 'expansion-answer' });
    handleEvent({ type: 'done' });
    var runTopic = bubble.querySelector('wa-run');
    check(!!runTopic && runTopic.open === false, 'the run topic itself still folds at the answer');
    check(decision.open === false,
      'the fold does not reopen a decision topic the reader closed, saw open=' + decision.open);
    check(plain.open === true,
      'and does not close the tool topic the reader opened, saw open=' + plain.open);
    check(!!commentary && commentary.open === false,
      'a commentary is still collapsed after the fold, saw open=' + (commentary && commentary.open));
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
  // Live, so the picture shows the rule rather than a folded run: thinking open, commentary collapsed,
  // a decision topic expanded, a tool-call topic collapsed.
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
          { type: 'tool', call_id: 'stage-plain', name: 'bash', arguments: { command: 'ls' } }
        ];
        for (var index = 0; index < events.length; index++) window.handleEvent(events[index]);
      });
    var stageThinking = pane.querySelector('wa-reasoning');
    var stageCommentary = pane.querySelector('wa-commentary');
    var stageDecision = pane.querySelector('wa-trace[data-decision="true"]');
    var stagePlain = Array.prototype.slice.call(pane.querySelectorAll('wa-trace'))
      .filter(function (node) { return node !== stageDecision; })[0] || null;
    check(!!stageDecision && stageDecision.open === true,
      'stage: the decision topic is drawn expanded');
    check(!!stagePlain && stagePlain.open === false,
      'stage: the tool-call topic is drawn collapsed');
    check(!!stageCommentary && stageCommentary.open === false,
      'stage: the commentary is drawn collapsed');
    check(!!stageThinking && stageThinking.open === true,
      'stage: the thinking is drawn open');
    // The image is only evidence if the topics are really laid out: a collapsed topic shows its header
    // and hides its body, so the decision's body (its arguments) is the only step text in the picture.
    var stageDecisionBody = stageDecision && stageDecision.querySelector('.trace-body');
    var stagePlainBody = stagePlain && stagePlain.querySelector('.trace-body');
    check(!!stageDecisionBody && !!stagePlainBody && stageDecisionBody.hidden === false && stagePlainBody.hidden === true,
      'stage: expanded means the body is shown, collapsed means only the header is, saw decision=' +
      (stageDecisionBody && stageDecisionBody.hidden) + ' tool=' + (stagePlainBody && stagePlainBody.hidden));
    caption('thinking ' + stamp(stageThinking) + ' open \u00b7 commentary ' + stamp(stageCommentary) +
      ' collapsed \u00b7 decision ' + stamp(stageDecision) + ' expanded \u00b7 tool-call topic ' +
      stamp(stagePlain) + ' collapsed');
  } catch (error) {
    report.dataset.status = 'fail';
    report.textContent = 'TOPIC-EXPANSION FAIL (stage): ' + String(error && error.stack ? error.stack : error) +
      ' (checks passed before the stage failure: ' + checks + ')';
    return;
  }
  report.dataset.status = 'pass';
  report.textContent = JSON.stringify({ checks: checks, skipped: 0 });
})();
