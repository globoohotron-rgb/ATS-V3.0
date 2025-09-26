$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

function Write-PatchLog {
  param([string]$Message,[string]$Level='INFO')
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $line = "[{0}] {1} {2}" -f $stamp,$Level,$Message
  Add-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\logs\patch.log') -Value $line -Encoding UTF8
  if($Level -eq 'ERROR'){ Write-Error $Message } elseif($Level -eq 'WARN'){ Write-Warning $Message } else { Write-Host $Message }
}

function New-PatchBackup {
  param([string[]]$Paths,[string]$OutDir = (Join-Path $PSScriptRoot '..\..\scripts\_backup\patches'))
  if(!(Test-Path $OutDir)){ New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $dest  = Join-Path $OutDir $stamp
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  foreach($p in $Paths){ if(Test-Path $p){ Copy-Item $p (Join-Path $dest (Split-Path $p -Leaf)) -Force } }
  Write-PatchLog "Backup created at $dest"
  return @{Dir=$dest; Stamp=$stamp}
}
function Restore-PatchBackup {
  param([string]$BackupDir)
  if(!(Test-Path $BackupDir)){ throw "Backup not found: $BackupDir" }
  Get-ChildItem $BackupDir -File | ForEach-Object {
    Copy-Item $_.FullName (Join-Path (Get-Location) (Split-Path $_.Name -Leaf)) -Force
  }
  Write-PatchLog "Backup restored from $BackupDir" 'WARN'
}

function Get-Text { param([string]$Path) if(!(Test-Path $Path)){throw "No file: $Path"}; Get-Content $Path -Raw }
function Set-Text { param([string]$Path,[string]$Text) Set-Content -LiteralPath $Path -Value $Text -Encoding UTF8 }
function Get-Regex  { param([string]$Pattern,[System.Text.RegularExpressions.RegexOptions]$Options = 'Multiline',[int]$TimeoutSec = 2)
  return [regex]::new($Pattern,$Options,[TimeSpan]::FromSeconds($TimeoutSec)) }

function Insert-AfterPattern {
  param([string]$Path,[string]$Pattern,[string[]]$Lines)
  $rx = Get-Regex $Pattern 'Multiline'
  $arr = Get-Content $Path
  $hit = ($arr | Select-String -Pattern $rx | Select-Object -First 1)
  if(-not $hit){ return $false }
  $idx = $hit.LineNumber - 1
  $before = if($idx -ge 0){ $arr[0..$idx] } else { @() }
  $after  = if($idx -lt $arr.Count-1){ $arr[($idx+1)..($arr.Count-1)] } else { @() }
  Set-Content $Path -Value (@()+$before+$Lines+$after) -Encoding UTF8
  return $true
}
function Replace-BetweenMarkers {
  param([string]$Path,[string]$Start,[string]$End,[string[]]$Replacement)
  $rxStart = Get-Regex $Start 'Multiline'
  $rxEnd   = Get-Regex $End 'Multiline'
  $txt = Get-Text $Path
  $m1 = $rxStart.Match($txt); if(-not $m1.Success){ return $false }
  $m2 = $rxEnd.Match($txt,$m1.Index+$m1.Length); if(-not $m2.Success){ return $false }
  $new = $txt.Substring(0,$m1.Index + $m1.Length) + "`r`n" + ($Replacement -join "`r`n") + "`r`n" + $txt.Substring($m2.Index)
  Set-Text $Path $new; return $true
}
function Ensure-BlockByMarkers {
  param([string]$Path,[string]$StartMarker,[string]$EndMarker,[string[]]$Lines)
  $ok = Replace-BetweenMarkers -Path $Path -Start $StartMarker -End $EndMarker -Replacement $Lines
  if(-not $ok){
    $block = @($StartMarker) + $Lines + @($EndMarker)
    Add-Content -LiteralPath $Path -Value ($block -join "`r`n") -Encoding UTF8
  }
  return $true
}
function Replace-Regex {
  param([string]$Path,[string]$Pattern,[string]$Replacement,[switch]$Single=$true)
  $rx = Get-Regex $Pattern 'Singleline,Multiline'
  $txt = Get-Text $Path
  $count = 0
  $new = $rx.Replace($txt,{ param($m) $script:count++; $Replacement }, $(if($Single){1}else{[int]::MaxValue}))
  if($count -gt 0){ Set-Text $Path $new; return $true } else { return $false }
}
function Test-ParseScript {
  param([string]$Path)
  $tokens=$null; $errors=$null
  [System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors) | Out-Null
  return @{Ok = ($errors.Count -eq 0); Errors=$errors}
}

function Get-SpecHash { param([string]$SpecPath) (Get-FileHash -Algorithm SHA256 $SpecPath).Hash }
function Read-Ledger {
  $p = Join-Path $PSScriptRoot '..\patches\registry.json'
  if(!(Test-Path $p)){ '{"applied":[]}' | Set-Content $p -Encoding UTF8 }
  return (Get-Content $p -Raw | ConvertFrom-Json -AsHashtable)
}
function Write-Ledger { param($Ledger)
  $p = Join-Path $PSScriptRoot '..\patches\registry.json'
  ($Ledger | ConvertTo-Json -Depth 8) | Set-Content $p -Encoding UTF8
}
function Update-Ledger {
  param([string]$Id,[string]$Name,[string]$Hash,[string]$Commit)
  $l = Read-Ledger
  if(-not $l.applied){ $l.applied = @() }
  $l.applied += @{ id=$Id; name=$Name; hash=$Hash; commit=$Commit; ts=(Get-Date).ToString('s') }
  Write-Ledger $l
}
function Is-Applied {
  param([string]$Id,[string]$Hash)
  $l = Read-Ledger
  return ($l.applied | Where-Object { $_.id -eq $Id -and $_.hash -eq $Hash }) -ne $null
}
function Test-PatchSpec {
  param($Spec)
  foreach($k in 'Id','Name','Steps'){ if(-not $Spec.ContainsKey($k)){ throw "Spec missing key: $k" } }
  foreach($s in $Spec.Steps){
    if(-not $s.Path){ throw "Step missing Path" }
    if(-not $s.Type){ throw "Step missing Type" }
  }
  return $true
}

Export-ModuleMember -Function * -Alias *
