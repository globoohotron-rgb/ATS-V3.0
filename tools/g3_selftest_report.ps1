param([string]$Date = (Get-Date -Format "yyyy-MM-dd"))

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
  if (Test-Path $collector) {
    Write-Host ("   • Не знайдено orders логів за {0} — запускаю колектор..." -f $Date)
    pwsh -NoProfile -File $collector | Out-Host
  }
  if (Test-Path $p) { return $p }
  return $null
}

Write-Host "▶ G3 self-tests 5.5 — старт"

# A) Конфіг та ризик-ручки
$cfgPath = Get-ConfigPath
$cfg     = Import-Config $cfgPath
$dayPct  = Get-Val $cfg @('Risk','DayLimitPct')
$ddPct   = Get-Val $cfg @('Risk','MaxDDPct')
$eq0     = Get-Val $cfg @('Account','StartingEquity') 100000

$checks = @()
$checks += [pscustomobject]@{ Name='Config exists';      Ok = (Test-Path $cfgPath);     Info=$cfgPath }
$checks += [pscustomobject]@{ Name='Risk.DayLimitPct';   Ok = ($null -ne $dayPct);      Info=$dayPct }
$checks += [pscustomobject]@{ Name='Risk.MaxDDPct';      Ok = ($null -ne $ddPct);       Info=$ddPct }
$checks += [pscustomobject]@{ Name='Account.Equity0';    Ok = ($null -ne $eq0);         Info=$eq0 }

# B) Логи ордерів (із 5.3)
$ordersPath = Ensure-Orders $Date
$ordersOk   = ($ordersPath -ne $null)
$checks += [pscustomobject]@{ Name='Orders log (logs/orders/<date>.csv)'; Ok = $ordersOk; Info = $ordersPath }

# C) SoftStop (із 5.4): якщо нема — пробуємо порахувати зараз
$riskDir = Join-Path (Get-Location) ("runs/$Date/risk")
$softPath = Join-Path $riskDir 'softstop.json'
if (-not (Test-Path $softPath)) {
  $ss = Join-Path (Get-Location) 'tools/softstop_check.ps1'
  if (Test-Path $ss -and $ordersOk) { Write-Host "   • Нема softstop.json — раджу порахувати."; pwsh -NoProfile -File $ss | Out-Host }
}
$softOk = Test-Path $softPath
$checks += [pscustomobject]@{ Name='SoftStop artifact (softstop.json)'; Ok = $softOk; Info = if($softOk){$softPath}else{'missing'} }

# D) Збір даних для репорту
$soft = $null
if ($softOk) {
  try { $soft = Get-Content -Path $softPath -Raw | ConvertFrom-Json } catch {}
}

$dayPnL = if ($soft) { [double]$soft.DayPnLPct } else { $null }
$ddSeen = if ($soft) { [double]$soft.MaxDDPctSeen } else { $null }
$trig   = if ($soft) { [bool]$soft.Triggered } else { $false }
$trType = if ($soft) { [string]$soft.TriggerType } else { '' }
$trTime = if ($soft) { [string]$soft.TriggerTime } else { '' }

# E) Вирок self-tests
$pass = -not ($checks | Where-Object { -not $_.Ok })
$status = if ($pass) { if ($trig) { 'PASS (ATTN: TRIGGERED)' } else { 'PASS' } } else { 'FAIL' }

# F) HTML-репорт
$repDir = Join-Path (Get-Location) ("reports/$Date")
New-Item -ItemType Directory -Path $repDir -Force | Out-Null
$repPath = Join-Path $repDir "G3_risk.html"

$rows = ($checks | ForEach-Object {
  "<tr><td style='padding:4px;border:1px solid #ccc;'>$($_.Name)</td><td style='padding:4px;border:1px solid #ccc;'>$($_.Ok)</td><td style='padding:4px;border:1px solid #ccc;'>$($_.Info)</td></tr>"
}) -join "`n"

$extra = @"
<h3>Risk summary</h3>
<table style='border-collapse:collapse;'>
<tr><td style='padding:4px;border:1px solid #ccc;'>DayPnL%</td><td style='padding:4px;border:1px solid #ccc;'>$dayPnL</td></tr>
<tr><td style='padding:4px;border:1px solid #ccc;'>MaxDD_seen%</td><td style='padding:4px;border:1px solid #ccc;'>$ddSeen</td></tr>
<tr><td style='padding:4px;border:1px solid #ccc;'>DayLimit%</td><td style='padding:4px;border:1px solid #ccc;'>$dayPct</td></tr>
<tr><td style='padding:4px;border:1px solid #ccc;'>MaxDD limit%</td><td style='padding:4px;border:1px solid #ccc;'>$ddPct</td></tr>
<tr><td style='padding:4px;border:1px solid #ccc;'>Triggered</td><td style='padding:4px;border:1px solid #ccc;'>$trig ($trType @ $trTime)</td></tr>
</table>
"@

@"
<!doctype html>
<html><head><meta charset="utf-8"><title>G3 Self-Tests ($Date) — $status</title></head>
<body style="font-family:ui-sans-serif,system-ui; padding:16px;">
<h2>G3 Self-Tests ($Date) — <span>$status</span></h2>
<h3>Checks</h3>
<table style='border-collapse:collapse;'>$rows</table>
$extra
<p><b>Artifacts:</b></p>
<ul>
  <li>Config: $cfgPath</li>
  <li>Orders: $ordersPath</li>
  <li>SoftStop: $softPath</li>
</ul>
</body></html>
"@ | Set-Content -Path $repPath -Encoding UTF8

Write-Host ""
Write-Host "▶ Підсумок 5.5:"
Write-Host ("   Self-tests: {0}" -f $status)
Write-Host ("   Report: {0}" -f (Resolve-Path $repPath).Path)
