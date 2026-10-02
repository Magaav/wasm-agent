// What the delivered audits can and cannot see, measured on the page they run against.
//
// The delivery's coverage claim is about *rules*: the box and the paint from one rule, nothing else stated
// about a footer control, and the two same-kind controls computing the same style property for property.
// Its own suite is the instrument for that (this probe does not re-run the audits); this probe answers the
// two questions the suite's verdict alone cannot:
//   - is a one-control pseudo-element rule *real* (does it change what a reader sees on the pane's control
//     and not on the main one)? measured with getComputedStyle(el, '::before').
//   - why can the audits not enumerate it? measured with the same call the audits make:
//     el.matches(rule.selectorText).
(function () {
  var out = document.createElement('pre');
  out.id = 'wa-probe';
  out.textContent = '{}';
  document.body.appendChild(out);
  var rec = {probe: 'coverage', stage: 'start'};
  function esc(text) { return text.replace(/[<>&]/g, function (c) { return c === '<' ? '\\u003c' : c === '>' ? '\\u003e' : '\\u0026'; }); }
  function save() { out.textContent = esc(JSON.stringify(rec)); }
  save();
  function tick() { return Promise.resolve(); }
  async function until(fn, rounds) {
    rounds = rounds || 300;
    for (var i = 0; i < rounds; i += 1) { if (fn()) return true; await tick(); }
    return !!fn();
  }
  function pseudo(el) {
    var style = getComputedStyle(el, '::before');
    return {content: style.content, width: style.width, color: style.color, display: style.display};
  }
  (async function () {
    await until(function () { return !!customElements.get('wa-agent-session') && !!document.getElementById('attach'); }, 400);
    var pane = document.createElement('wa-agent-session');
    // Placed where a screenshot can see it: this probe exists to look at the control, not to lay out a pane.
    pane.style.cssText = 'position:fixed;left:8px;top:8px;background:#fff;padding:8px;z-index:9999;border:1px solid #999';
    document.body.appendChild(pane);
    await until(function () { return !!pane.querySelector('wa-chat-shell .chat-control'); }, 200);
    var paneControl = pane.querySelector('wa-chat-shell .chat-control');
    var mainControl = document.getElementById('attach');
    rec.paneFound = !!paneControl;
    rec.mainFound = !!mainControl;
    rec.paneControlClass = paneControl ? paneControl.className : null;
    if (paneControl && mainControl) {
      rec.paneBefore = pseudo(paneControl);
      rec.mainBefore = pseudo(mainControl);
      rec.paneLetterSpacing = getComputedStyle(paneControl).letterSpacing;
      rec.mainLetterSpacing = getComputedStyle(mainControl).letterSpacing;
      rec.paneMarginTop = getComputedStyle(paneControl).marginTop;
      rec.mainMarginTop = getComputedStyle(mainControl).marginTop;
      // The audits collect a rule only when the element matches its selectorText. A pseudo-element
      // selector is what a control's own ::before rule is keyed on, so this is the whole reason it is
      // invisible to them - and the same is true of a :hover rule and of a rule under a media condition
      // that does not hold at the test window's width.
      try {
        rec.matchesPseudoSelector = paneControl.matches('wa-agent-session .chat-control::before');
        rec.matchesPseudoSelectorThrows = false;
      } catch (error) {
        rec.matchesPseudoSelector = null;
        rec.matchesPseudoSelectorThrows = true;
      }
      try {
        rec.matchesHoverSelector = paneControl.matches('wa-agent-session .chat-control:hover');
      } catch (error) { rec.matchesHoverSelector = 'threw'; }
      rec.mediaWideHolds = window.matchMedia('(min-width: 1200px)').matches;
      rec.viewport = {w: window.innerWidth, h: window.innerHeight};
    }
    rec.stage = 'done';
    save();
  })().catch(function (error) {
    rec.stage = 'threw';
    rec.error = String((error && error.message) || error);
    save();
  });
})();
