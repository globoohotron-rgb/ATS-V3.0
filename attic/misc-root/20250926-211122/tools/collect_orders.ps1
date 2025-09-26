param(
  [string]$Date = (Get-Date -Format "yyyy-MM-dd"),
  [int]$DiagLimitPerFile = 100
)

function Find-RunDate { param([string]$d)
  $root = Join-Path (Get-Location) 'runs'
  $todayPath = Join-Path $root $d
  if (Test-Path $todayPath) { return $d }
  $cands = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match "^\d{4}-\d{2}-\d{2}$" } |
           Sort-Object Name -Descending
  if ($cands) { return $cands[0].Name }
  return $d
}

function Import-CsvAuto { param([string]$Path)
  $first = ''
  try { $first = Get-Content -Path $Path -TotalCount 1 -ErrorAction Stop } catch {}
  $delim = ','
  if ($first -and (($first.Split(';').Count - 1) -gt ($first.Split(',').Count - 1))) { $delim = ';' }
  return Import-Csv -Path $Path -Delimiter $delim
}

function Read-JsonRecords { param([string]$Path)
  $res = New-Object System.Collections.Generic.List[object]
  try {
    $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
    try {
      $obj = $raw | ConvertFrom-Json -ErrorAction Stop
      if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string])) { foreach($o in $obj){ $res.Add($o) } }
      else { $res.Add($obj) }
    } catch {
      Get-Content -Path $Path -ErrorAction Stop | ForEach-Object {
        $line = $_.Trim()
        if ($line.StartsWith('{') -or $line.StartsWith('[')) {
          try {
            $o = $line | ConvertFrom-Json -ErrorAction Stop
            if ($o -is [System.Collections.IEnumerable] -and -not ($o -is [string])) { foreach($x in $o){ $res.Add($x) } }
            else { $res.Add($o) }
          } catch {}
        }
      }
    }
  } catch {}
  return $res
}

function Flatten-Object {
  param($obj, [string]$prefix = '')
  $list = New-Object System.Collections.Generic.List[pscustomobject]
  function Recurse([object]$o, [string]$p) {
    if ($o -is [System.Collections.IDictionary]) {
      foreach ($k in $o.Keys) { Recurse $o[$k] ($p + ($(if($p){'.'}else{''})) + [string]$k) }
      return
    }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
      foreach ($prop in $o.PSObject.Properties) {
        Recurse $o.($prop.Name) ($p + ($(if($p){'.'}else{''})) + [string]$prop.Name)
      }
      return
    }
    if ($o -is [System.Collections.IEnumerable] -and -not ($o -is [string])) {
      $i = 0
      foreach ($el in $o) { Recurse $el ($p + '['+$i+']'); $i++ }
      return
    }
    $list.Add([pscustomobject]@{ Path = $p; Value = $o })
  }
  Recurse $obj $prefix
  return $list
}

function Pick-ByRegex { param($flat, [string[]]$patterns)
  foreach ($pat in $patterns) {
    $m = $flat | Where-Object { $_.Path -match $pat } | Select-Object -First 1
    if ($m) { return $m.Value }
  }
  return $null
}

function Normalize-Side { param([string]$s)
  if([string]::IsNullOrWhiteSpace($s)){ return $null }
  $u=$s.Trim().ToUpper()
  if($u -match 'BUY|LONG|B|OPEN_BUY|BID|ASK_HIT|1|BUY_SIDE'){return 'BUY'}
  if($u -match 'SELL|SHORT|S|OPEN_SELL|ASK|BID_HIT|-1|SELL_SIDE'){return 'SELL'}
  return $u
}

function Normalize-Timestamp { param($v)
  if($null -eq $v){ return $null }
  try { ([datetime]::Parse($v,$null,[System.Globalization.DateTimeStyles]::AssumeUniversal)).ToString('yyyy-MM-ddTHH:mm:ssK') }
  catch { [string]$v }
}

