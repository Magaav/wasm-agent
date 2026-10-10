// Disposable browser proof: subagent receipts and tool decisions share the topic pattern.
(async function () {
  const report = document.createElement('pre');
  report.id = 'wa-probe'; report.hidden = true; document.body.append(report);
  let checks = 0;
  const check = (ok, label) => { if (!ok) throw Error(label); checks++; };
  try {
    await rendererLoaded;
    for (let i = 0; i < 200; i++) await Promise.resolve();
    const messages = document.getElementById('messages');
    messages.replaceChildren();
    handleEvent({type:'delegated', task:{subagent_id:'topic-child',profile:'orchestration-worker',state:'accepted',session_id:'topic-child-session'}});
    const receipt = messages.querySelector('wa-subagent');
    check(!!receipt && !messages.querySelector('.subagent-card'), 'native delegation uses wa-subagent, not a bespoke card');
    check(receipt.classList.contains('topic') && receipt.querySelector('.trace-glyph').textContent.trim(), 'subagent uses the shared topic surface and has an icon');
    check(receipt.querySelector('.trace-label').textContent.includes('orchestration-worker') && receipt.querySelector('.trace-meta').textContent.includes('accepted'), 'receipt preserves profile and launch state without claiming completion');
    const head = receipt.querySelector('.trace-head');
    check(head.getAttribute('aria-expanded') === 'false' && receipt.body.hidden, 'receipt starts collapsed');
    head.click();
    check(head.getAttribute('aria-expanded') === 'true' && !receipt.body.hidden && receipt.querySelector('.trace-chevron').textContent === '⌄', 'receipt expands with the standard chevron');
    let opened = '';
    receipt.addEventListener('subagent-open', event => {opened = event.detail.session; event.stopImmediatePropagation();}, true);
    receipt.body.querySelector('button').click();
    check(opened === 'topic-child-session' && receipt.open, 'open conversation addresses the exact child and does not toggle the topic');
    check(receipt.body.textContent.includes('topic-child-session'), 'expanded receipt preserves the full child session');
    head.click();
    check(receipt.body.hidden && head.getAttribute('aria-expanded') === 'false', 'receipt collapses normally');

    handleEvent({type:'tool',name:'subagent',arguments:{action:'start',profile:'explore'}});
    handleEvent({type:'tool_result',name:'subagent',result:JSON.stringify({profile:'explore',state:'completed',settled:true,session_id:'legacy-child-session'})});
    const receipts = messages.querySelectorAll('wa-subagent');
    check(receipts.length === 2 && receipts[1].textContent.includes('settled'), 'legacy JSON tool receipt uses the same topic');
    const oldCount = receipts.length;
    renderSubagentCard('not JSON'); renderSubagentCard({ok:false,error:'refused'});
    check(messages.querySelectorAll('wa-subagent').length === oldCount, 'invalid/refused receipts do not fabricate children');
    const noSession = document.createElement('wa-subagent'); noSession.receipt = {profile:'worker',state:'unknown'};
    messages.append(noSession);
    check(!noSession.body.querySelector('button'), 'missing session does not invent an open action');
    noSession.remove();

    // Both hosts use the same renderer, including durable native delegation replay.
    const parent = document.createElement('wa-orchestrator');
    parent.style.cssText = 'position:fixed;left:650px;top:65px;width:600px;height:700px;z-index:30;background:var(--panel)';
    document.body.append(parent);
    const pane = parent.pin({subagent_id:'topic-pane',session_id:'topic-pane',profile:'worker',state:'running',settled:false});
    parent.querySelector('.orchestrator-sidebar').hidden = true;
    const rows = [{id:1,seq:1,role:'user',content:'Delegate a fixture',created_at:1},
      {id:2,seq:2,role:'assistant',phase:'final',content:'Delegated fixture',created_at:2,
        trace:[{kind:'delegation',ok:true,receipt:{subagent_id:'replayed-child',profile:'worker',state:'accepted',session_id:'replayed-session'}}]}];
    repaintMessages(rows, {state:'completed'});
    paintChildTranscript(pane.transcript, rows, {task:pane.task});
    for (const host of [messages,pane.transcript]) check(host.querySelector('wa-subagent .trace-meta').textContent.includes('accepted'), 'shared renderer replays durable delegation as the same topic');
    const hosts = [messages, pane.transcript];
    const shapes = [];
    for (const host of hosts) {
      const bubble = document.createElement('wa-message'); bubble.setAttribute('role','assistant'); host.append(bubble);
      bubble.body.classList.add('steps');
      const trace = document.createElement('wa-trace'); bubble.body.append(trace);
      trace.addDecision('topic-call','read','{"path":"DESIGN.md"}',false);
      const reasoning = document.createElement('wa-reasoning'); bubble.body.append(reasoning); reasoning.setText('Choosing a tool');
      const commentary = document.createElement('wa-commentary'); bubble.body.append(commentary); commentary.setText('Checking the layout');
      const diff = document.createElement('wa-diff'); bubble.body.append(diff); diff.setSummary({files:[{path:'ui/style.css',added:1,removed:1}],added:1,removed:1});
      const subagent = document.createElement('wa-subagent'); subagent.receipt = {profile:'worker',state:'running',session_id:'nested-child'}; bubble.body.append(subagent);
      const run = document.createElement('wa-run'); bubble.body.append(run); run.open = true;
      const retry = document.createElement('wa-retry'); bubble.body.append(retry);
      retry.update({index:1,limit:10,cycle:1,state:'attempting',reason:'fixture',window_ms:60000,elapsed_ms:0});
      check(Math.abs(run.querySelector('.trace-head').getBoundingClientRect().height - 28) < 0.1, 'run uses the same header geometry');
      const topics = [trace,reasoning,commentary,diff,subagent,retry];
      for (const width of [300,600]) {
        bubble.style.width = width + 'px';
        for (const nested of [false,true]) {
          for (const topic of topics) (nested ? run.body : bubble.body).append(topic);
          for (const topic of topics) {
            const header = topic.querySelector('.trace-head');
            const closedHeight = header.getBoundingClientRect().height;
            topic.open = true;
            const body = topic.body || topic.querySelector('.topic-body');
            const style = getComputedStyle(body);
            check(header.getBoundingClientRect().height === closedHeight && Math.abs(closedHeight - 28) < 0.1, 'one compact header height for ' + topic.tagName + ' at ' + width + ', nested=' + nested + ': ' + closedHeight);
            check(getComputedStyle(header).marginTop === '0px' && getComputedStyle(header).paddingTop === '5px', 'header uses the shared spacing scale');
            check(style.marginTop === '0px' && style.marginBottom === '0px', 'markdown cannot add topic body margins: ' + topic.tagName + ' ' + style.marginTop);
            if (topic === trace) check(style.paddingLeft === '0px' && getComputedStyle(body.querySelector('li')).marginTop === '0px', 'markdown cannot indent or space decision tool rows');
            shapes.push(closedHeight);
            topic.open = false;
          }
        }
      }
      // Markdown lists still get their intended spacing and indentation.
      const prose = document.createElement('div'); prose.className = 'seg'; prose.innerHTML = '<ul><li>Markdown item</li></ul>'; bubble.body.append(prose);
      check(getComputedStyle(prose.firstChild).marginTop === '5px' && getComputedStyle(prose.firstChild).paddingLeft === '20px', 'markdown list spacing is retained');
      for (const topic of topics) bubble.body.append(topic);
      run.remove();
      const decision = trace.querySelector('.tool-line');
      trace.addTool('read','DESIGN.md',null,null,'topic-call');
      trace.settle('ok','fixture result',false);
      check(trace.querySelector('.tool-line') === decision && !decision.classList.contains('decision'), 'decision promotion preserves one tool row');
      trace.finish();
      check(Math.abs(trace.querySelector('.trace-head').getBoundingClientRect().height - 28) < 0.1, 'finished tool topics retain the same header geometry');
      retry.freeze(); retry.remove(); trace.open = true; subagent.open = true;
    }
    check(shapes.every(height => height === shapes[0]), 'main and child topic headers have identical geometry');
    // Keep the main fixture and the child receipt side by side in the screenshot.
    document.getElementById('panel').style.width = '630px';
    report.dataset.status = 'pass'; report.textContent = JSON.stringify({checks,skipped:0});
  } catch (error) {
    report.dataset.status = 'fail'; report.textContent = String(error.stack || error);
  }
})();
