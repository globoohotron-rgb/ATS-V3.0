param(
  [string]$Csv = (Join-Path (Join-Path "reports" (Get-Date -Format "yyyy-MM-dd")) "tools-candidates.csv"),
  [string]$Out = (Join-Path (Join-Path "reports" (Get-Date -Format "yyyy-MM-dd")) "tools-ranking.md")
)
$ErrorActionPreference = "Stop"

# Критерії/ваги (мають збігатись із шаблоном)
$crit = @(
  @{ Key="Value"; Weight=25 },
  @{ Key="Integration"; Weight=15 },
  @{ Key="CI"; Weight=10 },
  @{ Key="Locality"; Weight=10 },
  @{ Key="Maintenance"; Weight=10 },
  @{ Key="Cost"; Weight=5 },
  @{ Key="Learning"; Weight=10 },
  @{ Key="Noise"; Weight=5 },
  @{ Key="Repro"; Weight=5 },
  @{ Key="TimeSave"; Weight=5 }
)

if (-not (Test-Path $Csv)) { throw "CSV not found: $Csv" }
$data = Import-Csv -Path $Csv
$scored = foreach($r in $data){
  $score = 0
  foreach($c in $crit){
    $v = 0
    if ($r.PSObject.Properties.Name -contains $c.Key) {
      $try = [double]::TryParse([string]$r.$($c.Key), [ref]([double]$v)) | Out-Null
      if (-not $try) { $v = 0 }
    }
    $score += $v * ($c.Weight/100.0)
  }
  [pscustomobject]@{
    Tool   = $r.Tool
    Score  = [math]::Round($score, 2)
    Comment = $r.Comment
  }
} | Sort-Object Score -Descending

# Markdown вихід
$md = @("# Tools — Ranking ($(Get-Date -Format "yyyy-MM-dd HH:mm:ss"))", "")
$md += "| # | Tool | Score | Comment |"
$md += "|---:|---|---:|---|"
$i=1
foreach($row in $scored){
  $md += "| $i | $($row.Tool) | $($row.Score) | $($row.Comment) |"
  $i++
}
$md -join "`r`n" | Out-File -FilePath $Out -Encoding UTF8
Write-Host "Saved: $Out" -ForegroundColor Green
