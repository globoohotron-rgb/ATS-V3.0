[CmdletBinding()]
param(
  [string]$WFJsonPath,               # якщо не задано — шукаємо останній
  [string]$GuardCfgPath              # якщо не задано — config\g5.guardrails.psd1
)
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSCommandPath | Split-Path -Parent
if (-not $GuardCfgPath) { $GuardCfgPath = Join-Path $root 'config\g5.guardrails.psd1' }
$G = Import-PowerShellDataFile -Path $GuardCfgPath
$T = $G.Thresholds

function Find-LastWFJson {
  param([string]$runsRoot)
  $wf = Get-ChildItem (Join-Path $runsRoot '*') -Directory -ErrorAction SilentlyContinue |
        Get-ChildItem -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'wf-*' } |
        Sort-Object LastWriteTime | Select-Object -Last 1
  if (-not $wf) { throw "WF run folder not found under $runsRoot" }
  $json = Join-Path $wf.FullName 'g5\wf.results.json'
  if (-not (Test-Path $json)) { throw "wf.results.json not found in $($wf.FullName)\g5" }
  return $json
}

if (-not $WFJsonPath) { $WFJsonPath = Find-LastWFJson -runsRoot (Join-Path $root 'runs') }
$meta = Get-Content $WFJsonPath -Raw | ConvertFrom-Json

# базові значення
$gridN = @($meta.Grid).Count
$IS    = $meta.Aggregate.IS
$Best  = $meta.Aggregate.Best
$BH    = $meta.Aggregate.BH

# обчислення правил
$rules = @()

# R1: grid ≤ T.GridMax
$rules += [pscustomobject]@{
  Key='GridMax'; Desc="Grid ≤ $($T.GridMax)";
  Pass=($gridN -le $T.GridMax);
  Val=$gridN; Ref=$T.GridMax
}

# R2: OOS vs IS (PnL)
$passR2 = if($IS.PnL -gt 0){ $Best.PnL -ge ($T.PnL_OOS_vs_IS_Ratio * $IS.PnL) } else { $Best.PnL -ge $T.PnL_OOS_MinIfISNonPos }
$rules += [pscustomobject]@{
  Key='OOS_vs_IS_PnL'; Desc="OOS PnL vs IS (25%/≥0)";
  Pass=$passR2; Val=$Best.PnL; Ref= if($IS.PnL -gt 0){ ($T.PnL_OOS_vs_IS_Ratio * $IS.PnL) } else { $T.PnL_OOS_MinIfISNonPos }
}

# R3: Sharpe guard
$shOk   = if ($IS.Sharpe -gt 0) { $Best.Sharpe -ge ($T.Sharpe_OOS_vs_IS_Ratio * $IS.Sharpe) } else { $true }
$passR3 = ($Best.Sharpe -ge $T.Sharpe_OOS_Min) -and $shOk
$rules += [pscustomobject]@{
  Key='Sharpe'; Desc="OOS Sharpe ≥ 0 & ≥0.5×IS (якщо IS>0)";
  Pass=$passR3; Val=$Best.Sharpe; Ref= if($IS.Sharpe -gt 0){ ($T.Sharpe_OOS_vs_IS_Ratio * $IS.Sharpe) } else { $T.Sharpe_OOS_Min }
}

# R4: MaxDD guard
$rules += [pscustomobject]@{
  Key='MaxDD'; Desc="OOS MaxDD ≤ 1.5×IS + 2пп";
  Pass= ($Best.MaxDD -le ($T.MaxDD_OOS_vs_IS_Mult*$IS.MaxDD + $T.MaxDD_OOS_vs_IS_Add));
  Val=$Best.MaxDD; Ref= ($T.MaxDD_OOS_vs_IS_Mult*$IS.MaxDD + $T.MaxDD_OOS_vs_IS_Add)
}

# R5: Проти BH (PnL)
$rules += [pscustomobject]@{
  Key='OOS_vs_BH'; Desc="OOS PnL ≥ BH − 2пп";
  Pass= ($Best.PnL -ge ($BH.PnL + $T.OOS_vs_BH_PnL_MinDiff));
  Val=$Best.PnL; Ref= ($BH.PnL + $T.OOS_vs_BH_PnL_MinDiff)
}

$allPass = -not ($rules | Where-Object { -not $_.Pass })

$verdict = [pscustomobject]@{
  When = (Get-Date)
  Verdict = if($allPass){ 'ACCEPT' } else { 'REJECT' }
  Why = @($rules | ForEach-Object {
    if($_.Pass){ "PASS: $($_.Key)" } else { "FAIL: $($_.Key) — Val=$([math]::Round($_.Val,6)) vs Req=$([math]::Round($_.Ref,6))" }
  })
  Summary = [pscustomobject]@{
    Grid=$gridN
    IS=$IS; OOS=$Best; BH=$BH
  }
  SourceJson = $WFJsonPath
}
return $verdict