param([string]$Name,[string]$Script,[string]$Binary)
$ErrorActionPreference='Stop'
$reviewRepo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$reviewSpec=@{program=(Get-Command node).Source;args=@($Script,$Binary);cwd=$reviewRepo;receipt=(Join-Path $PSScriptRoot "$Name-job.json");stop=(Join-Path $PSScriptRoot "$Name-job.stop")}
$reviewSpecPath=Join-Path $PSScriptRoot "$Name-job-spec.json"
[IO.File]::WriteAllText($reviewSpecPath,($reviewSpec | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $reviewRepo 'scripts/fixture-native-job.ps1') -Spec $reviewSpecPath
exit $LASTEXITCODE
