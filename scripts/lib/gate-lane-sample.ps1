# Sample one process TREE's CPU on Windows: the gate's own descendants, never the machine.
#
# The gate lane runs as one sample process rather than one process per interval, because
# `powershell.exe` start-up (~300 ms) costs more than the sample it would take. Every
# interval it snapshots Win32_Process once, walks the parent links down from -Root, and
# writes one JSON line: the elapsed ms, the summed CPU of the tree, and each observed pid
# with its own CPU counter. The counter is 100 ns ticks (`UserModeTime` + `KernelModeTime`),
# absolute - never a delta - so the reader can subtract per pid and survive a sampler
# restart. See scripts/gate-lane.mjs for how the lines are reduced.
#
# A machine-wide count is what docs/EVOLUTION.md measured, and it could not attribute a
# build to the run that caused it. This samples the tree of the pid the lane started.
param(
  [Parameter(Mandatory = $true)][int]$Root,
  [int]$IntervalMs = 2000,
  [Parameter(Mandatory = $true)][string]$Out
)
$ErrorActionPreference = 'Stop'
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$writer = [System.IO.StreamWriter]::new($Out, $false)
try {
  while ($true) {
    $snapshot = @{}
    foreach ($process in Get-CimInstance Win32_Process -ErrorAction Stop) {
      $snapshot[[int]$process.ProcessId] = $process
    }
    $tree = New-Object 'System.Collections.Generic.HashSet[int]'
    [void]$tree.Add($Root)
    $grew = $true
    while ($grew) {
      $grew = $false
      foreach ($process in $snapshot.Values) {
        $parent = [int]$process.ParentProcessId
        if ($tree.Contains($parent) -and -not $tree.Contains([int]$process.ProcessId)) {
          [void]$tree.Add([int]$process.ProcessId)
          $grew = $true
        }
      }
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    [double]$cpu = 0
    foreach ($id in $tree) {
      $process = $snapshot[$id]
      if ($null -eq $process) { continue }
      [double]$ticks = [double]$process.UserModeTime + [double]$process.KernelModeTime
      $cpu += $ticks
      $rows.Add([pscustomobject]@{ pid = $id; name = [string]$process.Name; ticks = $ticks })
    }
    $line = [pscustomobject]@{ t_ms = [int]$clock.ElapsedMilliseconds; root = $Root; cpu_ticks = $cpu; tree = $rows }
    $writer.WriteLine(($line | ConvertTo-Json -Compress -Depth 4))
    $writer.Flush()
    Start-Sleep -Milliseconds $IntervalMs
  }
} finally {
  $writer.Close()
}
