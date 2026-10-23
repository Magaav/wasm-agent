// Focused probe: where a run's prose streams, and how it becomes the final answer.
//
//   node scripts/agent-benchmark-ui-observe.mjs --ui <ui> --probe scripts/probe-final-answer-placement.js
//
// The operator-approved placement rule (DESIGN.md section 6, docs/HOOK-EVENTS.md onFinalAnswer):
//
//   * `reasoning_content` is untouched: it streams inside the thinking topic from its first chunk.
//   * a run whose request carried NO tools is answering: its prose IS the answer, in the bubble.
//   * a run whose request DID carry tools has no provider label for its prose, so the first content
//     chunk streams INSIDE a commentary topic. A tool call settles that label with nothing moving;
//     a `finish_reason=stop` step converts that same prose block into the answer - exactly once -
//     folds the earlier steps and commentary into the run topic, and leaves the answer outside it.
//   * the conversion takes the answer's text box from the topic's ASIDE measure to the transcript's own
//     (12px -> `var(--font-size)`) once, as it moves that same element into the bubble; the box's
//     structure and text are unchanged, compared through `waProbeSameAs` against a fingerprint captured
//     before it. What must never happen is a change AFTER that first paint - section 3c measures that
//     window frame by frame.
//   * scroll: a tall answer anchors its first line, a short answer does not move the reader, and a
//     reader who scrolled up during the run is not pulled back.
//   * the WINDOW after the conversion (section 3c): what a reader sees is not the instant the answer
//     is moved, it is the frames and the settle/repaint passes that follow. The answer's own computed
//     font-size/line-height/padding and its box are sampled in the conversion's frame, one animation
//     frame later, 300ms later, after the settle passes, and after a repaint of the same ledger rows -
//     all of them must be the same numbers, and no pass may touch the live answer's class or style.
//     This is the gap that let a second, smaller typography ship: the conversion was measured, never
//     the window.
//   * `onFinalAnswer` fires once with the documented ids/lengths payload and refuses a replay of the
//     same run/message.
//
// Synchronous sections run against the DOM `handleEvent` built; only section 3c awaits a real frame
// and a real 300ms, because a window is not an instant.
(async function () {
  var problems = [];
  function check(ok, label) { if (!ok) problems.push(label); }
  function lastBubble() {
    var bubbles = document.querySelectorAll('#messages wa-message[role="assistant"]');
    return bubbles[bubbles.length - 1] || null;
  }
  function countText(root, text) {
    return String(root ? root.textContent : "").split(text).length - 1;
  }
  function metrics(node) {
    var rect = node.getBoundingClientRect();
    var style = getComputedStyle(node);
    return { width: +rect.width.toFixed(2), height: +rect.height.toFixed(2),
      left: +rect.left.toFixed(2), top: +rect.top.toFixed(2),
      fontSize: style.fontSize, lineHeight: style.lineHeight, padding: style.padding };
  }
  function sameMetrics(before, after) {
    return before.fontSize === after.fontSize && before.lineHeight === after.lineHeight &&
      before.padding === after.padding && Math.abs(before.width - after.width) <= 0.5 &&
      Math.abs(before.height - after.height) <= 0.5 && Math.abs(before.left - after.left) <= 0.5;
  }
  function metricText(m) {
    return "box " + m.width + "x" + m.height + " @ " + m.left + "," + m.top +
      " font " + m.fontSize + " line " + m.lineHeight + " pad " + m.padding;
  }
  function fresh() {
    handleEvent({ type: "done" });
    clearStatus();
    messages.replaceChildren();
    runBubble = null; streamBody = null; streamText = "";
    streamedCommentaryBlock = null; streamedCommentaryText = "";
    phasePendingText = new Map();
    setFollow(true);
    document.body.classList.add("expanded");
  }
  // The answer's own text box: the converted answer is a `.commentary-body` moved into its shell, a
  // plain answer is its own text, so the box the reader sees is this element either way.
  function answerTextBox(answer) {
    if (!answer) return null;
    return answer.querySelector(":scope > .commentary-body") || answer;
  }
  function windowMetrics(answer) {
    var node = answerTextBox(answer);
    if (!node) return null;
    var rect = node.getBoundingClientRect();
    var style = getComputedStyle(node);
    return { width: rect.width, height: rect.height, left: rect.left, top: rect.top,
      fontSize: style.fontSize, lineHeight: style.lineHeight, padding: style.padding };
  }
  function windowDeltas(first, other) {
    var deltas = {};
    for (var key of ["width", "height", "left", "top"]) {
      deltas[key] = other ? Math.abs(other[key] - first[key]) : NaN;
    }
    return deltas;
  }
  function windowSame(first, other, when) {
    if (!first || !other) { problems.push("the answer must be measurable " + when + ", saw none"); return false; }
    var deltas = windowDeltas(first, other);
    var ok = other.fontSize === first.fontSize && other.lineHeight === first.lineHeight &&
      other.padding === first.padding &&
      deltas.width < 0.01 && deltas.height < 0.01 && deltas.left < 0.01 && deltas.top < 0.01;
    check(ok, "the answer must not be re-painted " + when + ": the conversion painted [" +
      metricText(first) + "] and that paint is [" + metricText(other) + "], box delta " +
      "w=" + deltas.width.toFixed(2) + " h=" + deltas.height.toFixed(2) +
      " l=" + deltas.left.toFixed(2) + " t=" + deltas.top.toFixed(2));
    return ok;
  }
  function frame() { return new Promise(function (resolve) { requestAnimationFrame(function () { resolve(); }); }); }
  function wait(ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); }
  var result = { status: "fail", text: "probe did not finish" };

  try {
    fresh();

    // ---- 1. reasoning is untouched: its first chunk is inside the thinking topic --------------
    handleEvent({ type: "round", n: 1, tools: 3, run_id: "placement-run-a", session_id: "placement-session" });
    handleEvent({ type: "reasoning", text: "THINKING-FIRST-CHUNK " });
    var bubble = lastBubble();
    var thinking = bubble && bubble.body.querySelector(":scope > wa-reasoning");
    var thinkingBody = thinking && thinking.querySelector(".reasoning-body");
    check(!!thinkingBody && thinkingBody.textContent.indexOf("THINKING-FIRST-CHUNK") === 0,
      "control: the first reasoning chunk streams inside the thinking topic, saw: " +
      (thinkingBody ? JSON.stringify(thinkingBody.textContent) : "no thinking topic"));
    check(!!thinkingBody && bubble.body.contains(thinking));

    // ---- 2. a tool-capable run: its first content chunk is INSIDE the commentary topic ---------
    handleEvent({ type: "delta", text: "Let me read " });
    var provisional = bubble.body.querySelector(":scope > wa-commentary.phase-pending");
    var provisionalBody = provisional && provisional.querySelector(".commentary-body");
    check(!!provisionalBody, "the first content chunk of a tool-capable run must already render a commentary topic");
    check(!!provisionalBody && provisionalBody.textContent.indexOf("Let me read") === 0,
      "and that first chunk must stream INSIDE it, saw: " +
      (provisionalBody ? JSON.stringify(provisionalBody.textContent) : "no commentary body"));
    check(!!provisional && bubble.body.contains(provisional),
      "the commentary topic must be a direct child of the conversation bubble");
    handleEvent({ type: "delta", text: "the file." });
    var sameTopic = bubble.body.querySelector(":scope > wa-commentary.phase-pending");
    check(sameTopic === provisional, "the commentary keeps growing in the same topic");

    // A tool call for that message: it was commentary, so the label settles and nothing moves.
    var commentaryTextBefore = provisionalBody.textContent;
    handleEvent({ type: "tool", call_id: "placement-call-1", name: "read", arguments: { path: "ui/app.js" } });
    handleEvent({ type: "tool_result", name: "read", call_id: "placement-call-1", result: { content: "ok" } });
    check(provisional === bubble.body.querySelector("wa-commentary"),
      "a tool call settles the provisional node itself as commentary - it is not replaced or moved");
    // Seven lines, the same cap as thinking, and it scrolls rather than hiding the rest (operator ask).
    var cappedBody = provisional.querySelector(".commentary-body");
    var capStyle = cappedBody && getComputedStyle(cappedBody);
    var cap = capStyle ? parseFloat(capStyle.maxHeight) : 0;
    check(Math.abs(cap - 7 * 1.55 * 12) < 1,
      "a settled commentary body must cap at seven lines of its own measure, saw max-height " +
        (capStyle && capStyle.maxHeight));
    check(!!capStyle && capStyle.overflow === "auto",
      "and a longer body must scroll rather than be cut, saw overflow " + (capStyle && capStyle.overflow));
    // COMMENTARY IS FOR READING BACK; THINKING IS THE ROUTE (operator, 2026-10-21): the commentary carries
    // the transcript's own text colour so a run's milestone prose stands out, while thinking stays muted.
    check(!!capStyle && capStyle.color === "rgb(231, 235, 243)",
      "a settled commentary body must take the transcript's own text colour, saw " + (capStyle && capStyle.color));
    check(provisional.querySelector(".commentary-body").textContent === commentaryTextBefore,
      "and the settled commentary carries the same text once");
    check(!provisional.classList.contains("phase-pending"), "the label is settled (pending state removed)");
    check(!bubble.body.querySelector(":scope > wa-run"),
      "while the run is stepping no run topic exists, even after commentary is settled");

    // ---- 3. the answer step: one conversion, the answer outside the run topic, the box unmoved --
    handleEvent({ type: "round", n: 2, tools: 3, run_id: "placement-run-a", session_id: "placement-session" });
    handleEvent({ type: "delta", text: "The answer " });
    var answerTopic = bubble.body.querySelector(":scope > wa-commentary.phase-pending");
    var answerBody = answerTopic && answerTopic.querySelector(".commentary-body");
    check(!!answerBody, "the answer's first chunk also streams inside its commentary topic");
    // CHANGE 2 (operator rule): that topic PRINTS COLLAPSED now - only thinking topics print expanded;
    // commentary and tool/decision steps are collapsed - so the probe opens it the way a reader
    // following the prose does, before the
    // conversion. The claims below are about the block the conversion moves (same element, same
    // structure, same text), and a folded body has no box to compare: opening it here asserts the
    // shape the reader sees and keeps every structural claim in this section intact.
    if (answerTopic && !answerTopic.open) answerTopic.toggle();
    check(!!answerTopic && answerTopic.open === true,
      "the probe opened the answer's prose the way a reader does, saw open=" + (answerTopic && answerTopic.open));
    handleEvent({ type: "delta", text: "is 42." });
    var beforeMetrics = metrics(answerBody);
    var beforeClone = answerBody.cloneNode(true);

    // The documented event, emitted at the same boundary the conversion happens.
    var hookCalls = [];
    var offHook = onFinalAnswerHook(function (payload) { hookCalls.push(payload); });
    var payload = { type: "final_answer", session_id: "placement-session", run_id: "placement-run-a",
      message_id: "placement-msg-a", answer_id: "placement-run-a:answer", text_len: 15, at: 1792500000000 };
    var first = emitFinalAnswer(payload);
    handleEvent({ type: "reply", message_id: "placement-msg-a", text: "The answer is 42." });
    var second = emitFinalAnswer(payload);
    offHook();

    check(first === true, "onFinalAnswer must fire for a new run/message");
    check(second === false, "and a second emission of the same run/message must be refused");
    check(hookCalls.length === 1, "the hook must be called exactly once, saw " + hookCalls.length);
    check(!!hookCalls[0] && hookCalls[0].session_id === "placement-session" &&
      hookCalls[0].run_id === "placement-run-a" && hookCalls[0].message_id === "placement-msg-a" &&
      hookCalls[0].answer_id === "placement-run-a:answer" && hookCalls[0].text_len === 15 &&
      hookCalls[0].at === 1792500000000,
      "the payload must carry exactly the documented ids and lengths, saw " +
      JSON.stringify(hookCalls[0]));
    check(!!hookCalls[0] && !("text" in hookCalls[0]) && Object.keys(hookCalls[0]).length === 6,
      "the payload must not carry the answer text or extra fields");

    var finalBody = bubble.body;
    var runs = finalBody.querySelectorAll(":scope > wa-run");
    check(runs.length === 1, "the conversion must create exactly one run topic, saw " + runs.length);
    var run = runs[0];
    var answer = finalBody.querySelector(":scope > .seg.final-answer.answer-wrap");
    check(!!answer, "the answer must render directly in the bubble as the converted segment");
    check(!!answer && answer.parentNode === finalBody && !run.contains(answer),
      "the answer must be a child of the bubble and NOT inside the run topic");
    check(finalBody.querySelectorAll(":scope > .seg.final-answer").length === 1,
      "exactly one answer element may exist");
    check(countText(finalBody, "The answer is 42.") === 1,
      "the answer text must appear exactly once, saw " +
      countText(finalBody, "The answer is 42."));
    check(!finalBody.querySelector("wa-commentary.phase-pending"),
      "the converted provisional topic must not survive as a pending block");
    check(!!run.querySelector("wa-trace"),
      "the run topic must hold the earlier tool step");
    check(!!run.querySelector("wa-commentary") &&
      run.querySelector("wa-commentary").textContent.indexOf("Let me read the file.") >= 0,
      "and the earlier settled commentary");

    // The move itself is allowed to change the measure ONCE: the topic's aside measure to the
    // transcript's own, applied as the block is placed. What must never happen is a change AFTER that
    // first paint - section 3c measures that whole window against a control answer, with zero style
    // touches. So this section asserts the destination measure and the structure, not metric equality
    // (which was the previous, wrong direction: it kept the answer at the topic's size).
    var answerBodyAfter = answer.querySelector(":scope > .commentary-body");
    var afterMetrics = metrics(answerBodyAfter);
    var same = waProbeSameAs(beforeClone, answerBodyAfter, { text: true });
    check(same.equal, "the answer text box must keep its structure across the conversion: " + waProbeDiff(same));
    check(beforeMetrics.fontSize === "12px" && afterMetrics.fontSize === "14.5px",
      "the conversion must take a commentary body's aside measure (12px) to the transcript's (14.5px): before [" +
      metricText(beforeMetrics) + "] after [" + metricText(afterMetrics) + "]");
    var reported = JSON.parse(answer.dataset.conversionMetrics || "{}");
    check(!!reported.before, "the conversion must record the box it moved from, saw " + JSON.stringify(reported));
    check(answer.dataset.answerAnchor === "none" || answer.dataset.answerAnchor === "top",
      "the conversion must record the scroll rule it applied, saw " + answer.dataset.answerAnchor);

    // ---- 3b. the subscription route whose per-item phase never arrived: the same prose streams as
    // a provisional commentary (`pending_delta`) and the same stop converts it, without a duplicate.
    handleEvent({ type: "done" });
    messages.replaceChildren(); runBubble = null; streamBody = null; streamText = "";
    streamedCommentaryBlock = null; streamedCommentaryText = ""; phasePendingText = new Map();
    handleEvent({ type: "round", n: 1, tools: 3, run_id: "placement-run-p", session_id: "placement-session" });
    handleEvent({ type: "pending_delta", pending_id: "pending-answer", text: "The pending answer." });
    var pendingTopic = lastBubble().body.querySelector(":scope > wa-commentary.phase-pending");
    check(!!pendingTopic, "an unphased subscription chunk is the provisional commentary topic");
    handleEvent({ type: "reply", message_id: "placement-msg-p", text: "The pending answer." });
    var pendingBubble = lastBubble();
    check(!!pendingBubble.body.querySelector(":scope > .seg.final-answer.answer-wrap"),
      "a stop converts that pending node into the answer");
    check(countText(pendingBubble, "The pending answer.") === 1,
      "and the answer text appears once, saw " + countText(pendingBubble, "The pending answer."));

    // ---- 3c. the WINDOW: the first paint must already be the final one ----------------------------
    // The operator's report was a window, not an instant: the answer appeared with the wrong font-size and
    // a moment later was re-rendered at the right one. So this stage drives the ordinary route end to end,
    // then samples the answer's OWN box and typography five times - in the conversion's frame, one animation
    // frame later, 300ms later, after the settle passes (`done`, the trailing `final_answer`, a repeated
    // `reply`), and after a repaint of the same durable rows (the pass `reconcile`/`watchTurn` triggers, and
    // the one that used to be the "rerenders correctly"). Every sample must be the same number, and no pass
    // may touch the live answer node's class or style at all.
    fresh();
    var windowAnswerSelector = ".seg.final-answer";
    var windowText = "The answer is prose at the transcript's own measure.\n\nA second paragraph, so the " +
      "block wraps and its box is worth measuring.";
    var windowAttachments = 0;
    var windowStyleTouches = [];
    var liveAnswer = null;
    var replayedAnswer = null;
    // Only what a pass does AFTER the first paint is counted: the conversion's own records are drained
    // once, and from then on any class/style write to the answer (or its text box) is a second paint.
    function account(records) {
      for (var record of records) {
        if (record.type !== "attributes") continue;
        if (liveAnswer && (record.target === liveAnswer || liveAnswer.contains(record.target)))
          windowStyleTouches.push(record.attributeName + " on " +
            (record.target.className || record.target.tagName));
      }
    }
    // An attachment is counted by IDENTITY - the answer element itself arriving in the transcript - so a
    // parent that merely carries it later cannot be mistaken for a second paint.
    function attachmentsIn(records) {
      var count = 0;
      for (var record of records) {
        if (record.type === "attributes") continue;
        for (var added of record.addedNodes) if (added === liveAnswer || added === replayedAnswer) count += 1;
      }
      return count;
    }
    var watcher = new MutationObserver(account);
    watcher.observe(messages, { childList: true, subtree: true, attributes: true,
      attributeFilter: ["class", "style"] });
    function drainWindow() { account(watcher.takeRecords()); }
    add("user", "Read the file.");
    handleEvent({ type: "round", n: 1, tools: 3, run_id: "window-run", session_id: "placement-session" });
    handleEvent({ type: "delta", text: "Let me read the file." });
    handleEvent({ type: "tool", call_id: "window-call-1", name: "read", arguments: { path: "ui/app.js" } });
    handleEvent({ type: "tool_result", name: "read", call_id: "window-call-1", result: { content: "ok" } });
    handleEvent({ type: "round", n: 2, tools: 3, run_id: "window-run", session_id: "placement-session" });
    handleEvent({ type: "delta", text: windowText });
    handleEvent({ type: "reply", message_id: "window-msg", text: windowText });
    liveAnswer = lastBubble().body.querySelector(":scope > " + windowAnswerSelector);
    var windowFirst = windowMetrics(liveAnswer);
    var conversionRecords = watcher.takeRecords();
    windowAttachments = attachmentsIn(conversionRecords);
    check(!!liveAnswer && !!windowFirst,
      "the conversion must place the answer before the window is measured, saw " + windowFirst);
    check(windowAttachments === 1,
      "the conversion must attach the answer to the transcript exactly once, saw " +
      windowAttachments + " attachments");
    check(windowStyleTouches.length === 0,
      "no pass may rewrite the answer's class or style, saw " + JSON.stringify(windowStyleTouches));
    var windowFrame = null, windowLater = null, windowSettled = null, windowReplayed = null;
    await frame();
    windowFrame = windowMetrics(liveAnswer);
    drainWindow();
    await wait(300);
    windowLater = windowMetrics(liveAnswer);
    drainWindow();
    // The passes a run's own end triggers: settlement, the trailing final-answer event, and the durable
    // reply repainted before it. None of them may move, restyle or re-render the answer.
    handleEvent({ type: "done" });
    handleEvent({ type: "final_answer", session_id: "placement-session", run_id: "window-run",
      message_id: "window-msg", answer_id: "window-run:answer", text_len: windowText.length, at: 1792500000001 });
    handleEvent({ type: "reply", message_id: "window-msg", text: windowText });
    windowSettled = windowMetrics(liveAnswer);
    drainWindow();
    check(lastBubble().body.querySelector(":scope > " + windowAnswerSelector) === liveAnswer,
      "the settle passes must leave the answer node the conversion placed in place, not replace it");
    // And the repaint of the durable rows, which is what a window does a moment after a run ends.
    var windowRows = [
      { role: "user", seq: 1, id: "window-user", content: "Read the file.", created_at: 1000 },
      { role: "assistant", seq: 2, id: "window-commentary", content: "Let me read the file.",
        phase: "commentary", created_at: 1001, trace: [] },
      { role: "assistant", seq: 3, id: "window-call", content: "", created_at: 1002, trace: [],
        tool_calls: [{ id: "window-call-1", type: "function",
          function: { name: "read", arguments: "{\"path\":\"ui/app.js\"}" } }] },
      { role: "tool", seq: 4, id: "window-result", content: "ok", tool_name: "read",
        tool_call_id: "window-call-1", ok: 1, created_at: 1003, trace: [] },
      { role: "assistant", seq: 5, id: "window-msg", content: windowText, created_at: 1004, trace: [] }
    ];
    repaintMessages(windowRows, {});
    replayedAnswer = lastBubble().body.querySelector(":scope > " + windowAnswerSelector);
    windowReplayed = windowMetrics(replayedAnswer);
    var repaintRecords = watcher.takeRecords();
    var repaintAttachments = attachmentsIn(repaintRecords);
    account(repaintRecords);
    watcher.disconnect();
    check(!!replayedAnswer, "a repaint of the same rows must draw the answer again");
    check(repaintAttachments === 1,
      "the repaint must draw the answer once, not twice, saw " + repaintAttachments + " attachments");
    windowSame(windowFirst, windowFrame, "one animation frame after the conversion");
    windowSame(windowFirst, windowLater, "300ms after the conversion");
    windowSame(windowFirst, windowSettled, "after the settle passes");
    windowSame(windowFirst, windowReplayed, "after a repaint of the same durable rows");
    check(windowStyleTouches.length === 0,
      "across the whole window no pass may rewrite the answer's class or style, saw " +
      JSON.stringify(windowStyleTouches));
    // The measure itself: the answer is drawn at the transcript's own typography, not at the smaller
    // 12px a topic body used to have. A no-tool run's answer on this same page is the control.
    fresh();
    handleEvent({ type: "round", n: 1, tools: 0, run_id: "window-control", session_id: "placement-session" });
    handleEvent({ type: "delta", text: "A no-tool answer." });
    handleEvent({ type: "reply", message_id: "window-control-msg", text: "A no-tool answer." });
    var controlAnswer = lastBubble().body.querySelector(":scope > " + windowAnswerSelector);
    var control = windowMetrics(controlAnswer);
    check(!!control && !!windowFirst && control.fontSize === windowFirst.fontSize &&
      control.lineHeight === windowFirst.lineHeight,
      "the answer's first paint must already carry the answer's own measure (a no-tool run's answer on " +
      "this page), saw " + (windowFirst ? windowFirst.fontSize + "/" + windowFirst.lineHeight : "none") +
      " vs control " + (control ? control.fontSize + "/" + control.lineHeight : "none"));
    check(!!windowFirst && windowFirst.fontSize !== "12px",
      "the answer must not be painted at the old 12px topic-body measure, saw " +
      (windowFirst ? windowFirst.fontSize : "none"));

    // ---- 4. a run whose request carried NO tools: prose is the answer, as today -----------------
    handleEvent({ type: "done" });
    messages.replaceChildren(); runBubble = null; streamBody = null; streamText = "";
    handleEvent({ type: "round", n: 1, tools: 0, run_id: "placement-run-b", session_id: "placement-session" });
    handleEvent({ type: "delta", text: "No tools here." });
    var plainBubble = lastBubble();
    check(!plainBubble.body.querySelector("wa-commentary"),
      "a no-tool request must not assume commentary: its prose is the answer");
    check(!!plainBubble.body.querySelector(":scope > .seg"),
      "a no-tool request streams its prose as the answer segment");
    handleEvent({ type: "reply", message_id: "placement-msg-b", text: "No tools here." });
    check(!!plainBubble.body.querySelector(":scope > .seg.final-answer:not(.answer-wrap)"),
      "and it settles as an ordinary final answer, not a converted topic body");

    // ---- 4b. a tool-capable run that called no tool: no empty run topic is left behind ----------
    handleEvent({ type: "done" });
    messages.replaceChildren(); runBubble = null; streamBody = null; streamText = "";
    handleEvent({ type: "round", n: 1, tools: 3, run_id: "placement-run-c", session_id: "placement-session" });
    handleEvent({ type: "delta", text: "Only prose, no call." });
    handleEvent({ type: "reply", message_id: "placement-msg-c", text: "Only prose, no call." });
    var soloBubble = lastBubble();
    check(!soloBubble.body.querySelector(":scope > wa-run"),
      "a tool-capable run that called no tool must not leave an empty run topic");
    check(!!soloBubble.body.querySelector(":scope > .seg.final-answer.answer-wrap"),
      "and its converted answer is the only thing outside a (non-existent) topic");

    // ---- 4c. a candidate answer followed by a tool call is activity, not the answer --------------
    handleEvent({ type: "done" });
    messages.replaceChildren(); runBubble = null; streamBody = null; streamText = "";
    handleEvent({ type: "round", n: 1, tools: 3, run_id: "placement-run-d", session_id: "placement-session" });
    handleEvent({ type: "delta", text: "A candidate." });
    handleEvent({ type: "reply", message_id: "placement-msg-d1", text: "A candidate." });
    var candidateBubble = lastBubble();
    check(!!candidateBubble.body.querySelector(":scope > .seg.final-answer.answer-wrap"),
      "the candidate first converts as the answer");
    handleEvent({ type: "tool", call_id: "placement-call-d", name: "read", arguments: { path: "AGENTS.md" } });
    handleEvent({ type: "tool_result", name: "read", call_id: "placement-call-d", result: { content: "ok" } });
    check(!candidateBubble.body.querySelector(":scope > .seg.final-answer"),
      "a later tool call demotes the candidate: it is no longer the final answer");
    check(candidateBubble.textContent.indexOf("A candidate.") >= 0,
      "and the candidate text is retained as activity, not wiped");
    handleEvent({ type: "round", n: 2, tools: 3, run_id: "placement-run-d", session_id: "placement-session" });
    handleEvent({ type: "delta", text: "The real answer." });
    handleEvent({ type: "reply", message_id: "placement-msg-d2", text: "The real answer." });
    var continued = lastBubble().body.querySelector(":scope > .seg.final-answer.answer-wrap");
    check(!!continued && continued.textContent.indexOf("The real answer.") >= 0,
      "a continued run's final answer converts after the tool step");
    check(lastBubble().body.textContent.indexOf("A candidate.") >= 0,
      "and the earlier candidate stays visible in the run topic");

    // ---- 5. scroll at the conversion -------------------------------------------------------------
    function runToAnswer(runId, messageId, text) {
      handleEvent({ type: "round", n: 1, tools: 3, run_id: runId, session_id: "placement-session" });
      handleEvent({ type: "delta", text: text });
      handleEvent({ type: "reply", message_id: messageId, text: text });
      var answer = lastBubble().body.querySelector(":scope > .seg.final-answer.answer-wrap");
      return answer;
    }
    // Tall: anchor the first line.
    handleEvent({ type: "done" });
    messages.replaceChildren(); runBubble = null; streamBody = null; streamText = "";
    setFollow(true);
    for (var fill = 0; fill < 8; fill++) add("user", "Earlier evidence " + ("retained text ".repeat(35)));
    messages.scrollTop = messages.scrollHeight;
    var tallText = "# Start\n\n" + ("A paragraph of readable evidence.\n\n".repeat(90));
    var tall = runToAnswer("placement-run-tall", "placement-msg-tall", tallText);
    check(!!tall && tall.dataset.answerAnchor === "top",
      "an answer whose first line would be off-screen must anchor its top, saw " +
      (tall && tall.dataset.answerAnchor));
    check(!!tall && Math.abs(tall.getBoundingClientRect().top - messages.getBoundingClientRect().top) < 4,
      "and its first line must sit at the chat content top, saw top " +
      (tall ? tall.getBoundingClientRect().top - messages.getBoundingClientRect().top : "none"));
    check(!!tall && Math.abs(tall.getBoundingClientRect().height) > messages.clientHeight * 0.8,
      "the fixture must actually be taller than 80% of the viewport");

    // ---- 5b. A wheel that cannot move the transcript is not the reader leaving it. This was the second
    // half of the reported regression: one stray wheel at the bottom released the answer anchor for the
    // rest of the turn, so the final answer rendered and never came back to its first line. Same fixture,
    // one wheel pointing into the limit.
    handleEvent({ type: "done" });
    messages.replaceChildren(); runBubble = null; streamBody = null; streamText = "";
    setFollow(true);
    for (var fill4 = 0; fill4 < 8; fill4++) add("user", "Earlier evidence " + ("retained text ".repeat(35)));
    messages.scrollTop = messages.scrollHeight;
    handleEvent({ type: "round", n: 1, tools: 3, run_id: "placement-run-wheel", session_id: "placement-session" });
    handleEvent({ type: "delta", text: tallText });
    var atLimit = messages.scrollTop;
    messages.dispatchEvent(new WheelEvent("wheel", { deltaY: 1 }));
    check(messages.scrollTop === atLimit,
      "the fixture's wheel must not move a transcript already at its limit, saw " + atLimit + " -> " + messages.scrollTop);
    handleEvent({ type: "reply", message_id: "placement-msg-wheel", text: tallText });
    var wheelAnswer = lastBubble().body.querySelector(":scope > .seg.final-answer.answer-wrap");
    check(!!wheelAnswer && wheelAnswer.dataset.answerAnchor === "top",
      "a wheel that could not move the transcript must not release the answer anchor, saw " +
      (wheelAnswer && wheelAnswer.dataset.answerAnchor));
    check(!!wheelAnswer && Math.abs(wheelAnswer.getBoundingClientRect().top - messages.getBoundingClientRect().top) < 4,
      "and its first line must still come to the chat top, saw top " +
      (wheelAnswer ? wheelAnswer.getBoundingClientRect().top - messages.getBoundingClientRect().top : "none"));

    // Short: do not scroll.
    handleEvent({ type: "done" });
    messages.replaceChildren(); runBubble = null; streamBody = null; streamText = "";
    setFollow(true);
    for (var fill2 = 0; fill2 < 6; fill2++) add("user", "Earlier evidence " + ("retained text ".repeat(35)));
    messages.scrollTop = messages.scrollHeight;
    handleEvent({ type: "round", n: 1, tools: 3, run_id: "placement-run-short", session_id: "placement-session" });
    handleEvent({ type: "delta", text: "Short answer." });
    // The tail follow while streaming is expected; what the conversion must not do is scroll the
    // reader again. Measure at the conversion boundary, not before the run started.
    var shortBefore = messages.scrollTop;
    handleEvent({ type: "reply", message_id: "placement-msg-short", text: "Short answer." });
    var short = lastBubble().body.querySelector(":scope > .seg.final-answer.answer-wrap");
    check(!!short && short.dataset.answerAnchor === "none",
      "a short answer must not be scrolled into place, saw " + (short && short.dataset.answerAnchor));
    // A short answer is not scrolled into place: its first line is not at the chat top, and the
    // conversion does not chase it (the only movement is the browser clamping a shrunk scroll range).
    check(Math.abs(short.getBoundingClientRect().top - messages.getBoundingClientRect().top) > 4,
      "a short answer must stay where the stream left it, not at the chat top, saw top " +
      (short.getBoundingClientRect().top - messages.getBoundingClientRect().top));
    check(messages.scrollTop <= shortBefore + 8,
      "and the conversion must not scroll down to reveal it, saw " + shortBefore + " -> " + messages.scrollTop);

    // ---- 5e. THE FIRST LINE WHEN THE ANSWER IS DONE (regression, 2026-10-21, second report).
    // A reader who scrolled the thinking during the run is "released" for the whole bubble, and the answer
    // used to stay at its end because of it. Once the answer is finished, its first line is brought to the
    // chat content top if it overflows - unless the reader is reading something EARLIER than the answer.
    var longAnswer = "A paragraph of readable evidence. ".repeat(200);
    handleEvent({ type: "done" });
    messages.replaceChildren(); runBubble = null; streamBody = null; streamText = "";
    // Scroll bookkeeping belongs to a stage, not to the page. An anchor, a release mark or an expected
    // position left by an earlier stage decides the next one's scroll (measured: this stage began at
    // the top of its own transcript and its answer never left the fold, so the anchor it asserts could
    // not be produced). The state under test here is this reader's scroll, so it starts clean.
    answerAnchors.delete(messages); answerReleased.delete(messages);
    answerScrollPositions.delete(messages); answerMotions.delete(messages);
    setFollow(true);
    for (var fill5 = 0; fill5 < 8; fill5++) add("user", "Earlier evidence " + ("retained text ".repeat(35)));
    messages.scrollTop = messages.scrollHeight;
    handleEvent({ type: "round", n: 1, tools: 3, run_id: "placement-run-grow", session_id: "placement-session" });
    handleEvent({ type: "delta", text: longAnswer });
    messages.dispatchEvent(new WheelEvent("wheel", { deltaY: -1 }));
    // CHANGE 2 (operator rule): the run's prose prints inside a COLLAPSED commentary now, so the stream no
    // longer carries the reader down the transcript - their own scroll is the only one left, and it is what
    // this stage is about. The wheel above is what RELEASES them for the bubble; the scroll below is the
    // reader's own position when the run ends. The assertion that follows is unchanged: a released reader
    // still gets the answer's FIRST line.
    messages.scrollTop = messages.scrollHeight;
    messages.dispatchEvent(new Event("scroll"));
    check(answerReleased.has(messages),
      "this stage must measure a RELEASED reader (the scroll during the run is what released them)");
    check(messages.scrollTop >= messages.scrollHeight - messages.clientHeight - 1,
      "and that reader is at the end of the run when the answer lands, saw " + messages.scrollTop +
      "/" + (messages.scrollHeight - messages.clientHeight));
    handleEvent({ type: "reply", message_id: "placement-msg-grow", text: longAnswer });
    var growAnswer = lastBubble().body.querySelector(":scope > .seg.final-answer.answer-wrap");
    var grownTop = growAnswer ? growAnswer.getBoundingClientRect().top - messages.getBoundingClientRect().top : NaN;
    check(!!growAnswer && growAnswer.dataset.answerAnchor === "top",
      "a finished answer whose first line overflows must come to its first line even if the reader " +
      "scrolled during the run, saw " + (growAnswer && growAnswer.dataset.answerAnchor));
    check(!!growAnswer && Math.abs(grownTop) < 4,
      "and that first line must sit at the chat content top, saw top " + grownTop);

    // ...an answer that still fits when it is done is NOT moved.
    handleEvent({ type: "done" });
    messages.replaceChildren(); runBubble = null; streamBody = null; streamText = "";
    setFollow(true);
    for (var fill6 = 0; fill6 < 8; fill6++) add("user", "Earlier evidence " + ("retained text ".repeat(35)));
    messages.scrollTop = messages.scrollHeight;
    handleEvent({ type: "round", n: 1, tools: 3, run_id: "placement-run-fits", session_id: "placement-session" });
    handleEvent({ type: "delta", text: "A short answer that fits." });
    var fitsBefore = messages.scrollTop;
    handleEvent({ type: "reply", message_id: "placement-msg-fits", text: "A short answer that fits." });
    var fitsAnswer = lastBubble().body.querySelector(":scope > .seg.final-answer.answer-wrap");
    var fitsTop = fitsAnswer ? fitsAnswer.getBoundingClientRect().top - messages.getBoundingClientRect().top : NaN;
    check(!!fitsAnswer && fitsAnswer.dataset.answerAnchor === "none",
      "an answer that fits when it is done must not be anchored, saw " + (fitsAnswer && fitsAnswer.dataset.answerAnchor));
    check(fitsTop > 0,
      "and its first line stays visible where the stream left it, saw top " + fitsTop);
    check(messages.scrollTop <= fitsBefore + 8,
      "and the reader is not scrolled, saw " + fitsBefore + " -> " + messages.scrollTop);

    // ...and a reader reading EARLIER content than the answer is never pulled forward into it.
    handleEvent({ type: "done" });
    messages.replaceChildren(); runBubble = null; streamBody = null; streamText = "";
    setFollow(true);
    for (var fill7 = 0; fill7 < 12; fill7++) add("user", "Earlier evidence " + ("retained text ".repeat(35)));
    messages.scrollTop = 0;
    messages.dispatchEvent(new Event("scroll"));
    var earlierBefore = messages.scrollTop;
    handleEvent({ type: "round", n: 1, tools: 3, run_id: "placement-run-earlier", session_id: "placement-session" });
    handleEvent({ type: "delta", text: longAnswer });
    handleEvent({ type: "reply", message_id: "placement-msg-earlier", text: longAnswer });
    var earlierAnswer = lastBubble().body.querySelector(":scope > .seg.final-answer.answer-wrap");
    check(messages.scrollTop === earlierBefore,
      "a reader reading earlier content must not be pulled into the answer, saw " + earlierBefore + " -> " + messages.scrollTop);
    check(!!earlierAnswer && earlierAnswer.dataset.answerAnchor !== "top",
      "and that answer is not claimed as anchored, saw " + (earlierAnswer && earlierAnswer.dataset.answerAnchor));

    var verdict = "PASS: thinking streams in the thinking topic; a tool-capable run streams its prose " +
      "inside commentary from the first chunk, settles a commentary label on a tool call, and converts " +
      "the same block into the one answer outside the run topic with an unmoved text box; that first " +
      "paint is already the final one - the answer's own measure, unchanged one frame, 300ms, the " +
      "settle passes and a durable repaint later, with no pass touching its class or style; a no-tool " +
      "run answers directly; tall answers anchor their top, short answers and scrolled-up readers are " +
      "left alone; onFinalAnswer fires once and refuses a replay; a thinking topic survives the tool step that follows it and is closed by the next thinking or decision topic; the settled commentary body takes the transcript speech colour while thinking keeps the muted route colour";
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
