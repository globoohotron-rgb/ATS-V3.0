#requires -Version 7
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$run = ".\run.ps1"
$mod = ".\scripts\ats.psm1"
if (-not (Test-Path $run)) { throw "Не знайдено $run" }
if (-not (Test-Path $mod)) { throw "Не знайдено $mod" }

# backup
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
Copy-Item $run "$run.bak.$stamp" -Force

# читаємо run.ps1 як масив рядків
$lines = Get-Content $run -Encoding UTF8

function IndexOfPattern([string[]]$arr, [string]$regex){
  for ($i=0; $i -lt $arr.Count; $i++){
    if ($arr[$i] -match $regex) { return $i }
  }
  return -1
}

# 1) імпорт модуля ats: якщо нема — вставляємо після блоку param(...) (або на початок, якщо param нема)
$needImport = ($lines -join "`n") -notmatch 'Import-Module\s+\.\\scripts\\ats\.psm1'
if ($needImport) {
  $insertAt = 0
  $pIdx = IndexOfPattern $lines '^\s*param\s*\('
  if ($pIdx -ge 0) {
    $depth = 0
    for ($i=$pIdx; $i -lt $lines.Count; $i++){
      $depth += ([regex]::Matches($lines[$i], '\(').Count) - ([regex]::Matches($lines[$i], '\)').Count)
      if ($depth -le 0) { $insertAt = $i + 1; break }
    }
  }
  $importLine = 'Import-Module .\scripts\ats.psm1 -Force'
  if ($insertAt -le 0) { $lines = ,$importLine + $lines } else {
    $lines = @($lines[0..($insertAt-1)]) + @($importLine) + @($lines[$insertAt..($lines.Count-1)])
  }
}

# 2) знаходимо присвоєння $Metrics =
$metricsIdx = IndexOfPattern $lines '^\s*\$Metrics\s*='
$hook = '$Metrics = Use-TxInsideBacktest -Trades $Trades -Metrics $Metrics'

# якщо хук уже є — виходимо
if ( ($lines -join "`n") -match [regex]::Escape($hook) ) {
  Write-Host "Гачок Tx уже вставлено — нічого не міняю." -ForegroundColor Yellow
} else {
  if ($metricsIdx -lt 0) {
    # fallback: в самий кінець файлу
    $lines += @('', '# TX hook (fallback, $Metrics не знайдено поруч):', $hook)
  } else {
    # рухаємось від рядка з присвоєнням, поки не закінчиться вираз (дужки/фігурні/бектик)
    $i = $metricsIdx
    $brace = 0; $paren = 0; $cont = $false
    do {
      $brace += ([regex]::Matches($lines[$i], '\{').Count) - ([regex]::Matches($lines[$i], '\}').Count)
      $paren += ([regex]::Matches($lines[$i], '\(').Count) - ([regex]::Matches($lines[$i], '\)').Count)
      $cont   = $lines[$i].TrimEnd().EndsWith('`')
      $i++
      if ($i -ge $lines.Count) { break }
    } while ($brace -gt 0 -or $paren -gt 0 -or $cont)
    $insertPos = $i
    $lines = @($lines[0..($insertPos-1)]) + @($hook) + @($lines[$insertPos..($lines.Count-1)])
  }
}

# 3) запис
($lines -join "`r`n") | Set-Content -Encoding UTF8 -Path $run
Write-Host "✅ Tx-хук вставлено (бекап: $run.bak.$stamp)" -ForegroundColor Green
