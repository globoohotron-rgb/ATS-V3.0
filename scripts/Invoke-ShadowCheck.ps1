param(
  [int]$Days = 7,
  [int]$ToleranceMinutes = 15,
  [int]$MinFillRatePct = 95
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot 'shadow.psm1') -Force

$result = Invoke-Shadow -Days $Days -ToleranceMinutes $ToleranceMinutes
if ($null -eq $result) {
  Write-Host "[shadow] No data -> skipping flags." -ForegroundColor Yellow
  exit 0
}

$sum = $result.Summary
Write-Host ("[shadow] Fill-rate: {0}% | AvgSlip: {1} bps | P95: {2} bps | TE(proxy): {3} bps" -f `
    $sum.FillRatePct, $sum.AvgSlippageBps, $sum.P95SlippageBps, $sum.TrackingErrorBps) -ForegroundColor Cyan
Write-Host ("[shadow] Report: {0}" -f $result.OutPath) -ForegroundColor Green

$alerts = @()
if ($sum.Misses.Count -gt 0)                 { $alerts += "MissedSignals=$($sum.Misses.Count)" }
if ($sum.AvgSlippageBps -gt $sum.BudgetSlipBps) { $alerts += "AvgSlip=$($sum.AvgSlippageBps)>$($sum.BudgetSlipBps)b" }
if ($sum.TrackingErrorBps -gt $sum.BudgetTEBps) { $alerts += "TE=$($sum.TrackingErrorBps)>$($sum.BudgetTEBps)b" }
if ($sum.FillRatePct -lt $MinFillRatePct)      { $alerts += "FillRate=$($sum.FillRatePct)<$MinFillRatePct" }

$todayDir = Split-Path -Parent $result.OutPath
if ($alerts.Count -gt 0) {
  $flag = Join-Path $todayDir 'shadow.alert.txt'
  ("RED: " + ($alerts -join '; ')) | Set-Content -Path $flag -Encoding UTF8
  Write-Host "[shadow] RED FLAG -> $flag" -ForegroundColor Red
  exit 2
} else {
  $flag = Join-Path $todayDir 'shadow.ok.txt'
  ("OK: Fill={0}% AvgSlip={1}bps TE={2}bps" -f $sum.FillRatePct,$sum.AvgSlippageBps,$sum.TrackingErrorBps) | `
    Set-Content -Path $flag -Encoding UTF8
  Write-Host "[shadow] OK -> $flag" -ForegroundColor Green
  exit 0
}
