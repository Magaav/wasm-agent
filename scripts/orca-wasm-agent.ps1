# Register wasm-agent as a first-class agent inside Orca.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/orca-wasm-agent.ps1
#   powershell ... -File scripts/orca-wasm-agent.ps1 -Revert
#
# Orca's TUI agent registry is a hardcoded object (`isTuiAgent` is
# `Object.hasOwn(TUI_AGENT_CONFIG, id)`), and unknown ids are dropped by the
# settings normalizer - so there is no supported way to add one. This edits the
# two *unpacked* JavaScript files that define the registry and the display names.
#
# It is deliberately small, backed up, validated and reversible: Orca updates
# replace these files, so re-run it afterwards.
param(
  [string]$OrcaRoot = (Join-Path $env:LOCALAPPDATA "Programs\orca\resources\app.asar.unpacked\out\shared"),
  [string]$AgentId = "wasm",
  [string]$Label = "wasm-agent",
  [string]$LaunchCommand = "wa chat",
  [string]$DetectCommand = "wa",
  [switch]$Revert
)
$ErrorActionPreference = "Stop"

$configPath = Join-Path $OrcaRoot "tui-agent-config.js"
$labelPath = Join-Path $OrcaRoot "agent-type-label.js"
$marker = "// >>> wasm-agent registration"

function Fail($message) { Write-Host "  !  $message" -ForegroundColor Red; exit 1 }
function Note($message) { Write-Host "       $message" -ForegroundColor DarkGray }

if (-not (Test-Path $configPath)) { Fail "not found: $configPath (is Orca installed here?)" }
if (-not (Test-Path $labelPath)) { Fail "not found: $labelPath" }

Write-Host ""
Write-Host "   orca agent registration" -ForegroundColor Cyan
Write-Host ""

# --- revert -------------------------------------------------------------------
if ($Revert) {
  $restored = 0
  foreach ($path in @($configPath, $labelPath)) {
    $backup = "$path.wasm-agent-orig"
    if (Test-Path $backup) { Copy-Item $backup $path -Force; $restored++ ; Note "restored $(Split-Path $path -Leaf)" }
  }
  if ($restored -eq 0) { Note "no backups found; nothing to revert" }
  else { Write-Host "   reverted $restored file(s). Restart Orca." -ForegroundColor Green }
  Write-Host ""
  exit 0
}

# --- already registered? ------------------------------------------------------
if ((Get-Content -Raw $configPath) -match [regex]::Escape($marker)) {
  Write-Host "   already registered; nothing to do" -ForegroundColor Green
  Note "restart Orca if you have not since the last change"
  Write-Host ""
  exit 0
}

# --- back up once ------------------------------------------------------------
foreach ($path in @($configPath, $labelPath)) {
  $backup = "$path.wasm-agent-orig"
  if (-not (Test-Path $backup)) { Copy-Item $path $backup -Force; Note "backed up $(Split-Path $path -Leaf)" }
}

# --- patch the registry -------------------------------------------------------
$config = Get-Content -Raw $configPath
$anchor = "const TUI_AGENT_CONFIG_SOURCE = {"
if ($config -notlike "*$anchor*") { Fail "Orca's registry shape changed: anchor '$anchor' not found. Re-check tui-agent-config.js." }
$entry = @"
$anchor
$marker
    // Orca types the prompt in as an argument, which our REPL takes as the first
    // turn; it then stays interactive. Multi-line briefs survive this way.
    ${AgentId}: {
        detectCmd: '$DetectCommand',
        launchCmd: '$LaunchCommand',
        promptInjectionMode: 'argv'
    },
"@
$config = $config.Replace($anchor, $entry.TrimEnd())
Set-Content -Path $configPath -Value $config -NoNewline -Encoding UTF8
Note "patched tui-agent-config.js"

# --- patch the label ----------------------------------------------------------
$labels = Get-Content -Raw $labelPath
$labelAnchor = "const WELL_KNOWN_LABELS = {"
if ($labels -notlike "*$labelAnchor*") { Fail "Orca's label shape changed: anchor '$labelAnchor' not found." }
# Without this the label falls back to the raw id, which is fine but ugly.
$labels = $labels.Replace($labelAnchor, "$labelAnchor`n    ${AgentId}: '$Label',")
Set-Content -Path $labelPath -Value $labels -NoNewline -Encoding UTF8
Note "patched agent-type-label.js"

# --- validate -----------------------------------------------------------------
foreach ($path in @($configPath, $labelPath)) {
  & node --check $path 2>&1 | Out-String | ForEach-Object { if ($_.Trim()) { Fail "syntax check failed for $(Split-Path $path -Leaf): $_" } }
  if ($LASTEXITCODE -ne 0) { Fail "syntax check failed for $(Split-Path $path -Leaf); run -Revert" }
}
Write-Host "   ok  registered '$AgentId' -> $LaunchCommand" -ForegroundColor Green
Write-Host ""
Write-Host "   restart Orca, then:" -ForegroundColor DarkGray
Write-Host "     orca worktree create --repo id:<wasm-agent-repo-id> --name <task> --agent $AgentId --prompt `"<brief>`"" -ForegroundColor White
Write-Host "   or pick '$Label' from the agent list in the IDE." -ForegroundColor DarkGray
Write-Host ""
Write-Host "   An Orca update replaces these files: re-run this script." -ForegroundColor DarkGray
Write-Host "   Undo with:  -Revert" -ForegroundColor DarkGray
Write-Host ""
