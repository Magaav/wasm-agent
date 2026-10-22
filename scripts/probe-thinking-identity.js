// Focused probe: ONE ROUND'S THOUGHT IS ONE TOPIC - even when the step's own prose closes that topic
// before the node's authoritative copy of the round's reasoning arrives.
//
// The defect this pins (operator screenshot, one turn, 2026-10-22): the transcript showed TWO
// collapsible blocks, each labelled `thinking 2525 chars`, holding the same thinking text. The ledger
// had ONE row carrying that 2525-character reasoning (session 84a76ce0, seq 1769, phase commentary),
// so nothing was stored twice - it was drawn twice.
//
// How it is drawn twice, in the subscription route:
//   1. `thinking_delta` streams the round's thought  -> one topic, text accumulating;
//   2. the same step's prose starts streaming (`pending_delta`), and a commentary is the next topic,
//      so `appendReasoning`'s topic is SEALED in place (`sealReasoning`);
//   3. the round ends and the node emits its authoritative copy of that round's reasoning
//      (`{type:"reasoning", round, complete:true}`, lua/core/agent.lua) - and, because the topic was
//      sealed, the UI built a SECOND topic and wrote the same text into it.
//
// The identity that fixes it is the round's, never the text: the authoritative copy belongs to the
// topic that streamed that round, so it must be written INTO it. Text equality is not an identity -
// dropping "the same text again" is what once discarded the replay half of a streamed block, which is
// why the second and third checks below feed halves that must both survive.
//
//   node scripts/agent-benchmark-ui-observe.mjs --out "$TEMP/ui-look" \
//     --probe scripts/probe-thinking-identity.js
(async function () {
  var problems = [];
  function check(ok, label) { if (!ok) problems.push(label); }
  function tick() { return Promise.resolve(); }
  function bodyText(topic) {
    var body = topic ? topic.querySelector(".reasoning-body") : null;
    return body ? body.textContent : "";
  }
  function topicsOf(pane) { return pane.querySelectorAll("wa-message wa-reasoning"); }
  try {
    await window.rendererLoaded;
    for (var t = 0; t < 200 && !document.getElementById("messages"); t++) await tick();
    check(!!document.getElementById("messages"), "the transcript container must exist");

    var stage = document.createElement("div");
    stage.id = "wa-stage";
    stage.style.cssText = "position:fixed;left:0;right:0;bottom:0;z-index:900;max-height:88vh;" +
      "overflow:auto;background:#0b0d12;border-top:1px solid #2a3040;padding:8px 12px;color:#cfd6e4;" +
      "font:12px/1.5 ui-monospace,monospace;";
    document.documentElement.append(stage);
    function caption(text) {
      var line = document.createElement("div");
      line.style.cssText = "margin:6px 0 2px;color:#8bbcff;";
      line.textContent = text;
      stage.append(line);
    }
    function paneWith(events) {
      var pane = document.createElement("div");
      stage.append(pane);
      withChildRenderer(pane, { session_id: "probe-reasoning", subagent_id: "probe",
        state: "running", settled: false }, function () {
        for (var i = 0; i < events.length; i++) window.handleEvent(events[i]);
      });
      return pane;
    }

    // ---- A. one round whose prose sealed the thought before its authoritative copy arrived --------
    var halfOne = "The operator saw two blocks. ";
    var halfTwo = "The ledger holds one row.";
    var authoritative = halfOne + halfTwo;
    var paneA = paneWith([
      { type: "round", n: 1, tools: 3 },
      { type: "reasoning", text: halfOne, chars: halfOne.length },
      { type: "reasoning", text: halfTwo, chars: authoritative.length },
      { type: "pending_delta", pending_id: "probe:a-1", text: "Checking the ledger." },
      { type: "reasoning", text: authoritative, round: 1, complete: true },
    ]);
    var topicsA = topicsOf(paneA);
    check(topicsA.length === 1,
      "one round is one thinking topic even when its prose sealed it first, saw " + topicsA.length +
      " topics: " + Array.prototype.map.call(topicsA, bodyText).join(" || "));
    var textA = topicsA.length ? bodyText(topicsA[0]) : "";
    check(textA.indexOf(authoritative) >= 0,
      "the authoritative copy must be present whole, saw: " + JSON.stringify(textA));
    var occurrences = textA.split(authoritative).length - 1;
    check(occurrences === 1,
      "the round's thought must be drawn once, saw it " + occurrences + " times");

    // ---- B. a replayed stream arrives in halves, with no authoritative copy ----------------------
    // Two durable rows, each carrying part of one streamed block: both halves are content and must
    // concatenate. This is the half a text-equality dedupe dropped once; it must never come back.
    var paneB = paneWith([
      { type: "round", n: 1, tools: 3 },
      { type: "reasoning", text: "first half, ", chars: 12 },
      { type: "reasoning", text: "second half.", chars: 24 },
    ]);
    var topicsB = topicsOf(paneB);
    var textB = topicsB.length ? bodyText(topicsB[0]) : "";
    check(topicsB.length === 1,
      "a replayed stream in two halves is one topic, saw " + topicsB.length);
    check(textB.indexOf("first half, second half.") >= 0,
      "a replay must render the concatenation of both halves, saw: " + JSON.stringify(textB));

    // ---- C. an authoritative copy longer than what streamed keeps the tail ----------------------
    // The stream can be cut short (an interrupted delta); the node's copy is the whole round. It
    // replaces the round's streamed part, so the tail is content, not a duplicate.
    var paneC = paneWith([
      { type: "round", n: 1, tools: 3 },
      { type: "reasoning", text: "the thought began ", chars: 17 },
      { type: "pending_delta", pending_id: "probe:c-1", text: "Working." },
      { type: "reasoning", text: "the thought began and then continued to its end.", round: 1,
        complete: true },
    ]);
    var topicsC = topicsOf(paneC);
    var textC = topicsC.length ? bodyText(topicsC[0]) : "";
    check(topicsC.length === 1,
      "an authoritative copy after a seal is one topic, saw " + topicsC.length);
    check(textC.indexOf("continued to its end.") >= 0,
      "the authoritative tail must survive, saw: " + JSON.stringify(textC));

    // The screenshot is read from here: the pane above shows what the operator saw fixed.
    caption("one round, its prose, then the node's authoritative copy - one topic, full text");
  } catch (error) {
    problems.push("probe threw: " + (error && error.message ? error.message : String(error)));
  }
  var out = document.createElement("pre");
  out.id = "wa-probe";
  out.setAttribute("data-status", problems.length ? "fail" : "pass");
  out.textContent = problems.length
    ? "THINKING-IDENTITY FAIL: " + problems.join(" ;; ")
    : "THINKING-IDENTITY PASS: one round's thought is one topic (sealed-then-authoritative, " +
      "replayed halves and a longer authoritative tail all render once, whole)";
  (document.getElementById("panel") || document.body).append(out);
})();
