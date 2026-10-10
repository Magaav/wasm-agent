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
    report.dataset.status = 'pass'; report.textContent = JSON.stringify({ checks, skipped: 0 });
  } catch (error) {
    report.dataset.status = 'fail'; report.textContent = JSON.stringify({ checks, error: error.message });
  }
})();
