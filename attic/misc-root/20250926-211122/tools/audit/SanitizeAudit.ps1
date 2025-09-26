param(
  [string]$AuditRoot = "reports\\audit",
  [string]$TargetDir # optional: конкретна папка аудиту
)

$ErrorActionPreference = "Stop"

function Get-LatestAuditDir([string]$root) {
  if (-not (Test-Path $root)) { throw "Не знайдено $root" }
  Get-ChildItem -Path $root -Directory |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
}

$dirItem = if ($TargetDir) { Get-Item $TargetDir } else { Get-LatestAuditDir -root $AuditRoot }
$dir = $dirItem.FullName

$src = Join-Path $dir 'index.html'
$dst = Join-Path $dir 'index.clean.html'
if (-not (Test-Path $src)) { throw "Не знайдено $src" }

# Читаємо оригінальний HTML
$html = Get-Content -Path $src -Raw

# 1) Прибираємо рядки таблиць-кандидатів, що стосуються технічних директорій
$removePatterns = @(
  '<tr><td>\.git\\.*?</tr>',
  '<tr><td>tools\\modules\\Pester\\.*?</tr>',
  '<tr><td>tests\\.*?</tr>'
) | ForEach-Object { [regex]::new($_, "IgnoreCase, Singleline") }

foreach ($rx in $removePatterns) {
  $html = $rx.Replace($html, '')
}

# 2) Нормалізуємо EntryPoints (всередині блоку "<div>EntryPoints</div><div>...") 
$entryRx = [regex]::new('(<div>EntryPoints</div><div>)(.*?)(</div>)', 'Singleline, IgnoreCase')
$html = $entryRx.Replace($html, {
  param($m)
  $raw = $m.Groups[2].Value
  $items = $raw -split '\s*,\s*' | Where-Object { $_ -and $_.Trim() -ne '' }

  $normalized =
    $items |
    Where-Object { $_ -notmatch '(?i)\.bak|\.fail|scripts\\_backup\\' } |
    ForEach-Object { $_.Trim() } |
    Sort-Object -Unique -CaseInsensitive

  $joined = [string]::Join(', ', $normalized)
  $m.Groups[1].Value + $joined + $m.Groups[3].Value
})

Set-Content -Path $dst -Value $html -Encoding UTF8
Write-Host "AUDIT CLEAN PASS ⇒ $dst"
