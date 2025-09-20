param(
    [int]$Days = 7,
    [datetime]$EndDate = (Get-Date).Date,
    [string]$OutDir = "reports\digests",
    [string]$Label
)

# Корінь репо стабільно
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

if ($Days -lt 1) { throw "Days must be >= 1" }
$StartDate = $EndDate.AddDays(-($Days - 1))

# Папка для виводу
$OutDirFull = Join-Path $RepoRoot $OutDir
$null = New-Item -ItemType Directory -Force -Path $OutDirFull

# Шлях до файлу
$sd = $StartDate.ToString('yyyy-MM-dd')
$ed = $EndDate.ToString('yyyy-MM-dd')
$labelPart = if ($Label) { "_$Label" } else { "" }
$outFile = "Digest_${sd}_to_${ed}${labelPart}.md"
$outPath = Join-Path $OutDirFull $outFile

# Буфер рядків
$lines = New-Object 'System.Collections.Generic.List[string]'
$lines.Add("# Weekly Digest ($sd → $ed)")
$lines.Add("")
$lines.Add("> Автозбір `DaySummary-*.md` за останні $Days днів.")
$lines.Add("")

# Зміст
$lines.Add("## Зміст")
for ($i = 0; $i -lt $Days; $i++) {
    $day = $StartDate.AddDays($i).ToString('yyyy-MM-dd')
    $lines.Add("- [$day](#day-$day)")
}
$lines.Add("")

# Контент по днях
for ($i = 0; $i -lt $Days; $i++) {
    $dateObj = $StartDate.AddDays($i)
    $day = $dateObj.ToString('yyyy-MM-dd')
    $reportDir = Join-Path $RepoRoot "reports\$day"
    $summaryPath = Join-Path $reportDir "DaySummary-$day.md"

    $lines.Add("## Day $day <a id=""day-$day""></a>")

    if (Test-Path $summaryPath) {
        $content = Get-Content $summaryPath -Raw

        # Швидкі ключові рядки
        $goal   = ($content -split "`r?`n") | Where-Object { $_ -match '^\*\*Goal:\*\*' } | Select-Object -First 1
        $status = ($content -split "`r?`n") | Where-Object { $_ -match '^\*\*(G4 status \(heuristic\)|Status):\*\*' } | Select-Object -First 1
        $exit   = ($content -split "`r?`n") | Where-Object { $_ -match '^\*\*Runner exit:\*\*' } | Select-Object -First 1

        if ($goal)   { $lines.Add($goal) }
        if ($status) { $lines.Add($status) }
        if ($exit)   { $lines.Add($exit) }
        $lines.Add("")

        $lines.Add("<details><summary>Розгорнути повний DaySummary</summary>")
        $lines.Add("")
        $lines.Add($content.Trim())
        $lines.Add("")
        $lines.Add("</details>")
    } else {
        $lines.Add("_Немає DaySummary для цього дня._")
    }

    if ($i -lt ($Days - 1)) {
        $lines.Add("")
        $lines.Add("---")
        $lines.Add("")
    }
}

Set-Content -Path $outPath -Value ($lines -join "`r`n") -Encoding UTF8
Write-Host "[ok] Weekly digest written to $outPath" -ForegroundColor Green
