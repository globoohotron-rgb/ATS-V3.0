param(
  [string]$Date = (Get-Date -Format "yyyy-MM-dd"),
  [switch]$ForceDemoTrigger # опціонально штучно опустить ліміти для демонстрації
)

function Get-ConfigPath {
  foreach ($rel in @('config/config.psd1','scripts/config.psd1')) {
    $p = Join-Path (Get-Location) $rel
    if (Test-Path $p) { return $p }
  }
  throw "Не знайдено config.psd1 у config/ або scripts/."
}

function Import-Config([string]$Path) { Import-PowerShellDataFile -Path $Path }

function Get-Val($h, [string[]]$path, $def=$null) {
  $cur = $h
  foreach ($k in $path) {
    if ($cur -is [hashtable] -and $cur.ContainsKey($k)) { $cur = $cur[$k] } else { return $def }
  }
  return $cur
}

function Ensure-Orders([string]$Date) {
  $p = Join-Path (Get-Location) ("logs/orders/$Date.csv")
  if (Test-Path $p) { return $p }
  $collector = Join-Path (Get-Location) 'tools/collect_orders.ps1'
  if (-not (Test-Path $collector)) { throw "Не знайдено tools/collect_orders.ps1 (крок 5.3)" }
  Write-Host ("   • Не знайдено orders логів за {0} — запускаю колектор..." -f $Date)
  pwsh -NoProfile -File $collector | Out-Host
  if (Test-Path $p) { return $p }
  throw "Після collect_orders лог за $Date все ще не знайдено."
}

function Parse-Timestamp($s){
  try { [datetime]::Parse($s, $null, [System.Globalization.DateTimeStyles]::AssumeUniversal) }
  catch { Get-Date } # fallback
}

# Реалізація FIFO-матчингу для розрахунку реалізованого PnL
function Add-Trade {
  param(
    [string]$side, [double]$qty, [double]$price,
    [ref]$lots,   # List of hashtable @{Qty=<signed>, Price=<double>}
    [ref]$realized
  )
  $sign = $(if ($side -match '^(?i)buy$') { +1 } else { -1 })
  $q = $sign * [double]$qty
  if ($q -eq 0) { return }

  if ($lots.Value.Count -eq 0 -or [Math]::Sign($q) -eq [Math]::Sign($lots.Value[0].Qty)) {
    $lots.Value.Add(@{Qty=$q; Price=$price})
    return
  }

  $remaining = [math]::Abs($q); $incomingSign = [Math]::Sign($q)
  while ($remaining -gt 0 -and $lots.Value.Count -gt 0 -and [Math]::Sign($lots.Value[0].Qty) -ne $incomingSign) {
    $lot = $lots.Value[0]
    $lotAbs = [math]::Abs($lot.Qty)
    $match = [math]::Min($remaining, $lotAbs)
    $lotSign = [Math]::Sign($lot.Qty)
    # універсальна формула: (P_in - P_lot) * lotSign * matchedQty
    $realized.Value += ($price - $lot.Price) * $lotSign * $match
    if ($match -eq $lotAbs) { $lots.Value.RemoveAt(0) } else { $lots.Value[0].Qty = $lot.Qty + ($lotSign * -$match) }
    $remaining -= $match
  }
  if ($remaining -gt 0) { $lots.Value.Insert(0, @{Qty=$incomingSign*$remaining; Price=$price}) }
}

Write-Host "▶ Soft-Stop чекер 5.4 — старт"

$cfgPath = Get-ConfigPath
$cfg     = Import-Config $cfgPath
$dayPct  = Get-Val $cfg @('Risk','DayLimitPct') -2
$ddPct   = Get-Val $cfg @('Risk','MaxDDPct') 5
$eq0     = Get-Val $cfg @('Account','StartingEquity') 100000

if ($ForceDemoTrigger) { $dayPct = -0.1; $ddPct = 0.2 } # для демонстрації на маленьких логах

Write-Host ("   ✓ Конфіг: {0}  DayLimit={1}%, MaxDD={2}%  StartingEquity={3}" -f $cfgPath, $dayPct, $ddPct, $eq0)

$ordersCsv = Ensure-Orders $Date
$orders = Import-Csv $ordersCsv
if (-not $orders -or $orders.Count -eq 0) { throw "Лог ордерів порожній: $ordersCsv" }

# Сортуємо події
$orders = $orders | Sort-Object { Parse-Timestamp $_.ts }

