// Reviewer's probe of the page-budget fallback, on the new tip.
//
// Three questions the durable suite's budget check does not answer: is the retry BOUNDED (once for the
// window, not once per pane and not a loop)? is it VISIBLE (the pane says which size it asked for and
// what the node answered)? and does it HIDE a real failure when the unsized read fails too?
(function () {
  var notes = [], problems = [], facts = {}, phase = 'booting';
  var log = document.createElement('pre');
  log.id = 'wa-probe';
  log.setAttribute('data-status', 'running');
  log.style.cssText = 'position:fixed;bottom:0;left:0;right:0;z-index:99;pointer-events:none;background:#000;color:#0f0;font:10px monospace;padding:4px;max-height:45%;overflow:auto';
  function report() {
    var failed = problems.length > 0;
    log.textContent = (failed ? 'PAGE BUDGET FAIL' : 'PAGE BUDGET PASS') + ' (' + notes.length + ' checks, '
      + problems.length + ' failures) phase=' + phase + (failed ? ' | FAILURES: ' + problems.join(' ;; ') : '')
      + ' || FACTS ' + JSON.stringify(facts);
  }
  function check(ok, label) { (ok ? notes : problems).push(label); report(); }
  function tick() { return Promise.resolve(); }
  function repeat(text, times) { var out = ''; for (var i = 0; i < times; i += 1) out += text; return out; }
  function keyOf(pane) { return String(pane.dataset.key || ''); }

  (async function () {
    try {
      document.body.appendChild(log);
      phase = 'waiting for the view';
      if (window.rendererLoaded) await window.rendererLoaded;
      for (var mount = 0; mount < 60 && !document.querySelector('wa-orchestrator'); mount += 1) await tick();
      var panel = document.querySelector('wa-orchestrator');
      if (!panel) throw new Error('the orchestrator view did not mount');

      var longBody = repeat('child transcript text that occupies real height ', 4);
      var tasks = [], sessions = [], tmp = {children: {}};
      ['a', 'b', 'c'].forEach(function (name, index) {
        tasks.push({subagent_id: 'child-' + name, session_id: 's-' + name, profile: 'task-worker',
          model: 'fixture-model', reasoning: 'high', execution_node: 'local', state: 'running', settled: false,
          title: 'budget child ' + name, created_at: 100 + index});
        sessions.push({id: 's-' + name, title: 'budget ' + name, state: 'unfinished', workspace_required: 1,
          workspace_branch: 'change/budget-' + name, worktree: 'C:/work/wt-' + name, workspace_state: 'allocated'});
        tmp.children[name] = [
          {seq: 1, role: 'user', created_at: 1789990000, tool_calls: [], content: 'BUDGET-' + name + '-QUESTION ' + longBody},
          {seq: 2, role: 'assistant', created_at: 1789990001, ms: 9000, tool_calls: [],
            content: 'BUDGET-' + name + '-ANSWER ' + longBody}];
      });
      window.__fixtures.subagents = {subagents: tasks};
      window.__fixtures.sessions = {sessions: sessions};

      // A node whose tool-output budget is lowered refuses a sized page exactly as
      // lua/core/session_view.lua does, and accepts the unsized one.
      var counted = {session: 0, refusedSized: 0, acceptedUnsized: 0};
      var requestLog = [];
      var previousFetch = window.fetch;
      window.fetch = function (input, init) {
        var url = String(typeof input === 'string' ? input : (input && input.url) || '');
        var path = new URL(url, location.href).pathname.replace(/^\/+|\/+$/g, '');
        if (path === 'subagents' && init && init.method === 'POST') {
          var request = {};
          try { request = JSON.parse(init.body || '{}'); } catch (error) { request = {}; }
          if (request.action === 'session') {
            counted.session += 1;
            var name = String(request.id || '').replace('child-', '');
            function respond(value) {
              return Promise.resolve({ok: true, status: 200,
                json: function () { return Promise.resolve(value); },
                text: function () { return Promise.resolve(JSON.stringify(value)); }});
            }
            if (request.byte_limit != null) {
              counted.refusedSized += 1;
              requestLog.push({id: request.id, byte_limit: request.byte_limit, outcome: 'refused_sized'});
              return respond({error: 'invalid_session_byte_limit'});
            }
            counted.acceptedUnsized += 1;
            requestLog.push({id: request.id, byte_limit: null, outcome: window.__alsoFailUnsized ? 'unsized_failed' : 'unsized_accepted'});
            if (window.__alsoFailUnsized) return respond({error: 'fixture_page_unavailable'});
            return respond({session_id: 's-' + name, view: 'full', returned: (tmp.children[name] || []).length,
              messages: tmp.children[name] || [],
              task: {subagent_id: request.id, session_id: 's-' + name, state: 'running', settled: false,
                profile: 'task-worker', model: 'fixture-model', reasoning: 'high'}});
          }
        }
        return previousFetch(input, init);
      };

      phase = 'opening three children';
      for (var tries = 0; tries < 25 && panel.querySelectorAll('nav .agent-card').length !== 3; tries += 1) {
        await window.__refreshOrchestrator();
        for (var settle = 0; settle < 20; settle += 1) await tick();
      }
      Array.prototype.slice.call(panel.querySelectorAll('nav .agent-card')).forEach(function (card) { card.click(); });
      var panes = [];
      for (var drawn = 0; drawn < 40; drawn += 1) {
        await window.__refreshOrchestrator();
        for (var settle2 = 0; settle2 < 20; settle2 += 1) await tick();
        panes = Array.prototype.slice.call(panel.querySelectorAll('wa-agent-session'));
        if (panes.length === 3 && panes.every(function (pane) { return pane.querySelectorAll('wa-message').length >= 2; })) break;
      }
      facts.panes = panes.map(function (pane) {
        return {key: keyOf(pane), messages: pane.querySelectorAll('wa-message').length,
          answer: /BUDGET-[abc]-ANSWER/.test(pane.transcript.textContent),
          notice: pane.notice.textContent, noticeTitle: pane.notice.title,
          footerInsideBubble: !!(pane.transcript.querySelector('wa-message.assistant > .body.steps > .chat-content-run-status'))};
      });
      facts.counted = counted;
      facts.requestLog = requestLog.slice(0, 40);
      report();

      check(panes.length === 3 && facts.panes.every(function (row) { return row.answer && row.messages >= 2; }),
        'a lowered page budget must cost page size, not the transcript, saw ' + JSON.stringify(facts.panes));
      // Boundedness, precisely: the size is a per-WINDOW fact, so once the fallback has fired every
      // later read must be unsized (convergence), and the refused attempts must be bounded by the reads
      // already in flight - never growing again, never per pane in a later round.
      var sized = requestLog.filter(function (entry) { return entry.outcome === 'refused_sized'; });
      var firstUnsized = requestLog.map(function (entry) { return entry.outcome; }).indexOf('unsized_accepted');
      var sizedAfterConvergence = firstUnsized < 0 ? -1 : requestLog.slice(firstUnsized)
        .filter(function (entry) { return entry.outcome === 'refused_sized'; }).length;
      facts.bounded = {sizedAttempts: sized.length, firstUnsizedAt: firstUnsized,
        sizedAfterConvergence: sizedAfterConvergence};
      check(sized.length > 0 && sizedAfterConvergence === 0,
        'the refused size must never be re-attempted once the window has learned the node refuses it, saw '
        + sized.length + ' sized attempt(s), ' + sizedAfterConvergence + ' of them after the first accepted read');
      check(counted.refusedSized <= panes.length * 2,
        'the refused size must be paid a bounded number of times (concurrent first reads may each cost one), saw '
        + counted.refusedSized + ' refused sized request(s) for ' + panes.length + ' panes: ' + JSON.stringify(requestLog));
      check(facts.panes.every(function (row) { return row.notice.indexOf('invalid_session_byte_limit') >= 0
        && row.notice.indexOf('KiB') >= 0; }),
        'every pane must say which page size it asked for and that the node refused it, saw '
        + JSON.stringify(facts.panes.map(function (row) { return row.notice; })));
      check(facts.panes.every(function (row) { return /WASM_AGENT_TOOL_OUTPUT_BYTES/.test(String(row.noticeTitle)); }),
        'the full reason must travel with the row, saw ' + JSON.stringify(facts.panes.map(function (row) { return row.noticeTitle; })));

      // Bounded: more refresh rounds must not re-attempt the sized request.
      var beforeRounds = counted.refusedSized, beforeSession = counted.session;
      for (var round = 0; round < 3; round += 1) {
        await window.__refreshOrchestrator();
        for (var settle3 = 0; settle3 < 20; settle3 += 1) await tick();
      }
      check(counted.refusedSized === beforeRounds,
        'a further refresh round must not re-attempt the refused size (no retry loop), saw '
        + beforeRounds + ' -> ' + counted.refusedSized + ' refused, session reads ' + beforeSession + ' -> ' + counted.session);

      // A real failure must not be hidden by the note: make the unsized read fail too.
      phase = 'unsized read fails';
      window.__alsoFailUnsized = true;
      tmp.children.a = tmp.children.a.concat([{seq: 3, role: 'assistant', created_at: 1789990002, ms: 1000,
        tool_calls: [], content: 'BUDGET-a-LATER'}]);
      for (var failTry = 0; failTry < 6; failTry += 1) {
        await window.__refreshOrchestrator();
        for (var settle4 = 0; settle4 < 20; settle4 += 1) await tick();
      }
      var failing = panes.filter(function (pane) { return keyOf(pane) === 'child-a'; })[0];
      facts.failureNotice = failing ? failing.notice.textContent : null;
      check(!!failing && /Conversation unavailable/.test(failing.notice.textContent)
        && /fixture_page_unavailable/.test(failing.notice.textContent),
        'when the unsized read fails too the pane must show that failure, not only the note, saw '
        + JSON.stringify(facts.failureNotice));
      phase = 'done';
      log.setAttribute('data-status', problems.length ? 'fail' : 'pass');
      report();
    } catch (error) {
      problems.push('the probe threw: ' + ((error && error.stack) || error));
      phase = 'threw';
      log.setAttribute('data-status', 'fail');
      report();
    }
  })();
})();
