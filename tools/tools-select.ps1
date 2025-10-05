param(
  [string]$Csv = (Join-Path (Join-Path "reports" (Get-Date -Format "yyyy-MM-dd")) "tools-candidates.csv"),
  [string]$Out = (Join-Path (Join-Path "reports" (Get-Date -Format "yyyy-MM-dd")) "tools-selection.md")
)
$crit = @(
  @{ Key="Value"; Weight=25 }, @{ Key="Integration"; Weight=15 }, @{ Key="CI"; Weight=10 },
  @{ Key="Locality"; Weight=10 }, @{ Key="Maintenance"; Weight=10 }, @{ Key="Cost"; Weight=5 },
  @{ Key="Learning"; Weight=10 }, @{ Key="Noise"; Weight=5 }, @{ Key="Repro"; Weight=5 }, @{ Key="TimeSave"; Weight=5 }
)
$data = Import-Csv $Csv
$rows = foreach($r in $data){
  $s=0; foreach($c in $crit){ $v=0; [void][double]::TryParse([string]$r.$($c.Key),[ref]$v); $s += $v*($c.Weight/100.0) }
  [pscustomobject]@{ Tool=$r.Tool; Score=[math]::Round($s,2); Comment=$r.Comment }
} | Sort-Object Score -Descending
$adopt = $rows | ? { $_.Score -ge 3.5 }
$pilot = $rows | ? { $_.Score -ge 2.8 -and $_.Score -lt 3.5 }
$defer = $rows | ? { $_.Score -lt 2.8 }
$md = @("# Tools — Selection ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))","",
"## ✅ Adopt now") + ($(if($adopt){$adopt|%{"- $($_.Tool) — **$($_.Score)** $($_.Comment)"}}else{"- (none)"})) + "",
"## 🧪 Pilot" + ($(if($pilot){$pilot|%{"- $($_.Tool) — **$($_.Score)** $($_.Comment)"}}else{"- (none)"})) + "",
"## 💤 Defer" + ($(if($defer){$defer|%{"- $($_.Tool) — **$($_.Score)** $($_.Comment)"}}else{"- (none)"}))
$md -join "`r`n" | Out-File -Encoding UTF8 -FilePath $Out
Write-Host "✓ Вибір: $Out" -ForegroundColor Green
