// The reviewer's measurement probe for change/ui-action-row-binding.
//
// One instrument, run against the tip and against origin/main, at two viewports. It does
// not assert the delivery's claim by itself: it measures the four controls the claim is
// about and reports the numbers, and the expectation is chosen by the caller so the same
// instrument can be pointed at a tree where the claim is *false* (origin/main) and still
// produce a verdict.
//
//   ?review_expect=equal     - the four boxes must agree (the tip's claim)
//   ?review_expect=baseline  - the main Steer must be taller than the append-file control
//
// Nothing here reaches the node: test-fixtures.js has already stubbed fetch, and the only
// global functions called (setBusy) are app.js's own, by name, because app.js is a classic
// script and its top-level declarations are in the shared global scope.
(async function () {
  var problems = [];
  var report = {};
  function check(ok, label) { if (!ok) problems.push(label); }
  function tick() {
    return Promise.race([Promise.resolve(), new Promise(function (r) { setTimeout(r, 0); })]);
  }
  async function until(fn, tries) {
    for (var i = 0; i < (tries || 400); i += 1) { if (fn()) return true; await tick(); }
    return false;
  }

  // ---- measurement ---------------------------------------------------------------
  function describe(el) {
    if (!el) return 'none';
    return el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') +
      (el.className ? '.' + String(el.className).trim().split(/\s+/).join('.') : '');
  }
  function measure(el) {
    if (!el) return null;
    var rect = el.getBoundingClientRect();
    var st = getComputedStyle(el);
    return { what: describe(el), h: Math.round(rect.height * 10) / 10, w: Math.round(rect.width * 10) / 10,
      cssHeight: st.height, cssMinWidth: st.minWidth, cssPadding: st.padding,
      cssRadius: st.borderRadius, cssBorder: st.borderTopWidth, cssFont: st.fontSize,
      visible: rect.height > 0 && rect.width > 0 };
  }
  // Every rule in the document that states this control's box, listed per property: this is
  // "how many places state it" measured, not read off the source.
  function boxRules(el) {
    var props = ['height', 'min-height', 'max-height', 'width', 'min-width', 'max-width',
      'padding', 'padding-left', 'padding-top', 'padding-right', 'padding-bottom',
      'margin', 'margin-top', 'margin-left', 'margin-right', 'margin-bottom',
      'border-top-width', 'border-style', 'border-radius', 'font-size', 'font-family', 'font-weight',
      'line-height', 'letter-spacing', 'text-transform', 'color', 'background-color', 'box-shadow',
      'outline', 'opacity', 'transform', 'box-sizing', 'display', 'flex', 'gap'];
    var found = {};
    props.forEach(function (p) { found[p] = []; });
    var seen = 0;
    function walk(rules) {
      for (var i = 0; i < rules.length; i += 1) {
        var rule = rules[i];
        seen += 1;
        // A modern Chrome gives every style rule an (often empty) `cssRules` for CSS
        // nesting, so dispatch on the rule's own shape, not on that property.
        if (rule.selectorText !== undefined && rule.style) {
          var sels = rule.selectorText.split(',');
          for (var s = 0; s < sels.length; s += 1) {
            var sel = sels[s].trim();
            var hit = false;
            try { hit = el.matches(sel); } catch (error) { hit = false; }
            if (!hit) continue;
            for (var p = 0; p < props.length; p += 1) {
              var value = rule.style.getPropertyValue(props[p]);
              if (value && found[props[p]].indexOf(sel) < 0) found[props[p]].push(sel);
            }
          }
          if (rule.cssRules) walk(rule.cssRules);
          continue;
        }
        if (rule.cssRules) walk(rule.cssRules);
        continue;
      }
    }
    for (var i = 0; i < document.styleSheets.length; i += 1) {
      try { walk(document.styleSheets[i].cssRules); } catch (error) { /* unreadable sheet */ }
    }
    var out = {};
    Object.keys(found).forEach(function (p) { if (found[p].length) out[p] = found[p]; });
    out.__seen = seen;
    return out;
  }

  // ---- the app's own boot --------------------------------------------------------
  try {
  report.viewport = window.innerWidth + 'x' + window.innerHeight;
  var booted = await until(function () { return !!document.getElementById('attach'); }, 600);
  check(booted, 'the page must boot the shared shell (no #attach after 600 ticks)');
  await until(function () {
    var model = document.getElementById('composer-model');
    return !!model && model.textContent.indexOf('connecting') < 0;
  }, 600);

  // The main chat's Steer is revealed by the app's own setBusy, exactly as a run does it - and the
  // node is made to report a run in flight for *this* conversation (the fixture the app already reads
  // through activeRun), so the app's own health loop does not take the control down again mid-measure.
  var reveal = 'none';
  try {
    if (window.__fixtures && window.__fixtures.health && typeof chatSession !== 'undefined' && chatSession) {
      window.__fixtures.health.node_threads = [{ label: 'POST /chat', busy_ms: 15000, session: chatSession }];
    }
    if (typeof setBusy === 'function') { setBusy(true); reveal = 'setBusy(true)'; }
  } catch (error) { reveal = 'setBusy threw: ' + error.message; }
  var mainSteer = document.getElementById('steer');
  if (reveal === 'none' || (mainSteer && mainSteer.hidden)) {
    if (mainSteer) { mainSteer.hidden = false; reveal = reveal + '+hidden=false'; }
  }
  report.reveal = reveal;

  // A child pane, through the app's own component: the orchestrator pins a task into a pane.
  var pane = null;
  var showroom = null;
  var skipPane = new URLSearchParams(location.search).get('review_nopane') === '1';
  if (skipPane) report.panePath = 'skipped (review_nopane=1): the main footer stays visible for the screenshot'; else
try {
    showroom = document.createElement('wa-orchestrator');
    showroom.style.cssText = 'position:fixed;inset:0;width:100%;height:100%;z-index:9999';
    document.body.append(showroom);
    var task = { subagent_id: 'review-child', session_id: 'review-session', profile: 'worker',
      model: 'fixture', reasoning: 'max', execution_node: 'cloud', state: 'running', created_at: 0,
      prompt: 'review the row' };
    showroom.data = [task];
    pane = showroom.pin(task);
    report.panePath = 'wa-orchestrator.pin(task)';
  } catch (error) {
    report.panePath = 'orchestrator pin threw: ' + error.message;
  }
  check(!!pane || skipPane, 'a child pane must exist to measure: ' + report.panePath);
  report.pane = { exists: !!pane, showroomPanes: showroom && showroom.panes ? showroom.panes.size : null,
    shell: !!(pane && pane.querySelector('wa-chat-shell')) };

  var mainShell = document.getElementById('chat');
  var paneShell = pane ? pane.querySelector('wa-chat-shell') : null;
  check(!!mainShell && (!!paneShell || skipPane), 'both surfaces must host the shared shell');
  await until(function () {
    return !!(mainShell && mainShell.querySelector('[data-part="attach"]')) &&
      !!(paneShell && paneShell.querySelector('[data-part="attach"]'));
  }, 400);

  function rowOf(shell) { return shell ? shell.querySelector('wa-chat-actions, .chat-actions') : null; }
  var mainRow = rowOf(mainShell);
  var paneRow = rowOf(paneShell);
  function actionIn(row, name) {
    return row ? row.querySelector('[data-action="' + name + '"]') : null;
  }

  report.structure = {
    mainRow: describe(mainRow), paneRow: describe(paneRow),
    sameConstructor: !!(mainRow && paneRow && mainRow.constructor === paneRow.constructor),
    registeredElement: !!(mainRow && mainRow.constructor === customElements.get('wa-chat-actions')),
    mainSteerParent: describe(mainSteer ? mainSteer.parentElement : null),
    paneSteerParent: describe(actionIn(paneRow, 'steer') ? actionIn(paneRow, 'steer').parentElement : null),
    mainSteerId: mainSteer ? mainSteer.id : null,
    chatControlCount: document.querySelectorAll('.chat-control').length,
    chatActionCount: document.querySelectorAll('.chat-action').length,
    iconBtnCount: document.querySelectorAll('.icon-btn').length,
    controlSizeToken: getComputedStyle(document.documentElement).getPropertyValue('--control-size').trim(),
    rowControls: mainRow && typeof mainRow.controls !== 'undefined' ? mainRow.controls.length : null,
  };

  var mainAttach = mainShell ? mainShell.querySelector('[data-part="attach"]') : null;
  var paneAttach = paneShell ? paneShell.querySelector('[data-part="attach"]') : null;
  var paneSteer = actionIn(paneRow, 'steer');
  var paneCancel = actionIn(paneRow, 'cancel');
  var mic = document.getElementById('mic');
  var send = mainShell ? mainShell.querySelector('[data-part="send"]') : null;

  report.boxes = {
    'main-chat Steer': measure(mainSteer),
    'main-chat append-file': measure(mainAttach),
    'child-pane Steer': measure(paneSteer),
    'child-pane Cancel': measure(paneCancel),
    'child-pane append-file': measure(paneAttach),
    'main-chat mic (.icon-btn, same footer)': measure(mic),
    'main-chat send (.send)': measure(send),
  };
  check(skipPane || (!!mainSteer && !!mainAttach && !!paneSteer && !!paneCancel),
    'all four controls the claim is about must exist');
  check(Object.keys(report.boxes).every(function (k) { return !report.boxes[k] || report.boxes[k].visible; }),
    'every measured control must be rendered, not display:none');

  // The same kind of control on both surfaces must *compute* the same appearance: my own version of the
  // cross-surface comparison, over a property list I chose.
  var appearanceProps = ['height', 'min-width', 'padding-top', 'padding-left', 'padding-right',
    'border-top-width', 'border-top-style', 'border-top-color', 'border-radius', 'background-color',
    'color', 'font-size', 'font-family', 'font-weight', 'display', 'align-items', 'justify-content',
    'flex-grow', 'flex-shrink', 'flex-basis', 'cursor', 'box-sizing', 'letter-spacing', 'margin-top',
    'opacity', 'outline-width', 'box-shadow', 'transform'];
  function appearance(el) {
    if (!el) return 'none';
    var style = getComputedStyle(el);
    return appearanceProps.map(function (p) { return p + '=' + style.getPropertyValue(p); }).join(';');
  }
  report.appearance = { 'main action': appearance(mainSteer), 'child action': appearance(paneSteer),
    'main append-file': appearance(mainAttach), 'child append-file': appearance(paneAttach) };
  check(report.appearance['main action'] === report.appearance['child action'] &&
    report.appearance['main append-file'] === report.appearance['child append-file'],
    'the same kind of control must compute the same appearance on both surfaces, saw ' +
    JSON.stringify({ main: report.appearance['main action'], child: report.appearance['child action'] }));

  report.rules = {
    'main-chat Steer': mainSteer ? boxRules(mainSteer) : null,
    'main-chat append-file': mainAttach ? boxRules(mainAttach) : null,
    'child-pane Steer': paneSteer ? boxRules(paneSteer) : null,
    'main-chat mic (.icon-btn)': mic ? boxRules(mic) : null,
  };

  // Where the main footer actually sits, so a screenshot can be read against the numbers.
  var panel = document.querySelector('.panel');
  var mainFooter = mainShell ? mainShell.querySelector('.composer-footer') : null;
  report.mainLayout = { bodyClass: document.body.className,
    panel: panel ? [Math.round(panel.getBoundingClientRect().left), Math.round(panel.getBoundingClientRect().top),
      Math.round(panel.getBoundingClientRect().width), Math.round(panel.getBoundingClientRect().height),
      getComputedStyle(panel).position, getComputedStyle(panel).display] : null,
    footer: mainFooter ? [Math.round(mainFooter.getBoundingClientRect().left), Math.round(mainFooter.getBoundingClientRect().top),
      Math.round(mainFooter.getBoundingClientRect().width), Math.round(mainFooter.getBoundingClientRect().height)] : null,
    scroll: [window.scrollX, window.scrollY, document.documentElement.scrollHeight] };

  // The footer row at this viewport: a labelled action beside the model strip must not
  // overflow the footer it lives in.
  if (paneShell) {
    var footer = paneShell.querySelector('.composer-footer');
    var paneRowEl = paneRow;
    report.footer = { rowWidth: paneRowEl ? Math.round(paneRowEl.getBoundingClientRect().width) : null,
      footerWidth: footer ? Math.round(footer.getBoundingClientRect().width) : null,
      overflow: footer ? footer.scrollWidth - footer.clientWidth : null };
    check(footer ? footer.scrollWidth - footer.clientWidth <= 1 : false,
      'the composer footer must not overflow at this viewport, saw ' +
      (footer ? footer.scrollWidth - footer.clientWidth : 'no footer') + 'px');
  }

  // ---- the expectation the caller chose -----------------------------------------
  var expect = new URLSearchParams(location.search).get('review_expect') || '';
  var b = report.boxes;
  var four = ['main-chat Steer', 'main-chat append-file', 'child-pane Steer', 'child-pane Cancel'];
  var complete = four.every(function (k) { return !!b[k] && b[k].visible; });
  if (!complete && !skipPane) { check(false, 'the four controls must all be measured before any expectation can hold'); }
  if (expect === 'equal-main' && b['main-chat Steer'] && b['main-chat append-file']) {
    check(b['main-chat Steer'].h === b['main-chat append-file'].h && b['main-chat append-file'].h === 30,
      'expected the main chat Steer and the append-file control to be one 30px box, saw ' +
      b['main-chat Steer'].h + ' vs ' + b['main-chat append-file'].h);
    check(String(b['main-chat Steer'].what).indexOf('chat-control') >= 0 &&
      String(b['main-chat append-file'].what).indexOf('chat-control') >= 0,
      'expected both to carry .chat-control, saw ' + b['main-chat Steer'].what + ' / ' + b['main-chat append-file'].what);
  }
  if (expect === 'baseline-main' && b['main-chat Steer'] && b['main-chat append-file']) {
    check(b['main-chat Steer'].h > b['main-chat append-file'].h,
      'expected the main Steer to be taller than the append-file control on this tree, saw ' +
      b['main-chat Steer'].h + ' vs ' + b['main-chat append-file'].h);
  }
  if (expect === 'equal' && complete) {
    check(b['main-chat Steer'].h === b['main-chat append-file'].h &&
      b['child-pane Steer'].h === b['main-chat append-file'].h &&
      b['child-pane Cancel'].h === b['main-chat append-file'].h,
      'expected all four boxes to be the same height, saw ' + JSON.stringify([
        b['main-chat Steer'].h, b['main-chat append-file'].h, b['child-pane Steer'].h, b['child-pane Cancel'].h]));
    check(b['main-chat append-file'].h === 30 && b['main-chat append-file'].w === 30,
      'expected the append-file control to be the 30px square, saw ' +
      b['main-chat append-file'].h + 'x' + b['main-chat append-file'].w);
    check(['main-chat Steer', 'main-chat append-file', 'child-pane Steer', 'child-pane Cancel'].every(function (k) {
      return String(b[k].what).indexOf('chat-control') >= 0; }),
      'expected every one of the four to carry .chat-control, saw ' +
      JSON.stringify(['main-chat Steer', 'main-chat append-file', 'child-pane Steer', 'child-pane Cancel']
        .map(function (k) { return b[k].what; })));
  } else if (expect === 'baseline' && complete) {
    check(b['main-chat Steer'].h > b['main-chat append-file'].h,
      'expected the main Steer to be taller than the append-file control on this tree, saw ' +
      b['main-chat Steer'].h + ' vs ' + b['main-chat append-file'].h);
  } else {
    report.note = 'no review_expect given: numbers only';
  }

  } catch (error) {
    // An instrument that dies silently is worse than one that fails: report the throw.
    problems.push('the probe threw: ' + error.message + ' @ ' + String(error.stack).split('\n').slice(0, 3).join(' | '));
    report.threw = true;
  }

  // ---- the one line the caller reads ---------------------------------------------
  var log = document.createElement('pre');
  log.id = 'wa-probe';
  log.setAttribute('data-status', problems.length ? 'fail' : 'pass');
  log.textContent = (problems.length ? 'FAIL: ' + problems.join(' ;; ') + ' || ' : 'PASS || ') +
    'expect=' + expect + ' || ' + JSON.stringify(report);
  // Fixed, so the instrument does not become a flex sibling of the panel and change the very layout
  // it is measuring.
  log.style.cssText = 'position:fixed;left:0;top:0;margin:0;z-index:100000;max-width:100%;white-space:pre-wrap';
  document.body.append(log);
})();
