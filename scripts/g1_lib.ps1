Set-StrictMode -Version Latest

# Seed (determinism acknowledgment); meta.json untouched
$script:Seed = 1337

function Ema {
    param([double[]]$vals, [double]$alpha)
    $out = New-Object double[] ($vals.Count)
    $prev = $null
    for ($i=0; $i -lt $vals.Count; $i++) {
        $v = $vals[$i]
        if ($null -eq $v) {
            $out[$i] = $null
            continue
        }
        if ($null -eq $prev) { $prev = $v }
        $prev = $alpha * $v + (1.0 - $alpha) * $prev
        $out[$i] = [math]::Round($prev, 6)
    }
    return $out
}

function ZScore {
    param([double[]]$vals)
    $out = New-Object double[] ($vals.Count)
    $valid = @()
    for ($i=0; $i -lt $vals.Count; $i++) {
        if ($null -ne $vals[$i]) { $valid += [double]$vals[$i] }
    }
    if ($valid.Count -lt 2) {
        for ($i=0; $i -lt $vals.Count; $i++) { $out[$i] = $vals[$i] }
        return $out
    }
    $mean = ($valid | Measure-Object -Sum).Sum / $valid.Count
    $sumSq = 0.0
    foreach ($x in $valid) { $sumSq += ([math]::Pow(($x - $mean), 2)) }
    $var = $sumSq / $valid.Count
    $std = [math]::Sqrt($var)
    if ($std -eq 0) {
        for ($i=0; $i -lt $vals.Count; $i++) { $out[$i] = $vals[$i] }
        return $out
    }
    for ($i=0; $i -lt $vals.Count; $i++) {
        $v = $vals[$i]
        if ($null -eq $v) { $out[$i] = $null }
        else { $out[$i] = [math]::Round((([double]$v - $mean) / $std), 6) }
    }
    return $out
}

function Diff {
    param([double[]]$vals)
    $out = New-Object double[] ($vals.Count)
    $prev = $null
    for ($i=0; $i -lt $vals.Count; $i++) {
        $v = $vals[$i]
        if ($null -eq $prev -or $null -eq $v) { $out[$i] = $null }
        else { $out[$i] = [math]::Round(([double]$v - [double]$prev), 6) }
        if ($null -ne $v) { $prev = [double]$v }
    }
    return $out
}

function Lag {
    param([double[]]$vals, [int]$k)
    $out = New-Object object[] ($vals.Count)
    for ($i=0; $i -lt $vals.Count; $i++) {
        if ($i -lt $k) { $out[$i] = $null }
        else { $out[$i] = $vals[$i - $k] }
    }
    return $out
}

function ToDate {
    param([object]$v)
    function ParseOne([object]$x) {
        try {
            if ($null -eq $x) { return $null }
            $s = "$x"
            if ([string]::IsNullOrWhiteSpace($s)) { return $null }
            return [datetime]::Parse($s)
        } catch { return $null }
    }
    if ($v -is [System.Collections.IEnumerable] -and -not ($v -is [string])) {
        $arr = @()
        foreach ($item in $v) { $arr += (ParseOne $item) }
        return $arr
    } else {
        return @(ParseOne $v)
    }
}
