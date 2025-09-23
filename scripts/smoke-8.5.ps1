param([switch]$Open)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Resolve-Path (Join-Path $here "..")
$dash = Join-Path $root "dash.ps1"
& $dash -Scope OOS | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "dash.ps1 exit $LASTEXITCODE"; exit 1 }

$reports = Join-Path $root "reports"
$dayDir = Get-ChildItem -Path $reports -Directory | ? Name -match '^\d{4}-\d{2}-\d{2}$' | Sort-Object Name -Descending | Select -First 1
if (-not $dayDir) { Write-Error "no reports date folder"; exit 1 }
$todayHtml  = Join-Path $dayDir.FullName "dashboard.html"
$latestHtml = Join-Path $reports        "dashboard_latest.html"
if (-not (Test-Path $todayHtml) -or -not (Test-Path $latestHtml)) { Write-Error "dashboard html missing"; exit 1 }
$html = Get-Content -Raw $todayHtml

$checks = @(
  @{Name='PnL';     Pattern='<div class="kpi">PnL'            },
  @{Name='Sharpe';  Pattern='<div class="kpi">Sharpe'         },
  @{Name='MaxDD';   Pattern='<div class="kpi">MaxDD'          },
  @{Name='Equity';  Pattern='<div class="kpi">Equity'         },
  @{Name='Verdicts';Pattern='Вердикти ґейтів'                 },
  @{Name='Links';   Pattern='Звіти за день'                   },
  @{Name='Source';  Pattern='source:'                         },
  @{Name='Last';    Pattern='last:'                           },
  @{Name='Delta';   Pattern='Δ:'                              }
)

$fail = @()
foreach ($c in $checks) { if ($html -notmatch $c.Pattern) { $fail += $c.Name } }

if ($fail.Count -gt 0) {
  Write-Host "❌ Smoke FAIL. Missing: $($fail -join ', ')" -ForegroundColor Red
  exit 2
} else {
  Write-Host "✅ Smoke PASS: dashboard covers DoD blocks (KPI, equity, verdicts, links, sources)" -ForegroundColor Green
  if ($Open) { try { Start-Process $todayHtml } catch {} }
  exit 0
}
