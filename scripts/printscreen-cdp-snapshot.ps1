# Capture the focused Chrome DevTools page when Print Screen is pressed.
# Install in the interactive user's account: -Mode Install. -Mode Once verifies CDP without a keypress.
param(
  [ValidateSet('Install', 'Watch', 'Once')][string]$Mode = 'Once',
  [string]$TargetId,
  [ValidateSet('manual', 'printscreen')][string]$Source = 'manual',
  [string]$TriggeredAtUtc,
  [string]$CaptureRoot = (Join-Path $env:LOCALAPPDATA 'wasm-agent-service-data\snapshots')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$taskName = 'WA-PrintScreen-CDP-Snapshot'
$stateFile = Join-Path $env:LOCALAPPDATA 'wasm-agent\cdp-state.json'
$utf8 = [Text.UTF8Encoding]::new($false)

function Save-Text([string]$Path, [string]$Value) {
  [IO.File]::WriteAllText($Path, $Value, $utf8)
}

function Invoke-Cdp([string]$WebSocketUrl, [string]$Method, [hashtable]$Parameters) {
  $socket = New-Object Net.WebSockets.ClientWebSocket
  $timeoutMs = if ($Method -eq 'Page.captureScreenshot') { 30000 } else { 10000 }
  $cancel = [Threading.CancellationTokenSource]::new($timeoutMs)
  try {
    $null = $socket.ConnectAsync([Uri]$WebSocketUrl, $cancel.Token).GetAwaiter().GetResult()
    $request = @{ id = 1; method = $Method; params = $Parameters } | ConvertTo-Json -Compress -Depth 10
    $bytes = [Text.Encoding]::UTF8.GetBytes($request)
    $null = $socket.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text,
      $true, $cancel.Token).GetAwaiter().GetResult()
    while ($true) {
      $body = New-Object IO.MemoryStream
      $buffer = New-Object byte[] 65536
      do {
        $part = $socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), $cancel.Token).GetAwaiter().GetResult()
        if ($part.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'cdp_socket_closed' }
        $body.Write($buffer, 0, $part.Count)
        if ($body.Length -gt 32MB) { throw 'cdp_response_too_large' }
      } while (-not $part.EndOfMessage)
      $answer = [Text.Encoding]::UTF8.GetString($body.ToArray()) | ConvertFrom-Json
      if (-not $answer.PSObject.Properties['id'] -or $answer.id -ne 1) { continue } # CDP events can arrive before the reply.
      if ($answer.PSObject.Properties['error']) { throw "cdp_$Method`: $($answer.error.message)" }
      if ($answer.result.PSObject.Properties['exceptionDetails']) { throw "cdp_$Method`: $($answer.result.exceptionDetails.text)" }
      return $answer.result
    }
  } catch {
    throw "cdp_$Method`: $($_.Exception.Message)"
  } finally {
    $socket.Dispose()
    $cancel.Dispose()
  }
}

function Get-Pages {
  if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) { throw "cdp_state_missing: $stateFile" }
  $state = [IO.File]::ReadAllText($stateFile) | ConvertFrom-Json
  if ($state.host -notin @('127.0.0.1', '::1', 'localhost') -or
      -not $state.port -or [int]$state.port -lt 1 -or [int]$state.port -gt 65535) {
    throw 'cdp_state_invalid_or_not_loopback'
  }
  $port = [int]$state.port
  $listing = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 5
  $pages = @()
  foreach ($item in $listing) {
    if ($item.type -eq 'page' -and $item.webSocketDebuggerUrl) { $pages += $item }
  }
  if ($pages.Count -eq 0) { throw 'cdp_no_page_targets' }
  foreach ($page in $pages) {
    $url = [Uri]$page.webSocketDebuggerUrl
    if ($url.Scheme -ne 'ws' -or $url.Host -notin @('127.0.0.1', '::1', 'localhost') -or
        $url.Port -ne $port -or -not $url.AbsolutePath.StartsWith('/devtools/page/')) {
      throw 'cdp_page_endpoint_not_loopback'
    }
  }
  return $pages
}

