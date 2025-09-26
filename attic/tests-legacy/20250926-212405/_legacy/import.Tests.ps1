# tests/import.Tests.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path

Describe "Modules import" {
  It "imports scripts/ats.psm1 and exports commands" {
    $mod = Join-Path $RepoRoot "scripts/ats.psm1"
    Test-Path $mod | Should -BeTrue
    Import-Module $mod -Force -ErrorAction Stop -DisableNameChecking
    ((Get-Command -Module ats).Count) | Should -BeGreaterThan 0
  }

  It "imports scripts/qc.psm1 if present" -Skip:(-not (Test-Path (Join-Path $RepoRoot "scripts/qc.psm1"))) {
    $mod = Join-Path $RepoRoot "scripts/qc.psm1"
    Import-Module $mod -Force -ErrorAction Stop -DisableNameChecking
  }
}

Describe "Runner smoke test" {
  It "runs G1 without exiting session and creates artifacts" {
    $env:ATS_NOEXIT = "1"
    $date = Get-Date -Format "yyyy-MM-dd"
    & (Join-Path $RepoRoot "run.ps1") -Gate "G1" -Quiet
    (Test-Path (Join-Path $RepoRoot "runs/$date"))            | Should -BeTrue
    (Test-Path (Join-Path $RepoRoot "reports/$date/G1-hello.html")) | Should -BeTrue
  }
}
