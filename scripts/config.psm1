function Get-ATSConfig {
    param([string]$Path = (Join-Path (Split-Path -Parent $PSCommandPath) 'config.psd1'))
    if (!(Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
    Import-PowerShellDataFile -Path $Path
}

function Set-ATSProcessEnv {
    param($Cfg)
    $env:ATS_SEED           = [string]$Cfg.General.Seed
    $env:ATS_MODE           = [string]$Cfg.General.Mode
    $env:ATS_TX_BPS         = [string]$Cfg.Costs.TxCostsBps
    $env:ATS_SLIPPAGE_BPS   = [string]$Cfg.Costs.SlippageBps
    $env:ATS_WF_TRAIN_DAYS  = [string]$Cfg.WalkForward.TrainDays
    $env:ATS_WF_OOS_DAYS    = [string]$Cfg.WalkForward.OOSDays
    $env:ATS_WF_WINDOWS     = [string]$Cfg.WalkForward.Windows
    $env:ATS_GRID_MAX       = [string]$Cfg.WalkForward.GridMax
    $env:ATS_DAILY_LIMIT    = [string]$Cfg.Risk.DailyLimit
    $env:ATS_MAX_DD         = [string]$Cfg.Risk.MaxDD
}

function Save-ATSConfigSnapshot {
    param([string]$OutDir)
    $cfg  = Get-ATSConfig
    if (!(Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $json = $cfg | ConvertTo-Json -Depth 6
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $out = Join-Path $OutDir ("Config-Snapshot-$stamp.json")
    Set-Content -Path $out -Value $json -Encoding UTF8 -NoNewline
    Write-Host "Saved: $out"
}

Export-ModuleMember -Function Get-ATSConfig,Set-ATSProcessEnv,Save-ATSConfigSnapshot
