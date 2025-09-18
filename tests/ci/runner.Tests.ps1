Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
  $script:Runner   = Join-Path $RepoRoot "run.ps1"
}

Describe "Runner smoke" {
  It "runs G1 without killing session and creates artifacts" {
    $env:ATS_NOEXIT = "1"
    $date = Get-Date -Format "yyyy-MM-dd"
    & $Runner -Gate "G1" -Quiet
    (Test-Path (Join-Path $RepoRoot "runs/$date")) | Should -BeTrue
    (Test-Path (Join-Path $RepoRoot "reports/$date/G1-hello.html")) | Should -BeTrue
  }
}
