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


Import-Module (Join-Path $root 'scripts/ats.env.psm1') -Force
Publish-ATSEnvGlobals
$runner = Join-Path $root "run.ps1"
if (!(Test-Path -LiteralPath $runner)) { throw "Runner not found: $runner" }

# Явно прокидуємо -Gate і все інше як є
& $runner -Gate $Gate @Rest

# Після ранeру — збережемо snapshot конфіга в репорт
try {
    $reportsDir = if ($cfg.Paths.Reports) { Join-Path $root $cfg.Paths.Reports } else { Join-Path $root "reports" }
    if (!(Test-Path -LiteralPath $reportsDir)) { New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null }
    $latest = (Get-ChildItem $reportsDir -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1)
    $target = if ($latest) { $latest.FullName } else { $reportsDir }
    Save-ATSConfigSnapshot -OutDir $target
} catch {
    Write-Warning "Config snapshot failed: $($_.Exception.Message)"
}

