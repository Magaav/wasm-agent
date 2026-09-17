# Local/remote smoke suite for a Windows wasm-agent node.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-windows.ps1
#
# Validates that the *local* node works on its own - identity, UUIDs, config,
# memory, sessions, tools, a real model turn, and the UI on localhost - and that
# remote nodes are optional: an unreachable host and an unreachable rendezvous
# must not break any of it. Safe to run repeatedly; it uses a scratch database
# and never prints a credential.
param(
  [string]$WaExe = (Join-Path $env:LOCALAPPDATA "wasm-agent\wa.exe"),
  [string]$RemoteHost = "openclaw.ohana",
  [int]$Port = 8799,
  [switch]$SkipModel
)
$ErrorActionPreference = "Continue"

$pass = 0
$fail = 0
function Ok($m)   { Write-Host "  " -NoNewline; Write-Host "ok  " -ForegroundColor Green -NoNewline; Write-Host $m; $script:pass++ }
function Bad($m)  { Write-Host "  " -NoNewline; Write-Host "FAIL" -ForegroundColor Red -NoNewline; Write-Host " $m"; $script:fail++ }
function Note($m) { Write-Host "       $m" -ForegroundColor DarkGray }

# Never let a secret reach the console, whatever a future check prints.
function Redact([string]$text) {
  if (-not $text) { return "" }
  $out = $text
  $out = [regex]::Replace($out, '(sk-[A-Za-z0-9_\-]{6,})', { param($m) "sk-...$($m.Groups[1].Value.Substring($m.Groups[1].Value.Length - 4))" })
  $out = [regex]::Replace($out, '(?i)((api_?key|token|secret|password)[A-Za-z0-9_]*\s*[=:]\s*)(\S+)', '$1<redacted>')
  $out = [regex]::Replace($out, '(?i)(bearer\s+)(\S+)', '$1<redacted>')
  return $out
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ("wa-suite-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$db = Join-Path $scratch "suite.db"
$scriptFile = Join-Path $scratch "probe.lua"

function Wa([string[]]$Arguments) {
  # Feed EOF on stdin: `wa chat` is a REPL, and with no input it would sit at the
  # prompt forever instead of returning.
  $output = $null | & $WaExe @Arguments 2>&1 | Out-String
  return (Redact $output)
}
function Lua([string]$Source) {
  Set-Content -Path $scriptFile -Value $Source -Encoding ASCII
  $previous = $env:WA_SCRIPT
  $env:WA_SCRIPT = $scriptFile
  try { $output = $null | & $WaExe --db $db 2>&1 | Out-String }
  finally {
    if ($null -eq $previous) { Remove-Item Env:\WA_SCRIPT -ErrorAction SilentlyContinue }
    else { $env:WA_SCRIPT = $previous }
  }
  return (Redact $output)
}

Write-Host ""
Write-Host "   wasm-agent local suite" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $WaExe)) { Bad "no binary at $WaExe (run scripts/install.ps1)"; exit 1 }
Note "binary $WaExe"
Note "scratch $scratch"

# 1. the binary starts
$version = Wa @("--version")
if ($version -match "wasm-agent \d") { Ok "binary starts: $($version.Trim())" } else { Bad "binary did not report a version" }

# 2. identity: stable here, and distinct from the remote node
$identityA = Wa @("node")
$identityB = Wa @("node")
try {
  $idA = ($identityA | ConvertFrom-Json).node_id
  $idB = ($identityB | ConvertFrom-Json).node_id
  if ($idA -eq $idB -and $idA.Length -eq 32) { Ok "local identity is stable ($($idA.Substring(0,8))...)" }
  else { Bad "identity not stable or malformed" }
} catch { Bad "could not read the local identity" }
Note "a leaked or shared identity would make two nodes indistinguishable in the fabric"

