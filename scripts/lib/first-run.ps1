# Shared Windows onboarding mechanics. Never infer remote authorization.
Set-StrictMode -Version Latest

function Get-WaConfigDirectory {
  $homePath = $env:WASM_AGENT_HOME
  if (-not $homePath) { $homePath = [Environment]::GetFolderPath('UserProfile') }
  if (-not [IO.Path]::IsPathRooted($homePath) -or $homePath.StartsWith('/')) {
    throw 'native_absolute_home_required'
  }
  Join-Path ([IO.Path]::GetFullPath($homePath)) '.wasm-agent'
}

function Read-WaConfiguration([string]$Config) {
  $values = @{}
  $path = Join-Path $Config 'env'
  if (Test-Path -LiteralPath $path) {
    foreach ($line in [IO.File]::ReadAllLines($path)) {
      if ($line.Trim().StartsWith('#')) { continue }
      $index = $line.IndexOf('=')
      if ($index -gt 0) {
        $key = $line.Substring(0, $index).Trim()
        # The native loader keeps the first value; keep the same semantics.
        if (-not $values.ContainsKey($key)) {
          $values[$key] = $line.Substring($index + 1).Trim().Trim('"', "'")
        }
      }
    }
  }
  $values
}

function Assert-WaValue([string]$Value, [string]$Label, [switch]$AllowEmpty) {
  if ((-not $AllowEmpty -and [string]::IsNullOrWhiteSpace($Value)) -or
      $Value.IndexOfAny([char[]]"`r`n`0") -ge 0) { throw "invalid_$Label" }
}

function Assert-WaProviderUrl([string]$Value) {
  Assert-WaValue $Value 'provider_url'
  $uri = $null
  if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
      $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
      ($uri.Scheme -ne 'https' -and -not ($uri.Scheme -eq 'http' -and $uri.IsLoopback))) {
    throw 'provider_url_requires_https_or_loopback_http_without_credentials_or_query'
  }
}

function Protect-WaPrivateFile([string]$Path) {
  # Request/update only the DACL. Reusing Set-Acl's mutated object can ask for
  # SACL privileges on a later file, which ordinary Windows users do not have.
  $acl = [IO.File]::GetAccessControl($Path, [Security.AccessControl.AccessControlSections]::Access)
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($entry in @($acl.Access)) { $acl.RemoveAccessRuleSpecific($entry) }
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')
  $acl.AddAccessRule($rule)
  [IO.File]::SetAccessControl($Path, $acl)
}

function Write-WaPrivateText([string]$Path, [string]$Text) {
  $directory = Split-Path $Path -Parent
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
  $temporary = Join-Path $directory ('.setup-' + [guid]::NewGuid().ToString('N'))
  try {
    # Protect the empty file BEFORE writing any credential bytes.
    $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew)
    $stream.Dispose()
    Protect-WaPrivateFile $temporary
    [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) {
      # Replace is atomic on the same volume. Preserve no plaintext backup.
      Protect-WaPrivateFile $Path
      [IO.File]::Replace($temporary, $Path, [NullString]::Value)
    } else { [IO.File]::Move($temporary, $Path) }
  } finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
  }
}

