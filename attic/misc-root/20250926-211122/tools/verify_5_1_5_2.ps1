param()

function Get-ConfigPath {
  $candidates = @('config/config.psd1','scripts/config.psd1','config/config.ps1','scripts/config.ps1')
  foreach ($rel in $candidates) {
    $p = Join-Path -Path (Get-Location) -ChildPath $rel
    if (Test-Path $p) { return $p }
  }
  return $null
}

function Import-Config {
  param([string]$Path)
  if (-not $Path) { throw "Config file not found (looked in config/ and scripts/)." }
  if ($Path -like '*.psd1') { return Import-PowerShellDataFile -Path $Path }
  if ($Path -like '*.ps1')  { . $Path; return $Config } # допускаємо $Config у .ps1
  throw "Unsupported config file: $Path"
}

function Get-NestedValue {
  param([hashtable]$H, [string[]]$Path)
  $cur = $H
  foreach ($k in $Path) {
    if ($cur -is [hashtable] -and $cur.ContainsKey($k)) { $cur = $cur[$k] } else { return $null }
  }
  return $cur
}

Write-Host "▶ Step A: читаю конфіг і перевіряю ризик-ручки..."
$cfgPath = Get-ConfigPath
$cfg     = Import-Config -Path $cfgPath
Write-Host "   ✓ Config: $cfgPath"

$want = @(
  @('Risk','DayLimitPct'),
  @('Risk','MaxDDPct'),
  @('Risk','KillSwitchPct')
)
$have = @()
foreach ($p in $want) {
  $v = Get-NestedValue -H $cfg -Path $p
  if ($null -ne $v) { $have += ($p -join '.') }
}
if ($have.Count -lt 2) {
  Write-Warning "У конфізі бракує стандартних ризик-ручок (має бути щонайменше 2 з 3: Risk.DayLimitPct, Risk.MaxDDPct, Risk.KillSwitchPct)."
} else {
  Write-Host "   ✓ Ризик-ручки знайдені: $($have -join ', ')"
}

# Спроба визначити paper-режим із конфігу (не критично, бо G3 задає його раннером)
$paperOk = $false
foreach ($cand in @(
    @('Executor','Mode'),
    @('Exec','Mode'),
    @('Paper','Enabled')
)) {
  $v = Get-NestedValue -H $cfg -Path $cand
  if ($null -ne $v) {
    if (($v -is [string] -and $v -match '(paper|dry|sim)') -or ($v -is [bool] -and $v)) { $paperOk = $true }
  }
}
if ($paperOk) { Write-Host "   ✓ У конфізі видно paper-режим (або його еквівалент)." }
else { Write-Host "   • Paper-режим не підтверджено через конфіг — ок, перевіримо фактом запуску G3." }

Write-Host "`n▶ Step B: запускаю G3 (paper run)..."
$runner = Join-Path (Get-Location) 'run.ps1'
if (-not (Test-Path $runner)) { throw "Не знайдено run.ps1 у корені репо." }
& $runner -Gate G3

Write-Host "`n▶ Step C: перевіряю артефакти ранy..."
$today   = Get-Date -Format 'yyyy-MM-dd'
$runRoot = Join-Path (Get-Location) ("runs/$today")
$runDir  = (Get-ChildItem $runRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
if (-not $runDir) {
  Write-Warning "Не знайшла сьогоднішній run-* у runs/$today — глянь, чи G3 справді відпрацював без помилок."
} else {
  Write-Host "   ✓ Останній ран: $($runDir.Name)"
  $orders = Get-ChildItem -Path $runDir.FullName -Recurse -Include '*order*.csv','*orders*.csv' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($orders) {
    Write-Host "   ✓ Знайдено CSV ордерів: $($orders.FullName)"
    try {
      $csv = Import-Csv $orders.FullName
      $cols = $csv | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
      $need = @('ts','symbol','side','qty','price')
      $missing = $need | Where-Object { $_ -notin $cols }
      if ($missing) { Write-Warning "CSV ордерів не має стандартних колонок: $($missing -join ', ')" }
      else { Write-Host "   ✓ CSV ордерів має базові колонки: $($need -join ', ')" }
      Write-Host "   ─ Перші рядки:"
      $csv | Select-Object -First 5 | Format-Table | Out-String | Write-Host
    } catch {
      Write-Warning "Не вдалось прочитати CSV ордерів: $($_.Exception.Message)"
    }
  } else {
    Write-Warning "CSV ордерів у сьогоднішньому ранi не знайдено (це ок, якщо G3 сьогодні без трейдів)."
  }
  $repDir  = Join-Path (Get-Location) ("reports/$today")
  $g3Html  = Get-ChildItem $repDir -Filter '*G3*.html' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($g3Html) { Write-Host "   ✓ HTML-звіт G3: $($g3Html.Name)" }
  else { Write-Warning "HTML-звіт G3 у reports/$today не знайдено. Перевір логи run-*/messages/." }
}

Write-Host "`nГотово. Якщо були WARNING — надішли мені вивід нижче, ми полікуємо." 
