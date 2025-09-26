@{
  Name   = "Demo: ensure G2 one-liner section"
  Target = "README.md"
  Steps  = @(
    @{
      Type   = 'EnsureBlock'
      Path   = 'README.md'
      Start  = '<!-- G2-ONE-LINER-START -->'
      End    = '<!-- G2-ONE-LINER-END -->'
      Lines  = @(
        '## Quickstart: G2 smoke',
        '```powershell',
        '.\run.ps1 -Gate G2',
        '```',
        'Артефакти: html + config.json + metrics.json/csv + run.log + QC_OK.flag'
      )
    }
  )
  QC = @{
    Command = '.\scripts\selftest.ps1'
    Args    = @()
  }
}
