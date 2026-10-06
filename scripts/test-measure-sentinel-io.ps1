$ErrorActionPreference='Stop'
$source=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'measure-sentinel-io.ps1')
$tokens=$null;$errors=$null
[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)|Out-Null
if($errors.Count){throw 'measure script syntax invalid'}
$match=[regex]::Match($source,'(?m)^function Idle\(\$h\)\{[^\r\n]*\}\r?$')
if(!$match.Success){throw 'actual idle predicate missing'}
Invoke-Expression $match.Value
function Sample(){[pscustomobject]@{ok=$true;execution_schema=1;run_ids=@();queue=0;subagents=[pscustomobject]@{active=0};operations=@()}}
$checks=1
$h=Sample;if(!(Idle $h)){throw 'idle fixture refused'};$checks++
foreach($field in @('ok','execution_schema','queue')){
 $h=Sample;switch($field){'ok'{$h.ok=$false};'execution_schema'{$h.execution_schema=0};'queue'{$h.queue=1}}
 if(Idle $h){throw "invalid $field admitted"};$checks++
}
$h=Sample;$h.run_ids=@([pscustomobject]@{id=1});if(Idle $h){throw 'active run admitted'};$checks++
$h=Sample;$h.subagents.active=1;if(Idle $h){throw 'active child admitted'};$checks++
$h=Sample;$h.operations=@([pscustomobject]@{id=1});if(Idle $h){throw 'active operation admitted'};$checks++
Write-Output "sentinel idle measure ok ($checks checks, 0 skipped; actual predicate, no live effects)"
