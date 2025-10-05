param()
function Get-FailLocation {
  param([object]$t)
  $file = $null; $line = $null
  try {
    $inv = $t.ErrorRecord.InvocationInfo
    if ($inv) {
      if ($inv.ScriptName)       { $file = $inv.ScriptName }
      if ($inv.ScriptLineNumber) { $line = [int]$inv.ScriptLineNumber }
    }
  } catch {}

  if (-not $file -or -not $line) {
    try {
      $stack = $t.ErrorRecord.ScriptStackTrace
      if ($stack) {
        # приклад: "at <ScriptBlock>, C:\...\tests\DataQC_Tests.ps1:22"
        $m = [regex]::Match($stack, ',\s*(?<file>[A-Za-z]:\\[^:]+):(?<line>\d+)')
        if ($m.Success) { $file = $m.Groups['file'].Value; $line = [int]$m.Groups['line'].Value }
      }
    } catch {}
  }
  [pscustomobject]@{ File = $file; Line = $line }
}

$ErrorActionPreference = "Stop"

function Ensure-Pester5 {
  $has = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 }
  if (-not $has) {
    try {
      Install-Module Pester -Scope CurrentUser -Force -MinimumVersion 5.5.0 -AllowClobber -ErrorAction Stop
    } catch {
      Write-Warning "Не вдалося встановити Pester автоматично. Спробуйте вручну: Install-Module Pester -Scope CurrentUser"
    }
  }
  Import-Module Pester -Force
}

function Get-FailLocation { param([object]$t)
  $file=$null; $line=$null
  try { $inv = $t.ErrorRecord.InvocationInfo } catch {}
  if ($inv) {
    try { if ($inv.ScriptName)       { $file = $inv.ScriptName } } catch {}
    try { if ($inv.ScriptLineNumber) { $line = [int]$inv.ScriptLineNumber } } catch {}
  }
  if (-not $file -or -not $line) {
    try {
      $stack = $t.ErrorRecord.ScriptStackTrace
      if ($stack) {
        # приклади у нас: "at <ScriptBlock>, C:\...\tests\DataQC_Tests.ps1:22"
        $m = [regex]::Match($stack, ',\s*(?<file>[A-Za-z]:\\[^:]+):(?<line>\d+)')
        if ($m.Success) {
          $file = $m.Groups['file'].Value
          $line = [int]$m.Groups['line'].Value
        }
      }
    } catch {}
  }
  [pscustomobject]@{ File=$file; Line=$line }
}

  if (-not $file) {
    $stack = $null
    try { $stack = $tr.ErrorRecord.ScriptStackTrace } catch {}
    if (-not $stack) { try { $stack = $tr.StackTrace } catch {} }
    if ($stack) {
      $m = [regex]::Match($stack, '(?<file>[A-Za-z]:\\[^:]+?):line (?<line>\d+)', 'IgnoreCase')
      if ($m.Success) { $file = $m.Groups['file'].Value; $line = [int]$m.Groups['line'].Value }
    }
  }

  if (-not $file -and $tr.PSObject.Properties.Name -contains 'Path') { $file = $tr.Path }
  return [pscustomobject]@{ File = $file; Line = $line }
}

# --- main ---
Ensure-Pester5

$today  = Get-Date -Format 'yyyy-MM-dd'
$repDir = Join-Path -Path (Resolve-Path .\reports).Path -ChildPath $today
if (-not (Test-Path $repDir)) { New-Item -ItemType Directory -Path $repDir | Out-Null }

$xmlOut = Join-Path $repDir 'pester-results.xml'

$cfg = New-PesterConfiguration
$cfg.Run.Path = 'tests'
$cfg.Run.PassThru = $true    # <-- повертає об’єкт результатів у Pester 5
$cfg.Output.Verbosity = 'Detailed'
$cfg.TestResult.Enabled = $true
$cfg.TestResult.OutputPath = $xmlOut
$cfg.TestResult.OutputFormat = 'NUnitXml'

$run = Invoke-Pester -Configuration $cfg   # без -PassThru у Pester 5

$fails = @($run.TestResult | Where-Object { $_.Result -eq 'Failed' })

# Побудова Markdown
$md = [System.Collections.Generic.List[string]]::new()
$md.Add("# Selftest — snapshot $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$md.Add("")
$md.Add("**Summary:** Result=`$($run.Result)`, Total=`$($run.TestResult.Count)`, Failed=`$($fails.Count)`.")
$md.Add("")
if ($fails.Count -gt 0) {
  $md.Add("## Failures (mapped to file:line)")
  $md.Add("")
  $md.Add("| # | Test | File | Line | Message |")
  $md.Add("|-:|---|---|---:|---|")
  $i = 0
  foreach ($t in $fails) {
    $i++
    $loc = Get-FailLocation $t
    $file = $loc.File
    if ($file) {
      try {
        $file = (Resolve-Path -LiteralPath $file -ErrorAction SilentlyContinue).Path
        $repo = (Resolve-Path .).Path
        if ($file -and $repo) { $file = $file -replace [regex]::Escape($repo + [IO.Path]::DirectorySeparatorChar), '' }
      } catch {}
    }
    $line = if ($loc.Line) { $loc.Line } else { "" }
    $msg  = $(try { $t.ErrorRecord.Exception.Message } catch { $null })
    $row = "| $i | $($t.Name -replace '\|','\|') | $($file -replace '\|','\|') | $line | $((($msg -replace "`r?`n",' ') -replace '\|','\|')) |"
    $md.Add($row)
  }
} else {
  $md.Add("_No failures. All tests passed._")
}

$mdPath = Join-Path $repDir 'selftest.md'
$md.ToArray() -join "`r`n" | Set-Content -Path $mdPath -Encoding UTF8

# JSON-снимок
$failObjs = foreach ($t in $fails) {
    $loc = Get-FailLocation $t
  [ordered]@{
    name    = $t.Name
        file    = $loc.File
        line    = $loc.Line
    message = $(try { $t.ErrorRecord.Exception.Message } catch { $null })
    stack   = $(try { $t.ErrorRecord.ScriptStackTrace } catch { $null })
  }
}
# --- A1 PATCH: failures mapping (robust, balanced braces) ---
$failObjs = foreach ($t in $fails) {
  $loc = Get-FailLocation $t
  [ordered]@{
    name    = $t.Name
    file    = $loc.File
    line    = $loc.Line
    message = try { $t.ErrorRecord.Exception.Message } catch { $null }
    stack   = try { $t.ErrorRecord.ScriptStackTrace } catch { $null }
  }
}
# --- /A1 PATCH ---

$snapshot = [ordered]@{
  date     = $today
  total    = $run.TestResult.Count
  failed   = $fails.Count
  status   = $run.Result
  failures = $failObjs
}
($snapshot | ConvertTo-Json -Depth 8) | Set-Content -Path (Join-Path $repDir 'selftest.json') -Encoding UTF8

Write-Host "✅ Selftest snapshot saved: $mdPath"
exit 0

