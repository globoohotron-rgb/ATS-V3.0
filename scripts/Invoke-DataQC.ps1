param(
  [string]$SchemaFile = "config/data_schemas.json",
  [string]$OutDir = "artifacts/qc"
)

$ErrorActionPreference = "Stop"

function Ensure-Dir { param([string]$Path) if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }
function Read-Json($path) { Get-Content $path -Raw | ConvertFrom-Json }
function HtmlEncode([string]$s){ if ($null -eq $s) { return "" }; $s.Replace("&","&amp;").Replace("<","&lt;").Replace(">","&gt;") }

function Write-QcReport {
  param($Summary, $OutDir)
  $ts = (Get-Date).ToString("yyyy-MM-dd_HH-mm-ss")
  $jsonPath = Join-Path $OutDir "$ts`_qc.json"
  $htmlPath = Join-Path $OutDir "$ts`_qc.html"
  $Summary | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $jsonPath

  $status = if ($Summary.overall_pass) { "PASS" } else { "FAIL" }
  $rows = ($Summary.datasets | ForEach-Object {
    $issues = ($_.issues | ForEach-Object { HtmlEncode($_) }) -join "<br/>"
    "<tr><td>$($_.name)</td><td>$($_.pass)</td><td><pre>$issues</pre></td></tr>"
  }) -join "`n"

@"
<!DOCTYPE html>
<html><head><meta charset='utf-8'><title>QC $status</title>
<style>body{font-family:Segoe UI,Arial,sans-serif}table{border-collapse:collapse}td,th{border:1px solid #ddd;padding:6px}th{background:#f3f4f6}</style>
</head><body>
<h2>Data QC: $status</h2>
<p>Generated: $(Get-Date -Format u)</p>
<table><thead><tr><th>Dataset</th><th>Pass</th><th>Issues</th></tr></thead><tbody>
$rows
</tbody></table>
</body></html>
"@ | Set-Content -Encoding UTF8 $htmlPath

  return @{ json = $jsonPath; html = $htmlPath }
}

function Test-ColumnType {
  param($value, $type)
  switch ($type) {
    "string"   { return $true }
    "number"   { return ($value -as [double]) -ne $null }
    "integer"  { return ($value -as [int64]) -ne $null }
    "boolean"  { return @("true","false","0","1") -contains ($value.ToString().ToLower()) }
    "date"     { return [DateTime]::TryParse($value, [ref]([datetime]::MinValue)) }
    "datetime" { return [DateTime]::TryParse($value, [ref]([datetime]::MinValue)) }
    default    { return $false }
  }
}

$schema = Read-Json $SchemaFile
Ensure-Dir -Path $OutDir

$results = @()
$overall = $true

foreach ($kv in $schema.datasets.PSObject.Properties) {
  $name = $kv.Name
  $def  = $kv.Value
  $issues = New-Object System.Collections.Generic.List[string]

  $paths = @(Get-ChildItem -Path $def.path_glob -File -ErrorAction SilentlyContinue)
  if (-not $paths -or $paths.Count -eq 0) {
    $issues.Add("No files matched: $($def.path_glob)")
    $results += @{ name = $name; pass = $false; issues = $issues }
    $overall = $false
    continue
  }

  foreach ($file in $paths) {
    if ($def.format -eq "csv") {
      $csv = Import-Csv -Path $file.FullName -Delimiter $def.delimiter
      if (-not $csv -or $csv.Count -eq 0) {
        $issues.Add("Empty CSV: $($file.Name)")
        continue
      }

      $cols = $csv[0].PSObject.Properties.Name
      foreach ($col in $def.columns.name) {
        if (-not ($cols -contains $col)) { $issues.Add("Missing column '$col' in $($file.Name)") }
      }
      if (-not $def.allow_extra_columns) {
        $extra = $cols | Where-Object { $_ -notin $def.columns.name }
        if ($extra) { $issues.Add("Extra columns in $($file.Name): $($extra -join ', ')") }
      }

      $rowIndex = 0
      $lastTs = $null
      $set = New-Object 'System.Collections.Generic.HashSet[string]'

      foreach ($row in $csv) {
        $rowIndex++

        foreach ($c in $def.columns) {
          $val = $row.$($c.name)
          if ($c.required -and ([string]::IsNullOrWhiteSpace($val))) { $issues.Add("Row ${rowIndex}: '$($c.name)' is required"); continue }

          if ($val -ne $null -and $val -ne "") {
            if (-not (Test-ColumnType $val $c.type)) { $issues.Add("Row ${rowIndex}: '$($c.name)' type mismatch ($($c.type))") }
            if ($c.min -ne $null) { if (($val -as [double]) -lt [double]$c.min) { $issues.Add("Row ${rowIndex}: '$($c.name)' < min $($c.min)") } }
            if ($c.max -ne $null) { if (($val -as [double]) -gt [double]$c.max) { $issues.Add("Row ${rowIndex}: '$($c.name)' > max $($c.max)") } }
          }
        }

        # Primary key uniqueness
        if ($def.primary_key) {
          $pk = ($def.primary_key | ForEach-Object { $row.$_ }) -join "|"
          if (-not $set.Add($pk)) { $issues.Add("Duplicate PK at row ${rowIndex}: $pk") }
        }

        # Timestamp sorting (robust parsing; no typed nulls)
        $tsCol = ($def.columns | Where-Object { $_.type -eq "datetime" -or $_.type -eq "date" } | Select-Object -First 1)
        if ($tsCol) {
          $tsOut = [datetime]::MinValue
          $ok = [DateTime]::TryParse($row.$($tsCol.name), [ref]$tsOut)
          if (-not $ok) {
            $issues.Add("Row ${rowIndex}: invalid datetime in '$($tsCol.name)' -> '$($row.$($tsCol.name))'")
          } else {
            $isSortedFlag = ($def.columns | Where-Object { $_.name -eq $tsCol.name -and $_.sorted -eq $true }) -ne $null
            if ($isSortedFlag -and $lastTs -and $tsOut -lt $lastTs) {
              $issues.Add("Timestamp not sorted at row ${rowIndex}: $tsOut < $lastTs")
            }
            $lastTs = $tsOut
          }
        }
      }
    }
    else {
      $issues.Add("Format '$($def.format)' not implemented in v1")
    }
  }

  $pass = ($issues.Count -eq 0)
  if (-not $pass) { $overall = $false }
  $results += @{ name = $name; pass = $pass; issues = $issues }
}

$summary = [ordered]@{
  overall_pass = $overall
  datasets     = $results
}
$r = Write-QcReport -Summary $summary -OutDir $OutDir

if (-not $summary.overall_pass) {
  Write-Host "QC FAIL. See $($r.json), $($r.html)" -ForegroundColor Red
  exit 2
} else {
  Write-Host "QC PASS. See $($r.json), $($r.html)" -ForegroundColor Green
}
