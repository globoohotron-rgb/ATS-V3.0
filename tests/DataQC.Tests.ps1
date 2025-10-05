# --- A1 FIX: robust $repRoot even if $PSScriptRoot is $null ---
$__here = $PSScriptRoot
if (-not $__here) { try { $__here = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {} }
if (-not $__here) { $__here = (Get-Location).Path }
$repRoot = Split-Path -Parent $__here
# --- /A1 FIX ---
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

Describe "Data QC (targeted, inline)" {
  It "PASS → overall_pass true" {
    & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'qc_case.ps1') -Case pass | Out-Null
    $qcDir = Join-Path $repoRoot 'artifacts/qc'
    $json  = Get-ChildItem $qcDir -Filter '*_qc.json' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $s = Get-Content $json.FullName -Raw | ConvertFrom-Json
    $s | Should -Not -Be $null
    $s.overall_pass | Should -BeTrue
  }

  It "duplicate_pk → overall_pass false" {
    & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'qc_case.ps1') -Case duplicate_pk | Out-Null
    $qcDir = Join-Path $repoRoot 'artifacts/qc'
    $json  = Get-ChildItem $qcDir -Filter '*_qc.json' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $s = Get-Content $json.FullName -Raw | ConvertFrom-Json
    $s | Should -Not -Be $null
    $s.overall_pass | Should -BeFalse
  }

  It "missing_column → overall_pass false" {
    & pwsh -NoLogo -NoProfile -File (Join-Path $repoRoot 'qc_case.ps1') -Case missing_column | Out-Null
    $qcDir = Join-Path $repoRoot 'artifacts/qc'
    $json  = Get-ChildItem $qcDir -Filter '*_qc.json' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $s = Get-Content $json.FullName -Raw | ConvertFrom-Json
    $s | Should -Not -Be $null
    $s.overall_pass | Should -BeFalse
  }
}

