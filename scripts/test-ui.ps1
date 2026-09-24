# Structural test for the chat UI.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-ui.ps1
#
# Why this exists: an agent asked to change the UI has no way to see it. bash and
# grep cannot tell it whether a reply bubble contains its tool topics or whether
# they were pushed outside it, so it makes a plausible change and reports success.
# This gives it an observation channel - replay a synthetic turn in a real browser
# and assert the structure that was actually asked for.
param(
  [int]$Port = 8899,
  [int]$ClientPort = 8801,
  [string]$WaExe = (Join-Path $env:LOCALAPPDATA "wasm-agent\wa.exe")
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$ui = Join-Path $root "ui"
if (-not (Test-Path (Join-Path $ui "index.html"))) { Write-Host "  !  no ui/ in $root"; exit 1 }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("wa-ui-test-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$db = Join-Path $tmp "ui-test.db"
foreach ($name in @("index.html", "style.css", "app.js", "components.js", "render.wasm")) {
  $from = Join-Path $ui $name
  if (Test-Path $from) { Copy-Item $from (Join-Path $tmp $name) }
}

# The harness runs synchronously after app.js (no timers: headless virtual time
# does not reliably advance) and reports one machine-checkable line.
$harness = @'
<script>
(async function () {
  document.title = "stage: start";
  var problems = [];
  try {
  var tick = function () { return Promise.resolve(); };
  function check(ok, label) { if (!ok) problems.push(label); }
  if (sessionStorage.getItem("wa-ui-reload-stage") === "active") {
    // This is a real second navigation, not a second call to restoreSession in the old page.
    // The fixture was installed before app.js loaded, just as a live /session response is.
    sessionStorage.removeItem("wa-ui-reload-stage");
    var loadedAt = performance.now();
    await window.rendererLoaded;
    for (var retry = 0; retry < 200 && !document.getElementById("messages").textContent.includes("RELOAD-MID-RUN-QUESTION"); retry++) await tick();
    var restored = document.getElementById("messages");
    check(restored.textContent.includes("RELOAD-MID-RUN-QUESTION"),
      "a real reload during a turn must restore the transcript on boot");
    check(performance.now() - loadedAt < 3000,
      "the running-turn transcript should restore promptly, not wait for the turn to finish");
    check(!!restored.querySelector(".unfinished-notice") && /A run is in progress/.test(restored.textContent),
      "a reload during a turn must say the ledger is pending and the node is active");
    var stalePending = restored.querySelectorAll("wa-trace .pending").length;
    check(stalePending === 0 && !window.__toolTickerActive(),
      "a repainted tool must not invent a new 300-second execution clock, saw " + stalePending +
      " pending line(s) and ticker=" + window.__toolTickerActive());
    var unrecordedCount = restored.querySelectorAll("wa-trace .tool-line.unrecorded").length;
    check(unrecordedCount === 2,
      "a real reload must close historical as well as current missing tool calls, saw " + unrecordedCount);
    var restoredReasoning = restored.querySelector(".reasoning");
    check(!!restoredReasoning && restoredReasoning.textContent.indexOf("EARLIER-REASONING") >= 0,
      "a reload must repaint the stored thinking, saw: " +
      (restoredReasoning ? restoredReasoning.textContent : "nothing"));
    check(!!restoredReasoning && restoredReasoning.open === false,
      "and the repainted thinking must be folded away, not flooding the transcript");
    check(!restored.querySelector(".unfinished-notice button"),
      "an active turn must not offer a duplicate continuation");
    check(!window.__calls.some(function (call) { return call.url === "chat" && call.method === "POST"; }),
      "a page reload must never post another turn");
    // The reload redraws the transcript from stored rows, and a repainted run must still show its
    // footer - the same information the live stream produced. A replay emits no `done`, so this is
    // the path where no status line was ever created and finishRunStatus returned early.
    var repaintedBubbles = restored.querySelectorAll("wa-message.assistant");
    var repaintedBubble = repaintedBubbles[repaintedBubbles.length - 1];
    var repaintedKids = repaintedBubble ? repaintedBubble.body.children : [];
    var repaintedLast = repaintedKids[repaintedKids.length - 1];
    check(!!repaintedLast && repaintedLast.classList.contains("chat-content-run-status"),
      "a repainted bubble must show its run's footer, saw: "
      + (repaintedLast ? repaintedLast.tagName + "." + (repaintedLast.className || "") : "nothing"));

    // The stream belongs to the old page, so the new page must notice the worker become idle
    // and repaint the answer from the durable ledger, not open the engine's session view.
    window.__fixtures.session.state = { state: "answered", detail: "the last message is a reply" };
    // `messages`, not `turns`: the wire key was renamed (10326b4 renamed it in the fixtures and in
    // app.js, which reads payload.messages) and this stage was left pushing into a field nothing
    // defines. A stage that throws asserted nothing - and reported itself as `FAIL the harness threw`
    // for every later run, which is how a dead assertion hides.
    window.__fixtures.session.messages.push(
      { seq: 5, role: "tool", tool_name: "bash", content: "done", tool_calls: [] },
      { seq: 6, role: "assistant", content: "RELOAD-MID-RUN-ANSWER", tool_calls: [] });
    window.__fixtures.health.current = null;
    window.__fixtures.health.workers = [];
    await window.__watchTurn();
    for (var settled = 0; settled < 100; settled++) await tick();
    check(restored.textContent.includes("RELOAD-MID-RUN-ANSWER"),
      "when the turn ends, the reloaded chat must show the ledger's answer");
    check(!restored.querySelector(".unfinished-notice") && !restored.querySelector("wa-trace .pending"),
      "the pending notice and tool state must disappear after settlement");
    check(!document.getElementById("sessions-box").textContent.includes("RELOAD-MID-RUN-ANSWER"),
      "the answer belongs in chat, not in a switched engine view");
    var reloadLog = document.createElement("pre");
    reloadLog.id = "harness-log";
    reloadLog.textContent = problems.length ? ("UI FAIL: " + problems.join(" ;; ")) : "UI PASS (real mid-run reload)";
    document.body.append(reloadLog);
    return;
  }
  // Managed jobs are rules, after tools, and never optimistically reported enabled.
  check(document.querySelector('[data-target="tools-box"]').closest('.engine-topic').nextElementSibling.querySelector('[data-target="jobs-box"]'), 'jobs must follow tools in the engine');
  await refreshJobs();
  var jobPanel = document.querySelector('wa-jobs');
  check(!!jobPanel && !jobPanel.querySelector('img'), 'job text must not execute as HTML');
  var jobToggle = jobPanel.querySelector('input');
  check(!jobToggle.checked, 'new jobs show disabled');
  jobToggle.click();
  check(jobToggle.disabled && !jobToggle.checked, 'job toggle waits for durable confirmation');
  for (var jtick=0;jtick<30;jtick++) await tick();
  check(document.querySelector('wa-jobs input').checked, 'accepted enable is displayed');
  window.__fixtures.jobsRefuse = true;
  document.querySelector('wa-jobs input').click();
  for (var jtick=0;jtick<30;jtick++) await tick();
  check(document.querySelector('wa-jobs input').checked && document.getElementById('jobs-box').textContent.includes('fixture_job_refused'), 'a refused toggle preserves state and reports failure');
  window.__fixtures.jobsRefuse = false;
  document.querySelector('wa-jobs input').click();
  for (var jtick=0;jtick<30;jtick++) await tick();
  check(!document.querySelector('wa-jobs input').checked, 'accepted disable is displayed');
  var events = [
    { type: "round", n: 1 },
    { type: "delta", text: "Reading the config module to see what it names." },
    { type: "tool", name: "read", arguments: { path: "lua/core/paths.lua", offset: 1, limit: 40 } },
    { type: "tool_result", result: { path: "lua/core/paths.lua", content: "a b c" } },
    { type: "round", n: 2 },
    { type: "delta", text: "It names CONFIG_FILE; checking whether it exists." },
    { type: "tool", name: "bash", arguments: { command: "if exist env echo present" } },
    { type: "tool_result", result: { code: 1, stderr: "MISSING" } },
    { type: "round", n: 3 },
    { type: "delta", text: "Final: it exists." },
    // A turn that changed files, so the diff topic is exercised: without `changes` the topic
    // never renders and every assertion about it would pass vacuously.
    { type: "reply", text: "Final: it exists.", message_id: "message-fixture-1", changes: {
      added: 7, removed: 2, files: [
        { path: "lua/core/paths.lua", added: 5, removed: 2, created: false, recorded: true },
        { path: "scripts/probe.lua", added: 2, removed: 0, created: true, recorded: true }
      ] } },
    { type: "done" }
  ];
  // LIVE CHECK: while a decision is running its tool lines must be visible, not
  // folded behind a count - pi shows them as they happen, and that is the whole
  // point of a decision trace.
  var upto = 4;   // through the first tool result
  for (var i = 0; i < upto; i++) window.handleEvent(events[i]);
  var live = document.querySelector('wa-trace');
  check(!!live, 'a running decision must have a trace');
  check(!!live && live.hasAttribute('open'), 'a running trace must be open so its tool lines are visible');
  // A running tool line shows what the operation behind it is doing. The node already publishes
  // the operation on /health and its output through /operation; a window that shows only a clock
  // makes a five-minute build look like a hang - the failure this exists to prevent.
  window.handleEvent(events[4]);   // round
  window.handleEvent(events[5]);   // delta before the bash call
  window.handleEvent(events[6]);   // bash, still pending
  window.__fixtures.operation = { content: "compiling wa-host\nlinking wa\n", offset: 0, next_offset: 34, bytes: 34, eof: true };
  await window.__refreshOperationProgress(
    { operations: [{ operation_id: "op-fixture", owner: "run:3", state: "running", output_bytes: 34 }] },
    { run_id: 3 },
  );
  var progress = document.querySelector("wa-trace .tool-progress:not([hidden])");
  check(!!progress && progress.textContent === "running · 34 B · linking wa",
    "a running tool must show the operation's state, bytes and newest output line, saw: " + (progress && progress.textContent));
  // A silent command must still say something: the line is a liveness signal, not just a tail.
  await window.__refreshOperationProgress(
    { operations: [{ operation_id: "op-quiet", owner: "run:3", state: "running", output_bytes: 0 }] },
    { run_id: 3 },
  );
  var quiet = document.querySelector("wa-trace .tool-progress:not([hidden])");
  check(!!quiet && quiet.textContent === "running · 0 B",
    "a silent running tool must still show its state and byte count, saw: " + (quiet && quiet.textContent));
  for (var i = 7; i < events.length; i++) window.handleEvent(events[i]);
  check(!document.querySelector("wa-trace .tool-progress:not([hidden])"),
    "the settled result must clear the running progress line");

  var messages = document.getElementById("messages");
  var bubbles = messages.querySelectorAll("wa-message.assistant");
  check(bubbles.length === 1, "expected one assistant bubble, saw " + bubbles.length);

  var bubble = bubbles[0];
  var body = bubble ? bubble.querySelector(".body") : null;
  check(!!body && body.classList.contains("steps"), "the bubble body should be a steps container");

  // Once the answer is ready the whole path collapses into one run topic, which
  // sits above the answer so the reader lands on the answer - and the diff topic sits
  // *below* it, as a sibling of the answer rather than inside the run.
  var shape = body ? Array.prototype.map.call(body.children, function (c) {
    if (c.classList.contains("chat-content-run-status")) return "status";
    return c.tagName === "WA-RUN" ? "run" : (c.tagName === "WA-TRACE" ? "trace"
      : (c.tagName === "WA-DIFF" ? "diff" : "text"));
  }).filter(function (item) { return item !== "status"; }).join(",") : "";
  check(shape === "run,text,diff",
    "expected run,text,diff in the bubble after the reply, saw " + shape);

  // The diff must be a *sibling*, not a descendant of the run topic: it used to be appended
  // before collapseRun(), which sweeps every non-answer child into the run - so the reader
  // had to open the turn's path to find out which files changed.
  var runTopic = body ? body.querySelector("wa-run") : null;
  check(!!runTopic && !runTopic.querySelector("wa-diff"),
    "the diff topic must not be inside the run topic");
  var diffTopic = body ? body.querySelector(":scope > wa-diff") : null;
  check(!!diffTopic, "the diff topic should be a direct child of the bubble body");

  // ...and after the answer, not before it.
  var kids = body ? Array.prototype.slice.call(body.children) : [];
  var answerIndex = kids.findIndex(function (c) { return c.classList && c.classList.contains("seg"); });
  var diffIndex = kids.findIndex(function (c) { return c.tagName === "WA-DIFF"; });
  check(diffIndex > answerIndex && answerIndex >= 0,
    "the diff topic must come after the answer (answer at " + answerIndex + ", diff at " + diffIndex + ")");

  // The header is the real topic header - the same button, the same parts, in the same order
  // as <wa-run> - so the diff reads as a topic rather than as its own kind of thing.
  var diffHead = diffTopic ? diffTopic.querySelector(".trace-head") : null;
  check(!!diffHead && diffHead.tagName === "BUTTON",
    "the diff header should be the shared trace-head button, saw " + (diffHead && diffHead.tagName));
  var headParts = diffHead ? Array.prototype.map.call(diffHead.children, function (c) {
    return c.className;
  }).join(",") : "";
  check(headParts === "trace-glyph,trace-label,trace-meta,trace-chevron",
    "the diff header should hold glyph,label,meta,chevron like the run topic, saw: " + headParts);

  // Same collapse behaviour as the other topics: closed to start, chevron flipped when open.
  check(diffTopic && !diffTopic.hasAttribute("open"), "the diff topic should start collapsed");
  if (diffTopic) {
    var closedChevron = diffTopic.querySelector(".trace-chevron").textContent;
    diffTopic.toggle();
    check(diffTopic.hasAttribute("open"), "clicking the diff header should open the topic");
    check(diffTopic.querySelector(".trace-chevron").textContent !== closedChevron,
      "the diff chevron should flip when the topic opens");
    check(diffTopic.querySelector(".diff-body").hidden === false,
      "the diff body should be visible when the topic is open");
    var headText = diffHead.textContent;
    check(headText.indexOf("2 files changed") >= 0,
      "the diff topic should total its files, saw: " + headText);
    check(headText.indexOf("+7") >= 0 && headText.indexOf("\u22122") >= 0,
      "the diff topic should show +added and -removed, saw: " + headText);
    // The toggle is the diff's own addition: one button, at the right edge, sibling of the
    // header (a button inside a button is invalid and swallows its own clicks).
    var toggle = diffTopic.querySelector(".diff-toggle");
    check(!!toggle, "the diff topic should carry the undo/redo toggle");
    check(!!toggle && toggle.parentElement === diffHead.parentElement,
      "the toggle must be a sibling of the header, not inside it");

    // A changed file is a control. Clicking it asks the node for that file's patch and shows it in a
    // balloon, because the turn carries addresses and not bodies - so the click is what turns an
    // address back into something readable. It used to be a line that did nothing on hover, which
    // reads as a control and is not one.
    // A path must be readable, not elided: this topic is opened to find out *which* file changed, and
    // "C:/Users/Victor/orca/workspa…" is not an answer. Found on the node's branch, which was fixing the
    // same topic at the same time - the fix is CSS, the check belongs here.
    var pathCell = diffTopic.querySelector(".diff-path");
    check(!!pathCell, "each file row must carry its path");
    check(!!pathCell && getComputedStyle(pathCell).textOverflow !== "ellipsis",
      "the path must not be elided, saw text-overflow: "
      + (pathCell ? getComputedStyle(pathCell).textOverflow : "no cell"));
    check(!!pathCell && getComputedStyle(pathCell).whiteSpace === "nowrap",
      "the path must stay on one line so the row scrolls instead of wrapping");

    // "I do not know yet" is not a verdict, and must not be a trap. The first version rendered pending
    // through the refusal path, which sets `locked` - and the real answer then hit `if (locked) return`
    // and was thrown away, so an undoable change stayed disabled for good. The node's branch found that
    // while I was building the click preview, from the other side of the same code.
    var probe = document.createElement("wa-diff");
    probe.setSummary({ added: 1, removed: 1, files: [{ path: "x.txt", added: 1, removed: 1 }] });
    document.body.append(probe);
    probe.setPending();
    check(probe.querySelector(".diff-toggle").disabled === true,
      "a pending topic must not offer the action before the answer");
    var pendingNote = probe.querySelector(".diff-note");
    check(!pendingNote || pendingNote.textContent === "",
      "and must not dress a question up as a failure, saw: " + (pendingNote ? pendingNote.textContent : "nothing"));
    probe.setUndoable(true, "");
    check(probe.querySelector(".diff-toggle").disabled === false,
      "the answer that follows a pending state must be taken");
    probe.setUndoable(false, "the file moved on");
    check(probe.querySelector(".diff-toggle").disabled === true, "a refusal disables it");
    probe.setUndoable(true, "");
    check(probe.querySelector(".diff-toggle").disabled === true,
      "and a refusal is not reopened by a later answer - that is what locked is for");
    probe.remove();

    var fileRow = diffTopic.querySelector(".diff-file");
    check(!!fileRow && fileRow.tagName === "BUTTON",
      "a changed file must be a control, saw " + (fileRow && fileRow.tagName));
    if (fileRow) {
      fileRow.click();
      for (var ux = 0; ux < 40; ux++) { await tick(); }
      var patchBalloon = document.querySelector("wa-balloon.file-diff");
      check(!!patchBalloon, "clicking a changed file must open its patch in a balloon");
      var patchText = patchBalloon ? patchBalloon.textContent : "";
      check(patchText.indexOf("@@") >= 0 && patchText.indexOf("+new line") >= 0,
        "and the balloon must show the patch, saw: " + patchText.slice(0, 70));
      check(!!patchBalloon && patchBalloon.hasAttribute("open"), "and be open");

      // The window path: the same patch, in a real native window. Both containers are kept on purpose -
      // the balloon is instant and closes on a press outside, the window is resizable, movable, snapable
      // and survives the chat being collapsed - so the UI must be able to ask for either, and must say
      // which one it chose. This is the half of the feature a page-only test can still prove.
      window.__shellCalls.length = 0;
      window.__setShell(window.__makeShell());
      var shellCalls = window.__shellCalls;
      var callsBefore = shellCalls.length;
      var toWindow = patchBalloon ? patchBalloon.querySelector(".pop-head-action") : null;
      check(!!toWindow, "the patch balloon must offer its window form");
      if (toWindow) {
        toWindow.click();
        for (var uz = 0; uz < 20; uz++) { await tick(); }
        var opened = shellCalls.slice(callsBefore).filter(function (c) { return c.call === "openView"; });
        check(opened.length === 1, "clicking it must ask the shell for a window, saw " + opened.length);
        var url = opened.length === 1 ? opened[0].url : "";
        check(/[?&]view=patch/.test(url), "and the window must be the patch view, saw: " + url);
        check(/[?&]path=/.test(url) && /[?&]message=/.test(url),
          "carrying the message and the file it is about, saw: " + url);
        check(!document.querySelector("wa-balloon.file-diff"),
          "and the balloon must hand over to it rather than linger");
        window.__setShell(null);
      }

      // A balloon is a balloon: it owns the close rule, and the same control closes it again.
      fileRow.click();
      for (var uw = 0; uw < 20; uw++) { await tick(); }
      check(!!document.querySelector("wa-balloon.file-diff"), "clicking the file again reopens the balloon");
      fileRow.click();
      for (var uy = 0; uy < 20; uy++) { await tick(); }
      check(!document.querySelector("wa-balloon.file-diff"),
        "clicking the same changed file again must close the balloon");
    }
    diffTopic.toggle();
  }

  var run = body ? body.querySelector("wa-run") : null;
  check(!!run, "the collapsed run topic should exist");
  check(!!run && !run.hasAttribute("open"), "the run topic should start collapsed");

  var runBody = run ? run.querySelector(".run-body") : null;
  // One click on the run should show the sequence: the tools inside stay open.
  var innerTraces = runBody ? runBody.querySelectorAll('wa-trace') : [];
  for (var t2 = 0; t2 < innerTraces.length; t2++) {
    check(innerTraces[t2].hasAttribute('open'), 'tools inside a finished run should be visible in one click');
  }
  var inner = runBody ? Array.prototype.map.call(runBody.children, function (c) {
    return c.tagName === "WA-TRACE" ? "trace" : "text";
  }).join(",") : "";
  check(inner === "text,trace,text,trace", "expected text,trace,text,trace inside the run, saw " + inner);

  var runMeta = run ? run.querySelector(".trace-meta") : null;
  var runText = runMeta ? runMeta.textContent : "";
  check(runText.indexOf("2 tool calls") >= 0, "the run topic should total its tool calls, saw: " + runText);
  check(runText.indexOf("2 steps") >= 0, "the run topic should count its steps, saw: " + runText);

  // Tool topics belong to the reply, not to the transcript.
  check(messages.querySelectorAll(":scope > wa-trace").length === 0,
        "tool topics must not be children of the transcript container");

  var traces = runBody ? runBody.querySelectorAll("wa-trace") : [];
  check(traces.length === 2, "expected two tool topics, saw " + traces.length);
  if (traces.length) {
    var head = traces[0].querySelector(".trace-head");
    var headText = head ? head.textContent : "";
    check(headText.indexOf("read") >= 0, "the first topic should name the read tool, saw: " + headText);
    check(headText.indexOf("1 tool call") >= 0, "the first topic should count its calls, saw: " + headText);
  }
  // A failure must be visible without the reader expanding anything.
  if (traces.length > 1) {
    check(traces[1].hasAttribute("open"), "a failing tool call must open its topic");
    check(traces[1].classList.contains("has-error"), "a failing tool call must mark its topic");
  }

  // A pile of pasted screenshots must not push the composer off the screen. The strip
  // caps its height and scrolls; the message box stays visible under it, and the last
  // chip is reachable without the layout growing.
  window.__attachMany(24);
  var strip = document.getElementById("attachments");
  var composer = document.getElementById("composer");
  check(strip.children.length === 24, "24 attachments must render 24 chips, saw " + strip.children.length);
  check(strip.clientHeight <= 151, "the strip must cap its height at ~150px, saw " + strip.clientHeight + "px");
  check(strip.scrollHeight > strip.clientHeight + 40,
    "and the overflow must be scrollable, saw scrollHeight " + strip.scrollHeight + " vs " + strip.clientHeight);
  check(Math.abs(strip.clientHeight - 150) <= 1,
    "the cap must be 150px (2.5 cards), saw " + strip.clientHeight + "px");
  strip.scrollTop = strip.scrollHeight;
  var lastChip = strip.children[strip.children.length - 1];
  // Geometric, not offsetTop: the strip is not a positioned ancestor, so offsetTop is
  // measured against something else entirely and the first version of this passed/failed
  // for the wrong reason.
  check(lastChip.getBoundingClientRect().bottom <= strip.getBoundingClientRect().bottom + 1,
    "scrolling to the end must reach the last chip");
  check(strip.scrollTop > 0, "the strip must actually have scrolled, saw scrollTop " + strip.scrollTop);
  var inputBox = document.getElementById("input").getBoundingClientRect();
  check(inputBox.bottom <= window.innerHeight,
    "the message box must stay on screen, its bottom is at " + Math.round(inputBox.bottom) + " of " + window.innerHeight);
  check(composer.clientHeight < window.innerHeight,
    "the composer must not outgrow the window, saw " + composer.clientHeight + "px");
  window.__attachMany(0);
  check(document.getElementById("attachments").children.length === 0, "clearing must empty the strip");

  // A UI update must not break a turn. Styling changes apply live; markup/JS changes wait
  // for the running turn and then land on their own. The reload is a spy here because a
  // real one would take the page with it.
  var reloads = 0;
  window.__setReload(() => { reloads += 1; });
  // The page has already polled /version once (the fixture answers it), so start from
  // whatever the app believes and move relative to it - not from an invented "v1".
  var live = window.__uiVersion();
  check(typeof live === "string" && live.length > 0, "the page must have a version by now, saw " + live);
  check(window.__applyUiVersion(live) === "same", "an unchanged version must do nothing");
  check(reloads === 0, "an unchanged version must not reload, saw " + reloads);
  check(window.__applyUiVersion(live + "-next") === "reloading", "a change while idle must reload");
  check(reloads === 1, "exactly one reload while idle, saw " + reloads);
  window.__setBusy(true);
  window.handleEvent({ type: "round", n: 1 });
  window.handleEvent({ type: "delta", text: "a turn is running" });
  check(window.__applyUiVersion(live + "-third") === "deferred",
    "a change during a turn must be deferred, not applied under it");
  check(reloads === 1, "a deferred change must not reload yet, saw " + reloads);
  var updateNotes = document.querySelectorAll(".chat-content-run-status:not(.finished)");
  var updateNote = updateNotes[updateNotes.length - 1];
  check(!!updateNote && /update ready/.test(updateNote.textContent),
    "and it must say so, saw: " + (updateNote ? updateNote.textContent : "no status"));
  window.__setBusy(false);
  check(reloads === 2, "the deferred reload must land when the turn ends, saw " + reloads);
  window.handleEvent({ type: "reply", text: "done" });
  window.handleEvent({ type: "done" });
  window.__setBusy(false);

  // The context panel states what it knows in one line. The fixture has a budget
  // and no usage, so this is the "0 / budget" case, and the percentage must be
  // computed rather than printed as a placeholder.
  // The panel lives in a popover, so the harness draws it through the same
  // function the popover calls rather than reaching for the DOM it would build.
  // Metatada is fetched after the renderer loads (app.js chains them), so wait for
  // that first and then let the fixture's microtasks settle. Asserting earlier only
  // ever tests the no-budget branch, which is how this check first passed wrongly.
  if (window.rendererLoaded) { await window.rendererLoaded; }
  for (var c = 0; c < 20; c++) { await tick(); }
  window.renderContext();
  var contextText = document.getElementById("context-box").textContent;
  check(/last measured input/.test(contextText) && /128/.test(contextText),
    "context must show measured last request and selected capacity, saw: " + contextText);
  window.renderUsage(); window.renderModels();
  var diagnostics=document.getElementById('harness-status');
  check(diagnostics.querySelectorAll('details').length===4,'harness diagnostics have four progressively disclosed categories');
  check(/different configuration/.test(diagnostics.textContent),'model drift must be disclosed');
  check(/not verified task success/.test(diagnostics.textContent),'answered turns are not a quality score');
  check(/unknown \/ unpriced/.test(document.getElementById('usage-box').textContent),'missing pricing must not become zero dollars');
  check(/620/.test(diagnostics.textContent),'unsummarized coverage is visible');
  check(/request tool-result bytes/.test(diagnostics.textContent) && /JSON bytes, not tokens/.test(diagnostics.textContent),
    'prompt composition distinguishes exact bytes from token usage');
  var diagnosticDetails=diagnostics.querySelector('details'); diagnosticDetails.open=true;
  window.renderUsage();
  check(diagnostics.querySelector('details').open,'refresh preserves expanded diagnostic sections');
  var reasoningPicker=document.getElementById('reasoning-select');
  reasoningPicker.value='low'; reasoningPicker.dispatchEvent(new Event('change'));
  for(var c=0;c<20;c++) await tick();
  check(window.__calls.some(c=>c.url.indexOf('reasoning')>=0 && c.method==='POST' && c.body==='low'),'reasoning selection sends the selected level');
  check(/unsupported_reasoning_level/.test(document.getElementById('settings-error').textContent),'refused settings must be visible');
  diagnostics.querySelector('button').click();
  for(var c=0;c<20;c++) await tick();
  check(/Export failed/.test(document.getElementById('settings-error').textContent),'export failure must not claim a download');
  var emptyDiagnostic=document.createElement('wa-harness-status');
  emptyDiagnostic.data={observability:{available:false}};
  check(/Missing records do not mean zero/.test(emptyDiagnostic.textContent),'empty telemetry is unknown, not zero efficiency');

  // Markdown: a model answering with a table must get a table. Pipes are not
  // something a reader can reconstruct. The renderer arrives over the node's
  // static path, so this is real I/O: wait for it before dispatching the reply,
  // otherwise the reply is rendered by the escape-and-<br> fallback.
  if (window.rendererLoaded) { await window.rendererLoaded; }
  check(!!(window.rendererReady && window.rendererReady()),
    "the WASM markdown renderer must be loaded for this case: " + (window.__rendererError || "no error recorded"));
  window.handleEvent({
    type: "reply",
    text: "| tool | legacy | default |\n|---|--:|--:|\n| read | 4.0 | 3.0 |\n\n## Next\n\n- keep the payload\n- budget the context\n\n```\nnpm run build\n```\n\nRun `npm ci` first.",
  });
  window.handleEvent({ type: "done" });
  var all = messages.querySelectorAll("wa-message.assistant");
  var md = all[all.length - 1];
  var table = md ? md.querySelector(".md-table table") : null;
  check(!!table, "a markdown table in a reply must render as a table, saw: " +
    (md ? md.innerHTML.slice(0, 160) : "no bubble"));
  check(!!table && table.querySelectorAll("th").length === 3,
    "the table must have three header cells");
  check(!!table && table.querySelectorAll("tbody td").length === 3,
    "the table must have three body cells");
  check(!!md && !!md.querySelector("h2"), "a markdown heading must render as a heading");
  check(!!md && md.querySelectorAll("li").length === 2, "list items must render as list items");

  // A fenced block gets a copy button; inline code does not. The check must be
  // structural, because a button in the wrong place is a button that copies the wrong text.
  var copyButton = md ? md.querySelector(".code-wrap .copy-code") : null;
  check(!!copyButton, "a fenced block must carry a copy button inside its container");
  check(!!md && md.querySelectorAll(".copy-code").length === 1,
    "only the fenced block gets a copy button, saw " + (md ? md.querySelectorAll(".copy-code").length : -1));
  var inlineCode = md ? Array.prototype.filter.call(md.querySelectorAll("code"), function (el) { return !el.closest("pre"); }) : [];
  check(inlineCode.length === 1 && !inlineCode[0].closest(".code-wrap"),
    "inline code must not get a copy button");
  // The button copies the code TEXT, not its markup. Stub the clipboard so the
  // assertion does not depend on the headless browser granting clipboard access.
  try { Object.defineProperty(navigator, "clipboard", { configurable: true, value: {
    writeText: function (t) { window.__copied = t; return Promise.resolve(); } } }); } catch (e) {}
  window.__copied = null;
  if (copyButton) copyButton.click();
  for (var cb = 0; cb < 5; cb++) await tick();
  check(window.__copied === "npm run build",
    "the button must copy the fenced code text, got " + JSON.stringify(window.__copied));
  check(!!copyButton && copyButton.textContent === "Copied",
    "the click must be acknowledged, got " + (copyButton ? copyButton.textContent : "no button"));

  // A subagent's receipt must surface the child - profile, state and session - and link to its
  // transcript, not sit in the chat as an opaque JSON blob.
  window.handleEvent({ type: "tool", name: "subagent", arguments: { action: "start", profile: "explore" } });
  window.handleEvent({ type: "tool_result", name: "subagent", result: {
    profile: "explore", state: "completed", settled: true, session_id: "abcdef01-2345-6789-abcd-ef0123456789" } });
  for (var sc = 0; sc < 5; sc++) await tick();
  var sub = messages.querySelector(".subagent-card");
  check(!!sub, "a subagent result must render a child card");
  check(!!sub && /explore/.test(sub.textContent) && /abcdef01/.test(sub.textContent),
    "the card must name the profile and the child session, saw " + (sub ? sub.textContent : "no card"));
  check(!!sub && !!sub.querySelector("button"), "the child card must link to the child session");

  // A reasoning model thinks before it speaks, and a panel that shows nothing
  // during that time is indistinguishable from a hung one. The count is also the
  // number that explains where the output budget went when a turn ends with no
  // answer at all.
  window.handleEvent({ type: "reasoning", chars: 4096 });
  var reasoningStatuses = document.querySelectorAll(".chat-content-run-status:not(.finished)");
  var reasoningStatus = reasoningStatuses[reasoningStatuses.length - 1];
  check(!!reasoningStatus && /4096/.test(reasoningStatus.textContent),
    "reasoning must be visible while it happens, saw: " +
    (reasoningStatus ? reasoningStatus.textContent : "no status line"));

  // A run must not widen the transcript. Mid-run the bubble holds raw text and
  // the status line is at its longest, and an unbreakable token there pushed a
  // horizontal scrollbar onto the transcript that vanished with the answer.
  window.handleEvent({ type: "status",
    text: "recovering an unfinished thread: stopped after a tool result with no next decision" });
  // The status line is at its longest here, and it is the one element that exists
  // only during a run - which is why a scrollbar could come and go with it.
  var activeStatuses = document.querySelectorAll(".chat-content-run-status:not(.finished)");
  var statusLine = activeStatuses[activeStatuses.length - 1];
  check(!!statusLine, "a run must show its status line");
  var statusOverflow = messages.scrollWidth - messages.clientWidth;
  check(statusOverflow <= 1,
    "the status line must not widen the transcript (overflow " + statusOverflow + "px)");
  window.handleEvent({ type: "round", n: 1 });
  window.handleEvent({ type: "delta", text: "Reading " + "a".repeat(300) +
    "/C:/Users/Victor/orca/workspaces/wasm-agent/loggerhead/foundation/" + "b".repeat(160) + " now" });
  var overflow = messages.scrollWidth - messages.clientWidth;
  check(overflow <= 1,
    "a streaming delta must not widen the transcript (overflow " + overflow + "px)");
  var running = messages.querySelectorAll("wa-message.assistant");
  var runningBody = running.length ? running[running.length - 1].querySelector(".body.steps") : null;
  var runningText = runningBody ? runningBody.textContent : "";
  check(runningText.indexOf("Reading") >= 0,
    "a running decision must show its streaming text, saw: " + runningText.slice(0, 40));

  // The drift panel is a diff, not a transcript, and it is the one view that could
  // plausibly be given a write: pushing from here would make *looking* at another node's
  // ledger a mutation. So it is asserted twice - that it draws the drift it is given, and
  // that it has nothing to push with.
  document.getElementById("diff-btn").click();
  for (var d = 0; d < 20; d++) { await tick(); }
  var driftBody = document.getElementById("drift-body");
  var driftText = driftBody ? driftBody.textContent : "";
  check(driftBody && driftBody.children.length === 2,
    "the drift panel must show this node and its peers, saw " + (driftBody ? driftBody.children.length : "no panel"));
  check(/head/.test(driftText) && /42/.test(driftText), "it must state the local head, saw: " + driftText.slice(0, 120));
  check(/openclaw\.ohana/.test(driftText), "it must name where it is pushing, saw: " + driftText.slice(0, 120));
  check(/2 behind/.test(driftText), "a peer behind the head must say so");
  check(/3 ahead/.test(driftText), "a peer ahead of the head must say so");
  check(/level/.test(driftText), "a peer at the head must say level");
  var plusRows = driftBody ? driftBody.querySelectorAll(".drift-row.add").length : 0;
  check(plusRows === 2, "two pending entries must render two + rows, saw " + plusRows);
  check(!!driftBody && driftBody.querySelectorAll(".drift-row.del").length === 1,
    "the peer we are behind must render one - row");
  check(!!driftBody && driftBody.querySelectorAll(".drift-row.muted").length >= 1,
    "a level peer must render the muted = row");
  check(/cursor/.test(driftText), "each peer must show its cursor, so the count is auditable");
  var driftButtons = document.getElementById("drift").querySelectorAll("button");
  check(driftButtons.length <= 2, "the panel must have no action beyond refresh and close, saw " + driftButtons.length);
  var mutationWords = /push|send|upload|apply|sync now/i;
  var mutates = false;
  for (var b = 0; b < driftButtons.length; b += 1) {
    if (mutationWords.test(driftButtons[b].textContent + " " + (driftButtons[b].title || ""))) mutates = true;
  }
  check(!mutates, "nothing in the drift panel may push: looking at drift must not change it");
  document.getElementById("drift-close").click();


  document.title = "stage: node block done";
  // The engine view: open it, let the fixture fetch settle in microtasks, and
  // assert what a reader would see. Timers never fire in this mode, so the
  // wait is promise ticks only - which is also why the panel must render
  // synchronously after its fetch resolves.
  document.getElementById('engine-btn').click();
  // The session list is the node's front door: opening the engine lists this node's threads without
  // a second click, and clicking the topic reloads them the way a reader would.
  for (var eo = 0; eo < 200; eo++) {
    if (document.querySelectorAll('.session-row').length === 2) break;
    await tick();
  }
  check(document.querySelectorAll('.session-row').length === 2,
    'opening the engine must list this node\'s sessions, saw ' + document.querySelectorAll('.session-row').length);
  document.querySelector('[data-target="sessions-box"]').click();
  for (var t = 0; t < 20; t++) { await tick(); }
  var rows = document.querySelectorAll('.session-row');
  check(rows.length === 2, 'the engine sessions view should render both fixtures, saw ' + rows.length);
  var badge = document.querySelector('.session-state');
  check(!!badge, 'an unfinished thread must be badged');
  if (badge) {
    check(badge.textContent === 'unfinished', 'the badge should name the state, saw ' + badge.textContent);
    check((badge.title || '').indexOf('tool result') >= 0, 'the badge should carry the reason, saw ' + badge.title);
  }
  check(document.querySelectorAll('.session-state').length === 1,
    'only the thread that needs attention should be badged');
  // A thread the node is running must look live, and must not also read as unfinished: during a run
  // the ledger's last message is the prompt being answered, so "unfinished" would be true of the
  // ledger and false of the node. The badge comes from /health, which names the live conversation.
  window.__fixtures.health.runs = [{ conversation: "aaaaaaaa-0000-0000-0000-000000000001", pending: 1 }];
  window.__loadTopic('sessions-box');
  for (var lr = 0; lr < 200; lr++) {
    if (document.querySelector('.session-row.running .session-state.running')) break;
    await tick();
  }
  var liveBadge = document.querySelector('.session-row.running .session-state.running');
  check(!!liveBadge && /running/.test(liveBadge.textContent),
    'a session the node is running must show a running badge, saw ' + (liveBadge ? liveBadge.textContent : 'none'));
  check(document.querySelectorAll('.session-state').length === 1 &&
    !/unfinished/.test(document.querySelector('.session-state').textContent),
    'a running session must show running instead of unfinished');
  window.__fixtures.health.runs = [];
  window.__loadTopic('sessions-box');
  for (var rr = 0; rr < 200; rr++) {
    if (!document.querySelector('.session-row.running')) break;
    await tick();
  }
  // Detection is automatic; acting is one click. A node that resumes turns by itself would be
  // spending money on its own judgement, and the resume path deliberately only reports.
  var continuable = Array.prototype.filter.call(document.querySelectorAll(".session-row"),
    function (row) { return row.textContent.indexOf("continue") >= 0; });
  check(continuable.length === 1,
    "only the unfinished thread should offer to continue, saw " + continuable.length);

  // The update lock. A reload is invisible until it happens, and it used to happen at a moment the
  // reader did not choose, with no word about why - so it looked like the window flickering and
  // losing their place. The reload is replaced with a spy here: a real one would take the harness
  // with it.
  var reloads = 0;
  window.__setReload(function () { reloads += 1; });
  window.__setBusy(true);
  window.__applyUiVersion("version-after-a-patch");
  for (var ul = 0; ul < 5; ul++) { await tick(); }
  var lock = document.getElementById("update-lock");
  check(!!lock, "a deferred update must show the lock");
  check(!!lock && /UI updating/.test(lock.textContent), "and say what is happening");
  check(!!lock && /kept/.test(lock.textContent), "and that the reader's place and draft are kept");
  check(!!lock && !!lock.querySelector(".lock-now") && !!lock.querySelector(".lock-later"),
    "with both ways out: reload now, or keep working");
  check(reloads === 0, "and it must not reload while a turn is running");
  if (lock) {
    lock.querySelector(".lock-later").click();
    for (var uc = 0; uc < 3; uc++) { await tick(); }
    check(!document.getElementById("update-lock"), "dismissing it removes it");
  }
  window.__setBusy(false);
  for (var ud = 0; ud < 3; ud++) { await tick(); }
  check(reloads === 1, "and the reload lands the moment the turn finishes, saw " + reloads);

  // Where the reader was has to survive that reload: the scroll offset and whether they were
  // following the bottom. "Fresh" should not mean "moved".
  window.__setReload(function () { reloads += 1; });
  // The browser reports the scroll offset it actually accepted - a short transcript cannot scroll to
  // 123 - so the check compares what was remembered with what was observed, not with a number I
  // chose.
  messages.scrollTop = 123;
  var observedTop = messages.scrollTop;
  window.__rememberPlace();
  var place = null;
  try { place = JSON.parse(sessionStorage.getItem("wa-place") || "null"); } catch (error) { place = null; }
  check(!!place && place.top === observedTop,
    "the place must be remembered, saw " + JSON.stringify(place) + " for a scroll of " + observedTop);
  check(!!place && typeof place.following === "boolean", "including whether the reader was following");
  messages.scrollTop = 0;
  window.__restorePlace();
  for (var up = 0; up < 3; up++) { await tick(); }
  check(messages.scrollTop === observedTop, "and put back after a reload, saw " + messages.scrollTop);

  // A turn that was cut off must say so *in the chat*, where the answer would have been, and offer
  // to continue. A transcript that just stops looks like the agent had nothing to say - which is
  // exactly how a killed turn was read. The first fixture session is unfinished, so restoring it
  // must produce the notice.
  // The fixture is injected here rather than shipped in the defaults: the app restores its session at
  // load, so a `session` route present from the start repaints the transcript before the first check
  // runs - which is what happened, and it looked like a dozen unrelated failures.
  var fixtureNow = Math.floor(Date.now() / 1000);
  window.__fixtures.session = {
    session: { id: "aaaaaaaa-0000-0000-0000-000000000001", title: "unfinished thread" },
    // Match the real /session route: state is an object, unlike the flattened /sessions rows.
    state: { state: "unfinished", detail: "1 tool call(s) with no recorded result: bash" },
    messages: [
      { seq: 1, role: "user", content: "check the installer on the node", created_at: fixtureNow - 120, ok: 1, tool_calls: [] },
      { seq: 2, role: "assistant", content: "Running it now.", ok: 1, tool_calls: [] },
      { seq: 3, role: "assistant", content: "", ok: 1,
        tool_calls: [{ id: "c1", type: "function", function: { name: "bash", arguments: "{\"command\":\"wa toolchain check\"}" } }] },
      { seq: 4, role: "tool", content: "{\"code\":0,\"stdout\":\"git yes\"}", ok: 1, tool_name: "bash", tool_calls: [] },
      // A turn that changed a file. The repaint used to drop this, so a reloaded transcript showed no diff
      // topics at all while a live one did - and a window that has been reloaded is a repaint.
      { seq: 5, id: "message-with-changes", role: "assistant", content: "Changed it.", created_at: fixtureNow - 114, ok: 1, tool_calls: [],
        changes: { files: [{ path: "C:/tmp/proof.txt", added: 4, removed: 3, created: false }], added: 4, removed: 3 } },
      // A previous interruption was later continued. Its missing result is still in the ledger,
      // but it must not leave a live-looking row that triggers a repaint every five seconds.
      { seq: 6, role: "user", content: "first interrupted run", tool_calls: [] },
      { seq: 7, role: "assistant", content: "", tool_calls: [
        { id: "lost", type: "function", function: { name: "bash", arguments: "{\"command\":\"slow check\"}" } },
      ] },
      { seq: 8, role: "user", content: "continue after checking effects", tool_calls: [] },
      { seq: 9, role: "assistant", content: "Recovered safely.", tool_calls: [] },
      { seq: 10, role: "assistant", content: "", ok: 1,
        tool_calls: [
          { id: "c2", type: "function", function: { name: "read", arguments: "{\"path\":\"proof.txt\"}" } },
          { id: "c3", type: "function", function: { name: "bash", arguments: "{\"command\":\"wa toolchain check again\"}" } },
        ] },
      { seq: 11, role: "tool", tool_name: "read", content: "{\"content\":\"read completed\"}", ok: 1, tool_calls: [] },
    ],
  };
  var sendsBeforeRestore = window.__calls.filter(function (call) { return call.url === "chat" && call.method === "POST"; }).length;
  await window.__restoreSession();
  for (var un = 0; un < 30; un++) { await tick(); }
  var notice = document.querySelector(".unfinished-notice");
  check(!!notice, "a thread whose turn was cut off must say so in the chat");
  check(!!notice && /1 tool call/.test(notice.textContent),
    "and show the ledger's reason, saw: " + (notice ? notice.textContent.slice(0, 100) : "nothing"));
  check(!!notice && !!notice.querySelector("button"), "and offer to continue it");
  var unresolvedLines = document.querySelectorAll("wa-trace .tool-line.unrecorded");
  check(unresolvedLines.length === 2 && /result not recorded/.test(unresolvedLines[0].textContent),
    "both historical and current missing tool results must be marked unknown, never live");
  var tracesForBatch = document.querySelectorAll("wa-trace");
  var batchTrace = tracesForBatch[tracesForBatch.length - 1];
  var completedLine = batchTrace && batchTrace.querySelector(".tool-line.ok");
  check(!!completedLine && /read/.test(completedLine.textContent),
    "a partially completed tool batch must settle the recorded first call, not the last one: " +
      Array.from(batchTrace ? batchTrace.querySelectorAll(".tool-line") : []).map(function (line) { return line.className + ":" + line.textContent.slice(0, 70); }).join(" | "));
  check(!window.__toolTickerActive() && !document.querySelector("wa-trace .pending"),
    "a replayed tool must not start a new timer or remain pending");
  var firstRunMeta = document.querySelector("wa-run > button .trace-meta");
  check(!!firstRunMeta && /6\.0s/.test(firstRunMeta.textContent),
    "a replayed run must use recorded timestamps, not time since this page loaded");
  var oldBubble = document.querySelector("wa-message.assistant");
  var readsBeforeIdleReconcile = window.__calls.filter(function (call) { return call.url === "sessions"; }).length;
  await window.__reconcile();
  check(document.querySelector("wa-message.assistant") === oldBubble &&
    window.__calls.filter(function (call) { return call.url === "sessions"; }).length === readsBeforeIdleReconcile,
    "an idle page with historical missing results must not repaint the transcript");
  check(window.__calls.filter(function (call) { return call.url === "chat" && call.method === "POST"; }).length === sendsBeforeRestore,
    "restoring an unfinished tool must never execute it again");
  window.__fixtures.health.current = { label: "GET /models", ms: 50 };
  await window.__restoreSession();
  var readNotice = document.querySelector(".unfinished-notice");
  check(!!readNotice && /effects may have happened/.test(readNotice.textContent) && !!readNotice.querySelector("button"),
    "a UI read must not be mistaken for a running agent turn");
  window.__fixtures.health.current = null;

  // A chat run for a *different* conversation is not this window's run. Before `activeRun` was
  // scoped to the conversation, it returned the first chat run on the node, so a window watching
  // conversation B disabled its own composer and deferred its reconcile for conversation A's run.
  window.__fixtures.health.workers = [{ label: "POST /chat", busy_ms: 4000, session: "another-conversation" }];
  await window.__restoreSession();
  var foreignNotice = document.querySelector(".unfinished-notice");
  check(!!foreignNotice && /effects may have happened/.test(foreignNotice.textContent) && !!foreignNotice.querySelector("button"),
    "another conversation's run must not be treated as this window's run, saw: " +
      (foreignNotice ? foreignNotice.textContent.slice(0, 120) : "no notice"));
  window.__fixtures.health.workers = [];

  // Stop must tell the node, not only stop reading the stream: a client-side abort leaves the model
  // call running. The request is `POST /runs {action:cancel, thread}` for this window's conversation.
  var cancelCalls = window.__calls.filter(function (call) { return call.url === "runs" && call.method === "POST"; }).length;
  window.__setBusy(true);
  window.__cancelActiveRun();
  for (var cancelTick = 0; cancelTick < 10; cancelTick++) await tick();
  var runCalls = window.__calls.filter(function (call) { return call.url === "runs" && call.method === "POST"; });
  check(runCalls.length === cancelCalls + 1,
    "stopping a run must ask the node to cancel it, not only abort the stream");
  check(runCalls.some(function (call) { return /"action":"cancel"/.test(call.body || "") && /"thread"/.test(call.body || ""); }),
    "the cancel request must name the action and the conversation");
  window.__setBusy(false);

  // A session whose last turn *failed* is the same situation by another route, and it used to be
  // invisible here. Restoring it must say so without posting another turn: page navigation is read-only.
  //
  // The app picks the session from the *sessions list*, not from the session fixture - the first
  // attempt here set only the latter, so it restored the unfinished thread again. A fresh id
  // makes this a distinct case, and the fixtures are put back for the diff checks below.
  var savedSessions = window.__fixtures.sessions;
  var savedSession = window.__fixtures.session;
  window.__fixtures.sessions = {
    sessions: [
      {
        id: "cccccccc-0000-0000-0000-000000000003", title: "failed thread",
        mode: "chat", message_count: 3, updated_at: Math.floor(Date.now() / 1000) - 60,
        state: "failed", state_detail: "the last run failed (the model call errored)",
      },
    ],
  };
  window.__fixtures.session = {
    session: { id: "cccccccc-0000-0000-0000-000000000003", title: "failed thread" },
    state: { state: "failed", detail: "the last run failed (the model call errored)" },
    messages: [ { seq: 1, role: "user", content: "carry on with the cross-build", ok: 1, tool_calls: [] } ],
  };
  var sendsBeforeFailure = window.__calls.filter(function (call) { return call.url === "chat" && call.method === "POST"; }).length;
  await window.__restoreSession();
  for (var uf = 0; uf < 30; uf++) { await tick(); }
  var failedNotice = Array.from(document.querySelectorAll(".unfinished-notice")).find(function (n) {
    return /failed before it answered/.test(n.textContent);
  });
  check(!!failedNotice, "a session whose turn failed must say so in the chat, not just go quiet");
  check(!!failedNotice && !!failedNotice.querySelector("button"),
    "a failed turn must offer explicit continuation");
  check(window.__calls.filter(function (call) { return call.url === "chat" && call.method === "POST"; }).length === sendsBeforeFailure,
    "a failed turn must not spend another turn just because the page reloaded");

  // Repeated restores remain read-only; a prior regression auto-posted a turn on each page load.
  await window.__restoreSession();
  for (var ug = 0; ug < 30; ug++) { await tick(); }
  check(window.__calls.filter(function (call) { return call.url === "chat" && call.method === "POST"; }).length === sendsBeforeFailure,
    "repeated restores must remain read-only");
  window.__fixtures.sessions = savedSessions;
  window.__fixtures.session = savedSession;

  // A notice about a turn that is over must come down. It is a claim about right now, not a record - the
  // record is the engine's sessions topic - and a span that outlives what it described bloats the
  // transcript with every false alarm.
  // The ledger says this thread is settled, so the notice is not litter - it is simply not true any more.
  // The fixture must say so: it was unfinished, and the check passed only because the notice was never
  // re-derived. A test whose premise does not match its fixture is not testing what it claims.
  window.__fixtures.session.state = { state: "answered", detail: "the last turn is a reply" };
  window.__setBusy(false);
  await window.__restoreSession();
  for (var ur = 0; ur < 10; ur++) { await tick(); }
  check(!document.querySelector(".unfinished-notice"),
    "a notice about a finished turn must be removed once the node says the thread is settled");

  // The bug a reader hit: the turn had finished, the answer was in the ledger, and the window still said
  // "deciding..." until Ctrl+R. A tool is settled only by its own event, so a result that arrived while the
  // stream was gone leaves the topic open forever. When the node says the turn is over, the transcript is
  // repainted from the ledger - which is exactly what a reload does, and why a reload fixed it.
  // The fixture is new content, so it can only appear if the repaint ran: an assertion on content that was
  // already on screen would pass without the fix.
  var savedSessionsForRepaint = window.__fixtures.sessions;
  var savedSessionForRepaint = window.__fixtures.session;
  window.__fixtures.sessions = { sessions: [ { id: "dddddddd-0000-0000-0000-000000000004", title: "repaint proof", mode: "chat", message_count: 2, updated_at: Math.floor(Date.now()/1000), state: "answered", state_detail: "the last message is a reply" } ] };
  window.__fixtures.session = {
    session: { id: "dddddddd-0000-0000-0000-000000000004", title: "repaint proof" },
    state: { state: "answered", detail: "the last turn is a reply" },
    messages: [ { seq: 1, role: "user", content: "REPAINT-PROOF-QUESTION", ok: 1, tool_calls: [] },
             { seq: 2, role: "assistant", content: "REPAINT-PROOF-ANSWER", ok: 1, tool_calls: [] } ],
  };
  window.__setBusy(true);
  await window.__reconcile();
  for (var ux = 0; ux < 40; ux++) { await tick(); }
  check(messages.textContent.indexOf("REPAINT-PROOF-ANSWER") >= 0,
    "when the node says the turn is over, a stale transcript must be repainted from the ledger");
  // Put them back: a block that leaves its fixtures installed makes every later check test the wrong data -
  // which is what happened the first time this block was written.
  window.__fixtures.sessions = savedSessionsForRepaint;
  window.__fixtures.session = savedSessionForRepaint;

  // A repainted turn that changed a file must show its diff topic. The live path always did; the repaint
  // dropped the changes summary and the turn id, so every reloaded transcript lost every diff topic.
  //
  // The repaint is done here rather than relying on the transcript the block above left behind:
  // a check that says "a repainted turn" should explicitly repaint.
  await window.__restoreSession();
  for (var ud = 0; ud < 30; ud++) { await tick(); }
  var diffTopic = document.querySelector("wa-diff");
  check(!!diffTopic, "a repainted turn with changes must show its diff topic");
  check(!!diffTopic && /1 file changed/.test(diffTopic.textContent),
    "with the file count, saw: " + (diffTopic ? diffTopic.textContent.slice(0, 60) : "nothing"));
  check(!!diffTopic && /\+4/.test(diffTopic.textContent) && /3/.test(diffTopic.textContent),
    "and the GitHub-style totals, saw: " + (diffTopic ? diffTopic.textContent.slice(0, 60) : "nothing"));
  // The turn id is what the undo route is asked about. After the merge this is the branch's version, which
  // carries it in `dataset.messageId` - my check read a property my own version had, so it was asserting the
  // implementation rather than the behaviour. The behaviour is what matters: the topic knows its turn.
  check(!!diffTopic && !!(diffTopic.dataset.messageId || diffTopic.messageId),
    "and the message id the undo route is asked about, saw: " + (diffTopic ? JSON.stringify(diffTopic.dataset.messageId) : "no topic"));

  // Read-only topics use host read workers, so they must remain available while the run worker is
  // occupied. Topics that still need the run worker must queue clearly and load after the run.
  window.__setBusy(true);
  window.__loadTopic("sessions-box");
  for (var tb = 0; tb < 5; tb++) { await tick(); }
  var busyBox = document.getElementById("sessions-box");
  check(!/busy with a run/.test(busyBox.textContent) && !!busyBox.querySelector(".session-title"),
    "sessions must load from the read worker during a run, saw: " + busyBox.textContent.slice(0, 70));
  check(!/AbortError/.test(busyBox.textContent), "and must not report an abort as if the UI were broken");
  window.__loadTopic("spells-box");
  for (var tw = 0; tw < 5; tw++) { await tick(); }
  var waitingBox = document.getElementById("spells-box");
  check(/busy with a run/.test(waitingBox.textContent),
    "a topic that needs the run worker must say it is queued, saw: " + waitingBox.textContent.slice(0, 70));
  // And it must load by itself when the turn ends - nobody should have to reopen it.
  window.__setBusy(false);
  for (var tc = 0; tc < 40; tc++) { await tick(); }
  check(!/busy with a run/.test(waitingBox.textContent),
    "the queued topic must load when the turn finishes, saw: " + waitingBox.textContent.slice(0, 70));

  // The sessions topic is a way to *find* a thread, not just a list: named after its opening
  // message, most recent first, and searchable. A list you have to read top to bottom is not a way
  // to find anything.
  var search = document.getElementById("session-search");
  check(!!search, "the sessions topic must carry a search box");
  var titles = Array.prototype.map.call(document.querySelectorAll(".session-title"),
    function (node) { return node.textContent; });
  check(titles.indexOf("unfinished thread") >= 0 && titles.indexOf("settled thread") >= 0,
    "rows must show the thread's name, saw: " + titles.join("|"));
  check(/ago|just now/.test(document.getElementById("sessions-box").textContent),
    "and how long ago it was used rather than a locale timestamp, saw: " +
    document.getElementById("sessions-box").textContent.slice(0, 90));
  if (search) {
    search.value = "settled";
    search.dispatchEvent(new Event("input", { bubbles: true }));
    for (var sq = 0; sq < 5; sq++) { await tick(); }
    check(document.querySelectorAll(".session-row").length === 1,
      "searching must filter the list, saw " + document.querySelectorAll(".session-row").length);
    check(!!document.getElementById("session-search"), "and the box must survive its own filtering");
    search.value = "";
    search.dispatchEvent(new Event("input", { bubbles: true }));
    for (var sr = 0; sr < 5; sr++) { await tick(); }
    check(document.querySelectorAll(".session-row").length === 2, "and clearing it must restore them");
  }

  // The node chip answers the question the engine could not: which of these is this window
  // talking to? It names it, the engine marks exactly one row, and a rename leaves the
  // window: it goes to the node, and the label is redrawn from the node's reply.
  // The node control lives in the account balloon now, not the footer: it is a setting about
  // this node, and the footer is for the conversation. Open it the way a reader would.
  document.title = "stage: opening the balloon";
  document.getElementById("user-btn").click();
  for (var u = 0; u < 20; u++) { await tick(); }
  document.title = "stage: balloon open";
  var nodeButton = document.getElementById("node-name-btn");
  check(!!nodeButton, "the account balloon must carry the node control");
  check(!!nodeButton && nodeButton.textContent.length > 0 && nodeButton.textContent !== "…",
    "and it must name the node from the metadata the window already has, saw: " +
    (nodeButton ? JSON.stringify(nodeButton.textContent) : "no control"));
  check(document.getElementById("chip-node") === null,
    "the footer must no longer carry a node chip of its own");

  // The account pill is the icon and nothing beside it - a name there was truncated to "ma…" and
  // said nothing - and the tooltip carries what the icon cannot: which node, and how much this
  // window may do there.
  var pill = document.getElementById("user-btn");
  var avatar = document.getElementById("user-avatar");
  check(pill.textContent.trim() === (avatar.textContent || "").trim(),
    "the account pill must carry the icon and no written name, saw: " + JSON.stringify(pill.textContent));
  check(/^Signed in as .+ · \d+ tools$/.test(pill.title),
    "the account tooltip must read 'Signed in as <node> · n tools', saw: " + JSON.stringify(pill.title));

  // The balloon is three things: which node this is, what it looks like, and which node it talks
  // to. Everything that was taken out of it must stay out, and the node selector must have
  // arrived here rather than staying in the provider balloon.
  var accountMenu = document.getElementById("user-menu");
  var accountText = (accountMenu.textContent || "").toLowerCase();
  check(accountText.indexOf("change picture") >= 0, "the account balloon must offer Change Picture");
  check(accountText.indexOf("switch node") >= 0, "the account balloon must offer Switch Node");
  check(accountText.indexOf("sign in as") < 0 && accountText.indexOf("sign out") < 0,
    "and must not offer user sign-in any more, saw: " + JSON.stringify(accountText.slice(0, 80)));
  check(!!accountMenu.querySelector("select#node-select"),
    "the node selector must live in the account balloon now");
  check(document.querySelector("#status-balloon select#node-select") === null,
    "and must no longer be in the status balloon");

  // The picture replaces the initials inside the same circle, and taking it away brings them back.
  //
  // Only the two states are driven here. The picker itself needs a file dialog, and the resize
  // step needs async image decoding, which never completes under headless virtual time - the first
  // version of this block awaited it and hung the whole harness. So the swap is asserted, and the
  // downscale is checked by using the control rather than pretended to be covered here.
  localStorage.removeItem("wa-avatar");
  renderUser();
  check(!!avatar.textContent.trim() && !avatar.querySelector("img"),
    "with no picture the icon must show the initials, saw: " + JSON.stringify(avatar.textContent));
  localStorage.setItem("wa-avatar", "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==");
  renderUser();
  var picture = avatar.querySelector("img.user-avatar-img");
  check(!!picture, "a chosen picture must replace the initials inside the icon");
  check(pill.textContent.trim() === "",
    "and the pill must still carry no written text, saw: " + JSON.stringify(pill.textContent));
  check(avatar.classList.contains("has-picture"), "and the icon must know it is showing a picture");
  localStorage.removeItem("wa-avatar");
  renderUser();
  check(!!avatar.textContent.trim() && !avatar.querySelector("img"), "and removing it must restore the initials");

  // The nodes topic is a topic inside the engine, like sessions: opening the engine alone
  // does not fetch it, so click the way a reader would.
  document.title = "stage: nodes topic";
  document.querySelector('[data-target="nodes-box"]').click();
  for (var n = 0; n < 20; n++) { await tick(); }
  // One row for this machine: the node, with the desktop it runs a window on inside it. The
  // client executor is not a node and must not be listed as one - that is what made a single
  // node look like two.
  var localRows = document.querySelectorAll(".node-local");
  check(localRows.length === 1, "exactly one row is this machine, saw " + localRows.length);
  var thisBadge = document.querySelector(".node-this");
  check(!!thisBadge && /this node/.test(thisBadge.textContent), "and it must say this node");
  var desktopLine = document.querySelector(".node-desktop");
  check(!!desktopLine && /desktop/.test(desktopLine.textContent),
    "the desktop must be named on the node's own row, saw: " + (desktopLine ? desktopLine.textContent : "nothing"));
  var clientRow = null;
  var rows = document.querySelectorAll("#nodes-box .node");  for (var r = 0; r < rows.length; r += 1) {
    if (/\bclient\b/.test(rows[r].textContent)) clientRow = rows[r];
  }
  check(clientRow === null, "the client executor must not be a row of its own");
  var controlButtons = 0;
  for (var c = 0; c < rows.length; c += 1) {
    if (/control/.test(rows[c].textContent)) controlButtons += 1;
  }
  check(controlButtons === 2, "local and remote desktops must each offer control, saw " + controlButtons + " button(s)");
  // Keep it: the engine re-renders when its topics change, and the nodes rows are gone by the
  // time the control view is opened further down.
  var controlButton = null;
  for (var cb = 0; cb < rows.length; cb += 1) {
    var rowButtons = rows[cb].querySelectorAll("button");
    for (var rb = 0; rb < rowButtons.length; rb += 1) {
      if (/control/i.test(rowButtons[rb].textContent)) controlButton = rowButtons[rb];
    }
  }

  // Full screen is a mode, and a mode must be escapable more than one way: the control, Escape,
  // and closing the view. Its size comes from the shell, so the page asks for it - a spy here,
  // because a real one would resize the window this test runs in.
  window.__maximizeCalls = [];
  // The app captured its native bridge when it loaded, so the spy goes on that object rather
  // than on a fresh window.wasmAgent.
  if (window.__native) {
    window.__native.maximize = function () { window.__maximizeCalls.push("maximize"); };
    window.__native.expand = function () { window.__maximizeCalls.push("expand"); };
  }
  // Drive the view directly: how the row renders its button is already asserted above, and
  // this block is about what the maximize control does.
  check(!!controlButton, "the node row must offer the control view");
  window.__openControl("client");
  for (var m = 0; m < 10; m++) { await tick(); }
  var controlBox = document.getElementById("control-view");
  var controlSection = document.getElementById("control");
  check(!!controlBox, "the control view must exist");
  check(!!controlSection && controlSection.hidden === false, "the control view must open from the node row");
  document.getElementById("control-max").click();
  check(controlBox.classList.contains("maximized"), "the maximize control must enter full size");
  // In this harness there is no native shell, so there is nothing to ask and nothing may be
  // asked. The hand-off to the shell is verified in the real window, not faked here.
  check(window.__native === null || window.__native === undefined,
    "this harness runs without a native shell, so the shell call cannot be asserted here");
  check(window.__maximizeCalls.join(",") === "",
    "with no shell, nothing may be called, saw: " + window.__maximizeCalls.join(","));
  document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
  check(!controlBox.classList.contains("maximized"), "Escape must leave full size");
  check(controlBox.hidden === false, "and must not close the view as well");
  check(window.__maximizeCalls.join(",") === "",
    "and leaving it must not call a shell that is not there, saw: " + window.__maximizeCalls.join(","));
  document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
  check(controlSection.hidden === true, "and a second Escape closes the view");
  window.__openControl("openclaw");
  for (var remoteFrame = 0; remoteFrame < 10; remoteFrame++) { await tick(); }
  var frameCalls = window.__calls.filter(function (call) { return call.url === "frame"; });
  check(frameCalls.length > 0 && frameCalls[frameCalls.length - 1].headers["X-WA-Node"] === "openclaw",
    "the remote control view must request frames from its own node");
  var controlText = document.getElementById("control-text");
  controlText.value = "remote input";
  document.getElementById("control-keys").dispatchEvent(new Event("submit", { cancelable: true }));
  for (var remoteInput = 0; remoteInput < 5; remoteInput++) { await tick(); }
  var clientCalls = window.__calls.filter(function (call) { return call.url === "client"; });
  check(clientCalls.length > 0 && clientCalls[clientCalls.length - 1].headers["X-WA-Node"] === "openclaw",
    "remote keyboard input must go to the same node as the frame");
  document.getElementById("control-close").click();
  var nodesText = document.getElementById("nodes-box").textContent;
  check(/foundation/.test(nodesText) && /openclaw/.test(nodesText),
    "both nodes must be listed, saw: " + nodesText.slice(0, 120));

  // The skills topic, before spells: a skill is what the agent *is* - instructions it can be
  // given - while a spell is something it saved. It lists every skill this node can see and says,
  // for each, whether the body can actually be loaded on demand, which is a different fact from
  // the description being in context.
  document.title = "stage: skills topic";
  document.querySelector('[data-target="skills-box"]').click();
  for (var sk = 0; sk < 40; sk++) { await tick(); }
  var skillsBox = document.getElementById("skills-box");
  var skillRows = skillsBox.querySelectorAll(".skill-row");
  check(skillRows.length === 2, "the skills topic must list every skill, saw " + skillRows.length);
  var skillsText = skillsBox.textContent;
  check(skillsText.indexOf("handoff-gate") >= 0, "and must name them, saw: " + skillsText.slice(0, 80));
  check(skillsText.indexOf("chars on demand") >= 0,
    "and say whether each body can be loaded on demand, saw: " + skillsText.slice(0, 160));
  check(skillsText.indexOf("hidden from the model") >= 0 && skillsText.indexOf("described in context") >= 0,
    "and separate a skill the model is told about from one it is not");
  var topicNames = Array.prototype.map.call(document.querySelectorAll(".engine-name"),
    function (span) { return span.textContent; });
  check(topicNames.indexOf("skills") >= 0 && topicNames.indexOf("skills") < topicNames.indexOf("spells"),
    "the skills topic must come before spells, saw: " + topicNames.join(","));
  check((document.getElementById("skills-note").textContent || "").length > 0,
    "and the topic note must say how many there are");

  // <wa-window>: the in-page window used when there is no shell to spawn a real one - a browser,
  // or this harness. It makes the same promises the native window does: drag by the title bar,
  // resize from an edge, close, and come back where you left it.
  var inPage = document.createElement("wa-window");
  inPage.setAttribute("name", "harness-view");
  // Seed the geometry first: a default placement gets clamped to the harness window, and a drag
  // from a clamped edge is capped - which makes an exact assertion about the delta impossible. A
  // window with room around it moves by exactly what the pointer moved.
  localStorage.setItem("wa-window-harness-view", JSON.stringify({ x: 20, y: 20, w: 300, h: 240 }));
  inPage.open = true;
  document.body.append(inPage);
  for (var ww = 0; ww < 5; ww++) { await tick(); }
  var frame = inPage.shadowRoot.querySelector(".frame");
  check(!!frame, "wa-window must render a frame");
  check(!!frame && frame.offsetWidth > 0 && frame.offsetHeight > 0, "and it must have a size");
  var startLeft = frame.offsetLeft;
  var startTop = frame.offsetTop;
  var sendPointer = function (type, x, y, target) {
    var event = new PointerEvent(type, { bubbles: true, clientX: x, clientY: y, button: 0, pointerId: 1 });
    (target || document).dispatchEvent(event);
  };
  sendPointer("pointerdown", startLeft + 20, startTop + 8, inPage.shadowRoot.querySelector(".bar"));
  sendPointer("pointermove", startLeft + 80, startTop + 58);
  sendPointer("pointerup", startLeft + 80, startTop + 58);
  check(frame.offsetLeft === startLeft + 60 && frame.offsetTop === startTop + 50,
    "dragging the title bar must move the window by exactly the drag, saw " +
    startLeft + "," + startTop + " -> " + frame.offsetLeft + "," + frame.offsetTop);
  var widthBefore = frame.offsetWidth;
  // The expectation is derived from where the pointer actually started, not from a number I chose:
  // the press lands 2px inside the edge, so the delta is 62 and not 60. Writing 60 by hand made a
  // correct component look broken.
  var downX = frame.offsetLeft + frame.offsetWidth - 2;
  var moveX = downX + 62;
  sendPointer("pointerdown", downX, frame.offsetTop + 40,
    inPage.shadowRoot.querySelector(".grip.e"));
  sendPointer("pointermove", moveX, frame.offsetTop + 40);
  sendPointer("pointerup", moveX, frame.offsetTop + 40);
  check(frame.offsetWidth === widthBefore + (moveX - downX),
    "the east edge must resize it by exactly the pointer delta, saw " + widthBefore + " -> " + frame.offsetWidth);
  check(!!localStorage.getItem("wa-window-harness-view"), "and its geometry must be remembered");
  inPage.close();
  check(!inPage.open && inPage.hidden, "closing must hide it");
  inPage.remove();

  document.title = "stage: renaming";
  // Ticks, not await: the app's apiFetch arms a setTimeout for its own deadline, and this
  // harness runs with virtual time, so awaiting an app promise that goes through it never
  // settles. Driving the call and then draining microtasks is the pattern every other check
  // here uses, and this one had broken it.
  window.__renameNode("renamed-by-the-test");
  for (var w = 0; w < 40; w++) { await tick(); }
  document.title = "stage: renamed";
  check(!!nodeButton && nodeButton.textContent === "renamed-by-the-test",
    "the control must show what the node reported, saw: " + (nodeButton ? nodeButton.textContent : "no control"));
  // A name the node refuses must not stick: the branch could not be renamed, so the node kept
  // its old name and the window has to say so rather than showing a name the node does not have.
  window.__renameNode("refused");
  for (var rf = 0; rf < 30; rf++) { await tick(); }
  // `.status` is shared: setStatus draws transient notices *and* the run status line, so a bare
  // selector returns whichever came first in the document - which is now a repainted run's footer.
  // The notice is the most recent one.
  var refusedNotes = document.querySelectorAll(".status");
  var refusedNote = refusedNotes[refusedNotes.length - 1];
  check(!/refused/.test(nodeButton.textContent),
    "a refused rename must not stick in the control, saw: " + nodeButton.textContent);
  check(!!refusedNote && /could not rename/.test(refusedNote.textContent),
    "and it must say why, saw: " + (refusedNote ? refusedNote.textContent : "no status"));

  var posted = (window.__calls || []).filter(function (call) {
    return call.url.indexOf("node/name") >= 0 && call.method === "POST";
  });
  check(posted.length === 2, "both renames must be sent to the node, saw " + posted.length);
  check(posted.length >= 1 && JSON.parse(posted[0].body).name === "renamed-by-the-test",
    "and it must carry the new name, saw: " + (posted[0] ? posted[0].body : "nothing"));

  // A lost connection has to be classified: that is what turns a raw TypeError
  // into something a reader can act on, and it is checkable without a network.
  var classify = window.__classifyProbe ? window.__classifyProbe() : ["the classify probe is missing"];
  for (var c = 0; c < classify.length; c++) { problems.push(classify[c]); }

  // --- liveness: can a reader tell "working" from "stuck"? ---
  // This is the observation that was missing: a running turn showed a spinner either way, so a long
  // command and a wedged one were indistinguishable until one was killed. Both states must be
  // reachable, because a display that can only ever say "working" is decoration.
  (function () {
    window.__stopLiveness();
    window.__setLiveness({ working: true, stalled: 46, busy_ms: 25369, climbing_ms: 0, worker: "alive", queue: 0 });
    var ok = document.getElementById("liveness");
    check(!!ok, "liveness: no line rendered while working");
    if (ok) {
      check(!ok.classList.contains("stuck"), "liveness: a fresh beat must not read as stuck");
      check(ok.textContent.indexOf("working") >= 0, "liveness: the working state must say so");
      // The socket number is the node's own evidence, so it has to appear rather than a guess.
      check(ok.textContent.indexOf("46 ms") >= 0, "liveness: the beat age must be shown, got: " + ok.textContent);
      check(ok.textContent.indexOf("25") >= 0, "liveness: the elapsed time must be shown, got: " + ok.textContent);
    }
    window.__setLiveness({ working: false, stalled: 9000, busy_ms: 60000, climbing_ms: 9000, worker: "alive", queue: 0 });
    var stuck = document.getElementById("liveness");
    check(!!stuck, "liveness: the line vanished when it turned into a stall");
    if (stuck) {
      check(stuck.classList.contains("stuck"), "liveness: no beat for 9s must be flagged");
      check(stuck.textContent.indexOf("stuck") >= 0, "liveness: the stuck state must say so, got: " + stuck.textContent);
    }
    // One element, not two: a status line that accumulates is litter in the transcript.
    check(document.querySelectorAll("#liveness").length === 1, "liveness: more than one line in the transcript");
    window.__stopLiveness();
    check(!document.getElementById("liveness"), "liveness: the line outlived the turn it described");
  })();
  // ---- `/` commands -------------------------------------------------------
  //
  // Driven through the events a keyboard actually produces, because what matters is what a reader
  // gets, not what a function returns. The list, the choice and the effect are all asserted, and the
  // last one is the point: a menu that clears the transcript while the turn still goes to the old
  // thread would look exactly like a new session and be a lie.
  (function () {
    document.title = "stage: commands";
    var input = window.__commandInput();
    var menu = window.__commandMenu();
    function type(value) { window.__typeCommand(value); }

    type("/");
    check(menu.open, "commands: `/` must open the list");
    var items = Array.prototype.slice.call(menu.querySelectorAll(".menu-item"));
    check(items.length === 3, "commands: `/` must offer all three commands, got " + items.length);
    check(items[0] && items[0].textContent.indexOf("/new") >= 0,
      "commands: the list must offer /new first, got: " + (items[0] && items[0].textContent));
    check(items[1] && items[1].textContent.indexOf("/update") >= 0,
      "commands: the list must offer /update, got: " + (items[1] && items[1].textContent));
    check(items[2] && items[2].textContent.indexOf("/merge") >= 0,
      "commands: the list must offer /merge, got: " + (items[2] && items[2].textContent));

    // `/update` asks the node to install its own tree's build. The three answers it can give must
    // read as three different things: queued is *not* done, and a refusal is not a silence. The
    // sentence comes from the node, so this asserts that it is shown, not that it was invented here.
    var notice = window.__updateNotice({
      ok: true, queued: true, message: "queued: the sentinel will install abc1234 once this node is idle. This is not done yet.",
      next: "the sentinel performs it when this node is idle.",
    });
    check(notice.indexOf("queued") === 0 || notice.indexOf("/update — queued") >= 0,
      "commands: a queued update must say queued, got: " + notice);
    check(notice.indexOf("abc1234") >= 0, "commands: the queued notice must name the commit, got: " + notice);
    var current = window.__updateNotice({ ok: true, changed: false, message: "nothing to do: this node already runs commit abc1234." });
    check(current.indexOf("nothing to do") >= 0,
      "commands: an already-current node must say so, got: " + current);
    var refused = window.__updateNotice({ ok: false, error: "nothing_built", observed: "no binary at C:/work/foundation/rust/target/release/wa.exe", next: "build it first." });
    check(refused.indexOf("refused") >= 0 && refused.indexOf("no binary at") >= 0 && refused.indexOf("build it first") >= 0,
      "commands: a refusal must carry what was seen and where to go, got: " + refused);

    // The first match is chosen before any arrow key is pressed, so Enter does what the list shows.
    var chosen = menu.querySelectorAll(".menu-item.selected");
    check(chosen.length === 1, "commands: exactly one row is chosen by default, got " + chosen.length);
    check(chosen[0] === items[0], "commands: the default choice must be the first match");

    type("/n");
    check(menu.open, "commands: a partly typed command must keep the list open");
    type("/zzz");
    check(!menu.open, "commands: nothing matching must close the list");
    type("/new\nand then a message");
    check(!menu.open, "commands: a newline ends the command line, so a message is not trapped");

    // The arrows must not *lose* the selection: a menu that forgets it sends Enter nowhere.
    type("/");
    var beforeArrow = menu.querySelector(".menu-item.selected");
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }));
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true }));
    check(menu.querySelector(".menu-item.selected") === beforeArrow,
      "commands: the arrows must not lose the selection");

    // Enter runs it.
    var messages = document.getElementById("messages");
    var was = window.__chatThread();
    check(messages.children.length > 0, "commands: there must be a transcript for /new to clear");
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    check(!menu.open, "commands: running a command must close the list");
    check(messages.children.length === 1 && messages.firstElementChild.classList.contains("thread-notice"),
      "commands: /new must leave an empty transcript and say so, got " + messages.children.length + " children");
    var now = window.__chatThread();
    check(!!now && now !== was, "commands: /new must move the window to a different thread");
    check(input.value === "", "commands: the command text must not be left in the composer");

    // Running `/update` must actually ask the node. A notice that says "queued" without a request
    // behind it would look identical in the transcript, so the request is what is asserted - the
    // fixtures record it synchronously, the way the fetch wrapper sees it.
    type("/update");
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    var asked = (window.__calls || []).some(function (call) {
      return String(call.url).indexOf("update") >= 0 && call.method === "POST";
    });
    check(asked, "commands: running /update must POST to the node's update route");
    check(messages.lastElementChild && messages.lastElementChild.classList.contains("thread-notice"),
      "commands: /update must leave its answer in the transcript");

    // And the turn must name that thread, or the transcript is new and the ledger is not.
    var body = window.__composed("hello");
    check(body.contentType === "application/json",
      "commands: a named thread must be sent as a structured body, got " + body.contentType);
    var payload = JSON.parse(body.body);
    check(payload.thread === now, "commands: the turn must name the new thread, got " + payload.thread);
    check(payload.text === "hello", "commands: the message itself must survive, got " + payload.text);
    check(payload.images === undefined, "commands: no pictures must be sent when none were attached");

  })();
  // ---- in-flight tool age -------------------------------------------------
  //
  // A long command and a wedged one used to look identical: both were a tool line that had not come
  // back. The pending line now carries the call's age against its deadline, so a reader can tell
  // "42s of 300s" from a call that has no bound at all. Timers do not advance under this harness's
  // virtual time, so the ticker's own paint is driven directly; what is asserted is the text, and that
  // one shared ticker runs while a call is in flight and stops when it settles.
  (function () {
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "delta", text: "Running the slow check." });
    window.handleEvent({ type: "tool", name: "bash", arguments: { command: "sleep 300" }, timeout_ms: 300000 });
    var line = document.querySelector("wa-trace .tool-line.pending");
    check(!!line, "tool age: an in-flight call must have a pending line");
    var outcome = line ? line.querySelector(".tool-outcome") : null;
    check(!!outcome && outcome.textContent.indexOf("0s of 300s") >= 0,
      "tool age: a fresh call must show its bound immediately, saw: " + (outcome ? outcome.textContent : "no outcome"));
    window.__setToolAge(42);
    check(!!outcome && outcome.textContent.indexOf("42s of 300s") >= 0,
      "tool age: the age must be painted against the bound, saw: " + (outcome ? outcome.textContent : "no outcome"));
    check(window.__toolTickerActive() === true,
      "tool age: the shared ticker must run while a call is in flight");
    window.handleEvent({ type: "tool_result", result: { code: 0, stdout: "done" } });
    check(window.__toolTickerActive() === false,
      "tool age: the ticker must stop when the call settles, or it counts for a line that is over");
    check(!!outcome && outcome.textContent.indexOf("exit 0") >= 0,
      "tool age: the settled line must show its outcome, not a frozen age, saw: " + (outcome ? outcome.textContent : "no outcome"));
    window.handleEvent({ type: "reply", text: "Slow check done." });
    window.handleEvent({ type: "done" });
  })();
  // ---- reasoning ----------------------------------------------------------
  //
  // A reasoning model's thinking arrives in a field of its own, so a turn whose content was
  // entirely thinking used to render as a turn that only called tools. The thinking is now a
  // step of its own: it must appear with the text the node streamed, survive the run's
  // collapse, and fold away when the run answers.
  (function () {
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "reasoning", text: "weighing the options", chars: 19 });
    var blocks = document.querySelectorAll("wa-message .reasoning");
    var block = blocks[blocks.length - 1];
    check(!!block, "reasoning: a reasoning delta must render a thinking block");
    var runStatuses = document.querySelectorAll(".chat-content-run-status:not(.finished)");
    var runStatus = runStatuses[runStatuses.length - 1];
    check(!!runStatus && getComputedStyle(runStatus).position === "sticky",
      "run status: the live status must stay pinned to the chat viewport bottom");
    check(!!runStatus && !!runStatus.querySelector(".chat-content-run-elapsed"),
      "run status: elapsed time has its own right-aligned field");
    check(!!block && block.textContent.indexOf("weighing the options") >= 0,
      "reasoning: the block must carry the text the node streamed, saw: " +
      (block ? block.textContent : "nothing"));
    check(!!block && block.open === true, "reasoning: it must be open while the run is thinking");
    window.handleEvent({ type: "tool", name: "bash", arguments: { command: "ls" } });
    window.handleEvent({ type: "tool_result", result: { code: 0, stdout: "ok" } });
    window.handleEvent({ type: "reply", text: "The options are weighed." });
    var settled = document.querySelectorAll("wa-message .reasoning");
    var folded = settled[settled.length - 1];
    check(!!folded, "reasoning: collapsing the run must not swallow the thinking");
    check(!!folded && folded.open === false, "reasoning: it must fold away once the run answers");
    // It belongs *inside* the topic: it is the route, not the answer, and a long run left a wall of
    // "thinking · N chars" rows sitting outside the topics, between the reader and the answer
    // (measured live: 196 of them outside the topics in one thread).
    check(!!folded && folded.closest("wa-run") !== null,
      "reasoning: it is the route, not the answer, and belongs inside the run topic");
    window.handleEvent({ type: "done" });
    check(!!runStatus && runStatus.classList.contains("finished") && runStatus.closest("wa-message"),
      "run status: on completion, the same status becomes the assistant bubble footer");
    check(!!runStatus && /^\d+:\d{2}$/.test(runStatus.querySelector(".chat-content-run-elapsed").textContent),
      "run status: the completed footer keeps the run duration");
  })();

  // ...but a run that called no tool must not be swallowed whole: no topic is created for one, so its
  // thinking stays visible rather than the run reading as one that only called tools.
  (function () {
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "reasoning", text: "thinking, and nothing else", chars: 26 });
    window.handleEvent({ type: "reply", text: "Thought it through and answered." });
    var solo = document.querySelectorAll("wa-message .reasoning");
    var soloBlock = solo[solo.length - 1];
    check(!!soloBlock && soloBlock.closest("wa-run") === null,
      "reasoning: a run that called no tool keeps its thinking visible, outside any topic");
    check(!!soloBlock && soloBlock.open === false,
      "reasoning: and it still folds away when that run answers");
    window.handleEvent({ type: "done" });
  })();

  // ---- a trailing newline is a blank line, and must not render as one ----------------------
  // Both containers are `white-space: pre-wrap`, so a provider's trailing newline draws an empty line.
  // Measured in the live window: three of them sat between the thinking and the tool call that
  // followed it, which reads as three paragraphs of nothing. Interior breaks are content and stay.
  //
  // Written without a single backslash on purpose: the probe is injected as text, and an escape
  // sequence inside it becomes a real character - which turns a string literal into a syntax error and
  // kills the whole block silently. That is how this check first "passed": it was never running.
  (function () {
    var NL = String.fromCharCode(10);
    var CR = String.fromCharCode(13);
    var SP = String.fromCharCode(32);
    var TAB = String.fromCharCode(9);
    function endsBlank(text) {
      if (!text) return true;
      var last = text.charAt(text.length - 1);
      return last === NL || last === CR || last === SP || last === TAB;
    }
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "reasoning", text: "weighing it up" + NL + "and then" + NL + NL + NL, chars: 25 });
    var blocks = document.querySelectorAll("wa-message .reasoning");
    var block = blocks[blocks.length - 1];
    var body = block ? block.querySelector(".reasoning-body") : null;
    check(!!body, "trailing space: the reasoning body must exist");
    check(!!body && !endsBlank(body.textContent),
      "trailing space: the thinking must not end in a blank line, saw " +
      JSON.stringify(body ? body.textContent.slice(-10) : "no body"));
    check(!!body && body.textContent.indexOf("weighing it up" + NL + "and then") === 0,
      "trailing space: an interior break is content and must stay, saw " +
      JSON.stringify(body ? body.textContent : "no body"));
    window.handleEvent({ type: "delta", text: "Checking the file" + NL + NL + NL });
    var segs = document.querySelectorAll("wa-message .seg");
    var lastSeg = segs[segs.length - 1];
    check(!!lastSeg && !endsBlank(lastSeg.textContent),
      "trailing space: a streamed step must not end in a blank line, saw " +
      JSON.stringify(lastSeg ? lastSeg.textContent.slice(-10) : "no seg"));
    window.handleEvent({ type: "reply", text: "Done." + NL + NL });
    window.handleEvent({ type: "done" });
  })();

  // ---- one topic standard, and the thinking is a topic too -----------------------------------
  // The thinking block used to be a bespoke <details> with its own header: taller than the tool-call
  // topics beside it, no chevron, no glyph - so it read as a different kind of thing. It is now
  // <wa-reasoning>, built by the same `topicParts` as <wa-trace>/<wa-run>/<wa-diff>. Asserted as the
  // three things a reader sees: the same header parts in the same order, the same height, the chevron.
  (function () {
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "reasoning", text: "weighing the standard", chars: 22 });
    window.handleEvent({ type: "tool", name: "bash", arguments: { command: "ls" } });
    var topics = document.querySelectorAll("wa-message wa-reasoning");
    var think = topics[topics.length - 1];
    check(!!think, "topic standard: the thinking must be a <wa-reasoning> topic");
    var head = think ? think.querySelector(":scope > .trace-head") : null;
    var parts = head ? Array.prototype.map.call(head.children, function (c) { return c.className; }).join(",") : "";
    check(parts === "trace-glyph,trace-label,trace-meta,trace-chevron",
      "topic standard: the thinking header must hold glyph,label,meta,chevron like every other topic, saw: " + parts);
    check(!!head && head.textContent.indexOf("thinking") >= 0,
      "topic standard: its label says what it is, saw: " + (head ? head.textContent : "no head"));
    check(!!head && !!head.querySelector(".trace-chevron"),
      "topic standard: it carries the chevron that says it opens");
    var traces = document.querySelectorAll("wa-message wa-trace");
    var trace = traces[traces.length - 1];   // the one this block just made, so it is visible
    var traceHead = trace ? trace.querySelector(":scope > .trace-head") : null;
    var thinkH = head ? Math.round(head.getBoundingClientRect().height) : -1;
    var traceH = traceHead ? Math.round(traceHead.getBoundingClientRect().height) : -2;
    check(thinkH > 0 && thinkH === traceH,
      "topic standard: the thinking header must be the same height as a tool-call header, saw " + thinkH + " vs " + traceH);
    window.handleEvent({ type: "done" });
  })();

  // ---- the route stays open while the run is going --------------------------------------------
  // Measured with a probe on a two-round run: after the first answer the run topic CLOSED, and the
  // thinking and the tool lines went with it - so a reader watching a long run saw a folded topic and
  // a list of answers rather than the run happening. The principle is already the one a running
  // *trace* follows ("open so its tool lines are visible"); this is the same rule one level up, and a
  // repaint is history, so a reloaded transcript still starts closed.
  (function () {
    var vis = function (el) { if (!el) return false; var r = el.getBoundingClientRect(); return r.height > 0; };
    var lastOf = function (sel) { var l = document.querySelectorAll(sel); return l[l.length - 1]; };
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "reasoning", text: "first thought", chars: 13 });
    window.handleEvent({ type: "tool", name: "bash", arguments: { command: "ls" } });
    window.handleEvent({ type: "reply", text: "First answer." });
    var topic = lastOf("wa-message wa-run");
    check(!!topic && topic.open, "live route: the run topic must stay open while the run is going");
    check(vis(lastOf("wa-message wa-reasoning")), "live route: the thinking must still be visible mid-run");
    window.handleEvent({ type: "round", n: 2 });
    window.handleEvent({ type: "reasoning", text: "second thought", chars: 14 });
    window.handleEvent({ type: "tool", name: "bash", arguments: { command: "ls -la" } });
    window.handleEvent({ type: "reply", text: "Second answer." });
    check(!!topic && topic.open, "live route: it stays open across rounds");
    window.handleEvent({ type: "done" });
    check(!!topic && !topic.open, "live route: it folds away when the run ends");
  })();
  // ---- a run this window did not open must be followed, not waited out ----------------------
  // The node streams a run only to the request that opened it, so a reload during a run (or a run a
  // wake or a job started) has no live channel. Measured live before this existed: the node executed
  // 40s of work in the thread and the page's transcript did not change by one byte. /session answers
  // while the run is in flight, so the window follows the ledger instead of freezing until the run ends.
  //
  // Awaited in the harness's own body on purpose: an un-awaited IIFE left these checks running after
  // the verdict was computed, and a check that never runs looks exactly like one that passes.
  var followThread = window.__chatThread();
  check(!!followThread, "follow: the window must know which thread it is in");
  window.__fixtures.health.workers = [{ label: "POST /chat", busy_ms: 5000, session: followThread }];
  window.__fixtures.health.current = { label: "POST /chat", ms: 5000, session: followThread };
  window.__fixtures.sessions = { sessions: [{ id: followThread, title: "followed", user_id: "master",
    mode: "chat", message_count: 3, last_seq: 4242, updated_at: Math.floor(Date.now() / 1000),
    state: "unfinished", state_detail: "a run is in flight" }] };
  window.__fixtures.session = {
    session: { id: followThread, title: "followed" },
    state: { state: "unfinished", detail: "a run is in flight" },
    messages: [
      { seq: 1, role: "user", content: "FOLLOWED-QUESTION", tool_calls: [] },
      { seq: 2, role: "assistant", content: "FOLLOWED-PARTIAL", tool_calls: [] },
    ],
  };
  window.__resetFollow();
  await window.__watchTurn();
  for (var followDrain = 0; followDrain < 30; followDrain++) await tick();
  // The assertion is on the *text*, not on a bubble count: a count can grow because some other
  // path repainted, so it passes against the broken code too - and a check that passes on broken
  // code is not a check. FOLLOWED-PARTIAL exists only in the fixture above, so it can only appear
  // if this poll redrew the thread from the ledger.
  check(document.body.innerText.indexOf("FOLLOWED-PARTIAL") >= 0,
    "follow: a run this window did not open must be followed without a reload");
  // ONE BUBBLE PER RUN, however many times the model speaks inside it.
  // Measured live: a run whose model wrote a one-line preamble before each tool batch produced three
  // assistant messages in one run, and the window drew THREE bubbles - because the `reply` handler
  // closed the bubble (`runBubble = null`) on every reply event, contradicting flushDecision's own
  // contract that "the bubble only closes when the run really ends". The run topic exists to fold the
  // route away, and a topic cannot span bubbles, so a multi-step run read as several unrelated replies.
  (function () {
    var msgs = document.getElementById("messages");
    var before = msgs.querySelectorAll("wa-message.assistant").length;
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "delta", text: "Let me check the record." });
    window.handleEvent({ type: "tool", name: "bash", arguments: { command: "cat a" } });
    window.handleEvent({ type: "tool_result", name: "bash", result: { content: "a" } });
    window.handleEvent({ type: "reply", text: "Let me check the record.", message_id: "message-multi-1" });
    window.handleEvent({ type: "round", n: 2 });
    window.handleEvent({ type: "delta", text: "Now the second probe." });
    window.handleEvent({ type: "tool", name: "bash", arguments: { command: "cat b" } });
    window.handleEvent({ type: "tool_result", name: "bash", result: { content: "b" } });
    window.handleEvent({ type: "reply", text: "Now the second probe.", message_id: "message-multi-2" });
    window.handleEvent({ type: "round", n: 3 });
    window.handleEvent({ type: "delta", text: "The answer." });
    window.handleEvent({ type: "reply", text: "The answer.", message_id: "message-multi-3" });
    var after = msgs.querySelectorAll("wa-message.assistant").length;
    check(after === before + 1,
      "one run is one bubble however many times it speaks (was " + before + ", now " + after + ")");
    var multi = msgs.querySelectorAll("wa-message.assistant")[after - 1];
    var multiBody = multi ? multi.querySelector(".body") : null;
    var multiShape = multiBody ? Array.prototype.map.call(multiBody.children, function (c) {
      return c.tagName === "WA-RUN" ? "run" : (c.tagName === "WA-TRACE" ? "trace"
        : (c.tagName === "WA-DIFF" ? "diff" : "text"));
    }).join(",") : "";
    check(multiShape === "run,text",
      "a run that speaks three times folds into one topic above the answer, saw " + multiShape);
    check(multiBody && multiBody.querySelectorAll("wa-run").length === 1,
      "the run topic must not nest on the second reply, saw "
      + (multiBody ? multiBody.querySelectorAll("wa-run").length : "no body"));
    window.handleEvent({ type: "done" });
  })();
  // The status line belongs to the run, and then to the bubble, in that order. Mid-run it must be
  // the last thing in the transcript: appended when it was created - before the run's bubble
  // existed - it was overtaken by that bubble and drifted to the top of the bubble it describes.
  // At the end it must be the bubble's last child: a footer under the answer carrying the run's
  // time, not a child of the custom element, which has no place for it.
  (function () {
    window.handleEvent({ type: "status", text: "placement check: a run is in flight" });
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "delta", text: "the answer is being written" });
    var live = document.querySelectorAll(".chat-content-run-status:not(.finished)");
    var placed = live[live.length - 1];
    check(!!placed, "the placement check needs a live status line");
    var tail = messages.children[messages.children.length - 1];
    check(tail === placed,
      "mid-run the status line must be the last thing in the transcript, saw: "
      + (tail ? tail.tagName + "." + tail.className : "nothing"));
    // "Sticked" is half the behaviour and it is invisible to a structure check: the line is pinned
    // to the bottom of the transcript while the run is in flight, and only becomes the bubble's
    // footer when the run ends. A line that never pins and a line that never moves look identical
    // in a screenshot, so the computed position is asserted on both sides of that move.
    var livePosition = getComputedStyle(placed).position;
    check(livePosition === "sticky",
      "mid-run the status line must be sticky at the bottom of the transcript, saw position: " + livePosition);
    check(placed.parentNode === messages,
      "mid-run the status line must live in the transcript, not inside the bubble, saw parent: "
      + (placed.parentNode ? placed.parentNode.tagName : "none"));
    var bubbles = messages.querySelectorAll("wa-message.assistant");
    var bubble = bubbles[bubbles.length - 1];
    check(Array.prototype.indexOf.call(messages.children, bubble)
      < Array.prototype.indexOf.call(messages.children, placed),
      "the status line must sit below the run's bubble, not above it");
    window.handleEvent({ type: "reply", text: "the answer." });
    window.handleEvent({ type: "done" });
    var body = bubble ? bubble.body : null;
    var footer = body ? body.children[body.children.length - 1] : null;
    check(!!footer && footer.classList.contains("chat-content-run-status"),
      "after the run the status line must be inside the bubble's body, saw: "
      + (footer ? footer.tagName + "." + footer.className : "nothing"));
    check(!!footer && footer.classList.contains("finished"),
      "and it must be the finished footer, under the answer");
    var footerPosition = footer ? getComputedStyle(footer).position : "none";
    check(footerPosition === "static",
      "once the run ends the footer must stop being sticky and sit in the bubble, saw position: " + footerPosition);
    check(!!footer && footer.parentNode === body,
      "the footer must be a child of the bubble's body, saw parent: "
      + (footer && footer.parentNode ? footer.parentNode.tagName + "." + (footer.parentNode.className || "") : "none"));
    check(!!footer && /\d+:\d\d/.test(footer.textContent),
      "the footer must carry the run's time, saw: "
      + (footer ? footer.textContent : "nothing"));

    // A turn that changed files puts a diff topic below the answer, so the footer has to survive
    // that too. This is the case the first version of this check did not cover, and the one reported
    // from the running window as "not showing its status at the very bottom after the final answer".
    window.handleEvent({ type: "status", text: "placement check: a turn with changes" });
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "delta", text: "an answer that changed a file" });
    window.handleEvent({ type: "reply", text: "an answer that changed a file.", message_id: "placement-with-diff",
      changes: { added: 2, removed: 1, files: [{ path: "ui/app.js", added: 2, removed: 1, created: false, recorded: true }] } });
    window.handleEvent({ type: "done" });
    var changedBubbles = messages.querySelectorAll("wa-message.assistant");
    var changedBubble = changedBubbles[changedBubbles.length - 1];
    var changedKids = changedBubble.body.children;
    var changedLast = changedKids[changedKids.length - 1];
    check(!!changedLast && changedLast.classList.contains("chat-content-run-status")
      && changedLast.classList.contains("finished"),
      "with a diff in the turn the footer must still be the bubble's last child, saw: "
      + Array.prototype.map.call(changedKids, function (c) { return c.tagName + "." + (c.className || ""); }).join(", "));
    // The live node replies twice in one run: a preamble, then the answer that carries the diff
    // (agent.lua emits a plain reply, then one with changes). The diff is appended on that second
    // reply, so this is the order a reader actually sees - the case reported from the window as
    // "I only see file changed at the very bottom of the bubble".
    window.handleEvent({ type: "status", text: "placement check: two replies, diff on the second" });
    window.handleEvent({ type: "round", n: 1 });
    window.handleEvent({ type: "delta", text: "a preamble" });
    window.handleEvent({ type: "reply", text: "a preamble.", message_id: "two-reply-1" });
    window.handleEvent({ type: "delta", text: " and then the answer" });
    window.handleEvent({ type: "reply", text: " and then the answer.", message_id: "two-reply-2",
      changes: { added: 3, removed: 1, files: [{ path: "lua/core/agent.lua", added: 3, removed: 1, created: false, recorded: true }] } });
    window.handleEvent({ type: "done" });
    var twoBubbles = messages.querySelectorAll("wa-message.assistant");
    var twoBubble = twoBubbles[twoBubbles.length - 1];
    var twoKids = twoBubble.body.children;
    var twoLast = twoKids[twoKids.length - 1];
    check(!!twoLast && twoLast.classList.contains("chat-content-run-status"),
      "with two replies and a diff, the footer must still be last in the bubble, saw: "
      + Array.prototype.map.call(twoKids, function (c) { return c.tagName + "." + (c.className || ""); }).join(", "));
    check(!!twoLast && getComputedStyle(twoLast).position === "static",
      "and it must have stopped being sticky, saw: " + (twoLast ? getComputedStyle(twoLast).position : "none"));
    check(twoBubble.querySelectorAll("wa-diff").length === 1,
      "the diff must be one topic in that bubble, saw: " + twoBubble.querySelectorAll("wa-diff").length);
  })();
  // `/merge` is a brief for the agent, not a node operation: it must actually send the
  // orchestrator brief as a turn, and name the skill that holds the procedure, or the command is a
  // label with nothing behind it. Run last on purpose: it opens a real run, and a run left in the
  // transcript is state the other checks would read.
  await (async function () {
    var mergeInput = window.__commandInput();
    window.__typeCommand("/merge");
    mergeInput.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    // `send()` awaits /health before it posts, so the request is not in __calls yet: the turn has
    // to be drained before it is read. Reading it synchronously is how this check came to fail
    // against a command that was working - the POST simply had not happened yet.
    for (var mergeDrain = 0; mergeDrain < 20; mergeDrain += 1) await tick();
    var merged = (window.__calls || []).filter(function (call) {
      return String(call.url).indexOf("chat") >= 0 && call.method === "POST";
    }).pop();
    check(!!merged, "commands: running /merge must send a turn");
    check(!!merged && String(merged.body).indexOf("git-orchestrator") >= 0,
      "commands: the /merge brief must name the orchestrator skill, got: " + (merged && merged.body));
  })();
  document.title = "stage: end";
} catch (error) {
    // A throw must still produce a log: a reporter that swallows its own failure is worse
    // than none, and "the harness did not run" is a symptom with no cause.
    problems.push("the harness threw: " + ((error && error.stack) || error));
  }
  document.title = "stage: logging";
  if (!problems.length) {
    // Carry this page's verdict into a second real navigation. The next load gets an
    // unfinished session and an active /health response from fixtures.js before app.js boots.
    localStorage.setItem("wa-chat-session", "eeeeeeee-0000-0000-0000-000000000005");
    sessionStorage.setItem("wa-ui-reload-stage", "active");
    location.reload();
    return;
  }
  var log = document.createElement("pre");
  log.id = "harness-log";
  log.textContent = problems.length ? ("UI FAIL: " + problems.join(" ;; ")) : "UI PASS";
  log.style.cssText = "position:fixed;top:0;left:0;z-index:99;background:#000;color:#0f0;font:12px monospace;padding:6px";
  document.body.appendChild(log);
})();
</script>
'@
$index = Join-Path $tmp "index.html"
$fixtures = Get-Content -Raw (Join-Path $PSScriptRoot "../ui/test-fixtures.js")
Set-Content -Path (Join-Path $tmp "fixtures.js") -Value $fixtures -NoNewline
$html = Get-Content -Raw $index
# Fixtures load first: app.js reads them as it starts.
$html = $html.Replace('<script src="app.js"></script>', '<script src="fixtures.js"></script>' + "`n" + '<script src="app.js"></script>')
Set-Content -Path $index -Value $html -NoNewline

