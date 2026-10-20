// Focused probe: a topic is ONE component, and the prose inside it is Markdown.
//
//   node scripts/agent-benchmark-ui-observe.mjs --out <dir> --probe scripts/probe-topic-markdown.js
//
// Three operator-reported defects are measured here, on the real `handleEvent`:
//
//   1. the commentary topic was a second implementation of the thinking topic, so it did not collapse,
//      count or lay out its body the same way. Both tags must now be built by one class - the tag
//      classes add no behaviour - and behave identically: same header parts in the same order, same
//      header height, same toggle, same `N chars` meta, header above body.
//   2. a string printed inside ANY topic is Markdown, rendered by the transcript's one renderer:
//      `**bold**` -> <strong>, `` `x` `` -> <code>, a fenced block -> <pre><code>. Raw HTML stays
//      text: a literal `<text>` must appear as TEXT and create no element.
//   3. commentary streams INTO its topic from the first chunk when the phase is known, the way
//      thinking does. Asserted as the ancestry of the text node, not as a screenshot: the first
//      chunk's text node must already have a `wa-reasoning` / `wa-commentary` ancestor.
//
// Written without timers like the other probes, but it does await the real wasm Markdown renderer:
// "renders Markdown" cannot be proved by the pre-renderer fallback.
(async function () {
  var problems = [];
  function check(ok, label) { if (!ok) problems.push(label); }
  function tick() { return Promise.resolve(); }
  var result = { status: "fail", text: "probe did not finish" };
  try {
    await window.rendererLoaded;
    for (var i = 0; i < 200 && !window.handleEvent; i++) await tick();
    for (var m = 0; m < 200 && !document.getElementById("messages"); m++) await tick();
    var messages = document.getElementById("messages");
    check(!!messages && typeof window.handleEvent === "function",
      "the transcript and its event handler must exist before the probe can draw anything");
    for (var s = 0; s < 200; s++) await tick();
    messages.replaceChildren();

    // The text node carrying a chunk, so "is the string inside the topic?" is answered by ancestry.
    function textNodeUnder(root, needle) {
      var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) if (walker.currentNode.nodeValue.indexOf(needle) >= 0) return walker.currentNode;
      return null;
    }
    function lastOf(selector) {
      var all = messages.querySelectorAll(selector);
      return all[all.length - 1] || null;
    }
    function headerParts(topic) {
      var head = topic && topic.querySelector(":scope > .trace-head");
      return head ? Array.prototype.map.call(head.children, function (c) { return c.className; }).join(",") : "none";
    }
    function topicLayout(topic) {
      var head = topic && topic.querySelector(":scope > .trace-head");
      var body = topic && topic.querySelector(":scope > .topic-body");
      return { headerFirst: !!topic && topic.children[0] === head && topic.children[1] === body,
        headerHeight: head ? head.getBoundingClientRect().height : -1 };
    }
    function markdownProof(body, label) {
      var strong = body && body.querySelector("strong");
      check(!!strong && strong.textContent === "bold", label + ": **bold** must render as <strong>bold</strong>, saw " +
        (body ? JSON.stringify(body.innerHTML.slice(0, 240)) : "no body"));
      var inline = null;
      if (body) for (var code of body.querySelectorAll("code")) if (!code.closest("pre") && code.textContent === "x") inline = code;
      check(!!inline, label + ": `x` must render as inline <code>x</code>");
      var fence = body && body.querySelector("pre > code");
      check(!!fence && fence.textContent.indexOf("let y = 1;") >= 0,
        label + ": a fenced block must render as <pre><code>, saw " +
        (fence ? JSON.stringify(fence.textContent) : "none"));
      check(!!body && body.querySelector("text") === null, label + ": a literal <text> must create no element");
      check(!!body && body.textContent.indexOf("<text>") >= 0,
        label + ": a literal <text> must appear as its own text, saw " +
        (body ? JSON.stringify(body.textContent.slice(0, 160)) : "no body"));
    }

    // The same fixture in every prose body: one string proves the topic and the bubble agree.
    var FULL = "Checking **bold** and `x` and <text>\n```\nlet y = 1;\n```";

    // ---- 1. the thinking topic: the reference for streaming and for Markdown -------------------
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "reasoning", text: FULL });
    var think = lastOf("wa-reasoning");
    var thinkChunk = textNodeUnder(think || messages, "Checking");
    check(!!think && !!thinkChunk && thinkChunk.parentElement.closest("wa-reasoning") === think,
      "reference: the first thinking chunk's text node must already be inside the thinking topic");
    check(!!think && !!thinkChunk && think.body.contains(thinkChunk),
      "reference: the thinking text must be in the topic's own body, not beside it");
    var thinkLayout = topicLayout(think);
    check(thinkLayout.headerFirst, "reference: the thinking topic draws its header above its body");
    check(thinkLayout.headerHeight > 0 && headerParts(think) === "trace-glyph,trace-label,trace-meta,trace-chevron",
      "reference: the thinking header is glyph,label,meta,chevron, saw " + headerParts(think));
    check(!!think && think.querySelector(".trace-meta").textContent === FULL.length + " chars",
      "reference: the thinking meta counts the streamed characters, saw " +
      (think ? JSON.stringify(think.querySelector(".trace-meta").textContent) : "no topic"));
    markdownProof(think && think.body, "thinking");

    // ---- 2. commentary: the same component, streaming its Markdown into its own topic ----------
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "commentary_delta", pending_id: "md-oc", text: "Checking " });
    var commentary = lastOf("wa-commentary");
    var first = textNodeUnder(commentary || messages, "Checking");
    check(!!commentary && !!first && first.parentElement.closest("wa-commentary") === commentary,
      "commentary: the FIRST chunk's text node must already be inside the commentary topic, saw " +
      (commentary ? JSON.stringify(commentary.textContent.slice(0, 80)) : "no topic"));
    check(!!commentary && commentary.classList.contains("phase-pending"),
      "commentary: the topic that streamed the first token is the provisional one, not a later replacement");

    var full = FULL;
    window.handleEvent({ type: "commentary_delta", pending_id: "md-oc",
      text: full.slice("Checking ".length) });
    window.handleEvent({ type: "commentary", pending_id: "md-oc", message_id: "md-oc-1", text: full });
    var resolved = messages.querySelector('wa-commentary[data-message-id="md-oc-1"]');
    check(!!resolved && resolved === commentary,
      "commentary: the topic that streamed must BE the resolved topic, not be replaced by one");
    check(!!resolved && resolved.querySelector(".trace-meta").textContent === full.length + " chars",
      "commentary: its character count is the same measure thinking uses, saw " +
      (resolved ? JSON.stringify(resolved.querySelector(".trace-meta").textContent) : "no topic"));
    markdownProof(resolved && resolved.body, "commentary");

    // One implementation: the tag classes are names, and every observable of the topic agrees.
    var proto = function (node) { return node ? Object.getPrototypeOf(node.constructor) : null; };
    check(!!resolved && proto(resolved) === proto(think) && proto(think) !== HTMLElement &&
      Object.getOwnPropertyNames(resolved.constructor.prototype).length === 1 &&
      Object.getOwnPropertyNames(think.constructor.prototype).length === 1,
      "unified: <wa-commentary> and <wa-reasoning> must share one implementing class, and neither tag class may add behaviour");
    var commentaryLayout = topicLayout(resolved);
    check(commentaryLayout.headerFirst === thinkLayout.headerFirst &&
      commentaryLayout.headerHeight === thinkLayout.headerHeight && commentaryLayout.headerHeight > 0,
      "unified: the commentary draws the same header, in the same place, at the same height (" +
      commentaryLayout.headerHeight + " vs " + thinkLayout.headerHeight + ")");
    check(!!resolved && headerParts(resolved) === headerParts(think),
      "unified: the commentary header holds the same parts in the same order, saw " + headerParts(resolved));
    var toggles = [think, resolved].every(function (topic) {
      topic.open = false;
      var closed = topic.body.hidden && topic.getAttribute("open") === null &&
        topic.querySelector(".trace-chevron").textContent === "\u203a";
      topic.open = true;
      return closed && !topic.body.hidden && topic.querySelector(".trace-chevron").textContent === "\u2304";
    });
    check(toggles, "unified: the commentary collapses and expands exactly as the thinking topic does");

    // ---- 3. the honest constraint, still honoured: the phase arrives at step end, the text stays ---
    // The ordinary OpenAI-compatible route states no per-item phase (lua/core/agent.lua:1818-1821,
    // :1979-1980), so this prose streams in the answer's place and only then resolves to commentary.
    // That provisional state is allowed; what is not allowed is the sentence moving when it resolves.
    window.handleEvent({ type: "done" });
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "delta", text: FULL });
    var provisional = lastOf(".seg");
    var provisionalBox = provisional && provisional.getBoundingClientRect();
    window.handleEvent({ type: "step_phase", phase: "commentary",
      text: FULL, message_id: "md-in-place" });
    var inPlace = messages.querySelector('wa-commentary[data-message-id="md-in-place"]');
    check(!!inPlace, "phase-at-end: the resolved step must be a commentary topic");
    var inPlaceBox = inPlace && inPlace.querySelector(".commentary-body").getBoundingClientRect();
    check(!!provisionalBox && !!inPlaceBox &&
      Math.abs(provisionalBox.top - inPlaceBox.top) <= 1 &&
      Math.abs(provisionalBox.width - inPlaceBox.width) <= 1,
      "phase-at-end: resolving the phase must not move the streamed sentence, saw top/width " +
      (provisionalBox ? provisionalBox.top.toFixed(2) + "/" + provisionalBox.width.toFixed(2) : "none") + " -> " +
      (inPlaceBox ? inPlaceBox.top.toFixed(2) + "/" + inPlaceBox.width.toFixed(2) : "none"));
    markdownProof(inPlace && inPlace.body, "phase-at-end commentary");

    // The run is over: the commentary it ran through reads as the shared topic, the way a replayed
    // row is drawn - header above the body - while the run topic is folded away.
    window.handleEvent({ type: "reply", message_id: "md-answer", text: "It is fine." });
    window.handleEvent({ type: "done" });
    var run = lastOf("wa-run");
    var folded = run && run.querySelector("wa-commentary");
    check(!!folded && !folded.hasAttribute("data-in-place"),
      "settled: the folded commentary must take the shared topic's own layout");
    if (run) run.open = true;
    var foldedHead = folded && folded.querySelector(":scope > .trace-head").getBoundingClientRect();
    var foldedBody = folded && folded.querySelector(":scope > .commentary-body").getBoundingClientRect();
    check(!!foldedHead && !!foldedBody && foldedHead.top < foldedBody.top,
      "settled: the settled commentary draws its marker row above its body, like every other topic");

    result = { status: problems.length ? "fail" : "pass",
      text: problems.length ? "FAIL: " + problems.join(" ;; ")
        : "PASS: commentary and thinking are one topic, the topic body is the transcript's own Markdown " +
          "(**bold**, `x`, fenced block; raw tags stay text), and a commentary's first chunk already " +
          "streams inside its topic while the phase-at-end route still resolves without moving the text" };
  } catch (error) {
    result = { status: "fail", text: "probe threw: " + (error && (error.stack || error.message || error)) };
  }

  var pre = document.createElement("pre");
  pre.id = "wa-probe";
  pre.setAttribute("data-status", result.status);
  pre.textContent = result.text;
  document.body.append(pre);
})();
