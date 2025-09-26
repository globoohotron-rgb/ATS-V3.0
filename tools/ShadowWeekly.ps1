param(
  [string]$EndDate = (Get-Date).ToString("yyyy-MM-dd"),
  [int]$Days = 7
)

$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path

function Get-IsoWeekInfo([datetime]$dt){
  $cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
  $rule = [System.Globalization.CalendarWeekRule]::FirstFourDayWeek
  $firstDay = [System.DayOfWeek]::Monday
  $week = $cal.GetWeekOfYear($dt, $rule, $firstDay)
  $year = $dt.Year
  if ($week -ge 52 -and $dt.Month -eq 1){ $year-- }
  if ($week -eq 1 -and $dt.Month -eq 12){ $year++ }
  [pscustomobject]@{ Year=$year; Week=$week; Label=("{0}-W{1:D2}" -f $year,$week) }
}

function Safe-Avg($xs){ if(-not $xs -or $xs.Count -eq 0){ return $null } [math]::Round(($xs | Measure-Object -Average | Select-Object -ExpandProperty Average),4) }
function Safe-Med($xs){
  if(-not $xs -or $xs.Count -eq 0){ return $null }
  $s = $xs | Sort-Object
  $n = $s.Count
  if ($n % 2 -eq 1) { return $s[[int][math]::Floor($n/2)] } else { return [math]::Round((($s[($n/2)-1] + $s[$n/2]) / 2),4) }
}