Set-Content -Path $index -Value ((Get-Content -Raw $index).Replace("</body>", $harness + "</body>")) -NoNewline

# app.js keeps handleEvent module-scoped; expose it for the harness.
$app = Join-Path $tmp "app.js"
Add-Content -Path $app -Value "`nwindow.handleEvent = handleEvent; window.isConnectionLoss = isConnectionLoss; window.connectionMessage = connectionMessage; window.rendererReady = () => !!renderer; window.renderContext = renderContext; window.__applyUiVersion = applyUiVersion; window.__native = native; window.__openControl = openControl; window.__renameNode = saveNodeName; window.__setReload = (fn) => { reload = fn; }; window.__uiVersion = () => version; window.__setBusy = setBusy; window.__setLiveness = setLiveness; window.__stopLiveness = stopLiveness; window.__setShell = (shell) => { native = shell; }; window.__rememberPlace = rememberPlace; window.__restorePlace = restorePlace; window.__restoreSession = restoreSession; window.__watchTurn = watchTurn; window.__loadTopic = loadTopic; window.__reloadTopics = reloadTopics; window.__reconcile = reconcile; window.__clearStreamNotice = clearStreamNotice; window.__attachMany = (n) => { attachments.length = 0; for (let i = 0; i < n; i += 1) attachments.push({ kind: 'image', name: 'shot-' + i + '.png', data: 'data:image/png;base64,iVBORw0KGgo=' }); renderAttachments(); }; window.__commandInput = () => input; window.__commandMenu = () => commandMenu; window.__typeCommand = (value) => { input.value = value; input.dispatchEvent(new Event('input')); }; window.__chatThread = () => chatSession; window.__composed = (text) => composedBody(text); window.__cancelActiveRun = cancelActiveRun; window.__setToolAge = (s, b) => { if (trace) trace.setAge(s, b); }; window.__toolTickerActive = () => !!toolTicker; window.__updateNotice = updateNotice; window.__refreshOperationProgress = refreshOperationProgress;"

