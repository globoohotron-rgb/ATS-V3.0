param([string]$Profile = 'std')
$root   = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
$wfCfg  = Join-Path $root 'config\g5.wf.psd1'
if (-not (Test-Path $wfCfg)) { throw "WF config not found: $wfCfg" }

$data = Import-PowerShellDataFile -Path $wfCfg
if (-not $data.Profiles.ContainsKey($Profile)) { throw "Profile '$Profile' not found in $wfCfg" }

# Збираємо результат + кілька зручних похідних
$p = $data.Profiles[$Profile].Clone()
$p.DefaultProfile = $data.DefaultProfile
$p.Schema         = $data.Schema
$p.Profile        = $Profile
$p