// The `inspect` menu item, attacked in the main window.
//
// What this asks: is `inspect` exactly after `Reload window`; does asking twice reach ONE window
// (the shell keys a view by its name - modelled here as the shell really behaves); and does the
// asking window stay untouched - no reload, no navigation, no write, no other shell call, its
// transcript still the same nodes, and the app's own menu closed rather than left open.
(async function () {
  var problems = [];
  var report = {};
  function check(ok, label) { if (!ok) problems.push(label); }
  function tick() { return Promise.race([Promise.resolve(), new Promise(function (r) { setTimeout(r, 0); })]); }
  async function until(fn, tries) { for (var i = 0; i < (tries || 400); i += 1) { if (fn()) return true; await tick(); } return false; }

  await until(function () { return !!document.getElementById('attach'); }, 600);
  for (var i = 0; i < 200; i += 1) await tick();

  // A shell that behaves like rust/wa-window's: `open_view` refuses a title it already has
  // ("view {view} is already open") and opens nothing, so a second ask reuses the window.
  var base = window.__makeShell();
  var calls = [];
  var openTitles = [];
  var shell = Object.create(base);
  shell.openView = function (view, url) {
    calls.push({ call: 'openView', view: view, url: url });
    if (openTitles.indexOf(view) >= 0) { report.reused = true; return; }
    openTitles.push(view);
    base.openView(view, url);
  };
  ['closeView', 'setMode', 'expand', 'compact', 'maximize'].forEach(function (name) {
    shell[name] = function () { calls.push({ call: name }); };
  });
  shell.quit = function () { calls.push({ call: 'quit' }); };
  native = shell;                       // app.js's own top-level binding
  report.nativeInstalled = (typeof native === 'object' && native !== null);

  // State to compare against after the item runs.
  window.__reviewEpoch = (window.__reviewEpoch || 0) + 1;
  var firstBubble = document.querySelector('#messages wa-message');
  var bodyBefore = document.body.className;
  var hrefBefore = location.href;
  var fetchesBefore = (window.__calls || []).length;
  var transcriptBefore = document.querySelectorAll('#messages wa-message').length;

  // The app's own menu, drawn by the page's contextmenu listener.
  var menuEvent = new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 30, clientY: 30 });
  var dispatched = document.dispatchEvent(menuEvent);
  var menu = document.getElementById('context-menu');
  var items = (menu && menu.items) || [];
  var labels = items.map(function (item) { return item.label || (item.separator ? '---' : ''); });
  report.menu = labels;
  check(menuEvent.defaultPrevented && !dispatched,
    'the main window must still draw its own right-click menu (prevented=' + menuEvent.defaultPrevented + ')');
  var at = labels.indexOf('inspect');
  check(at >= 0 && labels[at - 1] === 'Reload window',
    'inspect must be the item immediately after Reload window, saw ' + JSON.stringify(labels));
  check(at >= 0 && labels[at + 1] === '---',
    'inspect must be the last of the three actions before the separator, saw ' + JSON.stringify(labels));

  // Ask for it twice through the menu's own click path (a click closes the menu and runs the item),
  // reopening the menu in between the way a reader right-clicking again would.
  function clickInspect() {
    var event = new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 30, clientY: 30 });
    document.dispatchEvent(event);
    var buttons = Array.prototype.slice.call(menu.querySelectorAll('.menu-item'));
    var button = buttons.filter(function (b) { return b.textContent === 'inspect'; })[0];
    if (!button) return false;
    button.click();
    return true;
  }
  var ranOnce = clickInspect();
  var closedAfterOne = !menu.hasAttribute('open');
  var ranTwice = clickInspect();
  check(ranOnce && ranTwice, 'the inspect item must be a clickable menu item');
  check(closedAfterOne, 'a click on the item must close the app menu, not leave it open over the chat');

  report.shellCalls = calls;
  var opened = calls.filter(function (c) { return c.call === 'openView'; });
  check(opened.length === 2, 'two invocations must ask the shell twice, saw ' + opened.length);
  check(opened.length === 2 && opened[0].view === 'inspect' && opened[1].view === 'inspect',
    'both asks must name the same view, saw ' + JSON.stringify(opened.map(function (c) { return c.view; })));
  check(opened.length === 2 && opened[0].url === opened[1].url,
    'both asks must use the same url, saw ' + JSON.stringify(opened.map(function (c) { return c.url; })));
  check(opened.length === 2 && /[?&]view=inspect/.test(opened[0].url) &&
    opened[0].url.indexOf(location.origin + location.pathname) === 0,
    'the ask must be this node\'s own page as ?view=inspect, saw ' + (opened[0] && opened[0].url));
  check(openTitles.length === 1, 'the shell must end up with ONE window, saw ' + JSON.stringify(openTitles));
  check(calls.every(function (c) { return c.call === 'openView'; }),
    'asking for the inspector must touch nothing else in the window it was asked from, saw ' + JSON.stringify(calls));
  check(!menu.hasAttribute('open'),
    'the app menu must be closed after the second ask too, not left open over the chat');

  // The asking window itself.
  check(window.__reviewEpoch === 1, 'the window that asked must not have reloaded');
  check(location.href === hrefBefore, 'the window that asked must not have navigated, saw ' + location.href);
  check(!!firstBubble && firstBubble.isConnected,
    'the transcript must be the same nodes after the ask (the window was not repainted from scratch)');
  check(document.querySelectorAll('#messages wa-message').length === transcriptBefore,
    'the transcript must be unchanged, saw ' + document.querySelectorAll('#messages wa-message').length + ' rows');
  check(document.body.className === bodyBefore, 'the body class must be unchanged, saw ' + document.body.className);
  var newFetches = (window.__calls || []).slice(fetchesBefore);
  check(newFetches.length === 0,
    'asking for the inspector must not itself talk to the node, saw ' + JSON.stringify(newFetches.slice(0, 3)));
  if (typeof menu.close === 'function') menu.close();

  // And it must be refused from inside a view, where a window opening a window is how you get two.
  var log = document.createElement('pre');
  log.id = 'wa-probe';
  log.setAttribute('data-status', problems.length ? 'fail' : 'pass');
  log.textContent = (problems.length ? 'FAIL: ' + problems.join(' ;; ') + ' || ' : 'PASS || ') + JSON.stringify(report);
  log.style.cssText = 'position:fixed;left:0;top:0;margin:0;z-index:100000;max-width:100%;white-space:pre-wrap';
  document.body.append(log);
})();
