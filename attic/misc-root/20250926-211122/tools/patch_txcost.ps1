#requires -Version 7
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$mod = ".\scripts\ats.psm1"
if (-not (Test-Path $mod)) { throw "Не знайдено $mod" }

# резервна копія
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
Copy-Item $mod "$mod.bak.$stamp" -Force

# якщо вже патчено — нічого не робимо
$txt = Get-Content $mod -Raw -Encoding UTF8
if ($txt -match '# === TXCOST HELPERS START ===') {
  Write-Host "Tx-хелпери вже присутні у scripts/ats.psm1 — пропускаю." -ForegroundColor Yellow
  exit 0
}

$block = @"
# === TXCOST HELPERS START ===
# Внутрішня підтримка транзакційних витрат для бек-тесту (trade PnL / turnover×bps).
# Нічого не чіпає за замовчуванням; викликається з executor/monitor.

function Get-AtsConfigTxBps {
  param([double]$OverrideBps)
  if ($PSBoundParameters.ContainsKey('OverrideBps') -and $OverrideBps) { return [double]$OverrideBps }
  \$cfgPath = Join-Path \$PSScriptRoot 'config.psd1'
  if (Test-Path \$cfgPath) {
    \$cfg = Import-PowerShellDataFile \$cfgPath
    if (\$cfg.ContainsKey('TxCostBps')) { return [double]\$cfg.TxCostBps }
  }
  return 8  # дефолт 8 bps
}

function Resolve-TxColumns {
  param([object]$Row)
  \$names = \$Row.PSObject.Properties | ForEach-Object Name
  \$price = @('Price','FillPrice','ExecPrice','AvgPrice') | Where-Object { \$names -contains \$_ } | Select-Object -First 1
  \$qty   = @('Qty','Quantity','Size','Filled','ExecQty') | Where-Object { \$names -contains \$_ } | Select-Object -First 1
  \$pnl   = @('PnL','Pnl','Profit','NetProfit') | Where-Object { \$names -contains \$_ } | Select-Object -First 1
  return [ordered]@{ Price=\$price; Qty=\$qty; PnL=\$pnl }
}

function Get-TxTurnover {
  param([IEnumerable]$Trades, [string]$PriceCol, [string]$QtyCol)
  if (-not \$Trades) { return 0.0 }
  \$sum = 0.0
  foreach (\$t in \$Trades) {
    \$price = [double](\$t.\$PriceCol)
    \$qty   = [double](\$t.\$QtyCol)
    \$sum  += [math]::Abs(\$price * \$qty)
  }
  return \$sum
}

function Get-TxCost {
  param([double]$Turnover, [double]$Bps)
  return \$Turnover * (\$Bps / 10000.0)
}

function Add-TxCostToTrades {
  param(
    [IEnumerable]$Trades,
    [double]$Bps,
    [string]$PriceCol,
    [string]$QtyCol
  )
  if (-not \$Trades) { return @() }
  \$out = @()
  foreach (\$t in \$Trades) {
    \$p = [double](\$t.\$PriceCol); \$q = [double](\$t.\$QtyCol)
    \$turn = [math]::Abs(\$p * \$q)
    \$tx   = \$turn * (\$Bps/10000.0)
    \$obj  = [PSCustomObject]@{}
    \$t.PSObject.Properties | ForEach-Object { \$obj | Add-Member NoteProperty \$_\.Name \$_\.Value }
    \$obj | Add-Member NoteProperty TxTurnover ([math]::Round(\$turn,6))
    \$obj | Add-Member NoteProperty TxBps      ([math]::Round(\$Bps,6))
    \$obj | Add-Member NoteProperty TxCost     ([math]::Round(\$tx,6))
    if (\$obj.PSObject.Properties.Name -contains 'PnL') {
      \$obj | Add-Member NoteProperty NetPnL ([double]\$obj.PnL - [double]\$tx)
    }
    \$out += \$obj
  }
  return \$out
}

function Apply-TxToMetrics {
  <#
    .SYNOPSIS
      Коригує метрики стратегії з урахуванням Tx.
    .PARAMETER Metrics
      Hashtable/PSCustomObject з полями PnL, Sharpe, MaxDD, тощо.
    .PARAMETER Trades
      Колекція трейдів (для обчислення обороту).
    .PARAMETER Bps
      Bps; якщо не задано — береться з конфігу.
    .OUTPUTS
      Новий обʼєкт метрик з полями TxCost, PnLNet (і тим самим Sharpe, якщо передано Returns).
  #>
  param(
    [Parameter(Mandatory)]$Metrics,
    [Parameter(Mandatory)][IEnumerable]$Trades,
    [double]$Bps
  )
  \$bps = Get-AtsConfigTxBps -OverrideBps \$Bps
  \$cols = Resolve-TxColumns -Row (\$Trades | Select-Object -First 1)
  if (-not \$cols.Price -or -not \$cols.Qty) { return \$Metrics }  # немає потрібних колонок

  \$turn = Get-TxTurnover -Trades \$Trades -PriceCol \$cols.Price -QtyCol \$cols.Qty
  \$cost = Get-TxCost -Turnover \$turn -Bps \$bps

  # зібрати оновлені метрики
  \$m = [ordered]@{}
  if (\$Metrics -is [hashtable]) { \$Metrics.Keys | ForEach-Object { \$m[\$_]=\$Metrics[\$_] } }
  else { \$Metrics.PSObject.Properties | ForEach-Object { \$m[\$_.Name]=\$_.Value } }

  if (\$m.Contains('PnL')) { \$m['PnLNet'] = [double]\$m['PnL'] - [double]\$cost }
  \$m['TxCostBps'] = \$bps
  \$m['TxTurnover'] = [math]::Round(\$turn,2)
  \$m['TxCost'] = [math]::Round(\$cost,2)
  return [PSCustomObject]\$m
}

# Зручна обгортка — коли у бек-тесті є \$Trades і \$Metrics
function Use-TxInsideBacktest {
  param(
    [Parameter(Mandatory)][IEnumerable]$Trades,
    [Parameter(Mandatory)]$Metrics,
    [double]$Bps
  )
  # 1) якщо є PnL у трейді — додаємо NetPnL на кожний трейд (не обов'язково)
  \$bps = Get-AtsConfigTxBps -OverrideBps \$Bps
  \$cols = Resolve-TxColumns -Row (\$Trades | Select-Object -First 1)
  if (\$cols.Price -and \$cols.Qty) {
    \$null = Add-TxCostToTrades -Trades \$Trades -Bps \$bps -PriceCol \$cols.Price -QtyCol \$cols.Qty
  }
  # 2) коригуємо агреговані метрики
  return Apply-TxToMetrics -Metrics \$Metrics -Trades \$Trades -Bps \$bps
}
# === TXCOST HELPERS END ===
"@

Add-Content -Path $mod -Value "`r`n$block" -Encoding UTF8
Write-Host "Патч додано в scripts/ats.psm1 ✔"
