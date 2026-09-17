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

  var children = body ? Array.prototype.slice.call(body.children) : [];
  var shape = children.map(function (c) { return c.tagName === "WA-TRACE" ? "trace" : "text"; }).join(",");
  check(shape === "text,trace,text,trace,text", "expected text,trace,text,trace,text inside the bubble, saw " + shape);

  // Tool topics belong to the reply, not to the transcript.
  check(messages.querySelectorAll(":scope > wa-trace").length === 0,
        "tool topics must not be children of the transcript container");

  var traces = body ? body.querySelectorAll("wa-trace") : [];
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

  var log = document.createElement("pre");
  log.id = "harness-log";
  log.textContent = problems.length ? ("UI FAIL: " + problems.join(" ;; ")) : "UI PASS";
  log.style.cssText = "position:fixed;top:0;left:0;z-index:99;background:#000;color:#0f0;font:12px monospace;padding:6px";
  document.body.appendChild(log);
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
    Write-Host "  ok   UI structure: one bubble, decisions and tool topics inside it" -ForegroundColor Green
  } else {
    Write-Host "  FAIL $result" -ForegroundColor Red
    exit 1
  }
} finally {
  if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
