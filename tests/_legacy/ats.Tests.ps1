BeforeAll {
  Import-Module (Join-Path $PSScriptRoot "..\scripts\ats.psm1") -Force
}
Describe "ATS helpers (scripts/ats.psm1) [Pester5]" {
  It "SMA returns correct length and last value (period=2)" {
    $arr = 1,2,3,4,5
    $sma = SMA $arr 2
    $sma.Length | Should -Be 5
    [double]::IsNaN($sma[0]) | Should -BeTrue
    $sma[4] | Should -BeGreaterThan 4.49
    $sma[4] | Should -BeLessOrEqual 4.51
  }
  It "StdDev is ~0 for constant array (epsilon)" {
    $sd = StdDev @(0,0,0,0,0)
    [math]::Abs($sd) -lt 1e-12 | Should -BeTrue
  }
  It "MaxDrawdown simple descending equity -> ~30%" {
    $dd = MaxDrawdown @(1.0,0.9,0.8,0.7)
    $dd | Should -BeGreaterThan 0.299
    $dd | Should -BeLessOrEqual 0.301
  }
}
