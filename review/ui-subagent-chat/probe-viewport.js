// Which layout viewport does this browser configuration actually give the page?
// The log element is written first and updated as the probe goes, so a dump that races the probe
// reports `running` rather than looking like a probe that failed to run.
(function () {
  var log = document.createElement('pre');
  log.id = 'wa-probe';
  log.setAttribute('data-status', 'running');
  log.style.cssText = 'position:fixed;bottom:0;left:0;pointer-events:none;background:#000;color:#0f0;font:10px monospace';
  log.textContent = 'VIEWPORT booting';
  document.body.appendChild(log);
  var seen = [];
  function snap(label) {
    seen.push(label + '=' + window.innerWidth + 'x' + window.innerHeight + '@' + window.devicePixelRatio);
    log.textContent = 'VIEWPORT ' + seen.join(' ');
  }
  (async function () {
    snap('load');
    for (var i = 0; i < 40; i += 1) await Promise.resolve();
    snap('ticks');
    await new Promise(function (resolve) { setTimeout(resolve, 400); });
    snap('timeout400');
    for (var k = 0; k < 300 && window.innerWidth < 1200; k += 1) {
      await new Promise(function (resolve) { setTimeout(resolve, 25); });
    }
    snap('poll-for-resize');
    await new Promise(function (resolve) { requestAnimationFrame(function () { resolve(); }); });
    snap('raf');
    log.setAttribute('data-status', 'pass');
    document.title = 'viewport: done';
  })();
})();
