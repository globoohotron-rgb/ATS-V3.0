using namespace System.Globalization

function Get-ShadowConfig {
    $cfgPath = Join-Path $PSScriptRoot 'config.psd1'
    $defaults = [ordered]@{
        Days                      = 7
        ToleranceMinutes          = 15
        TrackingErrorBudgetBps    = 50
        SlippageBudgetBps         = 20
        ReportDirRoot             = (Resolve-Path (Join-Path $PSScriptRoot '..\reports')).Path
    }
    if (Test-Path $cfgPath) {
        try { return ($defaults + (Import-PowerShellDataFile -Path $cfgPath)) }
        catch { Write-Warning "config.psd1 parse failed, using defaults. $($_.Exception.Message)"; return $defaults }
    }
    return $defaults
}

function Get-DateDirs([int]$Days) {
    $runsRoot = Resolve-Path (Join-Path $PSScriptRoot '..\runs')
    if (-not (Test-Path $runsRoot)) { return @() }
    $cut = (Get-Date).Date.AddDays(-$Days)
    Get-ChildItem -Path $runsRoot -Directory |
      Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } |
      Where-Object { [datetime]::ParseExact($_.Name,'yyyy-MM-dd',$null) -ge $cut } |
      Sort-Object Name -Descending
}

function Find-Csv([string]$dir, [string[]]$nameHints) {
    $pat = ($nameHints | ForEach-Object { [regex]::Escape($_) }) -join '|'
    Get-ChildItem -Path $dir -Recurse -File -Filter '*.csv' |
      Where-Object { $_.Name -match $pat }
}
function Find-Json([string]$dir, [string[]]$nameHints) {
    $pat = ($nameHints | ForEach-Object { [regex]::Escape($_) }) -join '|'
    Get-ChildItem -Path $dir -Recurse -File -Filter '*.json' |
      Where-Object { $_.Name -match $pat }
}

function ConvertTo-DateTime([object]$v) {
    if ($null -eq $v) { return $null }
    if ($v -is [datetime]) { return $v }
    $s = [string]$v

    # numeric -> unix time
    if ($s -match '^\d+(\.\d+)?$') {
        $num = [double]$s
        try {
            if ($num -gt 1e11) { return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$num).LocalDateTime }
            elseif ($num -gt 1e9) { return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$num).LocalDateTime }
            elseif ($num -gt 1e5) { return [DateTimeOffset]::FromUnixTimeSeconds([int64][math]::Floor($num)).LocalDateTime }
        } catch {}
    }

    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal

    # common exact formats (ISO-like)
    $fmts = @(
        'o',                       # 2025-09-24T18:05:17.1234567Z
        "yyyy-MM-dd'T'HH:mm:ss.fff'Z'",
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        'yyyy-MM-dd HH:mm:ss.fff',
        'yyyy-MM-dd HH:mm:ss',
        'yyyy-MM-dd'
    )
    foreach ($f in $fmts) {
        try { return [datetime]::ParseExact($s, $f, $ci, $styles) } catch {}
    }

    # relaxed parse
    try { return [datetime]::Parse($s, $ci) } catch {}
    try { return [datetime]::Parse($s) } catch {}
    return $null
}