function Select-Page($Pages, [string]$ExplicitId) {
  if ($ExplicitId) {
    $matching = @($Pages | Where-Object { $_.id -eq $ExplicitId })
    if ($matching.Count -ne 1) { throw "cdp_target_not_found: $ExplicitId" }
    return $matching[0]
  }
  $focused = @()
  $visible = @()
  foreach ($page in $Pages) {
    try {
      $result = Invoke-Cdp $page.webSocketDebuggerUrl 'Runtime.evaluate' @{
        expression = '({focused: document.hasFocus(), visible: document.visibilityState === "visible"})'
        returnByValue = $true
      }
      if ($result.result.value.focused) { $focused += $page }
      if ($result.result.value.visible) { $visible += $page }
    } catch { } # A tab that closed during enumeration is not a candidate.
  }
  if ($focused.Count -eq 1) { return $focused[0] }
  if ($focused.Count -gt 1) { throw 'cdp_multiple_focused_pages' }
  if ($visible.Count -eq 1) { return $visible[0] }
  throw "cdp_active_tab_ambiguous: focused=$($focused.Count) visible=$($visible.Count)"
}

function Save-Snapshot([string]$ExplicitId, [string]$CaptureSource, [string]$KeyTime) {
  $pages = @(Get-Pages)
  $page = Select-Page $pages $ExplicitId
  $expression = @'
(() => {
  const html = document.documentElement ? document.documentElement.outerHTML : '';
  const visibleText = document.body ? document.body.innerText : '';
  if (html.length > 8000000 || visibleText.length > 2000000) throw Error('snapshot_page_too_large');
  return {url: location.href, title: document.title, html, visibleText,
    focused: document.hasFocus(), visibility: document.visibilityState};
})()
'@
  $dom = Invoke-Cdp $page.webSocketDebuggerUrl 'Runtime.evaluate' @{
    expression = $expression
    returnByValue = $true
  }
  if ($dom -is [array]) {
    $shapes = @($dom | ForEach-Object { $_.GetType().FullName })
    throw "cdp_dom_array: count=$($dom.Count) types=$(($shapes) -join ';')"
  }
  if (-not $dom.PSObject.Properties['result']) { throw "cdp_dom_shape: $(($dom.PSObject.Properties.Name) -join ',')" }
  $value = $dom.result.value
  if (-not $value -or $null -eq $value.html) { throw 'cdp_dom_snapshot_missing' }
  $screen = Invoke-Cdp $page.webSocketDebuggerUrl 'Page.captureScreenshot' @{
    format = 'png'; fromSurface = $false; captureBeyondViewport = $false
  }
  if (-not $screen.data) { throw 'cdp_screenshot_missing' }
  $png = [Convert]::FromBase64String([string]$screen.data)
  New-Item -ItemType Directory -Path $CaptureRoot -Force | Out-Null
  $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
  $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $folder = Join-Path $CaptureRoot "$stamp-$id"
  New-Item -ItemType Directory -Path $folder | Out-Null
  Save-Text (Join-Path $folder 'page.html') ([string]$value.html)
  Save-Text (Join-Path $folder 'visible.txt') ([string]$value.visibleText)
  [IO.File]::WriteAllBytes((Join-Path $folder 'page.png'), $png)
  $record = [ordered]@{
    source = $CaptureSource
    triggered_at_utc = $KeyTime
    captured_at_utc = (Get-Date).ToUniversalTime().ToString('o')
    target_id = $page.id
    url = $value.url
    title = $value.title
    focused = $value.focused
    visibility = $value.visibility
    html_bytes = $utf8.GetByteCount([string]$value.html)
    text_bytes = $utf8.GetByteCount([string]$value.visibleText)
    screenshot_bytes = $png.Length
    folder = $folder
  }
  $json = $record | ConvertTo-Json -Compress -Depth 4
  Save-Text (Join-Path $folder 'metadata.json') $json
  Save-Text (Join-Path $CaptureRoot 'latest.json') $json
  return $json
}

if ($Mode -eq 'Install') {
  $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($existing) { throw "task_already_exists: $taskName" }
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $powershell = Join-Path $PSHOME 'powershell.exe'
  $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Mode Watch"
  $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
  $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal | Out-Null
  Start-ScheduledTask -TaskName $taskName
  Write-Output "task_requested: $taskName"
  exit 0
}

