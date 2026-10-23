(async function () {
  const report = document.createElement('pre');
  report.id = 'wa-probe'; report.hidden = true; document.body.append(report);
  let checks = 0;
  const check = (ok, label) => { if (!ok) throw Error(label); checks++; };
  const solid = color => color.startsWith('rgb(') || /^rgba\([^,]+,[^,]+,[^,]+,\s*1\)$/.test(color);
  const opaque = (el, label) => {
    const style = getComputedStyle(el);
    check(solid(style.backgroundColor), label + ' has an opaque fill: ' + style.backgroundColor);
    for (let node = el; node; node = node.parentElement) {
      check(getComputedStyle(node).opacity === '1', label + ' is not faded by an ancestor');
    }
  };
  const make = (tag, cls, parent = document.body) => {
    const el = document.createElement(tag); el.className = cls; parent.append(el); return el;
  };
  try {
    await rendererLoaded;
    for (let i = 0; i < 200 && !transcriptReady; i++) await Promise.resolve();
    check(transcriptReady, 'fixture transcript ready');
    for (let i = 1; i < 10000; i++) { clearTimeout(i); clearInterval(i); }
    // Assert authored states too, not just the states the fixture happens to display.
    const visit = rules => {
      for (const rule of rules) {
        if (rule.cssRules) visit(rule.cssRules);
        if (!rule.style) continue;
        check(!rule.style.opacity || Number(rule.style.opacity) === 1, 'no whole-element fading: ' + rule.cssText);
        for (const property of Array.from(rule.style)) {
          if (!/^(background|color|border)/.test(property)) continue;
          check(!/rgba\(|hsla\(|color-mix\(/.test(rule.style.getPropertyValue(property)), 'no alpha paint: ' + rule.cssText);
        }
      }
    };
    for (const sheet of document.styleSheets) visit(sheet.cssRules);
    check(document.querySelector('meta[name="apple-mobile-web-app-status-bar-style"]').content === 'black', 'opaque mobile status bar');
    for (const selector of ['html', 'body', '.topbar', '.composer', '#status-btn', '.control', '.control-bar', '.term-bar', '.term-in', '#status-balloon', '#user-menu']) {
      opaque(document.querySelector(selector), selector);
    }
    const root = make('section', ''); root.style.background = '#ff00ff';
    const assistant = make('wa-message', '', root);
    assistant.body.textContent = 'Solid topics and overlays keep underlying content hidden.';
    for (const tag of ['wa-run', 'wa-trace', 'wa-reasoning', 'wa-commentary', 'wa-diff']) {
      const topic = make(tag, '', assistant.body); opaque(topic, tag);
      if (tag === 'wa-commentary') {
        topic.classList.add('phase-pending'); opaque(topic, 'pending commentary');
        topic.classList.replace('phase-pending', 'phase-incomplete'); opaque(topic, 'incomplete commentary');
      }
    }
    const balloon = make('wa-balloon', 'file-diff', root);
    balloon.textContent = 'Opaque patch balloon'; balloon.show(); opaque(balloon, 'patch balloon'); balloon.remove();
    // Menus are authored markup in the app (their constructor supplies the class).
    root.insertAdjacentHTML('beforeend', '<wa-menu></wa-menu>');
    const menu = root.querySelector('wa-menu');
    menu.items = [{ label: 'Normal', action() {} }, { label: 'Danger', danger: true, action() {} }];
    menu.openAt(30, 100); opaque(menu, 'menu');
    menu.move(1); opaque(menu.querySelector('.selected'), 'selected item');
    menu.move(1); opaque(menu.querySelector('.selected'), 'selected danger item'); menu.remove();
    const input = document.querySelector('.composer textarea');
    input.focus();
    check(!/rgba\(/.test(getComputedStyle(input).backgroundImage), 'focused composer gradient has opaque stops');
    input.blur();
    check(!/rgba\(/.test(getComputedStyle(input).backgroundImage), 'resting composer gradient has opaque stops');
    for (const cls of ['chat-control', 'icon-btn', 'send', 'notify-test', 'diff-toggle']) {
      const button = make('button', cls, root); button.disabled = true;
      check(getComputedStyle(button).opacity === '1', cls + ' disabled without fading');
      if (cls !== 'diff-toggle') opaque(button, cls + ' disabled');
      check(getComputedStyle(button).cursor === 'default', cls + ' disabled affordance'); button.remove();
    }
    for (const state of ['completed', 'cancelled']) {
      const card = make('button', 'agent-card', root); card.dataset.state = state;
      opaque(card, state + ' card'); card.remove();
    }
    // Change what's behind an overlapping popup: its computed fill must not change.
    const popup = document.querySelector('#status-balloon');
    popup.show(); const before = getComputedStyle(popup).backgroundColor;
    document.querySelector('.composer').style.background = '#ff00ff';
    opaque(popup, 'popup over contrasting composer');
    check(getComputedStyle(popup).backgroundColor === before, 'popup fill independent of underlying content');
    document.querySelector('.composer').style.removeProperty('background'); popup.close();
    root.remove(); input.blur(); popup.show();
    // Sentinel queue overlay: active work is visible; once nothing is active it closes itself instead of
    // sitting in front of the chat. Failures remain in status and /health.
    const queue = document.getElementById('sentinel-queue');
    applySentinelQueue({sentinel:{active:1,failed:0,stale:false,requests:[{state:'running',verb:'deploy',phase:'installing',detail:'fixture'}]}});
    check(!queue.hidden && queue.textContent.includes('deploy') && queue.textContent.includes('installing'), 'sentinel queue shows active work');
    // A detached deploy is state=done/phase=spawned while /health.upgrading is queued; it is still active.
    applySentinelQueue({upgrading:{state:'queued'},sentinel:{active:0,failed:0,stale:false,requests:[{state:'done',phase:'spawned',verb:'deploy',age_seconds:10,detail:'fixture deploy'}]}});
    check(!queue.hidden && queue.textContent.includes('fixture deploy'), 'sentinel queue shows a spawned deploy while upgrading');
    applySentinelQueue({upgrading:{state:'done'},sentinel:{active:0,failed:1,stale:false,requests:[{state:'failed',verb:'restart',phase:'failed',detail:'fixture'}]}});
    check(queue.hidden, 'sentinel queue closes when no work is active');
    // --- restart recovery: install bar, offline status, and a hung transcript restore ---
    // The bar is retained across the null-health gap of an install, but a health answer that
    // reports done/failed/absent must take it down instead of leaving 'node restarting' forever.
    const upgradeBar = document.getElementById('upgrade-bar');
    applyUpgradeState({upgrading:{state:'upgrading',phase:'installing',to:'fixture build'}});
    check(!upgradeBar.hidden && upgradeBar.dataset.phase === 'installing', 'upgrade bar shows a live install');
    applyUpgradeState(null);
    check(!upgradeBar.hidden, 'upgrade bar survives the null-health gap of a restart');
    applyUpgradeState({upgrading:{state:'failed'}});
    check(upgradeBar.hidden && !document.body.classList.contains('upgrading'), 'upgrade bar hides when upgrading.state is failed');
    applyUpgradeState({upgrading:{state:'done'}});
    check(upgradeBar.hidden && !document.body.classList.contains('upgrading'), 'upgrade bar hides when upgrading.state is done');
    // A recovery /version read must clear the restart claim, not just the bar.
    applyUpgradeState({upgrading:{state:'upgrading',phase:'installing',to:'fixture build'}});
    nodeOffline(true);
    check(document.body.classList.contains('node-offline'), 'a restart marks the node offline');
    check(/restart/i.test((statusLine && statusLine.textContent) || ''), 'the restart status is visible');
    const recovered = await recoverAfterNodeReturn(Object.assign({}, window.__fixtures.health, {upgrading:{state:'done'}}));
    check(recovered === true, 'recovery reads health when the node answers');
    check(!document.body.classList.contains('node-offline'), 'health recovery clears the offline class');
    check(statusLine === null, 'health recovery clears the stale restart status');
    check(upgradeBar.hidden && !document.body.classList.contains('upgrading'), 'health recovery hides the upgrade bar');
    // A live run does not make a restart/offline claim true; the health answer still clears it.
    busy = true;
    applyUpgradeState({upgrading:{state:'upgrading',phase:'installing',to:'fixture build'}});
    nodeOffline(true);
    applyUpgradeState({upgrading:{state:'done'}});
    check(!document.body.classList.contains('node-offline') && statusLine === null, 'health recovery clears restart status while a run is busy');
    busy = false;
    // A pending restore can hang forever after a restart. It must be abandoned by its
    // generation/deadline so a watch retry starts a fresh request instead of reusing it.
    conversationEpoch += 1;
    const stalledBefore = window.__stalledSessionReads || 0;
    window.__stallSession = true;
    const hung = restoreSession(chatSession);
    for (let i = 0; i < 100 && (window.__stalledSessionReads || 0) === stalledBefore; i++) await Promise.resolve();
    const stalled = restoringSession;
    check(!!stalled && stalled.promise === hung, 'a hung restore is tracked as one pending attempt');
    check((window.__stalledSessionReads || 0) === stalledBefore + 1, 'the hung restore started its transcript read');
    const joined = restoreSession(chatSession, true);
    check(joined === hung, 'a watch retry joins the pending attempt once');
    check(restoringSession === stalled && !stalled.abandoned, 'the first retry does not abandon a live attempt');
    check(restoreAttemptStale({startedAt: Date.now() - RESTORE_ATTEMPT_DEADLINE_MS - 1, progressAt: Date.now(), retryWaits: 0, abandoned: false}, false), 'an attempt past its deadline is stale');
    stalled.progressAt = Date.now() - RESTORE_STALL_MS - 1;
    const fresh = restoreSession(chatSession, true);
    check(stalled.abandoned && stalled.controller.signal.aborted, 'an expired attempt is abandoned and aborted');
    check(fresh !== joined, 'an expired attempt is never handed to a later retry');
    check((window.__stalledSessionReads || 0) === stalledBefore + 2, 'the retry starts a fresh transcript request');
    check(restoringSession && restoringSession !== stalled, 'a fresh attempt is pending after the retry');
    // Recovery releases the new pending attempt too, then completes against the live node.
    window.__stallSession = false;
    const sessionReads = () => (window.__calls || []).filter(call => String(call.url).startsWith('session?')).length;
    const readsBeforeRecovery = sessionReads();
    const recoveredRestore = await restoreSession(chatSession, true, true);
    check(recoveredRestore === true, 'a forced restore after recovery completes');
    check(transcriptReady === true && restoringSession === null, 'recovery leaves no pending restore');
    check(sessionReads() === readsBeforeRecovery + 1, 'the forced restore issues one more fresh transcript read');
    check((window.__stalledSessionReads || 0) === stalledBefore + 2, 'recovery did not replay the stalled reads');
    check(Number(followedSeq) === 4, 'the restored cursor still covers every saved row');
    check(messages.textContent.includes('legacy fallback'), 'the recovered transcript repaints the saved history');
    // --- topic collapse, character-array details, and one max-height cap ---
    check(toolDetail(['l', 'u', 'a']) === 'lua', 'a character array is shown as one string, not one character per line');
    const nestedDetail = toolDetail({ error: ['p', 'r', 'o', 'v', 'i', 'd', 'e', 'r'] });
    check(nestedDetail.includes('"error": "provider"'), 'a character array inside a result is normalised too');
    const topicStage = document.createElement('div');
    topicStage.className = 'msg body steps';
    topicStage.style.cssText = 'width:700px;';
    document.body.append(topicStage);
    const plain = make('wa-trace', '', topicStage);
    plain.addTool('tool_call', 'arguments={...}', null, 149, 'plain-call', null);
    check(!plain.open, 'a plain tool-call topic is collapsed in the shared component');
    const decision = make('wa-trace', '', topicStage);
    decision.addDecision('decision-call', 'tool_call', '{}', true);
    check(decision.open, 'a decision topic still opens');
    const running = make('wa-trace', '', topicStage);
    running.addTool('bash', 'run', null, 300, 'running-call', null);
    check(running.querySelector('.trace-label').textContent === 'running…', 'a pending tool call is running, not deciding');
    for (const [tag, bodyClass] of [['wa-trace', 'trace-body'], ['wa-reasoning', 'reasoning-body'], ['wa-commentary', 'commentary-body'], ['wa-diff', 'diff-body']]) {
      const topic = make(tag, '', topicStage);
      const body = topic.querySelector('.' + bodyClass);
      check(body && getComputedStyle(body).maxHeight !== 'none', tag + ' topic body has a max-height');
      check(body && getComputedStyle(body).maxHeight.endsWith('px'), tag + ' topic body resolves to one pixel cap');
    }
    const traceCap = getComputedStyle(plain.querySelector('.trace-body')).maxHeight;
    const reasoningCap = getComputedStyle(make('wa-reasoning', '', topicStage).querySelector('.reasoning-body')).maxHeight;
    check(traceCap === reasoningCap, 'tool and thinking topic bodies share one max-height cap');
    plain.addTool('tool_call', 'failed', null, 149, 'failed-call', null);
    plain.settle('failed', toolDetail(['f', 'a', 'i', 'l']), true);
    check(plain.querySelector('.tool-output').textContent === 'fail', 'failed detail is not rendered as a vertical character column');
    check(getComputedStyle(plain.querySelector('.tool-output')).maxHeight === 'none', 'the tool row does not impose a second nested cap');
    // The main-chat path: a tool call after commentary used to be promoted by the app's `prior`
    // heuristic. Exercise the real event path, not just the component.
    busy = true; runBubble = null; runStepState = null; clearStatus();
    repaintMessages([], { active: true, notify: false });
    handleEvent({ type: 'commentary_delta', pending_id: 'collapse-step', text: 'Checking the next step.' });
    handleEvent({ type: 'tool', name: 'bash', call_id: 'collapse-tool', arguments: { command: 'true' } });
    const appTrace = runBubble && runBubble.querySelector('wa-trace');
    check(appTrace && !appTrace.open, 'a main-chat tool call after commentary is created collapsed');
    report.dataset.status = 'pass'; report.textContent = JSON.stringify({ checks, skipped: 0 });
  } catch (error) {
    report.dataset.status = 'fail'; report.textContent = JSON.stringify({ checks, error: error.message });
  }
})();
