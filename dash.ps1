<#  dash.ps1 — ATS-V3.0 Dashboard (v8.3)
    • Equity-спарклайн: шукаємо серію в CSV/JSON (equity/nav/balance/cum_pnl/…).
      Якщо знайдено лише pnl — рахуємо кумулятив.
      Даунсемпл до <= 400 точок, SVG 360x80, показуємо last і Δ%.
    • Решта (8.2b): метрики PnL/Sharpe/MaxDD, Scope, source, ігнор dashboard*.html.
#>

[CmdletBinding()]
param(
  [string]$ReportsRoot,
  [string]$GatesJournal,
  [ValidateSet('OOS','IS','AUTO')]
  [string]$Scope = 'OOS',
  [switch]$VerboseLog,
  [switch]$Open
)

$ErrorActionPreference = "Stop"

# --- корені
$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot) { $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ReportsRoot)   { $ReportsRoot   = Join-Path $ScriptRoot 'reports' }
if (-not $GatesJournal)  { $GatesJournal  = Join-Path $ScriptRoot 'docs\gates.md' }
$RunsRoot = Join-Path $ScriptRoot 'runs'

function Write-Info($msg) { if ($VerboseLog) { Write-Host "[dash] $msg" -ForegroundColor Cyan } }

function Ensure-ReportsRoot {
  if (-not (Test-Path $ReportsRoot)) {
    New-Item -ItemType Directory -Path $ReportsRoot -Force | Out-Null
    Write-Info "Створив $ReportsRoot"
  }
}

function Get-Or-CreateReportDate {
  $dirs = Get-ChildItem -Path $ReportsRoot -Directory -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } |
          Sort-Object Name -Descending
  if ($dirs) { return $dirs[0].Name }
  $today = Get-Date -Format 'yyyy-MM-dd'
  $path = Join-Path $ReportsRoot $today
  if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
  Write-Info "Не знайшов дат — створив $today"
  return $today
}

function Get-ReportLinks($dateFolder) {
  $path = Join-Path $ReportsRoot $dateFolder
  if (-not (Test-Path $path)) { return @() }
  Get-ChildItem -Path $path -Filter *.html -File -ErrorAction SilentlyContinue |
    Sort-Object Name |
    ForEach-Object { [pscustomobject]@{ Name = $_.Name; RelPath = (Join-Path $dateFolder $_.Name) } }
}

function Parse-GateVerdicts($journalPath) {
  if (-not (Test-Path $journalPath)) { return @() }
  $text = Get-Content -Path $journalPath -Raw
  $dateMatches = [regex]::Matches($text, '(?m)^\s{0,3}(?:[#-]+\s*)?(20\d{2}-\d{2}-\d{2}).*$')
  if ($dateMatches.Count -eq 0) {
    return (
      [regex]::Matches($text, '(G\d)\s*[:=]\s*(PASS|FAIL|ACCEPT|REJECT)', 'IgnoreCase') |
      ForEach-Object { [pscustomobject]@{ Gate=$_.Groups[1].Value; Verdict=$_.Groups[2].Value.ToUpper(); Date='—' } } |
      Select-Object -First 6
    )
  }
  $lastDate = $dateMatches[$dateMatches.Count-1].Groups[1].Value
  $tail = $text.Substring($dateMatches[$dateMatches.Count-1].Index)
  $pairs = [regex]::Matches($tail, '(G\d)\s*[:=]\s*(PASS|FAIL|ACCEPT|REJECT)', 'IgnoreCase')
  $items = foreach ($m in $pairs) {
    [pscustomobject]@{ Date=$lastDate; Gate=$m.Groups[1].Value; Verdict=$m.Groups[2].Value.ToUpper() }
  }
  $items | Sort-Object { [int]([regex]::Match($_.Gate, '\d+').Value) }
}

