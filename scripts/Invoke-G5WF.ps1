[CmdletBinding()]
param(
  [string]$WFProfile    = "std",
  [string]$CostsProfile = "vanilla",
  [string]$BenchProfile = "SPY",
  [string]$PricesCsv,
  [string]$OutDir
)

Set-StrictMode -Version Latest

# ---- repo root
$root = Split-Path -Parent $PSCommandPath | Split-Path -Parent

# ---- safe defaults (NO formatting inside param; NO colons in folder names)
if (-not $PricesCsv) {
  $PricesCsv = Join-Path $root 'data\raw\ohlcv_sample.csv'
}
if (-not $OutDir) {
  $date  = Get-Date -Format 'yyyy-MM-dd'
  $clock = Get-Date -Format 'HHmmss'
  $OutDir = Join-Path $root ("runs\{0}\wf-{1}\g5" -f $date, $clock)
}

# --- helpers (fallbacks у разі, якщо ats.psm1 недоступний) ---
function Get-SMA([double[]]$x,[int]$n){
  $N=$x.Length; $res = New-Object double[] $N; $sum=0.0
  for($i=0;$i -lt $N;$i++){
    $sum += $x[$i]
    if($i -ge $n){ $sum -= $x[$i-$n] }
    if($i -ge $n-1){ $res[$i] = $sum / $n } else { $res[$i] = [double]::NaN }
  }
  return $res
}
function Get-Std([double[]]$x){
  if(-not $x -or $x.Length -le 1){ return 0.0 }
  $m = ($x | Measure-Object -Average).Average
  $s = [math]::Sqrt( ($x | ForEach-Object { ($_-$m)*($_-$m) } | Measure-Object -Sum).Sum / [math]::Max(1,($x.Length-1)) )
  return [double]$s
}
function Get-MaxDD([double[]]$rets){
  $N=$rets.Length
  $eq = New-Object double[] ($N+1); $eq[0]=1.0
  for($i=0;$i -lt $N;$i++){ $eq[$i+1] = $eq[$i]*(1.0+$rets[$i]) }
  $peak= $eq[0]; $maxdd=0.0
  for($i=1;$i -lt $eq.Length;$i++){
    if($eq[$i] -gt $peak){ $peak=$eq[$i] }
    $dd = ($eq[$i]/$peak)-1.0
    if($dd -lt $maxdd){ $maxdd = $dd }
  }
  return -$maxdd
}

# --- load configs ---
$GetWF    = Join-Path $root 'scripts\Get-G5WF.ps1'
$GetCosts = Join-Path $root 'scripts\Get-G5Costs.ps1'
$GetBench = Join-Path $root 'scripts\Get-G5Benchmark.ps1'
if(-not (Test-Path $GetWF)){   throw "Get-G5WF.ps1 not found: $GetWF" }
if(-not (Test-Path $GetCosts)){throw "Get-G5Costs.ps1 not found: $GetCosts" }
if(-not (Test-Path $GetBench)){throw "Get-G5Benchmark.ps1 not found: $GetBench" }

$WF    = & $GetWF -Profile $WFProfile
$COSTS = & $GetCosts -Profile $CostsProfile
$BENCH = & $GetBench -Profile $BenchProfile

# --- load prices ---
if(-not (Test-Path $PricesCsv)){ throw "Prices CSV not found: $PricesCsv" }
$rows  = Import-Csv $PricesCsv
if(-not $rows){ throw "Empty CSV: $PricesCsv" }

# unify columns
$dtCol   = ('Date','date','DATE' | Where-Object { $rows[0].PSObject.Properties.Name -contains $_ })[0]
$closeCol= ('Close','close','CLOSE','AdjClose','Adj Close' | Where-Object { $rows[0].PSObject.Properties.Name -contains $_ })[0]
if(-not $dtCol -or -not $closeCol){ throw "CSV must have Date & Close columns; got: $($rows[0].PSObject.Properties.Name -join ', ')" }

$ts = $rows | ForEach-Object { [PSCustomObject]@{ Date = [datetime]$_.($dtCol); Close = [double]$_.($closeCol) } } | Sort-Object Date
$px = $ts.Close
if($px.Count -lt ($WF.TrainBars + $WF.OOSBars + 10)){ throw "Not enough bars for WF (have $($px.Count))" }

# --- build daily returns ---
$rets = New-Object double[] $px.Count
for($i=1;$i -lt $px.Count;$i++){ $rets[$i] = ($px[$i]/$px[$i-1])-1.0 }
$rets[0]=0.0

# --- small parameter grid (≤8) ---
$fastSet = @(5,10)
$slowSet = @(20,50)
$grid = @()
foreach($f in $fastSet){
  foreach($s in $slowSet){
    if($f -lt $s){ $grid += [PSCustomObject]@{ Fast=$f; Slow=$s } }
  }
}
if($grid.Count -gt 8){ throw "Grid too large: $($grid.Count) > 8 (guardrail)" }

