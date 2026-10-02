# Headless assertion for the orchestrator window's child panes.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/probe-ui-subagent-chat.ps1
#
# Why this exists: the five things this lane was asked for are all structural, and none of them can be
# read off the source. "Six open boxes stay readable" is a measured height, "the header is at most
# 44px" is a measured height, "the action row is the height of the append-file control" is two measured
# heights, "the child transcript renders through the main chat's path" is one DOM shape reached through
# one function, and "cards are grouped by lane" is an attribute on the grouping element. So this serves
# a *copy* of ui/ with the repository's own test-fixtures.js, opens the orchestrator view in a real
# headless browser, opens six children at once, and asserts each one against the live DOM.
#
# It never starts, stops or writes to a node, and never writes into ui/: the copy is a temp directory
# and the only thing added to it is this probe and one fixtures script, exactly as scripts/test-ui.ps1
# does. The probe writes `pre#probe-log`; the verdict is that element's text.
param(
  [int]$Port = 8917,
  [int]$ClientPort = 8801,
  [string]$WaExe = (Join-Path $env:LOCALAPPDATA "wasm-agent\wa.exe"),
  # A node whose page budget is lowered (`WASM_AGENT_TOOL_OUTPUT_BYTES`, the knob the benchmark and the
  # A/B experiments use). The fixture mirrors the node's own validation, and the probe asserts that a
  # lowered budget costs page size rather than the whole transcript.
  [int]$ToolOutputBytes = 0,
  [string]$Out = (Join-Path $env:TEMP "wa-probe-subagent-chat")
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$ui = Join-Path $root "ui"
if (-not (Test-Path (Join-Path $ui "index.html"))) { Write-Host "  !  no ui/ in $root"; exit 1 }

New-Item -ItemType Directory -Force -Path $Out | Out-Null
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("wa-probe-ui-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$db = Join-Path $tmp "probe.db"
foreach ($name in @("index.html", "style.css", "app.js", "components.js", "render.wasm", "manifest.webmanifest", "service-worker.js", "icon-192.png", "icon-512.png")) {
  $from = Join-Path $ui $name
  if (Test-Path $from) { Copy-Item $from (Join-Path $tmp $name) }
}

# The probe is written without escape sequences on purpose: one stray `\n` inside a string is a syntax
# error that kills the block silently, and a probe that never ran looks exactly like a probe that passed.
$probe = @'
(async function () {
  var problems = [], notes = [], facts = {};
  function check(ok, label) { if (ok) notes.push(label); else problems.push(label); }
  function tick() { return Promise.resolve(); }
  try {
    // The view mounts once the markdown renderer has loaded (app.js assigns `window.rendererLoaded`
    // before it calls applyViewMode), so wait for that rather than assuming the component is already
    // in the document - a probe that reads an empty page reports a broken app.
    if (window.rendererLoaded) await window.rendererLoaded;
    for (var mount = 0; mount < 50 && !document.querySelector("wa-orchestrator"); mount += 1) await tick();
    if (!document.querySelector("wa-orchestrator")) await new Promise(function (r) { setTimeout(r, 50); });
    var panel = document.querySelector("wa-orchestrator");
    if (!panel) throw new Error("the orchestrator window did not mount");
    if (typeof window.__refreshOrchestrator !== "function") throw new Error("the probe cannot reach the app's refresher");

    // ---- what the node answers ---------------------------------------------------------------
    // Six children over four lanes, each plan the *recorded* shape the node writes: a branch lane; a
    // released lane (workspaces.lua's release KEEPS `worktree` and sets `workspace_state='released'`);
    // a lane whose children recorded a worktree and no branch name (`sessions.workspace_branch` is
    // TEXT NOT NULL DEFAULT '', so a lane can be keyed by its worktree alone); and the node's own
    // checkout, which has neither. Children 1-2 alpha, 3-4 beta, 5 gamma, 6 main.
    var lanePlan = [
      { branch: "change/lane-alpha", worktree: "C:/work/wt-alpha", state: "allocated" },
      { branch: "change/lane-beta", worktree: "C:/work/wt-beta", state: "released" },
      { branch: "", worktree: "C:/work/wt-gamma", state: "allocated" },
      { branch: "", worktree: "", state: "unbound" }
    ];
    var laneOfChild = [0, 0, 1, 1, 2, 3];
    var tasks = [], sessions = [];
    for (var i = 1; i <= 6; i += 1) {
      var plan = lanePlan[laneOfChild[i - 1]];
      var id = "child-" + i, sid = "child-session-" + i;
      tasks.push({ subagent_id: id, session_id: sid, parent_session_id: "parent-fixture",
        profile: "task-worker", execution_node: "local",
        title: "LONG-TITLE-" + i + " " + new Array(24).join("a deliberately long mission line "),
        prompt: "prompt " + i, state: i <= 4 ? "running" : "completed", settled: i > 4,
        model: "fixture-model-" + i, reasoning: "high", created_at: 100 + i });
      sessions.push({ id: sid, title: "child session " + i, state: i <= 4 ? "unfinished" : "answered",
        workspace_required: 1, workspace_branch: plan.branch, worktree: plan.worktree,
        workspace_state: plan.state });
    }
    window.__fixtures.subagents = { subagents: tasks };
    window.__fixtures.sessions = { sessions: sessions };

    // The child transcript page the node answers with (lua/core/session_view.lua's shape): rows, the
    // task echo, and an oversized row handed back as an address rather than as a body.
    function page(id) {
      var n = Number(String(id).replace("child-", ""));
      var settled = n > 4;
      var rows = [
        { seq: 1, role: "user", content: "CHILD-" + n + "-QUESTION", created_at: 1789990000, tool_calls: [] },
        { seq: 2, role: "assistant", content: "", created_at: 1789990002, reasoning: "CHILD-" + n + "-REASONING",
          tool_calls: [{ id: "call-" + n, type: "function", function: { name: "bash", arguments: "{\"command\":\"echo " + n + "\"}" } }] },
        { seq: 3, role: "tool", tool_call_id: "call-" + n, tool_name: "bash", ok: 1, created_at: 1789990003,
          content: "CHILD-" + n + "-TOOL-RESULT", tool_calls: [] },
        { seq: 4, role: "assistant", created_at: 1789990004, omitted: true,
          content: "[Oversized message: retrieve the original using evidence.]",
          evidence: { tool: "subagent", action: "session", id: id, message_id: "oversized-" + n, byte_offset: 1 }, tool_calls: [] },
        { seq: 5, role: "assistant", content: "CHILD-" + n + "-ANSWER", ms: 13000, created_at: 1789990013, tool_calls: [] }
      ];
      return { session_id: "child-session-" + n, returned: rows.length, view: "full", messages: rows,
        note: "Bounded inspection only; original transcript unchanged.",
        task: { subagent_id: id, session_id: "child-session-" + n, state: settled ? "completed" : "running",
          settled: settled, profile: "task-worker", model: "fixture-model-" + n, reasoning: "high" } };
    }
    function respond(value) {
      return Promise.resolve({ ok: true, status: 200, json: function () { return Promise.resolve(value); },
        text: function () { return Promise.resolve(JSON.stringify(value)); } });
    }
    var previousFetch = window.fetch;
    window.fetch = function (input, init) {
      var url = String(typeof input === "string" ? input : (input && input.url) || "");
      var path = new URL(url, location.href).pathname.replace(/^\/+|\/+$/g, "");
      if (path === "subagents" && init && init.method === "POST") {
        var request = {};
        try { request = JSON.parse(init.body || "{}"); } catch (error) { request = {}; }
        if (request.action === "session") {
          // The node's own validation (lua/core/session_view.lua): a `byte_limit` above MAX_BYTES-2048
          // is refused, and MAX_BYTES is the budget `WASM_AGENT_TOOL_OUTPUT_BYTES` lowers.
          var budget = Number(window.__fixtureToolOutputBytes || 0);
          if (budget > 0 && Number(request.byte_limit || 0) > budget - 2048) return respond({ error: "invalid_session_byte_limit" });
          return respond(page(request.id));
        }
      }
      return previousFetch(input, init);
    };

    // ---- open six children at once ------------------------------------------------------------
    // The panel polls on its own timer, so a refresh asked for while one is in flight is skipped: ask
    // until the cards are there, then ask again until every pinned pane has drawn its child's page.
    for (var tries = 0; tries < 20 && panel.querySelectorAll("nav .agent-card").length !== 6; tries += 1) {
      await window.__refreshOrchestrator();
      for (var settle = 0; settle < 20; settle += 1) await tick();
    }
    var cards = Array.prototype.slice.call(panel.querySelectorAll("nav .agent-card"));
    check(cards.length === 6, "six children must produce six cards, saw " + cards.length);
    for (var c = 0; c < cards.length; c += 1) cards[c].click();
    var panes = [];
    for (var drawn = 0; drawn < 40; drawn += 1) {
      await window.__refreshOrchestrator();
      for (var settle2 = 0; settle2 < 20; settle2 += 1) await tick();
      panes = Array.prototype.slice.call(panel.querySelectorAll("wa-agent-session"));
      var drawnMessages = panel.querySelectorAll(".agent-transcript wa-message").length;
      if (panes.length === 6 && drawnMessages >= 12) break;
    }
    check(panes.length === 6, "six children must be open at once, saw " + panes.length);
    var canvas = panel.querySelector(".orchestrator-canvas");
    check(!!canvas && canvas.clientHeight > 300, "the canvas must be a real measured box, saw " + (canvas ? canvas.clientHeight : "none"));

    var headers = [], readable = [], controls = [], wrappers = [];
    panes.forEach(function (pane) {
      var n = Number(String(pane.dataset.key || "").replace("child-", ""));
      var head = pane.querySelector(".agent-pane-head");
      var transcript = pane.querySelector(".agent-transcript");
      var attach = pane.querySelector("[data-part=attach]");
      var actions = pane.querySelector(".chat-actions");
      var bubble = transcript ? transcript.querySelector("wa-message.assistant") : null;
      var body = bubble ? bubble.querySelector(".body") : null;
      headers.push({ child: n, height: head ? Math.round(head.getBoundingClientRect().height) : -1,
        text: head ? head.textContent.length : -1 });
      readable.push({ child: n, transcript: transcript ? transcript.clientHeight : -1,
        messages: transcript ? transcript.querySelectorAll("wa-message").length : -1,
        answer: !!(transcript && transcript.textContent.indexOf("CHILD-" + n + "-ANSWER") >= 0) });
      controls.push({ child: n, actions: actions ? actions.offsetHeight : -1,
        attach: attach ? attach.offsetHeight : -1 });
      wrappers.push({ child: n,
        shell: !!(transcript && transcript.classList.contains("messages") && transcript.classList.contains("agent-transcript")),
        steps: !!(body && body.classList.contains("steps")),
        footerInBubble: !!(body && body.querySelector(":scope > .chat-content-run-status.finished")),
        footerAtChatRoot: !!(transcript && transcript.querySelector(":scope > .chat-content-run-status")),
        earlier: !!(pane.querySelector(".agent-earlier")),
        retrieve: /Load original message/.test(pane.textContent),
        settlementLine: pane.notice ? pane.notice.textContent : "",
        readoutHidden: pane.statusLine ? pane.statusLine.hidden === true : true });
    });
    facts.headers = headers; facts.readable = readable; facts.controls = controls; facts.wrappers = wrappers;

    // (2) The pane header is a fixed strip of at most 44px, whatever text it is given.
    check(headers.length === 6 && headers.every(function (h) { return h.height > 0 && h.height <= 44; }),
      "every pane header must measure at most 44px, saw " + JSON.stringify(headers));
    check(headers.every(function (h) { return h.text > 60; }),
      "each header must still carry the long mission and model text the cap is holding in, saw " + JSON.stringify(headers));

    // (1) Six open boxes, each with a transcript that can actually be read.
    check(readable.length === 6 && readable.every(function (r) { return r.transcript >= 120; }),
      "every one of six open panes must keep a readable transcript height (>=120px), saw " + JSON.stringify(readable));
    check(readable.every(function (r) { return r.messages >= 2 && r.answer; }),
      "every pane must draw its child's turn as the user bubble plus the run's assistant bubble, saw " + JSON.stringify(readable));
    var evidence = panes.map(function (pane) {
      return { child: Number(String(pane.dataset.key || "").replace("child-", "")),
        run: pane.querySelectorAll(".agent-transcript wa-run").length,
        lines: pane.querySelectorAll(".agent-transcript wa-run .tool-line").length,
        reasoning: pane.querySelectorAll(".agent-transcript wa-reasoning").length,
        placeholder: pane.querySelector(".agent-transcript").textContent.indexOf("retrieve the original using evidence") >= 0 };
    });
    facts.evidence = evidence;
    check(evidence.every(function (e) { return e.run === 1 && e.lines === 1 && e.reasoning === 1 && e.placeholder; }),
      "every pane's run topic must hold the child's thinking, its tool line and the node's own placeholder for the oversized row, saw " + JSON.stringify(evidence));
    check(!!canvas && canvas.scrollHeight > canvas.clientHeight,
      "the canvas must scroll rather than squash the panes, saw " + (canvas ? canvas.scrollHeight + " of " + canvas.clientHeight : "none"));

    // (3) The Steer/Cancel row is the height of the shell's own append-file control.
    check(controls.length === 6 && controls.every(function (k) { return k.actions > 0 && k.actions === k.attach; }),
      "the action row must be the height of the append-file control, saw " + JSON.stringify(controls));
    check(controls.every(function (k) { return k.attach === 30; }),
      "the append-file control must be the shell's 30px control, saw " + JSON.stringify(controls));

    // (4) The child transcript is the main chat's own rendering path, not a parallel one.
    check(wrappers.every(function (w) { return w.shell && w.steps; }),
      "every pane transcript must be the shared shell's messages region holding wa-message bubbles, saw " + JSON.stringify(wrappers));
    check(wrappers.every(function (w) { return !w.earlier && !w.retrieve; }),
      "no pane may carry the `Earlier messages` control or a `Load original message N` button, saw " + JSON.stringify(wrappers));
    check(wrappers.every(function (w) { return w.settlementLine.indexOf("Ready for your next message") < 0; }),
      "no pane may restate the completion in its own notice, saw " + JSON.stringify(wrappers));
    check(wrappers.every(function (w) { return !w.footerAtChatRoot; }),
      "a run's status line must be inside its own bubble, never a second row in the transcript, saw " + JSON.stringify(wrappers));
    check(wrappers.filter(function (w) { return w.child <= 4; }).every(function (w) { return w.readoutHidden === false; }) &&
      wrappers.filter(function (w) { return w.child > 4; }).every(function (w) { return w.readoutHidden === true; }),
      "the pane's own readout must be live-only: shown while the child works, silent once its run's footer says how it ended, saw " + JSON.stringify(wrappers));

    // One implementation, measured: the same ledger rows, drawn into the main chat by the app's own
    // repaint, must produce the same DOM shape as the child pane's transcript. Two renderers agreed
    // only by inspection would still differ here.
    function shapeOf(root) {
      return Array.prototype.slice.call(root.children).map(function (node) {
        var kids = node.tagName === "WA-MESSAGE" && node.body ? Array.prototype.slice.call(node.body.children) : [];
        return node.tagName + "." + Array.prototype.slice.call(node.classList).sort().join(".") + "[" +
          kids.map(function (kid) {
            return kid.tagName + "." + Array.prototype.slice.call(kid.classList).sort().join(".");
          }).join(",") + "]";
      }).join(";");
    }
    var settledPane = panes.filter(function (pane) { return pane.dataset.key === "child-5"; })[0];
    var answer = page("child-5");
    window.__repaintMessages(answer.messages, { state: "answered", stateAt: answer.messages[4].created_at });
    var mainChat = document.getElementById("messages");
    var childShape = settledPane ? shapeOf(settledPane.transcript) : "no settled pane";
    var chatShape = shapeOf(mainChat);
    facts.childShape = childShape; facts.chatShape = chatShape;
    check(!!settledPane && childShape === chatShape && /WA-MESSAGE/.test(childShape) &&
      /chat-content-run-status/.test(childShape),
      "the child transcript and the main chat must be the same DOM for the same rows, saw " + childShape + " vs " + chatShape);

    // (5) Cards grouped BY LANE, keyed by the child's recorded branch, with the end-state checklist.
    var laneElements = Array.prototype.slice.call(panel.querySelectorAll("nav .lane"));
    var laneKeys = laneElements.map(function (g) { return g.dataset.lane; }).sort();
    var counts = laneElements.map(function (g) { return g.dataset.lane + ":" + g.querySelectorAll(".agent-card").length; }).sort();
    var outcomes = ["merged", "retired", "clean", "main-only"];
    var lists = laneElements.map(function (g) {
      var items = Array.prototype.slice.call(g.querySelectorAll(".lane-check"));
      var path = g.querySelector(".lane-path");
      return { lane: g.dataset.lane, path: path ? path.textContent : "",
        outcomes: items.map(function (item) { return item.dataset.outcome; }),
        states: items.map(function (item) { return item.dataset.state; }) };
    });
    facts.lanes = { keys: laneKeys, counts: counts, lists: lists };
    function laneOf(key) { return lists.filter(function (list) { return list.lane === key; })[0]; }
    function stateOf(key, index) { var lane = laneOf(key); return lane ? lane.states[index] : "no such lane"; }
    // The page budget first: it decides whether the panes drew their pages at all.
    var budgetPanes = panes.map(function (pane) {
      var n = Number(String(pane.dataset.key || "").replace("child-", ""));
      return { child: n, answer: pane.transcript.textContent.indexOf("CHILD-" + n + "-ANSWER") >= 0,
        notice: pane.notice ? pane.notice.textContent : "", title: pane.notice ? pane.notice.title : "" };
    });
    facts.budget = budgetPanes;
    if (window.__fixtureToolOutputBytes) {
      check(budgetPanes.every(function (p) { return p.answer; }) &&
        budgetPanes.every(function (p) { return p.notice.indexOf("Conversation unavailable") < 0; }),
        "a node whose page budget is lowered must still show every child's transcript, saw " +
        JSON.stringify(budgetPanes.map(function (p) { return p.notice; })));
      check(budgetPanes.some(function (p) { return p.notice.indexOf("invalid_session_byte_limit") >= 0 && p.notice.indexOf("KiB") >= 0; }),
        "and the pane must say which page size the node refused rather than showing an empty conversation, saw " +
        JSON.stringify(budgetPanes[0].notice));
      check(budgetPanes.every(function (p) { return p.title.indexOf("WASM_AGENT_TOOL_OUTPUT_BYTES") >= 0; }),
        "and every pane must carry the reason where a reader can find it, saw " + JSON.stringify(budgetPanes.map(function (p) { return p.title.slice(0, 60); })));
    } else {
      check(budgetPanes.every(function (p) { return p.notice.indexOf("invalid_session_byte_limit") < 0; }),
        "with the node's default budget no pane may report a refusal it never met, saw " +
        JSON.stringify(budgetPanes.map(function (p) { return p.notice.slice(0, 60); })));
    }
    check(laneKeys.join("|") === ["C:/work/wt-gamma", "change/lane-alpha", "change/lane-beta", "main"].sort().join("|"),
      "cards must be grouped by the child's recorded checkout - its branch, else its worktree, else the node's own - saw " + JSON.stringify(laneKeys));
    check(counts.join(" ") === "C:/work/wt-gamma:1 change/lane-alpha:2 change/lane-beta:2 main:1",
      "each lane group must hold that lane's own children, saw " + JSON.stringify(counts));
    check(lists.length === 4 && lists.every(function (list) {
      return list.outcomes.join(",") === outcomes.join(",") && list.states.length === 4 &&
        list.states.every(function (s) { return s === "yes" || s === "no" || s === "unknown"; });
    }), "every lane must carry the four-outcome checklist, each measured or explicitly unknown, saw " + JSON.stringify(lists));
    // A released lane in the shape the node records it: the worktree is kept and the state says released.
    check(stateOf("change/lane-beta", 1) === "yes" && laneOf("change/lane-beta").path === "C:/work/wt-beta",
      "`retired` must be measured from the recorded checkout, and a retired lane still shows where it was, saw " + JSON.stringify(laneOf("change/lane-beta")));
    check(stateOf("change/lane-alpha", 1) === "no",
      "a lane whose children still hold a bound checkout must not be called retired, saw " + JSON.stringify(laneOf("change/lane-alpha")));
    // The lane key and the outcome come from the same recorded facts: a worktree of its own is not the
    // node's checkout, whatever the empty branch column says.
    check(stateOf("C:/work/wt-gamma", 3) === "no" && laneOf("C:/work/wt-gamma").path === "C:/work/wt-gamma",
      "a lane keyed on a recorded worktree with no recorded branch must not be reported as main-only, saw " + JSON.stringify(laneOf("C:/work/wt-gamma")));
    check(stateOf("main", 3) === "yes" && laneOf("main").path === "",
      "and the lane with neither a branch nor a worktree of its own must be the main-only one, saw " + JSON.stringify(laneOf("main")));
    check(lists.every(function (list) {
      return list.states[0] === "unknown" && list.states[2] === "unknown";
    }), "the two outcomes this view cannot measure must say `unknown` rather than being drawn as facts, saw " + JSON.stringify(lists));
  } catch (error) {
    problems.push("the probe threw: " + ((error && error.stack) || error));
  }
  var log = document.createElement("pre");
  log.id = "probe-log";
  log.textContent = (problems.length ? "PROBE FAIL: " + problems.join(" ;; ") : "PROBE PASS (" + notes.length + " checks)") +
    "\nMEASURED " + JSON.stringify(facts);
  log.style.cssText = "position:fixed;top:0;left:0;z-index:99;background:#000;color:#0f0;font:11px monospace;padding:5px;max-height:100%;overflow:auto";
  document.body.appendChild(log);
  document.title = problems.length ? "probe: failed" : "probe: passed";
})();
'@
Set-Content -Path (Join-Path $tmp "wa-probe.js") -Value $probe -NoNewline
$fixtures = Get-Content -Raw (Join-Path $PSScriptRoot "../ui/test-fixtures.js")
Set-Content -Path (Join-Path $tmp "fixtures.js") -Value $fixtures -NoNewline

$index = Join-Path $tmp "index.html"
$html = Get-Content -Raw $index
# Fixtures first (app.js reads them as it starts), the probe last (after app.js has booted).
$html = $html.Replace('<script src="app.js"></script>',
  '<script src="fixtures.js"></script>' + "`n" + '<script src="app.js"></script>' + "`n" +
  '<script>window.__fixtureToolOutputBytes = ' + $ToolOutputBytes + ';</script>' + "`n" + '<script src="wa-probe.js"></script>')
Set-Content -Path $index -Value $html -NoNewline

# The probe drives the window through the app's own entry points, as a reader does by clicking. These
# exposures are added to the temp copy only; the repository's ui/app.js keeps its module scope.
$app = Join-Path $tmp "app.js"
Add-Content -Path $app -Value "`nwindow.__refreshOrchestrator = refreshOrchestrator; window.__repaintMessages = repaintMessages; window.__paintChildTranscript = paintChildTranscript;"

$edge = @(
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
  "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { Write-Host "  !  no Edge or Chrome found"; exit 1 }

$busy = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
if ($busy) {
  Write-Host "  !  port $Port is already in use by pid $($busy.OwningProcess) - stop it and run again"
  exit 1
}

$screenshot = Join-Path $Out "orchestrator.png"
$dumpPath = Join-Path $Out "orchestrator-dom.html"
$runtimeEnvironment = @{}
foreach ($entry in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'WASM_AGENT_*' -or $_.Name -eq 'WA_SCRIPT' })) {
  $runtimeEnvironment[$entry.Name] = $entry.Value
  [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
}
$env:WASM_AGENT_HOME = Join-Path $tmp 'home'
# The fixture is what enforces the node's rule (the page's API calls are stubbed), but the server this
# harness serves the page from gets the same setting, so nothing here claims a budget it did not set.
if ($ToolOutputBytes -gt 0) { $env:WASM_AGENT_TOOL_OUTPUT_BYTES = "$ToolOutputBytes" }
$server = $null
try {
  $server = Start-Process -FilePath $WaExe -ArgumentList @("serve", "--db", $db, "--port", "$Port", "--client-port", "$ClientPort", "--ui", $tmp) -WindowStyle Hidden -PassThru
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    try { if ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:$Port/health").StatusCode -eq 200) { break } } catch { }
  }
  # Native commands write to stderr even on success, and under $ErrorActionPreference = "Stop" that
  # aborts the script - the trap that made a busy port look like a broken harness.
  $previous = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $profile = Join-Path $tmp 'browser-profile'
    $dump = & $edge --headless=new --disable-gpu --no-sandbox --hide-scrollbars --virtual-time-budget=10000 --window-size=1280,900 "--user-data-dir=$profile" "--screenshot=$screenshot" --dump-dom "http://127.0.0.1:$Port/?view=orchestrator" 2>$null | Out-String
  } finally { $ErrorActionPreference = $previous }
  Set-Content -Path $dumpPath -Value $dump
  $match = [regex]::Match($dump, '<pre id="probe-log"[^>]*>([\s\S]*?)</pre>')
  if (-not $match.Success) {
    Write-Host "  !  the probe did not run (no #probe-log in the DOM dump)" -ForegroundColor Red
    Write-Host ("     dump written to " + $dumpPath + " (" + $dump.Length + " chars; logged=" + ($dump -match "probe-log") + ")")
    exit 1
  }
  $result = $match.Groups[1].Value
  Write-Host $result
  Write-Host ("     screenshot " + $screenshot)
  if (-not $result.StartsWith("PROBE PASS")) {
    Write-Host "  FAIL orchestrator child panes" -ForegroundColor Red
    exit 1
  }
  Write-Host "  ok   orchestrator child panes (header, six readable boxes, action row, one render path, lanes)" -ForegroundColor Green
} finally {
  if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  Remove-Item Env:WASM_AGENT_HOME -ErrorAction SilentlyContinue
  Remove-Item Env:WASM_AGENT_TOOL_OUTPUT_BYTES -ErrorAction SilentlyContinue
  foreach ($key in $runtimeEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $runtimeEnvironment[$key], 'Process') }
  $resolvedTmp = [IO.Path]::GetFullPath($tmp)
  $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if ($resolvedTmp.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
      [IO.Path]::GetFileName($resolvedTmp) -match '^wa-probe-ui-[0-9a-f]{8}$') {
    Remove-Item -LiteralPath $resolvedTmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}