function Normalize-Row($row) {
    $map = @{}
    foreach ($prop in $row.PSObject.Properties) {
        $n = ($prop.Name -as [string]).ToLower()
        switch -Regex ($n) {
            '^(time|timestamp|date|datetime|ts|t|created(_|-)?at)$' { $map.Time = $prop.Value; continue }
            '^(symbol|ticker|asset|secid|instrument)$'              { $map.Symbol = $prop.Value; continue }
            '^(side|action|signal|dir|direction)$'                  { $map.Side = $prop.Value; continue }
            '^(qty|quantity|size|shares|amount)$'                   { $map.Qty = $prop.Value; continue }
            '^(price|signalprice|px|avg(px|price)|avg_price)$'      { $map.Price = $prop.Value; continue }
            '^(fill(price)?|fillpx|execution(price|px)?|avgfill(px|price)?)$' { $map.FillPrice = $prop.Value; continue }
            '^(target|position)$'                                   { $map.Target = $prop.Value; continue }
        }
    }

    $dt = ConvertTo-DateTime $map.Time
    $sym = if ($map.Symbol) { [string]$map.Symbol } else { $null }
    $sideRaw = if ($map.Side) { [string]$map.Side } else { $null }
    $qty  = if ($map.Qty)  { [double]$map.Qty }  else { $null }
    $px   = if ($map.Price){ [double]$map.Price }else { $null }
    $fill = if ($map.FillPrice) { [double]$map.FillPrice } else { $null }
    $tgt  = if ($map.Target){ [double]$map.Target } else { $null }

    # Canonical side: +1 buy/long, -1 sell/short, 0 none
    $side = 0
    if ($sideRaw) {
        $s = $sideRaw.ToLower()
        if ($s -match 'buy|long|enter\+|up|open(l| long)?') { $side = 1 }
        elseif ($s -match 'sell|short|exit|down|close')     { $side = -1 }
    } elseif ($tgt) {
        if ([double]$tgt -gt 0) { $side = 1 }
        elseif ([double]$tgt -lt 0) { $side = -1 }
    } elseif ($qty) {
        if ($qty -gt 0) { $side = 1 }
        elseif ($qty -lt 0) { $side = -1 }
    }

    [pscustomobject]@{
        Time      = if ($dt) { $dt } else { $null }
        Symbol    = $sym
        Side      = $side
        Qty       = $qty
        Price     = $px
        FillPrice = $fill
        Target    = $tgt
        Raw       = $row
    }
}

function Read-CsvTable([string]$path) {
    (Import-Csv -Path $path) | ForEach-Object { Normalize-Row $_ } |
        Where-Object { $_.Time -ne $null -and $_.Symbol } |
        Sort-Object Time
}

function Read-JsonRecords([string]$path) {
    try {
        $raw = Get-Content -Raw -Path $path
        $obj = $raw | ConvertFrom-Json
        if ($obj -is [System.Collections.IEnumerable]) { return $obj }
        $cand = $obj.PSObject.Properties |
          Where-Object { $_.Value -is [System.Collections.IEnumerable] } |
          Sort-Object { ($_.Value | Measure-Object).Count } -Descending |
          Select-Object -First 1
        if ($cand) { return $cand.Value }
        return ,$obj
    } catch {
        # NDJSON fallback
        $out=@()
        Get-Content -Path $path | ForEach-Object {
            $line=$_.Trim()
            if ($line.Length -gt 0) {
                try { $out += ($line | ConvertFrom-Json) } catch {}
            }
        }
        return $out
    }
}
function Read-JsonTable([string]$path) {
    (Read-JsonRecords -path $path) | ForEach-Object { Normalize-Row $_ } |
        Where-Object { $_.Time -ne $null -and $_.Symbol } |
        Sort-Object Time
}

function Read-AnyTable([string]$path) {
    if ($path.ToLower().EndsWith('.csv')) { return Read-CsvTable -path $path }
    elseif ($path.ToLower().EndsWith('.json')) { return Read-JsonTable -path $path }
    else { return @() }
}

function Load-Day([string]$dayDir) {
    $runs = Get-ChildItem -Path $dayDir -Directory -Filter 'run-*' | Sort-Object Name
    $signals = @(); $orders = @()
    foreach ($r in $runs) {
        $sigFiles = @(Find-Csv $r.FullName @('signal','signals','target','position'); Find-Json $r.FullName @('signal','signals','target','position'))
        $ordFiles = @(Find-Csv $r.FullName @('order','orders','exec','executor','execution','fills','paper','trade');
                       Find-Json $r.FullName @('order','orders','exec','executor','execution','fills','paper','trade'))
        foreach ($f in $sigFiles) { $signals += Read-AnyTable $f.FullName }
        foreach ($f in $ordFiles) { $orders  += Read-AnyTable $f.FullName }
    }
    [pscustomobject]@{ Signals = $signals; Orders = $orders }
}

