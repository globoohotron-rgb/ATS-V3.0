param([switch]$DryRun,[switch]$Force,[switch]$AutoStash)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '..\tools\patchkit.psm1') -Force

$specs = Get-ChildItem (Join-Path $PSScriptRoot '..\tools\patches') -Filter *.psd1 | Sort-Object Name
# simple dependency resolver
$map = @{}; $deps = @{}
foreach($s in $specs){
  $d = Import-PowerShellDataFile -Path $s.FullName
  $map[$d.Id] = $s.FullName
  $deps[$d.Id] = @($d.DependsOn)  # can be $null
}
$done = New-Object System.Collections.Generic.HashSet[string]
$left = [System.Collections.Generic.List[string]]($map.Keys)

while($left.Count -gt 0){
  $progress = $false
  foreach($id in @($left)){
    $need = @($deps[$id]) | Where-Object { $_ } 
    if(($need | Where-Object { -not $done.Contains($_) }).Count -eq 0){
      $spec = $map[$id]
      Write-Host "==> $id  ($spec)"
      pwsh -File (Join-Path $PSScriptRoot 'patch.ps1') -Spec $spec -Force:$Force -DryRun:$DryRun -AutoStash:$AutoStash
      $done.Add($id) | Out-Null
      $left.Remove($id)
      $progress = $true
    }
  }
  if(-not $progress){ throw "Cyclic or missing dependencies among specs: $($left -join ', ')" }
}
Write-Host "All specs processed."
