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
(function () {
  var problems = [];
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
  for (var i = 0; i < events.length; i++) window.handleEvent(events[i]);

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

  // The context section is a summary row and a seeker, not a four-row table:
  // "taken" and "budget" fold into one ratio, and the percentage rides with it.
  // The log lives outside the harness IIFE so the late (async) part can write it.
  window.__uiProblems = problems;
  window.__uiLog = function () {
    var node = document.getElementById("harness-log");
    if (!node) { node = document.createElement("pre"); node.id = "harness-log"; document.body.appendChild(node); }
    node.textContent = problems.length ? ("UI FAIL: " + problems.join(" ;; ")) : "UI PASS";
    node.style.cssText = "position:fixed;top:0;left:0;z-index:99;background:#000;color:#0f0;font:12px monospace;padding:6px";
  };
  window.__uiLog();

  // The context section is a summary row and a seeker, not a four-row table:
  // "taken" and "budget" fold into one ratio, and the percentage rides with it.
  // A reader asked for exactly this shape, so the shape is what gets asserted.
  // The balloon renders it from settings fetched by refreshMeta, and that fetch is
  // a real promise, so the assertions run late - which is why the window is kept
  // open (--virtual-time-budget) and the log is written by a separate function.
  setTimeout(function () {
    document.getElementById("status-btn").click();
    var contextBox = document.getElementById("context-box");
    // Two lines: one string line and one seeker. The string line is a label + value
    // pair (SPAN + B), so "one pair, one meter" is the check - a bare child count
    // would call the pair itself two lines.
    var cells = contextBox ? contextBox.querySelectorAll(":scope > span, :scope > b").length : 0;
    var seekers = contextBox ? contextBox.querySelectorAll(":scope > .meter").length : 0;
    check(cells === 2, "the context section must be one string line, saw " + cells + " cell(s)");
    check(seekers === 1, "the context section must have one seeker, saw " + seekers);
    check(!!(contextBox ? contextBox.querySelector(".meter") : null), "the seeker is the second line");
    var contextText = contextBox ? contextBox.textContent : "";
    check(contextText.indexOf("taken") < 0, "the context section must not spell out 'taken', saw: " + contextText);
    check(contextText.indexOf("budget") < 0, "the context section must not spell out 'budget', saw: " + contextText);
    check(contextText.indexOf("used") < 0, "the context section must not spell out 'used', saw: " + contextText);
    check(contextText.indexOf(" / ") >= 0, "the ratio must be in the summary row, saw: " + contextText);
    check(/\d+%/.test(contextText), "the percentage must ride in the summary row, saw: " + contextText);
    window.__uiLog();
  }, 1200);
})();
</script>
'@
$index = Join-Path $tmp "index.html"
Set-Content -Path $index -Value ((Get-Content -Raw $index).Replace("</body>", $harness + "</body>")) -NoNewline

# app.js keeps handleEvent module-scoped; expose it for the harness.
$app = Join-Path $tmp "app.js"
Add-Content -Path $app -Value "`nwindow.handleEvent = handleEvent;"

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
    $dump = & $edge --headless=new --disable-gpu --virtual-time-budget=3000 --dump-dom "http://127.0.0.1:$Port/" 2>$null | Out-String
    # What the context section actually rendered, for the record: the shape is
    # asserted above, but a count cannot show whether the numbers are the right
    # ones, and an empty payload would pass a shape check happily.
    $context = [regex]::Match($dump, '(?s)<div id="context-box".*?</div>')
    if ($context.Success) {
      $text = ($context.Value -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()
      Write-Host "  ok   context section renders: '$text'"
    } else {
      Write-Host "  !  the context box never rendered"
    }
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
    Write-Host "  ok   UI structure: one bubble, decisions and tool topics inside it" -ForegroundColor Green
  } else {
    Write-Host "  FAIL $result" -ForegroundColor Red
    exit 1
  }
} finally {
  if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
