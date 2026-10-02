// The right-click rule, in both directions, after the fix.
//
//   no ?view          - the main window draws this app's own menu, with `inspect` immediately after
//                       `Reload window`
//   ?view=orchestrator - a view that is not the inspector draws this app's own menu again (the rule the
//                       first delivery had changed for every view), and does NOT offer `inspect`, because
//                       `openInspectWindow` refuses from inside a view
//   ?view=inspect      - the inspector keeps the browser's own menu (the event is not swallowed)
(async function () {
  var problems = [];
  var report = { search: location.search || '(none)', bodyClass: document.body.className };
  function check(ok, label) { if (!ok) problems.push(label); }
  function tick() { return Promise.race([Promise.resolve(), new Promise(function (r) { setTimeout(r, 0); })]); }
  for (var i = 0; i < 300 && !document.getElementById('attach'); i += 1) await tick();
  for (var j = 0; j < 200; j += 1) await tick();

  var shell = window.__makeShell();
  var shellCalls = [];
  ['openView', 'closeView', 'setMode', 'expand', 'compact', 'maximize', 'quit'].forEach(function (name) {
    shell[name] = function () { shellCalls.push({ call: name }); };
  });
  native = shell;

  var view = typeof viewMode === 'function' ? viewMode() : '';
  report.view = view || '(none)';
  var event = new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
  var dispatched = document.dispatchEvent(event);
  var menu = document.getElementById('context-menu');
  report.prevented = event.defaultPrevented;
  report.menuDrawn = !!(menu && menu.hasAttribute('open'));
  report.items = (menu && menu.items ? menu.items : []).map(function (item) { return item.label || '---'; });

  if (view === 'inspect') {
    check(dispatched && event.defaultPrevented === false,
      'the inspector must leave the browser\'s own context menu alone, saw prevented=' + event.defaultPrevented);
    check(!report.menuDrawn, 'and must not draw this app\'s own menu in its place');
  } else {
    check(!dispatched && event.defaultPrevented === true,
      'a window of this app must draw this app\'s own menu, saw prevented=' + event.defaultPrevented);
    var at = report.items.indexOf('inspect');
    if (view) {
      check(report.items.join(',') === 'Collapse to avatar,Reload window,---,Close wasm-agent',
        'a view that is not the inspector must hold the menu it held before the inspector existed, saw ' +
        JSON.stringify(report.items));
      check(at < 0, 'and must not offer inspect, which it would refuse, saw ' + JSON.stringify(report.items));
    } else {
      check(at >= 0 && report.items[at - 1] === 'Reload window',
        'inspect must be the item immediately after Reload window in the main window, saw ' + JSON.stringify(report.items));
      check(report.items[at + 1] === '---',
        'and must be the last action before the separator, saw ' + JSON.stringify(report.items));
    }
  }
  report.shellCalls = shellCalls;
  check(shellCalls.length === 0, 'drawing the menu must not call the shell, saw ' + JSON.stringify(shellCalls));
  if (menu && typeof menu.close === 'function') menu.close();

  var log = document.createElement('pre');
  log.id = 'wa-probe';
  log.setAttribute('data-status', problems.length ? 'fail' : 'pass');
  log.textContent = (problems.length ? 'FAIL: ' + problems.join(' ;; ') + ' || ' : 'PASS || ') + JSON.stringify(report);
  log.style.cssText = 'position:fixed;left:0;top:0;margin:0;z-index:100000;max-width:100%;white-space:pre-wrap';
  document.body.append(log);
})();
