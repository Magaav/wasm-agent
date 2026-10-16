# Human-run exact-match task retirement. No registration, broad deletes or process killing.
param([Parameter(Mandatory=$true)][string]$Manifest,[switch]$Apply,[string]$FixtureXml)
$ErrorActionPreference='Stop'
$m=Get-Content -Raw -LiteralPath $Manifest | ConvertFrom-Json
if($m.schema -ne 1 -or $m.owner -ne 'wasm-agent-whatsapp' -or $m.task_name -ne 'wasm-agent-whatsapp-chrome') {throw 'unowned_task_manifest'}
if($FixtureXml -and $Apply) {throw 'fixture_cannot_apply'}
if($FixtureXml) {$xmlText=Get-Content -Raw -LiteralPath $FixtureXml} else {$xmlText=Export-ScheduledTask -TaskName $m.task_name}
$bytes=[System.Text.Encoding]::UTF8.GetBytes($xmlText)
$sha=[System.Security.Cryptography.SHA256]::Create()
$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
if($hash -ne $m.xml_sha256) {throw 'task_xml_hash_mismatch'}
[xml]$xml=$xmlText
if($xml.Task.Principals.Principal.UserId -ne $m.principal_sid) {throw 'task_owner_mismatch'}
if(@($xml.Task.Actions.Exec).Count -ne 1 -or $xml.Task.Actions.Exec.Command -ne $m.command -or $xml.Task.Actions.Exec.Arguments -ne $m.arguments) {throw 'task_action_mismatch'}
if(-not [System.IO.Path]::IsPathRooted($m.wrapper_path)) {throw 'absolute_wrapper_required'}
$item=Get-Item -LiteralPath $m.wrapper_path
if(($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {throw 'wrapper_reparse_point_refused'}
if((Get-FileHash -Algorithm SHA256 -LiteralPath $m.wrapper_path).Hash.ToLowerInvariant() -ne $m.wrapper_sha256) {throw 'wrapper_hash_mismatch'}
if($Apply) {
 Disable-ScheduledTask -TaskName $m.task_name | Out-Null
 if((Get-ScheduledTask -TaskName $m.task_name).Settings.Enabled) {throw 'task_disable_unverified_do_not_replay'}
}
@{ok=$true;dry_run=(-not $Apply);fixture=[bool]$FixtureXml;task=$m.task_name;process_settlement_required=$true;activation_authorized=$false;history_preserved=$true} | ConvertTo-Json -Compress
