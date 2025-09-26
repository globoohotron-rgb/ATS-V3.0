param([string[]]$Paths = @("day.ps1"))

function Get-AstErrors {
  param([Parameter(Mandatory)][string]$Path)
  $nullTokens = $null; $errs = $null
  [System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$nullTokens,[ref]$errs) | Out-Null
  return @($errs)
}

$bad = @()
foreach ($p in $Paths) {
  if (-not (Test-Path $p)) { Write-Host "ℹ️ Пропущено: $p (нема файлу)"; continue }
  $errs = Get-AstErrors -Path $p
  if ($errs.Count -gt 0) {
    Write-Host "❌ AST FAIL у $p — помилок: $($errs.Count)" -ForegroundColor Red
    $errs | Select-Object -First 5 | ForEach-Object {
      Write-Host ("  {0}:{1} — {2}" -f $_.Extent.StartLineNumber,$_.Extent.StartColumnNumber,$_.Message)
    }
    $bad += $p
  } else {
    Write-Host "✅ AST OK: $p" -ForegroundColor Green
  }
}

if ($bad.Count -gt 0) { exit 1 } else { exit 0 }