# ---------- 8.2: Метрики (як у v8.2b) ----------
function Normalize-Key([string]$k) {
  if (-not $k) { return $null }
  $kk = $k.Trim()
  switch -Regex ($kk) {
    '^(pnl|p\&l|profit(\s*and\s*loss)?|return|total[_\s-]*return|final[_\s-]*pnl|cum[_\s-]*pnl)$' { return 'PnL' }
    '^(sharpe|sharpe[_\s-]*ratio)$'                                                             { return 'Sharpe' }
    '^(max[_\s-]*(dd|drawdown)|maxdrawdown|maxdraw[_\s-]*down|mdd)$'                            { return 'MaxDD' }
    default { return $null }
  }
}
function Parse-Num([string]$raw) {
  if (-not $raw) { return $null }
  $s = $raw.Trim(); $isPct = $s -match '%'
  $s = $s -replace '[^\d\-\+\,\.eE]', ''; $s2 = $s -replace ',', '.'
  [double]$val = [double]::NaN
  if (-not [double]::TryParse($s2, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$val)) { return $null }
  [pscustomobject]@{ Value=$val; Suffix=$(if ($isPct) { '%' } else { '' }) }
}
function Fmt([object]$parsed) {
  if (-not $parsed -or -not $parsed.PSObject.Properties['Value']) { return '—' }
  $v = [double]$parsed.Value
  $out = if ([math]::Abs($v) -ge 100) { "{0:N0}" -f $v } elseif ([math]::Abs($v) -ge 10) { "{0:N2}" -f $v } else { "{0:N3}" -f $v }
  "$out$($parsed.Suffix)"
}

function Detect-ScopeFromName([string]$name) {
  $n = $name.ToLower()
  if ($n -match '(?:^|[\\/_\.-])(oos|out[_-]?of[_-]?sample|test)(?:[\\/_\.-]|$)') { return 'OOS' }
  if ($n -match '(?:^|[\\/_\.-])(is|in[_-]?sample|train)(?:[\\/_\.-]|$)')         { return 'IS'  }
  return 'UNK'
}

function Get-MetricFiles($dateFolder) {
  $roots = @((Join-Path $RunsRoot $dateFolder), (Join-Path $ReportsRoot $dateFolder)) | Where-Object { Test-Path $_ }
  $patterns = @('*.json','*.csv','*.html','*.htm','*.md')
  $prefer   = @('wf.results.json','wf.oos.csv','oos','result','summary','metrics','report','stats','backtest','g5','gate')
  $files = @()
  foreach ($root in $roots) { foreach ($pat in $patterns) { $files += Get-ChildItem -Path $root -Recurse -File -Include $pat -ErrorAction SilentlyContinue } }
  $files = $files | Where-Object { $_.Name.ToLower() -notmatch '^dashboard(_latest)?\.html$' }
  $files | ForEach-Object { $_ | Add-Member ScopeCandidate (Detect-ScopeFromName $_.FullName) -Force; $_ } |
    Sort-Object @{Expression={ if ($_.FullName -like (Join-Path $RunsRoot '*')) {0}else{1}}},
                 @{Expression={ if ($_.ScopeCandidate -eq 'OOS'){0}elseif ($_.ScopeCandidate -eq 'IS'){1}else{2} }},
                 @{Expression={ $name=$_.Name.ToLower(); - [int](@('wf.results.json','wf.oos.csv','oos','result','summary','metrics','report','stats','backtest') |
                   ForEach-Object { if ($name -like "*$_*"){1}else{0}} | Measure-Object -Sum | Select-Object -ExpandProperty Sum) }},
                 LastWriteTime -Descending
}

function Extract-FromJsonObj($obj, [string]$inScope='UNK') {
  $acc = @{}
  function Walk($node, [string]$scope) {
    if ($null -eq $node) { return }
    if ($node -is [System.Collections.IDictionary]) {
      foreach ($k in $node.Keys) {
        $kn = [string]$k; $v = $node[$k]; $scope2 = $scope
        if ($kn -match '(?i)^(oos|out[_\s-]*of[_\s-]*sample|test)$') { $scope2 = 'OOS' }
        elseif ($kn -match '(?i)^(is|in[_\s-]*sample|train)$')       { $scope2 = 'IS'  }
        $norm = Normalize-Key($kn)
        if ($norm) {
          if ($v -isnot [string]) { $v = "$v" }
          $pn = Parse-Num($v)
          if ($pn) { if (-not $acc[$scope2]) { $acc[$scope2] = @{} }; $acc[$scope2][$norm] = $pn }
        }
        Walk $v $scope2
      }
    } elseif ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
      foreach ($it in $node) { Walk $it $scope }
    }
  }
  Walk $obj $inScope; return $acc
}