$Date = Find-RunDate $Date
$runRoot = Join-Path (Get-Location) ("runs/$Date")
if (-not (Test-Path $runRoot)) { Write-Warning ("За дату {0} папки runs/{0} не знайдено." -f $Date); return }

# Діагностика: перелік файлів
$csvPatterns  = @('*order*.csv','*orders*.csv','*fill*.csv','*fills*.csv','*execution*.csv','*executions*.csv','*trade*.csv','*trades*.csv','*deal*.csv','*deals*.csv')
$jsonPatterns = @('*order*.json','*orders*.json','*fill*.json','*fills*.json','*execution*.json','*executions*.json','*trade*.json','*trades*.json','*deal*.json','*deals*.json','*.ndjson','*.log')

$csvFiles  = Get-ChildItem -Path $runRoot -Recurse -File -Include $csvPatterns  -ErrorAction SilentlyContinue
$jsonFiles = Get-ChildItem -Path $runRoot -Recurse -File -Include $jsonPatterns -ErrorAction SilentlyContinue

Write-Host ("Файли CSV: {0}" -f ( ($csvFiles|Measure-Object).Count ))
$csvFiles  | Select-Object -First 10 | ForEach-Object { $rel=$_.FullName.Substring((Get-Location).Path.Length).TrimStart('\','/'); Write-Host ("  - {0}" -f $rel) }
Write-Host ("Файли JSON/LOG: {0}" -f ( ($jsonFiles|Measure-Object).Count ))
$jsonFiles | Select-Object -First 10 | ForEach-Object { $rel=$_.FullName.Substring((Get-Location).Path.Length).TrimStart('\','/'); Write-Host ("  - {0}" -f $rel) }

if ((!$csvFiles -or $csvFiles.Count -eq 0) -and (!$jsonFiles -or $jsonFiles.Count -eq 0)) {
  Write-Warning ("Файли, схожі на ордери за {0} не знайдено." -f $Date); return
}

# Регекси
$tsPats    = @('(^|\.)(ts|timestamp|time|datetime|created_at|filled_at|exec_time|event_time|date)(\.|\[|$)')
$symPats   = @('(^|\.)(symbol|ticker|instrument|asset|secid|pair|market|sec|code|name)(\.|\[|$)')
$sidePats  = @('(^|\.)(side|action|direction|buy_sell|type|is_buy|is_sell|side_code|side_id|side_num)(\.|\[|$)')
$qtyPats   = @('(^|\.)(qty|quantity|size|amount|filled_qty|exec_qty|volume|units|contracts|shares)(\.|\[|$)')
$pricePats = @('(^|\.)(price|avg_price|fill_price|order_price|executed_price|exec_price|px|rate|unit_price|trade_price|execution_price|mark_price)(\.|\[|$)')

$rows = New-Object System.Collections.Generic.List[object]

# ---- CSV ----
foreach ($f in $csvFiles) {
  try {
    $csv = Import-CsvAuto -Path $f.FullName
    if (-not $csv) { continue }
    $rel = $f.FullName.Substring((Get-Location).Path.Length).TrimStart('\','/')
    $parts = $rel -split '[\\/]'; $runId = ($parts | Where-Object { $_ -like 'run-*' } | Select-Object -First 1); if(-not $runId){$runId='unknown-run'}

    foreach ($r in $csv) {
      $flat  = Flatten-Object $r
      $ts    = Pick-ByRegex $flat $tsPats
      $sym   = Pick-ByRegex $flat $symPats
      $side0 = Pick-ByRegex $flat $sidePats
      $qty   = Pick-ByRegex $flat $qtyPats
      $price = Pick-ByRegex $flat $pricePats

      $side = Normalize-Side ([string]$side0)
      if (-not $side -and $qty -ne $null -and $qty.ToString() -match '^[\-\d\.]+$') {
        if ([double]$qty -gt 0) { $side='BUY' } elseif ([double]$qty -lt 0) { $side='SELL' }
      }
      if (-not $side) {
        $isBuy  = Pick-ByRegex $flat @('(^|\.)(is_buy|buy|long)(\.|\[|$)')
        $isSell = Pick-ByRegex $flat @('(^|\.)(is_sell|short)(\.|\[|$)')
        if ($isBuy  -ne $null -and [string]$isBuy  -match '^(true|1)$') { $side='BUY' }
        elseif ($isSell -ne $null -and [string]$isSell -match '^(true|1)$') { $side='SELL' }
      }

      $obj = [pscustomobject]@{
        ts          = Normalize-Timestamp $ts
        symbol      = if ($sym) { [string]$sym } else { $null }
        side        = $side
        qty         = if ($qty -ne $null -and $qty.ToString() -match '^[\d\.\-]+$') { [double]$qty } else { $qty }
        price       = if ($price -ne $null -and $price.ToString() -match '^[\d\.\-]+$') { [double]$price } else { $price }
        run_id      = $runId
        source_file = $rel
      }
      if ($obj.symbol -and $obj.side) { $rows.Add($obj) }
    }
  } catch { Write-Warning ("CSV помилка {0}: {1}" -f $f.FullName, $_.Exception.Message) }
}

# ---- JSON/NDJSON/LOG ----
foreach ($f in $jsonFiles) {
  try {
    $items = Read-JsonRecords -Path $f.FullName
    if (-not $items -or $items.Count -eq 0) { continue }
    $rel = $f.FullName.Substring((Get-Location).Path.Length).TrimStart('\','/')
    $parts = $rel -split '[\\/]'; $runId = ($parts | Where-Object { $_ -like 'run-*' } | Select-Object -First 1); if(-not $runId){$runId='unknown-run'}

    foreach ($r in $items) {
      $flat  = Flatten-Object $r
      $ts    = Pick-ByRegex $flat $tsPats
      $sym   = Pick-ByRegex $flat $symPats
      $side0 = Pick-ByRegex $flat $sidePats
      $qty   = Pick-ByRegex $flat $qtyPats
      $price = Pick-ByRegex $flat $pricePats

      $side = Normalize-Side ([string]$side0)
      if (-not $side -and $qty -ne $null -and $qty.ToString() -match '^[\-\d\.]+$') {
        if ([double]$qty -gt 0) { $side='BUY' } elseif ([double]$qty -lt 0) { $side='SELL' }
      }
      if (-not $side) {
        $isBuy  = Pick-ByRegex $flat @('(^|\.)(is_buy|buy|long)(\.|\[|$)')
        $isSell = Pick-ByRegex $flat @('(^|\.)(is_sell|short)(\.|\[|$)')
        if ($isBuy  -ne $null -and [string]$isBuy  -match '^(true|1)$') { $side='BUY' }
        elseif ($isSell -ne $null -and [string]$isSell -match '^(true|1)$') { $side='SELL' }
      }

      $obj = [pscustomobject]@{
        ts          = Normalize-Timestamp $ts
        symbol      = if ($sym) { [string]$sym } else { $null }
        side        = $side
        qty         = if ($qty -ne $null -and $qty.ToString() -match '^[\d\.\-]+$') { [double]$qty } else { $qty }
        price       = if ($price -ne $null -and $price.ToString() -match '^[\d\.\-]+$') { [double]$price } else { $price }
        run_id      = $runId
        source_file = $rel
      }
      if ($obj.symbol -and $obj.side) { $rows.Add($obj) }
    }
  } catch { Write-Warning ("JSON/LOG помилка {0}: {1}" -f $f.FullName, $_.Exception.Message) }
}

if ($rows.Count -eq 0) { Write-Warning "Після нормалізації придатних рядків не лишилось."; return }

$destDir = Join-Path (Get-Location) "logs/orders"
if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }

$dest = Join-Path $destDir ("{0}.csv" -f $Date)
$rows | Export-Csv -Path $dest -NoTypeInformation -Encoding UTF8
Write-Host ("✓ Зібрано {0} ордерів -> {1}" -f $rows.Count, $dest)
