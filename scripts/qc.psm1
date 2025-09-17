#requires -Version 7
# scripts/qc.psm1 — Data Quality Bot (InvariantCulture)
$ErrorActionPreference='Stop'
$CI = [System.Globalization.CultureInfo]::InvariantCulture
$NS = [System.Globalization.NumberStyles]::Float

function Ensure-Dir { param([string]$Path)
  if($Path -and -not (Test-Path $Path)){ New-Item -ItemType Directory -Force -Path $Path | Out-Null }
}
function Write-Doc { param([string]$Path,[string[]]$Lines)
  $d=Split-Path $Path; Ensure-Dir $d
  ($Lines -join "`r`n") | Set-Content -Path $Path -Encoding UTF8
}

function Invoke-DataQC {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$OutDir,
    [double]$MaxAbsReturn = 0.25,
    [switch]$RequireMonotonic
  )
  $issues  = New-Object System.Collections.Generic.List[string]
  $samples = New-Object System.Collections.Generic.List[string]
  $ok = $true

  if(-not (Test-Path $Path)){ $issues.Add("File not found: $Path") | Out-Null; $ok=$false }
  else{
    try { $rows = Import-Csv $Path } catch { $issues.Add("CSV parse error: $($_.Exception.Message)") | Out-Null; $ok=$false }
    if($ok){
      $need = @('Date','Open','High','Low','Close','Volume')
      $have = $rows[0].PsObject.Properties.Name
      $miss = @($need | Where-Object { $_ -notin $have })
      if($miss.Count -gt 0){ $issues.Add("Missing columns: " + ($miss -join ', ')) | Out-Null; $ok=$false }
      if($rows.Count -lt 2){ $issues.Add("Too few rows: $($rows.Count)") | Out-Null; $ok=$false }
      else{
        $prevDate=$null; $prevClose=$null
        for($i=0;$i -lt $rows.Count;$i++){
          $r=$rows[$i]; $err=@()
          $d=[datetime]::MinValue
          if(-not [DateTime]::TryParseExact($r.Date,'yyyy-MM-dd',$CI,[System.Globalization.DateTimeStyles]::None,[ref]$d)){
            $err+='bad Date (expect yyyy-MM-dd)'
          }
          if($RequireMonotonic){ if($prevDate -ne $null -and $d -le $prevDate){ $err+='non-monotonic/dup date' } ; $prevDate=$d }

          $o=[double]0; $h=[double]0; $l=[double]0; $c=[double]0; $v=[double]0
          $numsOk =  [double]::TryParse($r.Open,$NS,$CI,[ref]$o)   -and
                     [double]::TryParse($r.High,$NS,$CI,[ref]$h)   -and
                     [double]::TryParse($r.Low,$NS,$CI,[ref]$l)    -and
                     [double]::TryParse($r.Close,$NS,$CI,[ref]$c)  -and
                     [double]::TryParse($r.Volume,$NS,$CI,[ref]$v)
          if(-not $numsOk){ $err+='non-numeric fields' }
          else{
            if(($o -le 0) -or ($h -le 0) -or ($l -le 0) -or ($c -le 0)){ $err+='non-positive price' }
            if($v -lt 0){ $err+='negative volume' }
            if($h -lt [Math]::Max($o,[Math]::Max($l,$c)) -or $l -gt [Math]::Min($o,[Math]::Min($h,$c))){ $err+='bad candle (H/L bounds)' }
            if($prevClose -ne $null){
              $ret=$c/$prevClose - 1.0
              if([Math]::Abs($ret) -gt $MaxAbsReturn){ $err+=("outlier return: {0}%" -f ([Math]::Round(100*$ret,2))) }
            }
            $prevClose=$c
          }
          if($err.Count -gt 0){ $ok=$false; $samples.Add("row[$i]: " + ($err -join '; ')) | Out-Null; if($samples.Count -ge 10){ break } }
        }
      }
    }
  }

  $report = Join-Path $OutDir ("QC-Evidence-" + (Get-Date -Format 'yyyyMMdd') + "-" + ([Guid]::NewGuid().ToString('N').Substring(0,8)) + ".md")
  if($ok){
    Write-Doc $report @("# Data QC — PASS","","**File**: $Path","**Checks**: columns, numeric, candles, monotonic dates, outliers ≤ $([Math]::Round(100*$MaxAbsReturn,2))%","","No issues found.")
  } else {
    $lines=@("# Data QC — FAIL","","**File**: $Path","**Reasons**:")
    $lines += ($issues | ForEach-Object { "- $_" })
    $lines += "","## Sample issues (first 10)"
    $lines += ($samples | ForEach-Object { "- $_" })
    Write-Doc $report $lines
  }
  [pscustomobject]@{ Pass=$ok; Report=$report; Issues=$issues }
}

Export-ModuleMember -Function Invoke-DataQC
