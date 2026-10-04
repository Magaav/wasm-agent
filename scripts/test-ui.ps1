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
  [string]$WaExe = "",
  [string]$UiDirectory = ""
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
if (-not $WaExe) {
  $candidate = Join-Path $root 'rust/target/release/wa.exe'
  $WaExe = if (Test-Path -LiteralPath $candidate) { $candidate } else { Join-Path $env:LOCALAPPDATA 'wasm-agent/wa.exe' }
}
$ui = if ($UiDirectory) { [IO.Path]::GetFullPath($UiDirectory) } else { Join-Path $root "ui" }
if (-not (Test-Path (Join-Path $ui "index.html"))) { Write-Host "  !  no ui/ in $root"; exit 1 }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("wa-ui-test-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$db = Join-Path $tmp "ui-test.db"
foreach ($name in @("index.html", "style.css", "app.js", "components.js", "render.wasm", "manifest.webmanifest", "service-worker.js", "icon-192.png", "icon-512.png")) {
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
  // THE INSPECTOR WINDOW. `?view=inspect` is the chat *itself* in a window of its own, and the one thing
  // that makes it an inspector rather than a DOM panel is that the page leaves the browser's own context
  // menu alone: Chrome's `Inspect element` lives in that menu. A shell is installed here, exactly as in
  // the main stage, because the rule only means anything for a page that HAS a shell.
  if (new URLSearchParams(location.search).get("view") === "inspect") {
    window.__setShell(window.__makeShell());
    await window.rendererLoaded;
    for (var inspectTick = 0; inspectTick < 200 && !document.body.classList.contains("expanded"); inspectTick++) await tick();
    check(document.body.classList.contains("expanded") && !document.body.classList.contains("view-only"),
      "the inspector must show the chat itself, not a stripped view, saw body: " + document.body.className);
    check(!!document.getElementById("input") && !!document.getElementById("steer") && !!document.getElementById("attach"),
      "the inspector must open the furniture it is there to inspect, saw composer: " + !!document.getElementById("input")
        + " steer: " + !!document.getElementById("steer") + " append-file: " + !!document.getElementById("attach"));
    var inspectMenuEvent = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 20, clientY: 20 });
    var inspectSwallowed = !document.dispatchEvent(inspectMenuEvent);
    check(!inspectSwallowed && inspectMenuEvent.defaultPrevented === false,
      "the inspector must leave the browser's own context menu alone - Chrome's Inspect element is in it");
    check(!document.getElementById("context-menu").hasAttribute("open"),
      "and the app's own menu must not be drawn in the inspector in its place");
    check(window.__shellCalls.filter(function (call) { return call.call === "openView"; }).length === 0,
      "the inspector window must not open a second window of its own, saw " + JSON.stringify(window.__shellCalls));
    // A second window that posted a turn or started a run would be a second client of the same
    // conversation, which is the opposite of "look at it without disturbing it". The read count is
    // asserted first, so an instrument that recorded nothing cannot pass this by being empty.
    var inspectCalls = window.__calls || [];
    var inspectPosts = inspectCalls.filter(function (call) {
      if (call.method !== "POST") return false;
      // Owner-scoped discovery is a read even though its transport is POST.
      return !(call.url === 'subagents' && JSON.parse(call.body || '{}').action === 'lookup_session');
    });
    check(inspectCalls.length > 0,
      "the inspector must have read from the node, saw " + inspectCalls.length + " call(s)");
    check(inspectPosts.length === 0,
      "the inspector must only read: no POST may come from it, saw " + JSON.stringify(inspectPosts.slice(0, 3)));
    var inspectLog = document.createElement("pre");
    inspectLog.id = "harness-log";
    inspectLog.textContent = problems.length ? ("UI FAIL: " + problems.join(" ;; ")) : "UI PASS (inspect window)";
    document.body.append(inspectLog);
    return;
  }
  // A VIEW WINDOW THAT IS NOT THE INSPECTOR. Every other view is this app's own page too, so it draws this
  // app's own right-click menu - and it does not offer `inspect`, because `openInspectWindow` refuses to open
  // a window from inside a view. The rule was changed for every view once; this is the stage that says so.
  if (new URLSearchParams(location.search).get("view") === "orchestrator") {
    window.__setShell(window.__makeShell());
    await window.rendererLoaded;
    for (var viewTick = 0; viewTick < 200 && !document.body.classList.contains("view-only"); viewTick++) await tick();
    check(document.body.classList.contains("view-only"),
      "an orchestrator view must be a view page, saw body: " + document.body.className);
    var viewMenuEvent = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 20, clientY: 20 });
    var viewSwallowed = !document.dispatchEvent(viewMenuEvent);
    check(viewSwallowed && viewMenuEvent.defaultPrevented === true,
      "a view window that is not the inspector must still draw this app's own menu, saw prevented=" + viewMenuEvent.defaultPrevented);
    var viewItems = (document.getElementById("context-menu").items || []).map(function (item) { return item.label || (item.separator ? "---" : ""); });
    check(viewItems.join(",") === "Collapse to avatar,Reload window,---,Close wasm-agent",
      "and it must be the menu it held before the inspector existed, saw " + JSON.stringify(viewItems));
    var viewLog = document.createElement("pre");
    viewLog.id = "harness-log";
    viewLog.textContent = problems.length ? ("UI FAIL: " + problems.join(" ;; ")) : "UI PASS (view window)";
    document.body.append(viewLog);
    return;
  }
  // The provider, reasoning and model controls have one renderer now (renderControls): they are
  // three views of one settings payload, so the harness draws them through it - and through the two
  // it replaced when this page is an older app.js, so a case added for it fails on the behaviour
  // rather than on a missing function.
  var renderControls = function () {
    if (typeof window.renderControls === "function") return window.renderControls();
    window.renderProviders(); window.renderModels();
  };
  if (sessionStorage.getItem("wa-ui-startup-stage") === "active") {
    sessionStorage.removeItem("wa-ui-startup-stage");
    for (var initial = 0; initial < 200 && window.__failSessionReads > 0; initial++) await tick();
    check(window.__failSessionReads === 0, "startup must begin transcript restore without renderer or version");
    window.__failVersion = false;
    window.__expireRecoveryBackoff();
    await window.__watch();
    for (var attempt = 0; attempt < 200 && !document.getElementById("messages").textContent.includes("RELOAD-MID-RUN-QUESTION"); attempt++) await tick();
    check(window.__modelsRejected > 0, "startup fixture must fail the model catalogue");
    check(document.getElementById("messages").textContent.includes("RELOAD-MID-RUN-QUESTION"),
      "an idle startup must retry its transcript even when /models fails");
    check(!window.__calls.some(function (call) { return call.url === "chat" && call.method === "POST"; }),
      "an unrecorded tool call must not be started again by automatic recovery");
    window.__failModels = false;
    window.__expireRecoveryBackoff();
    await window.__ensureMeta();
    check(!document.getElementById("chip-model").textContent.includes("retrying"),
      "model metadata must recover after a transient startup failure");
    var recovered = null;
    try {
      recovered = window.__repaintMessages([
        { seq: 1, role: "assistant", content: "", tool_calls: [null] },
        { seq: 2, role: "user", content: "AFTER-BAD-ROW" }
      ]);
    } catch (error) { /* a broken per-row catch is what this assertion detects */ }
    check(recovered?.failed === 1 && document.getElementById("messages").textContent.includes("AFTER-BAD-ROW"),
      "one malformed ledger row must not stop the rest of startup repaint");
    var startupLog = document.createElement("pre");
    startupLog.id = "harness-log";
    startupLog.textContent = problems.length ? ("UI FAIL: " + problems.join(" ;; ")) : "UI PASS (reload and startup recovery)";
    document.body.append(startupLog);
    return;
  }
  if (sessionStorage.getItem("wa-ui-reload-stage") === "active") {
    // This is a real second navigation, not a second call to restoreSession in the old page.
    // The fixture was installed before app.js loaded, just as a live /session response is.
    sessionStorage.removeItem("wa-ui-reload-stage");
    var loadedAt = performance.now();
    await window.rendererLoaded;
    check(window.__failModels === true && window.__modelsRejected > 0,
      "reload fixture must fail a real model catalogue request");
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
    // The device-local notification choice, read back after a real navigation. This is the whole point
    // of keeping it in this window's storage rather than in a node setting: a reload is what a device
    // does, and the choice has to be there afterwards, showing its state.
    check(localStorage.getItem("wa.notify.settlement") === "on" &&
      document.getElementById("notify-bell").checked === true &&
      document.getElementById("notify-state").textContent === "on for this device",
      "the device-local bell must survive a real reload, saw: " + localStorage.getItem("wa.notify.settlement") +
      " / " + document.getElementById("notify-state").textContent);
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
    // The active run cannot yet have a final duration. Earlier settled and interrupted runs can.
    var repaintedBubbles = restored.querySelectorAll("wa-message.assistant");
    var repaintedBubble = repaintedBubbles[repaintedBubbles.length - 1];
    check(!repaintedBubble?.body.querySelector(":scope > .chat-content-run-status.finished"),
      "a running replay must not claim its duration is final");
    var earlierAnswer = Array.from(repaintedBubbles).find(function (bubble) {
      return bubble.textContent.includes("EARLIER-FINISHED-ANSWER");
    });
    var earlierFooter = earlierAnswer?.body.querySelector(":scope > .chat-content-run-status.finished");
    check(!!earlierFooter && earlierFooter.textContent.includes("0:05"),
      "every answered run must keep its duration after reload, saw: "
      + (earlierFooter ? earlierFooter.textContent : "no footer"));
    var interrupted = Array.from(repaintedBubbles).find(function (bubble) {
      return bubble.textContent.includes("EARLIER-REASONING");
    });
    var interruptedFooter = interrupted?.body.querySelector(":scope > .chat-content-run-status.finished");
    check(!!interruptedFooter && /unfinished/.test(interruptedFooter.textContent) &&
      interruptedFooter.textContent.includes("0:03"),
      "an interrupted historical bubble must show its recorded duration without claiming completion");
    var finished = Array.from(repaintedBubbles).find(function (bubble) {
      return bubble.textContent.includes("FINISHED-ANSWER") &&
        !bubble.textContent.includes("EARLIER-FINISHED-ANSWER");
    });
    check(!!finished?.body.querySelector(":scope > .chat-content-run-status.finished") &&
      finished.body.textContent.includes("0:04"),
      "the later answered run must retain its own four-second footer");

    // The stream belongs to the old page, so the new page must notice the node-thread become idle
    // and repaint the answer from the durable ledger, not open the engine's session view.
    window.__fixtures.session.state = { state: "answered", detail: "the last message is a reply" };
    // `messages`, not `turns`: the wire key was renamed (10326b4 renamed it in the fixtures and in
    // app.js, which reads payload.messages) and this stage was left pushing into a field nothing
    // defines. A stage that throws asserted nothing - and reported itself as `FAIL the harness threw`
    // for every later run, which is how a dead assertion hides.
    window.__fixtures.session.messages.push(
      { seq: 7, role: "tool", tool_call_id: "reload-tool", tool_name: "bash", content: "done", created_at: 1790000013, tool_calls: [] },
      { seq: 8, role: "assistant", content: "RELOAD-MID-RUN-ANSWER", created_at: 1790000014, tool_calls: [] });
    window.__fixtures.health.current = null;
    window.__fixtures.health.node_threads = [];
    await window.__watchTurn();
    for (var settled = 0; settled < 100; settled++) await tick();
    check(restored.textContent.includes("RELOAD-MID-RUN-ANSWER"),
      "when the turn ends, the reloaded chat must show the ledger's answer");
    check(!restored.querySelector(".unfinished-notice") && !restored.querySelector("wa-trace .pending"),
      "the pending notice and tool state must disappear after settlement");
    check(!document.getElementById("sessions-box").textContent.includes("RELOAD-MID-RUN-ANSWER"),
      "the answer belongs in chat, not in a switched engine view");
    var finalAnswer = Array.from(restored.querySelectorAll("wa-message.assistant")).find(function (bubble) {
      return bubble.textContent.includes("RELOAD-MID-RUN-ANSWER");
    });
    check(!!finalAnswer?.body.querySelector(":scope > .chat-content-run-status.finished") &&
      /completed/.test(finalAnswer.body.textContent) && finalAnswer.body.textContent.includes("0:04"),
      "the settled final run must show its duration and completed state");
    // A saved interim answer followed by a tool result is still unfinished if the node says so.
    // The live DeepSeek run exposed the contradiction: its bubble said completed above a stopped notice.
    window.__fixtures.session.messages.pop();
    window.__fixtures.session.state = {
      state: "unfinished", role: "tool", seq: 7, pending: [], at: 1790000013,
      detail: "stopped after a tool result with no next step",
    };
    var step = window.__fixtures.session.messages.find(function (row) { return row.seq === 6; });
    step.tool_calls.push({ id: "missing-sibling", type: "function", function: { name: "bash", arguments: "{}" } });
    window.__fixtures.session.state.pending = ["bash"];
    await window.__restoreSession();
    check(!window.__calls.some(function (call) { return call.url === "chat" && call.method === "POST"; }),
      "a tool result with an unrecorded sibling must wait for inspection");
    step.tool_calls.pop();
    window.__fixtures.session.state.pending = [];
    window.__typeCommand("saved draft");
    window.__attachMany(1);
    await window.__restoreSession();
    // Automatic continuation now has its own immediate progress balloon. Inspect
    // the last recorded tool turn, rather than mistaking that new balloon for it.
    var stopped = Array.from(restored.querySelectorAll("wa-message.assistant")).reverse()
      .find(function (bubble) { return !!bubble.querySelector('wa-trace'); });
    var stoppedFooter = stopped?.body.querySelector(":scope > .chat-content-run-status.finished");
    check(!!stoppedFooter && /unfinished/.test(stoppedFooter.textContent) &&
      stoppedFooter.textContent.includes("0:03") && !/completed/.test(stoppedFooter.textContent),
      "a stopped final run must show its recorded duration without a false completed claim");
    for (var resumeTick = 0; resumeTick < 100 && !window.__calls.some(function (call) { return call.url === "chat" && call.method === "POST"; }); resumeTick++) await tick();
    var autoPosts = window.__calls.filter(function (call) { return call.url === "chat" && call.method === "POST"; });
    var autoBody = autoPosts.length ? JSON.parse(autoPosts[0].body) : {};
    check(autoPosts.length === 1 && autoBody.thread === window.__fixtures.session.session.id &&
      autoBody.resume_seq === 7 && autoBody.text === "continue where you stopped" && !autoBody.images,
      "a complete recorded tool batch must post one guarded continuation to its own thread");
    check(window.__commandInput().value === "saved draft",
      "automatic recovery must preserve the reader's unsent draft");
    await window.__restoreSession();
    check(window.__calls.filter(function (call) { return call.url === "chat" && call.method === "POST"; }).length === 1,
      "a second transcript repaint must not post a duplicate continuation");
    if (problems.length) {
      var reloadLog = document.createElement("pre");
      reloadLog.id = "harness-log";
      reloadLog.textContent = "UI FAIL: " + problems.join(" ;; ");
      document.body.append(reloadLog);
      return;
    }
    sessionStorage.setItem("wa-ui-startup-stage", "active");
    location.reload();
    return;
  }
  // The tools topic is a selected preview, never an observed provider request.
  await refreshTools();
  var preview = document.querySelector('#tools-box .request-preview');
  check(!!preview && /not a model request/.test(preview.querySelector('summary').textContent) &&
    /"model": "fixture-model"/.test(preview.querySelector('pre').textContent) &&
    !/"messages"/.test(preview.querySelector('pre').textContent),
    'the selected tool/configuration preview must not claim to be an exact request');
  check(window.__calls.some(function (call) { return call.url === 'model-configuration-preview'; }) &&
    !window.__calls.some(function (call) { return call.url === 'envelope'; }),
    'the tools topic reads the preview route, not the legacy envelope route');
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
  // A job's controls are on the surface: shown with their values, and settable. The store is the only
  // judge of them, so a refusal has to come back in its own words rather than as a quiet repaint.
  var controlFields = function () { return Array.prototype.slice.call(document.querySelectorAll("wa-jobs .job-control input")); };
  var controlButton = function () { return document.querySelector("wa-jobs .job-controls button"); };
  var controlPosts = function () { return window.__calls.filter(function (call) { return call.url === "jobs" && call.method === "POST" && call.body.indexOf("controls") >= 0; }); };
  check(controlFields().length === 2 && controlFields()[0].value === "300" && controlFields()[1].value === "600", "a declared control is shown with its value");
  check(document.querySelectorAll("wa-jobs input[type=checkbox]").length === 2, "a control field is not mistaken for a job toggle");
  controlFields()[1].value = "120";
  controlButton().click();
  for (var ctick=0;ctick<30;ctick++) await tick();
  var sentControls = controlPosts();
  var sentBody = sentControls.length ? JSON.parse(sentControls[0].body) : {};
  check(sentControls.length === 1 && sentBody.action === "controls" && sentBody.controls.grace_seconds === 300 && sentBody.controls.max_age_seconds === 120, "a control change posts the numbers the fields hold");
  check(controlFields()[1].value === "120" && document.querySelectorAll("wa-jobs input[type=checkbox]")[1].checked === false, "an accepted control edit is displayed as the store left the job");
  controlFields()[0].value = "";
  controlButton().click();
  for (var ctick=0;ctick<30;ctick++) await tick();
  var emptied = controlPosts();
  check(emptied.length === 2 && JSON.parse(emptied[1].body).controls.grace_seconds === null, "an empty control field sends null rather than a zero nobody typed");
  window.__fixtures.controlsRefuse = true;
  controlFields()[1].value = "900";
  controlButton().click();
  for (var ctick=0;ctick<30;ctick++) await tick();
  check(controlButton().disabled === false && document.getElementById("jobs-box").textContent.indexOf("job_control_grace_exceeds_max_age_seconds") >= 0, "a refused control change is reported in the store's words and leaves the button usable");
  window.__fixtures.controlsRefuse = false;
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
    return c.tagName === "WA-TRACE" ? "trace" : (c.tagName === "WA-STEP" ? "phase" : "text");
  }).filter(function (item) { return item !== "phase"; }).join(",") : "";
  check(inner === "text,trace,text,trace", "expected text,trace,text,trace inside the run, saw " + inner);

  var runMeta = run ? run.querySelector(".trace-meta") : null;
  var runText = runMeta ? runMeta.textContent : "";
  check(runText.indexOf("2 tool calls") >= 0, "the run topic should total its tool calls, saw: " + runText);
  check(runText.indexOf("7 steps") >= 0 && runBody.querySelectorAll('wa-step').length === 5,
    "the run topic should count its text and observed phase steps, saw: " + runText);

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
  window.renderUsage(); renderControls();
  var savedModelSettings = settings;
  settings = Object.assign({}, settings, {provider:'openai-sub',model:'gpt-6-luna',
    providers:[{id:'openai-sub',label:'OpenAI subscription',auth:'subscription',configured:true,
      models:['gpt-6-luna','gpt-6-sol','gpt-6-astra']}]});
  renderControls();
  check(document.getElementById('provider-select').selectedOptions[0].textContent==='OpenAI subscription',
    'a configured subscription is shown without an API-key requirement');
  check(document.getElementById('model-select').value==='gpt-6-luna' &&
    document.getElementById('model-select').options.length===3,
    'the subscription picker offers the GPT-6 family and selects Luna');
  var statusBalloon=document.getElementById('status-balloon');
  var statusButton=document.getElementById('status-btn');
  statusButton.click();
  check(statusBalloon.open && statusButton.getAttribute('aria-expanded')==='true',
    'status button opens the balloon for settings changes');
  window.__fixtures.model=Object.assign({},settings,{model:'gpt-6-sol'});
  var modelPicker=document.getElementById('model-select');
  modelPicker.value='gpt-6-sol'; modelPicker.dispatchEvent(new Event('change'));
  for(var modelTick=0;modelTick<20;modelTick++) await tick();
  check(window.__calls.some(c=>c.url==='model' && c.method==='POST' && c.body==='gpt-6-sol') &&
    modelPicker.value==='gpt-6-sol','model selection must persist the chosen model');
  // A native dropdown may deliver a pointerup without a document pointerdown for its option.
  document.dispatchEvent(new PointerEvent('pointerup',{bubbles:true}));
  check(statusBalloon.open && statusButton.getAttribute('aria-expanded')==='true',
    'choosing a model must not dismiss the status balloon on an unmatched release');
  delete window.__fixtures.model;
  settings.providers[0].configured=false;
  renderControls();
  check(document.getElementById('provider-select').textContent.includes('login in Pi'),
    'a missing subscription login points to Pi');
  settings=savedModelSettings;
  renderControls();
  // A stale Go model must remain visible, not masquerade as the first choice.
  settings=Object.assign({},savedModelSettings,{provider:'opencode-go',model:'gpt-6-sol',
    model_error:'model_not_servable: choose a supported Go model',
    providers:[{id:'opencode-go',label:'opencode-go',configured:true,models:['deepseek-v4.1-flash']}],
    reasoning:{supported:false,levels:[],selected:'provider'}});
  renderControls();
  check(modelPicker.value==='gpt-6-sol' && modelPicker.selectedOptions[0].disabled &&
    /unavailable on this route/.test(modelPicker.selectedOptions[0].textContent),
    'stale Go selection stays visible instead of silently showing DeepSeek');
  check(/model_not_servable/.test(document.getElementById('settings-error').textContent),
    'stale model refusal is visible before the next failed chat');
  window.__fixtures.model=Object.assign({},settings,{model:'deepseek-v4.1-flash',model_error:null,
    reasoning:{supported:true,levels:['low','high','max'],selected:'high'}});
  modelPicker.value='deepseek-v4.1-flash'; modelPicker.dispatchEvent(new Event('change'));
  for(var goTick=0;goTick<20;goTick++) await tick();
  var goReasoning=document.getElementById('reasoning-select');
  check(modelPicker.value==='deepseek-v4.1-flash' && !goReasoning.disabled &&
    Array.from(goReasoning.options).map(o=>o.value).join(',')==='low,high,max',
    'explicit supported Go model recovery enables catalogue reasoning');
  window.__fixtures.reasoning=Object.assign({},window.__fixtures.model,
    {reasoning:{supported:true,levels:['low','high','max'],selected:'low'}});
  goReasoning.value='low'; goReasoning.dispatchEvent(new Event('change'));
  for(var goTick=0;goTick<20;goTick++) await tick();
  check(goReasoning.value==='low' && settings.reasoning.selected==='low' &&
    document.getElementById('settings-error').textContent==='',
    'Go reasoning selection roundtrips through the status balloon');
  // The controls are drawn from the node's answer now, so the fixture has to be the node's own:
  // the refused write answered nothing about where the route is.
  var baseModelsFixture = window.__fixtures.models;
  window.__fixtures.model={error:'model_not_servable'};
  window.__fixtures.models=Object.assign({},settings,{model:'deepseek-v4.1-flash'});
  await window.setModel('gpt-6-sol');
  check(modelPicker.value==='deepseek-v4.1-flash' && goReasoning.value==='low',
    'a refused model selection leaves the controls on the node answer, not on the refused value');
  delete window.__fixtures.model;
  window.__fixtures.models=baseModelsFixture;
  window.__fixtures.reasoning={error:'unsupported_reasoning_level'};
  settings=savedModelSettings;
  renderControls();
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
  document.dispatchEvent(new PointerEvent('pointerup',{bubbles:true}));
  check(statusBalloon.open && statusButton.getAttribute('aria-expanded')==='true',
    'choosing reasoning must leave the status balloon open');
  reasoningPicker.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));
  document.dispatchEvent(new PointerEvent('pointerup',{bubbles:true}));
  check(statusBalloon.open,'a press inside a native picker released outside must stay open');
  // A settings change must be confirmed or visibly refused, never silently dropped. The defect this
  // pins is the one the operator saw: the provider select kept "OpenAI subscription" while the model
  // dropdown still listed opencode-go's ids and the LIMITS rows were opencode-go's - a pair no
  // payload from the node ever contained. The POST had failed with nothing watching it, so nothing
  // re-rendered and the select kept what the operator had chosen. The node's own answer is the only
  // truth here: a request this window aborted may still be applied by the node afterwards.
  var nodeAnswer = { provider:'opencode-go', model:'deepseek-v4.1-flash', model_error:null,
    providers:[{id:'opencode-go',label:'opencode-go',configured:true,
      models:['deepseek-v4.1-flash','longcat-2.5-preview-free']},
      {id:'openai-sub',label:'OpenAI Subscription',auth:'subscription',configured:true,
      models:['gpt-6-luna','gpt-6-sol']}],
    limits:{rolling:{percent:61,resetsAt:'2026-10-01T18:47:17.000Z'},
      weekly:{percent:54,resetsAt:'2026-10-05T00:00:00.000Z'}},
    reasoning:{supported:true,levels:['low','high','max'],selected:'high'}};
  window.__fixtures.models=nodeAnswer;
  settings=Object.assign({},settings,nodeAnswer,{limits:{rolling:{percent:7,resetsAt:'2026-10-01T19:00:00.000Z'}}});
  renderControls(); window.renderLimits(); window.renderUsage();
  var providerPicker=document.getElementById('provider-select');
  var settingsPicks=document.getElementById('model-select');
  var limitsBox=document.getElementById('limits-box');
  var settingsErrBox=document.getElementById('settings-error');
  var providerPosts=function(){ return window.__calls.filter(function(c){ return c.url==='provider' && c.method==='POST'; }); };
  check(providerPicker.value==='opencode-go' && limitsBox.textContent.indexOf('7%')>=0,
    'the case must start on the node answer, with the window showing something else for LIMITS, saw ' +
    limitsBox.textContent);
  // 1. The write is never answered. The fetch rejects the way apiFetch's own deadline aborts it -
  //    the same DOMException, delivered directly because headless virtual time does not advance the
  //    8-second timer, so waiting for the real deadline would hang the harness instead of failing it.
  window.__fixtures.settingsAbort=true;
  providerPicker.value='openai-sub'; providerPicker.dispatchEvent(new Event('change'));
  for(var abortTick=0;abortTick<60;abortTick++) await tick();
  check(providerPosts().length===1,'the provider change must reach the node, saw '+providerPosts().length);
  check(providerPicker.value==='opencode-go' && settingsPicks.value==='deepseek-v4.1-flash',
    'an unanswered settings change must leave the controls on the node answer, saw ' +
    providerPicker.value + ' / ' + settingsPicks.value);
  check(settingsPicks.textContent.indexOf('gpt-6-luna')<0 && limitsBox.textContent.indexOf('61%')>=0,
    'and the model list and LIMITS must be re-read from the same answer, saw ' + limitsBox.textContent);
  // The note is derived from the node's re-read answer, never from the write outcome alone: the
  // exact wording is part of this case, because a note that reads as a denial next to a screen that
  // shows the change is the note the operator acts on. dash is the em dash the app writes.
  var dash=String.fromCharCode(8212);
  check(settingsErrBox.textContent==='not confirmed '+dash+' no answer within 8s (the request was aborted); the node now reports opencode-go / deepseek-v4.1-flash',
    'an unanswered change must be reported as unconfirmed with the node answer, never as not applied, saw: ' +
    settingsErrBox.textContent);
  window.__fixtures.models=Object.assign({},nodeAnswer,{provider:'openai-sub',model:'gpt-6-luna'});
  await refreshMeta();
  check(providerPicker.value==='openai-sub' && settingsErrBox.textContent.includes('in effect') &&
    settingsErrBox.textContent.includes('openai-sub / gpt-6-luna'),
    'a write applied after the immediate reconciliation must update its note on a later read');
  window.__fixtures.models=nodeAnswer;
  await refreshMeta();
  // 1b. The write is never answered and the node has applied it anyway (its own queue, or another
  //     window): the screen and the note must both say what the node reports. A note derived from
  //     the write outcome alone reads as a denial here - "not applied" next to the applied pair -
  //     which is the wording the operator would act on.
  window.__fixtures.models=Object.assign({},nodeAnswer,{provider:'openai-sub',model:'gpt-6-luna'});
  settings=Object.assign({},settings,{provider:'opencode-go',model:'deepseek-v4.1-flash'});
  renderControls();
  providerPicker.value='openai-sub'; providerPicker.dispatchEvent(new Event('change'));
  for(var lateTick=0;lateTick<60;lateTick++) await tick();
  check(providerPosts().length===2 && providerPicker.value==='openai-sub' &&
    settingsPicks.value==='gpt-6-luna' && settingsPicks.options.length===2,
    'a write the node applied after the abort must show the node answer, saw ' +
    providerPicker.value + ' / ' + settingsPicks.value);
  check(settingsErrBox.textContent==='in effect '+dash+' no answer within 8s (the request was aborted); the node reports openai-sub / gpt-6-luna, which is what was asked for',
    'and the note must say it is in effect, not deny an applied change, saw: ' + settingsErrBox.textContent);
  window.__fixtures.settingsAbort=false;
  window.__fixtures.models=nodeAnswer;
  settings=Object.assign({},settings,{provider:'opencode-go',model:'deepseek-v4.1-flash'});
  renderControls();
  // 2. The node refuses the write, in its own words.
  window.__fixtures.settingsRefuse=true;
  providerPicker.value='openai-sub'; providerPicker.dispatchEvent(new Event('change'));
  for(var refuseTick=0;refuseTick<60;refuseTick++) await tick();
  check(providerPosts().length===3 && providerPicker.value==='opencode-go' &&
    settingsErrBox.textContent.indexOf('not confirmed')>=0 &&
    settingsErrBox.textContent.indexOf('settings_refused_by_fixture')>=0 &&
    settingsErrBox.textContent.indexOf('opencode-go / deepseek-v4.1-flash')>=0,
    'a refused settings change must be reported in the node words with the node answer, saw ' +
    providerPicker.value + ' / ' + settingsErrBox.textContent);
  window.__fixtures.settingsRefuse=false;
  // 3. The node accepts it and answers with its refreshed payload: the three controls move together
  //    to that one answer.
  window.__fixtures.provider=Object.assign({},nodeAnswer,{provider:'openai-sub',model:'gpt-6-luna'});
  providerPicker.value='openai-sub'; providerPicker.dispatchEvent(new Event('change'));
  for(var acceptTick=0;acceptTick<60;acceptTick++) await tick();
  check(providerPicker.value==='openai-sub' && settingsPicks.value==='gpt-6-luna' &&
    settingsPicks.options.length===2 && settingsErrBox.textContent==='',
    'an accepted settings change must be confirmed from the node answer, saw ' +
    providerPicker.value + ' / ' + settingsPicks.value);
  delete window.__fixtures.provider;
  // A delayed write belongs to its original node even if this window changes
  // destination before the acknowledgement arrives. Versions order same-node reads.
  var beforeVersionedSettings=settings, beforeSettingsNode=activeNode;
  settings=Object.assign({},settings,{settings_revision:40});
  check(acceptSettings(Object.assign({},settings,{settings_revision:39,model:'obsolete-model'}))===false &&
    settings.model!=='obsolete-model','an older settings snapshot must not overwrite a newer acknowledgement');
  var savedSettingsFetch=window.fetch, settleOldWrite=null;
  window.fetch=function(url,options){
    if(url==='provider' && options?.method==='POST') return new Promise(function(resolve){settleOldWrite=resolve;});
    return savedSettingsFetch(url,options);
  };
  var oldWrite=window.setProvider('openai-sub');
  check(!!settleOldWrite,'the stale-target case must actually hold a settings write');
  activeNode='other-fixture-node';
  settings=Object.assign({},settings,{provider:'other-provider',model:'other-model',settings_revision:2});
  settleOldWrite({ok:true,status:200,json:()=>Promise.resolve(Object.assign({},beforeVersionedSettings,
    {provider:'openai-sub',model:'gpt-6-luna',settings_revision:41}))});
  await oldWrite;
  check(settings.provider==='other-provider' && settings.model==='other-model',
    'a POST response after a node switch must not replace the new node settings');
  window.fetch=savedSettingsFetch;activeNode=beforeSettingsNode;settings=beforeVersionedSettings;
  renderControls();
  window.__fixtures.models=baseModelsFixture;
  // Turn sovereignty: a run in flight owns the settings it started with, so the pickers lock and
  // the balloon says when a change lands - a control that moves under a running turn misreports
  // what that turn actually used.
  window.setBusy(true);
  check(document.getElementById('provider-select').disabled &&
    document.getElementById('model-select').disabled &&
    document.getElementById('reasoning-select').disabled,
    'the model controls must lock while a run is in flight');
  check(/applies at the next turn/.test(document.getElementById('settings-note').textContent),
    'the balloon must say when a change applies, saw: ' +
    document.getElementById('settings-note').textContent);
  // A change during a run is refused with its note *and* reconciled, so the control must not keep
  // the value the operator moved it to. A read is not a change, so only a settings POST counts as a
  // change that was sent.
  var settingsPostCount=function(){ return window.__calls.filter(function(c){ return c.method==='POST' &&
    ['provider','model','reasoning'].indexOf(c.url)>=0; }).length; };
  var postsWhileBusy=settingsPostCount();
  var busyProvider=document.getElementById('provider-select');
  var busyNodeProvider=window.__fixtures.models.provider;
  busyProvider.value='openai-sub';
  await window.setModel('deepseek-v4.1-flash');
  check(settingsPostCount()===postsWhileBusy,
    'a settings change must not be sent while a run is in flight');
  check(busyProvider.value===busyNodeProvider,
    'a change refused during a run must leave the control on the node answer (' + busyNodeProvider +
    '), saw ' + busyProvider.value);
  check(/applies at the next turn/.test(document.getElementById('settings-error').textContent),
    'the refused change must be visible, saw: ' +
    document.getElementById('settings-error').textContent);
  window.setBusy(false);
  check(!document.getElementById('provider-select').disabled &&
    !document.getElementById('model-select').disabled,
    'the model controls must unlock when the run ends');
  check(document.getElementById('settings-note').textContent==='',
    'the note must clear when there is no run to protect');
  document.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));
  document.dispatchEvent(new PointerEvent('pointerup',{bubbles:true}));
  check(!statusBalloon.open && statusButton.getAttribute('aria-expanded')==='false',
    'a matched press and release outside still dismisses the balloon');
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

  // The showroom reuses chat elements and never owns the runs it displays.
  window.__setShell(window.__makeShell());
  document.getElementById('orchestrator-btn').click();
  check(window.__shellCalls.some(call=>call.call==='openView' && call.view==='orchestrator' && call.url.includes('view=orchestrator')),
    'the topbar must open a separate native orchestrator window');
  window.__setShell(null);
  check(!document.getElementById('drift'),'the retired Drift inner view must be removed');
  var showroom=document.createElement('wa-orchestrator');
  showroom.style.cssText='position:fixed;inset:0;width:1200px;height:800px;z-index:9999';
  document.body.append(showroom);
  var agents=Array.from({length:4},(_,i)=>({subagent_id:'tile-'+i,session_id:'session-'+i,profile:'worker',model:'fixture',reasoning:'max',execution_node:'cloud',state:'running',created_at:i,prompt:'task '+i}));
  showroom.data=agents;
  var card=showroom.sidebar.querySelector('.agent-card');
  check(card?.querySelectorAll('.agent-card-mission, .agent-card-details').length===2 &&
    card.querySelector('.agent-card-mission').textContent==='task 0' &&
    card.querySelector('.agent-card-model').textContent==='fixture · max' &&
    card.querySelector('.agent-card-status').textContent==='running',
    'each sidebar card must show mission, model and running status in two rows');
  var linkProbe=document.createElement('div');
  linkProbe.innerHTML=window.__safeLinks('<a href="javascript:alert(1)">unsafe</a><a href="https://example.com">safe</a><code>https://code.example</code> https://bare.example.');
  document.body.append(linkProbe);
  check(linkProbe.querySelectorAll('a').length===2 && !linkProbe.querySelector('a[href^="javascript"]') && !linkProbe.querySelector('code a'),'links reject executable schemes and leave code alone');
  check([...linkProbe.querySelectorAll('a')].every(a=>a.target==='_blank' && a.rel.includes('noopener')),'links isolate external destinations');
  check(getComputedStyle(linkProbe.querySelector('a')).textDecorationLine.includes('underline') && getComputedStyle(linkProbe.querySelector('a')).color==='rgb(139, 188, 255)','links are blue-ish and underlined');
  linkProbe.remove();
  var cardHeight=card.getBoundingClientRect().height;
  var lineHeight=parseFloat(getComputedStyle(card).lineHeight);
  check(cardHeight<=lineHeight*2+15,'sidebar cards must be compact two-line cards');
  showroom.data=[{...agents[0],state:'completed'},...agents.slice(1)];
  check(showroom.sidebar.querySelector('[data-state="completed"] .agent-card-status').textContent==='completed' &&
    getComputedStyle(showroom.sidebar.querySelector('[data-state="completed"]')).opacity!=='1',
    'settled cards must be distinguishable from running cards without opening them');
  showroom.data=agents;
  agents.forEach(task=>showroom.pin(task));
  check(showroom.panes.size===4,'four pinned agents must create four session panes');
  var panes=[...showroom.panes.values()];
  var firstRect=panes[0].getBoundingClientRect(), secondRect=panes[1].getBoundingClientRect(), thirdRect=panes[2].getBoundingClientRect();
  check(firstRect.width>200 && secondRect.left>firstRect.left && thirdRect.top>firstRect.top,'four panes must form a readable two by two grid');
  // The child transcript route. `POST /subagents` with `action:'session'` is the page
  // `lua/core/session_view.lua` answers (rows, a task echo, and an address for a row too large to
  // send); the stubbed fetch above answers every other subagent action, so this wraps it to add that
  // one route. Everything the checks below assert is then drawn by the production path -
  // refreshAgentPane -> panePage -> paintChildTranscript - and not by a test-only renderer hook.
  var childPages={};
  var stubFetch=window.fetch;
  window.fetch=function(input,init){
    var url=String(typeof input==='string'?input:(input&&input.url)||'');
    var path=new URL(url,location.href).pathname.replace(/^\/+|\/+$/g,'');
    if(path==='subagents'&&init&&init.method==='POST'){
      var request={};try{request=JSON.parse(init.body||'{}');}catch(error){request={};}
      if(request.action==='session'){
        // A node whose page budget is lowered (`WASM_AGENT_TOOL_OUTPUT_BYTES` lowers `MAX_BYTES`)
        // refuses a sized request exactly here, and accepts the unsized one.
        if(window.__fixtureRefuseBytes&&request.byte_limit!=null){
          return Promise.resolve({ok:true,status:200,json:function(){return Promise.resolve({error:'invalid_session_byte_limit'});},
            text:function(){return Promise.resolve('{"error":"invalid_session_byte_limit"}');}});
        }
        var page=childPages[request.id]||{session_id:'unknown',returned:0,messages:[],task:null};
        return Promise.resolve({ok:true,status:200,json:function(){return Promise.resolve(page);},
          text:function(){return Promise.resolve(JSON.stringify(page));}});
      }
    }
    return stubFetch(input,init);
  };
  panes[0].input.value='keep my draft';
  // Page one, read through the production path: the pane asks the node's route, and the app draws what
  // comes back. `tile-0` is the pane's subagent id and `session-0` its session.
  childPages['tile-0']={session_id:'session-0',returned:4,view:'full',note:'Bounded inspection only; original transcript unchanged.',
    messages:[{seq:1,role:'user',content:'hello',created_at:1,tool_calls:[]},
      {seq:2,role:'assistant',content:'',created_at:1,tool_calls:[{id:'call-0',function:{name:'read',arguments:'{"path":"a"}'}}]},
      {seq:3,role:'tool',tool_call_id:'call-0',tool_name:'read',content:'original tool evidence',created_at:2,tool_calls:[]},
      {seq:4,role:'assistant',content:'answer',created_at:3,tool_calls:[]}],
    task:{subagent_id:'tile-0',session_id:'session-0',state:'answered',settled:true,profile:'worker',model:'fixture',reasoning:'max'}};
  await window.__refreshAgentPane(panes[0]);
  check(panes[0].querySelectorAll('wa-message').length===2 &&
    panes[0].querySelector('wa-run wa-trace .tool-line').textContent.includes('read') &&
    panes[0].querySelector('wa-trace .tool-output').textContent.includes('original tool evidence'),
    'a pane must render the original messages and the tool evidence inside the shared run topic');
  check(!!panes[0].transcript.querySelector('wa-message.assistant > .body.steps > .chat-content-run-status.finished'),
    'a pane draws its run status inside the bubble body, the way the window\'s own chat does');
  // A pane is a repaint of the page the node returned, not an accumulator: a second page replaces the
  // first, exactly as the window's own chat replaces its transcript when it repaints.
  childPages['tile-0']={session_id:'session-0',returned:5,view:'full',note:'Bounded inspection only; original transcript unchanged.',
    messages:[{seq:4,role:'user',content:'next',created_at:4,tool_calls:[]},
      {seq:5,role:'assistant',phase:'commentary',content:'Checking…',created_at:4,tool_calls:[]},
      {seq:6,role:'assistant',content:'',created_at:4,reasoning:'considering',tool_calls:[{id:'call-1',function:{name:'read',arguments:'{}'}}]},
      {seq:7,role:'tool',tool_call_id:'call-1',tool_name:'read',content:'result text',created_at:5,tool_calls:[]},
      {seq:8,role:'assistant',content:'**done**',created_at:6,tool_calls:[]}],
    task:{subagent_id:'tile-0',session_id:'session-0',state:'answered',settled:true,profile:'worker',model:'fixture',reasoning:'max'}};
  await window.__refreshAgentPane(panes[0]);
  check(panes[0].querySelectorAll('wa-message').length===2 &&
    panes[0].querySelectorAll('wa-run').length===1 &&
    !!panes[0].querySelector('wa-commentary') && !!panes[0].querySelector('wa-reasoning') &&
    panes[0].querySelectorAll('wa-trace .tool-line').length===1 &&
    panes[0].querySelector('wa-trace .tool-line').classList.contains('ok') &&
    panes[0].querySelector('wa-trace .tool-output').textContent.includes('result text'),
    'agent chat must group commentary, thinking, calls and results into shared chat components');
  // The shared chat folds a successful call's payload behind its line and forces only a failure open;
  // a pane that un-hid it would be the second implementation this replaced.
  check(panes[0].querySelector('wa-trace .tool-output').hidden===true,
    'a pane must fold a successful call\'s payload exactly as the window does');
  showroom.data=agents.slice().reverse();
  check([...showroom.panes.values()][0]===panes[0] && panes[0].input.value==='keep my draft','refresh must preserve pane order and drafts');
  // Expand promotes the conversation into its own <wa-window>: a frame the reader can move, resize
  // and close, reading the same task, while the workspace pane stays where it was. It used to mean
  // "focus this one tile", which a second reader of a running child makes unnecessary.
  var expandDetail=null;
  showroom.addEventListener('agent-action',event=>{if(event.detail.action==='expand')expandDetail=event.detail;});
  panes[0].querySelector('[data-action="expand"]').click();
  var promotedFrame=document.querySelector('wa-window[name="agent-tile-0"]');
  var promotedPane=promotedFrame?promotedFrame.querySelector('wa-agent-session'):null;
  check(!!expandDetail && expandDetail.pane===panes[0],
    'expand must still be announced as an agent-action, so a host can answer it');
  check(!!promotedFrame && promotedFrame.open && !!promotedPane && promotedPane.task.subagent_id==='tile-0',
    'expand must promote this conversation into its own wa-window, reading the same task');
  check(showroom.canvas.contains(panes[0]),'promoting must leave the workspace pane where it was');
  check(panes[0].notice.textContent.indexOf('own window')>=0,
    'the pane must say it was promoted, saw: ' + panes[0].notice.textContent);
  check(!!promotedPane && promotedPane.querySelector('[data-action="expand"]').hidden===true,
    'a conversation that is already its own window must not offer to expand again');
  check(showroom.windows.size===1 && showroom.allPanes().length===5,
    'the promoted conversation must be followed as a pane, not frozen where it was opened');
  panes[0].querySelector('[data-action="expand"]').click();
  check(showroom.windows.size===1,'expanding twice must focus the frame it already has, not open another');
  promotedFrame.shadowRoot.querySelector('.close').click();
  check(!promotedFrame.open && showroom.windows.size===0,
    'closing the frame must close the promoted conversation, not the workspace pane it came from');
  promotedFrame.remove();   // leave the document as this run found it

  // LANES. The claim: the cards are grouped by the child's recorded checkout - its workspace branch,
  // else its worktree - and each lane states its end state as an outcome checklist. Driven through the
  // app's own refresh (the dispatch list and `/sessions`), so a lane key or an outcome cannot be
  // asserted against a shape the app does not use. The recorded shapes are the ones the node really
  // writes, including a released checkout (`workspaces.lua`'s release KEEPS `worktree` and sets
  // `workspace_state='released'`) and a checkout with no recorded branch name
  // (`sessions.workspace_branch TEXT NOT NULL DEFAULT ''`) - the row shape whose `main-only` outcome
  // must still be answered from the lane's own key rather than from the branch name alone.
  var lanesPanel=document.createElement('wa-orchestrator');
  lanesPanel.style.cssText='position:fixed;inset:0;width:1200px;height:800px;z-index:9998';
  document.body.append(lanesPanel);
  var laneTasks=[
    {subagent_id:'lane-child-a',session_id:'lane-session-a',profile:'worker',model:'fixture',reasoning:'max',execution_node:'local',state:'running',settled:false,created_at:1,prompt:'alpha work'},
    {subagent_id:'lane-child-a2',session_id:'lane-session-a2',profile:'worker',model:'fixture',reasoning:'max',execution_node:'local',state:'running',settled:false,created_at:2,prompt:'alpha work two'},
    {subagent_id:'lane-child-b',session_id:'lane-session-b',profile:'worker',model:'fixture',reasoning:'max',execution_node:'local',state:'running',settled:false,created_at:3,prompt:'beta work'},
    {subagent_id:'lane-child-c',session_id:'lane-session-c',profile:'worker',model:'fixture',reasoning:'max',execution_node:'local',state:'running',settled:false,created_at:4,prompt:'gamma work'},
    {subagent_id:'lane-child-d',session_id:'lane-session-d',profile:'worker',model:'fixture',reasoning:'max',execution_node:'local',state:'running',settled:false,created_at:5,prompt:'main work'}];
  var savedSubagents=window.__fixtures.subagents, savedSessions=window.__fixtures.sessions;
  window.__fixtures.subagents={subagents:laneTasks};
  window.__fixtures.sessions={sessions:[
    {id:'lane-session-a',title:'alpha',state:'unfinished',workspace_required:1,workspace_branch:'change/lane-alpha',worktree:'C:/work/wt-alpha',workspace_state:'allocated'},
    {id:'lane-session-a2',title:'alpha two',state:'unfinished',workspace_required:1,workspace_branch:'change/lane-alpha',worktree:'C:/work/wt-alpha',workspace_state:'allocated'},
    {id:'lane-session-b',title:'beta',state:'unfinished',workspace_required:1,workspace_branch:'change/lane-beta',worktree:'C:/work/wt-beta',workspace_state:'released'},
    {id:'lane-session-c',title:'gamma',state:'unfinished',workspace_required:1,workspace_branch:'',worktree:'C:/work/wt-gamma',workspace_state:'allocated'},
    {id:'lane-session-d',title:'main',state:'unfinished',workspace_required:1,workspace_branch:'',worktree:'',workspace_state:'unbound'}]};
  // The page for the pane this block pins, so the app's own refresh paints a child through
  // refreshAgentPane -> panePage -> paintChildTranscript - the seam production uses.
  childPages['lane-child-a']={session_id:'lane-session-a',returned:2,view:'full',note:'Bounded inspection only.',
    messages:[{seq:1,role:'user',content:'LANE-QUESTION',created_at:1,tool_calls:[]},
      {seq:2,role:'assistant',content:'LANE-ANSWER',created_at:2,tool_calls:[]}],
    task:{subagent_id:'lane-child-a',session_id:'lane-session-a',state:'running',settled:false,profile:'worker',model:'fixture',reasoning:'max'}};
  window.__setOrchestratorPanel(lanesPanel);
  for(var laneTry=0;laneTry<20&&lanesPanel.querySelectorAll('nav .lane').length!==4;laneTry+=1){
    await window.__refreshOrchestrator();
    for(var laneTick=0;laneTick<20;laneTick+=1) await tick();
  }
  var lanePane=lanesPanel.pin(laneTasks[0]);
  // The panel polls on its own timer, and a refresh asked for while one is in flight is skipped: ask
  // until the pane has drawn its child's page.
  for(var paneTry=0;paneTry<20&&!lanePane.transcript.textContent.includes('LANE-ANSWER');paneTry+=1){
    await window.__refreshOrchestrator();
    for(var paneTick=0;paneTick<20;paneTick+=1) await tick();
  }
  var laneGroups=[...lanesPanel.querySelectorAll('nav .lane')];
  var laneKeys=laneGroups.map(group=>group.dataset.lane).sort();
  var laneCounts=laneGroups.map(group=>group.dataset.lane+':'+group.querySelectorAll('.agent-card').length).sort();
  var laneStates=key=>{var group=laneGroups.find(item=>item.dataset.lane===key);
    return group?[...group.querySelectorAll('.lane-check')].map(item=>item.dataset.outcome+'='+item.dataset.state).join(' '):'no such lane';};
  var lanePath=key=>{var group=laneGroups.find(item=>item.dataset.lane===key);var path=group?group.querySelector('.lane-path'):null;
    return path?path.textContent:'';};
  check(laneKeys.join('|')===['C:/work/wt-gamma','change/lane-alpha','change/lane-beta','main'].sort().join('|') &&
    laneCounts.join(' ')==='C:/work/wt-gamma:1 change/lane-alpha:2 change/lane-beta:1 main:1',
    'cards must be grouped by the child\'s recorded checkout (branch, else worktree), saw ' +
    JSON.stringify(laneKeys) + ' ' + JSON.stringify(laneCounts));
  check(laneStates('change/lane-alpha')==='merged=unknown retired=no clean=unknown main-only=no' &&
    laneStates('change/lane-beta')==='merged=unknown retired=yes clean=unknown main-only=no' &&
    laneStates('C:/work/wt-gamma')==='merged=unknown retired=no clean=unknown main-only=no' &&
    laneStates('main')==='merged=unknown retired=unknown clean=unknown main-only=yes',
    'each lane\'s four outcomes must come from its own recorded checkout, saw alpha[' + laneStates('change/lane-alpha') +
    '] beta[' + laneStates('change/lane-beta') + '] gamma[' + laneStates('C:/work/wt-gamma') + '] main[' + laneStates('main') + ']');
  check(lanePath('change/lane-beta')==='C:/work/wt-beta' && lanePath('C:/work/wt-gamma')==='C:/work/wt-gamma' &&
    lanePath('main')==='',
    'a lane must show the recorded worktree it is keyed or grouped by, saw ' +
    JSON.stringify([lanePath('change/lane-beta'),lanePath('C:/work/wt-gamma'),lanePath('main')]));
  check(!!lanePane && lanePane.querySelectorAll('wa-message').length===2 &&
    lanePane.transcript.textContent.includes('LANE-ANSWER') &&
    !!lanePane.transcript.querySelector('wa-message.assistant > .body.steps'),
    'the app\'s own refresh must paint a pinned child through the production path, saw ' +
    lanePane.transcript.children.length + ' node(s) ' + lanePane.transcript.textContent.slice(0,120) +
    ' | notice: ' + lanePane.notice.textContent.slice(0,120));
  window.__setOrchestratorPanel(null);
  lanesPanel.remove();
  window.__fixtures.subagents=savedSubagents;
  window.__fixtures.sessions=savedSessions;

  // THE SHARED CHAT SHELL. A child panel is a host of the same component the main conversation is, so
  // one chat improvement - model strip, sound, file appending, send button, text area, transcript -
  // lands in one place. These checks ask both surfaces for the same furniture and read the same
  // template out of them; a hand-built second implementation fails them.
  var mainShell=document.getElementById('chat');
  var paneShell=panes[1].querySelector('wa-chat-shell');
  var shellParts=function(shell){return Array.prototype.map.call(shell.querySelectorAll('[data-part]'),function(node){return node.dataset.part;}).join(',');};
  check(!!mainShell && !!paneShell && shellParts(mainShell)==='content,host,composer,attachments,input,send,footer-left,attach,file,footer-right,model'
    && shellParts(paneShell)===shellParts(mainShell),
    'the main conversation and a child panel must both be the same shell component, saw main: '
      + (mainShell?shellParts(mainShell):'none') + ' / child: ' + (paneShell?shellParts(paneShell):'none'));
  var composerControls=function(shell){
    return shell ? { textarea:shell.querySelectorAll('.composer-row textarea').length,
      send:shell.querySelectorAll('.composer-row button[type="submit"]').length,
      attach:shell.querySelectorAll('[data-part="attach"]').length,
      file:shell.querySelectorAll('[data-part="file"]').length,
      strip:shell.querySelectorAll('.attachments').length,
      model:shell.querySelectorAll('.composer-model').length,
      picker:shell.querySelectorAll('.footer-left .chip[aria-haspopup="true"]').length>=1,
      sound:typeof shell.notify==='function' } : null;
  };
  var mainControls=composerControls(mainShell), paneControls=composerControls(paneShell);
  check(JSON.stringify(mainControls)===JSON.stringify(paneControls) && paneControls.textarea===1 &&
    paneControls.send===1 && paneControls.attach===1 && paneControls.model===1 && paneControls.picker &&
    paneControls.sound, 'a child panel must render the same composer controls the main chat does - model pick, sound, file appending, send button, text area - saw main: ' + JSON.stringify(mainControls) + ' / child: ' + JSON.stringify(paneControls));
  check(paneShell && paneShell.querySelector('.composer') && paneShell.querySelector('.composer').parentNode===paneShell,
    'a child panel must not carry a composer of its own beside the shared one');
  check(typeof paneShell.notify==='function' && typeof mainShell.notify==='function' &&
    mainShell.notify===paneShell.notify,'the notification sound must be one implementation, not one per surface');
  // Requirement: the main conversation keeps its own controls - the shared ones and the ones only it has.
  check(['messages','composer','input','send','attach','file','attachments','composer-model'].every(function(id){
    return !!document.getElementById(id) && mainShell.contains(document.getElementById(id)); }),
    'the main conversation must keep the ids its own code and tests address, inside the shared shell');
  check(!!document.getElementById('status-balloon') && mainShell.contains(document.getElementById('status-balloon'))
    && mainShell.contains(document.getElementById('status-btn')) && mainShell.contains(document.getElementById('user-btn'))
    && mainShell.contains(document.getElementById('mic')) && mainShell.contains(document.getElementById('steer')),
    'and its own credits - account, status chip and balloon, mic and Steer - anchored to the shared shell');
  check(['engine-btn','term-btn','orchestrator-btn','collapse'].every(function(id){return !!document.getElementById(id);}),
    'the main window keeps the topbar controls a child panel must not have');

  // THE ACTION ROW AND THE APPEND-FILE CONTROL ARE ONE IMPLEMENTATION. The main chat's Steer and a child
  // pane's Steer/Cancel are the same `<wa-chat-actions>` element, and every control it holds - and the
  // append-file button the shell ships - comes out of the shell's own `chatControl()` factory: one class,
  // `.chat-control`, is the whole box. The assertions are structural on purpose. Two rules that happen to
  // measure the same today is exactly what the owner forbade, so the class identity, the shared factory
  // and a freshly built pair of components are asserted beside the measurement.
  var boxOf=function(el){ if(!el) return null; var rect=el.getBoundingClientRect(), style=getComputedStyle(el);
    return {h:Math.round(rect.height),w:Math.round(rect.width),padTop:style.paddingTop,padLeft:style.paddingLeft,
      radius:style.borderRadius,border:style.borderTopWidth,cls:el.className}; };
  var paneRow=paneShell.querySelector('wa-chat-actions');
  var mainRow=mainShell.querySelector('wa-chat-actions');
  var mainSteer=document.getElementById('steer');
  var mainAttach=document.getElementById('attach');
  var paneSteer=paneRow?paneRow.querySelector('button[data-action="steer"]'):null;
  var paneAttach=paneShell.querySelector('[data-part="attach"]');
  check(!!mainRow && !!paneRow && mainRow.tagName==='WA-CHAT-ACTIONS' && paneRow.tagName==='WA-CHAT-ACTIONS'
    && mainRow.constructor===paneRow.constructor && mainRow.constructor===customElements.get('wa-chat-actions'),
    'the action row must be the one shared component on both surfaces, saw main: '
      + (mainRow?mainRow.tagName+' '+(mainRow.constructor===customElements.get('wa-chat-actions')):'none') + ' / child: '
      + (paneRow?paneRow.tagName+' '+(paneRow.constructor===customElements.get('wa-chat-actions')):'none'));
  check(!!mainSteer && !!mainAttach && !!paneSteer && !!paneAttach && mainSteer.parentElement===mainRow
    && paneSteer.parentElement===paneRow && mainRow.controls.indexOf(mainSteer)>=0,
    'the actions must be the shared row\'s own controls, saw ' +
      (mainSteer?String(mainSteer.parentElement&&mainSteer.parentElement.tagName):'no steer') + ' / ' +
      (paneSteer?String(paneSteer.parentElement&&paneSteer.parentElement.tagName):'no child steer'));
  var footerBoxes=[mainAttach,mainSteer,paneAttach,paneSteer].map(boxOf);
  check(footerBoxes.every(function(box){return box && box.cls==='chat-control';}),
    'every footer control must be the factory\'s own class, saw ' + JSON.stringify(footerBoxes.map(function(box){return box?box.cls:null;})));
  // The pane's own pair is on screen through the app's own path, so it is measured here; the main chat's
  // Steer only appears while a run is in flight, and is measured where that run is (the busy section below).
  check(!!footerBoxes[2] && footerBoxes[2].h===30 && !!footerBoxes[3] && footerBoxes[3].h===footerBoxes[2].h,
    'in a child pane the Steer control must follow the append-file control\'s height, saw '
      + JSON.stringify(footerBoxes.map(function(box){return box?box.h:null;})));
  check(footerBoxes.every(function(box){return box && box.radius===footerBoxes[0].radius
    && box.border===footerBoxes[0].border && box.padTop===footerBoxes[0].padTop;}),
    'one box means one height, border, radius and vertical padding, saw '
      + JSON.stringify(footerBoxes.map(function(box){return box?box.radius+'/'+box.border+'/'+box.padTop:null;})));
  // A shell and a row built by the components themselves, with nothing authored: the control a row makes and
  // the control a shell makes must be the same control. That is "same implementation" where two surfaces are
  // involved, and it fails on the duplicated style block the height check alone would not catch.
  var freshShell=document.createElement('wa-chat-shell');
  var freshRow=document.createElement('wa-chat-actions');
  var declaration=document.createElement('button');
  declaration.type='button'; declaration.dataset.action='steer'; declaration.textContent='Steer';
  freshRow.append(declaration);
  document.body.append(freshShell,freshRow);
  var freshAttach=freshShell.querySelector('[data-part="attach"]');
  var freshAction=freshRow.querySelector('button[data-action="steer"]');
  check(!!freshAttach && !!freshAction && freshAction.tagName===freshAttach.tagName
    && freshAction.className===freshAttach.className && freshAction.className==='chat-control'
    && boxOf(freshAttach).h===boxOf(freshAction).h && boxOf(freshAction).h===footerBoxes[0].h,
    'a shell and a row built from the components alone must produce the same control, saw '
      + (freshAttach?freshAttach.className+' '+boxOf(freshAttach).h:'none') + ' / '
      + (freshAction?freshAction.className+' '+boxOf(freshAction).h:'none'));
  freshShell.remove(); freshRow.remove();

  // BEYOND GEOMETRY: WHICH RULES MAY STATE ANYTHING ABOUT A CONTROL AT ALL. The measurements above cannot
  // tell "one rule states the box" from "the same box is stated twice with identical values" (a duplicate
  // reads as agreement), and a curated property list is only as good as the properties it remembers:
  // `margin-top` and `letter-spacing` were outside it, so one control could be nudged alone and every check
  // stayed green. So the stylesheet is read the way the browser reads it, and the assertions are about *which
  // rules* may state *anything* about one of the four controls:
  //   - the box, stated by exactly one rule (`boxAudit`), and the paint by the shared rules (`paintAudit`);
  //   - nothing else, for any property at all, unless it is the page's own global rule (`strayAudit`);
  //   - and the two same-kind controls compute *identical* styles, property for property, which is what
  //     catches a property no stylesheet sets at all (an inline style).
  // A duplicate box, a higher-specificity rule that only happens to lose today, a one-control recolour, a
  // one-control margin or a one-control letter-spacing all fail here.
  var carriesBox=function(prop){ return prop==='height'||prop==='min-width'||prop==='border-radius'||prop.indexOf('border')===0; };
  var carriesPaint=function(prop){ return prop==='color'||prop.indexOf('background')===0||prop.indexOf('font')===0; };
  var declaredProperties=function(rule){ var props=[]; for (var i=0;i<rule.style.length;i++) props.push(rule.style[i]); return props; };
  var restingSelector=function(selector){
    return String(selector).replace(/::[a-z-]+(\([^)]*\))?/gi,'')
      .replace(/:(focus-visible|focus-within|hover|active|focus|target)\b/gi,'');
  };
  var collectRules=function(el,rules,out){
    for (var i=0;i<rules.length;i++) {
      var rule=rules[i];
      // A rule that carries a selector is a style rule. Chromium gives even a style rule an (empty)
      // `cssRules`, so the selector - not `cssRules` - is what tells a style rule from a group one; a
      // group rule (media, supports, layer) is entered when its condition holds.
      if (!rule.selectorText) {
        if (rule.cssRules) collectRules(el,rule.cssRules,out);
        continue;
      }
      if (!rule.style) continue;
      var matches=false;
      try { matches=el.matches(restingSelector(rule.selectorText)); } catch (error) { matches=false; }
      if (matches) out.push({selector:rule.selectorText,props:declaredProperties(rule)});
    }
    return out;
  };
  var rulesMatching=function(el){
    var found=[];
    for (var s=0;s<document.styleSheets.length;s++) {
      var rules=null;
      try { rules=document.styleSheets[s].cssRules; } catch (error) { rules=null; }
      if (rules) collectRules(el,rules,found);
    }
    var seen=[];
    return found.filter(function(rule){ if (seen.indexOf(rule.selector)>=0) return false; seen.push(rule.selector); return true; });
  };
  var statingRules=function(el,isCarried){
    return rulesMatching(el).filter(function(rule){ return restingSelector(rule.selector)===rule.selector && rule.props.some(isCarried); }).map(function(rule){ return rule.selector; });
  };
  // The shared implementation, and the page's own globals: `* { box-sizing }` and `[hidden] { display }` are
  // about every element on the page rather than about a footer control, so the two are named here instead of
  // the property list being loosened to accommodate them.
  var SHARED_RULES=['.chat-control','.chat-control[data-label]','.chat-control:hover','.chat-control:disabled','.chat-control:disabled:hover'];
  var GLOBAL_RULES=['*','[hidden]'];
  var GLOBAL_PROPERTIES=['box-sizing','display'];
  var strayRules=function(el){
    return rulesMatching(el).filter(function(rule){
      if (SHARED_RULES.indexOf(rule.selector)>=0||GLOBAL_RULES.indexOf(rule.selector)>=0) return false;
      return rule.props.some(function(prop){ return GLOBAL_PROPERTIES.indexOf(prop)<0; });
    }).map(function(rule){ return rule.selector+'['+rule.props.join(',')+']'; });
  };
  var strayProperties=function(el){
    var owned=[];
    rulesMatching(el).forEach(function(rule){
      if (SHARED_RULES.indexOf(rule.selector)>=0) owned=owned.concat(rule.props);
    });
    var stray=[];
    rulesMatching(el).forEach(function(rule){
      if (GLOBAL_RULES.indexOf(rule.selector)>=0) return;
      rule.props.forEach(function(prop){ if (owned.indexOf(prop)<0&&stray.indexOf(prop)<0) stray.push(prop); });
    });
    return stray;
  };
  // The main chat's Steer is hidden until a run is active; unhiding it is the only thing that changes, and the
  // state is put back so the checks below see the app's own reveal.
  var steerWasHidden=mainSteer.hidden;
  mainSteer.hidden=false;
  var auditTargets=[{name:'main append-file',el:mainAttach,labelled:false},{name:'main action',el:mainSteer,labelled:true},
    {name:'child append-file',el:paneAttach,labelled:false},{name:'child action',el:paneSteer,labelled:true}];
  var boxAudit=auditTargets.map(function(target){ return target.name+' -> '+statingRules(target.el,carriesBox).join(' + '); });
  check(boxAudit.every(function(line){ return line.split(' -> ')[1]==='.chat-control'; }),
    'exactly one rule may state a footer control\'s height, border and radius - the shared .chat-control - saw '
      + JSON.stringify(boxAudit));
  var paintAudit=auditTargets.map(function(target){ return target.name+' -> '+statingRules(target.el,carriesPaint).join(' + '); });
  check(paintAudit.every(function(line,index){
      var rules=line.split(' -> ')[1].split(' + ');
      var allowed=rules.every(function(name){ return name==='.chat-control'||name==='.chat-control[data-label]'; });
      return allowed && (auditTargets[index].labelled ? rules.indexOf('.chat-control[data-label]')>=0 : rules.length===1);
    }),
    'a footer control\'s colour, background and font must come from the shared control (and, when labelled, its own variant), saw ' + JSON.stringify(paintAudit));
  var strayAudit=auditTargets.map(function(target){
    return target.name+' -> rules['+strayRules(target.el).join(' | ')+'] properties['+strayProperties(target.el).join(',')+']'; });
  check(strayAudit.every(function(line){ return /-> rules\[\] properties\[\]$/.test(line); }),
    'no rule except the shared ones may state anything at all about a footer control: a margin, a letter-spacing or any other property set on one control alone is not the shared control, saw '
      + JSON.stringify(strayAudit));
  var computedDiff=function(a,b){
    var first=getComputedStyle(a), second=getComputedStyle(b), out=[];
    for (var i=0;i<first.length;i++) {
      var name=first[i];
      if (first.getPropertyValue(name)!==second.getPropertyValue(name)) out.push(name+'('+first.getPropertyValue(name)+' vs '+second.getPropertyValue(name)+')');
    }
    return out;
  };
  var appearanceDiff={ 'main vs child action':computedDiff(mainSteer,paneSteer),
    'main vs child append-file':computedDiff(mainAttach,paneAttach) };
  check(appearanceDiff['main vs child action'].length===0 && appearanceDiff['main vs child append-file'].length===0,
    'the same kind of control must compute the same style on both surfaces, property for property - an inline style on one alone is not the shared control, saw '
      + JSON.stringify(appearanceDiff));
  mainSteer.hidden=steerWasHidden;
  // Requirement: a child panel's header is its own two controls, with the icons asked for.
  var header=panes[1].querySelector('.agent-pane-head');
  var headerButtons=header?Array.prototype.slice.call(header.querySelectorAll('button')):[];
  check(headerButtons.length===2 && headerButtons.some(function(b){return b.dataset.action==='collapse';})
    && headerButtons.some(function(b){return b.dataset.action==='expand';}),
    'the child header must hold exactly a close and an expand control, saw: '
      + headerButtons.map(function(b){return b.dataset.action||b.textContent;}).join(','));
  var closePath=panes[1].querySelector('[data-action="collapse"] svg path');
  var expandPath=panes[1].querySelector('[data-action="expand"] svg path');
  check(!!closePath && !!expandPath && closePath.getAttribute('d')==='M6 6l12 12M18 6L6 18'
    && expandPath.getAttribute('d')==='M5 5h14v14H5z',
    'close must be the x icon and expand a squared icon, saw: '
      + (closePath?closePath.getAttribute('d'):'none') + ' / ' + (expandPath?expandPath.getAttribute('d'):'none'));
  check(!panes[1].querySelector('#engine-btn, #term-btn, #orchestrator-btn, #collapse, .topbar, .topbar-btn'),
    'a child panel must not show the window controls (engine, shell, orchestrator window, collapse avatar)');

  var messageDetail;
  showroom.addEventListener('agent-action',event=>{if(event.detail.action==='message')messageDetail=event.detail;});
  panes[0].form.requestSubmit();
  var messageKey=messageDetail?.key;
  panes[0].form.requestSubmit();
  check(messageDetail?.text==='keep my draft' && messageKey===messageDetail.key,'a repeated send must retain its idempotency key');
  var steerDetail=null;
  panes[0].addEventListener('agent-action',event=>{if(event.detail.action==='steer')steerDetail=event.detail;});
  panes[0].querySelector('[data-action="steer"]').click();
  check(steerDetail?.text==='keep my draft' && !!steerDetail.key,'child steering is distinct from queued Send');
  // A bounded child page hands an oversized row back as an address. The window's own rendering path
  // draws the node's placeholder sentence for it; what it must not grow is a retrieval button the
  // main chat does not have (the exact bytes are reachable through the session tool, not from here).
  childPages['tile-0']={session_id:'session-0',returned:1,view:'full',note:'Bounded inspection only.',
    messages:[{seq:9,role:'assistant',created_at:Date.now()/1000,
      omitted:true,content:'[Oversized message: retrieve the original using evidence.]',
      evidence:{message_id:'original'},tool_calls:[]}],
    task:{subagent_id:'tile-0',session_id:'session-0',state:'answered',settled:true,profile:'worker',model:'fixture',reasoning:'max'}};
  await window.__refreshAgentPane(panes[0]);
  check(![...panes[0].transcript.querySelectorAll('button')].some(b=>b.textContent.includes('Load original message')) &&
    panes[0].transcript.textContent.includes('retrieve the original using evidence'),
    'an oversized child row must say so in the node\'s words, without a pane-only retrieval button');
  var livePane=panes[1];
  var liveStart=Date.now()/1000-65;
  // A child streams to the node, not to this window: the node reports the call in flight on the task
  // (`preview.tool`), and the production read carries it into the one renderer as `liveTool`, which is
  // how a running child shows the step it is on.
  childPages['tile-1']={session_id:'session-1',returned:2,view:'full',note:'Bounded inspection only.',
    messages:[{seq:1,role:'user',content:'Run the check',created_at:liveStart,tool_calls:[]},
      {seq:2,role:'assistant',content:'',created_at:liveStart,tool_calls:[{id:'live-call',function:{name:'bash',arguments:'{}'}}]}],
    task:{subagent_id:'tile-1',session_id:'session-1',state:'running',settled:false,profile:'worker',model:'fixture',reasoning:'max'}};
  livePane.task={...agents[1],title:'Verify live worker chat',started_at:liveStart,preview:{status:'running bash',tool:{name:'bash',call_id:'live-call',arguments:{command:'slow check'},started_at:liveStart}}};
  await window.__refreshAgentPane(livePane);
  check(livePane.querySelector('.agent-pane-head strong').textContent==='Verify live worker chat','worker heading names its task rather than profile');
  check(!!livePane.querySelector('wa-trace')?.open && livePane.querySelectorAll('.tool-line.pending').length===1,
    'running worker tool is open and deduplicated before settlement, saw trace=' + !!livePane.querySelector('wa-trace') +
    ' open=' + (livePane.querySelector('wa-trace') ? livePane.querySelector('wa-trace').open : 'n/a') +
    ' pending=' + livePane.querySelectorAll('.tool-line.pending').length +
    ' lines=' + livePane.querySelectorAll('.tool-line').length +
    ' bubbles=' + livePane.transcript.children.length);
  check(livePane.statusLine.classList.contains('chat-content-run-status') && livePane.statusLine.textContent.includes('1:05'),'each worker pane has live elapsed run status');
  var liveTrace=livePane.querySelector('wa-trace');
  liveTrace.open=false;
  livePane.task={...livePane.task,preview:{...livePane.task.preview,text:'progress arrived'}};
  check(livePane.querySelector('wa-trace')===liveTrace && liveTrace.open===false && livePane.preview.textContent.includes('progress arrived'),'a live task update must refresh the readout without rebuilding the reader\'s transcript, so their fold choice survives');
  childPages['tile-1']={session_id:'session-1',returned:4,view:'full',note:'Bounded inspection only.',
    messages:[{seq:1,role:'user',content:'Run the check',created_at:liveStart,tool_calls:[]},
      {seq:2,role:'assistant',content:'',created_at:liveStart,tool_calls:[{id:'live-call',function:{name:'bash',arguments:'{}'}}]},
      {seq:3,role:'tool',tool_call_id:'live-call',tool_name:'bash',ok:0,content:'check failed',created_at:liveStart+60,tool_calls:[]},
      {seq:4,role:'assistant',content:'Failure explained',ok:0,created_at:liveStart+65,tool_calls:[]}],
    task:{subagent_id:'tile-1',session_id:'session-1',state:'failed',settled:true,settled_at:liveStart+65,profile:'worker',model:'fixture',reasoning:'max'}};
  await window.__refreshAgentPane(livePane);
  livePane.task={...livePane.task,settled:true,state:'failed',settled_at:liveStart+65,preview:null};
  check(!livePane.querySelector('.tool-line.pending') && !!livePane.querySelector('.tool-line.err'),'worker failure settles the original live tool, saw pending=' +
    livePane.querySelectorAll('.tool-line.pending').length + ' lines=' +
    [...livePane.querySelectorAll('.tool-line')].map(line=>line.className).join('|') +
    ' text=' + livePane.transcript.textContent.slice(0,120));
  check(livePane.querySelector('wa-message[role="assistant"]').body.querySelector(':scope > .chat-content-run-status')?.textContent.includes('1:05'),'elapsed footer is inside the worker balloon');
  check(livePane.statusLine.textContent.includes('failed') && livePane.statusLine.querySelector('.spinner').hidden,'settled worker status stops its spinner');
  // THE PAGE BUDGET IS THE NODE'S. `lua/core/session_view.lua` refuses a `byte_limit` above
  // `MAX_BYTES-2048`, and `WASM_AGENT_TOOL_OUTPUT_BYTES` lowers that budget; a hard-coded request made
  // every child pane read `Conversation unavailable: invalid_session_byte_limit` with no transcript at
  // all. The stub refuses a sized request exactly as the node does and accepts the unsized one, so this
  // asserts what the fix promises: a lowered budget costs page size, never the transcript, and the pane
  // says which size it asked for and that the node refused it.
  childPages['tile-3']={session_id:'session-3',returned:2,view:'full',note:'Bounded inspection only.',
    messages:[{seq:1,role:'user',content:'BUDGET-QUESTION',created_at:1,tool_calls:[]},
      {seq:2,role:'assistant',content:'BUDGET-ANSWER',created_at:2,tool_calls:[]}],
    task:{subagent_id:'tile-3',session_id:'session-3',state:'answered',settled:true,profile:'worker',model:'fixture',reasoning:'max'}};
  window.__fixtureRefuseBytes=true;
  await window.__refreshAgentPane(panes[3]);
  window.__fixtureRefuseBytes=false;
  check(panes[3].querySelectorAll('wa-message').length===2 &&
    panes[3].transcript.textContent.includes('BUDGET-ANSWER') &&
    /invalid_session_byte_limit/.test(panes[3].notice.textContent) && /KiB/.test(panes[3].notice.textContent),
    'a lowered tool-output budget must cost page size, not the transcript, and the pane must say so, saw: '
    + panes[3].notice.textContent);
  showroom.unpin('tile-0');
  check(showroom.panes.size===3 && showroom.sidebar.querySelectorAll('.agent-card').length===4 &&
    [...showroom.sidebar.querySelectorAll('.agent-card-mission')].some(mission=>mission.textContent==='task 0'),
    'collapse must keep the running agent\'s card in the sidebar, saw ' +
    [...showroom.sidebar.querySelectorAll('.agent-card-mission')].map(mission=>mission.textContent).join('|'));
  showroom.configure({policy:{enabled:true,nodes:[{node:'cloud',max_tasks:2},{node:'local',max_tasks:0}]},nodes:[]});
  check(showroom.policy.nodes[0].node==='cloud' && showroom.policy.nodes[1].max_tasks===0,'node order and zero-capacity devices must round trip');
  // WHAT IS RUNNING, ON WHICH MACHINE. The dispatch table is a placement record, so a child started
  // outside placement has no row there at all - that is how four running children were invisible.
  // These rows come from the app's own builder (window.__liveChildRows) over the node's own answers:
  // the dispatcher's live records, and this node's session ledger for a child with no record. A row
  // whose execution_node is a peer id is the measured shape of a row on this node - the peer id here
  // is the same one POST /subagents with action= list returned for openclaw. The recordless child is
  // the measured shape of a direct-path child session: in this node's ledger, unfinished, a worktree
  // and a parent, and no dispatch row anywhere. It is added to the sessions fixture only for these
  // checks (swapped back below), because the engine sessions view has its own two-session fixture.
  var peerRow={subagent_id:'child-peer',session_id:'child-session-peer',parent_session_id:'aaaaaaaa-0000-0000-0000-000000000001',
    profile:'explore',execution_node:'bbbbbbbb-5555-6666-7777-888888888888',title:'investigate on the peer',
    state:'running',settled:false};
  var directChild={id:'child-direct-0001',title:'direct child with no placement row',
    parent_session_id:'aaaaaaaa-0000-0000-0000-000000000001',mode:'chat',message_count:18,
    worktree:'C:/fixtures/wa-worktree-direct-0001',workspace_branch:'change/fixture-direct',
    state:'unfinished',state_detail:'1 tool call(s) with no recorded result: bash, 12s ago'};
  var withDirectChild={sessions:window.__fixtures.sessions.sessions.concat([directChild])};
  showroom.live=window.__liveChildRows({sessions:withDirectChild.sessions,
    dispatches:window.__fixtures.subagents.subagents.concat([peerRow]),fleet:window.__fixtures.fleet,health:window.__fixtures.health});
  var liveRows=Array.prototype.slice.call(showroom.querySelectorAll('.live-child'));
  var liveRowFor=function(id){return liveRows.find(function(row){return row.dataset.session===id;});};
  check(liveRows.length===3,'the live list must carry the running child, the peer child and the recordless child, saw '+liveRows.length);
  check(!liveRowFor('child-b'),'a settled dispatch must not be shown as a live child');
  check(!!liveRowFor('child-session-a') && liveRowFor('child-session-a').tagName==='BUTTON' &&
    /running/.test(liveRowFor('child-session-a').textContent) && /foundation/.test(liveRowFor('child-session-a').textContent),
    'a running child must show its state and name the machine it runs on, saw: '+(liveRowFor('child-session-a')||{}).textContent);
  check(!!liveRowFor('child-session-peer') && liveRowFor('child-session-peer').dataset.node==='bbbbbbbb-5555-6666-7777-888888888888' &&
    /openclaw/.test(liveRowFor('child-session-peer').textContent) && !/bbbbbbbb/.test(liveRowFor('child-session-peer').textContent),
    'a child on a peer must be named, not shown as its id, saw: '+(liveRowFor('child-session-peer')||{}).textContent);
  check(!!liveRowFor('child-direct-0001') && /unfinished/.test(liveRowFor('child-direct-0001').textContent) &&
    liveRowFor('child-direct-0001').textContent.indexOf('child-direct-0001')>=0 &&
    /bash, 12s ago/.test(liveRowFor('child-direct-0001').textContent) && liveRowFor('child-direct-0001').tagName==='DIV',
    'a child with no placement row must still appear with its session id and the node own detail, saw: '+(liveRowFor('child-direct-0001')||{}).textContent);
  check(/2 running/.test(showroom.querySelector('.live-children-counts').textContent) &&
    /1 queued/.test(showroom.querySelector('.live-children-counts').textContent),
    'the node own subagent counts must be shown as they were reported, saw: '+showroom.querySelector('.live-children-counts').textContent);
  check(/not reachable/.test(showroom.querySelector('.live-children-foot').textContent),
    'the view must say what it cannot show (a peer own live children), saw: '+showroom.querySelector('.live-children-foot').textContent);
  // And through the app own refresh, not only the builder: the panel must be fed by the node answers.
  var sessionsFixture=window.__fixtures.sessions;
  window.__fixtures.sessions=withDirectChild;
  var livePanel=document.createElement('wa-orchestrator');
  document.body.append(livePanel);
  window.__setOrchestratorPanel(livePanel);
  await window.__refreshOrchestrator();
  for(var lr=0;lr<200 && !livePanel.querySelector('.live-child');lr++) await tick();
  var refreshedRows=Array.prototype.slice.call(livePanel.querySelectorAll('.live-child'));
  check(refreshedRows.length===2 && refreshedRows.some(function(row){return row.dataset.session==='child-direct-0001';}),
    'the orchestrator refresh must feed the live list from the node own answers, saw '+refreshedRows.length);
  check(window.__calls.some(function(call){return call.url==='health' && call.method==='GET';}) &&
    window.__calls.some(function(call){return call.url==='sessions' && call.method==='GET';}),
    'the live list must rest on the node health view and the session ledger');
  livePanel.remove();
  window.__fixtures.sessions=sessionsFixture;
  showroom.remove();

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

  // The shell heartbeat proves this page's JavaScript is running, so it must be sent before (and
  // independently of) asking the node. It used to be sent only after `/version` returned; when a run
  // filled the browser's connection pool, `/version` never completed, no heartbeat was sent, and the
  // shell reloaded a live page - which re-issued the same requests and looped.
  var beats = 0;
  window.__setShell({ heartbeat: function () { beats += 1; } });
  window.__failVersion = true;
  window.__watch();
  for (var hb = 0; hb < 5; hb++) { await tick(); }
  check(beats >= 1, 'the shell heartbeat must be sent even when the node does not answer');
  window.__failVersion = false;
  window.__setShell(null);

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

  var ownControlThread=window.__chatThread();
  var backgroundHealth={node_threads:[{role:'runs',label:'child completion',session:ownControlThread,run_id:'9007199254740993'}]};
  check(window.__activeRunForTest(backgroundHealth,ownControlThread)?.run_id==='9007199254740993',
    'background completion must be recognized as the exact own run without losing its decimal id');
  check(window.__runningSessionsForTest(backgroundHealth).has(ownControlThread),
    'background completion activity and composer controls must agree');
  check(!window.__activeRunForTest(backgroundHealth,'another-conversation'),
    'background completion never takes controls from another conversation');
  window.__fixtures.health.node_threads=backgroundHealth.node_threads;
  await window.__restoreSession();
  check(!document.getElementById('steer').hidden && !document.getElementById('send').disabled
    && !document.querySelector('.unfinished-notice button'),
    'background completion exposes Stop and Steer rather than leaving the composer stranded');
  document.getElementById('send').click();
  for(var backgroundStopTick=0;backgroundStopTick<10;backgroundStopTick++)await tick();
  var backgroundStop=window.__calls.filter(call=>call.url==='runs' && call.method==='POST').at(-1);
  check(JSON.parse(backgroundStop?.body || '{}').run_id==='9007199254740993'
    && JSON.parse(backgroundStop?.body || '{}').thread===ownControlThread,
    'background Stop reaches the authenticated control route with its exact run and conversation');
  var unavailableHealthFetch=window.fetch;
  window.fetch=async function(url,options) {
    if(String(url).replace(/^.*\//,'')==='health')return new Response(JSON.stringify({error:'temporarily_unavailable'}),{status:503});
    return unavailableHealthFetch(url,options);
  };
  await window.__restoreSession();
  check(!document.getElementById('steer').hidden && document.getElementById('send').title==='Stop'
    && !document.querySelector('.unfinished-notice button'),
    'failed health observation does not falsely free known background ownership or duplicate Continue');
  window.fetch=unavailableHealthFetch;
  var readOnlyHealth={node_threads:[{role:'reads',label:'GET /models',session:ownControlThread,run_id:null}]};
  check(!window.__activeRunForTest(readOnlyHealth,ownControlThread)
    && !window.__runningSessionsForTest(readOnlyHealth).has(ownControlThread),
    'a read for the same session must not hide idle recovery controls');
  window.__fixtures.health.node_threads=readOnlyHealth.node_threads;
  await window.__restoreSession();
  check(!!document.querySelector('.unfinished-notice button') && !document.getElementById('send').disabled,
    'idle unfinished session keeps Continue and Send while ordinary reads run');
  check(window.__activeRunForTest({runs:[{conversation:ownControlThread,run_id:'42',state:'queued'}]},ownControlThread)?.run_id==='42'
    && !window.__activeRunForTest({runs:[{conversation:ownControlThread,run_id:'42',state:'completed'}]},ownControlThread),
    'queued ownership is recognized but a terminal scheduler row does not lock the composer');
  window.__fixtures.health.node_threads=[];

  // A chat run for a *different* conversation is not this window's run. Before `activeRun` was
  // scoped to the conversation, it returned the first chat run on the node, so a window watching
  // conversation B disabled its own composer and deferred its reconcile for conversation A's run.
  window.__fixtures.health.node_threads = [{ label: "POST /chat", busy_ms: 4000, session: "another-conversation" }];
  await window.__restoreSession();
  var foreignNotice = document.querySelector(".unfinished-notice");
  check(!!foreignNotice && /effects may have happened/.test(foreignNotice.textContent) && !!foreignNotice.querySelector("button"),
    "another conversation's run must not be treated as this window's run, saw: " +
      (foreignNotice ? foreignNotice.textContent.slice(0, 120) : "no notice"));
  window.__fixtures.health.node_threads = [];

  // Enter while a run is busy means "keep this draft for the next turn", not "cancel the run". The
  // red button is the explicit Stop control. Conflating them made a reader typing ahead kill a healthy
  // model call, then wonder why the next prompt had apparently made the agent lose control.
  var cancelCalls = window.__calls.filter(function (call) { return call.url === "runs" && call.method === "POST"; }).length;
  window.__setBusy(true);
  var busyInput = window.__commandInput();
  busyInput.value = "the next task";
  var busyEnter = new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });
  busyInput.dispatchEvent(busyEnter);
  for (var holdTick = 0; holdTick < 5; holdTick++) await tick();
  var heldCalls = window.__calls.filter(function (call) { return call.url === "runs" && call.method === "POST"; });
  check(heldCalls.length === cancelCalls, "Enter during a run must not cancel it");
  check(busyInput.value === "the next task", "Enter during a run must preserve the queued draft");
  check(busyEnter.defaultPrevented, "the busy Enter key must not fall through to form submission");
  check(!document.getElementById('steer').hidden,'active run exposes explicit steering');
  // The owner's own complaint, measured where the app itself reveals the control: with a run in flight the
  // main chat's Steer is on screen and it must be the append-file control's own box. The harness has the
  // engine view open here, which hides the composer, so the *computed* box is asserted first - and then the
  // rendered one, with that one body class taken off for the measurement and put back exactly as it was.
  var busySteer=document.getElementById('steer'), busyAttach=document.getElementById('attach');
  var busySteerStyle=getComputedStyle(busySteer), busyAttachStyle=getComputedStyle(busyAttach);
  var boxNote=function(style){return style.height+' / min '+style.minWidth+' / radius '+style.borderRadius
    + ' / border '+style.borderTopWidth; };
  check(busySteerStyle.height===busyAttachStyle.height && busyAttachStyle.height==='30px'
    && busySteerStyle.minWidth===busyAttachStyle.minWidth && busySteerStyle.borderTopWidth===busyAttachStyle.borderTopWidth
    && busySteerStyle.borderRadius===busyAttachStyle.borderRadius,
    'the main chat\'s Steer must compute to the append-file control\'s own box while a run is active, saw steer ['
      + boxNote(busySteerStyle) + '] and append-file [' + boxNote(busyAttachStyle) + '], classes '
      + busySteer.className + ' / ' + busyAttach.className);
  var engineWasOpen=document.body.classList.contains('engine');
  if(engineWasOpen) document.body.classList.remove('engine');
  var busySteerRect=busySteer.getBoundingClientRect(), busyAttachRect=busyAttach.getBoundingClientRect();
  if(engineWasOpen) document.body.classList.add('engine');
  check(Math.round(busySteerRect.height)===Math.round(busyAttachRect.height) && Math.round(busyAttachRect.height)===30,
    'the main chat\'s Steer must measure the append-file control\'s height while a run is active, saw steer '
      + Math.round(busySteerRect.height) + 'px (w ' + Math.round(busySteerRect.width) + ' - the label\'s own width, '
      + 'which follows the ambient font and is reported, not asserted) and append-file '
      + Math.round(busyAttachRect.height) + 'px (w ' + Math.round(busyAttachRect.width) + '), body '
      + document.body.className);
  document.getElementById('steer').click();
  for(var st=0;st<10;st++)await tick();
  check(window.__calls.some(call=>call.url==='subagents' && String(call.body).includes('steer_session')) && busyInput.value==='', 'steering sends durably and clears only accepted draft');
  check(window.__calls.filter(call=>call.url==='runs' && call.method==='POST').length===cancelCalls,'steering never cancels the run');

  var steeringFetch=window.fetch, steeringBodies=[], steeringBusy=true;
  window.fetch=async function(url,options) {
    if(String(url).replace(/^.*\//,'')==='subagents' && String(options?.body).includes('steer_session')) {
      steeringBodies.push(options.body);
      if(steeringBusy)return new Response(JSON.stringify({error:'read_capacity_busy'}),{status:503});
    }
    return steeringFetch(url,options);
  };
  busyInput.value='keep this steering draft';
  await window.__steerForTest();
  check(steeringBodies.length===2 && steeringBodies[0]===steeringBodies[1]
    && busyInput.value==='keep this steering draft' && !document.getElementById('send').disabled,
    'busy control capacity retries once with the same key and preserves draft plus Stop');
  steeringBusy=false;
  await window.__steerForTest();
  check(steeringBodies.length===3 && steeringBodies[2]===steeringBodies[0] && busyInput.value==='',
    'manual retry after busy refusal reuses the durable key and clears only an accepted draft');
  window.fetch=async function(url,options) {
    if(String(url).replace(/^.*\//,'')==='subagents' && String(options?.body).includes('steer_session')) {
      steeringBodies.push(options.body);throw new Error('connection lost after dispatch');
    }
    return steeringFetch(url,options);
  };
  busyInput.value='unknown outcome draft';
  await window.__steerForTest();
  check(steeringBodies.length===4 && busyInput.value==='unknown outcome draft',
    'unknown steering outcomes are not automatically replayed and retain the draft');
  window.fetch=steeringFetch;

  var steeringTarget=window.__controlIdentityForTest(), targetSteers=[];
  window.__setBusy(true);
  busyInput.value='original node steering';
  window.fetch=async function(url,options) {
    if(String(url)==='subagents' && String(options?.body).includes('steer_session')) {
      targetSteers.push({body:options.body,node:options.headers['X-WA-Node'] || ''});
      return new Response(JSON.stringify({error:'read_capacity_busy'}),{status:503});
    }
    if(String(url)==='health') {
      window.__rememberNodeForTest('steering-other-node');
      busyInput.value='new node draft';
    }
    return steeringFetch(url,options);
  };
  await window.__steerForTest();
  check(targetSteers.length===1 && targetSteers[0].node===steeringTarget.node
    && busyInput.value==='new node draft',
    'node switch during busy retry never posts the old steering to the new node or clears its draft');
  window.__rememberNodeForTest(steeringTarget.node);
  window.__setBusy(true);
  busyInput.value='old epoch steering';
  window.fetch=async function(url,options) {
    if(String(url)==='subagents' && String(options?.body).includes('steer_session')) {
      targetSteers.push({body:options.body,node:options.headers['X-WA-Node'] || ''});
      return {ok:true,status:200,json:async function(){
        window.__rememberNodeForTest('steering-epoch-away');
        window.__rememberNodeForTest(steeringTarget.node);
        busyInput.value='new epoch draft';
        return {id:'old-epoch-accepted',state:'queued'};
      }};
    }
    return steeringFetch(url,options);
  };
  await window.__steerForTest();
  check(targetSteers.length===2 && busyInput.value==='new epoch draft'
    && JSON.parse(targetSteers[0].body).idempotency_key!==JSON.parse(targetSteers[1].body).idempotency_key,
    'accepted response from an old epoch keeps the new draft and request keys bind the target epoch');
  window.fetch=steeringFetch;
  window.__setBusy(true);

  // Stop must tell the node, not only stop reading the stream: a client-side abort leaves the model
  // call running. It must wait for the node's acknowledgment and surface a refusal.
  document.getElementById("send").click();
  for (var cancelTick = 0; cancelTick < 10; cancelTick++) await tick();
  var runCalls = window.__calls.filter(function (call) { return call.url === "runs" && call.method === "POST"; });
  check(runCalls.length === cancelCalls + 1,
    "stopping a run must ask the node to cancel it, not only abort the stream");
  check(runCalls.some(function (call) { return /"action":"cancel"/.test(call.body || "") && /"thread"/.test(call.body || ""); }),
    "the cancel request must name the action and the conversation");
  check(/stop requested/.test(document.querySelector(".status:not(.finished) .chat-content-run-label").textContent),
    "Stop must report the node's cancellation acknowledgment, saw: " + document.querySelector(".status:not(.finished) .chat-content-run-label").textContent);
  window.__fixtures.runsCancelRefuse = true;
  await window.__cancelRunForTest(3);
  check(/could not stop this run: run_not_found/.test(document.querySelector(".status:not(.finished) .chat-content-run-label").textContent),
    "a rejected cancellation must be shown instead of silently aborting the stream, saw: " + document.querySelector(".status:not(.finished) .chat-content-run-label").textContent);
  window.__fixtures.runsCancelRefuse = false;
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

  // Read-only topics use host read node-threads, so they must remain available while the run node-thread is
  // occupied. Topics that still need the run node-thread must queue clearly and load after the run.
  window.__setBusy(true);
  window.__loadTopic("sessions-box");
  for (var tb = 0; tb < 5; tb++) { await tick(); }
  var busyBox = document.getElementById("sessions-box");
  check(!/busy with a run/.test(busyBox.textContent) && !!busyBox.querySelector(".session-title"),
    "sessions must load from the read node-thread during a run, saw: " + busyBox.textContent.slice(0, 70));
  check(!/AbortError/.test(busyBox.textContent), "and must not report an abort as if the UI were broken");
  window.__loadTopic("spells-box");
  for (var tw = 0; tw < 5; tw++) { await tick(); }
  var waitingBox = document.getElementById("spells-box");
  check(/busy with a run/.test(waitingBox.textContent),
    "a topic that needs the run node-thread must say it is queued, saw: " + waitingBox.textContent.slice(0, 70));
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
  var resourceLines = document.querySelectorAll("#nodes-box .node-resources");
  check(resourceLines.length === 2, "every machine node must have a resource line, saw " + resourceLines.length);
  check(/CPU 13%.*RAM 41%\/32GB.*DISK 30%\/2\.0TB/.test(resourceLines[0]?.textContent || ""),
    "the node card must format live CPU, RAM and workspace disk, saw: " + (resourceLines[0]?.textContent || "nothing"));
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
    window.__setLiveness({ working: true, stalled: 46, busy_ms: 25369, climbing_ms: 0, node_thread_state: "alive", queue: 0 });
    var ok = document.getElementById("liveness");
    check(!!ok, "liveness: no line rendered while working");
    if (ok) {
      check(!ok.classList.contains("stuck"), "liveness: a fresh beat must not read as stuck");
      check(ok.textContent.indexOf("working") >= 0, "liveness: the working state must say so");
      // The socket number is the node's own evidence, so it has to appear rather than a guess.
      check(ok.textContent.indexOf("46 ms") >= 0, "liveness: the beat age must be shown, got: " + ok.textContent);
      check(ok.textContent.indexOf("25") >= 0, "liveness: the elapsed time must be shown, got: " + ok.textContent);
    }
    window.__setLiveness({ working: false, stalled: 9000, busy_ms: 60000, climbing_ms: 9000, node_thread_state: "alive", queue: 0 });
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
  await (async function () {
    document.title = "stage: commands";
    var input = window.__commandInput();
    var menu = window.__commandMenu();
    function type(value) { window.__typeCommand(value); }

    var composerModel = document.getElementById("composer-model");
    check(!!composerModel && composerModel.textContent === "previous-model",
      "composer status: the far-right model label must show the latest observed model, not the selected model");
    check(!!composerModel && getComputedStyle(composerModel.parentElement).justifyContent === "flex-end",
      "composer status: the model label must sit at the far-right edge");

    type("/");
    check(menu.open, "commands: `/` must open the list");
    var items = Array.prototype.slice.call(menu.querySelectorAll(".menu-item"));
    check(items.length === 5, "commands: `/` must offer all five commands, got " + items.length);
    check(items[0] && items[0].textContent.indexOf("/new") >= 0,
      "commands: the list must offer /new first, got: " + (items[0] && items[0].textContent));
    check(items[1] && items[1].textContent.indexOf("/update") >= 0,
      "commands: the list must offer /update, got: " + (items[1] && items[1].textContent));
    check(items[2] && items[2].textContent.indexOf("/merge") >= 0,
      "commands: the list must offer /merge, got: " + (items[2] && items[2].textContent));
    check(items[2] && items[2].textContent.includes('internal branches') && items[2].textContent.includes('PR work for review'),
      'commands: ordinary merge menu describes its internal-only scope');
    check(items[3] && items[3].textContent.indexOf("/merge all") >= 0,
      "commands: the window must offer explicit PR-inclusive merge all");
    check(items[4] && items[4].textContent.indexOf("/efficiency_report") >= 0,
      "commands: the window must offer /efficiency_report, got: " + (items[4] && items[4].textContent));

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
    var updateCall = (window.__calls || []).filter(function (call) {
      return String(call.url).indexOf("update") >= 0 && call.method === "POST";
    }).pop();
    check(!!updateCall && JSON.parse(updateCall.body || "{}").thread === now,
      "commands: /update must carry the current thread for the post-replacement continuation");
    check(messages.lastElementChild && messages.lastElementChild.classList.contains("thread-notice"),
      "commands: /update must leave its answer in the transcript");

    // Running `/efficiency_report` must ask the node. The window has no ledger to read, so a
    // panel with no request behind it would be an invented report - the request is the evidence.
    type("/efficiency_report");
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    var reportAsked = (window.__calls || []).some(function (call) {
      return String(call.url).indexOf("efficiency") >= 0;
    });
    check(reportAsked, "commands: running /efficiency_report must ask the node's efficiency route");
    var reportCall = (window.__calls || []).filter(function (call) {
      return String(call.url).startsWith("efficiency?session_id=");
    }).slice(-1)[0];
    var reportThread = reportCall ? new URLSearchParams(reportCall.url.split("?")[1]).get("session_id") : "";
    check(reportThread === now,
      "commands: /efficiency_report must measure the selected chat, not the login token");
    var panel = messages.querySelector(".efficiency-report");
    check(!!panel, "commands: /efficiency_report must leave its report in the transcript");
    if (panel) {
      for (var reportTick = 0; reportTick < 20 && panel.textContent.indexOf("session fixture") < 0; reportTick += 1) await tick();
      check(panel.textContent.indexOf("session fixture") >= 0,
        "commands: /efficiency_report must show the node's answer, got: " + panel.textContent.slice(0, 60));
    }
    // The report is columns, not prose. A wrapped row reads as two rows and the numbers stop
    // lining up with their labels - and the node's report cannot know the window's width, so the
    // panel is the only place this can be kept true. Asserted on the rendered boxes rather than on
    // the CSS, because it is the rendered result the reader sees.
    if (panel) {
      var reportStyle = getComputedStyle(panel);
      check(reportStyle.whiteSpace === "pre",
        "commands: the report must keep its columns rather than wrap them, got white-space: " +
        reportStyle.whiteSpace);
      var reportText = panel.textContent.replace(/\n+$/, "");
      var reportLines = reportText.split(String.fromCharCode(10)).filter(function (line) {
        return line.trim() !== "";
      }).length;
      var reportRange = document.createRange();
      reportRange.selectNodeContents(panel);
      // Counted by distinct line tops, not by rects: the browser reports a line wider than the
      // panel as two rects (the visible fragment and the overflowing one), and a long line is
      // exactly the case this check is about.
      var reportTops = {};
      Array.prototype.forEach.call(reportRange.getClientRects(), function (box) {
        if (box.width > 0) reportTops[Math.round(box.top)] = true;
      });
      var reportRows = Object.keys(reportTops).length;
      check(reportRows === reportLines,
        "commands: every non-empty report line must render as exactly one line, saw " + reportRows +
        " rows for " + reportLines + " lines");
    }

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
  window.__fixtures.health.node_threads = [{ label: "POST /chat", busy_ms: 5000, session: followThread }];
  window.__fixtures.health.current = { label: "POST /chat", ms: 5000, session: followThread };
  window.__fixtures.sessions = { sessions: [{ id: followThread, title: "followed", user_id: "master",
    mode: "chat", message_count: 3, last_seq: 2, updated_at: Math.floor(Date.now() / 1000),
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
  // Seeing a new sequence is not the same as repainting it. A transient failure after the list read
  // used to advance `followedSeq` anyway, so the same sequence was never retried and the page stayed
  // stale for the entire next tool call.
  window.__fixtures.sessions.sessions[0].last_seq = 4;
  window.__fixtures.session.messages.push(
    { seq: 3, role: "assistant", content: "FOLLOW-RETRY-PROOF", tool_calls: [] });
  window.__failSessionReads = 1;
  await window.__followRun();
  var retryCalls = window.__calls.filter(c=>c.url.startsWith('session?')).length;
  await window.__followRun();
  check(window.__calls.filter(c=>c.url.startsWith('session?')).length===retryCalls,
    'transcript recovery must back off instead of issuing another read immediately');
  check(document.getElementById('messages').textContent.includes('FOLLOWED-PARTIAL'),
    'a failed refresh must preserve the last confirmed transcript');
  window.__expireRecoveryBackoff();
  await window.__followRun();
  check(document.body.innerText.indexOf("FOLLOW-RETRY-PROOF") >= 0,
    "follow: a failed transcript read must retry the same ledger sequence");
  check(window.__followedSeq()===3, 'the follower cursor must cover only actually loaded rows, not a newer session list sequence');
  window.__fixtures.sessions.sessions[0].last_seq = 3;
  var savedRecoveryFetch=window.fetch, settleTranscript=null, heldTranscriptReads=0;
  window.fetch=function(url,options){
    if(String(url).startsWith('session?')) {
      heldTranscriptReads++;
      return new Promise(function(resolve){settleTranscript=()=>resolve(savedRecoveryFetch(url,options));});
    }
    return savedRecoveryFetch(url,options);
  };
  var restoreA=window.__restoreSession(),restoreB=window.__restoreSession(),restoreC=window.__restoreSession();
  check(heldTranscriptReads===1,'simultaneous recovery callers must share one transcript request');
  settleTranscript();await Promise.all([restoreA,restoreB,restoreC]);window.fetch=savedRecoveryFetch;
  // Switch at each asynchronous recovery boundary. A first-response fence does
  // not protect the idle-tail reread or checkpoint's subsequent ledger await.
  var raceThread=chatSession,raceNode=activeNode,raceHealth=window.__fixtures.health;
  var raceFetch=window.fetch,lateTail=null,tailReads=0;
  var racePayload={session:{id:raceThread},state:{state:'unfinished',role:'user',pending:[]},
    messages:[{seq:99,role:'user',content:'OLD-IDLE-TAIL-RACE',tool_calls:[]}]};
  window.__fixtures.health={ok:true,runs:[],node_threads:[],current:null};
  window.fetch=function(url,options){
    if(String(url).startsWith('session?')) {
      tailReads++;
      if(tailReads===2)return new Promise(resolve=>{lateTail=resolve;});
      return Promise.resolve({ok:true,status:200,json:()=>Promise.resolve(racePayload)});
    }
    return raceFetch(url,options);
  };
  var tailRestore=restoreSessionOnce(chatSession,conversationEpoch);
  for(var tr=0;tr<50&&!lateTail;tr++)await tick();
  check(!!lateTail,'the idle-tail case must pause the actual second transcript read');
  rememberSession('late-tail-target');
  lateTail({ok:true,status:200,json:()=>Promise.resolve(racePayload)});await tailRestore;
  check(!document.getElementById('messages').textContent.includes('OLD-IDLE-TAIL-RACE') && followedSeq===null,
    'a session switch during idle-tail reread must reject its old rows and cursor');
  window.fetch=raceFetch;rememberSession(raceThread);
  var lateNodeRead=null;
  window.fetch=function(url,options){
    if(String(url).startsWith('session?'))return new Promise(resolve=>{lateNodeRead=resolve;});
    return raceFetch(url,options);
  };
  var nodeRestore=restoreSessionOnce(chatSession,conversationEpoch);
  if(typeof rememberNode==='function')rememberNode('other-race-node');else activeNode='other-race-node';
  var nodeRacePayload={session:{id:raceThread},state:{state:'failed'},
    messages:[{seq:88,role:'user',content:'OLD-NODE-RACE',tool_calls:[]}]};
  lateNodeRead({ok:true,status:200,json:()=>Promise.resolve(nodeRacePayload)});await nodeRestore;
  check(!document.getElementById('messages').textContent.includes('OLD-NODE-RACE'),
    'a node switch must fence an old transcript even when the session id stays the same');
  window.fetch=raceFetch;
  if(typeof rememberNode==='function')rememberNode(raceNode);else activeNode=raceNode;
  var raceFollow=followRun,lateCheckpoint=null;
  followRun=()=>new Promise(resolve=>{lateCheckpoint=resolve;});
  window.fetch=function(url,options){
    if(url==='run-events')return Promise.resolve({ok:true,status:200,json:()=>Promise.resolve({
      checkpoint_seq:5,checkpoint_message_seq:200,events:[{seq:6,event:{type:'delta',text:'OLD-CHECKPOINT-RACE'}}]})});
    return raceFetch(url,options);
  };
  var checkpointRestore=syncLiveRun({session:chatSession,run_id:551});
  for(var cp=0;cp<50&&!lateCheckpoint;cp++)await tick();
  check(!!lateCheckpoint,'checkpoint case must pause its ledger reconciliation await');
  rememberSession('late-checkpoint-target');followedSeq=999;
  lateCheckpoint();await checkpointRestore;
  check(!document.getElementById('messages').textContent.includes('OLD-CHECKPOINT-RACE') && liveEventSeq===0,
    'a session switch during checkpoint read must reject its old events and live cursor');
  followRun=raceFollow;window.fetch=raceFetch;window.__fixtures.health=raceHealth;
  rememberSession(raceThread);await window.__restoreSession();
  check(!document.getElementById('messages').textContent.includes('transcript refresh failed'),
    'successful recovery must clear its stale failure notice');
  // ONE BUBBLE PER RUN, however many times the model speaks inside it.
  // Measured live: a run whose model wrote a one-line preamble before each tool batch produced three
  // assistant messages in one run, and the window drew THREE bubbles - because the `reply` handler
  // closed the bubble (`runBubble = null`) on every reply event, contradicting flushDecision's own
  // contract that "the bubble only closes when the run really ends". The run topic exists to fold the
  // route away, and a topic cannot span bubbles, so a multi-step run read as several unrelated replies.
  (function () {
    var msgs = document.getElementById("messages");
    // The reload fixture is intentionally live. Close its bubble before starting this independent
    // synthetic run so the test measures one new bubble, rather than continuation of that fixture.
    window.handleEvent({ type: "done" });
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
    check(tail?.body?.lastElementChild === placed,
      "mid-run the status line must be the balloon's last child, saw: "
      + (tail ? tail.tagName + "." + tail.className : "nothing"));
    // "Sticked" is half the behaviour and it is invisible to a structure check: the line is pinned
    // to the bottom of the transcript while the run is in flight, and only becomes the bubble's
    // footer when the run ends. A line that never pins and a line that never moves look identical
    // in a screenshot, so the computed position is asserted on both sides of that move.
    var livePosition = getComputedStyle(placed).position;
    check(livePosition === "sticky",
      "mid-run the status line must be sticky at the bottom of the transcript, saw position: " + livePosition);
    check(placed.closest('wa-message.assistant') === tail,
      "mid-run the status line must live inside the assistant balloon, saw parent: "
      + (placed.parentNode ? placed.parentNode.tagName : "none"));
    var bubbles = messages.querySelectorAll("wa-message.assistant");
    var bubble = bubbles[bubbles.length - 1];
    check(placed.parentNode === bubble.body,
      "the status line must share the balloon with the run's steps");
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
    check(!!merged && String(merged.body).includes('Open PR work is excluded'),
      'commands: ordinary merge excludes PR work');
    for (var mergeDrain = 0; mergeDrain < 80; mergeDrain += 1) await tick();
    window.__typeCommand('/merge all');
    mergeInput.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',bubbles:true}));
    for (var mergeDrain = 0; mergeDrain < 80; mergeDrain += 1) await tick();
    var allMerged=(window.__calls || []).filter(call=>String(call.url).includes('chat') && call.method==='POST').pop();
    check(!!allMerged && String(allMerged.body).includes('/merge all explicitly includes every open PR head'),
      'commands: explicit merge all sends the PR-inclusive scope');
    check(!!allMerged && String(allMerged.body).includes('honor required checks and approvals'),
      'commands: merge all retains required PR review');
  })();

  // ---- choosing and creating sessions in the engine ------------------------------------------
  // `open` is a conversation switch, not an inspector that merely changes localStorage. Before
  // this check existed the screen kept showing thread A while the next send silently went to B;
  // reloading happened to repaint B and made the control look intermittent.
  var switchSessions = window.__fixtures.sessions;
  var switchSession = window.__fixtures.session;
  var switchId = "bbbbbbbb-0000-0000-0000-000000000002";
  window.__fixtures.sessions = { sessions: [
    { id: switchId, title: "settled thread", user_id: "master", mode: "chat", message_count: 2,
      last_seq: 2, updated_at: Math.floor(Date.now() / 1000), state: "answered" },
  ] };
  window.__fixtures.session = {
    session: { id: switchId, title: "settled thread", mode: "chat" },
    state: { state: "answered", detail: "the last message is a reply" },
    messages: [
      { seq: 1, role: "user", content: "SWITCHED-SESSION-QUESTION", tool_calls: [] },
      { seq: 2, role: "assistant", content: "SWITCHED-SESSION-ANSWER", tool_calls: [] },
    ],
  };
  if (!document.body.classList.contains("engine")) document.getElementById("engine-btn").click();
  await window.__loadTopic("sessions-box");
  for (var switchTick = 0; switchTick < 20 && !document.querySelector(".session-row button"); switchTick++) await tick();
  var openThread = Array.from(document.querySelectorAll(".session-row button"))
    .find(function (button) { return button.textContent.trim() === "open"; });
  if (openThread) openThread.click();
  for (var openTick = 0; openTick < 200 &&
      document.getElementById("messages").textContent.indexOf("SWITCHED-SESSION-ANSWER") < 0; openTick++) await tick();
  check(window.__chatThread() === switchId && !document.body.classList.contains("engine") &&
      document.getElementById("messages").textContent.indexOf("SWITCHED-SESSION-ANSWER") >= 0,
    "sessions: open must switch and repaint the chat immediately (thread=" + window.__chatThread() +
      ", engine=" + document.body.classList.contains("engine") + ", opened=" + !!openThread +
      ", text=" + document.getElementById("messages").textContent.slice(0, 80) + ")");

  // A blank session is a real choice even before its first message creates a ledger row. Restoring
  // must not snap it back to the newest old thread, which is what made `/new` fail across reloads.
  document.getElementById("engine-btn").click();
  await window.__loadTopic("sessions-box");
  for (var newTick = 0; newTick < 20 && !document.querySelector(".session-new"); newTick++) await tick();
  var beforeNew = window.__chatThread();
  document.querySelector(".session-new")?.click();
  var blankThread = window.__chatThread();
  check(!!blankThread && blankThread !== beforeNew && !document.body.classList.contains("engine") &&
      /new session/.test(document.getElementById("messages").textContent),
    "sessions: the engine must offer a new blank session and return to chat");
  await window.__restoreSession();
  check(window.__chatThread() === blankThread && /new session/.test(document.getElementById("messages").textContent),
    "sessions: restoring an unsent blank session must not replace it with an older thread");
  window.__fixtures.sessions = switchSessions;
  window.__fixtures.session = switchSession;
  window.__attachMany(1);
  window.__commandInput().value = "What is in this picture?";
  document.getElementById("composer").dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
  var userTurns = document.querySelectorAll("wa-message.user");
  var imageTurn = userTurns[userTurns.length - 1];
  var shownImage = imageTurn && imageTurn.querySelector(".message-image");
  check(!!shownImage && shownImage.alt === "shot-0.png" && shownImage.src.indexOf("data:image/png;base64,") === 0,
    "sending a picture must show its preview in the user turn, saw: " + (imageTurn ? imageTurn.innerHTML : "no user turn"));
  for (var imagePostTick = 0; imagePostTick < 50 && !(window.__calls || []).some(function (call) {
      return call.url === "chat" && call.method === "POST" && String(call.body).indexOf("What is in this picture?") >= 0;
    }); imagePostTick++) await tick();
  var imagePost = (window.__calls || []).filter(function (call) {
    return call.url === "chat" && call.method === "POST" && String(call.body).indexOf("What is in this picture?") >= 0;
  }).pop();
  var imagePayload = imagePost ? JSON.parse(imagePost.body) : {};
  check(!!imagePost && imagePayload.images && imagePayload.images.length === 1 && imagePayload.images[0].name === "shot-0.png",
    "the visible user-turn image must also be the image sent to the node");
  for (var finishImageSend = 0; finishImageSend < 20; finishImageSend++) await tick();
  await window.__refreshTasks();
  var taskPanel=document.querySelector('#tasks-box wa-tasks');
  check(taskPanel.querySelectorAll('.task-card').length===2, 'tasks: both child records are visible');
  check(taskPanel.textContent.includes('investigate A') && taskPanel.textContent.includes('investigate B'), 'tasks: objectives are attributable');
  check(!taskPanel.querySelector('img'), 'tasks: objective text is never HTML');
  var cancelButtons=Array.from(taskPanel.querySelectorAll('button')).filter(b=>b.textContent==='Cancel task');
  check(cancelButtons.length===1,'tasks: only unsettled child has cancellation');
  cancelButtons[0].click();
  for(var ti=0;ti<80;ti++) await tick();
  check(window.__calls.some(c=>c.url==='subagents' && c.body.includes('"action":"cancel"') && c.body.includes('"subagent_id":"child-a"')),
    'tasks: cancel names exactly the selected child');
  Array.from(taskPanel.querySelectorAll('button')).find(b=>b.textContent==='Inspect result').click();
  for(var ti=0;ti<80;ti++) await tick();
  check(taskPanel.querySelector('.task-evidence').textContent.includes('verified fixture result'),'tasks: actual result is inspectable');
  window.__holdTaskStart=true;
  taskPanel.prompt.value='new bounded investigation';
  taskPanel.form.dispatchEvent(new Event('submit',{cancelable:true}));
  for(var ti=0;ti<80;ti++) await tick();
  await window.__refreshTasks();
  check(taskPanel.start.disabled,'tasks: polling cannot admit a duplicate submission while the response is pending');
  window.__releaseTaskStart(); window.__holdTaskStart=false;
  for(var ti=0;ti<80;ti++) await tick();
  var taskStart=window.__calls.filter(c=>c.url==='subagents' && c.body.includes('"action":"start"')).pop();
  check(taskStart && JSON.parse(taskStart.body).thread && JSON.parse(taskStart.body).idempotency_key,
    'tasks: start binds a parent and a deduplication key');
  // A failed start keeps its submission identity for an unchanged retry, but a new prompt is a new task.
  taskPanel.prompt.value='retry this bounded investigation';
  window.__taskFailure=true;
  taskPanel.form.dispatchEvent(new Event('submit',{cancelable:true}));
  for(var ti=0;ti<80;ti++) await tick();
  var failedTaskStarts=window.__calls.filter(c=>c.url==='subagents' && c.body.includes('"action":"start"'));
  var failedTaskBody=failedTaskStarts.length ? JSON.parse(failedTaskStarts[failedTaskStarts.length-1].body) : {};
  check(taskPanel.notice.textContent.includes('unavailable'), 'tasks: a failed start is reported before retry');
  window.__taskFailure=false;
  taskPanel.form.dispatchEvent(new Event('submit',{cancelable:true}));
  for(var ti=0;ti<80;ti++) await tick();
  var retriedTaskStarts=window.__calls.filter(c=>c.url==='subagents' && c.body.includes('"action":"start"'));
  var retriedTaskBody=retriedTaskStarts.length ? JSON.parse(retriedTaskStarts[retriedTaskStarts.length-1].body) : {};
  check(failedTaskStarts.length+1===retriedTaskStarts.length && failedTaskBody.thread===retriedTaskBody.thread &&
    failedTaskBody.profile===retriedTaskBody.profile && failedTaskBody.prompt===retriedTaskBody.prompt &&
    !!failedTaskBody.idempotency_key && failedTaskBody.idempotency_key===retriedTaskBody.idempotency_key,
    'tasks: retrying an unchanged failed start reuses its parent/profile/prompt idempotency key');
  taskPanel.prompt.value='a different bounded investigation';
  taskPanel.form.dispatchEvent(new Event('submit',{cancelable:true}));
  for(var ti=0;ti<80;ti++) await tick();
  var newTaskStarts=window.__calls.filter(c=>c.url==='subagents' && c.body.includes('"action":"start"'));
  var newTaskBody=newTaskStarts.length ? JSON.parse(newTaskStarts[newTaskStarts.length-1].body) : {};
  check(newTaskStarts.length===retriedTaskStarts.length+1 && newTaskBody.prompt!==retriedTaskBody.prompt &&
    !!newTaskBody.idempotency_key && newTaskBody.idempotency_key!==retriedTaskBody.idempotency_key,
    'tasks: changing the prompt for a new task uses a different idempotency key');
  window.__taskFailure=true;
  await window.__refreshTasks();
  check(taskPanel.querySelectorAll('.task-card').length===2 && taskPanel.notice.textContent.includes('unavailable'),
    'tasks: failed refresh keeps prior evidence and shows the failure');
  window.__taskFailure=false;
  window.__fixtures.runs.runs=[{run_id:99,state:'unknown'}];
  await window.__refreshTasks();
  check(taskPanel.textContent.includes('Inspect effects before continuing.') &&
    !Array.from(taskPanel.querySelectorAll('button')).some(b=>b.textContent==='Cancel run'),
    'tasks: interrupted runs require inspection and cannot be presented as cancellable live work');
  Array.from(taskPanel.querySelectorAll('button')).find(b=>b.textContent==='Inspect run').click();
  for(var ti=0;ti<80;ti++) await tick();
  check(taskPanel.evidence.textContent.includes('ARCHIVE-BEFORE-CHECKPOINT') && !taskPanel.more.hidden,
    'tasks: inspection requests original output before checkpoints and exposes further pages');
  taskPanel.more.click();
  for(var ti=0;ti<80;ti++) await tick();
  check(taskPanel.evidence.textContent.includes('ARCHIVE-BEFORE-CHECKPOINT') &&
    taskPanel.evidence.textContent.includes('ARCHIVE-SECOND-PAGE') && taskPanel.more.hidden,
    'tasks: subsequent archive pages preserve already inspected evidence');
  window.__fixtures.subagents.subagents.reverse();
  var oldTaskPrompt=window.__fixtures.subagents.subagents[0].prompt;
  var longTaskPrompt='Full objective remains available. '.repeat(20);
  window.__fixtures.subagents.subagents[0].prompt=longTaskPrompt;
  await window.__refreshTasks();
  check(taskPanel.list.querySelector('.task-card').dataset.state==='running',
    'tasks: active work precedes retained history regardless of response order');
  var history=taskPanel.list.querySelector('.task-history');
  check(history && !history.open && history.querySelectorAll('.task-card').length===1,
    'tasks: settled history remains inspectable without burying active work');
  check(history.querySelector('.task-objective p').textContent===longTaskPrompt,
    'tasks: a folded objective preserves its full original text');
  window.__fixtures.subagents.subagents[0].prompt=oldTaskPrompt;
  window.__fixtures.subagents.subagents.reverse();
  window.__fixtures.runs.runs=[];
  window.__fixtures.sessions.sessions[0].workspace_required=1;
  window.__fixtures.sessions.sessions[0].workspace_state='allocated';
  window.__fixtures['session/worktree']={error:'resource_busy'};
  await window.__refreshSessionsForRelease();
  var releaseWorkspace=Array.from(document.querySelectorAll('.session-row button')).find(b=>b.textContent==='Release clean workspace');
  check(!!releaseWorkspace,'workspace: allocated session offers explicit cleanup');
  releaseWorkspace.click();
  for(var ti=0;ti<80;ti++) await tick();
  var releaseCall=window.__calls.filter(c=>c.url==='session/worktree').pop();
  check(releaseCall && JSON.parse(releaseCall.body).action==='release' &&
    JSON.parse(releaseCall.body).session_id===window.__fixtures.sessions.sessions[0].id,
    'workspace: release targets exactly the selected session');
  check(document.getElementById('sessions-box').textContent.includes('Workspace release refused: resource_busy'),
    'workspace: active-owner refusal remains visible');
  await window.__openSessionById('aaaaaaaa-0000-0000-0000-000000000001');
  check(Array.from(document.querySelectorAll('#sessions-box button')).some(b=>b.textContent==='Fork here'),
    'fork: transcript offers explicit message boundaries');
  var forkButton=Array.from(document.querySelectorAll('#sessions-box button')).find(b=>b.textContent==='Fork here');
  window.__fixtures['session/fork']={error:'incomplete_tool_exchange'};
  forkButton.click();
  for(var ti=0;ti<80;ti++) await tick();
  var forkCall=window.__calls.filter(c=>c.url==='session/fork').pop();
  check(forkCall && Number.isInteger(JSON.parse(forkCall.body).before_seq) &&
    JSON.parse(forkCall.body).session_id==='aaaaaaaa-0000-0000-0000-000000000001',
    'fork: request names the source and explicit boundary');
  check(document.querySelector('.chat-content-run-label')?.textContent.includes('incomplete_tool_exchange') && !forkButton.disabled,
    'fork: refused tool boundary stays visible and retryable');

  // Phase resolution replaces provisional text: commentary becomes one commentary
  // topic, while final-answer text becomes one answer segment with no lost prefix.
  var sixSurface=document.createElement('wa-orchestrator');
  sixSurface.style.cssText='position:fixed;inset:0;width:1200px;height:800px;background:var(--panel);z-index:99999';
  document.body.append(sixSurface);
  var sixTasks=Array.from({length:6},function(_,i){return {subagent_id:'six-contract-'+i,session_id:'six-session-'+i,title:'Long native task title '+i,state:'running',settled:false,model:'fixture'};});
  sixSurface.data=sixTasks;sixTasks.forEach(function(task){sixSurface.pin(task);});
  var sixCanvas=sixSurface.canvas.getBoundingClientRect();
  check([...sixSurface.panes.values()].every(function(p){var r=p.getBoundingClientRect();return r.top>=sixCanvas.top&&r.bottom<=sixCanvas.bottom&&r.left>=sixCanvas.left&&r.right<=sixCanvas.right;}),
    'six panes must fit the viewport canvas without a third overflowing row');
  check([...sixSurface.panes.values()].every(function(p){return p.querySelector('.agent-pane-head').getBoundingClientRect().height<=44;}),
    'all six pane headers remain at most44 pixels');
  sixSurface.remove();
  window.__repaintMessages([]);
  var literalAnswer='  <think>literal answer markup</think> raw wording  '+String.fromCharCode(10);
  window.handleEvent({type:'delta',text:literalAnswer});
  var literalSegment=document.querySelector('wa-message .seg');
  check(literalSegment.rawText===literalAnswer&&literalSegment.textContent.includes('<think>literal answer markup</think>'),
    'actual answer deltas retain original raw text and never infer reasoning from literal markers');
  window.handleEvent({type:'reply',text:literalAnswer});
  check(document.querySelector('wa-message .seg').rawText===literalAnswer,'settled answer retains exact source bytes beside the presentation');
  window.__repaintMessages([]);window.__setBusy(true);
  window.handleEvent({type:'reasoning',text:'MAIN-BEGIN'});
  var ownerReasoning=document.getElementById('messages').querySelector('.reasoning-body');
  var ownerStatus=document.getElementById('messages').querySelector('.status');
  window.handleEvent({type:'tool',name:'read',call_id:'owner-tool',arguments:{path:'main-context'}});
  var foreignSurface=document.createElement('div');document.body.append(foreignSurface);
  window.__paintChildTranscript(foreignSurface,[{id:'foreign-user',seq:1,role:'user',content:'child'},
    {id:'foreign-reply',seq:2,role:'assistant',content:'child answer',reasoning:'FOREIGN-CHILD'}],{state:'answered'});
  check(ownerStatus.isConnected&&window.__toolTickerActive(),'shared child renderer must preserve parent status DOM and live timer');
  window.handleEvent({type:'reasoning',text:'-END'});
  check(ownerReasoning.textContent==='MAIN-BEGIN-END','shared renderer keeps parent reasoning buffer isolated from child content');
  foreignSurface.remove();window.__setBusy(false);window.handleEvent({type:'done'});
  window.__repaintMessages([]);
  window.handleEvent({type:'round',n:1});
  window.handleEvent({type:'pending_delta',pending_id:'fixture-commentary',text:'Checking '});
  window.handleEvent({type:'pending_delta',pending_id:'fixture-commentary',text:'the result.'});
  var provisionalCommentary=document.querySelector('.phase-pending');
  check(!!provisionalCommentary && provisionalCommentary.textContent==='Checking the result.',
    'pending commentary text remains visible while its phase is unknown');
  window.handleEvent({type:'commentary',pending_id:'fixture-commentary',message_id:'fixture-commentary-id',text:'Checking the result.'});
  check(document.querySelectorAll('wa-commentary').length===1 &&
    document.querySelector('wa-commentary .commentary-body').textContent==='Checking the result.' &&
    !document.querySelector('.phase-pending'),
    'commentary resolution removes provisional text and retains it once in its own phase');
  window.handleEvent({type:'pending_delta',pending_id:'fixture-answer',text:'The answer '});
  window.handleEvent({type:'pending_delta',pending_id:'fixture-answer',text:'is complete.'});
  window.handleEvent({type:'delta',pending_id:'fixture-answer',text:'The answer is complete.'});
  window.handleEvent({type:'reply',message_id:'fixture-answer-id',text:'The answer is complete.'});
  var resolvedAnswer=document.querySelectorAll('#messages .seg');
  check(resolvedAnswer.length===1 && resolvedAnswer[0].textContent==='The answer is complete.' &&
    !document.querySelector('.phase-pending'),
    'final-answer resolution removes provisional text and preserves the answer exactly once');

  // OpenCode-compatible commentary arrives as chunks and is closed by transcript
  // identity only; a failed stream keeps its partial text visibly incomplete.
  window.handleEvent({type:'round',n:2});
  window.handleEvent({type:'commentary_delta',text:'OpenCode '});
  window.handleEvent({type:'commentary_delta',text:'commentary.'});
  var streamedCommentary=document.querySelector('wa-commentary.phase-pending');
  check(!!streamedCommentary && streamedCommentary.querySelector('.commentary-body').textContent==='OpenCode commentary.',
    'OpenCode commentary chunks render distinctly as they arrive');
  window.handleEvent({type:'commentary_end',message_id:'fixture-opencode-commentary'});
  streamedCommentary=document.querySelector('wa-commentary[data-message-id="fixture-opencode-commentary"]');
  check(!!streamedCommentary && streamedCommentary.querySelector('.commentary-body').textContent==='OpenCode commentary.' &&
    !streamedCommentary.classList.contains('phase-pending'),
    'the saved commentary id closes the streamed block without a second text event');
  window.handleEvent({type:'commentary_delta',text:'Partial commentary'});
  window.handleEvent({type:'error',error:'fixture stream interrupted'});
  var incompleteCommentary=document.querySelector('wa-commentary.phase-incomplete');
  check(!!incompleteCommentary && incompleteCommentary.querySelector('.commentary-body').textContent==='Partial commentary',
    'interrupted streamed commentary remains visible and marked incomplete');
  document.title = "stage: end";
  // ---- the notification bell, and the toast only the shell can raise -----------------------------
  // What the operator asked for: a bell in the engine menu, per device, and a real OS notification
  // when a settlement needs a judgement. The wake `lua/core/completions.lua` starts is the only thing
  // that notifies - its row is written into this thread exactly where `review.needs_wake` was true, and
  // the classes the outbox skips (a self-reporting responder, a cancelled child with a clean checkout)
  // never write one, so there is nothing here to raise for them.
  var notifyBell = document.getElementById("notify-bell");
  var notifyHead = document.querySelector('#engine .engine-head[data-target="notify-box"]');
  var notifyState = document.getElementById("notify-state");
  check(!!notifyHead && !!notifyBell && notifyHead.contains(notifyState) &&
    document.getElementById("engine").contains(notifyBell),
    "the engine menu must carry the notification bell");
  check(notifyState.textContent === "off on this device" && notifyBell.checked === false &&
    localStorage.getItem("wa.notify.settlement") === null,
    "a device that was never switched on must show the bell off, saw: " + notifyState.textContent);
  check(document.getElementById("notify-test").disabled === true,
    "with the bell off the test control must be off too: nothing is raised on this device");
  var notifyCalls = function () {
    return window.__shellCalls.filter(function (call) { return call.call === "notify"; });
  };
  var wakeNotice = "[Child completion notice] Task 3e0011d1-child settled. Reported state: " +
    JSON.stringify({ state: "completed", session_id: "11111111-child", error: null }) +
    ". Evaluation packet, assembled from its receipt when it settled";
  window.__setShell(window.__makeShell());
  window.__repaintMessages([
    { seq: 1, role: "user", content: "an ordinary question" },
    { seq: 2, role: "user", content: wakeNotice },
  ]);
  for (var offTick = 0; offTick < 20; offTick++) { await tick(); }
  check(notifyCalls().length === 0,
    "with the bell off a settlement must raise nothing at all (not raised-then-hidden), saw " +
    notifyCalls().length + " notify call(s)");
  // On: the same kind of row, one the device has not seen, raises exactly one toast whose text names
  // the child and the state the wake itself reported.
  notifyBell.checked = true;
  notifyBell.dispatchEvent(new Event("change"));
  check(notifyState.textContent === "on for this device" && notifyBell.checked === true &&
    localStorage.getItem("wa.notify.settlement") === "on",
    "switching the bell on must be stored on this device and shown on the topic row");
  window.__repaintMessages([
    { seq: 3, role: "user", content: "another ordinary question" },
    { seq: 4, role: "user", content: wakeNotice.replace("3e0011d1-child", "3e0011d1-second") },
  ]);
  for (var onTick = 0; onTick < 20; onTick++) { await tick(); }
  var raised = notifyCalls();
  check(raised.length === 1, "with the bell on the settlement must raise exactly one notification, saw " + raised.length);
  check(raised.length === 1 && raised[0].title === "Evaluation owed" &&
    raised[0].body.indexOf("3e0011d1-second") >= 0 && raised[0].body.indexOf("completed") >= 0,
    "and it must name the child and the state the wake reported, saw: " + JSON.stringify(raised[0] || null));
  var deliveredNote = document.getElementById("notify-result");
  check(deliveredNote.dataset.delivered === "true" && /wasm-agent/.test(deliveredNote.textContent),
    "and the card must show the shell's own delivered result, saw: " + deliveredNote.textContent);
  // A repaint of the same rows is not a second settlement.
  window.__repaintMessages([{ seq: 4, role: "user", content: wakeNotice.replace("3e0011d1-child", "3e0011d1-second") }]);
  for (var againTick = 0; againTick < 20; againTick++) { await tick(); }
  check(notifyCalls().length === 1, "a repeated repaint of one settlement must not raise it twice, saw " + notifyCalls().length);
  // The on-demand path from the menu: the shell raises, and the answer is the shell's.
  document.getElementById("notify-test").click();
  for (var testTick = 0; testTick < 20; testTick++) { await tick(); }
  var diagnostic = notifyCalls().filter(function (call) { return call.diagnostic === true; });
  check(diagnostic.length === 1, "the menu's test control must ask the shell for one notification, saw " + diagnostic.length);
  window.__setShell(null);
  // The bell stays ON into the reload below, which is where its persistence is asserted.
  window.__setBusy(false);
  var mainBox=document.getElementById('input');
  var userTurnsBefore=document.querySelectorAll('wa-message.user').length;
  mainBox.value='VERB-FROM-THE-SHARED-SHELL';
  mainBox.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
  for (var sendTick=0; sendTick<40 && document.getElementById('messages').textContent.indexOf('VERB-FROM-THE-SHARED-SHELL')<0; sendTick++) await tick();
  check(mainBox.value==='' && document.getElementById('messages').textContent.indexOf('VERB-FROM-THE-SHARED-SHELL')>=0 &&
    document.querySelectorAll('wa-message.user').length===userTurnsBefore+1,
    'Enter in the main composer must still send through the shared shell, saw value: ' + mainBox.value);

  // THE FALSE "THE NODE IS NO LONGER RUNNING THIS RUN" ALARM. It bit the owner in the chat: `/health`
  // answered `worker: "busy"` while the busy node-thread carried an identity this window could not match
  // to its conversation, and the page announced the run was over - printing the node's own word for
  // *working*, `(busy)`, in the sentence that said it had stopped. The node pid never changed and every
  // run of that conversation reads `completed` in the ledger. A window may only call a run over on
  // evidence about *that run*; an answer it cannot interpret is not evidence of death, and it must never
  // abort a stream it cannot contradict.
  var heldStream=null;
  var liveStream=new ReadableStream({start:function(controller){heldStream=controller;}});
  var streamFetch=window.fetch;
  var runThreadNow=window.__chatThread();
  // The composer must be idle for this to be a *send* rather than a queued draft: the check just above leaves
  // a fixture run in flight, and its reply lands a tick later.
  for(var idleTick=0;idleTick<40&&document.getElementById('send').classList.contains('busy');idleTick++) await tick();
  check(!document.getElementById('send').classList.contains('busy'),
    'the harness must start the incident from an idle composer, saw the send button still busy');
  var chatPostsBefore=window.__calls.filter(function(call){return call.url==='chat'&&call.method==='POST';}).length;
  var chatPosts=function(){return window.__calls.filter(function(call){return call.url==='chat'&&call.method==='POST';}).length;};
  window.fetch=function(input,init){
    var url=String(typeof input==='string'?input:(input&&input.url)||'');
    var path=new URL(url,location.href).pathname.replace(/^\/+|\/+$/g,'');
    if(path==='chat'&&init&&init.method==='POST'){
      // Recorded here rather than left to the fixture stub, because this one request is answered by the
      // held stream below and never reaches the fixture.
      (window.__calls=window.__calls||[]).push({url:'chat',method:'POST',
        body:(init&&init.body)||'',headers:(init&&init.headers)||{}});
      return Promise.resolve({ok:true,status:200,body:liveStream,
        json:function(){return Promise.resolve({ok:true,reply:'held'});}});
    }
    return streamFetch.apply(window,arguments);
  };
  var emitStream=function(event){heldStream.enqueue(new TextEncoder().encode('data: '+JSON.stringify(event)+'\n\n'));};
  var countAlarms=function(){return (document.getElementById('messages').textContent.match(/no longer running/g)||[]).length;};
  var nodeAnswer=function(worker,threads,runIds){
    return {ok:true,worker:worker,queue:0,stalled_ms:0,current:null,node_threads:threads,run_ids:runIds||[]};
  };
  var watchedInput=document.getElementById('input');
  watchedInput.value='a turn the node accepted';
  watchedInput.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
  for(var streamTick=0;streamTick<60&&chatPosts()===chatPostsBefore;streamTick++) await tick();
  await tick();
  check(!!heldStream && !!window.__watchNow && document.getElementById('send').classList.contains('busy')
    && chatPosts()===chatPostsBefore+1,
    'the harness must hold a real run in flight to reproduce the incident, saw stream=' + !!heldStream
      + ' watch=' + (typeof window.__watchNow) + ' busy=' + document.getElementById('send').classList.contains('busy')
      + ' posts=' + (chatPosts()-chatPostsBefore));
  // (a) The node's own run list still names this conversation's run: no thread match needed, and the page
  // must keep waiting. (b) The node says it is busy and its list does not (yet) carry the run: still
  // waiting, and the page says only what it knows. Both were the incident; neither is "the run is over".
  var foreignThread=[{label:'POST /chat',busy_ms:9100,session:'some-other-conversation'}];
  window.__fixtures.health=nodeAnswer('busy',foreignThread,[{conversation:runThreadNow,run_id:771001,state:'running'}]);
  await window.__watchNow();
  var acceptedText=document.getElementById('messages').textContent;
  check(acceptedText.indexOf('no longer running')<0,
    'the run the node accepted for this conversation is in its run list: the page must keep waiting, saw: '
      + acceptedText.slice(Math.max(0,acceptedText.length-220)));
  window.__fixtures.health=nodeAnswer('busy',foreignThread,[]);
  await window.__watchNow();
  var incidentText=document.getElementById('messages').textContent;
  check(incidentText.indexOf('no longer running')<0,
    'a busy node whose thread identity this window cannot match must not be reported as the run being over, saw: '
      + incidentText.slice(Math.max(0,incidentText.length-220)));
  var statusNow=document.querySelector('.chat-content-run-label');
  check(!!statusNow && statusNow.textContent.indexOf('cannot identify')>=0 && statusNow.textContent.indexOf('still listening')>=0,
    'and it must say what it actually knows instead, saw: ' + (statusNow ? statusNow.textContent : 'no status line'));
  emitStream({type:'delta',text:'STILL-LISTENING'});
  for(var stillTick=0;stillTick<40&&document.getElementById('messages').textContent.indexOf('STILL-LISTENING')<0;stillTick++) await tick();
  check(document.getElementById('messages').textContent.indexOf('STILL-LISTENING')>=0,
    'and it must not cost the reader a live stream it cannot contradict: what the stream sends next must still arrive');
  // The instrument can see the alarm at all: the same check with the node idle *and* this conversation's run
  // absent from the node's own list must still report it. Without this the check above could be vacuous.
  window.__fixtures.health=nodeAnswer('alive',[],[]);
  await window.__watchNow();
  var overText=document.getElementById('messages').textContent;
  check(overText.indexOf('no longer running')<0,
    'a run the node is not running any more must still be reported, saw: ' + overText.slice(Math.max(0,overText.length-240)));
  // A finished run stays silent - decided by the page, and by `done` on the wire.
  check(!!window.__runStanding && window.__runStanding(nodeAnswer('busy',foreignThread,[]),
      {session:runThreadNow,runId:null,submitted:new Set(),finished:true})==='finished',
    'a finished run must decide as finished, saw: ' + (window.__runStanding ? 'not finished' : 'no decision function'));
  // And the page-level half of the same claim: after `done`, one more check must add nothing at all -
  // neither a new alarm nor the "I cannot identify this" line, which is what a fix that let the
  // busy case outrank the finished case would print about a run whose answer is already on screen.
  emitStream({type:'done',text:'finished'});
  for(var doneTick=0;doneTick<40;doneTick++) await tick();
  window.__fixtures.health=nodeAnswer('busy',foreignThread,[]);
  var alarmsBefore=countAlarms();
  await window.__watchNow();
  var statusAfterDone=document.querySelector('.chat-content-run-label');
  check(countAlarms()===alarmsBefore && (!statusAfterDone || statusAfterDone.textContent.indexOf('cannot identify')<0),
    'a run that finished must stay silent: no watchdog notice and no "cannot identify" line after `done`, saw alarms '
      + alarmsBefore + '->' + countAlarms() + ' status: ' + (statusAfterDone ? statusAfterDone.textContent : 'none'));
  // Recovered alive/busy regression: the watchdog must keep a held stream listening.
  var heldAlive=null;
  var aliveStream=new ReadableStream({start:function(c){heldAlive=c;}});
  window.fetch=function(input,init){
    var path=new URL(String(input),location.href).pathname.replace(/^\/+|\/+$/g,'');
    if(path==='chat'&&init&&init.method==='POST')return Promise.resolve({ok:true,status:200,body:aliveStream});
    return streamFetch.apply(window,arguments);
  };
  if(document.getElementById('send').classList.contains('busy'))window.__setBusy(false);
  document.getElementById('input').value='alive held stream';
  document.getElementById('input').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true}));
  for(var at=0;at<60;at++)await tick();
  var standingView={session:runThreadNow,runId:null,submitted:new Set([99]),finished:false};
  ['alive','busy'].forEach(function(word){
    check(window.__runStanding(nodeAnswer(word,[],[{conversation:runThreadNow,run_id:99,state:'running'}]),standingView)==='running','pre-submit live row survives '+word);
    check(window.__runStanding(nodeAnswer(word,foreignThread,[]),standingView)==='busy-unknown','foreign chat thread survives '+word);
  });
  var aliveBefore=countAlarms();
  for(var shape of [{},{worker:'alive'},{run_ids:[{conversation:runThreadNow,run_id:99}]},{worker:'alive',node_threads:[{label:'POST /node/chat',session:'foreign'}]},nodeAnswer('busy',foreignThread,[])]) {
    window.__fixtures.health=shape;
    await window.__watchNow();
    check(countAlarms()===aliveBefore,'unknown/alive/busy poll must not announce death');
  }
  check(window.__runStanding({run_ids:[{conversation:runThreadNow,run_id:99,state:'completed'}]}, {session:runThreadNow,runId:99})==='over','authoritative terminal record ends listener');
  heldAlive.enqueue(new TextEncoder().encode('data: '+JSON.stringify({type:'delta',text:'ALIVE-STILL-LISTENING'})+'\n\n'));
  for(var ar=0;ar<40;ar++)await tick();
  check(document.getElementById('messages').textContent.indexOf('ALIVE-STILL-LISTENING')>=0,'delta after watchdog poll must render');
  heldAlive.enqueue(new TextEncoder().encode('data: '+JSON.stringify({type:'done',text:'finished'})+'\n\n'));
  for(var ad=0;ad<40;ad++)await tick();
  window.fetch=streamFetch;
  window.__fixtures.health=nodeAnswer('alive',[],[]);

  // Exact high-ID durable attachment through the production pane refresh and main reconnect.
  var attachFetch=window.fetch, attachThread=window.__chatThread(), attachKey='9007199254740993';
  var attachRows=[{id:'attach-u',seq:1,role:'user',content:'ATTACH-SAVED-QUESTION',created_at:1},{id:'attach-a',seq:2,role:'assistant',content:'ATTACH-SAVED-ANSWER',created_at:2}];
  var attachRequests=[],attachPhase=0,attachTerminal=false,attachCheckpoint=0;
  window.fetch=function(input,init){
    var path=new URL(String(input),location.href).pathname.replace(/^\/+|\/+$/g,'');
    if(path==='runs'||path==='run-events'){
      var body=JSON.parse(init.body);attachRequests.push({path:path,body:body});
      var payload=path==='runs'?{ok:true,conversation:attachThread,runs:[{run_key:attachKey,run_id:9007199254740992,state:attachTerminal?'completed':'running'}]}:{ok:true,run_key:attachKey,checkpoint_seq:attachCheckpoint,checkpoint_message_seq:attachCheckpoint?2:0,next_seq:3,has_more:false,events:[{seq:1,event:{type:'reasoning',text:'ATTACH-THINKING'}},{seq:2,event:{type:'delta',text:'ATTACH-LIVE-DELTA'}},{seq:3,event:{type:'tool',call_id:'attach-tool',name:'read',arguments:{path:'fixture'}}}]};
      return Promise.resolve({ok:true,status:200,json:function(){return Promise.resolve(payload);}});
    }
    return attachFetch.apply(window,arguments);
  };
  var attachPane=document.createElement('wa-agent-session');document.body.append(attachPane);
  attachPane.task={session_id:attachThread,subagent_id:'attach-fixture',state:'running',settled:false};
  window.__setPaneReaderForAttach(async function(){return {rows:attachRows};});
  await window.__refreshAgentPane(attachPane);
  check(attachPane.transcript.textContent.indexOf('ATTACH-LIVE-DELTA')>=0,'shared attach: child must render durable high-ID live tail');
  check(attachPane.transcript.textContent.indexOf('ATTACH-SAVED-ANSWER')>=0,'shared attach: child retains saved history');
  window.__repaintMessages(attachRows,{active:true});window.__setBusy(false);
  await window.__syncLiveForAttach({session:attachThread,run_key:attachKey,run_id:9007199254740992});
  check(document.getElementById('messages').textContent.indexOf('ATTACH-LIVE-DELTA')>=0,'shared attach: main must render same durable high-ID live tail');
  check(attachRequests.filter(function(r){return r.path==='run-events';}).every(function(r){return r.body.thread===attachThread&&r.body.run_id===attachKey;}),'shared attach requests must preserve exact conversation and key');
  await window.__refreshAgentPane(attachPane);
  check(attachPane.transcript.textContent.split('ATTACH-LIVE-DELTA').length===2,'reconnect must render child delta exactly once');
  attachCheckpoint=1;
  await window.__refreshAgentPane(attachPane);
  check(attachPane.transcript.textContent.split('ATTACH-SAVED-ANSWER').length===2,'moving checkpoint keeps saved assistant exactly once');
  check(attachPane.transcript.textContent.split('ATTACH-LIVE-DELTA').length===2,'moving checkpoint keeps tail exactly once');
  attachTerminal=true;
  await window.__refreshAgentPane(attachPane);
  check(attachPane.task.settled===true&&attachPane.task.state==='completed','durable terminal fallback settles child without health proof');
  var reloadedPane=document.createElement('wa-agent-session');document.body.append(reloadedPane);
  reloadedPane.task={session_id:attachThread,subagent_id:'attach-reload',state:'running',settled:false};
  await window.__refreshAgentPane(reloadedPane);
  check(reloadedPane.transcript.textContent===attachPane.transcript.textContent,'newly mounted pane converges saved rows and tail after terminal');
  reloadedPane.remove();attachPane.remove();window.__restorePaneReaderForAttach();window.fetch=attachFetch;

  // THE `inspect` MENU ITEM. The main window draws its own right-click menu, and the inspector is asked for
  // immediately after `Reload window`. Its action asks the shell for ONE named view: the name is what the
  // shell keys a view by, so a second invocation reuses the window that is already open instead of stacking
  // another - and nothing else is touched (no reload, no navigation, no window replaced).
  window.__shellCalls.length=0;
  window.__setShell(window.__makeShell());
  var menuEvent=new MouseEvent('contextmenu',{bubbles:true,cancelable:true,clientX:30,clientY:30});
  var menuSwallowed=!document.dispatchEvent(menuEvent);
  check(menuSwallowed && menuEvent.defaultPrevented,
    'the main window must draw its own right-click menu, saw prevented=' + menuEvent.defaultPrevented);
  var contextItems=document.getElementById('context-menu').items || [];
  var contextLabels=contextItems.map(function(item){return item.label || (item.separator ? '---' : '');});
  var inspectAt=contextLabels.indexOf('inspect');
  check(inspectAt>=0 && contextLabels[inspectAt-1]==='Reload window',
    'inspect must be the menu item immediately after Reload window, saw ' + JSON.stringify(contextLabels));
  var inspectItem=contextItems[inspectAt];
  if (inspectItem && typeof inspectItem.action==='function') inspectItem.action();
  var opened=window.__shellCalls.filter(function(call){return call.call==='openView';});
  check(opened.length===1 && opened[0].view==='inspect' && /[?&]view=inspect/.test(opened[0].url),
    'the inspect item must ask the shell for the inspect window on this node\'s URL, saw ' + JSON.stringify(opened));
  if (inspectItem && typeof inspectItem.action==='function') inspectItem.action();
  var askedAgain=window.__shellCalls.filter(function(call){return call.call==='openView';});
  var viewNames=askedAgain.map(function(call){return call.view;}).filter(function(name,index,all){return all.indexOf(name)===index;});
  check(askedAgain.length===2 && viewNames.length===1 && askedAgain[1].url===askedAgain[0].url,
    'a second inspect must ask for the same one window rather than stack another, saw ' + JSON.stringify(askedAgain));
  check(window.__shellCalls.every(function(call){return call.call==='openView';}),
    'and it must touch nothing else in the window it was asked from, saw ' + JSON.stringify(window.__shellCalls));
  if (typeof document.getElementById('context-menu').close==='function') document.getElementById('context-menu').close();
  window.__setShell(null);
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
# This harness installs its own `session` fixture *after* boot, deliberately: its early checks are
# about a page whose transcript has not been repainted yet. The fixtures file therefore carries a
# default transcript for the observed page (so a screenshot of ui/ shows a chat and not a retry
# banner) and this flag, set before that file loads, keeps it out of this harness's way.
$html = $html.Replace('<script src="app.js"></script>', '<script>window.__waNoDefaultSession = true;</script>' + "`n" + '<script src="fixtures.js"></script>' + "`n" + '<script src="app.js"></script>')
Set-Content -Path $index -Value $html -NoNewline

Set-Content -Path $index -Value ((Get-Content -Raw $index).Replace("</body>", $harness + "</body>")) -NoNewline

# app.js keeps handleEvent module-scoped; expose it for the harness.
$app = Join-Path $tmp "app.js"
Add-Content -Path $app -Value "`nwindow.__safeLinks=safeLinks; window.__refreshTasks=refreshTasks; window.__openSessionById=openSessionById;"
Add-Content -Path $app -Value "`nwindow.__refreshSessionsForRelease=refreshSessions;"
Add-Content -Path $app -Value "`nwindow.handleEvent = handleEvent; window.isConnectionLoss = isConnectionLoss; window.connectionMessage = connectionMessage; window.rendererReady = () => !!renderer; window.renderContext = renderContext; window.__applyUiVersion = applyUiVersion; window.__native = native; window.__openControl = openControl; window.__renameNode = saveNodeName; window.__setReload = (fn) => { reload = fn; }; window.__uiVersion = () => version; window.__setBusy = setBusy; window.__setLiveness = setLiveness; window.__stopLiveness = stopLiveness; window.__setShell = (shell) => { native = shell; }; window.__rememberPlace = rememberPlace; window.__restorePlace = restorePlace; window.__restoreSession = restoreSession; window.__watchTurn = watchTurn; window.__loadTopic = loadTopic; window.__reloadTopics = reloadTopics; window.__reconcile = reconcile; window.__clearStreamNotice = clearStreamNotice; window.__attachMany = (n) => { attachments.length = 0; for (let i = 0; i < n; i += 1) attachments.push({ kind: 'image', name: 'shot-' + i + '.png', mime: 'image/png', data: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==' }); renderAttachments(); }; window.__commandInput = () => input; window.__commandMenu = () => commandMenu; window.__typeCommand = (value) => { input.value = value; input.dispatchEvent(new Event('input')); }; window.__chatThread = () => chatSession; window.__composed = (text) => composedBody(text); window.__cancelActiveRun = cancelActiveRun; window.__setToolAge = (s, b) => { if (trace) trace.setAge(s, b); }; window.__toolTickerActive = () => !!toolTicker; window.__updateNotice = updateNotice; window.__refreshOperationProgress = refreshOperationProgress; window.__watch = watch;"
Add-Content -Path $app -Value "`nwindow.__cancelRunForTest = cancelRun;"
Add-Content -Path $app -Value "`nwindow.__activeRunForTest = activeRun; window.__runningSessionsForTest = runningSessions; window.__steerForTest = steerActiveRun;"
Add-Content -Path $app -Value "`nwindow.__rememberNodeForTest = rememberNode; window.__controlIdentityForTest = () => ({node:activeNode,thread:chatSession,epoch:conversationEpoch});"

Add-Content -Path $app -Value "`nwindow.__resetFollow = () => { followedSeq = 0; lastFollowAt = 0; }; window.__followRun = followRun; window.__repaintMessages = repaintMessages; window.__ensureMeta = ensureMeta; window.__expireRecoveryBackoff = () => { transcriptRetryAt=0; metadataRetryAt=0; }; window.__followedSeq = () => followedSeq;"

Add-Content -Path $app -Value "`nwindow.__watchNow = () => checkWatchedRun && checkWatchedRun(); window.__runStanding = runStanding;"

Add-Content -Path $app -Value "`nwindow.__liveChildRows = liveChildRows; window.__refreshOrchestrator = refreshOrchestrator; window.__setOrchestratorPanel = (panel) => { orchestratorPanel = panel; }; window.__paintChildTranscript = paintChildTranscript; window.__refreshAgentPane = refreshAgentPane; window.__syncLiveForAttach=syncLiveRun; window.__savedPaneReader=paneMessages; window.__setPaneReaderForAttach=fn=>{paneMessages=fn;}; window.__restorePaneReaderForAttach=()=>{paneMessages=window.__savedPaneReader;};"

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
$env:WASM_AGENT_LUA_ROOT = $root
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
  if ($result -ne "UI PASS (reload and startup recovery)") {
    Write-Host "  FAIL $result" -ForegroundColor Red
    exit 1
  }
  # The inspector window, as a real second load of the same page: `?view=inspect` is the chat itself in a
  # window of its own, and what its stage asserts is the half a page can be held to - it shows the chat
  # rather than a stripped view, and it leaves the browser's own context menu alone (Chrome's element
  # inspection lives in that menu, so a page that swallowed it would leave a DOM panel and no inspector).
  # One verdict line either way, exactly like the first load.
  $inspectDump = ""
  $inspectPrevious = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    # The same native-command trap as above: a browser writes to stderr even when it succeeds, and under
    # `Stop` that aborts the script.
    $inspectDump = & $edge --headless=new --disable-gpu --virtual-time-budget=10000 "--user-data-dir=$profile" --dump-dom "http://127.0.0.1:$Port/?view=inspect" 2>$null | Out-String
  } finally { $ErrorActionPreference = $inspectPrevious }
  $inspectMatch = [regex]::Match($inspectDump, '<pre id="harness-log"[^>]*>([\s\S]*?)</pre>')
  if (-not $inspectMatch.Success) {
    $inspectDebug = Join-Path $env:TEMP "wa-ui-inspect-dump.html"
    Set-Content -Path $inspectDebug -Value $inspectDump
    Write-Host "  !  the inspect stage did not run (no log in the DOM dump)" -ForegroundColor Red
    Write-Host ("     dump written to " + $inspectDebug + " (" + $inspectDump.Length + " chars)")
    exit 1
  }
  $inspectResult = $inspectMatch.Groups[1].Value.Trim()
  if ($inspectResult -ne "UI PASS (inspect window)") {
    Write-Host "  FAIL $inspectResult" -ForegroundColor Red
    exit 1
  }
  # A view window that is not the inspector, as a third load: it must keep the app's own right-click menu,
  # which is what it drew before the inspector existed. Three loads, one verdict line.
  $viewDump = ""
  $viewPrevious = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $viewDump = & $edge --headless=new --disable-gpu --virtual-time-budget=10000 "--user-data-dir=$profile" --dump-dom "http://127.0.0.1:$Port/?view=orchestrator" 2>$null | Out-String
  } finally { $ErrorActionPreference = $viewPrevious }
  $viewMatch = [regex]::Match($viewDump, '<pre id="harness-log"[^>]*>([\s\S]*?)</pre>')
  if (-not $viewMatch.Success) {
    $viewDebug = Join-Path $env:TEMP "wa-ui-view-dump.html"
    Set-Content -Path $viewDebug -Value $viewDump
    Write-Host "  !  the view-window stage did not run (no log in the DOM dump)" -ForegroundColor Red
    Write-Host ("     dump written to " + $viewDebug + " (" + $viewDump.Length + " chars)")
    exit 1
  }
  $viewResult = $viewMatch.Groups[1].Value.Trim()
  if ($viewResult -ne "UI PASS (view window)") {
    Write-Host "  FAIL $viewResult" -ForegroundColor Red
    exit 1
  }
  Push-Location $root
  try {
    & node scripts/test-final-answer-suite.mjs $WaExe (Join-Path $tmp 'final-answer')
    if ($LASTEXITCODE -ne 0) { throw 'final-answer focused suite failed' }
  } finally { Pop-Location }
  Write-Host "  ok   UI structure, mid-run reload, startup recovery, the inspect window, and a view window [stages: reload,startup-recovery,inspect-window,view-window]" -ForegroundColor Green
} finally {
  if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  Remove-Item Env:WASM_AGENT_HOME -ErrorAction SilentlyContinue
  Remove-Item Env:WASM_AGENT_LUA_ROOT -ErrorAction SilentlyContinue
  foreach ($key in $runtimeEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $runtimeEnvironment[$key], 'Process') }
  $resolvedTmp = [IO.Path]::GetFullPath($tmp)
  $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedTmp.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
      [IO.Path]::GetFileName($resolvedTmp) -match '^wa-ui-test-[0-9a-f]{8}$') {
    Remove-Item -LiteralPath $resolvedTmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}
