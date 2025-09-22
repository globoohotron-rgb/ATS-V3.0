param([string]$Profile = 'vanilla')
$root   = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
$cfg    = Join-Path $root 'config\g5.costs.psd1'
if (-not (Test-Path $cfg)) { throw "Costs config not found: $cfg" }
$data = Import-PowerShellDataFile -Path $cfg
if (-not $data.Profiles.ContainsKey($Profile)) { throw "Profile '$Profile' not found in $cfg" }
$p = $data.Profiles[$Profile].Clone()
$p.DefaultProfile = $data.DefaultProfile
$p.Schema         = $data.Schema
$p.Profile        = $Profile
$p