# --- helpers to compute strategy returns (long/flat: SMAf>SMAg -> 1 else 0) ---
function Get-Pos([double[]]$px,[int]$f,[int]$s){
  $smaF = Get-SMA $px $f
  $smaS = Get-SMA $px $s
  $N=$px.Length
  $pos = New-Object double[] $N
  for($i=0;$i -lt $N;$i++){
    if([double]::IsNaN($smaF[$i]) -or [double]::IsNaN($smaS[$i])){ $pos[$i]=0.0 }
    else { $pos[$i] = $(if($smaF[$i] -gt $smaS[$i]){1.0}else{0.0}) }
  }
  return $pos
}
function Apply-Costs([double[]]$rets,[double[]]$pos,$COSTS){
  $N=$rets.Length
  $out = New-Object double[] $N
  $bpsTrade = ([double]$COSTS.SlippageBps + [double]$COSTS.SpreadBps) / 10000.0
  $dailyDisc = ([double]$COSTS.PnLDiscountBps / 10000.0) / 252.0
  $prev=0.0
  for($i=0;$i -lt $N;$i++){
    $r = $pos[[math]::Max(0,$i-1)] * $rets[$i]
    $turnover = [math]::Abs($pos[$i]-$prev)     # 0 -> 1 trade, 1 -> 1 trade
    $cost = $turnover * $bpsTrade
    $out[$i] = $r - $cost - $dailyDisc
    $prev = $pos[$i]
  }
  return $out
}
function Get-Metrics([double[]]$series){
  $ann=252.0
  $mu = ($series | Measure-Object -Average).Average
  $sd = Get-Std $series
  $sh = if($sd -gt 0){ ($mu/[double]$sd) * [math]::Sqrt($ann) } else { 0.0 }
  $pnl = ($series | Measure-Object -Sum).Sum
  $dd  = Get-MaxDD $series
  [PSCustomObject]@{ PnL=$pnl; Sharpe=$sh; MaxDD=$dd }
}

# --- WF split loop ---
$start = $WF.TrainBars
if($WF.Align -eq 'MonthStart'){
  for($j=$start; $j -lt $px.Count; $j++){
    if($ts[$j].Date.Day -le 3){ $start=$j; break }
  }
}
$windows = @()
$aggOOS  = @()
$aggBH   = @()

while(($start + $WF.OOSBars) -le $px.Count){
  $isBeg = $start - $WF.TrainBars
  $isEnd = $start - 1
  $oBeg  = $start
  $oEnd  = $start + $WF.OOSBars - 1

  # обрати параметри по IS (за Sharpe)
  $scores = @()
  for($g=0;$g -lt $grid.Count;$g++){
    $p = $grid[$g]
    $pos = Get-Pos $px $p.Fast $p.Slow
    $str = Apply-Costs $rets $pos $COSTS
    $isSlice = $str[$isBeg..$isEnd]
    $scores += [PSCustomObject]@{ G=$g; M=(Get-Metrics $isSlice) }
  }
  $best = $scores | Sort-Object { -$_.M.Sharpe } | Select-Object -First 1
  $gIdx = $best.G

  # OOS для best і сусідів
  $nbr = @($gIdx)
  for($k=1;$k -le [int]$WF.Neighbors;$k++){
    if($gIdx-$k -ge 0){ $nbr += ($gIdx-$k) }
    if($gIdx+$k -lt $grid.Count){ $nbr += ($gIdx+$k) }
  }
  $nbr = $nbr | Sort-Object -Unique

  $oosBestRet = @()
  $recN = @()
  foreach($gi in $nbr){
    $p = $grid[$gi]
    $pos = Get-Pos $px $p.Fast $p.Slow
    $str = Apply-Costs $rets $pos $COSTS
    $oosSlice = $str[$oBeg..$oEnd]
    $m = Get-Metrics $oosSlice
    $recN += [PSCustomObject]@{ Grid=$gi; Fast=$p.Fast; Slow=$p.Slow; PnL=$m.PnL; Sharpe=$m.Sharpe; MaxDD=$m.MaxDD }
    if($gi -eq $gIdx){ $oosBestRet = $oosSlice }
  }

  # BH
  $bhSlice = $rets[$oBeg..$oEnd]
  $mBest = Get-Metrics $oosBestRet
  $mBH   = Get-Metrics $bhSlice

  $windows += [PSCustomObject]@{
    IS_Beg = $ts[$isBeg].Date; IS_End = $ts[$isEnd].Date;
    OOS_Beg= $ts[$oBeg].Date;  OOS_End= $ts[$oEnd].Date;
    Best   = [PSCustomObject]@{ Grid=$gIdx; Fast=$grid[$gIdx].Fast; Slow=$grid[$gIdx].Slow; PnL=$mBest.PnL; Sharpe=$mBest.Sharpe; MaxDD=$mBest.MaxDD }
    Neigh  = $recN
    Bench  = [PSCustomObject]@{ PnL=$mBH.PnL; Sharpe=$mBH.Sharpe; MaxDD=$mBH.MaxDD }
  }

  $aggOOS += $oosBestRet
  $aggBH  += $bhSlice

  $start += [int]$WF.StepBars
}

# --- aggregate over all OOS windows ---
$aggM = Get-Metrics $aggOOS
$aggB = Get-Metrics $aggBH

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$csvPath = Join-Path $OutDir 'wf.oos.csv'
$jsonPath= Join-Path $OutDir 'wf.results.json'

# CSV
$rowsOut = foreach($w in $windows){
  [PSCustomObject]@{
    IS_Beg=$w.IS_Beg; IS_End=$w.IS_End; OOS_Beg=$w.OOS_Beg; OOS_End=$w.OOS_End;
    Best_Fast=$w.Best.Fast; Best_Slow=$w.Best.Slow;
    Best_PnL=$w.Best.PnL; Best_Sharpe=$w.Best.Sharpe; Best_MaxDD=$w.Best.MaxDD;
    BH_PnL=$w.Bench.PnL;  BH_Sharpe=$w.Bench.Sharpe;  BH_MaxDD=$w.Bench.MaxDD
  }
}
$rowsOut | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

# JSON summary
$meta = [PSCustomObject]@{
  When     = (Get-Date)
  Profiles = [PSCustomObject]@{ WF=$WFProfile; Costs=$CostsProfile; Bench=$BenchProfile }
  Grid     = $grid
  Windows  = $windows
  Aggregate= [PSCustomObject]@{
    Best = $aggM
    BH   = $aggB
  }
}
$meta | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8

Write-Host "[ok] WF done → $OutDir"