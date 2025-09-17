Describe "ATS helpers (scripts/ats.psm1) [v3]" {
  BeforeAll { Import-Module (Join-Path $PSScriptRoot "..\scripts\ats.psm1") -Force -DisableNameChecking }

  It "SMA returns correct length and last value (period=2)" {
    $arr = 1,2,3,4,5
    $sma = SMA $arr 2
    ($sma.Length -eq 5) | Should Be $true
    ([double]::IsNaN($sma[0])) | Should Be $true
    (( $sma[4] -gt 4.49 ) -and ( $sma[4] -le 4.51 )) | Should Be $true
  }

  It "StdDev is ~0 for constant array (epsilon tolerance)" {
    $eps = 1e-12
    $sd  = StdDev @(0,0,0,0,0)
    ([math]::Abs($sd) -lt $eps) | Should Be $true
  }

  It "MaxDrawdown simple descending equity -> ~30%" {
    $eq = 1.0,0.9,0.8,0.7
    $dd = MaxDrawdown $eq
    (( $dd -gt 0.299 ) -and ( $dd -le 0.301 )) | Should Be $true
  }
}
