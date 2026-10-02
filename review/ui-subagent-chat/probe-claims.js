// Reviewer's own probe for the five claims of change/ui-subagent-chat.
//
// Independent of scripts/probe-ui-subagent-chat.ps1: written from the claims, measured in a real
// layout engine (getBoundingClientRect / getComputedStyle / elementFromPoint), and every number is
// reported whether it passes or fails. Long content on purpose, and the lane fixtures use the shape
// the node actually records (M.release keeps `worktree` and sets `workspace_state='released'`).
//
// The log element is created first and updated per phase, so a dump that races this probe reports
// `running` - which is "no evidence", not "passed".
(function () {
  var notes = [], problems = [], facts = {}, phase = 'booting';
  var log = document.createElement('pre');
  log.id = 'wa-probe';
  log.setAttribute('data-status', 'running');
  log.style.cssText = 'position:fixed;bottom:0;left:0;right:0;z-index:99;pointer-events:none;background:#000;color:#0f0;font:10px monospace;padding:4px;max-height:45%;overflow:auto';
  function report() {
    var failed = problems.length > 0;
    log.textContent = (failed ? 'REVIEW PROBE FAIL' : 'REVIEW PROBE PASS') + ' (' + notes.length + ' checks, '
      + problems.length + ' failures) phase=' + phase + (failed ? ' | FAILURES: ' + problems.join(' ;; ') : '')
      + ' || FACTS ' + JSON.stringify(facts);
  }
  function check(ok, label) { (ok ? notes : problems).push(label); report(); }
  function tick() { return Promise.resolve(); }
  function round(value) { return Math.round(Number(value) * 100) / 100; }
  function rect(element) {
    var box = element.getBoundingClientRect();
    return {x: round(box.left), y: round(box.top), top: round(box.top), left: round(box.left),
      w: round(box.width), h: round(box.height), right: round(box.right), bottom: round(box.bottom)};
  }
  function sig(element) { return element.tagName + '.' + Array.prototype.slice.call(element.classList).sort().join('.'); }
  function shape(root) {
    return Array.prototype.slice.call(root.children).map(function (node) {
      var kids = node.tagName === 'WA-MESSAGE' && node.body ? Array.prototype.slice.call(node.body.children) : [];
      return sig(node) + '[' + kids.map(function (kid) {
        return sig(kid) + '{' + Array.prototype.slice.call(kid.children).map(function (deep) { return sig(deep); }).join(',') + '}';
      }).join(',') + ']';
    }).join(';');
  }
  function repeat(text, times) { var out = ''; for (var i = 0; i < times; i += 1) out += text; return out; }
  function keyOf(pane) { return String(pane.dataset.key || ''); }
  function textOf(node) { return node ? String(node.textContent || '') : null; }

  (async function () {
    try {
      document.body.appendChild(log);
      phase = 'waiting for the view';
      if (window.rendererLoaded) await window.rendererLoaded;
      for (var mount = 0; mount < 60 && !document.querySelector('wa-orchestrator'); mount += 1) await tick();
      var panel = document.querySelector('wa-orchestrator');
      if (!panel) throw new Error('the orchestrator view did not mount');
      if (typeof window.__refreshOrchestrator !== 'function') throw new Error('no __refreshOrchestrator hook');

      // ---- the node's answers ----------------------------------------------------------------
      var lanes = [
        {branch: 'change/lane-alpha', worktree: 'C:/work/wt-alpha', state: 'allocated'},
        {branch: 'change/lane-beta', worktree: 'C:/work/wt-beta', state: 'released'},
        {branch: '', worktree: '', state: 'unbound'}
      ];
      var longTitle = repeat('a deliberately long mission line that must be ellipsized ', 8);
      var longBody = repeat('a long paragraph of child transcript text that has to occupy real height ', 6);
      var tasks = [], sessions = [];
      for (var i = 1; i <= 6; i += 1) {
        var plan = lanes[Math.floor((i - 1) / 2)];
        var settled = i > 4;
        tasks.push({subagent_id: 'child-' + i, session_id: 'child-session-' + i,
          parent_session_id: 'parent-fixture', profile: 'task-worker', execution_node: 'local',
          title: 'CHILD-' + i + ' ' + longTitle, prompt: 'prompt ' + i,
          state: settled ? 'completed' : 'running', settled: settled,
          model: 'fixture-model-' + i, reasoning: 'high', created_at: 100 + i});
        sessions.push({id: 'child-session-' + i, title: 'child session ' + i,
          state: settled ? 'answered' : 'unfinished', workspace_required: 1,
          workspace_branch: plan.branch, worktree: plan.worktree, workspace_state: plan.state});
      }
      window.__fixtures.subagents = {subagents: tasks};
      window.__fixtures.sessions = {sessions: sessions};

      var base = 1789990000;
      function page(id) {
        var n = Number(String(id).replace('child-', ''));
        var rows = [
          {seq: 1, role: 'user', created_at: base, tool_calls: [], content: 'CHILD-' + n + '-QUESTION ' + longBody},
          {seq: 2, role: 'assistant', created_at: base + 1, content: '', reasoning: 'CHILD-' + n + '-REASONING',
            tool_calls: [{id: 'call-' + n, function: {name: 'bash', arguments: '{}'}}]},
          {seq: 3, role: 'tool', created_at: base + 2, tool_call_id: 'call-' + n, tool_name: 'bash', ok: 1,
            content: 'CHILD-' + n + '-TOOL-RESULT ' + longBody, tool_calls: []},
          {seq: 4, role: 'assistant', created_at: base + 3, content: '',
            tool_calls: [{id: 'fail-' + n, function: {name: 'bash', arguments: '{}'}}]},
          {seq: 5, role: 'tool', created_at: base + 4, tool_call_id: 'fail-' + n, tool_name: 'bash', ok: 0,
            content: 'CHILD-' + n + '-TOOL-FAILURE', tool_calls: []}
        ];
        if (n === 5) {
          rows.push({seq: 6, role: 'assistant', created_at: base + 5, omitted: true, tool_calls: [],
            content: '[Oversized message: retrieve the original using evidence.]',
            evidence: {tool: 'subagent', action: 'session', id: id, message_id: 'oversized-' + n, byte_offset: 1}});
        }
        rows.push({seq: n === 5 ? 7 : 6, role: 'assistant', created_at: base + (n === 5 ? 6 : 5), ms: 13000,
          tool_calls: [], content: 'CHILD-' + n + '-ANSWER ' + longBody});
        return {session_id: 'child-session-' + n, view: 'full', messages: rows,
          note: 'Bounded inspection only; original transcript unchanged.',
          task: {subagent_id: id, session_id: 'child-session-' + n, profile: 'task-worker',
            model: 'fixture-model-' + n, reasoning: 'high',
            state: n > 4 ? 'completed' : 'running', settled: n > 4}};
      }
      var previousFetch = window.fetch;
      window.fetch = function (input, init) {
        var url = String(typeof input === 'string' ? input : (input && input.url) || '');
        var path = new URL(url, location.href).pathname.replace(/^\/+|\/+$/g, '');
        if (path === 'subagents' && init && init.method === 'POST') {
          var request = {};
          try { request = JSON.parse(init.body || '{}'); } catch (error) { request = {}; }
          if (request.action === 'session') {
            var value = page(request.id);
            return Promise.resolve({ok: true, status: 200,
              json: function () { return Promise.resolve(value); },
              text: function () { return Promise.resolve(JSON.stringify(value)); }});
          }
        }
        return previousFetch(input, init);
      };

      phase = 'opening six children';
      for (var tries = 0; tries < 25 && panel.querySelectorAll('nav .agent-card').length !== 6; tries += 1) {
        await window.__refreshOrchestrator();
        for (var settle = 0; settle < 20; settle += 1) await tick();
      }
      var cards = Array.prototype.slice.call(panel.querySelectorAll('nav .agent-card'));
      check(cards.length === 6, 'six children must produce six cards, saw ' + cards.length);
      cards.forEach(function (card) { card.click(); });
      var panes = [];
      for (var drawn = 0; drawn < 60; drawn += 1) {
        await window.__refreshOrchestrator();
        for (var settle2 = 0; settle2 < 20; settle2 += 1) await tick();
        panes = Array.prototype.slice.call(panel.querySelectorAll('wa-agent-session'));
        if (panes.length === 6 && panel.querySelectorAll('.agent-transcript wa-message').length >= 30) break;
      }
      check(panes.length === 6, 'six children must be open at once, saw ' + panes.length);
      var canvas = panel.querySelector('.orchestrator-canvas');
      if (!canvas) throw new Error('no .orchestrator-canvas');

      phase = 'measuring';
      var perPane = [], canvasRect = rect(canvas);
      var viewportHeight = window.innerHeight, viewportWidth = window.innerWidth;
      facts.viewport = {w: viewportWidth, h: viewportHeight, dpr: window.devicePixelRatio};
      facts.canvas = {clientHeight: canvas.clientHeight, scrollHeight: canvas.scrollHeight, rect: canvasRect};

      for (var p = 0; p < panes.length; p += 1) {
        var pane = panes[p];
        var head = pane.querySelector('.agent-pane-head');
        var title = pane.querySelector('.agent-pane-head strong');
        var subtitle = pane.querySelector('.agent-pane-head span');
        var controls = Array.prototype.slice.call(pane.querySelectorAll('.agent-pane-head .icon-btn'));
        var transcript = pane.querySelector('.agent-transcript');
        var actionRow = pane.querySelector('.chat-actions');
        var actionButton = pane.querySelector('.chat-actions .chat-action');
        var attach = pane.querySelector('wa-chat-shell [data-part="attach"]');
        var shell = pane.querySelector('wa-chat-shell');
        var bubble = transcript.querySelector('wa-message.assistant');
        var body = bubble ? bubble.querySelector('.body') : null;
        var footer = body ? body.querySelector(':scope > .chat-content-run-status') : null;
        var okLine = transcript.querySelector('wa-trace .tool-line.ok');
        var errLine = transcript.querySelector('wa-trace .tool-line.err');
        var okOutput = okLine ? okLine.querySelector('.tool-output') : null;
        var errOutput = errLine ? errLine.querySelector('.tool-output') : null;

        var headRect = rect(head), headStyle = getComputedStyle(head);
        var controlsInside = controls.every(function (control) {
          var box = rect(control);
          return box.w > 0 && box.h > 0 && box.left >= headRect.x - 0.5 && box.right <= headRect.right + 0.5
            && box.top >= headRect.y - 0.5 && box.bottom <= headRect.bottom + 0.5;
        });

        // (1) readable when it is scrolled to: bring this pane into view, then ask the renderer what is
        // actually in the middle of its content area. A hit inside the transcript is legibility; a
        // zero (or a hit outside it) is a box the reader cannot read.
        var paneBox = rect(pane);
        if (paneBox.top < 0 || paneBox.bottom > viewportHeight) {
          canvas.scrollTop = canvas.scrollTop + paneBox.top - canvasRect.y;
          for (var s = 0; s < 3; s += 1) await tick();
          paneBox = rect(pane);
        }
        var transcriptBox = rect(transcript);
        var centreX = Math.round((Math.max(paneBox.x, 0) + Math.min(paneBox.right, viewportWidth)) / 2);
        var centreY = Math.round((Math.max(transcriptBox.y, 0) + Math.min(transcriptBox.bottom, viewportHeight)) / 2);
        var hit = null, hitText = '', hitInside = false;
        if (centreY > 0 && centreY < viewportHeight && centreX > 0 && centreX < viewportWidth) {
          hit = document.elementFromPoint(centreX, centreY);
          if (hit) { hitText = (hit.textContent || '').slice(0, 40); hitInside = transcript === hit || transcript.contains(hit); }
        }
        var messageHeights = Array.prototype.slice.call(transcript.querySelectorAll('wa-message')).map(function (node) {
          return round(rect(node).h);
        });

        perPane.push({
          key: keyOf(pane),
          pane: {rect: paneBox, h: round(paneBox.h)},
          head: {rect: headRect, computedHeight: headStyle.height, computedMaxHeight: headStyle.maxHeight,
            clientHeight: head.clientHeight, scrollHeight: head.scrollHeight,
            titleRect: rect(title), subtitleRect: rect(subtitle),
            titleLen: title.textContent.length, titleClientWidth: title.clientWidth,
            titleScrollWidth: title.scrollWidth, titleTextOverflow: getComputedStyle(title).textOverflow,
            subtitleLen: subtitle.textContent.length, controls: controls.length, controlsInside: controlsInside,
            controlRects: controls.map(function (control) { return rect(control); })},
          transcript: {clientHeight: transcript.clientHeight, scrollHeight: transcript.scrollHeight,
            rect: transcriptBox, messages: messageHeights,
            minMessageHeight: messageHeights.length ? Math.min.apply(null, messageHeights) : -1,
            answerPresent: transcript.textContent.indexOf('CHILD-' + keyOf(pane).replace('child-', '') + '-ANSWER') >= 0,
            hitInside: hitInside, hitTag: hit ? hit.tagName : null, hitText: hitText},
          controls: {actionRowSelector: '.chat-actions', actionButtonSelector: '.chat-actions .chat-action',
            attachSelector: 'wa-chat-shell [data-part="attach"]',
            actionRowHeight: round(rect(actionRow).h), actionButtonHeight: round(rect(actionButton).h),
            attachHeight: round(rect(attach).h),
            actionButtonComputed: getComputedStyle(actionButton).height,
            attachComputed: getComputedStyle(attach).height,
            actionButtonOffset: actionButton.offsetHeight, attachOffset: attach.offsetHeight},
          path: {sharedShell: !!(shell && transcript.classList.contains('messages')
              && transcript.getAttribute('data-part') === 'content'),
            showMessagesType: typeof pane.showMessages,
            earlierElement: !!pane.querySelector('.agent-earlier'),
            earlierText: /Earlier messages/.test(pane.textContent),
            retrieveText: /Load original message/.test(pane.textContent),
            notice: textOf(pane.notice),
            bodySteps: !!(body && body.classList.contains('steps')),
            footerInBubble: !!(footer && footer.classList.contains('finished')),
            footerLabel: textOf(footer && footer.querySelector('.chat-content-run-label')),
            footerElapsed: textOf(footer && footer.querySelector('.chat-content-run-elapsed')),
            footerAtTranscriptRoot: !!transcript.querySelector(':scope > .chat-content-run-status'),
            statusLineHidden: pane.statusLine ? pane.statusLine.hidden : null},
          fold: {okLine: !!okLine, okOutputHidden: okOutput ? okOutput.hidden : null,
            errLine: !!errLine, errOutputHidden: errOutput ? errOutput.hidden : null,
            errRecorded: /not recorded/.test(textOf(transcript.querySelector('wa-trace .tool-line')) || '')}
        });
      }
      facts.panes = perPane;
      facts.canvasScrolled = canvas.scrollHeight > canvas.clientHeight;
      report();

      // Claim 1: six open boxes, each with a content area that is really visible and not clipped.
      check(perPane.length === 6 && perPane.every(function (row) { return row.transcript.clientHeight >= 120; }),
        'every one of six open panes must keep a readable transcript height (>=120px), saw '
        + JSON.stringify(perPane.map(function (row) { return row.transcript.clientHeight; })));
      check(perPane.every(function (row) { return row.transcript.minMessageHeight > 0 && row.transcript.scrollHeight >= 120
        && row.transcript.answerPresent; }),
        'every pane transcript must hold real bubbles (its answer among them) inside a scrollable box, saw '
        + JSON.stringify(perPane.map(function (row) {
          return [row.key, row.transcript.minMessageHeight, row.transcript.scrollHeight, row.transcript.answerPresent];
        })));
      check(perPane.every(function (row) { return row.transcript.hitInside; }),
        'the middle of every pane transcript must hit a node inside that transcript (visible, not covered), saw '
        + JSON.stringify(perPane.map(function (row) { return [row.key, row.transcript.hitTag, row.transcript.hitInside, row.transcript.hitText]; })));
      check(canvas.scrollHeight >= canvas.clientHeight && perPane.every(function (row) { return row.pane.h >= 300; }),
        'the canvas must scroll rather than squash its panes, and every pane must keep a real box, saw canvas '
        + canvas.clientHeight + ' of ' + canvas.scrollHeight + ' panes ' + JSON.stringify(perPane.map(function (row) { return row.pane.h; })));

      // Claim 2: the header is a fixed strip, and the cap must not be hiding the title or the controls.
      check(perPane.every(function (row) { return row.head.computedMaxHeight === '44px'; }),
        'the pane header must be capped at 44px, saw '
        + JSON.stringify(perPane.map(function (row) { return row.head.computedMaxHeight; })));
      check(perPane.every(function (row) { return row.head.rect.h > 0 && row.head.rect.h <= 44; }),
        'every pane header must measure at most 44px, saw '
        + JSON.stringify(perPane.map(function (row) { return [row.head.computedHeight, row.head.rect.h]; })));
      check(perPane.every(function (row) { return row.head.scrollHeight <= row.head.clientHeight + 1; }),
        'the 44px cap must not clip the header vertically (scrollHeight must not exceed clientHeight), saw '
        + JSON.stringify(perPane.map(function (row) { return [row.head.clientHeight, row.head.scrollHeight]; })));
      check(perPane.every(function (row) { return row.head.controlsInside; }),
        'both header controls must stay inside the header box the cap gives them, saw '
        + JSON.stringify(perPane.map(function (row) { return [row.head.controls, row.head.controlsInside, row.head.controlRects]; })));
      check(perPane.every(function (row) { return row.head.titleLen > 60 && row.head.titleClientWidth > 0
        && row.head.titleScrollWidth > row.head.titleClientWidth && row.head.titleTextOverflow === 'ellipsis'
        && row.head.titleRect.w > 0 && row.head.subtitleRect.w > 0; }),
        'the title and the model line must stay readable text that is ellipsized rather than hidden, saw '
        + JSON.stringify(perPane.map(function (row) {
          return [row.head.titleLen, row.head.titleClientWidth, row.head.titleScrollWidth, row.head.titleTextOverflow,
            row.head.titleRect.w, row.head.subtitleRect.w];
        })));

      // Claim 3: the action row is the height of the append-file control, measured by selector.
      check(perPane.every(function (row) { return row.controls.actionButtonHeight > 0
        && row.controls.actionButtonHeight === row.controls.attachHeight; }),
        'the Steer/Cancel row must be the height of the append-file control, saw '
        + JSON.stringify(perPane.map(function (row) { return [row.controls.actionButtonHeight, row.controls.attachHeight]; }))
        + ' measured as ' + perPane[0].controls.actionButtonSelector + ' vs ' + perPane[0].controls.attachSelector);
      check(perPane.every(function (row) { return row.controls.actionRowHeight === row.controls.attachHeight; }),
        'the whole action row must be the height of the append-file control too, saw '
        + JSON.stringify(perPane.map(function (row) { return [row.controls.actionRowHeight, row.controls.attachHeight]; })));

      // Claim 4: one render path, and the pane-only artifacts gone.
      var mainMessages = document.getElementById('messages');
      facts.mainWrapper = {classes: mainMessages.className, part: mainMessages.getAttribute('data-part')};
      check(perPane.every(function (row) { return row.path.sharedShell && row.path.showMessagesType === 'undefined'; }),
        'a pane transcript must be the shared shell content region, with no renderer of its own, saw '
        + JSON.stringify(perPane.map(function (row) { return [row.key, row.path.sharedShell, row.path.showMessagesType]; })));
      check(mainMessages.classList.contains('messages') && mainMessages.getAttribute('data-part') === 'content'
        && perPane.every(function (row) { return row.path.sharedShell; }),
        'the main chat and every pane transcript must be the same wrapper (.messages / data-part=content), saw '
        + JSON.stringify(facts.mainWrapper));
      check(perPane.every(function (row) { return !row.path.earlierElement && !row.path.earlierText && !row.path.retrieveText; }),
        'no pane may carry `Earlier messages` or `Load original message N`, saw '
        + JSON.stringify(perPane.map(function (row) {
          return [row.key, row.path.earlierElement, row.path.earlierText, row.path.retrieveText];
        })));
      check(perPane.every(function (row) { return (row.path.notice || '') .indexOf('Ready for your next message') < 0; }),
        'no pane may restate completion in its own notice, saw '
        + JSON.stringify(perPane.map(function (row) { return [row.key, row.path.notice]; })));
      var settledKeys = ['child-5', 'child-6'];
      var settledRows = perPane.filter(function (row) { return settledKeys.indexOf(row.key) >= 0; });
      var runningRows = perPane.filter(function (row) { return settledKeys.indexOf(row.key) < 0; });
      check(settledRows.length === 2 && settledRows.every(function (row) { return row.path.bodySteps
        && row.path.footerInBubble && !row.path.footerAtTranscriptRoot
        && row.path.footerLabel === 'completed' && /^\d+:\d\d$/.test(String(row.path.footerElapsed))
        && row.path.statusLineHidden === true && String(row.path.notice).indexOf('Ready for your next message') < 0; }),
        'a settled child must draw the shared completion footer inside its bubble and stay quiet in its own readout, saw '
        + JSON.stringify(settledRows.map(function (row) {
          return [row.key, row.path.bodySteps, row.path.footerInBubble, row.path.footerAtTranscriptRoot,
            row.path.footerLabel, row.path.footerElapsed, row.path.statusLineHidden, row.path.notice];
        })));
      check(runningRows.every(function (row) { return row.path.statusLineHidden === false
        && String(row.path.notice).indexOf('Working.') === 0; }),
        'a running child must keep its live readout and say it is working, saw '
        + JSON.stringify(runningRows.map(function (row) { return [row.key, row.path.statusLineHidden, row.path.notice]; })));
      check(perPane.every(function (row) { return row.fold.okLine && row.fold.okOutputHidden === true
        && row.fold.errLine && row.fold.errOutputHidden === false; }),
        'the shared fold rule must hold in a pane: a successful payload folded, a failure forced open, saw '
        + JSON.stringify(perPane.map(function (row) { return [row.key, row.fold]; })));

      phase = 'comparing shapes';
      // The same ledger rows through the window's own renderer must draw the same DOM as the pane's transcript.
      var settledPane = panes.filter(function (pane) { return keyOf(pane) === 'child-5'; })[0];
      var settledPage = page('child-5');
      var childShape = settledPane ? shape(settledPane.transcript) : 'no settled pane';
      window.__repaintMessages(settledPage.messages, {state: 'answered', stateAt: base + 6, notify: false});
      var chatShape = shape(mainMessages);
      facts.shapes = {child: childShape, chat: chatShape};
      check(!!settledPane && childShape === chatShape && /WA-MESSAGE/.test(childShape)
        && childShape.indexOf('chat-content-run-status') >= 0,
        'the child transcript and the main chat must be one DOM for the same rows, saw ' + childShape + ' vs ' + chatShape);
      facts.mainChatAfterRepaint = chatShape;

      phase = 'reading lanes';
      var laneElements = Array.prototype.slice.call(panel.querySelectorAll('nav .lane'));
      facts.lanes = laneElements.map(function (group) {
        return {key: group.dataset.lane,
          path: textOf(group.querySelector('.lane-path')),
          count: group.querySelectorAll('.agent-card').length,
          checklist: Array.prototype.slice.call(group.querySelectorAll('.lane-check')).map(function (item) {
            return {outcome: item.dataset.outcome, state: item.dataset.state,
              shown: textOf(item.querySelector('.lane-check-state')),
              reason: item.title};
          })};
      });
      var keys = facts.lanes.map(function (lane) { return lane.key; }).sort();
      check(keys.join('|') === ['change/lane-alpha', 'change/lane-beta', 'main'].sort().join('|'),
        'lanes must be keyed on the child\'s recorded branch (or the node checkout), saw ' + JSON.stringify(keys));
      check(facts.lanes.map(function (lane) { return lane.key + ':' + lane.count; }).sort().join(' ')
        === 'change/lane-alpha:2 change/lane-beta:2 main:2',
        'each lane must hold its own children, saw '
        + JSON.stringify(facts.lanes.map(function (lane) { return lane.key + ':' + lane.count; })));
      check(facts.lanes.length === 3 && facts.lanes.every(function (lane) {
        return lane.checklist.map(function (item) { return item.outcome; }).join(',') === 'merged,retired,clean,main-only'
          && lane.checklist.every(function (item) { return item.state === 'yes' || item.state === 'no' || item.state === 'unknown'
            && item.shown === item.state; });
      }), 'every lane must carry the four-outcome checklist, each measured or explicitly unknown, saw ' + JSON.stringify(facts.lanes));
      var laneOf = function (key) { return facts.lanes.filter(function (entry) { return entry.key === key; })[0] || {checklist: []}; };
      var stateOf = function (key, outcome) {
        var item = laneOf(key).checklist.filter(function (entry) { return entry.outcome === outcome; })[0];
        return item ? item.state : 'missing';
      };
      check(stateOf('change/lane-beta', 'retired') === 'yes' && stateOf('change/lane-alpha', 'retired') === 'no',
        '`retired` must be measured from the lane\'s recorded checkout, saw beta=' + stateOf('change/lane-beta', 'retired')
        + ' alpha=' + stateOf('change/lane-alpha', 'retired'));
      check(stateOf('main', 'main-only') === 'yes' && stateOf('change/lane-alpha', 'main-only') === 'no',
        '`main-only` must be measured from the lane\'s recorded branch, saw main=' + stateOf('main', 'main-only')
        + ' alpha=' + stateOf('change/lane-alpha', 'main-only'));
      check(facts.lanes.every(function (entry) { return stateOf(entry.key, 'merged') === 'unknown'
        && stateOf(entry.key, 'clean') === 'unknown'; }),
        'the two outcomes this view cannot measure must be `unknown` rather than drawn as facts, saw '
        + JSON.stringify(facts.lanes.map(function (entry) { return [entry.key, stateOf(entry.key, 'merged'), stateOf(entry.key, 'clean')]; })));
      phase = 'done';
      log.setAttribute('data-status', problems.length ? 'fail' : 'pass');
      report();
      document.title = problems.length ? 'review: failed' : 'review: passed';
    } catch (error) {
      problems.push('the probe threw: ' + ((error && error.stack) || error));
      phase = 'threw';
      log.setAttribute('data-status', 'fail');
      report();
    }
  })();
})();
