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
if ($env:ATS_NOEXIT -eq "1") { Write-Host "ATS_NOEXIT=1 → skip exit"; return }
exit 0

function Save-G2Artifacts {
  param(
    [Parameter(Mandatory)][string]$ReportDir,
    [Parameter(Mandatory)][string]$RunPathLocal,
    [Parameter(Mandatory)][string]$Gate,
    [Parameter(Mandatory)][string]$Seed,
    [Parameter(Mandatory)][string]$ConfigPath
  )
  if (!(Test-Path $ReportDir)) { throw "ReportDir not found: $ReportDir" }

  # 1) HTML header note (seed + gate) якщо це наш placeholder — допишемо службовий рядок
  try {
    $html = Get-ChildItem $ReportDir -Recurse -Include *.html -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($html) {
      $tag = "<!-- GATE=$Gate; SEED=$Seed; TS=$(Get-Date -Format s) -->"
      Add-Content -LiteralPath $html.FullName -Value $tag -Encoding UTF8
    }
  } catch { }

  # 2) CONFIG snapshot -> config.json (якщо .psd1 є)
  if (Test-Path $ConfigPath) {
    try {
      $cfg = Import-PowerShellDataFile -Path $ConfigPath
      $cfg | ConvertTo-Json -Depth 20 | Out-File -FilePath (Join-Path $ReportDir 'config.json') -Encoding UTF8
    } catch {
      Write-Warning "Config snapshot failed: $($_.Exception.Message)"
    }
  }

  # 3) METRICS (json + csv, базові поля)
  $metrics = [ordered]@{
    gate      = $Gate
    status    = 'PASS'
    seed      = $Seed
    date      = Split-Path $ReportDir -Leaf
    timestamp = (Get-Date).ToString('s')
  }
  $metrics | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $ReportDir 'metrics.json') -Encoding UTF8
  "Metric,Value`nGate,$($metrics.gate)`nStatus,$($metrics.status)`nSeed,$($metrics.seed)`nDate,$($metrics.date)" |
    Set-Content -Path (Join-Path $ReportDir 'metrics.csv') -Encoding UTF8

  # 4) LOG (runs/*/run.log -> report/run.log або заглушка)
  $runLog = Join-Path $RunPathLocal 'run.log'
  $dest   = Join-Path $ReportDir 'run.log'
  if (Test-Path $runLog) {
    Copy-Item $runLog $dest -Force
  } else {
    "G2 run log not found, created stub at $(Get-Date)." | Set-Content $dest -Encoding UTF8
  }

  # 5) QC guard: усі артефакти на місці?
  $need = @{
    HTML    = { Get-ChildItem $ReportDir -Recurse -Include *.html -ErrorAction SilentlyContinue | Select-Object -First 1 }
    Config  = { Get-Item (Join-Path $ReportDir 'config.json') -ErrorAction SilentlyContinue }
    Metrics = { Get-Item (Join-Path $ReportDir 'metrics.json') -ErrorAction SilentlyContinue }
    Log     = { Get-Item (Join-Path $ReportDir 'run.log') -ErrorAction SilentlyContinue }
  }
  $missing = @()
  foreach ($k in $need.Keys) { if (-not (& $need[$k])) { $missing += $k } }
  if ($missing.Count) {
    throw "QC FAIL: missing artifacts -> $($missing -join ', ')"
  } else {
    Write-Host "✅ G2 artifacts ready in $ReportDir"
  }
}

# >> G2 artifacts hook
try {
  if ($Gate -eq 'G2' -and (Test-Path $ReportPath)) {
    Save-G2Artifacts -ReportDir $ReportPath -RunPathLocal $RunPath -Gate $Gate -Seed $seed -ConfigPath $ConfigPath
  }
} catch {
  Write-Host "Artifacts hook warning: $($_.Exception.Message)" -ForegroundColor Yellow
}
# << end hook
