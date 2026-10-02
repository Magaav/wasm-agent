// Steer/Cancel plumbing through the refactor, attacked end to end in the app's own path.
//
// The claim to break: a child pane's Steer and Cancel still reach the host's handler now that the
// buttons are built by `chatControl()` inside `<wa-chat-actions>` and announced as `chat-action`
// rather than bound one by one; the main chat's `#steer` by id still works; and a pane whose row is
// rebuilt (reconnected) neither double-fires nor loses its handler.
(async function () {
  var problems = [];
  var report = {};
  function check(ok, label) { if (!ok) problems.push(label); }
  function tick() { return Promise.race([Promise.resolve(), new Promise(function (r) { setTimeout(r, 0); })]); }
  async function until(fn, tries) { for (var i = 0; i < (tries || 400); i += 1) { if (fn()) return true; await tick(); } return false; }
  function drain(n) { return (async function () { for (var i = 0; i < (n || 30); i += 1) await tick(); })(); }
  function posts(filter) {
    return (window.__calls || []).filter(function (call) {
      if (call.method !== 'POST') return false;
      if (String(call.url).indexOf('subagents') < 0) return false;
      var body = {};
      try { body = JSON.parse(call.body); } catch (error) { body = {}; }
      return filter ? filter(body) : true;
    }).map(function (call) { return JSON.parse(call.body); });
  }

  await until(function () { return !!document.getElementById('attach'); }, 600);
  for (var i = 0; i < 150; i += 1) await tick();

  // A shell that records instead of acting, so nothing here reaches the desktop.
  var shell = window.__makeShell();
  native = shell;

  // ---- 1. the main chat's #steer, by id, on the built control ----------------------
  var mainSteer = document.getElementById('steer');
  report.mainSteer = mainSteer ? mainSteer.tagName + '#' + mainSteer.id + '.' + mainSteer.className : 'none';
  check(!!mainSteer && mainSteer.id === 'steer' && String(mainSteer.className).indexOf('chat-control') >= 0,
    'the main chat must keep #steer as the built control, saw ' + report.mainSteer);
  if (window.__fixtures && window.__fixtures.health && typeof chatSession !== 'undefined' && chatSession) {
    window.__fixtures.health.node_threads = [{ label: 'POST /chat', busy_ms: 15000, session: chatSession }];
  }
  setBusy(true);
  var mainInput = document.getElementById('input');
  mainInput.value = 'MAIN-STEER-TEXT';
  var before = posts(function (b) { return b.action === 'steer_session'; }).length;
  mainSteer.click();
  await drain(40);
  var mainPosts = posts(function (b) { return b.action === 'steer_session'; });
  report.mainSteerPosts = mainPosts.slice(before);
  check(mainPosts.length === before + 1 && mainPosts[before].session_id === chatSession &&
    mainPosts[before].text === 'MAIN-STEER-TEXT',
    'the main chat\'s #steer must reach steer_session with its own draft, saw ' +
    JSON.stringify(mainPosts.slice(before)));
  check(mainInput.value === '', 'an accepted steer must clear only the accepted draft, saw ' + JSON.stringify(mainInput.value));

  // ---- 2. a child pane's Steer and Cancel, through the row's own chat-action path ----
  mountOrchestrator();
  var panel = orchestratorPanel;
  check(!!panel, 'the app\'s own orchestrator handler must mount (mountOrchestrator)');
  var task = { subagent_id: 'review-child-1', session_id: 'review-session-1', profile: 'worker',
    model: 'fixture', reasoning: 'max', execution_node: 'cloud', state: 'running', created_at: 0,
    prompt: 'plumbing probe' };
  panel.data = [task];
  var pane = panel.pin(task);
  check(!!pane, 'the app must pin a child pane');
  await drain(40);
  var row = pane.querySelector('wa-chat-actions');
  var paneSteer = pane.querySelector('[data-action="steer"]');
  var paneCancel = pane.querySelector('[data-action="cancel"]');
  report.paneControls = {
    row: row ? row.tagName : 'none',
    steer: paneSteer ? paneSteer.tagName + '.' + paneSteer.className + (paneSteer.parentElement === row ? ' (in row)' : ' (NOT in row)') : 'none',
    cancel: paneCancel ? paneCancel.tagName + '.' + paneCancel.className : 'none',
    disabled: paneSteer ? paneSteer.disabled : null,
  };
  check(!!row && !!paneSteer && !!paneCancel && paneSteer.parentElement === row && paneCancel.parentElement === row,
    'the pane\'s actions must be the shared row\'s own controls, saw ' + JSON.stringify(report.paneControls));
  check(paneSteer && paneSteer.disabled === false,
    'a running child\'s Steer must be enabled (the app\'s own set task addresses it by data-action)');

  pane.input.value = 'PANE-STEER-TEXT';
  var seenDetail = null;
  if (row) row.addEventListener('chat-action', function (event) { seenDetail = event.detail; });
  var steerBefore = posts(function (b) { return b.action === 'steer'; }).length;
  paneSteer.click();
  await drain(40);
  report.chatActionDetail = seenDetail ? { action: seenDetail.action, controlIsTheBuiltOne: seenDetail.control === paneSteer } : null;
  check(!!seenDetail && seenDetail.action === 'steer' && seenDetail.control === paneSteer,
    'the row must announce {action, control} with the control that was clicked, saw ' + JSON.stringify(report.chatActionDetail));
  var steerPosts = posts(function (b) { return b.action === 'steer'; });
  report.paneSteerPosts = steerPosts.slice(steerBefore);
  check(steerPosts.length === steerBefore + 1,
    'one click on the pane\'s Steer must send exactly one request, saw ' + (steerPosts.length - steerBefore));
  check(steerPosts.length === steerBefore + 1 && steerPosts[steerBefore].id === 'review-child-1' &&
    steerPosts[steerBefore].text === 'PANE-STEER-TEXT',
    'the pane\'s Steer must carry the child id and its draft, saw ' + JSON.stringify(steerPosts.slice(steerBefore)));
  check(pane.notice && /Steering/.test(pane.notice.textContent),
    'the host\'s own receipt must come back to the pane, saw ' + (pane.notice && pane.notice.textContent));

  var cancelBefore = posts(function (b) { return b.action === 'cancel'; }).length;
  paneCancel.click();
  await drain(40);
  var cancelPosts = posts(function (b) { return b.action === 'cancel'; });
  report.paneCancelPosts = cancelPosts.slice(cancelBefore);
  check(cancelPosts.length === cancelBefore + 1 && cancelPosts[cancelBefore].id === 'review-child-1',
    'one click on the pane\'s Cancel must send exactly one cancel for the child, saw ' + JSON.stringify(cancelPosts.slice(cancelBefore)));
  check(pane.notice && /Cancellation requested/.test(pane.notice.textContent),
    'the cancel receipt must come back to the pane, saw ' + (pane.notice && pane.notice.textContent));

  // ---- 3. a pane whose controls are rebuilt: no double fire, no lost handler --------
  // (a) the row is taken out and put back, which fires its connectedCallback again.
  var footer = row.parentElement;
  row.remove();
  footer.append(row);
  check(pane.querySelector('wa-chat-actions') === row,
    'the row must be the same element after a reconnect (built once, not rebuilt)');
  pane.input.value = 'AFTER-ROW-RECONNECT';
  var reconnectBefore = posts(function (b) { return b.action === 'steer'; }).length;
  paneSteer.click();
  await drain(40);
  var reconnectPosts = posts(function (b) { return b.action === 'steer'; });
  report.afterRowReconnect = reconnectPosts.length - reconnectBefore;
  check(reconnectPosts.length === reconnectBefore + 1,
    'a reconnected row must still send exactly one request, saw ' + (reconnectPosts.length - reconnectBefore));

  // (b) the whole pane is taken out and put back inside its own host, which fires the pane's own
  // connectedCallback again. (In the host's tree, because the host hears `agent-action` by bubbling -
  // moving a pane out of its panel is a different question, not this one.)
  var paneHome = pane.parentElement;
  pane.remove();
  paneHome.append(pane);
  var rowAfter = pane.querySelector('wa-chat-actions');
  var steerAfter = pane.querySelector('[data-action="steer"]');
  var actionEvents = 0;
  if (rowAfter) rowAfter.addEventListener('chat-action', function () { actionEvents += 1; });
  pane.input.value = 'AFTER-PANE-RECONNECT';
  report.reconnectState = { sameRow: rowAfter === row, sameControl: steerAfter === paneSteer,
    disabled: steerAfter ? steerAfter.disabled : null, input: pane.input.value,
    notice: pane.notice ? pane.notice.textContent.slice(0, 80) : null,
    taskState: pane.task ? pane.task.state : null };
  var paneAgainBefore = posts(function (b) { return b.action === 'steer'; }).length;
  if (steerAfter) steerAfter.click();
  await drain(40);
  var paneAgain = posts(function (b) { return b.action === 'steer'; });
  report.afterPaneReconnect = { posts: paneAgain.length - paneAgainBefore, chatActionEvents: actionEvents,
    inputAfter: pane.input.value, disabledAfter: steerAfter ? steerAfter.disabled : null,
    noticeAfter: pane.notice ? pane.notice.textContent.slice(0, 80) : null };
  check(paneAgain.length === paneAgainBefore + 1,
    'a reconnected pane must still send exactly one request, saw ' + (paneAgain.length - paneAgainBefore) +
    ' with ' + JSON.stringify(report.reconnectState));
  check(pane.querySelector('[data-action="steer"]') === paneSteer,
    'a reconnected pane must keep the control it addressed by id/handler, not a new one');

  var log = document.createElement('pre');
  log.id = 'wa-probe';
  log.setAttribute('data-status', problems.length ? 'fail' : 'pass');
  log.textContent = (problems.length ? 'FAIL: ' + problems.join(' ;; ') + ' || ' : 'PASS || ') + JSON.stringify(report);
  log.style.cssText = 'position:fixed;left:0;top:0;margin:0;z-index:100000;max-width:100%;white-space:pre-wrap';
  document.body.append(log);
})();