function Match-OrdersToSignals($signals, $orders, [int]$tolMin) {
    $ordersBySym = $orders | Group-Object Symbol -AsHashTable -AsString
    $matches = @()
    foreach ($s in $signals) {
        if ($s.Side -eq 0) { continue }
        if (-not $ordersBySym.ContainsKey($s.Symbol)) {
            $matches += [pscustomobject]@{ Signal=$s; Order=$null; Matched=$false; SlippageBps=$null }
            continue
        }
        $candidates = $ordersBySym[$s.Symbol] | Where-Object {
            $_.Side -eq $s.Side -and [math]::Abs(($_.Time - $s.Time).TotalMinutes) -le $tolMin
        }
        if (-not $candidates) {
            $matches += [pscustomobject]@{ Signal=$s; Order=$null; Matched=$false; SlippageBps=$null }
            continue
        }
        $best = $candidates | Sort-Object @{e={ [math]::Abs(($_.Time - $_.Signal.Time).TotalSeconds) }} -Descending:$false | Select-Object -First 1
        $fill = if ($best.FillPrice) { $best.FillPrice } else { $best.Price }
        $sigPx = if ($s.Price) { $s.Price } else { $fill }
        $dir = if ($s.Side -ge 0) { 1.0 } else { -1.0 }
        $bps = if ($sigPx -and $fill) { 10000.0 * (($fill - $sigPx) * $dir) / [math]::Max([math]::Abs($sigPx), 1e-9) } else { $null }

        $matches += [pscustomobject]@{ Signal=$s; Order=$best; Matched=$true; SlippageBps=$bps }
    }
    $matches
}

function Summarize-Matches($matches,[double]$budgetSlip,[double]$budgetTE) {
    $total   = ($matches | Measure-Object).Count
    $filled  = ($matches | Where-Object Matched).Count
    $fillRate = if ($total) { [math]::Round(100.0 * $filled / $total,2) } else { 0 }

    $slips = $matches | Where-Object { $_.Matched -and $_.SlippageBps -ne $null } | Select-Object -ExpandProperty SlippageBps
    $avgSlip = if ($slips) { [math]::Round(($slips | Measure-Object -Average).Average,2) } else { $null }
    $p95Slip = if ($slips) { [math]::Round(($slips | Sort-Object | Select-Object -Last [int]([math]::Ceiling(0.05*$slips.Count)))[-1],2) } else { $null }

    $misses = $matches | Where-Object { -not $_.Matched }
    $teProxyBps = if ($misses) { 100.0 * [math]::Min(1.0, $misses.Count / [math]::Max($total,1)) } else { 0.0 }

    [pscustomobject]@{
        TotalSignals      = $total
        MatchedSignals    = $filled
        FillRatePct       = $fillRate
        AvgSlippageBps    = $avgSlip
        P95SlippageBps    = $p95Slip
        TrackingErrorBps  = [math]::Round($teProxyBps,2)
        BudgetSlipBps     = $budgetSlip
        BudgetTEBps       = $budgetTE
        Misses            = $misses
    }
}

