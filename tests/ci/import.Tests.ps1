Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

BeforeAll {
  $script:RepoRoot  = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
  $script:AtsModule = Join-Path $RepoRoot "scripts/ats.psm1"
  $script:QcModule  = Join-Path $RepoRoot "scripts/qc.psm1"
}

Describe "Modules import" {

  It "ats module exists" {
    Test-Path $AtsModule | Should -BeTrue
  }

  It "ats module imports and exports" {
    Import-Module $AtsModule -Force -ErrorAction Stop -DisableNameChecking
    ((Get-Command -Module ats).Count) | Should -BeGreaterThan 0
  }

  It "qc module imports if present (else skip)" {
    if (Test-Path $QcModule) {
      Import-Module $QcModule -Force -ErrorAction Stop -DisableNameChecking
    } else {
      Set-ItResult -Skipped -Because "qc.psm1 not present"
    }
  }
}
