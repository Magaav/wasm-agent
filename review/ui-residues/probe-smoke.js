// Smoke probe: does this runner stage a working page, does the delivered seam exist, and does the
// browser's virtual clock advance far enough for the watchdog's own timer to be exercised at all?
(function () {
  var out = document.createElement('pre');
  out.id = 'wa-probe';
  out.textContent = '{}';
  document.body.appendChild(out);
  var rec = {probe: 'smoke', stage: 'start', ticks: 0, slept: 0, thread: null, watch: null, app: null};
  function esc(text) { return text.replace(/[<>&]/g, function (c) { return c === '<' ? '\\u003c' : c === '>' ? '\\u003e' : '\\u0026'; }); }
  function save() { out.textContent = esc(JSON.stringify(rec)); }
  save();
  var ticks = 0;
  setInterval(function () { ticks += 1; rec.ticks = ticks; if (ticks % 5 === 0) save(); }, 1000);
  function sleep(ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); }
  (async function () {
    for (var i = 0; i < 200; i += 1) await Promise.resolve();
    rec.stage = 'ready-ish';
    rec.thread = typeof window.__chatThread === 'function' ? window.__chatThread() : 'no export';
    rec.watch = typeof window.__watchNow;
    rec.app = typeof window.__runStanding;
    rec.input = !!document.getElementById('input');
    rec.busy = !!(document.getElementById('send') && document.getElementById('send').classList.contains('busy'));
    rec.calls = (window.__calls || []).length;
    save();
    rec.stage = 'sleeping';
    save();
    for (var s = 0; s < 6; s += 1) { await sleep(1000); rec.slept = s + 1; rec.ticks = ticks; save(); }
    rec.stage = 'done';
    rec.verdict = ticks >= 5 ? 'virtual clock advances (' + ticks + ' ticks)' : 'INCONCLUSIVE: the virtual clock did not advance (' + ticks + ' ticks)';
    save();
  })();
})();
