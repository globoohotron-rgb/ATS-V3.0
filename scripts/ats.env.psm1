function Get-ATSEnvMap {
    $map = [ordered]@{
        Seed          = [int]   ($env:ATS_SEED           ?? 42)
        Mode          = [string]($env:ATS_MODE           ?? "dev")
        TxCostsBps    = [double]($env:ATS_TX_BPS         ?? 10)
        SlippageBps   = [double]($env:ATS_SLIPPAGE_BPS   ?? 5)
        WF_TrainDays  = [int]   ($env:ATS_WF_TRAIN_DAYS  ?? 252)
        WF_OOSDays    = [int]   ($env:ATS_WF_OOS_DAYS    ?? 63)
        WF_Windows    = [int]   ($env:ATS_WF_WINDOWS     ?? 4)
        GridMax       = [int]   ($env:ATS_GRID_MAX       ?? 8)
        Risk_DailyLim = [double]($env:ATS_DAILY_LIMIT    ?? -0.02)
        Risk_MaxDD    = [double]($env:ATS_MAX_DD         ?? 0.08)
    }
    # конверт bps -> rate при потребі
    $map.TxRate      = [double]($map.TxCostsBps / 10000.0)
    $map.SlippageRt  = [double]($map.SlippageBps / 10000.0)
    [PSCustomObject]$map
}

function Publish-ATSEnvGlobals {
    $m = Get-ATSEnvMap
    $Global:ATS = $m
    $Global:ATS_SEED          = $m.Seed
    $Global:ATS_TX_BPS        = $m.TxCostsBps
    $Global:ATS_SLIPPAGE_BPS  = $m.SlippageBps
    $Global:ATS_WF_TRAIN_DAYS = $m.WF_TrainDays
    $Global:ATS_WF_OOS_DAYS   = $m.WF_OOSDays
    $Global:ATS_WF_WINDOWS    = $m.WF_Windows
    $Global:ATS_GRID_MAX      = $m.GridMax
    $Global:ATS_DAILY_LIMIT   = $m.Risk_DailyLim
    $Global:ATS_MAX_DD        = $m.Risk_MaxDD
    Write-Host "ATS ENV published → `$Global:ATS (+ convenience globals)."
}

Export-ModuleMember -Function Get-ATSEnvMap,Publish-ATSEnvGlobals
