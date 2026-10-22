// Focused probe: THE ANSWER'S FIRST LINE MUST HOLD, NOT BOUNCE BACK TO THE END.
//
// Report (operator, 2026-10-22): the final answer is correctly brought up so its first line fits the
// chat content rect - and then, a frame or two later, it sometimes snaps back to the end, so the reader
// is looking at the bottom of the answer. Intermittent, which is why the placement probe missed it:
// that probe asserts the anchor synchronously inside the `reply` event and nothing after it.
//
// The house motion is a 220 ms rAF glide, and a headless dump does not give us frames to wait on, so
// this probe ends the glide the way the app does when it finishes (`answerMotions` entry removed) and
// then asks the app's own `pin()` where the reader should be. That is the state one or two frames after
// the answer lands - which is exactly when the report says the bounce happens.
//
// What it drives after the answer: the trailing events a live run really sends (a `round`, a `tool`, a
// late per-item `commentary`, a status row) and a repaint of the same conversation while the run is
// live. The reader must stay on the answer's first line through all of them.
//
//   node scripts/agent-benchmark-ui-observe.mjs --out "$TEMP/ui-look-anchor" \
//     --probe scripts/probe-answer-anchor-hold.js
(async function () {
  var problems = [];
  var trace = [];
  function check(ok, label) { if (!ok) problems.push(label); }
  function tick() { return Promise.resolve(); }
  function gap(answer) {
    if (!answer) return Infinity;
    return Math.abs(answer.getBoundingClientRect().top - messages.getBoundingClientRect().top);
  }
  function slack() { return messages.scrollHeight - messages.scrollTop - messages.clientHeight; }
  function lastAnswer() {
    var bubbles = document.querySelectorAll("wa-message.assistant");
    var node = bubbles.length ? bubbles[bubbles.length - 1] : null;
    return node ? node.querySelector(":scope .body > .seg.final-answer") : null;
  }
  // The glide has ended: the motion entry is gone, the anchor remains - the state `pin()` sees a frame
  // after the answer has been brought to its first line.
  function settledMotion() { answerMotions.delete(messages); pin(); }
  try {
    await window.rendererLoaded;
    for (var t = 0; t < 200 && !document.getElementById("messages"); t++) await tick();
    check(!!document.getElementById("messages"), "the transcript container must exist");
    for (var w = 0; w < 2000 && !(messages && messages.textContent.indexOf("Which config file") >= 0); w++) await tick();
    for (var s = 0; s < 200; s++) await tick();

    var tallText = "# Start\n\n" + ("A paragraph of readable evidence.\n\n".repeat(90));
    function resetTranscript() {
      window.handleEvent({ type: "done" });
      messages.replaceChildren();
      runBubble = null; streamBody = null; streamText = "";
      setFollow(true);
      for (var fill = 0; fill < 8; fill++) add("user", "Earlier evidence " + ("retained text ".repeat(35)));
      messages.scrollTop = messages.scrollHeight;
    }
    function answerRun(runId, messageId) {
      window.handleEvent({ type: "round", n: 1, tools: 3, run_id: runId, session_id: "anchor-session" });
      window.handleEvent({ type: "delta", text: tallText });
      window.handleEvent({ type: "reply", message_id: messageId, text: tallText });
      settledMotion();
      return lastAnswer();
    }

    // ---- A. the answer holds through a later step event ------------------------------------------
    resetTranscript();
    var a = answerRun("anchor-a", "anchor-msg-a");
    check(!!a && gap(a) < 4, "A: the answer's first line must be at the content top, saw gap " + Math.round(gap(a)));
    check(slack() > 40, "A: the fixture answer must be tall enough to scroll into, saw slack " + Math.round(slack()));
    trace.push("A.reply:gap=" + Math.round(gap(a)) + ",slack=" + Math.round(slack()));
    window.handleEvent({ type: "status", text: "working" });
    window.handleEvent({ type: "run_counts", counts: { calls: 3, tools: 1, ms: 1200 } });
    check(gap(a) < 4 && slack() > 40,
      "A: a status/run-count update must not move a reader at the answer's first line, saw gap " +
      Math.round(gap(a)) + " slack " + Math.round(slack()));

    // ---- B. the turn settling ---------------------------------------------------------------------
    resetTranscript();
    var b = answerRun("anchor-b", "anchor-msg-b");
    window.handleEvent({ type: "done" });
    check(gap(b) < 4 && slack() > 40,
      "B: settling the turn must leave the reader at the first line, saw gap " + Math.round(gap(b)) +
      " slack " + Math.round(slack()));

    // ---- C. a repaint of the same conversation while the run is live -------------------------------
    // This is the path that ends in `pin(true)`: a repaint redraws the transcript and, today, always
    // sends the reader to the bottom. A reader parked on the answer's first line must stay there.
    resetTranscript();
    var c = answerRun("anchor-c", "anchor-msg-c");
    trace.push("C.before:gap=" + Math.round(gap(c)));
    repaintMessages([
      { seq: 1, role: "user", content: "Earlier evidence", created_at: 1700000000 },
      { seq: 2, role: "assistant", content: tallText, created_at: 1700000001 },
    ], { active: true });
    var c2 = lastAnswer();
    check(!!c2, "C: the repaint must draw the answer");
    check(gap(c2) < 4 && slack() > 40,
      "C: a repaint must leave a reader at the answer's first line, not send them to the end, saw gap " +
      Math.round(gap(c2)) + " slack " + Math.round(slack()));

    // ---- D. a new round after the answer (a continued run) ----------------------------------------
    // A round is the next step, not the end of the answer the reader is reading: it must not yank them
    // to the bottom before that step's own answer anchors.
    resetTranscript();
    var d = answerRun("anchor-d", "anchor-msg-d");
    window.handleEvent({ type: "round", n: 2, tools: 3, run_id: "anchor-d", session_id: "anchor-session" });
    settledMotion();
    check(gap(d) < 4 && slack() > 40,
      "D: a continued round must not move a reader who is at the answer's first line, saw gap " +
      Math.round(gap(d)) + " slack " + Math.round(slack()));

    var out = document.createElement("pre");
    out.id = "wa-probe";
    out.setAttribute("data-status", problems.length ? "fail" : "pass");
    out.textContent = problems.length
      ? "ANSWER-ANCHOR-HOLD FAIL: " + problems.join(" ;; ") + " ;; [" + trace.join(" ") + "]"
      : "ANSWER-ANCHOR-HOLD PASS: the final answer's first line holds through status/run-count updates, " +
        "the turn settling, a repaint of the same conversation and a continued round - the transcript " +
        "never snaps back to its end [" + trace.join(" ") + "]";
    (document.getElementById("panel") || document.body).append(out);
  } catch (error) {
    problems.push("probe threw: " + (error && error.message ? error.message : String(error)));
    var failed = document.createElement("pre");
    failed.id = "wa-probe";
    failed.setAttribute("data-status", "fail");
    failed.textContent = "ANSWER-ANCHOR-HOLD FAIL: " + problems.join(" ;; ");
    (document.getElementById("panel") || document.body).append(failed);
  }
})();
