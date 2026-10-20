// Focused probe: the scroll-to-latest arrow in the chat content.
//
//   node scripts/agent-benchmark-ui-observe.mjs --ui <ui> --probe scripts/probe-scroll-to-bottom.js
//
// The arrow is the reader's way back to the tail of a long transcript, so the things that can go wrong
// are all positional and all measurable:
//
//   * it must be on screen ONLY while the transcript is away from the bottom - the rule is
//     `scrollTop + clientHeight < scrollHeight - 8` - and gone the moment the bottom is reached;
//   * it is pinned to the bottom of the CHAT CONTENT rect, inline-end aligned on the 5px scale, and
//     it does not scroll away with the transcript (an absolutely positioned child of the scroll
//     container would);
//   * the live run-status row is a control comparison: measured with the row hidden and with it
//     shown, the arrow sits 5px above the row's top edge and follows it in both directions, so the
//     two never stack or overlap;
//   * clicking reaches the bottom AND re-arms follow-the-tail, so the next streamed delta keeps the
//     reader at the bottom instead of dropping them off it again;
//   * aria state at both positions: labelled 'scroll to latest', focusable when shown, aria-hidden
//     and out of the tab order at the bottom;
//   * `prefers-reduced-motion: reduce` takes the instant path, not the animation.
//
// Asynchronous, unlike the structure probes: a smooth scroll is frames, so this one awaits frames and
// states which path it measured. Nothing here starts, stops or writes to the node.
(function () {
  var problems = [];
  function check(ok, label) { if (!ok) problems.push(label); }
  function round(value) { return Math.round(value * 10) / 10; }
  function distance() {
    return messages.scrollHeight - messages.scrollTop - messages.clientHeight;
  }
  // One turn of the event loop, whichever clock the harness advances: headless virtual time does not
  // always run animation frames, so a timer is raced against them rather than trusted alone.
  function step() {
    return new Promise(function (resolve) {
      var done = false;
      function finish() { if (!done) { done = true; resolve(); } }
      requestAnimationFrame(finish);
      setTimeout(finish, 40);
    });
  }
  function arrow() { return document.getElementById('jump'); }
  function region() { return messages.parentElement; }
  function statusRow() { return messages.querySelector('.chat-content-run-status:not(.finished)'); }
  function rectOf(node) { return node.getBoundingClientRect(); }
  // The motion preference is a fact about the machine, so the probe sets it rather than assuming it:
  // headless Chrome reports `prefers-reduced-motion: reduce` by default, and both paths have to be
  // measured on the same page.
  function preference(reduce, body) {
    var real = window.matchMedia;
    window.matchMedia = function (query) {
      if (String(query).indexOf('prefers-reduced-motion') >= 0) {
        return { matches: reduce === true, media: String(query), onchange: null,
          addEventListener: function () {}, removeEventListener: function () {},
          addListener: function () {}, removeListener: function () {},
          dispatchEvent: function () { return false; } };
      }
      return real.call(window, query);
    };
    try { return body(); } finally { window.matchMedia = real; }
  }
  // Frames plus a short settle: a streamed chunk can be repainted a frame after it was appended.
  async function settle(turns) {
    for (var i = 0; i < (turns || 4); i++) await step();
  }

  async function run() {
    var jump = arrow();
    var content = region();
    check(!!jump, 'the transcript must carry a scroll-to-latest arrow');
    check(!!content && content.classList.contains('chat-content'),
      'the chat content rect must be the transcript region, saw ' +
        (content ? content.className : 'no parent element'));
    if (!jump || !content) return 'FAIL: ' + problems.join(' ;; ');

    // ---- fixture: a transcript taller than the viewport, and the live status row taken out of play --
    document.body.classList.add('expanded');
    handleEvent({ type: 'round', n: 1, tools: 0, run_id: 'scroll-run', session_id: 'scroll-session' });
    handleEvent({ type: 'done' });
    clearStatus();
    messages.replaceChildren();
    runBubble = null; streamBody = null; streamText = '';
    streamedCommentaryBlock = null; streamedCommentaryText = '';
    phasePendingText = new Map();
    setFollow(true);
    for (var row = 0; row < 12; row++) add('user', 'Earlier evidence ' + row + ' ' + 'retained text '.repeat(40));
    messages.scrollTop = messages.scrollHeight;
    messages.dispatchEvent(new Event('scroll'));
    await step();

    check(messages.scrollHeight - messages.clientHeight > messages.clientHeight,
      'the fixture transcript must be taller than the viewport, saw ' +
        (messages.scrollHeight - messages.clientHeight) + 'px of range in ' + messages.clientHeight + 'px');
    check(distance() <= 8, 'the fixture starts at the bottom, saw ' + round(distance()) + 'px short');

    // ---- 1. at the bottom: no arrow, and nothing of it reachable --------------------------------
    check(!jump.classList.contains('show'),
      'control: the arrow must be hidden at the bottom, saw class ' + JSON.stringify(String(jump.className)));
    check(jump.getClientRects().length === 0, 'a hidden arrow must not be painted');
    check(jump.getAttribute('aria-hidden') === 'true',
      'at the bottom the arrow must be hidden from assistive tech, saw aria-hidden=' +
        JSON.stringify(jump.getAttribute('aria-hidden')));
    check(jump.tabIndex === -1, 'and it must not be focusable at the bottom, saw tabindex ' + jump.tabIndex);
    check(jump.getAttribute('aria-label') === 'scroll to latest',
      'the arrow must be named "scroll to latest", saw ' + JSON.stringify(jump.getAttribute('aria-label')));

    // ---- 2. scrolled up by more than the 8px rule: the arrow appears, pinned to the content rect -
    messages.scrollTop = Math.max(0, messages.scrollHeight - messages.clientHeight - 60);
    messages.dispatchEvent(new WheelEvent('wheel', { deltaY: -1 }));
    messages.dispatchEvent(new Event('scroll'));
    await step();
    check(distance() > 8, 'the fixture must be more than 8px from the bottom, saw ' + round(distance()));
    check(jump.classList.contains('show'),
      'the arrow must appear once the reader is away from the bottom by more than 8px');
    check(jump.getAttribute('aria-hidden') !== 'true',
      'a shown arrow must not be hidden from assistive tech, saw aria-hidden=' +
        JSON.stringify(jump.getAttribute('aria-hidden')));
    check(jump.tabIndex === 0, 'a shown arrow must be focusable, saw tabindex ' + jump.tabIndex);
    check(jump.tagName === 'BUTTON', 'the arrow must be a real control, saw <' + jump.tagName.toLowerCase() + '>');

    var contentRect = rectOf(content);
    var arrowRect = rectOf(jump);
    check(arrowRect.bottom <= contentRect.bottom + 0.5 && arrowRect.top >= contentRect.top - 0.5 &&
      arrowRect.right <= contentRect.right + 0.5 && arrowRect.left >= contentRect.left - 0.5,
      'the arrow must sit inside the chat content rect: arrow ' +
        [round(arrowRect.left), round(arrowRect.top), round(arrowRect.right), round(arrowRect.bottom)].join(',') +
        ' content ' +
        [round(contentRect.left), round(contentRect.top), round(contentRect.right), round(contentRect.bottom)].join(','));
    check(Math.abs((contentRect.bottom - arrowRect.bottom) - 5) <= 1,
      'with no status row the arrow sits 5px above the chat content bottom, saw ' +
        round(contentRect.bottom - arrowRect.bottom) + 'px');
    check(Math.abs((contentRect.right - arrowRect.right) - 5) <= 1,
      'the arrow is inline-end aligned on the 5px scale, saw ' +
        round(contentRect.right - arrowRect.right) + 'px from the inline end');
    check(Math.abs(Math.round(arrowRect.width) % 5) === 0 && Math.abs(Math.round(arrowRect.height) % 5) === 0,
      'the arrow is a square control on the 5px scale, saw ' + round(arrowRect.width) + 'x' + round(arrowRect.height));

    // It is pinned to the content rect, not to the transcript: two scroll positions, one position.
    messages.scrollTop = Math.max(0, messages.scrollTop - 120);
    messages.dispatchEvent(new Event('scroll'));
    await step();
    var pinnedRect = rectOf(jump);
    check(jump.classList.contains('show'), 'the arrow stays on screen while the reader keeps scrolling up');
    check(Math.abs(pinnedRect.bottom - arrowRect.bottom) <= 1 && Math.abs(pinnedRect.left - arrowRect.left) <= 1,
      'the arrow must not scroll away with the transcript: bottom ' + round(arrowRect.bottom) + ' -> ' +
        round(pinnedRect.bottom) + ', left ' + round(arrowRect.left) + ' -> ' + round(pinnedRect.left));

    // ---- 3. the run-status row: control comparison, hidden then shown ---------------------------
    // (a) hidden: measured above - 5px above the content bottom. It did not move the reader either.
    var readerBefore = messages.scrollTop;
    setStatus('reading the file');
    await step();
    var shownRow = statusRow();
    check(!!shownRow, 'the run-status row must be showing for the control comparison');
    check(messages.scrollTop === readerBefore,
      'showing the run-status row must not move the reader, saw ' + readerBefore + ' -> ' + messages.scrollTop);
    var rowRect = shownRow ? rectOf(shownRow) : null;
    var withRowRect = rectOf(jump);
    var withRowContent = rectOf(content);
    check(jump.classList.contains('show'), 'the arrow is still on screen with the run-status row showing');
    check(!!rowRect && withRowRect.bottom <= rowRect.top + 0.5,
      'the arrow must not overlap the run-status row: arrow bottom ' + round(withRowRect.bottom) +
        ' row top ' + (rowRect ? round(rowRect.top) : 'no row'));
    check(!!rowRect && Math.abs((rowRect.top - withRowRect.bottom) - 5) <= 1,
      'the arrow sits 5px above the run-status row, saw ' +
        (rowRect ? round(rowRect.top - withRowRect.bottom) : 'no row') + 'px');
    check(!!rowRect && (arrowRect.bottom - withRowRect.bottom) >= rowRect.height - 1,
      'the arrow moved up by at least the row height when it appeared: offset ' +
        round(arrowRect.bottom - withRowRect.bottom) + 'px, row height ' + (rowRect ? round(rowRect.height) : 'no row'));
    check(withRowRect.bottom <= withRowContent.bottom + 0.5 && withRowRect.top >= withRowContent.top - 0.5,
      'the arrow is still inside the chat content rect with the row showing');

    // (b) the row goes away again: the arrow follows it back down.
    clearStatus();
    await step();
    var restoredRect = rectOf(jump);
    check(!statusRow(), 'the run-status row is gone');
    check(Math.abs((rectOf(content).bottom - restoredRect.bottom) - 5) <= 1,
      'when the row disappears the arrow returns to 5px above the content bottom, saw ' +
        round(rectOf(content).bottom - restoredRect.bottom) + 'px');

    // ---- 4. click: reach the bottom, and re-arm follow-the-tail ---------------------------------
    function scrollUp(px) {
      messages.scrollTop = Math.max(0, messages.scrollHeight - messages.clientHeight - px);
      messages.dispatchEvent(new WheelEvent('wheel', { deltaY: -1 }));
      messages.dispatchEvent(new Event('scroll'));
    }
    var chunk = 'Following the tail. '.repeat(40);

    // CONTROL: the same delta arriving at the same scrollback position with the tail NOT re-armed.
    // This is what the click has to change - the reader is left where they were.
    scrollUp(300);
    await settle(1);
    var controlBefore = distance();
    check(controlBefore > 250, 'the control starts in scrollback, saw ' + round(controlBefore) + 'px');
    handleEvent({ type: 'delta', text: chunk });
    await settle();
    var controlAfter = distance();
    check(follow === false, 'control: without the click the reader is not following the tail');
    check(controlAfter >= controlBefore,
      'control: and a delta leaves them exactly where they were: ' + round(controlBefore) +
        ' -> ' + round(controlAfter) + 'px short of the bottom');

    // SUBJECT: the same position, the click, then the same delta. The smooth path, then aria state.
    scrollUp(300);
    await settle(1);
    check(jump.classList.contains('show'), 'the arrow is showing before the click, saw ' + round(distance()) + 'px short');
    preference(false, function () { jump.click(); });
    check(jump.dataset.motion === 'smooth',
      'a click with motion allowed must take the smooth path, saw ' + JSON.stringify(jump.dataset.motion));
    for (var frames = 0; frames < 80 && distance() > 1; frames++) await step();
    await settle(2);
    check(distance() <= 1, 'the click must reach the bottom, saw ' + round(distance()) + 'px short');
    check(!jump.classList.contains('show'), 'and the arrow must be gone at the bottom');
    check(jump.getAttribute('aria-hidden') === 'true' && jump.tabIndex === -1,
      'aria-hidden and out of the tab order once the bottom is reached, saw aria-hidden=' +
        JSON.stringify(jump.getAttribute('aria-hidden')) + ' tabindex ' + jump.tabIndex);
    check(follow === true, 'the click must re-arm follow-the-tail');
    var beforeDelta = messages.scrollHeight;
    handleEvent({ type: 'delta', text: chunk });
    await settle();
    check(messages.scrollHeight > beforeDelta + 100,
      'the delta must actually have grown the transcript, saw ' + beforeDelta + ' -> ' + messages.scrollHeight + 'px');
    check(atBottom() || distance() <= 8,
      'a delta streamed after the click must keep the view at the bottom (follow re-armed): ' +
        round(distance()) + 'px short of ' + messages.scrollHeight + ', follow=' + follow);
    handleEvent({ type: 'done' });
    clearStatus();

    // ---- 5. reduced motion: the instant path, same destination ----------------------------------
    scrollUp(300);
    await settle(1);
    check(jump.classList.contains('show'), 'the arrow is showing before the reduced-motion click');
    preference(true, function () {
      jump.click();
    });
    var immediate = distance();
    check(jump.dataset.motion === 'instant',
      'prefers-reduced-motion must take the instant path, saw ' + JSON.stringify(jump.dataset.motion));
    check(immediate <= 1,
      'the instant path must already be at the bottom in the same turn, saw ' + round(immediate) + 'px short');
    check(!jump.classList.contains('show'), 'and the arrow is not left on screen at the bottom');

    if (problems.length) return 'FAIL: ' + problems.join(' ;; ');
    return 'PASS: the arrow is absent at the bottom and present when the reader is away from it by ' +
      'more than 8px; it is pinned to the chat content rect, inline-end aligned, 5px above the content ' +
      'bottom and 5px above the live run-status row (measured with the row hidden and shown, and it ' +
      'follows the row both ways) without moving the reader; the click takes the smooth path to the ' +
      'bottom, hides the arrow, sets aria-hidden/not focusable, re-arms follow so the same delta that ' +
      'left the un-clicked reader behind keeps this one at the bottom; prefers-reduced-motion takes the ' +
      'instant path';
  }

  var result = { status: 'fail', text: 'probe did not finish' };
  Promise.resolve()
    .then(run)
    .then(function (text) { result = { status: /^PASS/.test(text) ? 'pass' : 'fail', text: text }; })
    .catch(function (error) {
      result = { status: 'fail', text: 'probe threw: ' + (error && (error.stack || error.message || error)) };
    })
    .then(function () {
      var pre = document.createElement('pre');
      pre.id = 'wa-probe';
      pre.setAttribute('data-status', result.status);
      pre.textContent = result.text;
      document.body.append(pre);
    });
})();
