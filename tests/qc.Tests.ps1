Describe "Invoke-DataQC (scripts/qc.psm1) [v3]" {
  BeforeAll {
    Import-Module (Join-Path $PSScriptRoot "..\scripts\qc.psm1") -Force -DisableNameChecking
    $fixtures = Join-Path $PSScriptRoot "fixtures"; if(-not (Test-Path $fixtures)){ New-Item -ItemType Directory -Force -Path $fixtures | Out-Null }
    $out = Join-Path (Join-Path $PSScriptRoot "..\reports") "TEST"; if(-not (Test-Path $out)){ New-Item -ItemType Directory -Force -Path $out | Out-Null }
    Set-Variable -Name OutDir -Value $out -Scope Script
  }
  It "passes on clean monotonic OHLCV" {
    $csv = Join-Path $PSScriptRoot "fixtures\clean.csv"
    @(
      "Date,Open,High,Low,Close,Volume",
      "2025-01-01,100,101,99,100.5,1000",
      "2025-01-02,100.5,101.5,100,101,1100",
      "2025-01-03,101,102,100.5,102,1200"
    ) | Set-Content -Path $csv -Encoding UTF8
    $r = Invoke-DataQC -Path $csv -OutDir $Script:OutDir -RequireMonotonic
    ($r.Pass)     | Should Be $true
    (Test-Path $r.Report) | Should Be $true
  }
  It "fails on duplicate dates" {
    $csv = Join-Path $PSScriptRoot "fixtures\dupdate.csv"
    @(
      "Date,Open,High,Low,Close,Volume",
      "2025-01-01,100,101,99,100.5,1000",
      "2025-01-01,100.5,101.5,100,101,1100",
      "2025-01-03,101,102,100.5,102,1200"
    ) | Set-Content -Path $csv -Encoding UTF8
    $r = Invoke-DataQC -Path $csv -OutDir $Script:OutDir -RequireMonotonic
    ($r.Pass)     | Should Be $false
    (Test-Path $r.Report) | Should Be $true
  }
}
