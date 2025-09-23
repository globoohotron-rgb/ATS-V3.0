$ErrorActionPreference = "Stop"

Describe "Dashboard smoke (8.5)" {

  BeforeAll {
    # визначаємо here/root *всередині* Pester-скопу
    $here = @(
      $PSScriptRoot
      ($(if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { $null }))
      ($(if ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $null }))
      ((Get-Location).Path)
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

    $script:root = (Resolve-Path -Path (Join-Path -Path $here -ChildPath '..')).Path
    if (-not (Test-Path (Join-Path $script:root 'dash.ps1'))) {
      # крайній фолбек — читаємо з поточної теки
      $script:root = (Get-Location).Path
    }

    Write-Host "[tests] here=$here; root=$script:root" -ForegroundColor DarkGray

    $script:dash        = Join-Path $script:root 'dash.ps1'
    $script:reportsRoot = Join-Path $script:root 'reports'
  }

  It "dash.ps1 runs successfully" {
    & $script:dash -Scope OOS
    $LASTEXITCODE | Should -Be 0
  }

  It "produces required HTML files" {
    Test-Path $script:reportsRoot | Should -BeTrue
    $dayDir = Get-ChildItem -Path $script:reportsRoot -Directory |
              Where-Object { $_.Name -match "^\d{4}-\d{2}-\d{2}$" } |
              Sort-Object Name -Descending | Select-Object -First 1
    $dayDir | Should -Not -BeNullOrEmpty
    (Test-Path (Join-Path $dayDir.FullName 'dashboard.html'))           | Should -BeTrue
    (Test-Path (Join-Path $script:reportsRoot 'dashboard_latest.html')) | Should -BeTrue
  }

  It "meets DoD: has KPI/equity/verdicts/links + sources" {
    $latest   = Get-ChildItem -Path $script:reportsRoot -Directory |
                Where-Object Name -match '^\d{4}-\d{2}-\d{2}$' |
                Sort-Object Name -Descending | Select-Object -First 1
    $htmlPath = Join-Path $latest.FullName 'dashboard.html'
    $html     = Get-Content -Raw -Path $htmlPath

    $html | Should -Match '<div class="kpi">PnL'
    $html | Should -Match '<div class="kpi">Sharpe'
    $html | Should -Match '<div class="kpi">MaxDD'
    $html | Should -Match '<div class="kpi">Equity'
    $html | Should -Match 'Вердикти ґейтів'
    $html | Should -Match 'Звіти за день'
    $html | Should -Match 'source:'
    $html | Should -Match 'last:'
    $html | Should -Match 'Δ:'
  }

  It "is idempotent (second run OK)" {
    & $script:dash -Scope OOS
    $LASTEXITCODE | Should -Be 0
  }

  It "pipeline hook exists in run.ps1 (8.4)" {
    $runTxt = Get-Content -Raw -Path (Join-Path $script:root 'run.ps1')
    $runTxt | Should -Match '# === ATS Dashboard hook \(8\.4\) ==='
  }
}
