// The right-click rule outside the inspector: what a *view* window keeps now.
// Run against ?view=orchestrator (a view that is not the chat) to see whether the app's own menu
// is still drawn there - the delivery changed the rule for every view, not only for the inspector.
(async function () {
  function tick() { return Promise.race([Promise.resolve(), new Promise(function (r) { setTimeout(r, 0); })]); }
  for (var i = 0; i < 200; i += 1) await tick();
  var shell = window.__makeShell();
  native = shell;
  var event = new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 10, clientY: 10 });
  var dispatched = document.dispatchEvent(event);
  var menu = document.getElementById('context-menu');
  var log = document.createElement('pre');
  log.id = 'wa-probe';
  log.setAttribute('data-status', 'pass');
  log.textContent = JSON.stringify({
    view: location.search,
    bodyClass: document.body.className,
    eventNotSwallowed: dispatched && event.defaultPrevented === false,
    appMenuDrawn: !!(menu && menu.hasAttribute('open')),
    menuItems: menu && menu.items ? menu.items.map(function (item) { return item.label || '---'; }) : null,
  });
  log.style.cssText = 'position:fixed;left:0;top:0;margin:0;z-index:100000;max-width:100%;white-space:pre-wrap';
  document.body.append(log);
})();
