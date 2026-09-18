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
    { type: "reply", text: "Final: it exists." },
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
  for (var i = upto; i < events.length; i++) window.handleEvent(events[i]);

  var messages = document.getElementById("messages");
  var bubbles = messages.querySelectorAll("wa-message.assistant");
  check(bubbles.length === 1, "expected one assistant bubble, saw " + bubbles.length);

  var bubble = bubbles[0];
  var body = bubble ? bubble.querySelector(".body") : null;
  check(!!body && body.classList.contains("steps"), "the bubble body should be a steps container");

  // Once the answer is ready the whole path collapses into one run topic, which
  // sits above the answer so the reader lands on the answer.
  var shape = body ? Array.prototype.map.call(body.children, function (c) {
    return c.tagName === "WA-RUN" ? "run" : (c.tagName === "WA-TRACE" ? "trace" : "text");
  }).join(",") : "";
  check(shape === "run,text", "expected run,text in the bubble after the reply, saw " + shape);

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
  check(runText.indexOf("2 decisions") >= 0, "the run topic should count its decisions, saw: " + runText);

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
  var updateNote = document.querySelector(".status");
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
  check(/used/.test(contextText) && /128/.test(contextText) && /%/.test(contextText),
    "the context panel must state used / budget / percent, saw: " + contextText);

  // Markdown: a model answering with a table must get a table. Pipes are not
  // something a reader can reconstruct. The renderer arrives over the node's
  // static path, so this is real I/O: wait for it before dispatching the reply,
  // otherwise the reply is rendered by the escape-and-<br> fallback.
  if (window.rendererLoaded) { await window.rendererLoaded; }
  check(!!(window.rendererReady && window.rendererReady()),
    "the WASM markdown renderer must be loaded for this case: " + (window.__rendererError || "no error recorded"));
  window.handleEvent({
    type: "reply",
    text: "| tool | legacy | default |\n|---|--:|--:|\n| read | 4.0 | 3.0 |\n\n## Next\n\n- keep the payload\n- budget the context",
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

  // A reasoning model thinks before it speaks, and a panel that shows nothing
  // during that time is indistinguishable from a hung one. The count is also the
  // number that explains where the output budget went when a turn ends with no
  // answer at all.
  window.handleEvent({ type: "reasoning", chars: 4096 });
  var reasoningStatus = document.querySelector(".status");
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
  var statusLine = document.querySelector(".status");
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
  // The sessions view is a topic inside the engine: opening the engine alone
  // does not fetch it, so click the way a reader would.
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
  var rows = document.querySelectorAll("#nodes-box .node");
  for (var r = 0; r < rows.length; r += 1) {
    if (/\bclient\b/.test(rows[r].textContent)) clientRow = rows[r];
  }
  check(clientRow === null, "the client executor must not be a row of its own");
  var controlButtons = 0;
  for (var c = 0; c < rows.length; c += 1) {
    if (/control/.test(rows[c].textContent)) controlButtons += 1;
  }
  check(controlButtons === 1, "the control view must still be reachable, saw " + controlButtons + " control button(s)");
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
  var nodesText = document.getElementById("nodes-box").textContent;
  check(/foundation/.test(nodesText) && /openclaw/.test(nodesText),
    "both nodes must be listed, saw: " + nodesText.slice(0, 120));

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
  var posted = (window.__calls || []).filter(function (call) {
    return call.url.indexOf("node/name") >= 0 && call.method === "POST";
  });
  check(posted.length === 1, "the rename must be sent to the node, saw " + posted.length);
  check(posted.length === 1 && JSON.parse(posted[0].body).name === "renamed-by-the-test",
    "and it must carry the new name, saw: " + (posted[0] ? posted[0].body : "nothing"));

  // A lost connection has to be classified: that is what turns a raw TypeError
  // into something a reader can act on, and it is checkable without a network.
  var classify = window.__classifyProbe ? window.__classifyProbe() : ["the classify probe is missing"];
  for (var c = 0; c < classify.length; c++) { problems.push(classify[c]); }

  document.title = "stage: end";
} catch (error) {
    // A throw must still produce a log: a reporter that swallows its own failure is worse
    // than none, and "the harness did not run" is a symptom with no cause.
    problems.push("the harness threw: " + ((error && error.stack) || error));
  }
  document.title = "stage: logging";
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
Add-Content -Path $app -Value "`nwindow.handleEvent = handleEvent; window.isConnectionLoss = isConnectionLoss; window.connectionMessage = connectionMessage; window.rendererReady = () => !!renderer; window.renderContext = renderContext; window.__applyUiVersion = applyUiVersion; window.__native = native; window.__openControl = openControl; window.__renameNode = saveNodeName; window.__setReload = (fn) => { reload = fn; }; window.__uiVersion = () => version; window.__setBusy = setBusy; window.__attachMany = (n) => { attachments.length = 0; for (let i = 0; i < n; i += 1) attachments.push({ kind: 'image', name: 'shot-' + i + '.png', data: 'data:image/png;base64,iVBORw0KGgo=' }); renderAttachments(); };"

$server = $null
$edge = @(
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { Write-Host "  !  no Edge or Chrome found"; exit 1 }

try {
  $server = Start-Process -FilePath $WaExe -ArgumentList @("serve", "--port", "$Port", "--client-port", "$ClientPort", "--ui", $tmp) -WindowStyle Hidden -PassThru
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
    $dump = & $edge --headless=new --disable-gpu --dump-dom "http://127.0.0.1:$Port/" 2>$null | Out-String
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
  if ($result -like "UI PASS*") {
    Write-Host "  ok   UI structure: reply bubble and run topic, plus the unfinished-session badge in the engine view" -ForegroundColor Green
  } else {
    Write-Host "  FAIL $result" -ForegroundColor Red
    exit 1
  }
} finally {
  if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