Add-Content -Path $app -Value "`nwindow.__resetFollow = () => { followedSeq = 0; lastFollowAt = 0; };"

$server = $null
$edge = @(
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { Write-Host "  !  no Edge or Chrome found"; exit 1 }

# A server left behind by an interrupted run serves an *old* temp copy of the UI, so the harness would
# test the wrong page and report on it - which is worse than not running at all. It happened: a stale
# server on this port meant the page had no harness and no fixtures, the dump was the unpatched
# markup, and the run looked like a broken test rather than a stale one.
$busy = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
if ($busy) {
  Write-Host "  !  port $Port is already in use by pid $($busy.OwningProcess)"
  Write-Host "     that is probably a previous run's server, and it would serve an old copy of the UI"
  Write-Host "     stop it and run again:  Stop-Process -Id $($busy.OwningProcess)"
  exit 1
}

$runtimeEnvironment = @{}
foreach ($entry in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'WASM_AGENT_*' -or $_.Name -eq 'WA_SCRIPT' })) {
  $runtimeEnvironment[$entry.Name] = $entry.Value
  [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
}
$env:WASM_AGENT_HOME = Join-Path $tmp 'home'
try {
  $server = Start-Process -FilePath $WaExe -ArgumentList @("serve", "--db", $db, "--port", "$Port", "--client-port", "$ClientPort", "--ui", $tmp) -WindowStyle Hidden -PassThru
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    try { if ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:$Port/health").StatusCode -eq 200) { break } } catch { }
  }
  # Native commands write to stderr even on success, and under
  # $ErrorActionPreference = "Stop" that aborts the script - the same trap that
  # made a failing ssh look like a dead host.
  $previous = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    # The renderer's WASM initialization and second navigation are asynchronous.
    # A load-only dump can stop at "stage: start" before the harness has a verdict.
    # Isolate the browser profile as well as the server; never reuse user storage.
    $profile = Join-Path $tmp 'browser-profile'
    $dump = & $edge --headless=new --disable-gpu --virtual-time-budget=10000 "--user-data-dir=$profile" --dump-dom "http://127.0.0.1:$Port/" 2>$null | Out-String
  } finally { $ErrorActionPreference = $previous }
  $match = [regex]::Match($dump, '<pre id="harness-log"[^>]*>([\s\S]*?)</pre>')
  if (-not $match.Success) {
    $debug = Join-Path $env:TEMP "wa-ui-dump.html"
    Set-Content -Path $debug -Value $dump
    Write-Host "  !  the harness did not run (no log in the DOM dump)" -ForegroundColor Red
    Write-Host ("     dump written to " + $debug + " (" + $dump.Length + " chars; logged=" + ($dump -match "harness-log") + ")")
    exit 1
  }
  $result = $match.Groups[1].Value.Trim()
  if ($result -eq "UI PASS (real mid-run reload)") {
    Write-Host "  ok   UI structure, interrupted tools, and a real mid-run page reload" -ForegroundColor Green
  } else {
    Write-Host "  FAIL $result" -ForegroundColor Red
    exit 1
  }
} finally {
  if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  Remove-Item Env:WASM_AGENT_HOME -ErrorAction SilentlyContinue
  foreach ($key in $runtimeEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $runtimeEnvironment[$key], 'Process') }
  $resolvedTmp = [IO.Path]::GetFullPath($tmp)
  $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedTmp.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
      [IO.Path]::GetFileName($resolvedTmp) -match '^wa-ui-test-[0-9a-f]{8}$') {
    Remove-Item -LiteralPath $resolvedTmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}
