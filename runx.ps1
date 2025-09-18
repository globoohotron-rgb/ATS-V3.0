[CmdletBinding()]
param(
  [ValidateSet("All","G1","G2","G3","G4","G5","G6")]
  [string]$Gate = "All",
  [Parameter(ValueFromRemainingArguments=$true)]
  [string[]]$Rest
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $root "scripts/config.psm1") -Force
$cfg = Get-ATSConfig
Set-ATSProcessEnv -Cfg $cfg

$modDir = Join-Path $root "scripts"
$sep = [IO.Path]::PathSeparator
if (-not ($env:PSModulePath -split $sep | Where-Object { $_ -eq $modDir })) {
  $env:PSModulePath = "$modDir$sep$($env:PSModulePath)"
}

Import-Module (Join-Path $root "scripts/ats.env.psm1") -Force
Publish-ATSEnvGlobals

$runner = Join-Path $root "run.ps1"
if (!(Test-Path -LiteralPath $runner)) { throw "Runner not found: $runner" }
& $runner -Gate $Gate @Rest

try {
    $reportsDir = if ($cfg.Paths.Reports) { Join-Path $root $cfg.Paths.Reports } else { Join-Path $root "reports" }
    if (!(Test-Path -LiteralPath $reportsDir)) { New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null }
    $latest = Get-ChildItem $reportsDir -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    $target = if ($latest) { $latest.FullName } else { $reportsDir }

    Save-ATSConfigSnapshot -OutDir $target

    Import-Module (Join-Path $root "scripts/report.config.psm1") -Force
    $cfgHtml = New-ATSConfigHtml -ReportDir $target
    Add-ATSConfigToIndex -ReportDir $target
}
catch {
    Write-Warning ("Report post-hook failed: " + $_.Exception.Message)
}
