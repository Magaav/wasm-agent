// Run with scripts/agent-benchmark-ui-observe.mjs --probe scripts/probe-chat-footer.js.
// Measures the actual footer boxes, including host-owned chips, on both chat hosts.
(async function () {
  const report = document.createElement('pre');
  report.id = 'wa-probe';
  report.hidden = true;
  document.body.append(report);
  let checks = 0;
  const check = (ok, label) => { if (!ok) throw Error(label); checks++; };
  try {
    await rendererLoaded;
    // Drain the fixture startup without relying on headless virtual-time timers.
    for (let i = 0; i < 200; i++) await Promise.resolve();
    const main = document.getElementById('chat');
    const panel = document.getElementById('panel');
    const parent = document.createElement('wa-orchestrator');
    parent.style.cssText = 'position:fixed;left:610px;top:0;width:600px;height:900px;display:flex';
    document.body.append(parent);
    const pane = parent.pin({subagent_id:'footer-fixture',session_id:'footer-fixture',state:'completed',settled:true,profile:'worker'});
    parent.querySelector('.orchestrator-sidebar').hidden = true;
    pane.style.height = '850px';
    pane.shell.setModelPicker([{label:'context',value:'unknown'}], '▤ ??%/?M');
    const row = document.createElement('wa-chat-actions');
    const declaration = document.createElement('span');
    declaration.dataset.action = 'fixture';
    declaration.textContent = 'Fixture action';
    row.append(declaration);
    pane.shell.querySelector('.footer-right').prepend(row);
    const shells = [main, pane.shell];
    const buttons = shell => Array.from(shell.querySelectorAll('.composer-footer button'));
    check(['user-btn','status-btn','mic','attach'].every(id => buttons(main).some(button => button.id === id)), 'all four main footer controls are measured');
    check(buttons(pane.shell).length === 3, 'child context, attach and labelled action are measured');
    for (const width of [320,540,800]) {
      panel.style.width = width + 'px';
      parent.style.width = width + 'px';
      for (const disabled of [false,true]) {
        for (const shell of shells) {
          shell.busy = disabled;
          for (const button of buttons(shell)) button.disabled = disabled;
          const boxes = buttons(shell).map(button => ({name:button.id || button.dataset.action || button.getAttribute('aria-label'),height:button.getBoundingClientRect().height}));
          check(boxes.every(box => Math.abs(box.height - 30) < 0.1), 'every footer control is 30px at width ' + width + ', disabled=' + disabled + ': ' + JSON.stringify(boxes));
        }
      }
    }
    for (const shell of shells) {
      shell.busy = false;
      for (const button of buttons(shell)) button.disabled = false;
    }
    panel.style.width = '600px';
    parent.style.width = '600px';
    // Leave both footer rows visible for the retained screenshot.
    report.dataset.status = 'pass';
    report.textContent = JSON.stringify({checks,skipped:0});
  } catch (error) {
    report.dataset.status = 'fail';
    report.textContent = String(error.stack || error);
  }
})();