function Write-ShadowReport($summary, $matches, [string]$outPath) {
@"
<!DOCTYPE html>
<html lang="uk">
<head>
<meta charset="UTF-8">
<title>Shadow-live report</title>
<style>
 body { font-family: system-ui, Segoe UI, Arial; margin:24px; }
 h1 { margin: 0 0 8px 0; }
 .kpi { display:grid; grid-template-columns: repeat(3, minmax(220px, 1fr)); gap:12px; margin:16px 0 24px 0;}
 .card { border:1px solid #ddd; border-radius:12px; padding:12px; }
 .ok{background:#e8f8f0} .warn{background:#fff8e6} .bad{background:#ffecec}
 table { border-collapse: collapse; width:100%; }
 th, td { border:1px solid #e5e5e5; padding:8px; text-align:left; }
 th { background:#fafafa; }
 .muted{color:#666}
</style>
</head>
<body>
<h1>Shadow-live (paper) — операційна вірність</h1>
<p class="muted">Звіт зібрано $(Get-Date -Format 'yyyy-MM-dd HH:mm')</p>

<div class="kpi">
  <div class="card $(if($summary.FillRatePct -ge 95){'ok'}elseif($summary.FillRatePct -ge 85){'warn'}else{'bad'})">
    <div><b>Fill-rate</b></div>
    <div style="font-size:28px;"><b>$($summary.FillRatePct)%</b></div>
    <div class="muted">Ціль ≥ 95%</div>
  </div>
  <div class="card $(if($summary.AvgSlippageBps -le $summary.BudgetSlipBps){'ok'}elseif($summary.AvgSlippageBps -le ($summary.BudgetSlipBps*1.5)){'warn'}else{'bad'})">
    <div><b>Avg slippage</b></div>
    <div style="font-size:28px;"><b>$($summary.AvgSlippageBps) bps</b></div>
    <div class="muted">Бюджет ≤ $($summary.BudgetSlipBps) bps</div>
  </div>
  <div class="card $(if($summary.TrackingErrorBps -le $summary.BudgetTEBps){'ok'}elseif($summary.TrackingErrorBps -le ($summary.BudgetTEBps*1.5)){'warn'}else{'bad'})">
    <div><b>Tracking-error (proxy)</b></div>
    <div style="font-size:28px;"><b>$($summary.TrackingErrorBps) bps</b></div>
    <div class="muted">Бюджет ≤ $($summary.BudgetTEBps) bps</div>
  </div>
</div>

<h3>Неметчені сигнали (потенційні пропуски)</h3>
<table>
  <tr><th>Time</th><th>Symbol</th><th>Side</th><th>Price</th></tr>
  $(
    $summary.Misses | ForEach-Object {
      "<tr><td>$($_.Signal.Time)</td><td>$($_.Signal.Symbol)</td><td>$($_.Signal.Side)</td><td>$($_.Signal.Price)</td></tr>"
    } | Out-String
  )
</table>

<h3>Семпл змечених (до 50)</h3>
<table>
  <tr><th>Time (signal)</th><th>Symbol</th><th>Side</th><th>SigPx</th><th>FillPx</th><th>Δbps</th><th>Δt (sec)</th></tr>
  $(
    $matches | Where-Object Matched | Sort-Object { [math]::Abs(($_.Order.Time - $_.Signal.Time).TotalSeconds) } |
      Select-Object -First 50 | ForEach-Object {
        $sigPx = if ($_.Signal.Price){$_.Signal.Price}else{$_.Order.FillPrice}
        $fill  = if ($_.Order.FillPrice){$_.Order.FillPrice}else{$_.Order.Price}
        $dtSec = [int]([math]::Round( ($_.Order.Time - $_.Signal.Time).TotalSeconds ))
        "<tr><td>$($_.Signal.Time)</td><td>$($_.Signal.Symbol)</td><td>$($_.Signal.Side)</td><td>$sigPx</td><td>$fill</td><td>$([math]::Round($_.SlippageBps,2))</td><td>$dtSec</td></tr>"
      } | Out-String
  )
</table>

<p class="muted">v0.2 — свій парсер часу (без TryParse), JSON підтримка. Далі: позиційний tracking-error, weekly roll-up.</p>
</body>
</html>
"@ | Set-Content -Path $outPath -Encoding UTF8
}

function Invoke-Shadow {
    param([int]$Days,[int]$ToleranceMinutes)
    $cfg = Get-ShadowConfig
    if (-not $Days) { $Days = $cfg.Days }
    if (-not $ToleranceMinutes) { $ToleranceMinutes = $cfg.ToleranceMinutes }

    $dateDirs = Get-DateDirs -Days $Days
    if (-not $dateDirs) { Write-Warning "No runs/ date directories found for last $Days day(s)."; return $null }

    $allSignals=@(); $allOrders=@()
    foreach ($d in $dateDirs) {
        $loaded = Load-Day -dayDir $d.FullName
        $allSignals += $loaded.Signals
        $allOrders  += $loaded.Orders
    }

    if (-not $allSignals) { Write-Warning "No signals found."; return $null }
    if (-not $allOrders)  { Write-Warning "No orders found.";  return $null }

    $matches = Match-OrdersToSignals -signals $allSignals -orders $allOrders -tolMin $ToleranceMinutes
    $summary = Summarize-Matches -matches $matches -budgetSlip $cfg.SlippageBudgetBps -budgetTE $cfg.TrackingErrorBudgetBps

    $todayDir = Join-Path $cfg.ReportDirRoot (Get-Date -Format 'yyyy-MM-dd')
    New-Item -ItemType Directory -Path $todayDir -Force | Out-Null
    $outPath = Join-Path $todayDir 'shadow-live.html'
    Write-ShadowReport -summary $summary -matches $matches -outPath $outPath

    [pscustomobject]@{ Summary=$summary; OutPath=$outPath; Matches=$matches }
}

Export-ModuleMember -Function Invoke-Shadow
