param([string]$Date = (Get-Date -Format "yyyy-MM-dd"), [int]$Head = 50)

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

function Read-JsonRecords { param([string]$Path)
  $res = @()
  try {
    $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
    try {
      $obj = $raw | ConvertFrom-Json -ErrorAction Stop
      if ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string])) { $res = $obj }
      else { $res = @($obj) }
    } catch {
      $res = Get-Content -Path $Path -ErrorAction Stop | ForEach-Object {
        $line = $_.Trim()
        if ($line.StartsWith('{') -or $line.StartsWith('[')) {
          try { $line | ConvertFrom-Json -ErrorAction Stop } catch {}
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
    } elseif ($o -is [System.Collections.IEnumerable] -and -not ($o -is [string])) {
      $i = 0; foreach ($el in $o) { Recurse $el ($p + '['+$i+']'); $i++ }
    } else {
      $list.Add([pscustomobject]@{ Path = $p; Value = $o })
    }
  }
  Recurse $obj $prefix
  return $list
}

$Date = Find-RunDate $Date
$runRoot = Join-Path (Get-Location) ("runs/$Date")
$diagRoot = Join-Path (Get-Location) "diagnostics/orders_dump/$Date"
New-Item -ItemType Directory -Path $diagRoot -Force | Out-Null

$jsonFiles = Get-ChildItem -Path $runRoot -Recurse -File -Include *.json,*.ndjson,*.log -ErrorAction SilentlyContinue
foreach ($f in $jsonFiles) {
  $rel   = $f.FullName.Substring((Get-Location).Path.Length).TrimStart('\','/')
  $safe  = ($rel -replace '[\\/:*?"<>|]','_')
  $headPath = Join-Path $diagRoot ("{0}.head.txt" -f $safe)
  Get-Content -Path $f.FullName -TotalCount $Head -ErrorAction SilentlyContinue | Set-Content -Path $headPath -Encoding UTF8

  $items = Read-JsonRecords -Path $f.FullName
  if ($items -and $items.Count -gt 0) {
    $flat = Flatten-Object $items[0] | Select-Object -First 300
    $keysPath = Join-Path $diagRoot ("{0}.keys.txt" -f $safe)
    ($flat | Select-Object -ExpandProperty Path) | Set-Content -Path $keysPath -Encoding UTF8
  }
}
Write-Host ("Готово. Діагностика у: {0}" -f $diagRoot)
