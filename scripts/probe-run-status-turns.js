// Focused probe: the live run-status row carries a TURN COUNTER.
//
// Operator's row (2026-11-x): `• ↻2 👣17·10s ⚒17 ◈~28.6k ◷2:25` - the counter stands immediately
// after the activity glyph and before the first measurement, in the live row and in the finished
// footer, in the main chat and in a child pane (one renderer).
//
// WHAT IS A TURN. One run of the agent, and one run is one `run_id` - never a user message and never
// a provider step (one turn is many steps). The probe drives two runs in ONE transcript, each `round`
// carrying its own `run_id`, and then replays a transcript whose rows carry two run ids in their
// `run_counts` traces. The count must be the number of DISTINCT run ids, and `↻?` when nothing has
// named a run yet (an unknown count is not `0`).
//
// Run with the disposable observer (it serves a copy of ui/ with test-fixtures.js injected, in real
// headless Chrome, and writes screenshot.png + dom.html):
//
//   node scripts/agent-benchmark-ui-observe.mjs --out "$TEMP/ui-turns" \
//     --probe scripts/probe-run-status-turns.js
//
// The probe ends with a stage the screenshot is read from: a child pane holding TWO live runs, so
// the image shows the row itself - `↻2` between the glyph and the clock.
(async function () {
  var report = document.createElement('pre');
  report.id = 'wa-probe';
  report.style.display = 'none';
  document.body.append(report);
  var checks = 0;
  function check(ok, label) { if (!ok) throw Error(label); checks++; }
  function liveRow() { return transcript.querySelector('.chat-content-run-status:not(.finished)'); }
  function liveTurns() {
    var node = liveRow() ? liveRow().querySelector('.chat-content-run-turns') : null;
    return node ? node.textContent.trim() : 'absent';
  }
  function footerTurns(root) {
    return Array.prototype.map.call(
      (root || transcript).querySelectorAll('.chat-content-run-status.finished .chat-content-run-turns'),
      function (node) { return node.textContent.trim(); }).join('|');
  }
  function counts(run, models, tools, extra) {
    return Object.assign({ kind: 'run_counts', version: 1, run_id: run,
      model_calls: models, tool_calls: tools }, extra || {});
  }
  try {
    await window.rendererLoaded;
    for (var i = 0; i < 200 && !transcriptReady; i++) await new Promise(function (resolve) { setTimeout(resolve, 10); });
    check(transcriptReady, 'startup ready');
    var now = Date.now();
    busy = false; activeRunId = null; observedRun = { session: chatSession, run_id: 901 };

    // ---- A. NOTHING KNOWN IS NOT ZERO ----------------------------------------------------------
    // A row that has never seen a run must say so. `↻0` would be a measurement the window never
    // made, and it would read as "this session ran no turns" over a transcript it has not loaded.
    repaintMessages([], { active: true, notify: false });
    handleEvent({ type: 'status', text: 'model' });
    check(liveTurns() === '↻?',
      'a row with no run named yet reads an unknown count, never zero, saw ' + JSON.stringify(liveTurns()));
    var bare = liveRow();
    check(!!bare && bare.children.length > 2 &&
      bare.children[0].classList.contains('run-activity-glyph') &&
      bare.children[1].classList.contains('chat-content-run-turns'),
      'the counter is its own element immediately after the activity glyph, saw ' +
      (bare ? Array.prototype.map.call(bare.children, function (n) { return n.className; }).join(',') : 'no row'));
    check(!!bare && !bare.querySelector('.chat-content-run-calls .chat-content-run-turns') &&
      !bare.querySelector('.chat-content-run-elapsed .chat-content-run-turns'),
      'and it is not string-appended into either stats half');

    // ---- B. TURN ONE ---------------------------------------------------------------------------
    handleEvent({ type: 'round', n: 1, run_id: 'run-one' });
    handleEvent({ type: 'run_counts', counts: counts('run-one', 1, 0) });
    check(liveTurns() === '↻1',
      'the first run of a session reads one turn, saw ' + JSON.stringify(liveTurns()));
    check(/^\S ↻1 \S/.test(liveRow().textContent),
      'and it stands before the first measurement, saw ' + JSON.stringify(liveRow().textContent));
    handleEvent({ type: 'delta', text: 'First turn answer.' });
    handleEvent({ type: 'reply', text: 'First turn answer.', message_id: 'turn-one-answer' });
    handleEvent({ type: 'done' });
    var firstFooter = transcript.querySelector('.chat-content-run-status.finished');
    check(!!firstFooter && footerTurns() === '↻1',
      'the finished footer keeps the counter of the turn it closes, saw ' + JSON.stringify(footerTurns()));
    check(!!firstFooter && firstFooter.children[0].classList.contains('chat-content-run-turns'),
      'with the activity glyph gone the counter still stands first, saw ' +
      (firstFooter ? firstFooter.innerHTML.slice(0, 160) : 'no footer'));

    // ---- C. A SECOND RUN IN THE SAME TRANSCRIPT IS A SECOND TURN -------------------------------
    handleEvent({ type: 'round', n: 1, run_id: 'run-two' });
    handleEvent({ type: 'status', text: 'model' });
    handleEvent({ type: 'run_counts', counts: counts('run-two', 1, 0) });
    check(liveTurns() === '↻2',
      'a second run of the same transcript reads two turns, saw ' + JSON.stringify(liveTurns()));
    // A repeated report of the SAME run is still one turn: the count is distinct run ids, so a
    // count snapshot, a retry of that snapshot and a later checkpoint cannot inflate it.
    handleEvent({ type: 'run_counts', counts: counts('run-two', 2, 0) });
    handleEvent({ type: 'round', n: 2, run_id: 'run-two' });
    check(liveTurns() === '↻2',
      'a second report of the same run does not add a turn, saw ' + JSON.stringify(liveTurns()));
    handleEvent({ type: 'delta', text: 'Second turn answer.' });
    handleEvent({ type: 'reply', text: 'Second turn answer.', message_id: 'turn-two-answer' });
    handleEvent({ type: 'done' });
    check(footerTurns() === '↻1|↻2',
      'each footer keeps the count its own run ended with, saw ' + JSON.stringify(footerTurns()));

    // ---- D. A REPLAYED TRANSCRIPT COUNTS ITSELF -------------------------------------------------
    // The durable half: a row's `run_counts` trace carries the run id, so a reload needs no live
    // event to know the session ran two turns. `run-alpha` is never named live by this probe.
    busy = false; activeRunId = null; observedRun = null;
    var rows = [
      { id: 'r1u', seq: 1, role: 'user', content: 'first question', created_at: (now - 68000) / 1000,
        trace: [counts('run-alpha', 0, 0)] },
      { id: 'r1a', seq: 2, role: 'assistant', content: 'first answer', created_at: now / 1000,
        trace: [counts('run-alpha', 2, 1, { complete: true, elapsed_ms: 68000 })] },
      { id: 'r2u', seq: 3, role: 'user', content: 'second question', created_at: now / 1000, trace: [] },
      { id: 'r2a', seq: 4, role: 'assistant', content: 'second answer', created_at: now / 1000,
        trace: [counts('run-beta', 1, 0, { complete: true, elapsed_ms: 1000 })] }
    ];
    repaintMessages(rows, { state: 'answered', notify: false });
    check(footerTurns() === '↻1|↻2',
      'a replayed transcript counts the distinct run ids its rows carry, saw ' + JSON.stringify(footerTurns()));
    repaintMessages([{ id: 'r1u', seq: 1, role: 'user', content: 'unmeasured question', created_at: now / 1000, trace: [] },
      { id: 'r1a0', seq: 2, role: 'assistant', content: 'answer with no counts', created_at: now / 1000, trace: [] }],
      { state: 'answered', notify: false });
    check(footerTurns() === '↻?',
      'a transcript whose rows name no run reads an unknown count, saw ' + JSON.stringify(footerTurns()));

    // ---- E. ONE RENDERER: A CHILD PANE COUNTS ITS OWN TRANSCRIPT --------------------------------
    var child = document.createElement('div');
    child.className = 'probe-child-turns';
    document.body.append(child);
    paintChildTranscript(child, rows, { notify: false });
    check(footerTurns(child) === '↻1|↻2',
      'a child pane counts its own rows with the same renderer, saw ' + JSON.stringify(footerTurns(child)));
    check(footerTurns() === '↻?',
      'and the child read never reaches the main chat, saw ' + JSON.stringify(footerTurns()));
    child.remove();
  } catch (error) {
    report.dataset.status = 'fail';
    report.textContent = 'RUN-STATUS-TURNS FAIL: ' + String(error && error.stack ? error.stack : error) +
      ' (checks passed before the failure: ' + checks + ')';
    return;
  }

  // ---- F. THE STAGE THE IMAGE IS READ FROM ------------------------------------------------------
  // The window keeps repainting its own transcript, so anything drawn into #messages is gone when
  // the screenshot is taken. This is the same renderer and the same `handleEvent`, run inside a
  // container the app does not own - exactly as a child pane is drawn - holding TWO runs, so the
  // picture shows the row the probe is about.
  try {
    var stage = document.createElement('div');
    stage.id = 'wa-stage';
    stage.style.cssText = 'position:fixed;left:0;right:0;bottom:0;z-index:900;max-height:60vh;' +
      'overflow:auto;background:#0b0d12;border-top:1px solid #2a3040;padding:8px 12px;' +
      'color:#cfd6e4;font:12px/1.5 ui-monospace,monospace;';
    document.documentElement.append(stage);
    function caption(text) {
      var line = document.createElement('div');
      line.style.cssText = 'margin:6px 0 2px;color:#8bbcff;';
      line.textContent = text;
      stage.append(line);
    }
    caption('two runs of one session, still live: the row must read \u21bb2 before its clock');
    var pane = document.createElement('div');
    stage.append(pane);
    withChildRenderer(pane, { session_id: 'probe-turns', subagent_id: 'turns', state: 'running', settled: false },
      function () {
        var events = [
          { type: 'round', n: 1, run_id: 'stage-run-one' },
          { type: 'run_counts', counts: counts('stage-run-one', 2, 1) },
          { type: 'status', text: 'model' },
          { type: 'tool', call_id: 'stage-call-one', name: 'read', arguments: { path: 'review/ledger.json' } },
          { type: 'tool_result', name: 'read', result: { code: 0, stdout: 'ok' } },
          { type: 'round', n: 2, run_id: 'stage-run-two' },
          { type: 'run_counts', counts: counts('stage-run-two', 3, 1) },
          { type: 'status', text: 'model' }
        ];
        for (var index = 0; index < events.length; index++) window.handleEvent(events[index]);
      });
    var paneTurns = pane.querySelector('.chat-content-run-status:not(.finished) .chat-content-run-turns');
    check(!!paneTurns && paneTurns.textContent.trim() === '↻2',
      'stage: a child pane holding two runs shows the count on its live row, saw ' +
      (paneTurns ? paneTurns.textContent : 'absent'));
    var paneRow = pane.querySelector('.chat-content-run-status:not(.finished)');
    caption('the row as it is drawn: ' + (paneRow ? paneRow.textContent.trim() : 'absent'));
  } catch (error) {
    report.dataset.status = 'fail';
    report.textContent = 'RUN-STATUS-TURNS FAIL (stage): ' + String(error && error.stack ? error.stack : error) +
      ' (checks passed before the stage failure: ' + checks + ')';
    return;
  }
  report.dataset.status = 'pass';
  report.textContent = JSON.stringify({ checks: checks, skipped: 0 });
})();
