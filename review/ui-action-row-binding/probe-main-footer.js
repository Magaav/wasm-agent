// A deliberately tiny probe: reveal the main chat's Steer the way a run does, wait a beat, and
// report one short line. Used for the picture - the numbers come from probe-controls.js.
(async function () {
  function tick() { return Promise.race([Promise.resolve(), new Promise(function (r) { setTimeout(r, 0); })]); }
  for (var i = 0; i < 600 && !document.getElementById('attach'); i += 1) await tick();
  // Let the app itself believe a run is in flight for this conversation, so its own health loop keeps
  // the Steer up instead of taking it down again between the measurement and the picture.
  try {
    if (window.__fixtures && window.__fixtures.health && typeof chatSession !== 'undefined' && chatSession) {
      window.__fixtures.health.node_threads = [{ label: 'POST /chat', busy_ms: 15000, session: chatSession }];
    }
  } catch (error) { /* report below */ }
  var mode = '';
  if (typeof setBusy === 'function') { setBusy(true); mode = 'setBusy'; }
  var steer = document.getElementById('steer');
  if (steer && steer.hidden) { steer.hidden = false; mode += '+hidden=false'; }
  for (var j = 0; j < 200; j += 1) await tick();
  var attach = document.getElementById('attach');
  var row = document.querySelector('wa-chat-actions');
  var line = 'steer ' + (steer ? Math.round(steer.getBoundingClientRect().height) + 'x' + Math.round(steer.getBoundingClientRect().width) +
    ' [' + steer.className + ']' : 'none') +
    ' | attach ' + (attach ? Math.round(attach.getBoundingClientRect().height) + 'x' + Math.round(attach.getBoundingClientRect().width) +
    ' [' + attach.className + ']' : 'none') +
    ' | row ' + (row ? row.tagName : 'none') + ' | ' + mode;
  var log = document.createElement('pre');
  log.id = 'wa-probe';
  log.setAttribute('data-status', steer && attach ? 'pass' : 'fail');
  log.textContent = line;
  log.style.cssText = 'position:fixed;left:0;top:0;margin:0;z-index:100000';
  document.body.append(log);
})();
