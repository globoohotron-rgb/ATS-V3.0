param(
  [ValidateSet("pass","duplicate_pk","missing_column")]
  [string]$Case = "pass"
)

$ErrorActionPreference = "Stop"
function Ensure-Dir { param([string]$Path)
  if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

# 0) Дані для кейсу
Ensure-Dir "data/raw"
$pricesPath   = "data/raw/prices_demo.csv"
$calendarPath = "data/raw/calendar_demo.csv"

switch ($Case) {
  "pass" {
@"
timestamp,symbol,open,high,low,close,volume
2025-01-01T09:00:00Z,AAA,100,101,99,100.5,10000
2025-01-01T09:01:00Z,AAA,100.5,101.5,100,101,12000
2025-01-01T09:02:00Z,AAA,101,102,100.5,101.7,9000
"@ | Set-Content -Encoding UTF8 $pricesPath
  }
  "duplicate_pk" {
@"
timestamp,symbol,open,high,low,close,volume
2025-01-01T09:00:00Z,AAA,100,101,99,100.5,10000
2025-01-01T09:00:00Z,AAA,100,101,99,100.5,10000
2025-01-01T09:02:00Z,AAA,101,102,100.5,101.7,9000
"@ | Set-Content -Encoding UTF8 $pricesPath
  }
  "missing_column" {
@"
timestamp,open,high,low,close,volume
2025-01-01T09:00:00Z,100,101,99,100.5,10000
2025-01-01T09:01:00Z,100.5,101.5,100,101,12000
2025-01-01T09:02:00Z,101,102,100.5,101.7,9000
"@ | Set-Content -Encoding UTF8 $pricesPath
  }
}

@"
date,is_open
2025-01-01,true
2025-01-02,true
2025-01-03,false
"@ | Set-Content -Encoding UTF8 $calendarPath

Write-Host "Seeded: $pricesPath, $calendarPath (Case=$Case)" -ForegroundColor Cyan

# 1) Запуск QC у дочірньому pwsh
$qc = "scripts/Invoke-DataQC.ps1"
if (-not (Test-Path $qc)) { throw "Not found: $qc" }

& pwsh -NoLogo -NoProfile -NonInteractive -File $qc
$code = $LASTEXITCODE

# 2) Знайти останній HTML-звіт
$report = Get-ChildItem "artifacts/qc" -Filter "*_qc.html" -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1

if ($code -eq 0) { Write-Host "QC PASS (exit $code)" -ForegroundColor Green }
if ($code -ne 0) { Write-Host "QC FAIL (exit $code)" -ForegroundColor Red }

if ($null -ne $report) { Write-Host "Report: $($report.FullName)" -ForegroundColor Cyan }
if ($null -eq $report) { Write-Host "Report: NOT FOUND" -ForegroundColor Yellow }

$global:LASTEXITCODE = $code
