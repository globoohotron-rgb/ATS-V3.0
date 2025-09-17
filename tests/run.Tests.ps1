Describe "Runner smoke (G2) [v3]" {
  It "produces (CSV + G2 HTML) OR QC evidence" {
    $repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    & (Join-Path $repo "run.ps1") -Gate G2 -CostBps 5 | Out-Null
    $date = (Get-Date).ToString("yyyy-MM-dd")
    $repDir = Join-Path $repo ("reports\" + $date)
    $hasCsv  = Test-Path (Join-Path $repo "data\processed\signals_sample.csv")
    $hasHtml = (Get-ChildItem $repDir -Filter "G2-*.html" -ErrorAction SilentlyContinue).Count -gt 0
    $hasQC   = (Get-ChildItem $repDir -Filter "QC-Evidence-*.md" -ErrorAction SilentlyContinue).Count -gt 0
    (($hasCsv -and $hasHtml) -or $hasQC) | Should Be $true
  }
}
