param()
$root    = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
$costCfg = Join-Path $root 'config\g5.costs.psd1'
$benCfg  = Join-Path $root 'config\g5.benchmark.psd1'
$getC    = Join-Path $root 'scripts\Get-G5Costs.ps1'
$getB    = Join-Path $root 'scripts\Get-G5Benchmark.ps1'

function Need([string]$p){ if(-not (Test-Path $p)){ throw "[selftest] missing: $p" } }
Need $costCfg; Need $benCfg; Need $getC; Need $getB

$C1 = & $getC -Profile vanilla
$C2 = & $getC -Profile conservative
foreach($c in @($C1,$C2)){
  foreach($bp in 'SlippageBps','SpreadBps','PnLDiscountBps'){
    if([int]$c.$bp -lt 0 -or [int]$c.$bp -gt 100){ throw "[selftest] costs $bp out of sane range: $($c.$bp)" }
  }
  if([double]$c.CommissionPerTrade -lt 0){ throw "[selftest] CommissionPerTrade negative" }
  if([int]$c.BorrowAnnualBps -lt 0){ throw "[selftest] BorrowAnnualBps negative" }
}

$B1 = & $getB -Profile SPY
$B2 = & $getB -Profile BTC
foreach($b in @($B1,$B2)){
  if([string]::IsNullOrWhiteSpace($b.Symbol)){ throw "[selftest] benchmark Symbol empty" }
  if($b.ReturnMode -notin @('CloseToClose','TotalReturn')){ throw "[selftest] ReturnMode invalid: $($b.ReturnMode)" }
}

Write-Host "[selftest] Costs+Benchmark configs OK → profiles: costs(vanilla,conservative), bench(SPY,BTC)"