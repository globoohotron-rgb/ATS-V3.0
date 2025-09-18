function Get-ATSConfig {
    param([string]$Path = (Join-Path (Split-Path -Parent $PSCommandPath) "config.psd1"))
    Import-PowerShellDataFile -Path $Path
}

function ConvertTo-HTMLEncoded {
    param([AllowNull()][string]$s)
    if ($null -eq $s) { return "" }
    ($s -replace "&","&amp;") -replace "<","&lt;" -replace ">","&gt;" -replace '"','&quot;'
}

function New-ATSConfigHtml {
    param([Parameter(Mandatory)][string]$ReportDir)

    $cfg = Get-ATSConfig
    if (!(Test-Path -LiteralPath $ReportDir)) { New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null }

    $css = @"
<style>
  .ats-conf {font: 14px/1.4 -apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Ubuntu,Cantarell,Helvetica,Arial;}
  .ats-conf h2{margin:8px 0 12px}
  .ats-sec{margin:14px 0 18px;border:1px solid #eee;border-radius:12px;padding:10px}
  .ats-sec h3{margin:0 0 8px;font-size:16px}
  .ats-tbl{width:100%;border-collapse:collapse}
  .ats-tbl th,.ats-tbl td{border-bottom:1px solid #f0f0f0;padding:6px 8px;text-align:left;vertical-align:top}
  .ats-key{white-space:nowrap;width:35%}
  details summary{cursor:pointer;font-weight:600;margin-bottom:6px}
</style>
"@

    $body = "<div class='ats-conf' id='ats-config-block'><h2>Config</h2><details open><summary>Current run settings</summary>"
    foreach ($top in $cfg.GetEnumerator() | Sort-Object Key) {
        $sectionName = [string]$top.Key
        $sectionVal  = $top.Value
        $body += "<div class='ats-sec'><h3>$(ConvertTo-HTMLEncoded $sectionName)</h3><table class='ats-tbl'><thead><tr><th>Key</th><th>Value</th></tr></thead><tbody>"
        if ($sectionVal -is [System.Collections.IDictionary]) {
            foreach ($kv in $sectionVal.GetEnumerator() | Sort-Object Key) {
                $k = [string]$kv.Key
                $v = if ($kv.Value -is [System.Collections.IEnumerable] -and -not ($kv.Value -is [string])) { ($kv.Value -join ", ") } else { [string]$kv.Value }
                $body += "<tr><td class='ats-key'>$(ConvertTo-HTMLEncoded $k)</td><td>$(ConvertTo-HTMLEncoded $v)</td></tr>"
            }
        } else {
            $v = [string]$sectionVal
            $body += "<tr><td class='ats-key'>(value)</td><td>$(ConvertTo-HTMLEncoded $v)</td></tr>"
        }
        $body += "</tbody></table></div>"
    }
    $body += "</details></div>"

    $html = $css + $body
    $out = Join-Path $ReportDir "config.html"
    Set-Content -Path $out -Value $html -Encoding UTF8 -NoNewline
    Write-Host "Config HTML saved: $out"
    return $out
}

function New-ATSIndexHtml {
    param([Parameter(Mandatory)][string]$ReportDir)
    $index = Join-Path $ReportDir "index.html"
    if (Test-Path -LiteralPath $index) { return $index }
    $skeleton = @"
<!doctype html>
<html><head>
  <meta charset="utf-8"/>
  <title>ATS Report</title>
</head><body>
  <h1 style="font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial;">ATS Report</h1>
  <!-- Auto-generated index -->
</body></html>
"@
    Set-Content -Path $index -Value $skeleton -Encoding UTF8 -NoNewline
    Write-Host "Created minimal index.html: $index"
    return $index
}

function Add-ATSConfigToIndex {
    param([Parameter(Mandatory)][string]$ReportDir)
    $index = New-ATSIndexHtml -ReportDir $ReportDir
    $configPart = Join-Path $ReportDir "config.html"
    if (!(Test-Path -LiteralPath $configPart)) { throw "config.html not found in $ReportDir. Run New-ATSConfigHtml first." }

    $html = Get-Content $index -Raw
    $inj  = Get-Content $configPart -Raw

    if ($html -match 'id="ats-config-block"') { Write-Host "index.html already contains ats-config-block — skip."; return }

    if ($html -match '</body>') {
        $newHtml = $html -replace '</body>', ("`r`n<!-- ATS Config injected -->`r`n" + $inj + "`r`n</body>")
    } else {
        $newHtml = $html + "`r`n<!-- ATS Config appended -->`r`n" + $inj
    }
    Set-Content -Path $index -Value $newHtml -Encoding UTF8
    Write-Host "Injected config block into: $index"
}

Export-ModuleMember -Function New-ATSConfigHtml,Add-ATSConfigToIndex,New-ATSIndexHtml
