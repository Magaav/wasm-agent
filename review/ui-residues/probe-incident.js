// The incident, the neighbouring shapes, and the stream - driven through the page's own send().
//
// This probe is served by review/ui-residues/probe-runner.mjs: a copy of ui/ with the fixtures, the
// delivered seam (window.__watchNow / window.__runStanding), and this file. It never touches the running
// window or the installed UI.
//
// Scenarios, in order (each recorded in the #wa-probe JSON as it happens, so a truncated run says how far
// it got rather than looking like a pass):
//   A  the incident's exact shape, through the delivered seam: worker "busy", a busy node-thread belonging
//      to another conversation, no run id for this conversation. Expect: no alarm, the "cannot identify"
//      status, and the stream still rendering what arrives after the ask.
//   B  the same shape one beat later: worker "alive" (the aggregate is the beat age, so the same healthy
//      node answers "busy" or "alive" depending on when the poll lands). Recorded, not asserted.
//   C  the non-vacuity control: an idle node with no run for this conversation MUST still be reported.
//   D  the decision table, through window.__runStanding with the same view the watchdog passes.
//   E  an ask that is in flight when the run ends: the answer arrives after `done`. Must stay silent.
//   S  the timer path: >= 30 s of silence with the incident's answer, no seam call at all. The virtual
//      clock is witnessed by a 1 s counter, so "the timer never fired" cannot be mistaken for "no alarm".
(function () {
  var out = document.createElement('pre');
  out.id = 'wa-probe';
  out.textContent = '{}';
  document.body.appendChild(out);
  var rec = {probe: 'incident-and-neighbours', stage: 'start', ticks: 0};
  function esc(text) { return text.replace(/[<>&]/g, function (c) { return c === '<' ? '\\u003c' : c === '>' ? '\\u003e' : '\\u0026'; }); }
  function save() { out.textContent = esc(JSON.stringify(rec)); }
  save();
  var ticks = 0;
  setInterval(function () { ticks += 1; rec.ticks = ticks; if (ticks % 5 === 0) save(); }, 1000);
  function tick() { return Promise.resolve(); }
  async function until(fn, rounds) {
    rounds = rounds || 300;
    for (var i = 0; i < rounds; i += 1) { if (fn()) return true; await tick(); }
    return !!fn();
  }
  function sleep(ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); }
  function messagesText() { return document.getElementById('messages').textContent; }
  function alarms() { return (messagesText().match(/no longer running/g) || []).length; }
  function statusText() { var el = document.querySelector('.chat-content-run-label'); return el ? el.textContent : null; }
  function composerBusy() { var button = document.getElementById('send'); return !!(button && button.classList.contains('busy')); }
  function tail(n) { return messagesText().slice(-(n || 200)); }

  var held = [], healthHoldNext = false, healthRelease = null, chatPosts = 0, healthCalls = 0, aborted = 0, emitFailed = 0;
  var streamFetch = window.fetch;
  window.fetch = function (input, init) {
    var url = String(typeof input === 'string' ? input : (input && input.url) || '');
    var path = new URL(url, location.href).pathname.replace(/^\/+|\/+$/g, '');
    if (path === 'health') {
      healthCalls += 1;
      var body = window.__fixtures.health;
      var answer = function () { return {ok: true, status: 200, json: function () { return Promise.resolve(body); }}; };
      if (healthHoldNext) { healthHoldNext = false; return new Promise(function (resolve) { healthRelease = function () { resolve(answer()); }; }); }
      return Promise.resolve(answer());
    }
    if (path === 'chat' && init && init.method === 'POST') {
      chatPosts += 1;
      (window.__calls = window.__calls || []).push({url: 'chat', method: 'POST', body: (init && init.body) || '', headers: (init && init.headers) || {}});
      var stream = new ReadableStream({start: function (controller) { held.push(controller); }});
      // A real fetch's body read rejects when its signal aborts. The page's abort() is therefore wired to
      // this fake stream the way the browser wires it to a real one: an abort marks the run lost, errors
      // the body, and the reader in send() sees an AbortError. Without this the probe would report "the
      // stream still delivered" about a stream the page had already given up on.
      if (init && init.signal) {
        init.signal.addEventListener('abort', function () {
          aborted += 1;
          try { held[held.length - 1].error(new DOMException('The user aborted a request.', 'AbortError')); } catch (error) { /* already closed */ }
        });
      }
      return Promise.resolve({ok: true, status: 200, body: stream, json: function () { return Promise.resolve({ok: true, reply: 'held'}); }});
    }
    return streamFetch.apply(window, arguments);
  };
  function emit(event) {
    var controller = held[held.length - 1];
    if (!controller) return false;
    // After the page aborted the stream this throws: that IS the observation (the page gave up on the
    // stream), so it is recorded rather than allowed to end the probe.
    try {
      controller.enqueue(new TextEncoder().encode('data: ' + JSON.stringify(event) + '\n\n'));
      return true;
    } catch (error) {
      emitFailed += 1;
      return false;
    }
  }
  function closeStream() { var controller = held[held.length - 1]; if (controller) { try { controller.close(); } catch (error) { /* already gone */ } } }

  var nodeBody = function (worker, threads, runIds) {
    return {ok: worker !== 'stalled', worker: worker, queue: 0, stalled_ms: 0, current: null,
      node_threads: threads || [], run_ids: runIds || [], subagents: {running: 0, queued: 0, active: 0}};
  };
  // The incident's answer, exactly as the owner's log describes it: the node is working, and the thread it
  // is working on belongs to a conversation this window cannot match to the one it is watching.
  var foreignThread = [{id: 0, label: 'POST /chat', busy_ms: 9100, session: 'some-other-conversation', run_id: 404}];
  var incidentBusy = function () { return nodeBody('busy', foreignThread, []); };
  var incidentAlive = function () { return nodeBody('alive', foreignThread, []); };
  var idleOver = function () { return nodeBody('alive', [], []); };

  async function sendTurn(tag) {
    var before = chatPosts;
    var input = document.getElementById('input');
    input.value = 'a turn the node accepted (' + tag + ')';
    input.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true, cancelable: true}));
    var posted = await until(function () { return chatPosts > before; }, 400);
    await until(function () { return composerBusy(); }, 40);
    return {posted: posted, posts: chatPosts - before, busy: composerBusy(), stream: held.length};
  }
  async function waitIdle(rounds) { await until(function () { return !composerBusy(); }, rounds || 400); }

  (async function () {
    await until(function () { return !!document.getElementById('input') && typeof window.__watchNow === 'function'; }, 400);
    rec.boot = {thread: typeof window.__chatThread === 'function' ? window.__chatThread() : 'no export',
      watch: typeof window.__watchNow, standing: typeof window.__runStanding, input: !!document.getElementById('input')};
    save();
    await waitIdle(200);

    // ---- A: the incident, through the seam -----------------------------------------------------------
    rec.stage = 'A-incident';
    save();
    rec.A = {send: await sendTurn('A')};
    window.__fixtures.health = incidentBusy();
    rec.A.alarmsBefore = alarms();
    rec.A.abortedBefore = aborted;
    await window.__watchNow();
    await until(function () { return true; }, 5);
    rec.A.alarmsAfter = alarms();
    rec.A.status = statusText();
    rec.A.busy = composerBusy();
    rec.A.tail = tail(220);
    rec.A.abortedAfter = aborted;
    emit({type: 'delta', text: 'AFTER-ASK-DELTA-A'});
    rec.A.streamRendered = await until(function () { return messagesText().indexOf('AFTER-ASK-DELTA-A') >= 0; }, 200);
    rec.A.alarmsAtEnd = alarms();
    save();

    // ---- B: the same shape, worker "alive" -----------------------------------------------------------
    rec.stage = 'B-alive';
    save();
    window.__fixtures.health = incidentAlive();
    rec.B = {alarmsBefore: alarms(), busyBefore: composerBusy(), abortedBefore: aborted};
    await window.__watchNow();
    await until(function () { return true; }, 20);
    rec.B.alarmsAfter = alarms();
    rec.B.status = statusText();
    rec.B.tail = tail(240);
    rec.B.abortedAfter = aborted;
    rec.B.enqueueAfterAbort = emit({type: 'delta', text: 'AFTER-ASK-DELTA-B'});
    rec.B.streamRendered = await until(function () { return messagesText().indexOf('AFTER-ASK-DELTA-B') >= 0; }, 200);
    rec.B.runEnded = await until(function () { return !composerBusy(); }, 200);
    rec.B.busyAfter = composerBusy();
    rec.B.stopped = messagesText().indexOf('stopped.') >= 0;
    rec.B.alarmsAtEnd = alarms();
    save();

    // ---- C: the control - the alarm must still be reachable ------------------------------------------
    rec.stage = 'C-over';
    save();
    closeStream();
    await waitIdle(400);
    rec.C = {send: await sendTurn('C')};
    window.__fixtures.health = idleOver();
    rec.C.alarmsBefore = alarms();
    await window.__watchNow();
    await until(function () { return true; }, 20);
    rec.C.alarmsAfter = alarms();
    rec.C.tail = tail(240);
    rec.C.status = statusText();
    save();

    // ---- D: the decision table through the delivered function ----------------------------------------
    rec.stage = 'D-table';
    save();
    var thread = window.__chatThread();
    var view = {session: thread, runId: null, submitted: new Set(), finished: false};
    rec.D = {
      busyUnidentifiable: window.__runStanding(incidentBusy(), view),
      aliveUnidentifiable: window.__runStanding(incidentAlive(), view),
      idleNoRun: window.__runStanding(idleOver(), view),
      finished: window.__runStanding(incidentAlive(), {session: thread, runId: null, submitted: new Set(), finished: true}),
      stalled: window.__runStanding(nodeBody('stalled', foreignThread, []), view),
      foreignTerminalAccepted: window.__runStanding(nodeBody('busy', [], [{conversation: 'other', run_id: 42, state: 'completed'}]), {session: thread, runId: 42, submitted: new Set(), finished: false}),
      mineLiveInBaseline: window.__runStanding(nodeBody('alive', [], [{conversation: thread, run_id: 42, state: 'running'}]), {session: thread, runId: null, submitted: new Set([42]), finished: false}),
      mineLiveNotInBaseline: window.__runStanding(nodeBody('alive', [], [{conversation: thread, run_id: 42, state: 'running'}]), {session: thread, runId: null, submitted: new Set([41]), finished: false}),
      mineThread: window.__runStanding(nodeBody('busy', [{label: 'POST /chat', session: thread, run_id: 7}], []), view)
    };
    save();

    // ---- E: an ask in flight when the run ends -------------------------------------------------------
    rec.stage = 'E-late-answer';
    save();
    closeStream();
    await waitIdle(400);
    rec.E = {send: await sendTurn('E')};
    window.__fixtures.health = incidentAlive();
    healthHoldNext = true;
    var pending = window.__watchNow();
    var heldSeen = await until(function () { return !!healthRelease; }, 200);
    // `reply` is the event that both ends the run and puts the answer on screen, so "the run ended while the
    // ask was in flight" is observable rather than assumed.
    emit({type: 'reply', text: 'the answer is on screen'});
    var replySeen = await until(function () { return messagesText().indexOf('the answer is on screen') >= 0; }, 200);
    var alarmsBeforeRelease = alarms();
    if (healthRelease) healthRelease();
    await pending;
    await until(function () { return true; }, 20);
    rec.E = {held: heldSeen, replySeen: replySeen, alarmsBeforeRelease: alarmsBeforeRelease, alarmsAfter: alarms(),
      status: statusText(), tail: tail(160)};
    closeStream();
    await waitIdle(400);
    save();

    // ---- S: the timer path, >= 30 s of silence, no seam call ------------------------------------------
    rec.stage = 'S-silence';
    save();
    rec.S = {send: await sendTurn('S')};
    window.__fixtures.health = incidentBusy();
    // The watchdog is the only /health caller left once the liveness line is stopped, so a health request
    // during the silence IS the 30-second timer firing - an observation that does not depend on the status
    // line, which other parts of the page overwrite.
    if (typeof window.__stopLiveness === 'function') window.__stopLiveness();
    rec.S.alarmsBefore = alarms();
    rec.S.healthBefore = healthCalls;
    rec.S.statusAtStart = statusText();
    rec.S.ticksAtStart = ticks;
    var sawCannotIdentify = false, sawAlarm = false, firstStatus = null;
    for (var second = 0; second < 45; second += 1) {
      await sleep(1000);
      rec.S.waited = second + 1;
      rec.S.ticks = ticks;
      rec.S.healthDuring = healthCalls - rec.S.healthBefore;
      if (second % 5 === 0) save();
      var status = statusText() || '';
      if (status.indexOf('cannot identify') >= 0 && (rec.S.statusAtStart || '').indexOf('cannot identify') < 0) {
        sawCannotIdentify = true;
        if (!firstStatus) firstStatus = status;
      }
      if (alarms() > rec.S.alarmsBefore) { sawAlarm = true; rec.S.alarmedAtSecond = second + 1; break; }
    }
    rec.S.sawCannotIdentify = sawCannotIdentify;
    rec.S.firstCannotIdentifyStatus = firstStatus;
    rec.S.alarmsAfter = alarms();
    rec.S.healthAfter = healthCalls - rec.S.healthBefore;
    rec.S.status = statusText();
    emit({type: 'delta', text: 'AFTER-ASK-DELTA-S'});
    rec.S.streamRendered = await until(function () { return messagesText().indexOf('AFTER-ASK-DELTA-S') >= 0; }, 200);
    rec.S.busy = composerBusy();
    rec.S.verdict = ticks >= 31
      ? (sawAlarm ? 'TIMER PATH: the alarm was printed'
        : (rec.S.healthAfter > 0
          ? (rec.S.streamRendered ? 'timer path: the watchdog asked after 30 s of silence, printed no alarm, and the stream still rendered what arrived after the ask' : 'timer path: the watchdog asked, printed no alarm, but the stream did not render')
          : 'INCONCLUSIVE: no health request happened during the silence, so no check ran'))
      : 'INCONCLUSIVE: the virtual clock reached only ' + ticks + ' s, so the 30 s watchdog never fired';
    rec.stage = 'done';
    save();
  })().catch(function (error) {
    rec.stage = 'threw';
    rec.error = String((error && error.message) || error);
    save();
  });
})();
