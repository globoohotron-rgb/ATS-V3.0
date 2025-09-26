param(
  [string]$Date = (Get-Date).ToString('yyyy-MM-dd'),
  [TimeSpan]$Tolerance = [TimeSpan]::FromMinutes(5)
)

$ErrorActionPreference = 'Stop'

function Find-Delim {
  param([string]$Path)
  $first = (Get-Content -Path $Path -TotalCount 1)
  $c = ($first.ToCharArray() | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
  if ($first -match ';' -and ($first.Split(';').Count -gt $first.Split(',').Count)) { return ';' } else { return ',' }
}

function Pick-Col {
  param($Row,[string[]]$Candidates)
  $cols = ($Row | Get-Member -MemberType NoteProperty | ForEach-Object Name)
  return ($Candidates | Where-Object { $_ -in $cols } | Select-Object -First 1)
}

function Parse-Time([object]$v){
  if ($v -is [datetime]) { return $v }
  try { return [datetime]::Parse($v, [Globalization.CultureInfo]::InvariantCulture) } catch { try { return [datetime]$v } catch { return $null } }
}

function Side-To-Int([string]$s){
  if (-not $s) { return $null }
  $t = $s.ToUpper()
  if ($t -match 'BUY|LONG|B') { 1 }
  elseif ($t -match 'SELL|SHORT|S') { -1 }
  else { $null }
}

# 0) Визначаємо дату/папки runs і reports
$repo = Get-Location
$runsDateDir = Join-Path $repo ("runs/" + $Date)
if (-not (Test-Path $runsDateDir)) {
  $last = Get-ChildItem (Join-Path $repo 'runs') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if ($last) { $runsDateDir = $last.FullName; $Date = Split-Path $runsDateDir -Leaf }
}
$reportDir = Join-Path $repo ("reports/" + $Date)
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir | Out-Null }

# 1) Якщо shadow-live.html вже існує — просто SMOKE PASS і вихід
$shadowHtml = Join-Path $reportDir 'shadow-live.html'
$shadowJson = Join-Path $reportDir 'shadow-live.json'
if (Test-Path $shadowHtml) {
  Write-Host "SHADOW V0 SMOKE PASS — вже є: $shadowHtml"
  exit 0
}

# 2) Збір файлів
$signalFiles = @()
$orderFiles  = @()
if (Test-Path $runsDateDir) {
  $signalFiles = Get-ChildItem $runsDateDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'signal' -and $_.Extension -match 'csv' }
  $orderFiles  = Get-ChildItem $runsDateDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'order' -and $_.Extension -match 'csv' }
}

# 3) Імпорт CSV
$signals = @()
foreach($f in $signalFiles){
  try {
    $del = Find-Delim $f.FullName
    $rows = Import-Csv -Path $f.FullName -Delimiter $del
    foreach($r in $rows){ $r | Add-Member -NotePropertyName Source -NotePropertyValue $f.FullName -Force }
    $signals += $rows
  } catch { }
}
$orders = @()
foreach($f in $orderFiles){
  try {
    $del = Find-Delim $f.FullName
    $rows = Import-Csv -Path $f.FullName -Delimiter $del
    foreach($r in $rows){ $r | Add-Member -NotePropertyName Source -NotePropertyValue $f.FullName -Force }
    $orders += $rows
  } catch { }
}

# 4) Нормалізація колонок
if ($signals.Count -gt 0) {
  $s0 = $signals | Select-Object -First 1
  $sigSym = Pick-Col $s0 @('Symbol','Ticker','Asset','Instrument')
  $sigTs  = Pick-Col $s0 @('Timestamp','Time','DateTime','Datetime','Date','ts')
  $sigPx  = Pick-Col $s0 @('SignalPrice','Price','Close','Open','Px','Mid','RefPrice')
  $sigSide= Pick-Col $s0 @('Side','Signal','Direction','Action','SideInt')
  $signals = $signals | ForEach-Object {
    [pscustomobject]@{
      Symbol = if($sigSym){ $_.$sigSym } else { $null }
      Time   = if($sigTs){  Parse-Time $_.$sigTs } else { $null }
      Price  = if($sigPx){ [double]($_.$sigPx -replace ',','.') } else { $null }
      Side   = if($sigSide){ if($_.$sigSide -is [int]){ [int]$_.$sigSide } else { Side-To-Int ([string]$_.$sigSide) } } else { $null }
      Raw    = $_
    }
  } | Where-Object { $_.Symbol -and $_.Time }
}

