param([Parameter(Mandatory=$true)][string]$Spec)
$ErrorActionPreference='Stop'
function Fail($m){ throw "preflight: $m" }

# 0) Bootstrap registries (both locations your patcher may use)
$regRoots = @('patches','tools/patches')
foreach ($r in $regRoots) {
  if (-not (Test-Path $r)) { New-Item -ItemType Directory -Force -Path $r | Out-Null }
  $reg = Join-Path -Path $r -ChildPath 'registry.json'
  if (-not (Test-Path $reg)) { Set-Content -LiteralPath $reg -Encoding UTF8 -Value '{"applied":[]}' }
}

# 1) PSD1 validity
try { $specData = Import-PowerShellDataFile -Path $Spec }
catch { Fail ("PSD1 parse failed: " + $_.Exception.Message) }
if (-not $specData) { Fail "spec is empty" }

# 2) Unsafe Lines checks (no dynamic concat, no nested single quotes)
$bad = @()
$steps = @()
if ($specData.PSObject.Properties.Name -contains 'Steps') { $steps = $specData.Steps } else { $steps = @() }
foreach ($step in $steps) {
  if ($null -ne $step.Lines) {
    foreach ($ln in $step.Lines) {
      if ($ln -match '\+\s*".*"' -or $ln -match "\+\s*'.*'") { $bad += "dyn-concat in Lines: [$ln]" }
      if ($ln -match "'[^']*'[^']*'")        { $bad += "nested single quotes: [$ln]" }
    }
  }
}
if ($bad.Count) { Fail ("Unsafe lines:`n" + ($bad -join "`n")) }

# 3) EnsureBlock anchors exist
function Test-Anchors([string]$path,[string]$start,[string]$end){
  if (-not (Test-Path $path)) { return "file not found: $path" }
  $t = Get-Content -LiteralPath $path -Raw
  if ($t.IndexOf($start) -lt 0) { return ("start anchor missing in {0}: {1}" -f $path, $start) }
  if ($t.IndexOf($end)   -lt 0) { return ("end anchor missing in {0}: {1}"   -f $path, $end) }
  return $null
}
$anchorIssues = @()
foreach ($s in $steps) {
  if ($s.Type -eq 'EnsureBlock') {
    $iss = Test-Anchors $s.Path $s.Start $s.End
    if ($iss) { $anchorIssues += $iss }
  }
}
if ($anchorIssues.Count) { Fail ("Anchor issues: " + ($anchorIssues -join '; ')) }

# 4) Summary
Write-Host "Preflight OK"
Write-Host "  Id   : $($specData.Id)"
Write-Host "  Name : $($specData.Name)"
Write-Host "  Steps: $($steps.Count)"
if ($specData.PSObject.Properties.Name -contains 'QC') {
  Write-Host ("  QC   : {0} {1}" -f $specData.QC.Command, (($specData.QC.Args -join ' ')))
} else {
  Write-Host "  QC   : (none)"
}