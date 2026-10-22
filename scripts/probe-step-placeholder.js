// Focused probe: A STEP THAT HAS BEGUN IS PREPAINTED, AND ITS OWN TOPIC TAKES THAT PLACE.
//
// The vacuum this pins (operator, 2026-10-2x): when a run begins a new step the transcript shows
// NOTHING until that step's own topic arrives - the reasoning burst, the decision, the tool call, the
// commentary - so the reader watches a gap where the step is about to be. The operator asked for the
// gap filled with the shape of the coming step:
//
//   "right together a new step begins, we can go ahead and prepaint a topic named <reasoning_icon>
//    reasoning... <seconds_count> which we swap to the step topic seamlessly ... once the new step
//    topic arrives, we place in the place of the reasoning topic"
//
// So the checks below are about three things, and none of them is "a node exists":
//   1. the step is prepainted with the REASONING topic's shape - glyph, the label `reasoning…`, and a
//      LIVE seconds count - drawn where the step's real topic will be;
//   2. the real topic REPLACES it in place: same parent, same sibling index, and no second topic left
//      behind, for every kind of first topic (thinking, tool, decision);
//   3. the placeholder never survives the turn: a reply, an error and `done` remove it, and a settled
//      run with no step draws no empty run topic of its own.
//
// FAILS against the tree before the change (no placeholder is ever drawn), passes after it.
//
//   node scripts/agent-benchmark-ui-observe.mjs --out "$TEMP/ui-look-placeholder" \
//     --probe scripts/probe-step-placeholder.js
(async function () {
  var problems = [];
  function check(ok, label) { if (!ok) problems.push(label); }
  function tick() { return Promise.resolve(); }
  function indexIn(parent, node) {
    return parent && node ? Array.prototype.indexOf.call(parent.children, node) : -1;
  }
  function placeholdersIn(root) {
    return root.querySelectorAll("[data-step-placeholder='true']");
  }
  function textOf(node, selector) {
    var part = node ? node.querySelector(selector) : null;
    return part ? part.textContent : null;
  }
  // The two characters the shape is pinned to, written without string escapes: the reasoning glyph
  // (U+2733) and the ellipsis (U+2026) that makes the label say "not yet".
  var GLYPH = String.fromCharCode(0x2733);
  var ELLIPSIS = String.fromCharCode(0x2026);
  var LABEL = "reasoning" + ELLIPSIS;
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
      line.style.cssText = "margin:8px 0 2px;color:#8bbcff;";
      line.textContent = text;
      stage.append(line);
    }
    // One pane per scenario, each with its own renderer (the child-pane mechanism the app itself uses
    // for a subagent transcript), so one scenario's topics cannot be read as another's.
    function paneRun(kind, steps) {
      var pane = document.createElement("div");
      stage.append(pane);
      withChildRenderer(pane, { session_id: "probe-placeholder-" + kind, subagent_id: "probe",
        state: "running", settled: false }, function () {
        for (var i = 0; i < steps.length; i++) steps[i](pane);
      });
      return pane;
    }

    // ---- A. a step has begun and said nothing yet: the shape of the coming topic ------------------
    // This pane is left in that state on purpose: the screenshot is read from it.
    caption("A: `round` and nothing else yet - the step is prepainted (live seconds count)");
    paneRun("round-only", [function (pane) {
      handleEvent({ type: "round", n: 1, tools: 2 });
      var found = placeholdersIn(pane);
      check(found.length === 1,
        "a step that has begun but said nothing yet draws exactly one placeholder, saw " + found.length);
      var node = found[0] || null;
      check(!!node && node.tagName === "WA-REASONING",
        "the placeholder has the reasoning topic's shape, saw " + (node ? node.tagName : "none"));
      check(textOf(node, ".trace-glyph") === GLYPH,
        "the placeholder carries the reasoning glyph, saw " + JSON.stringify(textOf(node, ".trace-glyph")));
      check(textOf(node, ".trace-label") === LABEL,
        "the placeholder is labelled " + LABEL + ", saw " + JSON.stringify(textOf(node, ".trace-label")));
      var meta = textOf(node, ".trace-meta");
      check(!!meta && /^[0-9]+s$/.test(meta),
        "the placeholder shows a seconds count, saw " + JSON.stringify(meta));
      // The count is LIVE, not the 0s it was drawn with: move the clock the node records back five
      // seconds and let the app's own painter say the age.
      if (node) {
        node.dataset.stepStartedAt = String(Date.now() - 5000);
        paintStepAge(node);
      }
      check(textOf(node, ".trace-meta") === "5s",
        "the seconds count is live, saw " + JSON.stringify(textOf(node, ".trace-meta")) + " after 5s");
      check(!pane.querySelector(".topic-body:not([hidden])") ||
        !node || node.open === false, "the placeholder is a topic shape with no empty body");
    }]);
    // The same step announcing itself twice - `round`, then the `model` status note - is ONE shape, and
    // the count it already had is not restarted.
    paneRun("round-then-status", [function (pane) {
      handleEvent({ type: "round", n: 1, tools: 2 });
      var first = placeholdersIn(pane)[0] || null;
      var startedAt = first ? first.dataset.stepStartedAt : null;
      handleEvent({ type: "status", text: "model" });
      var after = placeholdersIn(pane);
      check(after.length === 1,
        "a second announcement of the same step is one placeholder, saw " + after.length);
      check(!!first && after[0] === first && first.dataset.stepStartedAt === startedAt,
        "the step already announced keeps its placeholder and its own clock");
    }]);

    // ---- B. the step is a THOUGHT: the thinking topic takes the placeholder's own place -------------
    caption("B: `reasoning` arrives - the thinking topic stands where the shape was");
    paneRun("round-then-reasoning", [function (pane) {
      handleEvent({ type: "round", n: 1, tools: 2 });
      var node = placeholdersIn(pane)[0] || null;
      check(!!node, "the thinking case starts from a placeholder");
      var parent = node ? node.parentNode : null;
      var index = indexIn(parent, node);
      handleEvent({ type: "reasoning", text: "Reading the ledger row.", chars: 23 });
      check(placeholdersIn(pane).length === 0,
        "the thinking topic consumes the placeholder, saw " + placeholdersIn(pane).length + " left");
      var topic = pane.querySelector("wa-reasoning:not([data-step-placeholder='true'])");
      check(!!topic, "the thinking topic exists");
      check(!!topic && topic.parentNode === parent && indexIn(topic.parentNode, topic) === index,
        "the thinking topic stands in the placeholder's place - same parent and index " + index +
        ", saw parent " + (topic ? (topic.parentNode === parent ? "same" : "different") : "-") +
        " index " + indexIn(topic ? topic.parentNode : null, topic));
      check(pane.querySelectorAll("wa-message wa-reasoning").length === 1,
        "one step leaves one topic, saw " + pane.querySelectorAll("wa-message wa-reasoning").length);
    }]);

    // ---- C. the step is a TOOL CALL: the tool topic takes that place ---------------------------------
    caption("C: `tool` arrives - the tool topic stands where the shape was, with the call in it");
    paneRun("round-then-tool", [function (pane) {
      handleEvent({ type: "round", n: 1, tools: 2 });
      var node = placeholdersIn(pane)[0] || null;
      check(!!node, "the tool case starts from a placeholder");
      var parent = node ? node.parentNode : null;
      var index = indexIn(parent, node);
      handleEvent({ type: "tool", call_id: "probe-call-1", name: "bash", arguments: { command: "ls" } });
      check(placeholdersIn(pane).length === 0,
        "the tool topic consumes the placeholder, saw " + placeholdersIn(pane).length + " left");
      var topic = pane.querySelector("wa-trace");
      check(!!topic && topic.parentNode === parent && indexIn(topic.parentNode, topic) === index,
        "the tool topic stands in the placeholder's place - same parent and index " + index +
        ", saw index " + indexIn(topic ? topic.parentNode : null, topic));
      check(!!topic && topic.count === 1, "the tool topic holds the call it was drawn for");
    }]);

    // ---- D. the step is a DECISION: its topic takes that place ---------------------------------------
    caption("D: `decision` arrives - the decision's topic stands where the shape was");
    paneRun("round-then-decision", [function (pane) {
      handleEvent({ type: "round", n: 1, tools: 2 });
      var node = placeholdersIn(pane)[0] || null;
      check(!!node, "the decision case starts from a placeholder");
      var parent = node ? node.parentNode : null;
      var index = indexIn(parent, node);
      handleEvent({ type: "decision", call_id: "probe-call-2", name: "bash",
        arguments_text: "{\"command\":\"pwd\"}", complete: true });
      check(placeholdersIn(pane).length === 0,
        "the decision's topic consumes the placeholder, saw " + placeholdersIn(pane).length + " left");
      var topic = pane.querySelector("wa-trace");
      check(!!topic && topic.parentNode === parent && indexIn(topic.parentNode, topic) === index,
        "the decision's topic stands in the placeholder's place - same parent and index " + index +
        ", saw index " + indexIn(topic ? topic.parentNode : null, topic));
    }]);

    // ---- E. the turn settles with no step topic: nothing of the shape survives ----------------------
    caption("E: `done` with no step - no placeholder, and no empty run topic invented for it");
    paneRun("round-then-done", [function (pane) {
      handleEvent({ type: "round", n: 1, tools: 2 });
      check(placeholdersIn(pane).length === 1, "the done case starts from a placeholder");
      handleEvent({ type: "done" });
      check(placeholdersIn(pane).length === 0,
        "done removes the placeholder, saw " + placeholdersIn(pane).length + " left");
      check(pane.querySelectorAll("wa-run").length === 0,
        "a step that drew no topic leaves no empty run topic, saw " + pane.querySelectorAll("wa-run").length);
    }]);
    paneRun("round-then-error", [function (pane) {
      handleEvent({ type: "round", n: 1, tools: 2 });
      handleEvent({ type: "error", error: "provider refused" });
      check(placeholdersIn(pane).length === 0,
        "an error removes the placeholder, saw " + placeholdersIn(pane).length + " left");
    }]);
    paneRun("round-then-reply", [function (pane) {
      handleEvent({ type: "round", n: 1, tools: 2 });
      handleEvent({ type: "reply", text: "Straight to the answer.", message_id: "probe-msg-1" });
      check(placeholdersIn(pane).length === 0,
        "a reply with no step of its own removes the placeholder, saw " + placeholdersIn(pane).length + " left");
    }]);

    caption("the shape at the top of this pane is the vacuum filled: it becomes the step's own topic");
  } catch (error) {
    problems.push("probe threw: " + (error && error.message ? error.message : String(error)));
  }
  var out = document.createElement("pre");
  out.id = "wa-probe";
  out.setAttribute("data-status", problems.length ? "fail" : "pass");
  out.textContent = problems.length
    ? "STEP-PLACEHOLDER FAIL: " + problems.join(" ;; ")
    : "STEP-PLACEHOLDER PASS: a begun step is prepainted with the reasoning shape and a live seconds " +
      "count, and its own topic (thinking, tool or decision) replaces it in place - same parent, same " +
      "index, one topic - while a reply, an error and done remove it";
  (document.getElementById("panel") || document.body).append(out);
})();