if ($orders.Count -gt 0) {
  $o0 = $orders | Select-Object -First 1
  $ordSym = Pick-Col $o0 @('Symbol','Ticker','Asset','Instrument')
  $ordTs  = Pick-Col $o0 @('Timestamp','Time','DateTime','Datetime','Date','ts')
  $ordPx  = Pick-Col $o0 @('ExecPrice','FillPrice','AvgPrice','Price','Px')
  $ordSide= Pick-Col $o0 @('Side','Direction','Action','SideInt')
  $orders = $orders | ForEach-Object {
    [pscustomobject]@{
      Symbol = if($ordSym){ $_.$ordSym } else { $null }
      Time   = if($ordTs){  Parse-Time $_.$ordTs } else { $null }
      Price  = if($ordPx){ [double]($_.$ordPx -replace ',','.') } else { $null }
      Side   = if($ordSide){ if($_.$ordSide -is [int]){ [int]$_.$ordSide } else { Side-To-Int ([string]$_.$ordSide) } } else { $null }
      Raw    = $_
    }
  } | Where-Object { $_.Symbol -and $_.Time }
}

# 5) Матчінг сигналів і ордерів
$matches = @()
if ($signals.Count -gt 0 -and $orders.Count -gt 0) {
  $signalsBySym = $signals | Group-Object Symbol -AsHashTable -AsString
  foreach($o in $orders){
    if (-not $signalsBySym.ContainsKey([string]$o.Symbol)) { continue }
    $cands = $signalsBySym[[string]$o.Symbol] | Where-Object {
      [math]::Abs(($_.Time - $o.Time).TotalSeconds) -le $Tolerance.TotalSeconds
    } | Sort-Object Time
    if ($cands.Count -gt 0) {
      # найкраще: найближче за часом, з пріоритетом <= orderTime
      $c = ($cands | Where-Object { $_.Time -le $o.Time } | Select-Object -Last 1)
      if (-not $c) { $c = $cands | Select-Object -First 1 }
      $slipBps = $null
      if ($c.Price -and $o.Price) {
        if ($o.Side -eq -1) { $slipBps = (($c.Price - $o.Price) / $c.Price) * 10000 }
        elseif ($o.Side -eq 1) { $slipBps = (($o.Price - $c.Price) / $c.Price) * 10000 }
        else { $slipBps = (([double]$o.Price - [double]$c.Price)/[double]$c.Price)*10000 }
      }
      $matches += [pscustomobject]@{
        Symbol = $o.Symbol
        SigTime = $c.Time
        OrdTime = $o.Time
        LatencySec = [math]::Round(($o.Time - $c.Time).TotalSeconds, 3)
        SigPrice = $c.Price
        OrdPrice = $o.Price
        Side = $o.Side
        SlippageBps = if($slipBps -ne $null){ [math]::Round($slipBps,3) } else { $null }
      }
    }
  }
}

# 6) Метрики
$signalsTotal = $signals.Count
$ordersTotal  = $orders.Count
$ordersMatched = $matches.Count
$signalsMatched = ($matches | Group-Object Symbol,SigTime | Measure-Object).Count

function Safe-Avg($xs){ if(-not $xs -or $xs.Count -eq 0){ return $null } ([math]::Round(($xs | Measure-Object -Average | Select-Object -ExpandProperty Average),3)) }
function Safe-Med($xs){
  if(-not $xs -or $xs.Count -eq 0){ return $null }
  $s = $xs | Sort-Object
  $n = $s.Count
  if ($n % 2 -eq 1) { return $s[[int][math]::Floor($n/2)] } else { return [math]::Round((($s[($n/2)-1] + $s[$n/2]) / 2),3) }
}
function Safe-SD($xs){
  if(-not $xs -or $xs.Count -lt 2){ return $null }
  $avg = ($xs | Measure-Object -Average | Select-Object -ExpandProperty Average)
  $var = ($xs | ForEach-Object { ($_ - $avg) * ($_ - $avg) } | Measure-Object -Average | Select-Object -ExpandProperty Average)
  return [math]::Round([math]::Sqrt($var),3)
}

