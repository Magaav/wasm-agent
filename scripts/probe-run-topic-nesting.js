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
// Written without await and without timers: headless virtual time does not advance, so the probe
// runs synchronously against the DOM `handleEvent` built.
(function () {
  var problems = [];
  function check(ok, label) { if (!ok) problems.push(label); }
  function indexIn(parent, node) { return Array.prototype.indexOf.call(parent.children, node); }
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

    // ---- 3. the route where the phase is only known at the end of the step: the text streams into
    // a provisional segment, then the node says commentary. It must resolve in place, not move.
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "pending_delta", pending_id: "probe-pending", text: "Provisional " });
    window.handleEvent({ type: "pending_delta", pending_id: "probe-pending", text: "progress." });
    var bubble3 = lastAssistant();
    var provisional = bubble3 && bubble3.body.querySelector(":scope > .phase-pending");
    check(!!provisional, "unknown phase must still render as provisional text");
    var provisionalIndex = provisional ? indexIn(bubble3.body, provisional) : -1;
    window.handleEvent({ type: "commentary", pending_id: "probe-pending",
      message_id: "probe-commentary-2", text: "Provisional progress." });
    var resolved = bubble3 && bubble3.body.querySelector(
      ':scope > wa-commentary[data-message-id="probe-commentary-2"]');
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

    result = { status: problems.length ? "fail" : "pass",
      text: problems.length ? "FAIL: " + problems.join(" ;; ") : "PASS: run steps stay in the bubble until the final answer nests them" };
  } catch (error) {
    result = { status: "fail", text: "probe threw: " + (error && (error.stack || error.message || error)) };
  }

  var pre = document.createElement("pre");
  pre.id = "wa-probe";
  pre.setAttribute("data-status", result.status);
  pre.textContent = result.text;
  document.body.append(pre);
})();
