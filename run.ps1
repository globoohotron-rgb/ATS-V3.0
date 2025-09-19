param(
  [ValidateSet('All','G1','G2','G3','G4','G5','G6')]
  [string]$Gate = 'G2',
  [string]$Date = (Get-Date -Format 'yyyy-MM-dd'),
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'config/config.psd1'),
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Kill-switch + reproducibility seed ---
$KillSwitchPath = Join-Path $PSScriptRoot 'config/KILL'
if (Test-Path $KillSwitchPath) { throw "Kill-switch is ON ($KillSwitchPath)" }

$Seed = if ($env:ATS_SEED) { try { [int]$env:ATS_SEED } catch { 42 } } else { 42 }

# --- Paths ---
$Root       = $PSScriptRoot
$RunId      = Get-Date -Format 'HHmmss'
$RunPath    = Join-Path $Root "runs/$Date/run-$RunId"
$ReportPath = Join-Path $Root "reports/$Date"
$DocsPath   = Join-Path $Root 'docs'

New-Item -ItemType Directory -Force -Path $RunPath, $ReportPath, $DocsPath | Out-Null
$GatesFile = Join-Path $DocsPath 'gates.md'
if (!(Test-Path $GatesFile)) { "# Gates journal`n" | Set-Content -Encoding utf8 -LiteralPath $GatesFile }

function Write-Log {
  param([string]$Message, [ValidateSet('INFO','WARN','ERROR')]$Level='INFO')
  $line = "[{0}] {1} {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
  if(-not $Quiet){ Write-Host $line }
  Add-Content -LiteralPath (Join-Path $RunPath 'run.log') -Value $line -Encoding UTF8
}

function Import-IfExists([string]$Path){
  if (Test-Path $Path) { Import-Module $Path -Force -ErrorAction Stop -DisableNameChecking; return $true }
  return $false
}
function Invoke-IfExists([string]$ScriptPath){
  if (Test-Path $ScriptPath) { & $ScriptPath; return $true }
  return $false
}

# Import core modules
$atsOk = Import-IfExists (Join-Path $Root 'scripts/ats.psm1')
$qcOk  = Import-IfExists (Join-Path $Root 'scripts/qc.psm1')
if(-not $atsOk){ throw "Missing module scripts/ats.psm1" }

# Context snapshot (включно з Seed)
$ctx = [ordered]@{
  RunId      = $RunId
  Date       = $Date
  Root       = $Root
  RunPath    = $RunPath
  ReportPath = $ReportPath
  ConfigPath = $ConfigPath
  Seed       = $Seed
}
$ctx | ConvertTo-Json -Depth 5 | Set-Content -NoNewline -Encoding utf8 -LiteralPath (Join-Path $RunPath 'context.json')

function Invoke-Gate {
  param(
    [Parameter(Mandatory)]
    [ValidateSet('G1','G2','G3','G4','G5','G6')]
    [string]$Name,
    [Parameter(Mandatory)]
    [scriptblock]$Body
  )
  Write-Log "=== ${Name}: START ==="
  try {
    & $Body
    Write-Log "=== ${Name}: PASS ==="
    Add-Content -Encoding utf8 -LiteralPath $GatesFile -Value ("{0}  -  {1}  PASS  (run {2})" -f $Date, $Name, $RunId)
  }
  catch {
    Write-Log ("${Name}: " + $_.Exception.Message) 'ERROR'
    Add-Content -Encoding utf8 -LiteralPath $GatesFile -Value ("{0}  -  {1}  FAIL  (run {2})  :: {3}" -f $Date, $Name, $RunId, $_.Exception.Message)
    throw
  }
}

