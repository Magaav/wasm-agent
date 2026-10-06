# Read-only bounded idle samples. Run outside the node through sentinel request run.
param([string]$Install=$env:WA_INSTALL_DIR,[string]$Data,[string]$Receipt,[int]$Port=8799,[int]$IdleWaitSeconds=180,[int]$SampleSeconds=8,[int]$Samples=3)
$ErrorActionPreference='Stop'
if(!$Install){$Install=Join-Path $env:LOCALAPPDATA 'wasm-agent'}
if(!$Data){$Data=Join-Path $(if($env:WASM_AGENT_HOME){$env:WASM_AGENT_HOME}else{$env:USERPROFILE}) '.wasm-agent'}
if(!$Receipt){$Receipt=Join-Path $Data ('sentinel/io-idle-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')+'.json')}
if(Test-Path -LiteralPath $Receipt){throw 'measurement_receipt_exists'}
if($IdleWaitSeconds -lt 1 -or $IdleWaitSeconds -gt 240 -or $SampleSeconds -lt 1 -or $SampleSeconds -gt 15 -or $Samples -lt 1 -or $Samples -gt 3){throw 'measurement_budget_invalid'}
function Health(){Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 5}
function Idle($h){$h.ok -eq $true -and $h.execution_schema -eq 1 -and @($h.run_ids).Count -eq 0 -and $h.queue -eq 0 -and $h.subagents.active -eq 0 -and @($h.operations).Count -eq 0}
$until=[DateTime]::UtcNow.AddSeconds($IdleWaitSeconds)
do { $health=Health; if(Idle $health){break}; if([DateTime]::UtcNow -ge $until){throw 'node_never_idle; no measurement verdict'}; Start-Sleep -Seconds 2 } while($true)
$sentinel=[int](Get-Content -LiteralPath (Join-Path $Data 'sentinel/sentinel.pid'))
$node=[int](Get-Content -LiteralPath (Join-Path $Install 'serve.pid'))
function Snap($Id){$p=Get-CimInstance Win32_Process -Filter "ProcessId=$Id";if(!$p){throw "measurement_pid_missing:$Id"};[ordered]@{pid=$Id;created=$p.CreationDate.ToString('o');name=$p.Name;reads=[decimal]$p.ReadOperationCount;bytes=[decimal]$p.ReadTransferCount;cpu100ns=([decimal]$p.KernelModeTime+[decimal]$p.UserModeTime)}}
$rows=@()
for($sample=1;$sample -le $Samples;$sample++){
 $start=Health;if(!(Idle $start)){throw 'sample_started_busy'}
 $a=@((Snap $sentinel),(Snap $node));$watch=[Diagnostics.Stopwatch]::StartNew()
 Start-Sleep -Seconds $SampleSeconds
 $b=@((Snap $sentinel),(Snap $node));$watch.Stop();$end=Health
 $valid=Idle $end
 $processes=for($i=0;$i -lt 2;$i++){if($a[$i].created -ne $b[$i].created){throw 'measurement_process_generation_changed'};[ordered]@{pid=$a[$i].pid;created=$a[$i].created;name=$a[$i].name;read_ops_per_second=($b[$i].reads-$a[$i].reads)/$watch.Elapsed.TotalSeconds;read_bytes_per_second=($b[$i].bytes-$a[$i].bytes)/$watch.Elapsed.TotalSeconds;cpu_core_percent=(($b[$i].cpu100ns-$a[$i].cpu100ns)/100000)/$watch.Elapsed.TotalSeconds}}
 $rows+=@([ordered]@{sample=$sample;seconds=$watch.Elapsed.TotalSeconds;idle_at_both_boundaries=$valid;processes=@($processes)})
 if(!$valid){break}
}
$result=[ordered]@{schema=1;at=[DateTime]::UtcNow.ToString('o');ok=(@($rows|Where-Object {!$_.idle_at_both_boundaries}).Count -eq 0 -and $rows.Count -eq $Samples);mode='bounded-current-idle';samples=$rows;limits='OS process counters include cached/network I/O. Idle sampled at boundaries, not continuous proof. No matched old idle baseline or fan causation claim. No settings, jobs or process state changed.'}
$json=$result|ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($Receipt,$json)
Write-Output $json
if(!$result.ok){exit 1}