function Save-WaSetup {
  param([string]$Config, [string]$Mode, [string]$Name, [string]$Workspace,
        [string]$BaseUrl, [string]$Model, [Security.SecureString]$ApiKey)
  if ($Mode -notin @('personal', 'guest')) { throw 'invalid_mode' }
  Assert-WaValue $Name 'name'
  if ($Name.Length -gt 80) { throw 'name_too_long' }
  Assert-WaValue $Workspace 'workspace'
  if (-not [IO.Path]::IsPathRooted($Workspace) -or $Workspace.StartsWith('/') -or
      -not (Test-Path -LiteralPath $Workspace -PathType Container)) { throw 'existing_native_workspace_required' }
  $workspacePath = (Get-Item -LiteralPath $Workspace).FullName
  $existing = Read-WaConfiguration $Config
  if ((Test-Path -LiteralPath (Join-Path $Config 'env')) -and -not $existing['WASM_AGENT_ONBOARDING_MODE']) {
    throw 'unmanaged_configuration: use a clean WASM_AGENT_HOME; setup will not adopt an operator configuration'
  }
  $launchers = Join-Path $Config 'launchers'
  if (Test-Path -LiteralPath $launchers) {
    foreach ($record in @(Get-ChildItem -LiteralPath $launchers -Filter '*.pid' -File -Recurse)) {
      $serverPid = 0
      if (-not [int]::TryParse([IO.File]::ReadAllText($record.FullName).Trim(), [ref]$serverPid) -or $serverPid -le 0) {
        throw 'invalid_server_pid_record: cannot prove setup is safe while a server may be running'
      }
      if (Get-Process -Id $serverPid -ErrorAction SilentlyContinue) {
        throw 'server_still_running: finish the task and stop the recorded server before changing setup'
      }
    }
  }
  $updates = [ordered]@{
    WASM_AGENT_ONBOARDING_MODE = $Mode
    WASM_AGENT_DISPLAY_NAME = $Name.Trim()
    WASM_AGENT_WORKSPACE = $workspacePath
  }
  if ($Mode -eq 'personal') {
    Assert-WaProviderUrl $BaseUrl
    Assert-WaValue $Model 'model'
    $updates['WASM_AGENT_LLM_BASE_URL'] = $BaseUrl.TrimEnd('/')
    $updates['WASM_AGENT_LLM_MODEL'] = $Model.Trim()
    $updates['WASM_AGENT_PROVIDER'] = 'opencode-go'
    $updates['WASM_AGENT_NODE_ROLE'] = 'master'
    # Avoid claiming env settings win over the native provider's persisted state.
    $selectionFiles = @()
    if (Test-Path -LiteralPath $Config) {
      $selectionFiles = @(Get-ChildItem -LiteralPath $Config -File -Recurse | Where-Object {
        $_.Name -eq 'provider' -or $_.Name -eq 'model.opencode-go'
      })
    }
    foreach ($file in $selectionFiles) {
      $wanted = if ($file.Name -eq 'provider') { 'opencode-go' } else { $Model.Trim() }
      if ([IO.File]::ReadAllText($file.FullName).Trim() -ne $wanted) {
        throw 'persisted_provider_selection_conflicts: change the selection in the existing UI before setup'
      }
    }
    if ($ApiKey -and $ApiKey.Length -gt 0) {
      $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ApiKey)
      try { $updates['WASM_AGENT_LLM_API_KEY'] = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
      finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    } elseif (-not $existing['WASM_AGENT_LLM_API_KEY']) {
      throw 'api_key_required: run interactive setup; keys are not accepted in arguments'
    }
  } else {
    $updates['WASM_AGENT_NODE_ROLE'] = 'guest'
  }
  # Neither entry path implicitly opts into a network. Remote enrollment has its
  # own security gates. Preserve unrelated settings, but disable connectivity.
  $updates['WASM_AGENT_RENDEZVOUS'] = ''
  $updates['WASM_AGENT_ENDPOINT'] = ''
  $updates['WASM_AGENT_SYNC_TO'] = ''
  foreach ($key in $updates.Keys) {
    Assert-WaValue ([string]$updates[$key]) 'configuration_value' -AllowEmpty
    $override = [Environment]::GetEnvironmentVariable($key, 'Process')
    if ($null -ne $override -and $override -ne [string]$updates[$key]) {
      throw "process_environment_overrides_config: $key (clear it before setup)"
    }
  }
  $lines = @()
  $path = Join-Path $Config 'env'
  if (Test-Path -LiteralPath $path) {
    $lines = @([IO.File]::ReadAllLines($path) | Where-Object {
      $index = $_.IndexOf('=')
      $index -lt 1 -or -not $updates.Contains($_.Substring(0, $index).Trim())
    })
  }
  foreach ($key in $updates.Keys) { $lines += "$key=$($updates[$key])" }
  Write-WaPrivateText $path (($lines -join "`n") + "`n")
}

function Test-WaProvider([hashtable]$Configuration) {
  $url = $Configuration['WASM_AGENT_LLM_BASE_URL']
  Assert-WaProviderUrl $url
  if (-not $Configuration['WASM_AGENT_LLM_API_KEY'] -or -not $Configuration['WASM_AGENT_LLM_MODEL']) {
    throw 'provider_configuration_incomplete'
  }
  Write-Output 'Validating provider with one small model request (may incur provider cost).'
  $payload = @{
    model = $Configuration['WASM_AGENT_LLM_MODEL']; max_tokens = 16
    messages = @(@{ role = 'user'; content = 'Reply with OK.' })
  } | ConvertTo-Json -Depth 4 -Compress
  try {
    $reply = Invoke-WebRequest -UseBasicParsing -Method Post -Uri ($url.TrimEnd('/') + '/chat/completions') `
      -Headers @{ Authorization = 'Bearer ' + $Configuration['WASM_AGENT_LLM_API_KEY'] } `
      -ContentType 'application/json' -Body $payload -TimeoutSec 30 -MaximumRedirection 0
    $body = $reply.Content | ConvertFrom-Json
    if (-not $body.choices -or -not $body.choices[0].message.content) {
      throw 'no_text_response'
    }
    Write-Output 'Provider VALIDATED: a text response arrived. Tool-backed task success is not yet verified.'
  } catch {
    # Do not print Exception.Message: provider bodies and URLs can contain secrets.
    throw 'provider_validation_failed: settings are saved; check endpoint, model, credential and provider availability, then retry wa doctor -ValidateProvider'
  }
}

