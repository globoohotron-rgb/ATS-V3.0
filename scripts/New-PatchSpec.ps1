param(
  [Parameter(Mandatory)][string]$Name,
  [string]$DependsOn
)
$ErrorActionPreference='Stop'
$id = (Get-Date -Format "yyyyMMdd") + "-" + (Get-Random -Minimum 100 -Maximum 999)
$path = Join-Path (Join-Path $PSScriptRoot '..\tools\patches') "$id-$($Name -replace '\s+','_').psd1"
$spec = @"
@{
  Id    = '$id'
  Name  = '$Name'
  DependsOn = @($([string]::IsNullOrWhiteSpace($DependsOn) ? '' : "'$DependsOn'"))
  Steps = @(
    # @{
    #   Type = 'EnsureBlock'; Path = 'run.ps1';
    #   Start = '# >> MY-BLOCK-START'; End = '# << MY-BLOCK-END';
    #   Lines = @('echo hello')
    # }
  )
  QC = @{
    Command = '.\scripts\selftest.ps1'
    Args    = @()
  }
}
"@
Set-Content $path $spec -Encoding UTF8
Write-Host "Spec created: $path"
