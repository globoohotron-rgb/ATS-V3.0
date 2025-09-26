param()
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
$inv  = Join-Path $root "scripts\Invoke-G5WF.ps1"
$ver  = Join-Path $root "scripts\Get-G5Verdict.ps1"
$rep  = Join-Path $root "scripts\g5.report.ps1"

# 1) свіжий WF (demo)
try { & $inv -WFProfile demo | Out-Null } catch { Write-Host "[warn] WF run issue: $_" }

# 2) останній JSON
$wfJson = Get-ChildItem (Join-Path $root "runs") -Recurse -Filter "wf.results.json" -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $wfJson) { throw "wf.results.json not found" }

# 3) md-вердикт (опц., для лінку)
$mdPath = $null
try {
  $verPS = (Resolve-Path $ver).Path; $v = & $verPS -WFJsonPath $wfJson.FullName
  $repDir = Join-Path $root ("reports\{0:yyyy-MM-dd}" -f (Get-Date)); New-Item -ItemType Directory -Path $repDir -Force | Out-Null
  $md = Join-Path $repDir ("G5-Verdict-{0:HHmmss}.md" -f (Get-Date))
  $why = ($v.Why | ForEach-Object { "- $_" }) -join "`n"
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($md, "# G5 Verdict — $($v.Verdict)`n`n$why`n", $enc)
  $mdPath = $md
} catch { Write-Host "[warn] verdict md not generated: $_" }

# 4) HTML-репорт
$repPS = (Resolve-Path $rep).Path; & $repPS -WFJsonPath $wfJson.FullName -VerdictMdPath $mdPath