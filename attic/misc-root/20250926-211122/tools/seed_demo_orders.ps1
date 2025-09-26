param([string]$Date = (Get-Date -Format "yyyy-MM-dd"))

function Find-RunDate { param([string]$d)
  $root = Join-Path (Get-Location) 'runs'
  $todayPath = Join-Path $root $d
  if (Test-Path $todayPath) { return $d }
  $cands = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match "^\d{4}-\d{2}-\d{2}$" } |
           Sort-Object Name -Descending
  if ($cands) { return $cands[0].Name }
  return $d
}

$Date = Find-RunDate $Date
$seedRun = Join-Path (Get-Location) ("runs/$Date/run-SEED-demo/messages")
New-Item -ItemType Directory -Path $seedRun -Force | Out-Null

# 1) CSV ордери
$csvPath = Join-Path $seedRun "orders_demo.csv"
@"
ts,symbol,side,qty,price
$($Date)T10:00:01Z,AAPL,BUY,10,182.15
$($Date)T10:05:03Z,AAPL,SELL,-10,182.70
$($Date)T11:12:00Z,TSLA,BUY,5,255.40
"@ | Set-Content -Path $csvPath -Encoding UTF8

# 2) NDJSON (executions)
$ndjsonPath = Join-Path $seedRun "executions_demo.ndjson"
@"
{ "timestamp":"$($Date)T12:00:00Z","symbol":"MSFT","side":"buy","exec_qty":7,"exec_price":330.25 }
{ "timestamp":"$($Date)T12:10:00Z","symbol":"MSFT","side":"sell","exec_qty":-7,"exec_price":331.10 }
"@ | Set-Content -Path $ndjsonPath -Encoding UTF8

# 3) LOG з JSON-рядками (fills)
$logPath = Join-Path $seedRun "fills_demo.log"
@"
INFO preface line
{ "filled_at":"$($Date)T13:00:00Z", "order":{ "symbol":"NVDA", "side":"BUY", "qty":3, "price":450.00 } }
SOME TEXT
{ "event_time":"$($Date)T13:30:00Z", "execution":{ "symbol":"NVDA", "side":"SELL", "qty":-3, "price":451.25 } }
"@ | Set-Content -Path $logPath -Encoding UTF8

Write-Host "✓ Seeded demo files:"
Write-Host "  - $csvPath"
Write-Host "  - $ndjsonPath"
Write-Host "  - $logPath"
