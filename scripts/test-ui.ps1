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
  var problems = [];
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
  check(strip.clientHeight <= 216, "the strip must cap its height at ~215px, saw " + strip.clientHeight + "px");
  check(strip.scrollHeight > strip.clientHeight + 40,
    "and the overflow must be scrollable, saw scrollHeight " + strip.scrollHeight + " vs " + strip.clientHeight);
  check(Math.abs(strip.clientHeight - 215) <= 1,
    "the cap must be 215px (3.5 cards), saw " + strip.clientHeight + "px");
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

  // A lost connection has to be classified: that is what turns a raw TypeError
  // into something a reader can act on, and it is checkable without a network.
  var classify = window.__classifyProbe ? window.__classifyProbe() : ["the classify probe is missing"];
  for (var c = 0; c < classify.length; c++) { problems.push(classify[c]); }

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
Add-Content -Path $app -Value "`nwindow.handleEvent = handleEvent; window.isConnectionLoss = isConnectionLoss; window.connectionMessage = connectionMessage; window.rendererReady = () => !!renderer; window.renderContext = renderContext; window.__attachMany = (n) => { attachments.length = 0; for (let i = 0; i < n; i += 1) attachments.push({ kind: 'image', name: 'shot-' + i + '.png', data: 'data:image/png;base64,iVBORw0KGgo=' }); renderAttachments(); };"

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
