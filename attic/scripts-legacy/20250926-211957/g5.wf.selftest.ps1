param()
$root   = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
$wfCfg  = Join-Path $root 'config\g5.wf.psd1'
$getWF  = Join-Path $root 'scripts\Get-G5WF.ps1'

function Need([string]$p){ if(-not (Test-Path $p)){ throw "[selftest] missing: $p" } }
Need $wfCfg; Need $getWF

# Спробуємо обидва профілі
$std = & $getWF -Profile std
$cmp = & $getWF -Profile compact

foreach($o in @($std,$cmp)){
  foreach($k in 'TrainBars','OOSBars','StepBars'){ if([int]$o.$k -le 0){ throw "[selftest] $k invalid: $($o.$k)" } }
  if([int]$o.MinSample.BarsIS  -le 0){ throw "[selftest] MinSample.BarsIS invalid" }
  if([int]$o.MinSample.BarsOOS -le 0){ throw "[selftest] MinSample.BarsOOS invalid" }
}

Write-Host "[selftest] WF config OK → profiles: std, compact"