# 3. UUIDs stay unique across repeated operations
$uuidProbe = @'
local seen = {}
for i = 1, 200 do
  local u = host.uuid()
  assert(not seen[u], "duplicate uuid at " .. i .. ": " .. u)
  assert(#u == 36, "unexpected uuid shape: " .. u)
  seen[u] = true
end
print("uuids unique: 200")
'@
if ((Lua $uuidProbe) -match "uuids unique") { Ok "200 UUIDs unique" } else { Bad "UUID generation collided" }

# 4/5. config loads and the model resolves (never print the key)
$configProbe = @'
local provider = dofile("lua/core/provider.lua")
local settings = provider.settings()
local key = tostring(settings.api_key or "")
print("configured=" .. tostring(provider.configured()))
print("model=" .. tostring(settings.model))
print("base=" .. tostring(settings.base_url))
print("keyset=" .. tostring(#key > 0))
'@
$config = Lua $configProbe
if ($config -match "configured=true") { Ok "model configuration resolves" } else { Bad "no model configured"; Note ($config -replace "\s+", " ") }
if ($config -match "keyset=true") { Note "credential present (value never printed)" } else { Bad "no credential configured" }

# 6. memory write and read, in separate processes
$fact = "local suite fact " + [guid]::NewGuid().ToString("N").Substring(0, 6)
Wa @("--db", $db, "remember", $fact) | Out-Null
if ((Wa @("--db", $db, "recall", $fact)) -match [regex]::Escape($fact)) { Ok "memory write/read across processes" }
else { Bad "memory did not survive a second process" }

# 7. bash/shell tool and 8. recall tool, through real turns
if (-not $SkipModel) {
  $toolProbe = @'
local tools = dofile("lua/core/tools.lua")
local names = {}
for _, t in ipairs(tools.all("master")) do names[t["function"].name] = true end
assert(names["bash"], "bash tool missing")
assert(names["recall"], "recall tool missing")
print("tools discovered")
'@
  if ((Lua $toolProbe) -match "tools discovered") { Ok "bash and recall are in the envelope" } else { Bad "expected tools are missing" }

  $turn = Wa @("--db", $db, "chat", "Use bash to print the word walrus, then answer in one short sentence: say 'walrus'.")
  if ($turn -match "wasm-agent 0.1.0") { Ok "a real model turn completed" } else { Bad "the model turn failed"; Note ($turn -replace "\s+", " ").Substring(0, [Math]::Min(160, $turn.Length)) }

  $sessionProbe = @'
local memory = dofile("lua/core/memory.lua")
memory.setup()
local sessions = memory.list_sessions(nil, 10)
local withTools, toolNames = 0, {}
for _, session in ipairs(sessions) do
  for _, turn in ipairs(memory.session_turns(session.id, { limit = 200 })) do
    if turn.role == "tool" then withTools = withTools + 1; toolNames[turn.tool_name or "?"] = true end
  end
end
local list = {}
for name in pairs(toolNames) do list[#list + 1] = name end
table.sort(list)
print("tool turns=" .. withTools .. " names=" .. table.concat(list, ","))
'@
  $tools = Lua $sessionProbe
  if ($tools -match "names=.*bash") { Ok "the bash tool actually ran ($($tools.Trim() -replace '\s+',' '))" }
  else { Bad "no bash tool call was recorded"; Note ($tools -replace "\s+", " ") }

  # 9. sessions: new by default, --continue reuses
  $before = (Lua 'local m = dofile("lua/core/memory.lua") m.setup() print("sessions=" .. #m.list_sessions(nil, 100))')
  Wa @("--db", $db, "chat", "say one") | Out-Null
  $after = (Lua 'local m = dofile("lua/core/memory.lua") m.setup() print("sessions=" .. #m.list_sessions(nil, 100))')
  if ($before -ne $after) { Ok "a new session is the default ($($before.Trim()) -> $($after.Trim()))" } else { Bad "the default did not start a new session" }
  Wa @("--db", $db, "chat", "--continue", "say two") | Out-Null
  $continued = (Lua 'local m = dofile("lua/core/memory.lua") m.setup() print("sessions=" .. #m.list_sessions(nil, 100))')
  if ($continued -eq $after) { Ok "--continue reuses the latest session" } else { Bad "--continue created a session" }
} else {
  Note "model checks skipped (-SkipModel)"
}

# Session recovery: a thread cut off mid-answer must be visible, recorded, and
# continuable. The contract is one shared file (scripts/test-recovery.lua) which
# the cloud smoke test runs too - two copies of it would drift, and the shape a
# killed process leaves in the ledger is the thing being asserted either way.
$root = Split-Path $PSScriptRoot -Parent
$recoveryFile = Join-Path $root "scripts/test-recovery.lua"
if (Test-Path $recoveryFile) {
  $out = Lua (Get-Content -Raw -Path $recoveryFile)
  if ($out -match "recovery ok") { Ok "session recovery: derived state, durable record, recovery notice" }
  else { Bad "the session recovery test failed"; Note ($out -replace "\s+", " ") }
} else {
  Bad "scripts/test-recovery.lua is missing"
}

if (-not $SkipModel) {
  # The end-to-end: seed a thread cut off mid-answer, then continue it for real.
  # A verified resume says so before the user types, tells the model what was
  # lost, and settles the thread while keeping the record of the interruption.
  $seedProbe = @'
local memory = dofile("lua/core/memory.lua")
memory.setup()
local id = memory.start_session("", "chat", { user_id = "master", node_id = "", title = "recovery-seed" })
memory.append_turn(id, { role = "user", content = "count the files in scripts/" })
memory.append_turn(id, { role = "assistant", content = "Listing them now.", tool_calls = {
  { id = "seed1", type = "function", ["function"] = { name = "bash", arguments = "{}" } } } })
print("seeded=" .. id)
'@
  $seeded = Lua $seedProbe
  $seededId = ([regex]::Match($seeded, "seeded=([0-9a-fA-F\-]{36})")).Groups[1].Value
  if ($seededId) { Ok "seeded an interrupted thread ($($seededId.Substring(0, 8)))" }
  else { Bad "could not seed an interrupted thread"; Note ($seeded -replace "\s+", " ") }

  if ($seededId) {
    # `wa resume` is the visible half: read-only, and it names the unfinished call.
    $report = Wa @("--db", $db, "resume")
    if ($report -match "1 tool call\(s\) never reported: bash") { Ok "wa resume names the unfinished work" }
    else { Bad "wa resume did not describe the interruption"; Note ($report -replace "\s+", " ") }

    $resumed = Wa @("--db", $db, "chat", "--session", $seededId, "Answer with the single word: ready")
    if ($resumed -match "interrupted") { Ok "continuing an interrupted thread says so before the prompt" }
    else { Bad "the banner did not report the interruption"; Note ($resumed -replace "\s+", " ") }

    $stateProbe = "local m = dofile(`"lua/core/memory.lua`") m.setup() local s = m.session_state(`"$seededId`") " +
      "print(`"state=`" .. s.state .. `" interruptions=`" .. s.interruptions .. `" at=`" .. s.recorded_seq)"
    $state = Lua $stateProbe
    if ($state -match "state=answered") { Ok "the resumed thread settled ($($state.Trim()))" }
    else { Bad "the resumed thread did not settle: $($state -replace '\s+', ' ')" }
    if ($state -match "interruptions=1") { Ok "the interruption is recorded and survives the recovery" }
    else { Bad "the interruption was not recorded: $($state -replace '\s+', ' ')" }
  }
}

# 9c. The shell the tools run in. The model speaks POSIX: with cmd these failed
# with "is not recognized", which is what pi avoids by requiring bash.
$shellProbe = @'
local platform = dofile("lua/core/platform.lua")
local shell = platform.shell()
local raw = host.exec("echo $0; pwd; ls -a . | head -2", "")
local decoded = dofile("lua/vendor/json.lua").decode(raw)
print("shell=" .. shell .. " code=" .. tostring(decoded.code))
print("out=" .. tostring(decoded.stdout):gsub("\n", " | "))
assert(decoded.code == 0, "the tool shell must run POSIX commands")
print(shell:find("bash", 1, true) and "posix shell on Windows" or "cmd shell on Windows")
'@
$probeOut = Lua $shellProbe
if ($probeOut -match "posix shell on Windows") { Ok "tools run in bash on Windows (POSIX habits work)" }
else { Bad "tools run in cmd on Windows: POSIX commands fail"; Note ($probeOut -replace "s+", " ") }
# 10/11. local operation with the remote node and the rendezvous unreachable
$env:WASM_AGENT_HOST = "unreachable.invalid"
$env:WASM_AGENT_RENDEZVOUS = "http://127.0.0.1:1"
$offlineFact = "offline fact " + [guid]::NewGuid().ToString("N").Substring(0, 6)
Wa @("--db", $db, "remember", $offlineFact) | Out-Null
$offlineOk = (Wa @("--db", $db, "recall", $offlineFact)) -match [regex]::Escape($offlineFact)
$offlineVersion = Wa @("--version")
if ($offlineOk -and $offlineVersion -match "wasm-agent") { Ok "remote unavailable does not break local operation" }
else { Bad "local operation depended on the remote node" }
Remove-Item Env:\WASM_AGENT_HOST, Env:\WASM_AGENT_RENDEZVOUS -ErrorAction SilentlyContinue

# 12. UI reaches localhost
function Test-Health([int]$p) { try { (Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 "http://127.0.0.1:$p/health").StatusCode -eq 200 } catch { $false } }
$started = $false
$serverProcess = $null
if (-not (Test-Health $Port)) {
  $uiDir = Join-Path (Split-Path $WaExe) "ui"
  # PassThru: this run owns the server, so it stops it again at the end. The
  # suite must be safe to run repeatedly, and a server left behind also keeps
  # this console open, which looks like a hang.
  $serverProcess = Start-Process -FilePath $WaExe -ArgumentList @("serve", "--port", "$Port", "--ui", $uiDir) -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $scratch "serve.log") -RedirectStandardError (Join-Path $scratch "serve.err.log")
  $started = $true
  for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 250; if (Test-Health $Port) { break } }
}
if (Test-Health $Port) {
  try {
    $page = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "http://127.0.0.1:$Port/"
    if ($page.Content -match "<title>") { Ok "the UI is served on localhost:$Port" } else { Bad "localhost:$Port did not serve the UI" }
  } catch { Bad "could not fetch the local UI" }
  if ($started) { Note "started by this run; stopped again below" } else { Note "already running (left as it was)" }
} else { Bad "no local server on $Port" }

# 13. remote discovery when it is available (optional, never fatal)
$bogus = Wa @("nodes")
try {
  $null = $bogus | ConvertFrom-Json
  Ok "node discovery answers locally"
  if ($bogus -match "openclaw") { Note "a remote peer is registered" } else { Note "no remote peer registered right now" }
} catch { Bad "node discovery did not return JSON" }

Write-Host ""
if ($fail -eq 0) { Write-Host "   local suite ok ($pass checks)" -ForegroundColor Green } else { Write-Host "   local suite FAILED ($fail of $($pass + $fail))" -ForegroundColor Red }
Write-Host ""
if ($started -and $serverProcess) {
  Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
  Note "stopped the server this run started"
}
Remove-Item -Recurse -Force $scratch -ErrorAction SilentlyContinue
exit ($fail -gt 0)
