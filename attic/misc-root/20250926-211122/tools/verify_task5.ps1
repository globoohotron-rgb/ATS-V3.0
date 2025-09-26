param(
  [string]$Date = (Get-Date -Format "yyyy-MM-dd"),
  [switch]$FreshRun # якщо вказати, примусово проганяє G3 перед перевіркою
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
function Ensure-Orders([string]$Date, [ref]$mode) {
  $p = Join-Path (Get-Location) ("logs/orders/$Date.csv")
  if (Test-Path $p) { $mode.Value = 'native'; return $p }
  $collector = Join-Path (Get-Location) 'tools/collect_orders.ps1'
  if (Test-Path $collector) { pwsh -NoProfile -File $collector | Out-Host }
  if (Test-Path $p) { $mode.Value = 'collected'; return $p }
  # остання спроба: демо-сід + колектор
  $seed = Join-Path (Get-Location) 'tools/seed_demo_orders.ps1'
  if (Test-Path $seed) { pwsh -NoProfile -File $seed | Out-Host; pwsh -NoProfile -File $collector | Out-Host }
  if (Test-Path $p) { $mode.Value = 'demo'; return $p }
  $mode.Value = 'absent'; return $null
}
function Read-FileOrNull([string]$path){ try { if(Test-Path $path){ Get-Content -Path $path -Raw -Encoding UTF8 } } catch { $null } }

$results = New-Object System.Collections.Generic.List[object]
function Add-Result { param($name,$ok,$info,$tag='')
  $results.Add([pscustomobject]@{ Check=$name; Status=($(if($ok){'PASS'}else{'FAIL'})); Info=$info; Tag=$tag })
}

$today = $Date
$repDir = Join-Path (Get-Location) ("reports/$today")
$runDir = Join-Path (Get-Location) ("runs/$today")
New-Item -ItemType Directory -Path $repDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $runDir 'verification') -Force | Out-Null

Write-Host "▶ Task 5 — інтегрована перевірка ($today)"

# 5.2 — конфіг і ризик-ручки
$cfgPath = Get-ConfigPath
$cfg     = Import-Config $cfgPath
$dayPct  = Get-Val $cfg @('Risk','DayLimitPct')
$ddPct   = Get-Val $cfg @('Risk','MaxDDPct')
$killPct = Get-Val $cfg @('Risk','KillSwitchPct')
$mode    = (Get-Val $cfg @('Executor','Mode') 'unknown')

$okRisk = ($null -ne $dayPct) -and ($null -ne $ddPct) -and ($null -ne $killPct)
Add-Result "5.2 Risk knobs in config" $okRisk ("DayLimit=$dayPct, MaxDD=$ddPct, Kill=$killPct; ExecMode=$mode")

# 5.1 — paper G3 артефакти (+ за потреби запустити)
$runner = Join-Path (Get-Location) 'run.ps1'
$g3Html = Get-ChildItem -Path $repDir -Filter '*G3*.html' -ErrorAction SilentlyContinue | Select-Object -First 1
$runAny = Get-ChildItem -Path $runDir -Directory -Filter 'run-*' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($FreshRun -or -not ($g3Html -and $runAny)) {
  if (Test-Path $runner) { & $runner -Gate G3 | Out-Host }
  $g3Html = Get-ChildItem -Path $repDir -Filter '*G3*.html' -ErrorAction SilentlyContinue | Select-Object -First 1
  $runAny = Get-ChildItem -Path $runDir -Directory -Filter 'run-*' -ErrorAction SilentlyContinue | Select-Object -First 1
}
$okG3 = ($g3Html -ne $null) -and ($runAny -ne $null)
Add-Result "5.1 Paper G3 artifacts" $okG3 ("Report=" + $(if($g3Html){$g3Html.Name}else{'missing'}) + ", Runs=" + $(if($runAny){$runAny.Name}else{'none'}))

# 5.3 — лог ордерів (зібрання/демо за потреби)
$ordMode = '' ; $ordersCsv = Ensure-Orders $today ([ref]$ordMode)
$okOrders = ($ordersCsv -ne $null)
Add-Result "5.3 Orders log" $okOrders ("$ordersCsv") $(if($ordMode -eq 'demo'){'PASS (DEMO)'}else{''})

# 5.4 — soft-stop (рахунок і читання)
$softScript = Join-Path (Get-Location) 'tools/softstop_check.ps1'
$softJson   = Join-Path (Join-Path $runDir 'risk') 'softstop.json'
if (Test-Path $softScript) { pwsh -NoProfile -File $softScript | Out-Host }
$soft = $null
try { if (Test-Path $softJson) { $soft = Get-Content -Path $softJson -Raw | ConvertFrom-Json } } catch {}
$okSoft = ($soft -ne $null)
$softInfo = if($okSoft){ "DayPnL=${($soft.DayPnLPct)}%, MaxDD_seen=${($soft.MaxDDPctSeen)}%, Triggered=$($soft.Triggered) ($($soft.TriggerType))" } else { 'missing softstop.json' }
Add-Result "5.4 Soft-stop artifact" $okSoft $softInfo

# 5.5 — self-tests + HTML
$repTool = Join-Path (Get-Location) 'tools/g3_selftest_report.ps1'
if (Test-Path $repTool) { pwsh -NoProfile -File $repTool | Out-Host }
$g3risk = Join-Path $repDir 'G3_risk.html'
$html   = Read-FileOrNull $g3risk
$passHtml = ($html -ne $null) -and ($html -match 'Self-Tests.*PASS') -and ($html -notmatch 'FAIL')
Add-Result "5.5 G3 self-tests report" $passHtml ($(if($html){(Resolve-Path $g3risk).Path}else{'missing'}))

# Зведення + артефакти
$summary = [pscustomobject]@{
  Date=$today; Results=$results; Config=$cfgPath; Orders=$ordersCsv; SoftStop=$softJson; G3RiskHtml=$g3risk
}
$sumPath = Join-Path (Join-Path $runDir 'verification') 'task5_summary.json'
$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $sumPath -Encoding UTF8

Write-Host ""
Write-Host "──────────── СТАТУС TASK 5 ────────────"
$results | Format-Table -AutoSize | Out-String | Write-Host
$allOk = -not ($results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ("Зведення: {0}" -f $(if($allOk){'PASS'}else{'ATTN: є FAIL'}))
Write-Host ("Артефакт: {0}" -f (Resolve-Path $sumPath).Path)
