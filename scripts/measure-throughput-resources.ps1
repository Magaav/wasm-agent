param([int]$Jobs=1,[Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$directory=[IO.Path]::GetFullPath($Output)
if ($directory.Contains('"') -or $root.Contains('"')) { throw 'Paths must not contain quotes' }
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$node=(Get-Command node).Source
$arguments='"'+(Join-Path $root 'scripts/gate-check.mjs')+'" run ui-js --jobs '+$Jobs+' --output "'+$directory+'"'
$child=Start-Process -FilePath $node -ArgumentList $arguments -WorkingDirectory $root -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $directory 'stdout.log') -RedirectStandardError (Join-Path $directory 'stderr.log')
$null=$child.Handle
$watch=[Diagnostics.Stopwatch]::StartNew()
$cpu=@{}; $read=@{}; $write=@{}; $peakMemory=0L; $samples=0; $rows=@()
do {
  $snapshot=Get-CimInstance Win32_Process
  $tree=[Collections.Generic.HashSet[int]]::new(); [void]$tree.Add($child.Id)
  do {
    $grew=$false
    foreach($process in $snapshot) {
      if($tree.Contains([int]$process.ParentProcessId) -and $tree.Add([int]$process.ProcessId)) {$grew=$true}
    }
  } while($grew)
  $memory=0L
  foreach($process in $snapshot) {
    if(-not $tree.Contains([int]$process.ProcessId)){continue}
    $key=[string]$process.ProcessId+':'+[string]$process.CreationDate
    $ticks=[double]$process.UserModeTime+[double]$process.KernelModeTime
    $cpu[$key]=[Math]::Max([double]$cpu[$key],$ticks)
    $read[$key]=[Math]::Max([double]$read[$key],[double]$process.ReadTransferCount)
    $write[$key]=[Math]::Max([double]$write[$key],[double]$process.WriteTransferCount)
    $memory+=[long]$process.WorkingSetSize
  }
  $peakMemory=[Math]::Max($peakMemory,$memory);$samples++
  $rows+=@{ms=$watch.ElapsedMilliseconds;working_set_bytes=$memory;pids=@($tree)}
  Start-Sleep -Milliseconds 500
  $child.Refresh()
} while(-not $child.HasExited)
$child.WaitForExit()
if($null -eq $child.ExitCode){throw "Child exit status unavailable; resource sample is not verified"}
$result=[pscustomobject]@{schema=1;workload='ui-js';jobs=$Jobs;samples=$samples;wall_ms=$watch.ElapsedMilliseconds;exit=$child.ExitCode;observed_cpu_ms=(@($cpu.Values)|Measure-Object -Sum).Sum/10000;peak_observed_working_set_bytes=$peakMemory;observed_read_bytes=(@($read.Values)|Measure-Object -Sum).Sum;observed_write_bytes=(@($write.Values)|Measure-Object -Sum).Sum;rows=$rows;limits='500ms plus CIM scan sampling misses short-lived children; counters are lower bounds; working set is summed resident memory, not unique physical memory; sampler and foreign workload perturbation not charged to child'}
$result|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $directory 'resources.json') -Encoding utf8
$result|Select-Object jobs,samples,wall_ms,exit,observed_cpu_ms,peak_observed_working_set_bytes,observed_read_bytes,observed_write_bytes|ConvertTo-Json
exit $child.ExitCode
