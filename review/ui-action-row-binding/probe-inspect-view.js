// The `?view=inspect` page, attacked on its own.
//
// What this asks: does the inspector window really show the chat (not a stripped view), does it keep
// the browser's own context menu (Chrome's Inspect element lives there) instead of drawing this
// app's, does it open no second window, does it ask for no window resizing, does it only read from
// the node, and does it leave nothing of its own behind.
(async function () {
  var problems = [];
  var report = {};
  function check(ok, label) { if (!ok) problems.push(label); }
  function tick() { return Promise.race([Promise.resolve(), new Promise(function (r) { setTimeout(r, 0); })]); }
  async function until(fn, tries) { for (var i = 0; i < (tries || 400); i += 1) { if (fn()) return true; await tick(); } return false; }

  var base = window.__makeShell();
  var calls = [];
  var shell = Object.create(base);
  ['openView', 'closeView', 'setMode', 'expand', 'compact', 'maximize', 'quit'].forEach(function (name) {
    shell[name] = function () { calls.push({ call: name }); };
  });
  native = shell;
  report.viewMode = typeof viewMode === 'function' ? viewMode() : 'viewMode() missing';
  report.url = location.href;

  var booted = await until(function () { return !!document.getElementById('attach'); }, 600);
  check(booted, 'the inspector page must boot the shell (no #attach after 600 ticks)');
  if (typeof window.rendererLoaded !== 'undefined') await until(function () { return !!document.body.classList.contains('expanded'); }, 400);
  for (var i = 0; i < 200; i += 1) await tick();

  report.bodyClass = document.body.className;
  check(document.body.classList.contains('expanded') && !document.body.classList.contains('view-only'),
    'the inspector must show the chat itself, saw body: ' + document.body.className);
  check(!document.body.classList.contains('compact'),
    'the inspector must not stay compact (a fresh profile boots compact), saw body: ' + document.body.className);
  var furniture = ['chat', 'input', 'steer', 'attach', 'messages', 'send'].map(function (id) {
    return id + ':' + (document.getElementById(id) ? 'yes' : 'no');
  });
  report.furniture = furniture.join(' ');
  check(furniture.every(function (entry) { return /:yes$/.test(entry); }),
    'the inspector must open the furniture it is there to inspect, saw ' + furniture.join(' '));
  report.transcriptRows = document.querySelectorAll('#messages wa-message').length;
  check(report.transcriptRows > 0,
    'the inspector must show the conversation, saw ' + report.transcriptRows + ' rows');
  var shellEl = document.getElementById('chat');
  report.row = shellEl && shellEl.querySelector('wa-chat-actions') ? shellEl.querySelector('wa-chat-actions').tagName : 'none';
  check(report.row === 'WA-CHAT-ACTIONS', 'the inspector window must host the same action row, saw ' + report.row);

  // The browser's own menu, not this app's: the page must NOT swallow the event.
  var menuEvent = new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 20, clientY: 20 });
  var dispatched = document.dispatchEvent(menuEvent);
  var menu = document.getElementById('context-menu');
  report.menuDrawn = !!(menu && menu.hasAttribute('open'));
  check(dispatched && menuEvent.defaultPrevented === false,
    'the inspector must leave the browser\'s own context menu alone (prevented=' + menuEvent.defaultPrevented + ')');
  check(!report.menuDrawn, 'and must not draw this app\'s own menu in its place');

  // Nothing may be opened, resized or quit from inside a view.
  report.shellCalls = calls;
  check(calls.length === 0,
    'a view window must ask the shell for nothing (no second window, no resize), saw ' + JSON.stringify(calls));

  // Reads only.
  var all = window.__calls || [];
  var posts = all.filter(function (call) { return call.method === 'POST'; });
  report.reads = all.length;
  report.posts = posts.length;
  check(all.length > 0, 'the inspector must have read from the node, saw ' + all.length + ' call(s)');
  check(posts.length === 0, 'the inspector must only read: no POST may come from it, saw ' + JSON.stringify(posts.slice(0, 3)));

  // Leftovers of its own: no promoted window, no control/engine surface mounted, one mode class.
  report.windows = document.querySelectorAll('wa-window').length;
  report.controlSurface = !!document.querySelector('#control:not([hidden])');
  var modeClasses = ['compact', 'expanded', 'engine', 'shell', 'control'].filter(function (name) {
    return document.body.classList.contains(name);
  });
  report.modeClasses = modeClasses.join(',');
  check(report.windows === 0, 'the inspector must open no wa-window of its own, saw ' + report.windows);
  check(!report.controlSurface, 'the inspector must not mount the control surface');
  check(modeClasses.length === 1 && modeClasses[0] === 'expanded',
    'the inspector must be in exactly one mode, saw ' + modeClasses.join(','));

  var log = document.createElement('pre');
  log.id = 'wa-probe';
  log.setAttribute('data-status', problems.length ? 'fail' : 'pass');
  log.textContent = (problems.length ? 'FAIL: ' + problems.join(' ;; ') + ' || ' : 'PASS || ') + JSON.stringify(report);
  log.style.cssText = 'position:fixed;left:0;top:0;margin:0;z-index:100000;max-width:100%;white-space:pre-wrap';
  document.body.append(log);
})();
