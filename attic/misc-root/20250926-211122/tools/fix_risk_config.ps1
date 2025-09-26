param()

function Get-ConfigPath {
  foreach ($rel in @('config/config.psd1','scripts/config.psd1')) {
    $p = Join-Path (Get-Location) $rel
    if (Test-Path $p) { return $p }
  }
  throw "Не знайдено config.psd1 у config/ або scripts/."
}

function Import-ConfigData([string]$Path) {
  return Import-PowerShellDataFile -Path $Path
}

function ConvertTo-Psd1 {
  param([hashtable]$Table, [int]$Indent = 0)
  $sp = ' ' * $Indent
  $nl = [Environment]::NewLine
  $out = "@{$nl"
  foreach ($k in ($Table.Keys | Sort-Object)) {
    $v = $Table[$k]
    $out += (' ' * ($Indent + 2)) + "$k = " + (Format-Psd1Value $v ($Indent + 2)) + $nl
  }
  $out += $sp + "}"
  return $out
}

function Format-Psd1Value {
  param($v, [int]$Indent = 0)
  $nl = [Environment]::NewLine
  if ($v -is [hashtable]) { return (ConvertTo-Psd1 -Table $v -Indent $Indent) }
  elseif ($v -is [System.Collections.IDictionary]) { return (ConvertTo-Psd1 -Table ([hashtable]$v) -Indent $Indent) }
  elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
    $sp = ' ' * $Indent
    $s = "@($nl"
    foreach ($item in $v) {
      $s += (' ' * ($Indent + 2)) + (Format-Psd1Value $item ($Indent + 2)) + $nl
    }
    $s += $sp + ")"
    return $s
  }
  elseif ($v -is [bool])   { return ($(if($v){'$true'}else{'$false'})) }
  elseif ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { return "$v" }
  else {
    $s = [string]$v
    $s = $s -replace "'", "''"  # екрануємо одинарні
    return "'$s'"
  }
}

Write-Host "▶ Визначаю конфіг..."
$cfgPath = Get-ConfigPath
$cfg     = Import-ConfigData -Path $cfgPath
Write-Host "   ✓ Config: $cfgPath"

# Стандарти ризику (з нашого STATE/огляду):
# DayLimit ≈ -2%, MaxDD ≈ 5%, KillSwitch ≈ 8% (для G6). Paper-режим як дефолт. 
# (Джерело: план/STATE/огляд) 
$defs = @{
  Risk = @{
    DayLimitPct    = -2
    MaxDDPct       = 5
    KillSwitchPct  = 8
  }
  Executor = @{ Mode = 'paper' }
}

# Забезпечуємо вкладені хеші
foreach ($top in $defs.Keys) {
  if (-not $cfg.ContainsKey($top) -or -not ($cfg[$top] -is [hashtable])) {
    $cfg[$top] = @{}
  }
  foreach ($k in $defs[$top].Keys) {
    if (-not $cfg[$top].ContainsKey($k)) {
      $cfg[$top][$k] = $defs[$top][$k]
    }
  }
}

# Бекап і збереження
$backup = "$cfgPath.bak"
Copy-Item -Path $cfgPath -Destination $backup -Force
$psd1 = ConvertTo-Psd1 -Table $cfg -Indent 0
Set-Content -Path $cfgPath -Value $psd1 -Encoding UTF8
Write-Host "   ✓ Оновлено конфіг; бекап: $backup"