function Test-WaWebView {
  foreach ($path in @('HKCU:\Software\Microsoft\EdgeUpdate\Clients\*',
                       'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\*',
                       'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\*')) {
    foreach ($entry in @(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue)) {
      if ($entry.PSObject.Properties['name'] -and $entry.name -like '*WebView2*') { return $true }
    }
  }
  return $false
}

function Start-WaLocalUi([string]$Install, [string]$Config, [int]$Port, [switch]$Browser, [switch]$NoOpen) {
  $settings = Read-WaConfiguration $Config
  if ($settings['WASM_AGENT_ONBOARDING_MODE'] -ne 'personal') {
    throw 'personal_setup_required: guest networking is disabled pending verified enrollment'
  }
  if (-not (Test-Path -LiteralPath $settings['WASM_AGENT_WORKSPACE'] -PathType Container)) {
    throw 'configured_workspace_unavailable'
  }
  foreach ($entry in @(Get-ChildItem Env: | Where-Object {
    ($_.Name -like 'WASM_AGENT_*' -and $_.Name -ne 'WASM_AGENT_HOME') -or $_.Name -eq 'WA_SCRIPT'
  })) {
    if ($entry.Value) { throw "unsafe_launch_override: $($entry.Name)" }
  }
  if (-not $NoOpen -and -not $Browser -and -not (Test-WaWebView)) {
    throw 'webview2_runtime_missing: install Microsoft WebView2 Runtime or use wa ui -Browser'
  }
  # Reconnect only to the recorded process from THIS installation, not any process
  # which happens to answer /health. Never stop or replace a window/server here.
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $identity = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Install)))).Replace('-', '').Substring(0, 16) }
  finally { $sha.Dispose() }
  $runtime = Join-Path $Config "launchers/$identity"
  New-Item -ItemType Directory -Force -Path $runtime | Out-Null
  $pidFile = Join-Path $runtime "serve-$Port.pid"
  $listener = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
  if ($listener.Count -gt 0) {
    if (-not (Test-Path -LiteralPath $pidFile)) { throw 'port_owned_by_another_process' }
    $recorded = [int]([IO.File]::ReadAllText($pidFile).Trim())
    $process = Get-Process -Id $recorded -ErrorAction SilentlyContinue
    if (-not $process -or $listener[0].OwningProcess -ne $recorded -or
        $process.Path -ne (Join-Path $Install 'wa.exe')) { throw 'port_owned_by_another_process' }
  } else {
    if (@(Get-NetTCPConnection -LocalPort ($Port + 1) -State Listen -ErrorAction SilentlyContinue).Count -gt 0) {
      throw 'client_port_in_use'
    }
    $ui = Join-Path $Install 'ui'
    $process = Start-Process -FilePath (Join-Path $Install 'wa.exe') -PassThru -WindowStyle Hidden `
      -WorkingDirectory $settings['WASM_AGENT_WORKSPACE'] `
      -ArgumentList @('serve', '--port', $Port, '--client-port', ($Port + 1), '--ui', ('"' + $ui + '"')) `
      -RedirectStandardOutput (Join-Path $runtime "serve-$Port.log") `
      -RedirectStandardError (Join-Path $runtime "serve-$Port.err.log")
    [IO.File]::WriteAllText($pidFile, [string]$process.Id)
    $ready = $false
    for ($i = 0; $i -lt 50; $i++) {
      if ($process.HasExited) { break }
      Start-Sleep -Milliseconds 200
      try {
        $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 "http://127.0.0.1:$Port/health"
        $owners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
        if ($response.StatusCode -eq 200 -and $owners.Count -eq 1 -and $owners[0].OwningProcess -eq $process.Id) {
          $ready = $true; break
        }
      } catch { }
    }
    if (-not $ready) { throw "server_start_unverified: inspect $runtime/serve-$Port.err.log; PID $($process.Id)" }
  }
  $url = "http://127.0.0.1:$Port/"
  if ($NoOpen) { Write-Output "Local server verified at $url; no window requested."; return }
  if ($Browser) { Start-Process $url }
  else {
    $env:WASM_AGENT_UI_URL = $url
    $env:WASM_AGENT_CLIENT_PORT = [string]($Port + 1)
    Start-Process (Join-Path $Install 'wa-window.exe')
  }
  Write-Output "Local server verified at $url; window launch requested."
}
