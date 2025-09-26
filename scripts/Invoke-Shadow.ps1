param(
  [int]$Days = 7,
  [int]$ToleranceMinutes = 15
)
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot 'shadow.psm1') -Force

$result = Invoke-Shadow -Days $Days -ToleranceMinutes $ToleranceMinutes
if ($null -eq $result) {
  Write-Host "[shadow] Nothing to report. Check runs/ structure." -ForegroundColor Yellow
  exit 0
}

$sum = $result.Summary
Write-Host ("[shadow] Fill-rate: {0}% | AvgSlip: {1} bps | P95: {2} bps | TE(proxy): {3} bps" -f `
    $sum.FillRatePct, $sum.AvgSlippageBps, $sum.P95SlippageBps, $sum.TrackingErrorBps) -ForegroundColor Cyan
Write-Host ("[shadow] Report: {0}" -f $result.OutPath) -ForegroundColor Green