function Extract-FromJsonFile($path) {
  try { $json = (Get-Content -Path $path -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
  $acc = Extract-FromJsonObj $json (Detect-ScopeFromName $path)
  if ($acc.Keys.Count -eq 0) { return $null }
  $out = @()
  foreach ($sc in $acc.Keys) {
    $bag = $acc[$sc]
    $score = @($bag['PnL'],$bag['Sharpe'],$bag['MaxDD']) | Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count
    if ($score -gt 0) { $out += [pscustomobject]@{ Source=$path; ScopeCandidate=$sc; PnL=$bag['PnL']; Sharpe=$bag['Sharpe']; MaxDD=$bag['MaxDD']; Score=$score } }
  }
  if ($out.Count -eq 0) { return $null } else { return $out }
}

function Extract-FromCsvFile($path) {
  try { $rows = Import-Csv -Path $path -ErrorAction Stop } catch { return $null }
  if (-not $rows) { return $null }
  $hdr = $rows[0].PSObject.Properties.Name
  $map = @{}
  foreach ($name in $hdr) { $norm = Normalize-Key($name); if ($norm -and -not $map[$norm]) { $map[$norm] = $name } }
  $vals = @{}
  if ($map.Count -gt 0) {
    $last = $rows[-1]
    foreach ($k in @('PnL','Sharpe','MaxDD')) { if ($map[$k]) { $vals[$k] = Parse-Num([string]$last.($map[$k])) } }
  } else {
    $mcol = $hdr | Where-Object { $_ -match '^(metric|name|key)$' } | Select-Object -First 1
    $vcol = $hdr | Where-Object { $_ -match '^(value|val|number)$' } | Select-Object -First 1
    if ($mcol -and $vcol) { foreach ($r in $rows) { $norm = Normalize-Key([string]$r.$mcol); if ($norm -and -not $vals[$norm]) { $vals[$norm] = Parse-Num([string]$r.$vcol) } } }
  }
  if ($vals.Count -eq 0) { return $null }
  [pscustomobject]@{ Source=$path; ScopeCandidate=(Detect-ScopeFromName $path); PnL=$vals['PnL']; Sharpe=$vals['Sharpe']; MaxDD=$vals['MaxDD'];
                     Score=@($vals['PnL'],$vals['Sharpe'],$vals['MaxDD']) | Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count }
}

function Gather-Candidates($files) {
  $cands = @()
  foreach ($f in $files) {
    $ext = $f.Extension.ToLower()
    $one = switch ($ext) {
      '.json' { Extract-FromJsonFile $f.FullName }
      '.csv'  { Extract-FromCsvFile  $f.FullName }
      default { # text
        $base = [System.IO.Path]::GetFileName($f.FullName).ToLower()
        if ($base -match '^dashboard(_latest)?\.html$') { $null } else {
          try { $txt = Get-Content -Path $f.FullName -Raw -ErrorAction Stop } catch { $txt = $null }
          if ($null -eq $txt) { $null } else {
            $vals = @{}
            $patterns = @{
              'PnL'   = '(?i)\b(PnL|profit(?:\s*and\s*loss)?|return|total\s*return|final\s*pnl)\b.{0,60}?([\-+]?\d+(?:[\.,]\d+)?(?:[eE][\-+]?\d+)?%?)'
              'Sharpe'= '(?i)\b(Sharpe(?:\s*ratio)?)\b.{0,40}?([\-+]?\d+(?:[\.,]\d+)?(?:[eE][\-+]?\d+)?)'
              'MaxDD' = '(?i)\b(Max(?:imum)?\s*(?:DD|Drawdown)|MDD)\b.{0,60}?([\-+]?\d+(?:[\.,]\d+)?(?:[eE][\-+]?\d+)?%?)'
            }
            foreach ($k in $patterns.Keys) { $m = [regex]::Match($txt, $patterns[$k]); if ($m.Success) { $vals[$k] = Parse-Num($m.Groups[2].Value) } }
            if ($vals.Count -eq 0) { $null } else {
              [pscustomobject]@{ Source=$f.FullName; ScopeCandidate=(Detect-ScopeFromName $f.FullName);
                                 PnL=$vals['PnL']; Sharpe=$vals['Sharpe']; MaxDD=$vals['MaxDD'];
                                 Score=@($vals['PnL'],$vals['Sharpe'],$vals['MaxDD']) | Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count }
            }
          }
        }
      }
    }
    if ($one) { $cands += $one }
  }
  $cands
}

function Choose-Best([object[]]$cands, [string]$scopeWanted) {
  if (-not $cands) { return $null }
  $pool = if ($scopeWanted -eq 'AUTO') { $cands } else { $cands | Where-Object { $_.ScopeCandidate -eq $scopeWanted } }
  if (-not $pool -or $pool.Count -eq 0) { $pool = $cands }
  $best = $pool | Sort-Object @{Expression={ - $_.Score }},
                          @{Expression={ if ($_.Source -like (Join-Path $RunsRoot '*')) {0}else{1} }},
                          @{Expression={ if ($_.ScopeCandidate -eq 'OOS'){0}elseif ($_.ScopeCandidate -eq 'IS'){1}else{2} }},
                          @{Expression={ - (Get-Item $_.Source).LastWriteTime.Ticks }} | Select-Object -First 1
  return $best
}

function Extract-Metrics($dateFolder) {
  $files = Get-MetricFiles -dateFolder $dateFolder
  Write-Info ("Кандидатів файлів: " + $files.Count)
  $found = Gather-Candidates $files
  if ($VerboseLog) { $found | Select-Object Source,ScopeCandidate,Score | Sort-Object Score -Descending | Select -First 10 |
    ForEach-Object { Write-Host ("[dash] cand: {0} | scope={1} | score={2}" -f $_.Source, $_.ScopeCandidate, $_.Score) -ForegroundColor DarkGray } }
  $best = Choose-Best $found $Scope
  if (-not $best) { return [pscustomobject]@{ PnL='—'; Sharpe='—'; MaxDD='—'; Source='—'; Scope='—' } }
  Write-Info ("Best source -> " + $best.Source + " (scope=" + $best.ScopeCandidate + ")")
  [pscustomobject]@{ PnL=Fmt $best.PnL; Sharpe=Fmt $best.Sharpe; MaxDD=Fmt $best.MaxDD; Source=$best.Source; Scope=$best.ScopeCandidate }
}

# ---------- 8.3: Equity series → SVG sparkline ----------
function Try-ParseDouble($s) {
  $s2 = [string]$s
  $s2 = $s2 -replace '[^\d\-\+\,\.eE]', ''
  $s2 = $s2 -replace ',', '.'
  [double]$v = [double]::NaN
  if ([double]::TryParse($s2, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $v } else { return $null }
}

function Downsample([double[]]$arr, [int]$maxN=400) {
  if ($arr.Count -le $maxN) { return ,$arr }
  $step = [math]::Ceiling($arr.Count / [double]$maxN)
  $out = New-Object System.Collections.Generic.List[double]
  for ($i=0; $i -lt $arr.Count; $i+=$step) { $out.Add($arr[$i]) }
  return ,$out.ToArray()
}

function Extract-EquityFromCsv($path) {
  try { $rows = Import-Csv -Path $path -ErrorAction Stop } catch { return $null }
  if (-not $rows) { return $null }
  $hdr = $rows[0].PSObject.Properties.Name
  $eqCol = $hdr | Where-Object { $_ -match '(?i)^(equity|nav|balance|value|cum[_\-]?pnl|equity_curve)$' } | Select-Object -First 1
  $pnlCol = $hdr | Where-Object { $_ -match '(?i)^(pnl|profit|ret(urn)?|pl)$' } | Select-Object -First 1
  $vals = @()
  if ($eqCol) {
    foreach ($r in $rows) { $v = Try-ParseDouble $r.$eqCol; if ($null -ne $v) { $vals += $v } }
  } elseif ($pnlCol) {
    $sum = 0.0
    foreach ($r in $rows) { $x = Try-ParseDouble $r.$pnlCol; if ($null -ne $x) { $sum += $x; $vals += $sum } }
  } else { return $null }
  if ($vals.Count -lt 2) { return $null }
  return [pscustomobject]@{ Source=$path; Values=$vals }
}

function Extract-EquityFromJson($path) {
  try { $json = (Get-Content -Path $path -Raw -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
  $stack = New-Object System.Collections.Stack
  $stack.Push($json)
  $vals = $null
  while ($stack.Count -gt 0) {
    $node = $stack.Pop()
    if ($node -is [System.Collections.IDictionary]) {
      foreach ($k in $node.Keys) {
        $kn = [string]$k
        $v  = $node[$k]
        if ($kn -match '(?i)^(equity|nav|balance|value|cum[_\-]?pnl|equity_curve)$' -and $v -is [System.Collections.IEnumerable] -and $v -isnot [string]) {
          $tmp = @(); foreach ($t in $v) { $d = Try-ParseDouble $t; if ($null -ne $d) { $tmp += $d } }
          if ($tmp.Count -ge 2) { $vals = $tmp; break }
        }
        if ($kn -match '(?i)^(pnl|profit|ret(urn)?|pl)$' -and $v -is [System.Collections.IEnumerable] -and $v -isnot [string]) {
          $sum=0.0; $tmp=@(); foreach ($t in $v) { $d = Try-ParseDouble $t; if ($null -ne $d) { $sum += $d; $tmp += $sum } }
          if ($tmp.Count -ge 2) { $vals = $tmp; break }
        }
        if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { $stack.Push($v) }
      }
    } elseif ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
      foreach ($it in $node) { $stack.Push($it) }
    }
    if ($vals) { break }
  }
  if (-not $vals) { return $null }
  return [pscustomobject]@{ Source=$path; Values=$vals }
}

function Find-Equity($dateFolder) {
  $roots = @((Join-Path $RunsRoot $dateFolder), (Join-Path $ReportsRoot $dateFolder)) | Where-Object { Test-Path $_ }
  $files = @()
  foreach ($root in $roots) {
    $files += Get-ChildItem -Path $root -Recurse -File -Include *.csv,*.json -ErrorAction SilentlyContinue |
              Where-Object { $_.Name.ToLower() -notmatch '^dashboard(_latest)?\.html$' }
  }
  # Пріоритет: runs > reports, назва містить equity/nav/balance/cum_pnl/wf.oos, потім найсвіжіший
  $prefer = @('equity','equity_curve','nav','balance','cum_pnl','wf.oos','wf.results','oos')
  $files = $files | Sort-Object @{Expression={ if ($_.FullName -like (Join-Path $RunsRoot '*')) {0}else{1} }},
                             @{Expression={ $n=$_.Name.ToLower(); - [int]($prefer | % { if ($n -like "*$_*"){1}else{0} } | Measure-Object -Sum | % Sum) }},
                             LastWriteTime -Descending

  foreach ($f in $files) {
    $ext = $f.Extension.ToLower()
    $res = if ($ext -eq '.csv') { Extract-EquityFromCsv $f.FullName } else { Extract-EquityFromJson $f.FullName }
    if ($res -and $res.Values.Count -ge 2) { return $res }
  }
  return $null
}

function Build-SparklineSvg([double[]]$vals, [int]$w=360, [int]$h=80) {
  $arr = Downsample $vals 400
  $min = [Linq.Enumerable]::Min($arr)
  $max = [Linq.Enumerable]::Max($arr)
  if ($max -eq $min) { $max = $min + 1.0 }
  $pts = for ($i=0; $i -lt $arr.Count; $i++) {
    $x = [math]::Round(($i/([double]($arr.Count-1)))*$w, 2)
    $y = [math]::Round($h - (($arr[$i]-$min)/($max-$min))*$h, 2)
    "$x,$y"
  } -join " "
  $last = $arr[-1]; $first = $arr[0]
  $deltaPct = if ([math]::Abs($first) -gt 1e-9) { (($last-$first)/[math]::Abs($first))*100.0 } else { $null }
  $lastTxt  = if ([math]::Abs($last) -ge 100) { "{0:N0}" -f $last } elseif ([math]::Abs($last) -ge 10) { "{0:N2}" -f $last } else { "{0:N3}" -f $last }
  $deltaTxt = if ($null -ne $deltaPct) { "{0:+0.0#;-0.0#;0}% " -f $deltaPct } else { "—" }

  $svg = @"
<svg width="$w" height="$h" viewBox="0 0 $w $h" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Equity">
  <polyline fill="none" stroke="currentColor" stroke-width="2" points="$pts"/>
</svg>
"@
  return [pscustomobject]@{ Svg=$svg; Last=$lastTxt; Delta=$deltaTxt }
}

function Build-EquityCard($dateFolder) {
  $hit = Find-Equity $dateFolder
  if (-not $hit) { return [pscustomobject]@{ Svg='<div class="muted">equity: дані поки відсутні</div>'; Last='—'; Delta='—'; Source='—' } }
  $sp = Build-SparklineSvg $hit.Values
  return [pscustomobject]@{ Svg=$sp.Svg; Last=$sp.Last; Delta=$sp.Delta; Source=$hit.Source }
}

# ---------- HTML ----------
function Build-Html($dateFolder, $links, $verdicts, $metrics, $equityCard) {
  $today = Get-Date -Format "yyyy-MM-dd HH:mm"
  $css = @"
  body { font-family:-apple-system,Segoe UI,Roboto,Inter,Arial,sans-serif; margin:24px; color:#111; }
  h1 { font-size:24px; margin-bottom:8px; }
  .muted { color:#666; font-size:12px; }
  .grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:12px; margin:16px 0; }
  .card { border:1px solid #eee; border-radius:12px; padding:12px; box-shadow:0 1px 3px rgba(0,0,0,.04); }
  .kpi { font-size:12px; color:#666; margin-bottom:6px; }
  .kpi b { font-size:20px; color:#111; }
  ul { padding-left:18px; }
  a { color:#0b65c2; text-decoration:none; }
  a:hover { text-decoration:underline; }
  .tiny { font-size:11px; color:#888; margin-top:4px; }
"@
  $verdictList = if ($verdicts -and $verdicts.Count) { ($verdicts | ForEach-Object { "<li><b>$($_.Gate)</b>: $($_.Verdict) <span class='muted'>($($_.Date))</span></li>" }) -join "`n" } else { "<li class='muted'>немає даних</li>" }
  $linksList   = if ($links -and $links.Count)       { ($links   | ForEach-Object { "<li><a href='./$($_.RelPath)'>$($_.Name)</a></li>" }) -join "`n" } else { "<li class='muted'>звітів не знайдено</li>" }

  @"
<!doctype html>
<html lang="uk">
<meta charset="utf-8"/>
<title>ATS Dashboard — $dateFolder</title>
<style>$css</style>
<body>
  <h1>ATS — дашборд за $dateFolder</h1>
  <div class="muted">Згенеровано: $today</div>

  <div class="grid">
    <div class="card">
      <div class="kpi">PnL</div><div><b>$($metrics.PnL)</b></div>
      <div class="tiny">source: $($metrics.Source)</div>
      <div class="tiny">scope:  $($metrics.Scope)</div>
    </div>
    <div class="card"><div class="kpi">Sharpe</div><div><b>$($metrics.Sharpe)</b></div></div>
    <div class="card"><div class="kpi">MaxDD</div><div><b>$($metrics.MaxDD)</b></div></div>

    <div class="card">
      <div class="kpi">Equity</div>
      <div>$($equityCard.Svg)</div>
      <div class="tiny">last: <b>$($equityCard.Last)</b> · Δ: $($equityCard.Delta)</div>
      <div class="tiny">source: $($equityCard.Source)</div>
    </div>
  </div>

  <div class="card"><h3 style="margin:0 0 8px 0;">Вердикти ґейтів</h3><ul>$verdictList</ul></div>
  <div class="card" style="margin-top:12px;"><h3 style="margin:0 0 8px 0;">Звіти за день</h3><ul>$linksList</ul></div>
  <div class="muted" style="margin-top:12px;">root: $ScriptRoot</div>
</body>
</html>
"@
}

# ---- main
try {
  Write-Info "ScriptRoot: $ScriptRoot"
  Write-Info "ReportsRoot: $ReportsRoot"
  Write-Info "RunsRoot: $RunsRoot"
  Write-Info "GatesJournal: $GatesJournal"
  Write-Info "Scope: $Scope"

  Ensure-ReportsRoot
  $dateFolder   = Get-Or-CreateReportDate
  Write-Info "Дата репорту: $dateFolder"

  $links        = Get-ReportLinks -dateFolder $dateFolder
  $verdicts     = Parse-GateVerdicts -journalPath $GatesJournal
  $metrics      = Extract-Metrics -dateFolder $dateFolder
  $equityCard   = Build-EquityCard -dateFolder $dateFolder

  $html = Build-Html -dateFolder $dateFolder -links $links -verdicts $verdicts -metrics $metrics -equityCard $equityCard

  $outDir = Join-Path $ReportsRoot $dateFolder
  if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

  $dashToday  = Join-Path $outDir "dashboard.html"
  $dashLatest = Join-Path $ReportsRoot "dashboard_latest.html"

  $html | Set-Content -Path $dashToday  -Encoding UTF8
  $html | Set-Content -Path $dashLatest -Encoding UTF8

  Write-Host "✅ Dashboard згенеровано:" -ForegroundColor Green
  Write-Host "   $dashToday"
  Write-Host "   $dashLatest"

  if ($Open) { try { Start-Process $dashToday } catch { Write-Info "Не вдалось відкрити браузер: $($_.Exception.Message)" } }
  exit 0
}
catch {
  Write-Error "❌ dash.ps1 помилка: $($_.Exception.Message)"
  exit 1
}
