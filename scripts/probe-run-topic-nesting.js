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

    // ---- 7. one train of thought is ONE thinking topic, and it keeps its place -------------------
    // Operator's report: "the thinking topic in the turn bubble changes position when the next
    // tool-call step arrives." WHY this assertion exists at all: nothing measured the *position* of
    // the thinking topic against the step that followed it, so a fix could pass every other probe
    // while re-creating the topic per round. The property is the document order of one run's
    // children: it must be the order the steps happened in, at every instant, and a later thinking
    // burst must land inside the topic the earlier one opened - the same element, in the same place
    // - because one train of thought in a run is ONE `wa-reasoning` topic.
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

    // The step happens after the thought: a decision, then the call it chose and the call's result.
    window.handleEvent({ type: "decision", call_id: "topic-call-1", name: "read",
      arguments_text: '{"path":"ui/components.js"}' });
    window.handleEvent({ type: "tool", call_id: "topic-call-1", name: "read",
      arguments: { path: "ui/components.js" } });
    window.handleEvent({ type: "tool_result", name: "read", call_id: "topic-call-1",
      result: { content: "ok" } });
    var step = thinkBody && thinkBody.querySelector(":scope > wa-trace");
    check(!!step, "the tool call must draw its step in the run bubble");
    check(precedes(firstThought, step),
      "the thinking topic must still be ABOVE the step it preceded once the step arrives " +
      "(compareDocumentPosition); order was first-topic then step");
    check(firstThoughtIndex >= 0 && indexIn(thinkBody, firstThought) === firstThoughtIndex,
      "the thinking topic must keep its own index in the bubble when the step arrives; was " +
      firstThoughtIndex + ", now " + (firstThought ? indexIn(thinkBody, firstThought) : "gone"));

    // The next round thinks again. It is the same train of thought, so it continues in the same
    // topic - the text lands INSIDE the node that already sits above the step.
    window.handleEvent({ type: "round", n: 2, tools: 2 });
    window.handleEvent({ type: "reasoning", text: "Second, check where the header is drawn." });
    var thoughts = thinkBody ? thinkBody.querySelectorAll(":scope > wa-reasoning") : [];
    check(thoughts.length === 1,
      "one train of thought in a run is ONE wa-reasoning topic, saw " + thoughts.length +
      " after the second burst (a second topic is the reader's thinking moving below the step)");
    check(thoughts.length === 1 && thoughts[0] === firstThought,
      "the second burst must land in the FIRST topic - the same element - not in a re-created one");
    check(firstThoughtIndex >= 0 && indexIn(thinkBody, firstThought) === firstThoughtIndex,
      "the thinking topic must not move when the next step arrives; was index " + firstThoughtIndex +
      ", now " + (firstThought ? indexIn(thinkBody, firstThought) : "gone"));
    check(!!firstThought && Math.abs(firstThought.getBoundingClientRect().top - firstThoughtTop) <= 1,
      "the topic's own top must not move when the next step arrives; was " + firstThoughtTop +
      ", now " + (firstThought ? firstThought.getBoundingClientRect().top : "gone"));
    check(precedes(firstThought, step),
      "after the second burst the topic must still precede the step it sits above");
    var thoughtText = firstThought
      ? firstThought.querySelector(":scope > .reasoning-body").textContent : "";
    check(firstThoughtTextBefore !== "" && thoughtText.indexOf(firstThoughtTextBefore) >= 0,
      "the first burst must still be readable in that one topic; had " +
      JSON.stringify(firstThoughtTextBefore) + ", now " + JSON.stringify(thoughtText));
    check(thoughtText.indexOf("Second, check where the header is drawn.") >= 0,
      "the second burst's text must land INSIDE the first wa-reasoning; body reads " +
      JSON.stringify(thoughtText));
    // The node re-sends each round's reasoning as an authoritative copy (`complete`, see
    // lua/core/agent.lua). That copy replaces the round it belongs to and must NOT erase the earlier
    // round of the same topic - the text-loss failure mode of folding one run's thinking into one node.
    window.handleEvent({ type: "reasoning", text: "Second, check where the header is drawn.", complete: true });
    var afterCompleteText = firstThought
      ? firstThought.querySelector(":scope > .reasoning-body").textContent : "";
    check(afterCompleteText.indexOf("First, read the topic component.") >= 0 &&
      afterCompleteText.indexOf("Second, check where the header is drawn.") >= 0,
      "a round's authoritative copy must replace that round only, not the earlier round of the same " +
      "topic; body reads " + JSON.stringify(afterCompleteText));
    // A burst that has not been read yet must not arrive folded away: the decision may close the
    // topic (it is the next thinking-shaped step), but continuing the thought reopens it - text that
    // lands in a collapsed topic is text the reader cannot see.
    check(!!firstThought && firstThought.open,
      "the topic a new burst lands in must be open, so the text just arrived is readable");

    // The fold: the final answer moves the topic into the run topic. A later round of the same run
    // still has one train of thought, so it appends into the same node WHERE IT NOW SITS.
    window.handleEvent({ type: "reply", message_id: "topic-answer", text: "Done reading." });
    var thinkRun = thinkBody && thinkBody.querySelector(":scope > wa-run");
    check(!!thinkRun && !!firstThought && thinkRun.contains(firstThought),
      "the final answer must fold the thinking topic into the run topic, keeping it as the same node");
    window.handleEvent({ type: "round", n: 3, tools: 2 });
    window.handleEvent({ type: "reasoning", text: "Third, still thinking." });
    check(!!thinkBody && thinkBody.querySelectorAll("wa-reasoning").length === 1,
      "a burst after the fold must continue the same topic, not draw a second one in the bubble; saw " +
      (thinkBody ? thinkBody.querySelectorAll("wa-reasoning").length : "none"));
    check(!!thinkRun && !!firstThought && thinkRun.contains(firstThought),
      "a burst after the fold must append into the topic where it now sits (inside the run topic), " +
      "so the run's own order is unchanged");
    window.handleEvent({ type: "done" });

    var verdict = "PASS: run steps stay in the bubble until the final answer nests them; one train of " +
      "thought in a run is ONE thinking topic that keeps its place (same node, same index, still above " +
      "the step it preceded after the next burst and after the fold - compareDocumentPosition); and on " +
      "every route a commentary is an ordinary topic - header above the body, body inside the topic box, " +
      "the streamed sentence kept in its own place (moving only by the measured header height) - with " +
      "no in-place state, in the main chat and in a subagent pane alike";
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
