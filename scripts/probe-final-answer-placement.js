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
//   * the answer's text box must not be re-laid out by the conversion: same box and same computed
//     font-size/line-height/padding before and after, compared through `waProbeSameAs` against a
//     fingerprint captured before the conversion.
//   * scroll: a tall answer anchors its first line, a short answer does not move the reader, and a
//     reader who scrolled up during the run is not pulled back.
//   * `onFinalAnswer` fires once with the documented ids/lengths payload and refuses a replay of the
//     same run/message.
//
// Synchronous, like the other probes: headless virtual time does not advance.
(function () {
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

    // The hard constraint: same text box, same computed metrics.
    var answerBodyAfter = answer.querySelector(":scope > .commentary-body");
    var afterMetrics = metrics(answerBodyAfter);
    var same = waProbeSameAs(beforeClone, answerBodyAfter, { text: true });
    check(same.equal, "the answer text box must keep its structure across the conversion: " + waProbeDiff(same));
    check(sameMetrics(beforeMetrics, afterMetrics),
      "the answer text box must not change metrics across the conversion: before [" +
      metricText(beforeMetrics) + "] after [" + metricText(afterMetrics) + "]");
    var reported = JSON.parse(answer.dataset.conversionMetrics || "{}");
    check(!!reported.before && reported.widthDelta === 0 && reported.heightDelta === 0 &&
      reported.leftDelta === 0,
      "the conversion's own measurement must be 0px, saw " + JSON.stringify(reported));
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
      "a tall answer (>80% of the chat viewport) must anchor its top, saw " +
      (tall && tall.dataset.answerAnchor));
    check(!!tall && Math.abs(tall.getBoundingClientRect().top - messages.getBoundingClientRect().top) < 4,
      "and its first line must sit at the chat content top, saw top " +
      (tall ? tall.getBoundingClientRect().top - messages.getBoundingClientRect().top : "none"));
    check(!!tall && Math.abs(tall.getBoundingClientRect().height) > messages.clientHeight * 0.8,
      "the fixture must actually be taller than 80% of the viewport");

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

    // Reader scrolled up during the run: never pulled back.
    handleEvent({ type: "done" });
    messages.replaceChildren(); runBubble = null; streamBody = null; streamText = "";
    setFollow(true);
    for (var fill3 = 0; fill3 < 8; fill3++) add("user", "Earlier evidence " + ("retained text ".repeat(35)));
    messages.scrollTop = messages.scrollHeight;
    handleEvent({ type: "round", n: 1, tools: 3, run_id: "placement-run-reader", session_id: "placement-session" });
    handleEvent({ type: "delta", text: "A long answer " + ("that keeps going.\n\n".repeat(60)) });
    messages.dispatchEvent(new WheelEvent("wheel", { deltaY: -1 }));
    messages.scrollTop = Math.max(0, messages.scrollTop - 120);
    messages.dispatchEvent(new Event("scroll"));
    var readerPosition = messages.scrollTop;
    handleEvent({ type: "reply", message_id: "placement-msg-reader", text: "A long answer" });
    var readerAnswer = lastBubble().body.querySelector(":scope > .seg.final-answer.answer-wrap");
    check(!!readerAnswer && readerAnswer.dataset.answerAnchor === "reader-released",
      "a reader already in scrollback must be recorded as released, saw " +
      (readerAnswer && readerAnswer.dataset.answerAnchor));
    check(messages.scrollTop === readerPosition,
      "and must not be pulled to the new answer, saw " + readerPosition + " -> " + messages.scrollTop);

    var verdict = "PASS: thinking streams in the thinking topic; a tool-capable run streams its prose " +
      "inside commentary from the first chunk, settles a commentary label on a tool call, and converts " +
      "the same block into the one answer outside the run topic with an unmoved text box; a no-tool run " +
      "answers directly; tall answers anchor their top, short answers and scrolled-up readers are left " +
      "alone; onFinalAnswer fires once and refuses a replay";
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