# Пер-символьний облік
$books = @{} # symbol -> @{ lots=List, realized=ref double }
function Get-Book([string]$sym){
  if (-not $books.ContainsKey($sym)) {
    $books[$sym] = @{ lots = (New-Object System.Collections.Generic.List[object]); realized = ([ref]([double]0)) }
  }
  return $books[$sym]
}

$timeline = New-Object System.Collections.Generic.List[pscustomobject]
$cum = 0.0; $peak = 0.0; $maxDDSeen = 0.0
$triggered = $false; $trigType = 'None'; $trigTime = $null; $trigRow = $null

foreach ($r in $orders) {
  $sym   = [string]$r.symbol
  $side  = ([string]$r.side).ToUpper()
  $qty   = [double]$r.qty
  $price = [double]$r.price
  $ts    = Parse-Timestamp $r.ts

  $book = Get-Book $sym
  Add-Trade -side $side -qty $qty -price $price -lots ([ref]$book.lots) -realized $book.realized

  # Cum realized по всіх символах
  $cum = 0.0
  foreach ($k in $books.Keys) { $cum += $books[$k].realized.Value }

  # MaxDD по realized-equity
  if ($cum -gt $peak) { $peak = $cum }
  $dd = ($peak - $cum)
  $ddPctSeen = ($dd / $eq0) * 100.0
  if ($ddPctSeen -gt $maxDDSeen) { $maxDDSeen = $ddPctSeen }

  $pnlPct = ($cum / $eq0) * 100.0
  $timeline.Add([pscustomobject]@{ ts=$ts; cum=$cum; pnlPct=$pnlPct; ddPct=$ddPctSeen })

  if (-not $triggered) {
    if ($pnlPct -le $dayPct) { $triggered=$true; $trigType='DayLimit'; $trigTime=$ts; $trigRow=$r }
    elseif ($ddPct -le $ddPctSeen) { $triggered=$true; $trigType='MaxDD'; $trigTime=$ts; $trigRow=$r }
  }
}

# Вивод та артефакти
$riskDir = Join-Path (Get-Location) ("runs/$Date/risk")
New-Item -ItemType Directory -Path $riskDir -Force | Out-Null

$curveCsv = Join-Path $riskDir "equity_curve.csv"
$timeline | Export-Csv -Path $curveCsv -NoTypeInformation -Encoding UTF8

$summary = [pscustomobject]@{
  Date            = $Date
  StartingEquity  = $eq0
  DayLimitPct     = $dayPct
  MaxDDPct        = $ddPct
  DayPnLPct       = [math]::Round((($timeline[-1].cum / $eq0) * 100.0), 4)
  MaxDDPctSeen    = [math]::Round($maxDDSeen, 4)
  Triggered       = $triggered
  TriggerType     = $trigType
  TriggerTime     = if ($trigTime) { $trigTime.ToString("yyyy-MM-ddTHH:mm:ssK") } else { $null }
  TriggerOrder    = if ($trigRow) { @{ ts=$trigRow.ts; symbol=$trigRow.symbol; side=$trigRow.side; qty=$trigRow.qty; price=$trigRow.price } } else { $null }
  OrdersLog       = (Resolve-Path $ordersCsv).Path
  CurveCsv        = (Resolve-Path $curveCsv).Path
}
$summaryJson = $summary | ConvertTo-Json -Depth 6
$summaryPath = Join-Path $riskDir "softstop.json"
$summaryJson | Set-Content -Path $summaryPath -Encoding UTF8

Write-Host ""
Write-Host "▶ Підсумок 5.4:"
Write-Host ("   DayPnL = {0}% ; MaxDD_seen = {1}%" -f $summary.DayPnLPct, $summary.MaxDDPctSeen)
if ($triggered) {
  Write-Warning ("   SOFT-STOP TRIGGERED → {0} @ {1}" -f $trigType, $summary.TriggerTime)
  Write-Host ("   Деталі ордера-тригера: {0} {1} {2} @ {3}" -f $summary.TriggerOrder.symbol, $summary.TriggerOrder.side, $summary.TriggerOrder.qty, $summary.TriggerOrder.price)
  Write-Host ("   Артефакт: {0}" -f $summaryPath)
} else {
  Write-Host "   Ліміти не порушені. Артефакти збережено."
  Write-Host ("   Артефакт: {0}" -f $summaryPath)
}