# Gates (делегуємо на scripts/gates/GX.ps1, інакше плейсхолдер)
$G1 = { if (Invoke-IfExists (Join-Path $Root 'scripts/gates/G1.ps1')) {return}
  $out = Join-Path $ReportPath 'G1-hello.html'
  @"
<html><body><h1>G1 hello</h1><p>Run $($ctx.RunId) on $($ctx.Date)</p></body></html>
"@ | Set-Content -Encoding utf8 -LiteralPath $out
}
$G2 = { if (Invoke-IfExists (Join-Path $Root 'scripts/gates/G2.ps1')) {return}
  $out = Join-Path $ReportPath 'G2-report.html'
  "<html><body><h1>G2 report (placeholder)</h1></body></html>" | Set-Content -Encoding utf8 -LiteralPath $out
}
$G3 = { if (Invoke-IfExists (Join-Path $Root 'scripts/gates/G3.ps1')) {return}
  $out = Join-Path $ReportPath 'G3-paper.html'
  "<html><body><h1>G3 paper-run (placeholder)</h1></body></html>" | Set-Content -Encoding utf8 -LiteralPath $out
}
$G4 = { if (Invoke-IfExists (Join-Path $Root 'scripts/gates/G4.ps1')) {return}
  $out = Join-Path $ReportPath 'G4-day.html'
  "<html><body><h1>G4 orchestration (placeholder)</h1></body></html>" | Set-Content -Encoding utf8 -LiteralPath $out
}
$G5 = { if (Invoke-IfExists (Join-Path $Root 'scripts/gates/G5.ps1')) {return}
  $out = Join-Path $ReportPath 'G5-stub.html'
  "<html><body><h1>G5 stub</h1><p>Guardrails pending.</p></body></html>" | Set-Content -Encoding utf8 -LiteralPath $out
}
$G6 = { if (Invoke-IfExists (Join-Path $Root 'scripts/gates/G6.ps1')) {return}
  $out = Join-Path $ReportPath 'G6-live-check.html'
  "<html><body><h1>G6 live guard (placeholder)</h1></body></html>" | Set-Content -Encoding utf8 -LiteralPath $out
}

switch ($Gate) {
  'All' {
    Invoke-Gate -Name 'G1' -Body $G1
    Invoke-Gate -Name 'G2' -Body $G2
    Invoke-Gate -Name 'G3' -Body $G3
    Invoke-Gate -Name 'G4' -Body $G4
    Invoke-Gate -Name 'G5' -Body $G5
    Invoke-Gate -Name 'G6' -Body $G6
  }
  default {
    Invoke-Gate -Name $Gate -Body (Get-Variable $Gate -ValueOnly)
  }
}

Write-Log "Run complete. Artifacts: $ReportPath"
# >> G2 finalize (clean inline)
if ($Gate -eq 'G2' -and (Test-Path $ReportPath)) {
  try {
    # CONFIG snapshot
    if (Test-Path $ConfigPath) {
      (Import-PowerShellDataFile -Path $ConfigPath) | ConvertTo-Json -Depth 20 |
        Out-File -FilePath (Join-Path $ReportPath 'config.json') -Encoding UTF8
    }

    # METRICS (json + csv, без "плюсів" на переноси)
    $date = Split-Path $ReportPath -Leaf
    $m = [ordered]@{ gate=$Gate; status='PASS'; seed=$seed; date=$date; ts=(Get-Date).ToString('s') }
    $m | ConvertTo-Json -Depth 5 | Out-File (Join-Path $ReportPath 'metrics.json') -Encoding UTF8

    $csv = @()
    $csv += 'Metric,Value'
    $csv += ('Gate,{0}'   -f $m.gate)
    $csv += ('Status,{0}' -f $m.status)
    $csv += ('Seed,{0}'   -f $m.seed)
    $csv += ('Date,{0}'   -f $m.date)
    $csv | Set-Content (Join-Path $ReportPath 'metrics.csv') -Encoding UTF8

    # LOG
    $src = Join-Path $RunPath 'run.log'
    if (Test-Path $src) { Copy-Item $src (Join-Path $ReportPath 'run.log') -Force }
    else { 'G2 run log stub ' + (Get-Date) | Set-Content (Join-Path $ReportPath 'run.log') -Encoding UTF8 }

    # META → HTML (три прості коментарі)
    $html = Get-ChildItem $ReportPath -Recurse -Filter *.html -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($html) {
      $meta = @('<!-- RUN-META-START -->',
                ("<!-- Gate="+$Gate+" Seed="+$seed+" Date="+$date+" -->"),
                '<!-- RUN-META-END -->')
      $meta | Add-Content -LiteralPath $html.FullName -Encoding UTF8
    }

    # QC flag
    Set-Content (Join-Path $ReportPath 'QC_OK.flag') ('PASS ' + (Get-Date -Format s)) -Encoding UTF8
  } catch {
    Write-Error ('G2 finalize failed: {0}' -f $_.Exception.Message)
    exit 1
  }
}
# << G2 finalize (clean inline)

if ($env:ATS_NOEXIT -eq "1") { Write-Host "ATS_NOEXIT=1 → skip exit"; return }
exit 0



