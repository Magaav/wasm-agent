# Paste-once bootstrap. Only a checksum-pinned, published package may execute.
param(
  [string]$ReleaseManifestUri = 'https://raw.githubusercontent.com/Magaav/wasm-agent/main/releases/windows-service.json',
  [string]$ManifestPath,
  [string]$Name,
  [string]$InstallDir,
  [string]$NodeHome,
  [ValidateRange(1,8760)][int]$Hours = 24,
  [switch]$AcceptAccess,
  [switch]$NoRegisterCommand
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$job = $null
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('wa-bootstrap-' + [guid]::NewGuid())
$environment = @{}
$environmentIsolated = $false
$enrolled = $false
$connected = $false
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  if ($ManifestPath) { $release = [IO.File]::ReadAllText([IO.Path]::GetFullPath($ManifestPath)) | ConvertFrom-Json }
  else {
    if (([Uri]$ReleaseManifestUri).Scheme -ne 'https') { throw 'release_manifest_requires_https' }
    $release = Invoke-RestMethod -Uri $ReleaseManifestUri -TimeoutSec 30
  }
  if ($release.schema -ne 1 -or $release.available -ne $true) {
    throw 'service_release_not_published: operator must publish the tested package and enable managed rendezvous first'
  }
  if ($release.sha256 -cnotmatch '^[a-f0-9]{64}$' -or @($release.operators).Count -eq 0) { throw 'invalid_release_descriptor' }
  $local = [Environment]::GetFolderPath('LocalApplicationData')
  if (-not $InstallDir) { $InstallDir = Join-Path $local 'wasm-agent-service' }
  if (-not $NodeHome) { $NodeHome = Join-Path $local 'wasm-agent-service-data' }
  $InstallDir = [IO.Path]::GetFullPath($InstallDir)
  $NodeHome = [IO.Path]::GetFullPath($NodeHome)
  if (Test-Path -LiteralPath $InstallDir) { throw 'installation_exists: use wa connect or the external upgrade procedure' }
  if (Test-Path -LiteralPath $NodeHome) { throw 'data_home_exists: refusing to adopt or overwrite existing identity or credentials' }
  New-Item -ItemType Directory -Path $scratch | Out-Null
  # Install concurrently with the name/consent prompts. The child never launches WA.
  $job = Start-Job -ArgumentList @($release, $scratch, $InstallDir, [bool]$ManifestPath) -ScriptBlock {
    param($release, $scratch, $install, $localManifest)
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $archive = Join-Path $scratch 'package.zip'
    $uri = [Uri]$release.package_url
    if ($localManifest -and $uri.IsFile) { Copy-Item -LiteralPath $uri.LocalPath -Destination $archive }
    else {
      if ($uri.Scheme -ne 'https' -and -not ($localManifest -and $uri.IsLoopback -and $uri.Scheme -eq 'http')) { throw 'package_requires_https' }
      Invoke-WebRequest -UseBasicParsing -Uri $uri.AbsoluteUri -OutFile $archive -TimeoutSec 180
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $release.sha256) { throw 'archive_checksum_mismatch' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
      $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
      $total = 0L
      foreach ($entry in $zip.Entries) {
        $path = $entry.FullName.Replace('\','/')
        if ($path -notmatch '^[a-zA-Z0-9_.\-/]+$' -or $path.StartsWith('/') -or
            @($path.TrimEnd('/').Split('/') | Where-Object { $_ -in @('', '.', '..') -or $_.EndsWith('.') }).Count -gt 0 -or
            -not $seen.Add($path)) { throw 'unsafe_archive_entry' }
        $total += $entry.Length
        if ($total -gt 1GB -or $seen.Count -gt 1000) { throw 'archive_too_large' }
      }
    } finally { $zip.Dispose() }
    $extracted = Join-Path $scratch 'extracted'
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $extracted)
    & (Join-Path $extracted 'install.ps1') -InstallDir $install
    if (-not (Test-Path -LiteralPath (Join-Path $install 'manifest.json'))) { throw 'background_install_failed' }
  }
  Write-Host 'Downloading and verifying WA in the background. No node has been connected.'
  while (-not $Name -or $Name.Trim().Length -eq 0) { $Name = Read-Host 'Name this node' }
  if ($Name.Length -gt 80 -or $Name -match '[\r\n\x00]') { throw 'invalid_node_name' }
  # Consent is collected before starting a runtime, never inferred from a node name.
  Write-Host "Allow the operator at $($release.service) to automate this Windows account for $Hours hours?"
  Write-Host ('Pinned operator IDs: ' + ((@($release.operators) | ForEach-Object { $_.node_id }) -join ', '))
  Write-Host 'This allows reading/writing files and running programs as YOU, not just inside a workspace.'
  Write-Host 'Your node name/public identity go to the service. No model key or inbound firewall rule is needed.'
  if (-not $AcceptAccess -and (Read-Host 'Type CONNECT to approve; anything else cancels') -cne 'CONNECT') { throw 'access_not_approved' }
  Write-Host 'Finishing installation...'
  $job | Wait-Job | Receive-Job -ErrorAction Stop
  if ($job.State -ne 'Completed') { throw 'background_install_failed' }
  . (Join-Path $InstallDir 'scripts/lib/first-run.ps1')
  . (Join-Path $InstallDir 'scripts/lib/managed-guest.ps1')
  . (Join-Path $InstallDir 'scripts/lib/release-package.ps1')
  Test-WaReleasePackage $InstallDir | Out-Null
  Assert-WaService $release.service $release.operators
  # Never inherit a developer/operator provider key or Lua override into a customer.
  $environmentIsolated = $true
  foreach ($entry in @(Get-ChildItem Env: | Where-Object {
    $_.Name -like 'WASM_AGENT_*' -or $_.Name -like 'WA_*' -or $_.Name -in @('OPENAI_API_KEY','OPENCODE_GO_API_KEY')
  })) {
    $environment[$entry.Name] = $entry.Value
    [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
  }
  $env:WASM_AGENT_HOME = $NodeHome
  $workspace = Join-Path $NodeHome 'workspace'
  New-Item -ItemType Directory -Path $workspace | Out-Null
  $config = Get-WaConfigDirectory
  $one = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  $one.Start(); $port = $one.LocalEndpoint.Port
  $two = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, ($port + 1))
  try { $two.Start() } finally { $one.Stop(); $two.Stop() }
  Save-WaEnrollment -Config $config -Service $release.service -Operators $release.operators `
    -Name $Name -Workspace $workspace -Port $port -Hours $Hours -Consent
  $enrolled = $true
  Write-WaPrivateText (Join-Path $config 'AGENTS.guest.md') ([IO.File]::ReadAllText((Join-Path $InstallDir 'AGENTS.runtime.md')))
  Start-WaLocalUi -Install $InstallDir -Config $config -Port $port -NoOpen
  $identity = (& (Join-Path $InstallDir 'wa.exe') node | Out-String | ConvertFrom-Json)
  if ($LASTEXITCODE -ne 0) { throw 'identity_unavailable' }
  # The local runtime reports only its own registration. No customer inventory is fetched.
  $registered = $false
  for ($i=0; $i -lt 30; $i++) {
    $status = (& (Join-Path $InstallDir 'wa.exe') access | Out-String | ConvertFrom-Json)
    if ($status.registered -eq $true -and $status.attached -eq $true) { $registered = $true; break }
    Start-Sleep -Milliseconds 500
  }
  if (-not $registered) { throw 'registration_or_relay_attachment_not_verified' }
  if (-not $NoRegisterCommand) {
    $bin = Join-Path $local 'wasm-agent-service-cli'
    if (Test-Path -LiteralPath $bin) { throw 'command_shim_exists: refusing to overwrite it' }
    New-Item -ItemType Directory -Path $bin | Out-Null
    # Keep mutable launch configuration outside the immutable release inventory.
    Write-WaGuestShim -Path (Join-Path $bin 'wa.cmd') -Install $InstallDir -NodeHome $NodeHome
    $previous = [Environment]::GetEnvironmentVariable('Path','User')
    [Environment]::SetEnvironmentVariable('Path', ((@($bin) + @($previous -split ';' | Where-Object { $_ -and $_ -ne $bin })) -join ';'), 'User')
    $env:Path = $bin + ';' + $env:Path
  }
  $connected = $true
  Write-Host "CONNECTED as guest: $Name ($($identity.node_id)). No model configured."
  Write-Host 'Use wa disconnect to revoke access; wa connect to renew/reconnect after logout or expiry.'
  Write-Host "Files: $InstallDir | Private state: $NodeHome"
} catch {
  if ($enrolled -and -not $connected) {
    try { Revoke-WaEnrollment (Join-Path $NodeHome '.wasm-agent') } catch { Write-Warning 'Could not verify local revocation; inspect enrollment.json before using this installation.' }
  }
  Write-Error $_.Exception.Message -ErrorAction Continue
  throw
} finally {
  if ($job) { $job | Stop-Job -ErrorAction SilentlyContinue; $job | Remove-Job -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
  if (-not $connected -and $InstallDir -and (Test-Path -LiteralPath $InstallDir)) {
    Write-Warning "Installation remains at $InstallDir; no successful connection was claimed."
  }
  if ($environmentIsolated) {
    foreach ($entry in @(Get-ChildItem Env: | Where-Object {
      $_.Name -like 'WASM_AGENT_*' -or $_.Name -like 'WA_*' -or $_.Name -in @('OPENAI_API_KEY','OPENCODE_GO_API_KEY')
    })) { [Environment]::SetEnvironmentVariable($entry.Name,$null,'Process') }
    foreach ($key in $environment.Keys) { [Environment]::SetEnvironmentVariable($key,$environment[$key],'Process') }
  }
}