# HTML-escape, що працює всюди (PS7+)
function Esc([string]$s){
  if ([string]::IsNullOrEmpty($s)) { return '' }
  try { return [System.Security.SecurityElement]::Escape($s) }
  catch { return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;') }
}

# Пороги з конфіга
$cfg = $null
try {
  $cfgFile = Join-Path $root 'config/metrics.psd1'
  if (Test-Path $cfgFile) { $cfg = Import-PowerShellDataFile -Path $cfgFile }
} catch {}

$minFill    = if ($cfg -and $cfg.ContainsKey('MinFillRate'))       { [double]$cfg.MinFillRate }       else { 0.8 }
$slipBudget = if ($cfg -and $cfg.ContainsKey('SlippageBudgetBps')) { [double]$cfg.SlippageBudgetBps } else { 1e9 }
$teBudget   = if ($cfg -and $cfg.ContainsKey('TEBudgetBpsSD'))     { [double]$cfg.TEBudgetBpsSD }     else { 1e9 }

# Діапазон дат
$end = [datetime]::Parse($EndDate)
$start = $end.AddDays(-[math]::Max(0,$Days-1))
$dates = for($d=$start; $d -le $end; $d=$d.AddDays(1)){ $d.ToString('yyyy-MM-dd') }

$rows = @()
$fillList = @()
$slipMedList = @()
$teSdList = @()
$flagCounts = @{}

foreach($d in $dates){
  $repDir = Join-Path $root ("reports/" + $d)
  $json = Join-Path $repDir 'shadow-live.json'
  $html = Join-Path $repDir 'shadow-live.html'
  $flagFile = Join-Path $repDir 'shadow-live.flag.txt'

  $metrics = $null
  if (Test-Path $json){
    try { $metrics = Get-Content $json -Raw | ConvertFrom-Json } catch {}
  }

  $flag = if (Test-Path $flagFile) {
    (Get-Content $flagFile -Raw).Trim()
  } elseif ($metrics){
    $fill = if ($metrics.FillRate_bySignals -ne $null){ [double]$metrics.FillRate_bySignals } else { $null }
    $slipMed = if ($metrics.SlippageBps_Med -ne $null){ [double]$metrics.SlippageBps_Med } else { $null }
    $teSd = if ($metrics.TEproxyBpsSD -ne $null){ [double]$metrics.TEproxyBpsSD } else { $null }

    if ($metrics.SignalsTotal -eq 0) { 'RED: NO_SIGNALS' }
    elseif ($fill -ne $null -and $fill -lt $minFill) { "RED: LOW_FILL_RATE ($fill < $minFill)" }
    elseif ($slipMed -ne $null -and [math]::Abs($slipMed) -gt $slipBudget) { "RED: SLIPPAGE_BUDGET_EXCEEDED (|$slipMed| > $slipBudget)" }
    elseif ($teSd -ne $null -and $teSd -gt $teBudget) { "RED: TE_BUDGET_EXCEEDED ($teSd > $teBudget)" }
    else { 'GREEN' }
  } else {
    'GRAY: NO_REPORT'
  }

  if ($metrics){
    if ($metrics.FillRate_bySignals -ne $null){ $fillList += [double]$metrics.FillRate_bySignals }
    if ($metrics.SlippageBps_Med -ne $null){ $slipMedList += [double]$metrics.SlippageBps_Med }
    if ($metrics.TEproxyBpsSD -ne $null){ $teSdList += [double]$metrics.TEproxyBpsSD }
  }

  $t = ($flag -split ':')[0].Trim()
  if (-not $flagCounts.ContainsKey($t)) { $flagCounts[$t] = 0 }
  $flagCounts[$t]++

  $rows += [pscustomobject]@{
    Date = $d
    Signals    = if($metrics){ $metrics.SignalsTotal } else { $null }
    Orders     = if($metrics){ $metrics.OrdersTotal } else { $null }
    FillRate   = if($metrics){ $metrics.FillRate_bySignals } else { $null }
    SlipMedBps = if($metrics){ $metrics.SlippageBps_Med } else { $null }
    TESDBps    = if($metrics){ $metrics.TEproxyBpsSD } else { $null }
    Flag       = $flag
    Report     = if(Test-Path $html){ $html } else { $null }
  }
}

$summary = [ordered]@{
  StartDate = $start.ToString('yyyy-MM-dd')
  EndDate   = $end.ToString('yyyy-MM-dd')
  DaysTotal = $dates.Count
  DaysWithReport = ($rows | Where-Object { $_.Signals -ne $null -or $_.Orders -ne $null }).Count
  Flags = $flagCounts
  AvgFillRate = Safe-Avg $fillList
  MedSlippageBps = Safe-Med $slipMedList
  AvgTESDBps = Safe-Avg $teSdList
}

$iso = Get-IsoWeekInfo $end
$weeklyDir = Join-Path $root ("reports/weekly/" + $iso.Label)
if (-not (Test-Path $weeklyDir)) { New-Item -ItemType Directory -Path $weeklyDir -Force | Out-Null }

$weeklyJson = Join-Path $weeklyDir 'index.json'
[pscustomobject]@{ Summary=$summary; Days=$rows } | ConvertTo-Json -Depth 6 | Set-Content -Path $weeklyJson -Encoding UTF8

# Таблиця днів (З ДУЖКАМИ перед -join)
$rowsHtml = ( $rows | Sort-Object Date | ForEach-Object {
  $flag = $_.Flag
  $cls = if($flag -like 'GREEN*'){ 'green' } elseif($flag -like 'RED*'){ 'red' } else { 'gray' }
  $link = if($_.Report){
    $rel = $_.Report.Substring($root.Length+1).Replace('\','/')
    "<a href='../../$rel' target='_blank'>HTML</a>"
  } else { '' }
  "<tr class='$cls'><td>$($_.Date)</td><td>$($_.Signals)</td><td>$($_.Orders)</td><td>$($_.FillRate)</td><td>$($_.SlipMedBps)</td><td>$($_.TESDBps)</td><td>$(Esc($flag))</td><td>$link</td></tr>"
} ) -join "`n"

$flagsSummary = ( $flagCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { "<div><b>$($_.Name)</b>: $($_.Value)</div>" } ) -join "`n"

$html = @"
<!doctype html><html><head><meta charset='utf-8'>
<title>Shadow Weekly — $($iso.Label) [$($summary.StartDate) → $($summary.EndDate)]</title>
<style>
body{font-family:ui-sans-serif,system-ui,Segoe UI,Arial;margin:20px}
h1{margin:0 0 8px}
.grid{display:grid;grid-template-columns:240px 1fr;gap:6px 12px;max-width:720px}
.grid div{padding:6px 8px;background:#f7f7f9;border:1px solid #eee;border-radius:8px}
table{border-collapse:collapse;margin-top:16px;font-size:14px}
td,th{border:1px solid #e5e5e5;padding:6px 8px} th{background:#fafafa}
tr.green td{background:#f2fff2}
tr.red td{background:#fff2f2}
tr.gray td{background:#f6f6f6;color:#666}
.small{color:#666;font-size:12px}
</style></head><body>
<h1>Shadow Weekly — $($iso.Label)</h1>
<div class='grid'>
  <div>Range</div><div>$($summary.StartDate) → $($summary.EndDate)</div>
  <div>Days (reported/total)</div><div>$($summary.DaysWithReport)/$($summary.DaysTotal)</div>
  <div>Avg FillRate</div><div>$($summary.AvgFillRate)</div>
  <div>Med Slippage (bps)</div><div>$($summary.MedSlippageBps)</div>
  <div>Avg TE SD (bps)</div><div>$($summary.AvgTESDBps)</div>
  <div>Flags</div><div>$flagsSummary</div>
</div>
<table>
<thead><tr><th>Date</th><th>Signals</th><th>Orders</th><th>FillRate</th><th>SlipMed bps</th><th>TE SD bps</th><th>Flag</th><th>Report</th></tr></thead>
<tbody>
$rowsHtml
</tbody></table>
<p class='small'>Source: reports/YYYY-MM-DD/shadow-live.json, thresholds from config/metrics.psd1.</p>
</body></html>
"@

$weeklyHtml = Join-Path $weeklyDir 'index.html'
$html | Set-Content -Path $weeklyHtml -Encoding UTF8

if (Test-Path $weeklyHtml) {
  Write-Host "WEEKLY PASS => $weeklyHtml"
} else {
  Write-Host "WEEKLY WARN: не вдалося згенерувати weekly HTML."
  exit 1
}
