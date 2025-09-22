param()
$root = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
$inv  = Join-Path $root 'scripts\Invoke-G5WF.ps1'

# 1) Прогін у demo (коротка історія)
& $inv -WFProfile demo

# 2) Пошук останньої teки wf-*
$today  = Get-Date -Format 'yyyy-MM-dd'
$base   = Join-Path $root ("runs\{0}" -f $today)
$wfLast = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'wf-*' } | Sort-Object Name | Select-Object -Last 1
if(-not $wfLast){ throw "[selftest] wf folder not found in $base" }

$g5dir  = Join-Path $wfLast.FullName 'g5'
$csv    = Join-Path $g5dir 'wf.oos.csv'
$json   = Join-Path $g5dir 'wf.results.json'

if(-not (Test-Path $csv)){ throw "[selftest] wf.oos.csv not found" }
if(-not (Test-Path $json)){ throw "[selftest] wf.results.json not found" }

$rows = Import-Csv $csv
if($rows.Count -lt 1){ throw "[selftest] no OOS windows" }

$sum = ($rows | Measure-Object -Property Best_PnL -Sum).Sum
Write-Host "[selftest] WF OK (demo): windows=$($rows.Count); ΣBest_PnL=$([math]::Round($sum,6))"