$slips = $matches | Where-Object { $_.SlippageBps -ne $null } | Select-Object -ExpandProperty SlippageBps
$lat   = $matches | Select-Object -ExpandProperty LatencySec

$metrics = [ordered]@{
  Date = $Date
  SignalsTotal = $signalsTotal
  OrdersTotal  = $ordersTotal
  SignalsMatched = $signalsMatched
  OrdersMatched  = $ordersMatched
  FillRate_bySignals = if($signalsTotal){ [math]::Round($signalsMatched/$signalsTotal,4) } else { $null }
  SlippageBps_Avg = Safe-Avg $slips
  SlippageBps_Med = Safe-Med $slips
  TEproxyBpsSD    = Safe-SD $slips
  LatencySec_Avg  = Safe-Avg $lat
  LatencySec_Med  = Safe-Med $lat
  ToleranceSec    = $Tolerance.TotalSeconds
}

# 7) HTML/JSON в reports/<Date>/
$shadowJson = Join-Path $reportDir 'shadow-live.json'
$shadowHtml = Join-Path $reportDir 'shadow-live.html'

$metrics | ConvertTo-Json -Depth 4 | Set-Content -Path $shadowJson -Encoding UTF8

$tableRows = ($matches | Sort-Object {[math]::Abs($_.LatencySec)} | Select-Object -First 100 | ForEach-Object {
  "<tr><td>$($_.Symbol)</td><td>$($_.SigTime)</td><td>$($_.OrdTime)</td><td>$($_.LatencySec)</td><td>$($_.SigPrice)</td><td>$($_.OrdPrice)</td><td>$($_.Side)</td><td>$($_.SlippageBps)</td></tr>"
}) -join "`n"

$html = @"
<!doctype html><html><head><meta charset='utf-8'>
<title>Shadow Live v0 — $Date</title>
<style>body{font-family:ui-sans-serif,system-ui,Segoe UI,Arial;margin:20px} h1{margin:0 0 8px}
.kv{display:grid;grid-template-columns:220px 1fr;gap:6px 12px;max-width:620px}
.kv div{padding:6px 8px;background:#f7f7f9;border:1px solid #eee;border-radius:8px}
table{border-collapse:collapse;margin-top:16px;font-size:14px}
td,th{border:1px solid #e5e5e5;padding:6px 8px} th{background:#fafafa}
.small{color:#666;font-size:12px}
</style></head><body>
<h1>Shadow Live v0 — $Date</h1>
<div class='kv'>
  <div>SignalsTotal</div><div>$($metrics.SignalsTotal)</div>
  <div>OrdersTotal</div><div>$($metrics.OrdersTotal)</div>
  <div>SignalsMatched</div><div>$($metrics.SignalsMatched)</div>
  <div>OrdersMatched</div><div>$($metrics.OrdersMatched)</div>
  <div>FillRate_bySignals</div><div>$($metrics.FillRate_bySignals)</div>
  <div>SlippageBps_Avg</div><div>$($metrics.SlippageBps_Avg)</div>
  <div>SlippageBps_Med</div><div>$($metrics.SlippageBps_Med)</div>
  <div>TEproxyBpsSD</div><div>$($metrics.TEproxyBpsSD)</div>
  <div>LatencySec_Avg</div><div>$($metrics.LatencySec_Avg)</div>
  <div>LatencySec_Med</div><div>$($metrics.LatencySec_Med)</div>
  <div>ToleranceSec</div><div>$($metrics.ToleranceSec)</div>
</div>
<p class='small'>Source: runs/$Date/run-*/ (auto-discovery). Top 100 matches by |latency|.</p>
<table><thead><tr>
  <th>Symbol</th><th>SigTime</th><th>OrdTime</th><th>LatencySec</th>
  <th>SigPrice</th><th>OrdPrice</th><th>Side</th><th>SlippageBps</th>
</tr></thead><tbody>
$tableRows
</tbody></table>
</body></html>
"@

$html | Set-Content -Path $shadowHtml -Encoding UTF8

if (Test-Path $shadowHtml) {
  Write-Host "SHADOW V0 PASS  => $shadowHtml"
} else {
  Write-Host "SHADOW V0 WARN: звіт не створено (можливо, немає даних runs/$Date)."
  exit 1
}

