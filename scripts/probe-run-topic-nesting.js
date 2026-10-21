// Focused probe: where a run's steps are drawn while it is still stepping, and where they end up
// when its final answer arrives.
//
//   node scripts/agent-benchmark-ui-observe.mjs --out <dir> --probe scripts/probe-run-topic-nesting.js
//
// Replays the two live shapes the node emits for a step whose prose is *commentary* rather than an
// answer (see lua/core/agent.lua's `step_phase` and lua/core/openai_sub_bridge.lua's
// `commentary_delta`/`commentary`), through the real `handleEvent`, and asserts the structure the
// design calls for (DESIGN.md section 6):
//
//   * while the run is stepping, every step - tool calls AND commentary - is a direct child of the
//     conversation bubble; no run topic exists yet.
//   * a streamed sentence whose phase resolves to commentary becomes the commentary topic *in place*:
//     its first chunk is already inside a commentary topic when the provider stated the phase up
//     front, and it does not jump when the phase is only resolved at the end of the step.
//   * only the final answer folds the history: tool steps and commentary then live in one collapsed
//     run topic, and the answer is what stays outside it.
//
// WHERE IT MOVED is measured as geometry, not as element order: DOM order was preserved by
// `replaceWith` while the operator watched the sentence re-lay out. The honest rule is that a
// commentary is an ordinary topic at every instant: its header row is ABOVE its body, its body is
// INSIDE the topic's box, and the shared topic's own chrome is drawn. So the streamed sentence may
// move DOWN by exactly the header row's height (measured, not ignored) when the phase resolves; what
// must not happen is the sentence being re-created somewhere else - it keeps the same parent and the
// same sibling index - nor a second, chrome-less layout for the live state (the removed
// `[data-in-place]` exception, which drew the header below the prose and the prose outside a box).
// On the routes whose node was already a `wa-commentary` (same element, same box) the resolution
// must leave width, font, line-height and padding untouched as well.
//
// Written without await and without timers: headless virtual time does not advance, so the probe
// runs synchronously against the DOM `handleEvent` built.
(function () {
  var problems = [];
  var notes = [];
  function check(ok, label) { if (!ok) problems.push(label); }
  function indexIn(parent, node) { return Array.prototype.indexOf.call(parent.children, node); }
  // The element whose box the reader is watching: a streamed `.seg` is its own text box, and a
  // commentary's text is its body (the topic's outer box also holds the marker row).
  function textNode(node) {
    if (!node) return null;
    return node.tagName === "WA-COMMENTARY" ? node.querySelector(".commentary-body") : node;
  }
  function textBox(node) {
    var text = textNode(node);
    if (!node || !text) return null;
    var rect = text.getBoundingClientRect();
    var style = getComputedStyle(text);
    var parent = node.parentNode;
    return { top: rect.top, left: rect.left, width: rect.width, fontSize: style.fontSize,
      lineHeight: style.lineHeight, padding: style.padding, parent: parent,
      index: parent ? indexIn(parent, node) : -1 };
  }
  function rectText(r) {
    return r ? "l=" + r.left.toFixed(1) + " t=" + r.top.toFixed(1) + " " + r.width.toFixed(1) +
      "x" + r.height.toFixed(1) : "none";
  }
  function boxText(b) {
    return b ? "top=" + b.top.toFixed(2) + " left=" + b.left.toFixed(2) +
      " width=" + b.width.toFixed(2) + " index=" + b.index + " font=" + b.fontSize +
      " line=" + b.lineHeight + " padding=" + b.padding : "none";
  }
  // Establishing the phase never re-creates the sentence: it keeps the same parent and the same
  // sibling index, so it is not drawn somewhere else in the bubble.
  function samePlace(before, after) {
    if (!before || !after) return false;
    return before.parent === after.parent && before.index === after.index;
  }
  // The document order of the bubble's own children IS the order the steps happened in. Asked of the
  // DOM, not of the array index: `compareDocumentPosition` answers about the order the reader sees,
  // and it answers even after one of the two nodes has been moved into a run topic.
  function precedes(a, b) {
    if (!a || !b || a === b) return false;
    return (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0;
  }
  // Same element, same place: the resolved box is still where the reader was reading (1px).
  function unmoved(before, after) {
    return !!before && !!after && Math.abs(before.top - after.top) <= 1 &&
      Math.abs(before.left - after.left) <= 1;
  }
  // On a route that resolves the node it already streamed into (same element), the box it carries
  // must be untouched: same width, font, line-height and padding.
  function sameTypography(before, after) {
    if (!before || !after) return false;
    return Math.abs(before.width - after.width) <= 1 && before.fontSize === after.fontSize &&
      before.lineHeight === after.lineHeight && before.padding === after.padding;
  }
  // The operator's complaint, as a measurement: the prose sits inside the topic's own border box.
  function bodyInsideTopic(topic) {
    var text = textNode(topic);
    if (!topic || !text) return false;
    var t = text.getBoundingClientRect(), box = topic.getBoundingClientRect();
    return t.top >= box.top - 0.5 && t.bottom <= box.bottom + 0.5 &&
      t.left >= box.left - 0.5 && t.right <= box.right + 0.5;
  }
  // A topic draws its header ABOVE its body - the same shape as <wa-reasoning> and <wa-trace>.
  function headerAbove(topic) {
    var text = textNode(topic);
    var head = topic && topic.querySelector(":scope > .trace-head");
    if (!text || !head) return false;
    var t = text.getBoundingClientRect(), h = head.getBoundingClientRect();
    return h.height > 0 && h.top < t.top && h.bottom <= t.top + 0.5;
  }
  // A commentary is the shared topic: it must draw that topic's own box, not a chrome-less variant.
  function sharedTopicChrome(topic) {
    if (!topic) return false;
    var style = getComputedStyle(topic);
    var border = parseFloat(style.borderTopWidth) || 0;
    var bg = style.backgroundColor;
    var painted = style.backgroundImage !== "none" && style.backgroundImage !== "" ||
      (!!bg && bg !== "transparent" && bg !== "rgba(0, 0, 0, 0)");
    return border > 0 && painted;
  }
  // The streamed sentence may move DOWN by the header row's height plus the topic's top border, and
  // by nothing else. Measured from the two real rects, never assumed.
  function shiftIsHeader(before, topic) {
    var text = textNode(topic);
    if (!before || !text) return false;
    var shift = text.getBoundingClientRect().top - before.top;
    var head = topic.querySelector(":scope > .trace-head");
    var border = parseFloat(getComputedStyle(topic).borderTopWidth) || 0;
    var expected = (head ? head.getBoundingClientRect().height : NaN) + border;
    return isFinite(expected) && Math.abs(shift - expected) <= 0.5;
  }
  function markerText(topic) {
    var head = topic && topic.querySelector(".trace-head");
    if (!head) return "none";
    var r = head.getBoundingClientRect();
    return "top=" + r.top.toFixed(2) + " left=" + r.left.toFixed(2) +
      " width=" + r.width.toFixed(2) + " height=" + r.height.toFixed(2);
  }
  // The marker row's own rect, for the message that shows where the chrome went.
  function lastAssistant() {
    var bubbles = document.querySelectorAll('#messages wa-message[role="assistant"]');
    return bubbles[bubbles.length - 1] || null;
  }
  var result = { status: "fail", text: "probe did not finish" };

  try {
    // ---- 1. the ordinary provider route: text streams, then the step's completion reason says it
    // was a decision (a tool call), so the node emits `step_phase` with phase=commentary.
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "tool", name: "read", call_id: "probe-call-1",
      arguments: { path: "ui/app.js" } });
    window.handleEvent({ type: "tool_result", name: "read", call_id: "probe-call-1",
      result: { content: "ok" } });
    window.handleEvent({ type: "delta", text: "Checking " });
    window.handleEvent({ type: "delta", text: "the second file." });

    var bubble = lastAssistant();
    check(!!bubble, "the run must draw one assistant bubble");
    var body = bubble && bubble.body;
    var streamed = body && body.querySelector(":scope > .seg:not(.final-answer)");
    check(!!streamed, "prose must stream as a segment of the bubble");
    var streamedIndex = streamed ? indexIn(body, streamed) : -1;
    var streamedBox = textBox(streamed);

    window.handleEvent({ type: "step_phase", phase: "commentary",
      text: "Checking the second file.", message_id: "probe-commentary-1" });

    var commentary = body && body.querySelector(":scope > wa-commentary");
    check(!!commentary, "a commentary phase must render a commentary topic in the bubble");
    check(!!commentary && commentary.querySelector(".commentary-body").textContent ===
      "Checking the second file.",
      "the commentary topic must carry the streamed sentence exactly once, saw: " +
      (commentary ? JSON.stringify(commentary.querySelector(".commentary-body").textContent) : "no topic"));
    check(!!commentary && indexIn(body, commentary) === streamedIndex && streamedIndex >= 0,
      "BUG B: the commentary must take the streamed sentence's own place, so it does not move; " +
      "streamed at index " + streamedIndex + ", topic at " +
      (commentary ? indexIn(body, commentary) : "none"));
    // The ordinary OpenAI-compatible route states no per-item phase: the node can only say what the
    // step was after it ended (lua/core/agent.lua:1818-1821 sets decision_phase on finish_reason,
    // and `step_phase` is emitted after the step at :1979-1980). Nothing here may guess the phase
    // earlier. What the resolution must do is make this an ORDINARY topic: the header above the body,
    // the body inside the topic's box, the shared chrome drawn - and the sentence may move down by
    // exactly that header row's height. It must not be re-created elsewhere in the bubble.
    var commentaryBox = textBox(commentary);
    check(!!streamedBox && !!commentaryBox && samePlace(streamedBox, commentaryBox),
      "the resolved commentary must hold the streamed sentence's own place - same parent, same " +
      "sibling index (ordinary route, no early phase); streamed [" + boxText(streamedBox) +
      "] -> topic [" + boxText(commentaryBox) + "]");
    check(bodyInsideTopic(commentary),
      "the operator's complaint: the commentary body must be INSIDE the commentary topic's box; text [" +
      boxText(commentaryBox) + "], topic [" + rectText(commentary && commentary.getBoundingClientRect()) + "]");
    check(headerAbove(commentary),
      "the commentary's header row must be ABOVE its body, like every other topic; text [" +
      boxText(commentaryBox) + "], marker [" + markerText(commentary) + "]");
    check(sharedTopicChrome(commentary),
      "the commentary must draw the shared topic's own box (border and background), not a chrome-less " +
      "variant: saw border " + (commentary ? getComputedStyle(commentary).borderTopWidth : "none") +
      " background " + (commentary ? getComputedStyle(commentary).backgroundColor : "none"));
    check(shiftIsHeader(streamedBox, commentary),
      "the streamed sentence may move DOWN by exactly the header row's height (plus the topic's top " +
      "border) and no further; streamed [" + boxText(streamedBox) + "] -> topic [" +
      boxText(commentaryBox) + "]");
    notes.push("ordinary route (delta -> step_phase), no early phase: text [" + boxText(streamedBox) +
      "] -> [" + boxText(commentaryBox) + "]");
    check(body && body.querySelectorAll(":scope > .seg").length === 0,
      "no orphaned streamed segment may be left behind");
    check(body && !body.querySelector(":scope > wa-run"),
      "BUG A: a commentary arriving mid-run must not create a run topic, saw " +
      (body && body.querySelectorAll(":scope > wa-run").length) + " topic(s)");
    check(body && !!body.querySelector(":scope > wa-trace") &&
      body.querySelectorAll("wa-run wa-trace").length === 0,
      "BUG A: the tool step called before the commentary must still be drawn directly in the bubble");

    // The step really is a run step: it folds with the tool calls once the run settles.
    window.handleEvent({ type: "done" });

    // ---- 2. the subscription route with the phase known from the first chunk: the topic exists
    // before the second chunk arrives, so the first token is already inside it.
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "commentary_delta", pending_id: "probe-oc", text: "OpenCode " });
    var streamed2 = lastAssistant();
    var topic2 = streamed2 && streamed2.body.querySelector(":scope > wa-commentary");
    check(!!topic2, "BUG B: the first commentary chunk must already render its commentary topic");
    check(!!topic2 && topic2.querySelector(".commentary-body").textContent.indexOf("OpenCode") === 0,
      "BUG B: the first token must already stream inside that topic, saw: " +
      (topic2 ? JSON.stringify(topic2.querySelector(".commentary-body").textContent) : "no topic"));
    window.handleEvent({ type: "commentary_delta", pending_id: "probe-oc", text: "commentary." });
    check(!!topic2 && topic2.querySelector(".commentary-body").textContent === "OpenCode commentary.",
      "the streamed commentary keeps growing in the same topic");
    // The provider resolved this item's phase, so the topic that streamed must be the topic that
    // remains: the same element in the same box, not a second one drawn in its place.
    var topicBox2 = textBox(topic2);
    window.handleEvent({ type: "commentary", pending_id: "probe-oc", message_id: "probe-oc-1",
      text: "OpenCode commentary." });
    var resolved2 = streamed2 && streamed2.body.querySelector(':scope > wa-commentary[data-message-id="probe-oc-1"]');
    check(!!resolved2 && resolved2 === topic2,
      "the streamed commentary node must BE the resolved topic, not be replaced by one");
    var resolvedBox2 = textBox(resolved2);
    check(samePlace(topicBox2, resolvedBox2) && sameTypography(topicBox2, resolvedBox2) &&
      unmoved(topicBox2, resolvedBox2),
      "the resolved commentary must keep the streaming text's own box: same parent and index, " +
      "unmoved, and " +
      "the same width, font-size, line-height and padding; " +
      boxText(topicBox2) + " -> " + boxText(resolvedBox2));
    check(bodyInsideTopic(resolved2) && headerAbove(resolved2) && sharedTopicChrome(resolved2),
      "the resolved commentary must be an ordinary topic: body inside the box, header above it, " +
      "shared chrome; text [" + boxText(resolvedBox2) + "], marker [" + markerText(resolved2) + "]");

    // ---- 3. the route where the phase is only known at the end of the step: the text streams into
    // a provisional segment, then the node says commentary. It must resolve in place, not move.
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "pending_delta", pending_id: "probe-pending", text: "Provisional " });
    window.handleEvent({ type: "pending_delta", pending_id: "probe-pending", text: "progress." });
    var bubble3 = lastAssistant();
    var provisional = bubble3 && bubble3.body.querySelector(":scope > .phase-pending");
    check(!!provisional, "unknown phase must still render as provisional text");
    var provisionalIndex = provisional ? indexIn(bubble3.body, provisional) : -1;
    // The provisional node must already be the commentary element: establishing the phase is then a
    // state flip on it, and the sentence the reader was following is not re-laid out.
    check(!!provisional && provisional.tagName === "WA-COMMENTARY",
      "the provisional commentary node must already BE the commentary element, saw " +
      (provisional ? provisional.tagName : "none"));
    var provisionalBox = textBox(provisional);
    window.handleEvent({ type: "commentary", pending_id: "probe-pending",
      message_id: "probe-commentary-2", text: "Provisional progress." });
    var resolved = bubble3 && bubble3.body.querySelector(
      ':scope > wa-commentary[data-message-id="probe-commentary-2"]');
    check(!!resolved && resolved === provisional,
      "the resolved topic must be the provisional node itself, not a replacement");
    var resolvedBox = textBox(resolved);
    check(samePlace(provisionalBox, resolvedBox) && sameTypography(provisionalBox, resolvedBox) &&
      unmoved(provisionalBox, resolvedBox),
      "resolving the phase must not move the text: same parent and index, unmoved, and the same width, " +
      "font-size, line-height and padding; " +
      boxText(provisionalBox) + " -> " + boxText(resolvedBox));
    check(bodyInsideTopic(resolved) && headerAbove(resolved) && sharedTopicChrome(resolved),
      "the provisional-turned-commentary must be an ordinary topic: body inside the box, header above " +
      "it, shared chrome; text [" + boxText(resolvedBox) + "], topic [" +
      rectText(resolved && resolved.getBoundingClientRect()) + "]");
    check(!!resolved && resolved.querySelector(".commentary-body").textContent ===
      "Provisional progress.",
      "a commentary resolved from provisional text must carry that text once");
    check(!!resolved && indexIn(bubble3.body, resolved) === provisionalIndex &&
      provisionalIndex >= 0,
      "BUG B: the resolved topic must hold the provisional text's place; provisional at index " +
      provisionalIndex + ", topic at " + (resolved ? indexIn(bubble3.body, resolved) : "none"));
    check(bubble3 && !bubble3.body.querySelector(":scope > .phase-pending"),
      "the provisional node must be gone once its phase is established");

    // ---- 4. the final answer: the whole run history nests, the answer is what stays outside.
    window.handleEvent({ type: "delta", text: "The second file is fine." });
    window.handleEvent({ type: "reply", message_id: "probe-answer", text: "The second file is fine." });
    var finalBubble = lastAssistant();
    var finalBody = finalBubble && finalBubble.body;
    var run = finalBody && finalBody.querySelector(":scope > wa-run");
    check(!!run, "the final answer must fold the run's activity into one run topic");
    check(!!run && !!run.querySelector("wa-commentary"),
      "the run topic must hold the commentary it ran through");
    var answer = finalBody && finalBody.querySelector(":scope > .seg.final-answer");
    check(!!answer && !!run && !run.contains(answer),
      "the final answer is the one visible outcome and stays outside the run topic");
    check(!!finalBody && finalBody.querySelectorAll(":scope > wa-run").length === 1,
      "one run topic per bubble, never nested");
    window.handleEvent({ type: "done" });
    check(!!run && run.open === false, "and that topic is collapsed once the run settles");

    // ---- 5. the stage the picture is read from ---------------------------------------------------
    // The window keeps repainting its own transcript, so what was drawn above is gone by the time the
    // screenshot is taken. This stage is the same renderer in a container the app does not own (as a
    // child pane is drawn), with the run topics left open so the nesting is visible in the image.
    var stage = document.createElement("div");
    stage.id = "wa-stage";
    stage.style.cssText = "position:fixed;right:0;top:0;bottom:0;width:620px;overflow:auto;z-index:900;" +
      "background:#0b0d12;border-left:1px solid #2a3040;padding:8px 12px;color:#cfd6e4;" +
      "font:12px/1.5 ui-monospace,monospace;";
    document.documentElement.append(stage);
    function caption(text) {
      var line = document.createElement("div");
      line.style.cssText = "margin:8px 0 4px;color:#8bbcff;";
      line.textContent = text;
      stage.append(line);
    }
    function paneFor(events) {
      var pane = document.createElement("div");
      stage.append(pane);
      withChildRenderer(pane, { session_id: "probe-stage", subagent_id: "stage",
        state: "running", settled: false }, function () {
        for (var i = 0; i < events.length; i++) window.handleEvent(events[i]);
      });
      return pane;
    }
    function openEveryTopic(pane) {
      var topics = pane.querySelectorAll("wa-run,wa-trace,wa-commentary");
      for (var i = 0; i < topics.length; i++) topics[i].open = true;
    }
    caption("while the run is stepping: the tool step and the commentary are both drawn in the bubble - no run topic");
    var livePane = paneFor([
      { type: "round", n: 1 },
      { type: "tool", call_id: "stage-call-1", name: "read", arguments: { path: "ui/app.js" } },
      { type: "tool_result", name: "read", call_id: "stage-call-1", result: { content: "ok" } },
      { type: "delta", text: "The first file is unchanged; checking the second." },
      { type: "step_phase", phase: "commentary",
        text: "The first file is unchanged; checking the second.", message_id: "stage-commentary-1" },
    ]);
    openEveryTopic(livePane);
    check(!!livePane.querySelector("wa-commentary") && !livePane.querySelector("wa-run"),
      "stage: the live pane must show the commentary in the bubble and no run topic");
    check(!!livePane.querySelector("wa-trace .tool-line[data-call-id='stage-call-1']"),
      "stage: the live pane must show the tool step it called");
    caption("the final answer: the same history nested in one run topic, and the answer is what stays outside it");
    var answerPane = paneFor([
      { type: "round", n: 1 },
      { type: "tool", call_id: "stage-call-2", name: "read", arguments: { path: "ui/app.js" } },
      { type: "tool_result", name: "read", call_id: "stage-call-2", result: { content: "ok" } },
      { type: "delta", text: "The first file is unchanged; checking the second." },
      { type: "step_phase", phase: "commentary",
        text: "The first file is unchanged; checking the second.", message_id: "stage-commentary-2" },
      { type: "delta", text: "Both files are fine." },
      { type: "reply", message_id: "stage-answer", text: "Both files are fine." },
    ]);
    openEveryTopic(answerPane);
    var answerRun = answerPane.querySelector("wa-run");
    check(!!answerRun && !!answerRun.querySelector("wa-commentary") &&
      !!answerRun.querySelector("wa-trace"),
      "stage: the answered pane must nest the commentary and the tool step in its run topic");
    check(!!answerPane.querySelector(".seg.final-answer") &&
      !!answerRun && !answerRun.contains(answerPane.querySelector(".seg.final-answer")),
      "stage: the answer must be outside the run topic");

    // ---- 6. main chat and subagent pane draw the SAME shape --------------------------------------
    // The bug that produced this fix was a differential: the subagent pane never took the in-place
    // branch, so it rendered correctly, while the main chat did. The same events are therefore drawn
    // through the real transcript here and compared, field by field, with the pane's commentary.
    window.handleEvent({ type: "done" });
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "tool", call_id: "cmp-call", name: "read", arguments: { path: "ui/app.js" } });
    window.handleEvent({ type: "tool_result", name: "read", call_id: "cmp-call", result: { content: "ok" } });
    window.handleEvent({ type: "delta", text: "The first file is unchanged; checking the second." });
    window.handleEvent({ type: "step_phase", phase: "commentary",
      text: "The first file is unchanged; checking the second.", message_id: "cmp-commentary" });
    var mainTopic = messages.querySelector('wa-commentary[data-message-id="cmp-commentary"]');
    var paneTopic = answerPane.querySelector("wa-run wa-commentary");
    // `line-height` is inherited from the hosting surface (the stage declares a smaller font for the
    // screenshot), and a topic nested in a run body deliberately loses its own top border/background
    // (`.run-body > .topic`), so neither is a property of the path: they are asserted above, where
    // they belong. What must match across surfaces is the topic itself: body class, the body's measure
    // against its own hosting surface, padding, header height, header above body, body inside the topic
    // box, and no in-place state. The body's font/line-height are the surface's by design - a commentary
    // body IS the answer's text box when its step answers, so it cannot carry a size of its own - which
    // is why the compared field is that relationship and not one absolute number two different surfaces
    // were never meant to share; a second implementation that hard-codes a measure still fails here.
    function topicShape(topic) {
      var bodyNode = topic && topic.querySelector(":scope > .commentary-body");
      var headNode = topic && topic.querySelector(":scope > .trace-head");
      if (!bodyNode || !headNode) return null;
      var style = getComputedStyle(bodyNode);
      var host = bodyNode.parentElement ? getComputedStyle(bodyNode.parentElement) : null;
      var measure = !!host && style.fontSize === host.fontSize && style.lineHeight === host.lineHeight;
      return [bodyNode.className, measure ? "surface-measure" : (style.fontSize + "/" + style.lineHeight),
        style.padding,
        headNode.getBoundingClientRect().height.toFixed(1),
        headerAbove(topic), bodyInsideTopic(topic),
        topic.hasAttribute("data-in-place"), topic.querySelectorAll("[data-in-place]").length].join("|");
    }
    var mainShape = topicShape(mainTopic);
    var paneShape = topicShape(paneTopic);
    check(!!mainShape && !!paneShape && mainShape === paneShape,
      "the main chat and a subagent pane must draw the same commentary shape (body class, the body's " +
      "measure against its surface, padding, header height, header-above-body, body-inside-box, no " +
      "in-place); main [" + mainShape + "] pane [" + paneShape + "]");
    check(!!mainTopic && !mainTopic.hasAttribute("data-in-place") &&
      messages.querySelectorAll("[data-in-place]").length === 0,
      "the main chat must hold no in-place commentary state after a resolution, saw " +
      messages.querySelectorAll("[data-in-place]").length);
    check(document.querySelectorAll("[data-in-place]").length === 0,
      "no element in the page may carry the removed in-place state, saw " +
      document.querySelectorAll("[data-in-place]").length);

    // ---- 7. the thinking topic ends when the NEXT TOPIC begins, and keeps its place ---------------
    // Two operator reports meet here. First (2026-10-21): "the thinking topic changes position when
    // the next tool-call step arrives" - so the node must keep its parent and its sibling index, and
    // the next thought must be drawn beside it, not at the far end. Second (2026-10-2x): the topic
    // stayed OPEN until another thinking or decision topic began, so a commentary or a tool step that
    // followed it read as if the thought were still going. The property asserted here is therefore
    // both: the topic CLOSES in place (header collapsed, body hidden, same node, same index, same
    // top, same text - never deleted, never re-created) as soon as the next topic of any kind starts,
    // and a thought AFTER that is a new node drawn in the same order.
    window.handleEvent({ type: "done" });
    window.handleEvent({ type: "round", n: 1, tools: 2 });
    window.handleEvent({ type: "reasoning", text: "First, read the topic component." });
    var thinkBubble = lastAssistant();
    var thinkBody = thinkBubble && thinkBubble.body;
    var firstThought = thinkBody && thinkBody.querySelector(":scope > wa-reasoning");
    check(!!firstThought, "the first thinking burst must draw a thinking topic in the run bubble");
    var firstThoughtIndex = firstThought ? indexIn(thinkBody, firstThought) : -1;
    var firstThoughtTop = firstThought ? firstThought.getBoundingClientRect().top : NaN;
    var firstThoughtTextBefore = firstThought
      ? firstThought.querySelector(":scope > .reasoning-body").textContent : "";
    function closedInPlace(topic, index, top, text, label) {
      check(!!topic && topic.isConnected, label + ": the topic must still be the same connected node");
      check(topic.open === false && topic.hasAttribute("open") === false && topic.body.hidden === true,
        label + ": the topic must be collapsed - header closed and body hidden");
      check(!!thinkBody && indexIn(thinkBody, topic) === index,
        label + ": the topic must keep its own index; was " + index + ", now " +
        (topic ? indexIn(thinkBody, topic) : "gone"));
      check(Math.abs(topic.getBoundingClientRect().top - top) <= 1,
        label + ": the topic must keep its own top; was " + top + ", now " +
        topic.getBoundingClientRect().top);
      check(topic.querySelector(":scope > .reasoning-body").textContent === text,
        label + ": the topic's text must not move or change; reads " +
        JSON.stringify(topic.querySelector(":scope > .reasoning-body").textContent));
    }

    // A decision starts the next topic; the thinking closes where it stands, before the trace.
    window.handleEvent({ type: "decision", call_id: "topic-call-1", name: "read",
      arguments_text: '{"path":"ui/components.js"}' });
    closedInPlace(firstThought, firstThoughtIndex, firstThoughtTop, firstThoughtTextBefore,
      "after a decision");
    window.handleEvent({ type: "tool", call_id: "topic-call-1", name: "read",
      arguments: { path: "ui/components.js" } });
    window.handleEvent({ type: "tool_result", name: "read", call_id: "topic-call-1",
      result: { content: "ok" } });
    var step = thinkBody && thinkBody.querySelector(":scope > wa-trace");
    check(!!step, "the tool call must draw its step in the run bubble");
    // The TOOL STEP is the next topic too: it must close the thinking, and the closed node must still
    // precede the step it preceded (the earlier position fix is not traded away for this one).
    closedInPlace(firstThought, firstThoughtIndex, firstThoughtTop, firstThoughtTextBefore,
      "after a tool step");
    check(precedes(firstThought, step),
      "the closed thinking topic must still be ABOVE the step it preceded (compareDocumentPosition)");

    // A thought after the step is a NEW node, drawn beside the closed one - not more text in it.
    window.handleEvent({ type: "round", n: 2, tools: 2 });
    window.handleEvent({ type: "reasoning", text: "Second, check where the header is drawn." });
    var thoughts = thinkBody ? Array.from(thinkBody.querySelectorAll(":scope > wa-reasoning")) : [];
    check(thoughts.length === 2,
      "a thought after a tool step must be a NEW topic, saw " + thoughts.length + " wa-reasoning nodes");
    var secondThought = thoughts[1] || null;
    check(!!secondThought && secondThought !== firstThought,
      "the new burst must not re-use or re-create the closed topic");
    check(!!secondThought && secondThought.open === true,
      "the new thinking topic must be open so the text it just streamed is readable");
    check(precedes(firstThought, secondThought),
      "the new topic must be drawn AFTER the closed one, in the order the steps happened");
    closedInPlace(firstThought, firstThoughtIndex, firstThoughtTop, firstThoughtTextBefore,
      "after the next thinking topic");
    var firstThoughtTextAfter = firstThought
      ? firstThought.querySelector(":scope > .reasoning-body").textContent : "";
    check(firstThoughtTextAfter.indexOf("Second, check where the header is drawn.") < 0,
      "the new burst's text must not land in the closed topic; body reads " +
      JSON.stringify(firstThoughtTextAfter));
    // The node re-sends each round's reasoning as an authoritative copy (`complete`). It replaces the
    // round it belongs to - here the NEW topic - and must not touch the closed earlier topic.
    window.handleEvent({ type: "reasoning", text: "Second, check where the header is drawn.", complete: true });
    var afterCompleteText = secondThought
      ? secondThought.querySelector(":scope > .reasoning-body").textContent : "";
    check(afterCompleteText.indexOf("Second, check where the header is drawn.") >= 0,
      "the new topic must keep its own round's authoritative copy; body reads " +
      JSON.stringify(afterCompleteText));
    check(!!firstThought && firstThought.querySelector(":scope > .reasoning-body").textContent === firstThoughtTextBefore,
      "the authoritative copy must not change the closed earlier topic");

    // The fold moves the closed topic into the run topic WITHOUT reopening it and without re-creating
    // it: a reply is not a topic, so nothing here closes or reopens anything - the fold is a move.
    window.handleEvent({ type: "reply", message_id: "topic-answer", text: "Done reading." });
    var thinkRun = thinkBody && thinkBody.querySelector(":scope > wa-run");
    check(!!thinkRun && !!firstThought && thinkRun.contains(firstThought),
      "the final answer must fold the thinking topic into the run topic, keeping it as the same node");
    check(!!firstThought && firstThought.open === false,
      "the fold must not reopen a topic the next step closed");
    // A reply is not a topic, so the thinking stays open through it. WHY THIS CHANGED (operator,
    // 2026-10-2x): one thinking topic per PROVIDER STEP, not one per run - the operator reversed the
    // earlier "one train of thought is one topic" rule after reporting a whole run's thinking stacked
    // above its tool steps ("thinking 2575 chars" above five "1 tool call" topics: "in order of the
    // received from the provider step"). This assertion used to state the opposite - "no topic followed
    // the reply, so the burst continues the open topic" - which is exactly the accumulation now
    // forbidden. A `round` is a topic boundary like a tool step or a commentary, so the burst after it
    // is a NEW topic, drawn after everything the earlier steps drew, and the folded earlier topic is
    // still untouched.
    window.handleEvent({ type: "round", n: 3, tools: 2 });
    window.handleEvent({ type: "reasoning", text: "Third, still thinking." });
    var afterFoldThoughts = thinkBody ? Array.from(thinkBody.querySelectorAll("wa-reasoning")) : [];
    check(afterFoldThoughts.length === 3,
      "the round after the fold must start its OWN thinking topic (one topic per provider step); saw " +
      afterFoldThoughts.length + " wa-reasoning node(s)");
    var thirdThought = afterFoldThoughts[2] || null;
    check(!!thirdThought && thirdThought !== secondThought && thirdThought.open === true,
      "the burst after the round boundary must be a new, open topic, not more text in the earlier one");
    var thirdText = thirdThought
      ? thirdThought.querySelector(":scope > .reasoning-body").textContent : "";
    check(thirdText.indexOf("Third, still thinking.") >= 0,
      "the new round's text must land in its own topic; body reads " + JSON.stringify(thirdText));
    var secondTextAfterRound = secondThought
      ? secondThought.querySelector(":scope > .reasoning-body").textContent : "";
    check(secondTextAfterRound.indexOf("Third, still thinking.") < 0,
      "no round's text may land in another round's topic; the earlier topic reads " +
      JSON.stringify(secondTextAfterRound));
    check(!!secondThought && secondThought.open === false && secondThought.body.hidden === true,
      "the round boundary must close the previous thinking topic where it stands");
    // The fold is the ONE move allowed: the closed topic is nested into the run topic with the rest of
    // the route. It must still be the same node, closed, with the same text - the index/geometry
    // property was already asserted above, where a step (not the answer) arrived.
    check(!!firstThought && firstThought.isConnected && firstThought.open === false &&
      firstThought.querySelector(":scope > .reasoning-body").textContent === firstThoughtTextBefore,
      "after the fold the closed topic must still be the same node, still closed, with the same text");

    // A COMMENTARY is the next topic too, and it must close the thinking exactly as a step does:
    // the operator's "it never closes when a commentary ... follows" case.
    window.handleEvent({ type: "done" });
    window.handleEvent({ type: "round", n: 1, tools: 2 });
    window.handleEvent({ type: "reasoning", text: "A thought before the progress update." });
    var commentBubble = lastAssistant();
    var commentBody = commentBubble && commentBubble.body;
    var commentThought = commentBody && commentBody.querySelector(":scope > wa-reasoning");
    var commentIndex = commentThought ? indexIn(commentBody, commentThought) : -1;
    var commentTop = commentThought ? commentThought.getBoundingClientRect().top : NaN;
    window.handleEvent({ type: "commentary_delta", pending_id: "close-commentary", text: "Working on it." });
    var commentTopic = commentBody && commentBody.querySelector(":scope > wa-commentary");
    check(!!commentTopic, "the commentary must draw its own topic");
    check(!!commentThought && commentThought.isConnected &&
      commentBody.querySelector(":scope > wa-reasoning") === commentThought &&
      indexIn(commentBody, commentThought) === commentIndex &&
      commentThought.open === false && commentThought.body.hidden === true &&
      Math.abs(commentThought.getBoundingClientRect().top - commentTop) <= 1,
      "a commentary must CLOSE the thinking topic in place: same node, same index, same top, body hidden");
    check(precedes(commentThought, commentTopic),
      "the closed thinking topic must stay above the commentary that closed it");
    window.handleEvent({ type: "commentary_delta", pending_id: "close-commentary", text: " Still working." });
    check(!!commentThought && commentBody.querySelector(":scope > wa-reasoning") === commentThought,
      "more commentary must not touch the closed thinking topic");
    window.handleEvent({ type: "reasoning", text: "A new thought after the commentary." });
    var afterCommentary = commentBody ? commentBody.querySelectorAll(":scope > wa-reasoning") : [];
    check(afterCommentary.length === 2 && afterCommentary[1] !== commentThought &&
      afterCommentary[1].open === true,
      "a thought after a commentary must be a new, open topic beside the closed one; saw " +
      afterCommentary.length);
    window.handleEvent({ type: "done" });

    // ---- 8. ONE PROVIDER STEP'S THINKING IS ONE TOPIC, IN THE ORDER THE STEPS ARRIVED -------------
    // Operator report (2026-10-2x), verbatim: "thinking is not correctly in the step by step order, it
    // is stacking in the top of the tool calls topic. The correct behavior should be in order of the
    // received from the provider step, not rearranging the order." Screenshot: ONE `thinking 2575 chars`
    // topic above five `1 tool call` topics - a whole run's thinking in one block at the top.
    //
    // The run is driven the way the node emits it (lua/core/agent.lua): a `round`, that step's
    // reasoning (streamed, then the step's authoritative `complete` copy), then the step's tool call and
    // its result, then the next `round`. What must be true: every step's thinking is its OWN topic, and
    // the topics read top to bottom in exactly the order the provider sent them - thinking, tool,
    // thinking, tool - never stacked at the top and never merged into one topic.
    window.handleEvent({ type: "done" });
    window.handleEvent({ type: "round", n: 1, tools: 2 });
    window.handleEvent({ type: "reasoning", text: "Round one: read ui/app.js." });
    window.handleEvent({ type: "reasoning", text: "round one: the header is drawn above its body.", complete: true });
    var ordBubble = lastAssistant();
    var ordBody = ordBubble && ordBubble.body;
    function ordText(topic) {
      var node = topic && topic.querySelector(":scope > .reasoning-body");
      return node ? node.textContent : "";
    }
    var roundOne = ordBody && ordBody.querySelector(":scope > wa-reasoning");
    check(!!roundOne, "step order: the first round's thinking must draw a thinking topic");
    check(/round one/i.test(ordText(roundOne)) && !/round two/i.test(ordText(roundOne)),
      "step order: the first thinking topic must carry only round one's text; reads " + JSON.stringify(ordText(roundOne)));
    var roundOneIndex = roundOne ? indexIn(ordBody, roundOne) : -1;
    window.handleEvent({ type: "decision", call_id: "ord-call-1", name: "read",
      arguments_text: '{"path":"ui/app.js"}' });
    window.handleEvent({ type: "tool", call_id: "ord-call-1", name: "read",
      arguments: { path: "ui/app.js" } });
    window.handleEvent({ type: "tool_result", name: "read", call_id: "ord-call-1",
      result: { content: "ok" } });
    var ordStep1 = ordBody && ordBody.querySelector(":scope > wa-trace");
    check(!!ordStep1, "step order: round one's tool step must draw its own step topic");

    window.handleEvent({ type: "round", n: 2, tools: 2 });
    window.handleEvent({ type: "reasoning", text: "round two: now check the second file." });
    var ordThoughts = ordBody ? Array.from(ordBody.querySelectorAll(":scope > wa-reasoning")) : [];
    check(ordThoughts.length === 2,
      "step order: one topic per provider step - round two's thinking must be a SECOND topic, saw " +
      ordThoughts.length + " wa-reasoning node(s)");
    var roundTwo = ordThoughts[1] || null;
    check(!!roundTwo && roundTwo !== roundOne, "step order: the second round must not re-use the first topic");
    check(!!roundOne && !!ordStep1 && precedes(roundOne, ordStep1),
      "step order: round one's thinking must stay ABOVE the tool step it preceded (compareDocumentPosition)");
    check(!!ordStep1 && !!roundTwo && precedes(ordStep1, roundTwo),
      "step order: round two's thinking must be drawn AFTER the tool step that preceded it, not stacked " +
      "above it (compareDocumentPosition) - the operator's \"stacking in the top of the tool calls topic\"");
    check(/round two/i.test(ordText(roundTwo)) && !/round one/i.test(ordText(roundTwo)),
      "step order: the second thinking topic must carry only round two's text; reads " + JSON.stringify(ordText(roundTwo)));
    check(!!roundOne && /round one/i.test(ordText(roundOne)) && !/round two/i.test(ordText(roundOne)),
      "step order: no round's text may land in another round's topic - round one reads " + JSON.stringify(ordText(roundOne)));
    check(!!roundOne && indexIn(ordBody, roundOne) === roundOneIndex,
      "step order: the first thinking topic must keep its own position after the second round arrives " +
      "(was " + roundOneIndex + ", now " + (roundOne ? indexIn(ordBody, roundOne) : "gone") + ")");

    window.handleEvent({ type: "decision", call_id: "ord-call-2", name: "read",
      arguments_text: '{"path":"ui/app.js","offset":10}' });
    window.handleEvent({ type: "tool", call_id: "ord-call-2", name: "read",
      arguments: { path: "ui/app.js", offset: 10 } });
    window.handleEvent({ type: "tool_result", name: "read", call_id: "ord-call-2",
      result: { content: "ok" } });
    var ordSteps = ordBody ? Array.from(ordBody.querySelectorAll(":scope > wa-trace")) : [];
    check(ordSteps.length === 2, "step order: round two's tool step must be its own step topic, saw " +
      ordSteps.length + " wa-trace node(s)");
    check(!!roundTwo && ordSteps[1] && precedes(roundTwo, ordSteps[1]),
      "step order: round two's thinking must stay above round two's tool step");
    // The order the reader sees, top to bottom: thinking, tool, thinking, tool.
    function topicOrder(body) {
      if (!body) return [];
      return Array.from(body.querySelectorAll("wa-reasoning, wa-trace"))
        .map((node) => node.tagName === "WA-REASONING" ? "thinking" : "tool");
    }
    check(topicOrder(ordBody).join(",") === "thinking,tool,thinking,tool",
      "step order: the run's steps must read in the exact order the provider sent them - " +
      "thinking, tool, thinking, tool - saw [" + topicOrder(ordBody).join(",") + "]");

    // The final answer folds the route into the run topic: the same order must survive the fold, with
    // each round's text still in its own topic.
    window.handleEvent({ type: "reply", message_id: "ord-answer", text: "Both files are fine." });
    var ordRun = ordBody && ordBody.querySelector(":scope > wa-run");
    check(!!ordRun, "step order: the final answer must fold the route into a run topic");
    check(topicOrder(ordBody).join(",") === "thinking,tool,thinking,tool",
      "step order: after the fold the run topic's children must still read thinking, tool, thinking, " +
      "tool - saw [" + topicOrder(ordBody).join(",") + "]");
    check(!!ordRun && ordRun.querySelectorAll("wa-reasoning").length === 2,
      "step order: the folded run topic must still hold exactly two thinking topics, saw " +
      (ordRun ? ordRun.querySelectorAll("wa-reasoning").length : "none"));
    check(/round one/i.test(ordText(roundOne)) && !/round two/i.test(ordText(roundOne)) &&
      /round two/i.test(ordText(roundTwo)) && !/round one/i.test(ordText(roundTwo)),
      "step order: the fold must not merge the rounds; one reads " + JSON.stringify(ordText(roundOne)) +
      ", two reads " + JSON.stringify(ordText(roundTwo)));
    window.handleEvent({ type: "done" });

    var verdict = "PASS: run steps stay in the bubble until the final answer nests them; a thinking " +
      "topic CLOSES IN PLACE (same node, same index, same top, same text, body hidden - never " +
      "deleted, never re-created) when the next topic of any kind begins - a decision, a tool step, " +
      "or a commentary - and a thought after that is a new node drawn in the run's own order; " +
      "every provider step's thinking is its OWN topic, drawn in the position that step arrived in, " +
      "so a run of two rounds with a tool step between reads thinking, tool, thinking, tool - never " +
      "stacked above the steps it followed and never merged into another round's topic; and on " +
      "every route a commentary is an ordinary topic - header above the body, body inside the topic " +
      "box, the streamed sentence kept in its own place (moving only by the measured header height) " +
      "- with no in-place state, in the main chat and in a subagent pane alike";
    if (notes.length) verdict += " [" + notes.join(" ;; ") + "]";
    result = { status: problems.length ? "fail" : "pass",
      text: problems.length ? "FAIL: " + problems.join(" ;; ") : verdict };
  } catch (error) {
    result = { status: "fail", text: "probe threw: " + (error && (error.stack || error.message || error)) };
  }

  var pre = document.createElement("pre");
  pre.id = "wa-probe";
  pre.setAttribute("data-status", result.status);
  pre.textContent = result.text;
  document.body.append(pre);
})();
