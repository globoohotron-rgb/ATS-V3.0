#requires -Version 7
param(
  [double]$Bps,                 # якщо не задано — візьмемо з scripts/config.psd1
  [string]$RunPath              # якщо не задано — візьмемо останній run-*/ у runs/
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Say($msg, $level="INFO") {
  $ts = Get-Date -Format "HH:mm:ss"
  switch ($level) {
    "ERR"  { Write-Host "$ts [$level] $msg" -ForegroundColor Red }
    "WARN" { Write-Host "$ts [$level] $msg" -ForegroundColor Yellow }
    default{ Write-Host "$ts [$level] $msg" -ForegroundColor Green }
  }
}

# === 0) Bps з конфігу, якщо не передали
if (-not $PSBoundParameters.ContainsKey('Bps')) {
  $cfgPath = "scripts/config.psd1"
  if (Test-Path $cfgPath) {
    $cfg = Import-PowerShellDataFile $cfgPath
    if ($cfg.ContainsKey('TxCostBps')) { $Bps = [double]$cfg.TxCostBps }
  }
  if (-not $Bps) { $Bps = 8 }  # дефолт
}
Say "TxCostBps = $Bps bps"

# === 1) Знаходимо потрібний run
if (-not $RunPath) {
  $RunPath = Get-ChildItem .\runs -Directory -Recurse |
    Where-Object { $_.Name -like 'run-*' } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 -ExpandProperty FullName
}
if (-not $RunPath) { Say "Не знайшов run-*/ у runs/" "ERR"; exit 2 }
Say "RunPath = $RunPath"

# === 2) Пошук таблиці угод
$candidates = @("trades.csv","fills.csv","orders.csv")
$tradeCsv = $null
foreach ($name in $candidates) {
  $hit = Get-ChildItem -Path $RunPath -Recurse -Filter $name -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($hit) { $tradeCsv = $hit.FullName; break }
}
if (-not $tradeCsv) { Say "Не знайшов trades/fills/orders CSV усередині run. Пропущу застосування витрат." "WARN"; exit 0 }
Say "Trades source: $tradeCsv"

# === 3) Завантажуємо CSV і намагаємось визначити колонки
$rows = Import-Csv -Path $tradeCsv
if ($rows.Count -eq 0) { Say "Порожній CSV для угод." "WARN"; exit 0 }

# спробуємо знайти поля ціни/кількості/напрямку
$cols = ($rows[0].PSObject.Properties | ForEach-Object Name)
function HasCol($n) { return $cols -contains $n }

# типові назви:
$priceCol = @('Price','FillPrice','ExecPrice','AvgPrice') | Where-Object { HasCol $_ } | Select-Object -First 1
$qtyCol   = @('Qty','Quantity','Size','Filled','ExecQty') | Where-Object { HasCol $_ } | Select-Object -First 1
$sideCol  = @('Side','Direction','Action')               | Where-Object { HasCol $_ } | Select-Object -First 1

if (-not $priceCol -or -not $qtyCol) {
  Say "Не вдалося визначити колонки ціни/кількості. Доступні: $($cols -join ', ')" "WARN"
  exit 0
}

# === 4) Рахуємо оборот та витрати
$totalTurnover = 0.0
foreach ($r in $rows) {
  $price = [double]($r.$priceCol)
  $qty   = [double]($r.$qtyCol)
  # якщо є direction (BUY/SELL) — беремо модуль; витрата не залежить від напряму
  $turn  = [math]::Abs($price * $qty)
  $totalTurnover += $turn
}
$txCost = $totalTurnover * ($Bps / 10000.0)

Say ("Total turnover = {0:n2}" -f $totalTurnover)
Say ("Tx cost        = {0:n2}" -f $txCost)

# === 5) Звітні файли: txcost.json + report_tx.html
$txJsonPath = Join-Path $RunPath "txcost.json"
$payload = [ordered]@{
  TxCostBps      = $Bps
  TotalTurnover  = [math]::Round($totalTurnover,2)
  TxCost         = [math]::Round($txCost,2)
  SourceCsv      = $tradeCsv
  GeneratedAt    = (Get-Date).ToString("s")
}
$payload | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -Path $txJsonPath
Say "Saved: $txJsonPath"

# шукаємо report.html поруч
$report = Get-ChildItem -Path $RunPath -Recurse -Filter report.html -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($report) {
  $html = Get-Content $report.FullName -Raw -Encoding UTF8
  $inject = @"
<!-- injected: txcost -->
<section style=""border:1px solid #ddd;padding:12px;margin-top:12px"">
  <h3>Transaction Costs</h3>
  <p><b>Bps:</b> $Bps</p>
  <p><b>Total turnover:</b> $([math]::Round($totalTurnover,2))</p>
  <p><b>Tx cost (currency units):</b> $([math]::Round($txCost,2))</p>
  <p><i>Note:</i> оцінка на основі CSV угод ($($payload.SourceCsv)).</p>
</section>
"@
  $out = $html + "`r`n" + $inject
  $outPath = Join-Path $report.DirectoryName "report_tx.html"
  $out | Set-Content -Encoding UTF8 -Path $outPath
  Say "Saved: $outPath"
} else {
  Say "report.html не знайдено — пропускаю HTML-ін’єкцію" "WARN"
}

Say "Tx-costs applied (post-processing)."
