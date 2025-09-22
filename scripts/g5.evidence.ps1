[CmdletBinding()]
param(
  [string]$WFJsonPath,          # опційно: шлях до wf.results.json
  [string]$ForceVerdict         # опційно: FOR TEST ("REJECT"/"ACCEPT") — пересилити вердикт
)
Set-StrictMode -Version Latest

function Write-Utf8NoBom([string]$Path,[string]$Content){
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($Path,$Content,$enc)
}
function Rel([string]$from,[string]$to){
  try {
    $u = New-Object System.Uri($from + (if(-not $from.EndsWith('\')){'\' } else {''}))
    $v = New-Object System.Uri($to)
    return [Uri]::UnescapeDataString($u.MakeRelativeUri($v).ToString()).Replace('/', '/')
  } catch { return $to }
}
function Upsert-LinksBlock([string]$path,[string]$line){
  $start='GS-RULES-LINK START'; $end='GS-RULES-LINK END'
  $raw = if(Test-Path $path){ Get-Content -Raw $path } else { "# Gates`n$start`n$end`n" }
  $rx = '(?s)(.*?' + [regex]::Escape($start) + '\s*)(.*?)(\s*' + [regex]::Escape($end) + '.*)'
  $m = [regex]::Match($raw,$rx)
  if($m.Success){
    $inner = $m.Groups[2].Value.Trim()
    if($inner -notmatch [regex]::Escape($line)){
      $inner = $line + "`r`n" + $inner
    }
    $new = $m.Groups[1].Value + $inner + "`r`n" + $m.Groups[3].Value
    Write-Utf8NoBom $path $new
  } else {
    $new = $raw.TrimEnd() + "`r`n$start`r`n$line`r`n$end`r`n"
    Write-Utf8NoBom $path $new
  }
}

$root   = Split-Path -Parent $PSCommandPath | Split-Path -Parent
$scrDir = Join-Path $root 'scripts'
$repDir = Join-Path $root ('reports\{0:yyyy-MM-dd}' -f (Get-Date))
$docsDir= Join-Path $root 'docs'
New-Item -ItemType Directory -Path $repDir -Force | Out-Null

# 1) знайти JSON (або взяти останній)
if(-not $WFJsonPath){
  $wf = Get-ChildItem (Join-Path $root 'runs') -Recurse -Filter 'wf.results.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime | Select-Object -Last 1
  if(-not $wf){ throw "wf.results.json not found under runs — спочатку запусти WF" }
  $WFJsonPath = $wf.FullName
}

# 2) вердикт
$verPS = (Resolve-Path (Join-Path $scrDir 'Get-G5Verdict.ps1')).Path
$v = & $verPS -WFJsonPath $WFJsonPath
if($ForceVerdict){ $v.Verdict = $ForceVerdict }

if("$($v.Verdict)" -ne 'REJECT'){
  Write-Host "[ok] Verdict is $($v.Verdict) — EvidencePack не потрібен."
  return
}

# 3) забезпечити HTML-репорт
$reportPS = (Resolve-Path (Join-Path $scrDir 'g5.report.ps1')).Path
$report = Get-ChildItem $repDir -Filter 'G5-Report-*.html' -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime | Select-Object -Last 1
if(-not $report){
  & $reportPS -WFJsonPath $WFJsonPath | Out-Null
  $report = Get-ChildItem $repDir -Filter 'G5-Report-*.html' | Sort-Object LastWriteTime | Select-Object -Last 1
}
$reportPath = if($report){ $report.FullName } else { $null }

# 4) CSV біля JSON (якщо є)
$csvPath = Join-Path (Split-Path $WFJsonPath -Parent) 'wf.oos.csv'
if(-not (Test-Path $csvPath)){ $csvPath = $null }

# 5) створити папку EvidencePack
$stamp = Get-Date -Format 'HHmmss'
$epDir = Join-Path $repDir ("EvidencePack-{0}" -f $stamp)
New-Item -ItemType Directory -Path $epDir -Force | Out-Null

# 6) скопіювати артефакти
Copy-Item $WFJsonPath (Join-Path $epDir 'wf.results.json') -Force
if($csvPath){ Copy-Item $csvPath (Join-Path $epDir 'wf.oos.csv') -Force }
if($reportPath){ Copy-Item $reportPath (Join-Path $epDir (Split-Path $reportPath -Leaf)) -Force }

# 7) згенерувати EvidencePack.md (з шаблону або inline)
$tplPath = Join-Path $root 'docs\GS-EvidencePack.template.md'
if(Test-Path $tplPath){ $tpl = Get-Content -Raw $tplPath } else {
$tpl = @"
# G5 Evidence Pack — {DATE}

**Verdict:** {VERDICT}

## Why
{WHY_BULLETS}

## Artifacts
- JSON: {LINK_JSON}
{LINK_CSV_LINE}- HTML report: {LINK_HTML}
"@
}
$why = ($v.Why | ForEach-Object { "* " + $_ }) -join "`n"
$ep = $tpl
$ep = $ep.Replace('{DATE}', (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$ep = $ep.Replace('{VERDICT}', "$($v.Verdict)")
$ep = $ep.Replace('{WHY_BULLETS}', $why)
$ep = $ep.Replace('{LINK_JSON}', 'wf.results.json')
$ep = $ep.Replace('{LINK_HTML}', (Get-ChildItem $epDir -Filter 'G5-Report-*.html' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select -Last 1 | ForEach-Object Name))
$ep = $ep.Replace('{LINK_CSV_LINE}', ($(if(Test-Path (Join-Path $epDir 'wf.oos.csv')){ "- CSV: wf.oos.csv`n" } else { "" })))

$epMdPath = Join-Path $epDir 'EvidencePack.md'
Write-Utf8NoBom $epMdPath $ep

# 8) вписати лінк у docs/gates.md між GS-RULES-LINK START/END
$gates = Join-Path $root 'docs\gates.md'
$date  = Get-Date -Format 'yyyy-MM-dd'
$short = if($v.Why -and $v.Why.Count -gt 0){ $v.Why[0] } else { "see pack" }
$relEp = Rel $root $epMdPath     # відносно кореня, для md
$relEp = $relEp.Replace('\','/') # md-стиль
$line  = "- $date — **REJECT**: $short. [EvidencePack]($relEp)"
Upsert-LinksBlock -path $gates -line $line

Write-Host "[done] EvidencePack створено: $epDir"
Write-Host "[done] Лінк додано у: $gates"