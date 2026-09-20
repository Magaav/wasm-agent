# Model-free onboarding. Requires first-run.ps1 helpers in the caller's scope.
Set-StrictMode -Version Latest
function Assert-WaService([string]$Service, $Operators) {
  Assert-WaProviderUrl $Service
  if (@($Operators).Count -eq 0) { throw 'operator_pins_required' }
  $reply = Invoke-RestMethod -Uri ($Service.TrimEnd('/') + '/service') -TimeoutSec 15
  if ($reply.protocol -ne 1 -or $reply.enrollment_ready -ne $true) { throw 'managed_service_not_ready' }
  foreach ($operator in @($Operators)) {
    if ($operator.node_id -cnotmatch '^[a-f0-9]{32}$' -or $operator.public_key -cnotmatch '^[a-f0-9]{64}$') {
      throw 'invalid_operator_pin'
    }
    $found = @($reply.operators | Where-Object {
      $_.node_id -ceq $operator.node_id -and $_.public_key -ceq $operator.public_key
    })
    if ($found.Count -ne 1) { throw 'operator_identity_not_authorized_by_service' }
  }
}
function Save-WaEnrollment {
  param([string]$Config, [string]$Service, $Operators, [string]$Name, [string]$Workspace,
        [int]$Port, [ValidateRange(1, 8760)][int]$Hours = 24, [switch]$Consent)
  if (-not $Consent) { throw 'explicit_remote_access_consent_required' }
  if (Test-Path -LiteralPath (Join-Path $Config 'env')) { throw 'fresh_guest_home_required' }
  Assert-WaService $Service $Operators
  Save-WaSetup -Config $Config -Mode guest -Name $Name -Workspace $Workspace
  $settings = [IO.File]::ReadAllText((Join-Path $Config 'env'))
  $settings = $settings -replace '(?m)^WASM_AGENT_RENDEZVOUS=.*$', ('WASM_AGENT_RENDEZVOUS=' + $Service.TrimEnd('/'))
  $settings = $settings -replace '(?m)^WASM_AGENT_RELAY=.*$', ('WASM_AGENT_RELAY=' + $Service.TrimEnd('/'))
  $settings += "WASM_AGENT_MANAGED=1`n"
  Write-WaPrivateText (Join-Path $Config 'node.name') ($Name.Trim() + "`n")
  Write-WaPrivateText (Join-Path $Config 'env') $settings
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $profile = [ordered]@{ schema=1; active=$true; service=$Service.TrimEnd('/'); operators=@($Operators)
    local_role='guest'; consented_at=$now; expires_at=($now + 3600 * $Hours); port=$Port
    authority='full-user-account'; consent_id=[guid]::NewGuid().ToString() }
  Write-WaPrivateText (Join-Path $Config 'enrollment.json') ($profile | ConvertTo-Json -Depth 8)
}
function Read-WaEnrollment([string]$Config) {
  $settings = Read-WaConfiguration $Config
  if ($settings['WASM_AGENT_MANAGED'] -ne '1') { throw 'managed_guest_required' }
  $profile = [IO.File]::ReadAllText((Join-Path $Config 'enrollment.json')) | ConvertFrom-Json
  if ($profile.schema -ne 1) { throw 'invalid_enrollment' }
  return $profile
}
function Revoke-WaEnrollment([string]$Config) {
  $profile = Read-WaEnrollment $Config
  $profile.active = $false
  Write-WaPrivateText (Join-Path $Config 'enrollment.json') ($profile | ConvertTo-Json -Depth 8)
  Write-Output 'Remote access REVOKED. Queued/future calls are refused; outbound polling pauses.'
  Write-Output 'Already running native operations may finish. Registry presence can remain briefly until its heartbeat expires.'
}
function Renew-WaEnrollment([string]$Config, [int]$Hours, [switch]$Consent) {
  if (-not $Consent) { throw 'explicit_remote_access_consent_required' }
  if ($Hours -lt 1 -or $Hours -gt 8760) { throw 'invalid_access_hours' }
  $profile = Read-WaEnrollment $Config
  Assert-WaService $profile.service $profile.operators
  $profile.active = $true
  $profile.consented_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $profile.expires_at = $profile.consented_at + 3600 * $Hours
  $profile.consent_id = [guid]::NewGuid().ToString()
  Write-WaPrivateText (Join-Path $Config 'enrollment.json') ($profile | ConvertTo-Json -Depth 8)
}
function Confirm-WaAccess([string]$Service, $Operators, [int]$Hours) {
  Write-Host "Remote assistance through $Service for $Hours hours (or until wa disconnect)."
  Write-Host ('Approved operator IDs: ' + ((@($Operators) | ForEach-Object { $_.node_id }) -join ', '))
  Write-Host 'These operators can read/write your files and run programs with YOUR Windows account authority.'
  Write-Host 'This is not a workspace sandbox. No model subscription or API key is required.'
  Write-Host 'Your chosen node name and public identity are sent to the service. No inbound firewall rule is added.'
  return ((Read-Host 'Type CONNECT to authorize this access; anything else cancels') -ceq 'CONNECT')
}
