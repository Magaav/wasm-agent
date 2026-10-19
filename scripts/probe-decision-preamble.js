// Focused probe: a step that ends in a tool call is a decision step, so the prose it wrote before
// choosing is a step of the run, not an answer. While the run is still stepping that prose and the
// tool rows it chose are drawn directly in the conversation bubble - nothing is folded into a run
// topic yet; the final answer is what folds the whole history in and stays outside it. Replayed from
// durable rows, the same structure comes back.
//
// The live half of this contract changed: commentary used to be moved into an open run topic as soon
// as its phase arrived, which the operator reported as a defect (a run that is still stepping must
// not hide its steps in a topic, and the move belongs to the final answer). The settled and repaint
// halves are unchanged, and both are still checked below.
//
// Run with the disposable observer (it serves a copy of ui/ with test-fixtures.js injected, in real
// headless Chrome, and writes screenshot.png + dom.html):
//
//   node scripts/agent-benchmark-ui-observe.mjs --out "$TEMP/ui-look" \
//     --probe scripts/probe-decision-preamble.js
//
// The probe is ordered so the screenshot is worth reading: the live run is drawn last and stays live,
// with its topic open, so the image shows the prelude inside the topic it belongs to and an answer
// outside the topic above it. Every claim is checked in the DOM; the image is the second reading.
(async function () {
  var problems = [];
  function check(ok, label) { if (!ok) problems.push(label); }
  function tick() { return Promise.resolve(); }
  try {
    await window.rendererLoaded;
    for (var t = 0; t < 200 && !document.getElementById("messages"); t++) await tick();
    var messages = document.getElementById("messages");
    check(!!messages, "the transcript container must exist before the probe can draw anything");
    // The window restores its own conversation first and redraws the transcript when it lands, so a
    // probe that draws immediately is drawing into a container about to be emptied. Wait for that
    // restore to have drawn the fixture conversation it was served, then give it rounds to settle.
    for (var w = 0; w < 2000 && !(messages && messages.textContent.indexOf("Which config file") >= 0); w++) await tick();
    for (var s = 0; s < 200; s++) await tick();
    check(!!(messages && messages.textContent.indexOf("Which config file") >= 0),
      "the window must have restored its own transcript before the probe draws its own runs");
    var before = messages.querySelectorAll("wa-message.assistant").length;

    // ---- A. control: the same prose, a step that did NOT call a tool, stays an answer -------------
    // The signal is the provider's completion reason and nothing else, so a step that finishes
    // normally must keep today's behaviour: its text is answer text and it creates no run topic.
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "delta", text: "The ledger agrees; that is the whole answer." });
    window.handleEvent({ type: "reply", text: "The ledger agrees; that is the whole answer.",
      message_id: "probe-answer-0" });
    window.handleEvent({ type: "done" });
    await tick();
    var control = messages.querySelectorAll("wa-message.assistant");
    var controlBubble = control[control.length - 1];
    var controlBody = controlBubble ? controlBubble.querySelector(".body") : null;
    var controlSeg = controlBody ? controlBody.querySelector(":scope > .seg") : null;
    check(control.length === before + 1,
      "a text-only step must draw one assistant bubble, saw " + control.length + " from " + before);
    check(!!controlSeg && controlSeg.textContent.indexOf("The ledger agrees") >= 0,
      "a step that did not call a tool keeps its text as answer text");
    check(!controlBody || !controlBody.querySelector(":scope > wa-run"),
      "a text-only answer must not create a run topic");
    check(!controlBody || !controlBody.querySelector("wa-commentary[data-decision-prelude='true']"),
      "a text-only answer must not be marked as a decision prelude");

    // ---- B. a settled decision step: prose in the topic, answer outside it ------------------------
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "delta", text: "Let me get the numbers rather than assert." });
    window.handleEvent({ type: "decision", call_id: "probe-call-1", name: "bash",
      arguments_text: '{"command":"ledger"}', complete: false });
    window.handleEvent({ type: "decision", call_id: "probe-call-1", name: "bash",
      arguments_text: '{"command":"ledger"}', complete: true });
    // What the node emits once the step's own completion reason is known (finish_reason tool_calls).
    window.handleEvent({ type: "step_phase", phase: "commentary",
      text: "Let me get the numbers rather than assert.", message_id: "probe-prelude-1", round: 1 });
    window.handleEvent({ type: "tool", call_id: "probe-call-1", name: "bash",
      arguments: { command: "ledger" } });
    window.handleEvent({ type: "tool_result", name: "bash", result: { code: 0, stdout: "ok" } });
    window.handleEvent({ type: "round", n: 2 });
    window.handleEvent({ type: "delta", text: "Short answer: no - and here is why." });
    window.handleEvent({ type: "reply", text: "Short answer: no - and here is why.",
      message_id: "probe-answer-1" });
    window.handleEvent({ type: "done" });
    await tick();
    var settledBubbles = messages.querySelectorAll("wa-message.assistant");
    var settled = settledBubbles[settledBubbles.length - 1];
    var settledBody = settled ? settled.querySelector(".body") : null;
    var settledRun = settledBody ? settledBody.querySelector(":scope > wa-run") : null;
    var settledPrelude = settledRun
      ? settledRun.querySelector("wa-commentary[data-decision-prelude='true']") : null;
    check(settledBubbles.length === before + 2,
      "the settled run must be its own bubble, saw " + settledBubbles.length + " from " + before);
    check(!!settledRun, "a run that called a tool must have a run topic");
    check(!!settledPrelude && settledPrelude.textContent.indexOf("Let me get the numbers") >= 0,
      "a decision step's prose must be a commentary inside the run topic, saw: " +
      (settledRun ? settledRun.textContent.slice(0, 160) : "no run topic"));
    check(!!settledBody && !settledBody.querySelector(":scope > .seg[data-message-id='probe-prelude-1']"),
      "the prelude must not also remain as an answer segment");
    var settledAnswer = settledBody ? settledBody.querySelector(":scope > .seg") : null;
    check(!!settledAnswer && settledAnswer.textContent.indexOf("Short answer: no") >= 0,
      "the final answer must stay outside the run topic, saw: " +
      (settledAnswer ? settledAnswer.textContent.slice(0, 120) : "no answer segment"));
    check(!!settledRun && !settledRun.textContent.includes("Short answer: no"),
      "the final answer must not be inside the run topic");
    var settledMeta = settledRun ? settledRun.querySelector(".trace-meta") : null;
    var metaText = settledMeta ? settledMeta.textContent : "";
    check(metaText.indexOf("1 step") >= 0,
      "the prelude still counts as one visible text step, saw: " + metaText);
    check(metaText.indexOf("1 tool call") >= 0,
      "the tool call count is unchanged by the phase marker, saw: " + metaText);
    if (settledRun) settledRun.open = true;

    // ---- C. a repaint from durable rows reconstructs the same structure --------------------------
    // `phase = "commentary"` on a row that also carries tool calls is the durable half of the rule;
    // the child renderer is the window's own renderer, so this is also the main/child parity check.
    var host = document.createElement("div");
    host.className = "probe-replay";
    messages.append(host);
    paintChildTranscript(host, [
      { seq: 1, role: "user", content: "did the ledger really do that?", created_at: 1000 },
      { seq: 2, role: "assistant", phase: "commentary",
        content: "Let me get the numbers rather than assert.",
        tool_calls: [{ id: "replay-call-1", type: "function",
          function: { name: "bash", arguments: '{"command":"ledger"}' } }],
        created_at: 1001 },
      { seq: 3, role: "tool", tool_call_id: "replay-call-1", tool_name: "bash", ok: 1,
        content: "ok", created_at: 1002 },
      { seq: 4, role: "assistant", phase: "", content: "Short answer: no - and here is why.",
        tool_calls: [], created_at: 1003 },
    ], { active: true });
    await tick();
    var replay = host.querySelector("wa-message.assistant");
    var replayBody = replay ? replay.querySelector(".body") : null;
    var replayRun = replayBody ? replayBody.querySelector(":scope > wa-run") : null;
    var replayPrelude = replayRun
      ? replayRun.querySelector("wa-commentary[data-decision-prelude='true']") : null;
    check(!!replayRun, "a repainted decision step must reconstruct the run topic");
    check(!!replayPrelude && replayPrelude.textContent.indexOf("Let me get the numbers") >= 0,
      "a repaint must put the stored prelude back inside the run topic, saw: " +
      (replayRun ? replayRun.textContent.slice(0, 160) : "no run topic"));
    check(!!replayBody && !!replayBody.querySelector(":scope > .seg") &&
      replayBody.querySelector(":scope > .seg").textContent.indexOf("Short answer: no") >= 0,
      "a repaint must leave the stored final answer outside the run topic");
    check(!!replayRun && !replayRun.textContent.includes("Short answer: no"),
      "a repaint must not fold the final answer into the run topic");

    // ---- D. the live run, drawn last so the screenshot shows it as it happened --------------------
    var beforeLive = messages.querySelectorAll("wa-message.assistant").length;
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "delta", text: "Checking the ledger before I answer." });
    window.handleEvent({ type: "decision", call_id: "probe-call-2", name: "read",
      arguments_text: '{"path":"review/ledger.json"}', complete: true });
    window.handleEvent({ type: "step_phase", phase: "commentary",
      text: "Checking the ledger before I answer.", message_id: "probe-prelude-2", round: 1 });
    window.handleEvent({ type: "tool", call_id: "probe-call-2", name: "read",
      arguments: { path: "review/ledger.json" } });
    await tick();
    var liveBubbles = messages.querySelectorAll("wa-message.assistant");
    var live = liveBubbles[liveBubbles.length - 1];
    var liveBody = live ? live.querySelector(".body") : null;
    var liveRun = liveBody ? liveBody.querySelector(":scope > wa-run") : null;
    var livePrelude = liveBody
      ? liveBody.querySelector(":scope > wa-commentary[data-decision-prelude='true']") : null;
    check(liveBubbles.length === beforeLive + 1,
      "the live run must be its own bubble, saw " + liveBubbles.length + " from " + beforeLive);
    check(!liveRun, "a run that is still stepping must not fold its steps into a run topic yet, saw: " +
      (liveRun ? liveRun.textContent.slice(0, 160) : "no run topic"));
    check(!!livePrelude && livePrelude.textContent.indexOf("Checking the ledger") >= 0,
      "while the run is live, the decision step's prose is drawn directly in the bubble, saw: " +
      (liveBody ? liveBody.textContent.slice(0, 160) : "no bubble"));
    check(!!liveBody && !liveBody.querySelector(":scope > .seg"),
      "while the run is live, nothing may sit in the answer's place: the step did not answer");
    check(!!liveBody && !!liveBody.querySelector(":scope > wa-trace .tool-line[data-call-id='probe-call-2']"),
      "the tool the decision chose must be the row beside that prose, still in the bubble");
  } catch (error) {
    problems.push("probe threw: " + (error && error.message ? error.message : String(error)));
  }
  // ---- E. the stage the image is read from -------------------------------------------------------
  // The window keeps repainting its own transcript after this probe returns (its restore and its
  // watch both redraw it), so anything drawn into #messages is gone when the screenshot is taken.
  // The stage below is the same renderer and the same `handleEvent` - run inside a container the app
  // does not own, exactly as a child pane is drawn - so the picture survives without a second
  // renderer. Two panes: a settled run, and a run that is still live.
  try {
    var stage = document.createElement("div");
    stage.id = "wa-stage";
    stage.style.cssText = "position:fixed;left:0;right:0;bottom:0;z-index:900;max-height:88vh;overflow:auto;" +
      "background:#0b0d12;border-top:1px solid #2a3040;padding:8px 12px;color:#cfd6e4;" +
      "font:12px/1.5 ui-monospace,monospace;";
    document.documentElement.append(stage);
    function caption(text) {
      var line = document.createElement("div");
      line.style.cssText = "margin:6px 0 2px;color:#8bbcff;";
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
    caption("live decision step: the prose and the tool row it chose are both in the bubble - no run topic yet");
    var livePane = paneFor([
      { type: "round", n: 1 },
      { type: "delta", text: "Checking the ledger before I answer." },
      { type: "decision", call_id: "stage-call-2", name: "read",
        arguments_text: '{"path":"review/ledger.json"}', complete: true },
      { type: "step_phase", phase: "commentary",
        text: "Checking the ledger before I answer.", message_id: "stage-prelude-2", round: 1 },
      { type: "tool", call_id: "stage-call-2", name: "read",
        arguments: { path: "review/ledger.json" } },
    ]);
    check(!livePane.querySelector("wa-run"),
      "stage: a live run must not be drawn as a folded topic");
    check(!!livePane.querySelector("wa-commentary[data-decision-prelude='true']"),
      "stage: the live prelude must be drawn in the bubble, where the run is happening");
    check(!!livePane.querySelector("wa-trace .tool-line[data-call-id='stage-call-2']"),
      "stage: the tool row the decision chose must be beside it");
    check(!livePane.querySelector(".seg"),
      "stage: the live pane must have no answer segment - the step did not answer");
    caption("settled decision step: prelude inside the run topic, final answer below it (outside)");
    var settledPane = paneFor([
      { type: "round", n: 1 },
      { type: "delta", text: "Let me get the numbers rather than assert." },
      { type: "decision", call_id: "stage-call-1", name: "bash",
        arguments_text: '{"command":"ledger"}', complete: true },
      { type: "step_phase", phase: "commentary",
        text: "Let me get the numbers rather than assert.", message_id: "stage-prelude-1", round: 1 },
      { type: "tool", call_id: "stage-call-1", name: "bash", arguments: { command: "ledger" } },
      { type: "tool_result", name: "bash", result: { code: 0, stdout: "ok" } },
      { type: "round", n: 2 },
      { type: "delta", text: "Short answer: no - and here is why." },
      { type: "reply", text: "Short answer: no - and here is why.", message_id: "stage-answer-1" },
    ]);
    var settledTopic = settledPane.querySelector("wa-run");
    if (settledTopic) settledTopic.open = true;
    var settledInside = settledPane.querySelector("wa-run wa-commentary[data-decision-prelude='true']");
    var settledOutside = Array.prototype.filter.call(settledPane.querySelectorAll(".seg"),
      function (node) { return !node.closest("wa-run"); })[0] || null;
    check(!!settledInside, "stage: the settled prelude must be inside the run topic");
    check(!!settledOutside && settledOutside.textContent.indexOf("Short answer: no") >= 0,
      "stage: the settled answer must be outside the run topic");
    check(!settledTopic || !settledTopic.textContent.includes("Short answer: no"),
      "stage: the settled answer must not be inside the run topic");

  } catch (error) {
    problems.push("stage threw: " + (error && error.message ? error.message : String(error)));
  }
  var out = document.createElement("pre");
  out.id = "wa-probe";
  out.setAttribute("data-status", problems.length ? "fail" : "pass");
  // Geometry of the things the screenshot is supposed to show: a passing probe over an empty page is
  // not evidence, so the rectangles are reported with the verdict.
  function rect(node) {
    if (!node) return "absent";
    var r = node.getBoundingClientRect();
    return Math.round(r.left) + "," + Math.round(r.top) + " " + Math.round(r.width) + "x" + Math.round(r.height);
  }
  var bubbles = document.querySelectorAll("#messages wa-message.assistant");
  var live = bubbles[bubbles.length - 1] || null;
  function styleOf(node) {
    if (!node) return "absent";
    var s = getComputedStyle(node);
    return s.display + "/" + s.visibility + "/o" + s.opacity + "/" + s.position + "/z" + s.zIndex;
  }
  var panel = document.getElementById("panel");
  var msgEl = document.getElementById("messages");
  var geometry = " [messages " + rect(msgEl) + " " + styleOf(msgEl) +
    "; panel " + rect(panel) + " " + styleOf(panel) +
    "; live-bubble " + rect(live) + " " + styleOf(live) +
    "; live-run " + rect(live && live.querySelector("wa-run")) +
    "; live-content " + rect(live && live.querySelector("wa-run wa-commentary")) +
    "; scroll " + (msgEl ? msgEl.scrollTop + "/" + msgEl.scrollHeight + "/" + msgEl.clientHeight : "?") +
    "; viewport " + window.innerWidth + "x" + window.innerHeight + "]";
  out.textContent = (problems.length
    ? "DECISION-PREAMBLE FAIL: " + problems.join(" ;; ")
    : "DECISION-PREAMBLE PASS: a decision step's prose is drawn in the bubble while the run is " +
      "stepping, inside the run topic once the answer folds it (live, settled and on repaint), " +
      "and a step that did not call a tool keeps its answer") + geometry;
  var host = document.getElementById("panel") || document.body;
  host.append(out);
})();
