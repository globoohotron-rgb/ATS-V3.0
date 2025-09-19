param(
  [Parameter(Mandatory)][string]$Spec,
  [switch]$Force,
  [switch]$DryRun,
  [switch]$NoQC,
  [switch]$AutoStash
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\tools\patchkit.psm1') -Force

if(!(Test-Path $Spec)){ throw "Spec not found: $Spec" }
$specData = Import-PowerShellDataFile -Path $Spec
Test-PatchSpec $specData | Out-Null
$Id    = $specData.Id
$Name  = $specData.Name
$Steps = $specData.Steps
$QC    = $specData.QC
$Targets = ($Steps | ForEach-Object { $_.Path } | Select-Object -Unique)

$hash  = Get-SpecHash $Spec
$commit = ''
try { $commit = (& git rev-parse --short HEAD) 2>$null } catch {}

Write-PatchLog "▶ Patch [$Id] $Name"

if(Is-Applied -Id $Id -Hash $hash -and -not $Force){
  Write-PatchLog "Already applied (hash match). Use -Force to re-apply." 'WARN'
  exit 0
}

# optional autostash
$stashRef = $null
if($AutoStash){
  try {
    $dirty = (& git status --porcelain) 2>$null
    if($dirty){ $stashRef = (& git stash push -k -u -m "patch-$Id") 2>$null; Write-PatchLog "auto-stash created: $stashRef" }
  } catch { Write-PatchLog "Git autostash failed: $($_.Exception.Message)" 'WARN' }
}

# Backup
$backup = New-PatchBackup -Paths $Targets

# Apply
$changed = @()
foreach($s in $Steps){
  $path = $s.Path; $type = $s.Type; $ok=$false
  switch($type){
    'InsertAfter'  { $ok = Insert-AfterPattern -Path $path -Pattern $s.Pattern -Lines $s.Lines }
    'EnsureBlock'  { $ok = Ensure-BlockByMarkers -Path $path -StartMarker $s.Start -EndMarker $s.End -Lines $s.Lines }
    'ReplaceRegex' { $ok = Replace-Regex -Path $path -Pattern $s.Pattern -Replacement $s.Replacement -Single:$s.Single }
    default { throw "Unknown step type: $type" }
  }
  if($ok){ $changed += $path; Write-PatchLog "✔ $type on $path" } else { Write-PatchLog "• $type no-op on $path" }
}

# Parse check for changed ps1
$psFiles = $changed | Where-Object { $_ -like '*.ps1' } | Select-Object -Unique
foreach($f in $psFiles){
  $r = Test-ParseScript $f
  if(-not $r.Ok){
    Write-PatchLog "Parse error: $f" 'ERROR'
    Restore-PatchBackup -BackupDir $backup.Dir
    throw "Parse check failed."
  }
}

if($DryRun){
  Write-PatchLog "Dry-run complete (no QC, no ledger)."
  if($stashRef){ try { & git stash pop } catch {} }
  exit 0
}

# QC
if(-not $NoQC -and $QC){
  Write-PatchLog "QC: $($QC.Command)"
  & $QC.Command @($QC.Args)
}

# Success → ledger
Update-Ledger -Id $Id -Name $Name -Hash $hash -Commit $commit
Write-PatchLog "✅ Patch applied: [$Id] $Name"

# pop stash if existed
if($stashRef){ try { & git stash pop 2>$null | Out-Null } catch { Write-PatchLog "git stash pop failed: $($_.Exception.Message)" 'WARN' } }
