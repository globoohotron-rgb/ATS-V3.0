#requires -Version 7
param([switch]$Fix)

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

Say "ATS Doctor starting… PowerShell $($PSVersionTable.PSVersion)"

# 1) PS 7+
if ($PSVersionTable.PSVersion.Major -lt 7) { Say "PowerShell 7+ required. Current: $($PSVersionTable.PSVersion)" "ERR"; exit 2 }

# 2) Repo root
if (-not (Test-Path ".git")) { Say "Not in repo root ('.git' not found). cd to repo root and retry." "ERR"; exit 3 }

# 3) Folders
$folders = @("data/raw","data/processed","runs","reports","docs","scripts","tools",".trash")
$folders | ForEach-Object { New-Item -ItemType Directory -Force -Path $_ | Out-Null }
Say "Folders OK: $($folders -join ', ')"

# 4) '#requires -Version 7' enforcement
function Ensure-RequiresHeader($path) {
  if (-not (Test-Path $path)) { return }
  $content = Get-Content $path -Raw -Encoding UTF8
  if ($content -notmatch '^\s*#requires\s+-Version\s+7') {
    if ($Fix) {
      ("#requires -Version 7`r`n" + $content) | Set-Content -NoNewline -Encoding UTF8 -Path $path
      Say "Added '#requires -Version 7' → $path"
    } else {
      Say "Would add '#requires -Version 7' → $path (use -Fix)" "WARN"
    }
  }
}
$targets = @(".\run.ps1") + (Get-ChildItem .\scripts -Filter *.psm1 -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
$targets | ForEach-Object { Ensure-RequiresHeader $_ }

# 5) Default config
$cfgPath = "scripts/config.psd1"
if (-not (Test-Path $cfgPath)) {
  $cfg = @'
@{
  Seed       = 42
  TxCostBps  = 8     # 8 bps default
  Risk       = @{
    DailyLimit   = -0.02  # -2% day limit
    KillSwitchDD = -0.08  # -8% equity drawdown
  }
}
'@
  if ($Fix) { $cfg | Set-Content -NoNewline -Encoding UTF8 -Path $cfgPath; Say "Created $cfgPath with defaults" }
  else      { Say "Would create $cfgPath (use -Fix)" "WARN" }
} else { Say "$cfgPath already exists — OK" }

# 6) Duplicate finder (no regex)
$skipMarkers = @("\.git\", "\.trash\", "\bin\", "\obj\")
function ShouldSkip([string]$fullPath) {
  foreach ($m in $skipMarkers) { if ($fullPath -like "*$m*") { return $true } }
  return $false
}
$allFiles = Get-ChildItem -Recurse -File | Where-Object { -not (ShouldSkip $_.FullName) }
$dups = $allFiles | Group-Object Name | Where-Object { $_.Count -gt 1 }

if ($dups.Count -gt 0) {
  Say "Found $($dups.Count) duplicate name group(s):" "WARN"
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $trash = Join-Path -Path (Resolve-Path '.\.trash') -ChildPath $stamp
  if ($Fix) { New-Item -ItemType Directory -Force -Path $trash | Out-Null }

  foreach ($g in $dups) {
    $files = $g.Group | Sort-Object FullName
    $keep  = $files | Select-Object -First 1
    $others = $files | Where-Object { $_.FullName -ne $keep.FullName }
    Say "Keep: $($keep.FullName)"
    foreach ($f in $others) {
      if ($Fix) {
        $destName = ($f.Name + "." + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($f.FullName)) + ".quarantined")
        $dest = Join-Path $trash $destName
        Move-Item -LiteralPath $f.FullName -Destination $dest -Force
        Say "Moved duplicate → $dest"
      } else {
        Say "Would move duplicate → $($f.FullName)" "WARN"
      }
    }
  }
} else {
  Say "No duplicate file names — OK"
}

# 7) Git branch hint
try { $branch = (git rev-parse --abbrev-ref HEAD) 2>$null; if ($LASTEXITCODE -eq 0 -and $branch) { Say "Git branch: $branch" } } catch { }
Say "Doctor finished. Use '-Fix' to apply changes if not yet applied."