if ($Mode -eq 'Once') {
  try { Save-Snapshot $TargetId $Source $TriggeredAtUtc }
  catch {
    New-Item -ItemType Directory -Path $CaptureRoot -Force | Out-Null
    Save-Text (Join-Path $CaptureRoot 'last-error.json') (@{
      at_utc = (Get-Date).ToUniversalTime().ToString('o'); error = $_.Exception.Message
      source = $Source; triggered_at_utc = $TriggeredAtUtc
    } | ConvertTo-Json -Compress)
    throw
  }
  exit 0
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class WaPrintScreenHook {
  const int WH_KEYBOARD_LL = 13, VK_SNAPSHOT = 0x2c;
  const int WM_KEYDOWN = 0x100, WM_KEYUP = 0x101, WM_SYSKEYDOWN = 0x104, WM_SYSKEYUP = 0x105;
  delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
  static readonly HookProc Callback = OnKey;
  static IntPtr hook;
  static int pending;
  static int observed;
  static long lastPrint;
  [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
  [StructLayout(LayoutKind.Sequential)] struct MSG {
    public IntPtr hwnd; public uint message; public IntPtr wParam, lParam;
    public uint time; public POINT pt; public uint privateValue;
  }
  [DllImport("user32.dll", SetLastError=true)] static extern IntPtr SetWindowsHookEx(int id, HookProc fn, IntPtr module, uint thread);
  [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr value);
  [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr value, int code, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] static extern bool PeekMessage(out MSG msg, IntPtr window, uint min, uint max, uint remove);
  [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG msg);
  [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG msg);
  [DllImport("kernel32.dll", CharSet=CharSet.Auto)] static extern IntPtr GetModuleHandle(string name);
  static IntPtr OnKey(int code, IntPtr wParam, IntPtr lParam) {
    if (code >= 0) {
      Interlocked.Increment(ref observed); // Count only; never record other keys.
      long message = wParam.ToInt64();
      if ((message == WM_KEYDOWN || message == WM_KEYUP || message == WM_SYSKEYDOWN || message == WM_SYSKEYUP) &&
          Marshal.ReadInt32(lParam) == VK_SNAPSHOT) {
        long now = DateTime.UtcNow.Ticks;
        if (now - Interlocked.Read(ref lastPrint) > TimeSpan.TicksPerSecond) {
          Interlocked.Exchange(ref lastPrint, now);
          Interlocked.Exchange(ref pending, 1);
        }
      }
    }
    return CallNextHookEx(hook, code, wParam, lParam);
  }
  public static void Start() {
    hook = SetWindowsHookEx(WH_KEYBOARD_LL, Callback, GetModuleHandle(null), 0);
    if (hook == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
  }
  public static void Stop() { if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; } }
  public static bool Take() { return Interlocked.Exchange(ref pending, 0) != 0; }
  public static int Count() { return Interlocked.Exchange(ref observed, 0); }
  public static void Pump() { MSG msg; while (PeekMessage(out msg, IntPtr.Zero, 0, 0, 1)) { TranslateMessage(ref msg); DispatchMessage(ref msg); } }
}
'@

New-Item -ItemType Directory -Path $CaptureRoot -Force | Out-Null
[WaPrintScreenHook]::Start()
Save-Text (Join-Path $CaptureRoot 'watcher.json') (@{
  pid = $PID; started_at_utc = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json -Compress)
try {
  $capture = $null
  $lastHealth = Get-Date
  while ($true) {
    [WaPrintScreenHook]::Pump()
    if ([WaPrintScreenHook]::Take()) {
      if ($capture -and -not $capture.HasExited) {
        Add-Content -LiteralPath (Join-Path $CaptureRoot 'watcher.log') -Value "$(Get-Date -Format o) capture_busy"
      } else {
        $triggered = (Get-Date).ToUniversalTime().ToString('o')
        try {
          # Pin the page before starting a new PowerShell process. The tab can still close later;
          # that fails visibly instead of silently capturing a different page.
          $selected = Select-Page @(Get-Pages) ''
        } catch {
          $problem = $_.Exception.Message
          Save-Text (Join-Path $CaptureRoot 'last-error.json') (@{
            at_utc = (Get-Date).ToUniversalTime().ToString('o')
            source = 'printscreen'; triggered_at_utc = $triggered; error = $problem
          } | ConvertTo-Json -Compress)
          Add-Content -LiteralPath (Join-Path $CaptureRoot 'watcher.log') -Value "$(Get-Date -Format o) selection_failed $problem"
          continue
        }
        Add-Content -LiteralPath (Join-Path $CaptureRoot 'watcher.log') -Value "$(Get-Date -Format o) printscreen target=$($selected.id)"
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode Once -TargetId $($selected.id) -Source printscreen -TriggeredAtUtc $triggered"
        $capture = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
      }
    }
    if (((Get-Date) - $lastHealth).TotalSeconds -ge 10) {
      Save-Text (Join-Path $CaptureRoot 'hook-health.json') (@{
        pid = $PID; at_utc = (Get-Date).ToUniversalTime().ToString('o')
        key_events_since_last = [WaPrintScreenHook]::Count()
      } | ConvertTo-Json -Compress)
      $lastHealth = Get-Date
    }
    Start-Sleep -Milliseconds 20
  }
} finally { [WaPrintScreenHook]::Stop() }
