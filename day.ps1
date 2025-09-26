# day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # Конфіг з порогами
  $cfg = $null
  try {
    $cfgFile = Join-Path $repo 'config/metrics.psd1'
    if (Test-Path $cfgFile) { $cfg = Import-PowerShellDataFile -Path $cfgFile }
  } catch { Write-Warning "[SHADOW 9.2] Не вдалось прочитати config/metrics.psd1: $(# day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # знайдемо актуальний reports/<дата> (або останній на випадок нічного рану)
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json
      $fill   = [double]$m.FillRate_bySignals
      $minFill = 0.8  # тимчасово тут; у 9.3 винесемо в конфіг
      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } else {
        'GREEN'
      }
      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3}" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + $_.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# >> SHADOW-WEEKLY (9.4) START
try {
  $wDate = (Get-Date).ToString('yyyy-MM-dd')
  $repo  = Get-Location
  $weekly = Join-Path $repo 'tools/ShadowWeekly.ps1'
  if (Test-Path $weekly) {
    Write-Host "[SHADOW 9.4] Оновлюю тижневий дайджест за $wDate…"
    & $weekly -EndDate $wDate -Days 7 | Out-Host
  } else {
    Write-Warning "[SHADOW 9.4] Не знайдено tools/ShadowWeekly.ps1"
  }
} catch {
  Write-Warning ("[SHADOW 9.4] Error: " + # day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # Конфіг з порогами
  $cfg = $null
  try {
    $cfgFile = Join-Path $repo 'config/metrics.psd1'
    if (Test-Path $cfgFile) { $cfg = Import-PowerShellDataFile -Path $cfgFile }
  } catch { Write-Warning "[SHADOW 9.2] Не вдалось прочитати config/metrics.psd1: $(# day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # знайдемо актуальний reports/<дата> (або останній на випадок нічного рану)
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json
      $fill   = [double]$m.FillRate_bySignals
      $minFill = 0.8  # тимчасово тут; у 9.3 винесемо в конфіг
      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } else {
        'GREEN'
      }
      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3}" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + $_.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END
.Exception.Message)" }

  $minFill    = if ($cfg -and $cfg.ContainsKey('MinFillRate'))       { [double]$cfg.MinFillRate }       else { 0.8 }
  $slipBudget = if ($cfg -and $cfg.ContainsKey('SlippageBudgetBps')) { [double]$cfg.SlippageBudgetBps } else { 1e9 }
  $teBudget   = if ($cfg -and $cfg.ContainsKey('TEBudgetBpsSD'))     { [double]$cfg.TEBudgetBpsSD }     else { 1e9 }

  # Визначимо актуальний reports/<дата>
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json

      $fill = if ($m.FillRate_bySignals -ne $null) { [double]$m.FillRate_bySignals } else { $null }
      $slipMed = if ($m.SlippageBps_Med   -ne $null) { [double]$m.SlippageBps_Med } else { $null }
      $teSd = if ($m.TEproxyBpsSD         -ne $null) { [double]$m.TEproxyBpsSD }   else { $null }

      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -ne $null -and $fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } elseif ($slipMed -ne $null -and [math]::Abs($slipMed) -gt $slipBudget) {
        "RED: SLIPPAGE_BUDGET_EXCEEDED (|$slipMed| > $slipBudget)"
      } elseif ($teSd -ne $null -and $teSd -gt $teBudget) {
        "RED: TE_BUDGET_EXCEEDED ($teSd > $teBudget)"
      } else {
        'GREEN'
      }

      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3} | SlipMed={4}bps | TE_SD={5}bps" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill,$slipMed,$teSd)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + # day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # знайдемо актуальний reports/<дата> (або останній на випадок нічного рану)
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json
      $fill   = [double]$m.FillRate_bySignals
      $minFill = 0.8  # тимчасово тут; у 9.3 винесемо в конфіг
      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } else {
        'GREEN'
      }
      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3}" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + $_.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END
.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END

.Exception.Message)
}
# << SHADOW-WEEKLY (9.4) END
# << SHADOW-LIVE (9.2) END
# >> SHADOW-WEEKLY (9.4) START
try {
  $wDate = (Get-Date).ToString('yyyy-MM-dd')
  $repo  = Get-Location
  $weekly = Join-Path $repo 'tools/ShadowWeekly.ps1'
  if (Test-Path $weekly) {
    Write-Host "[SHADOW 9.4] Оновлюю тижневий дайджест за $wDate…"
    & $weekly -EndDate $wDate -Days 7 | Out-Host
  } else {
    Write-Warning "[SHADOW 9.4] Не знайдено tools/ShadowWeekly.ps1"
  }
} catch {
  Write-Warning ("[SHADOW 9.4] Error: " + # day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # Конфіг з порогами
  $cfg = $null
  try {
    $cfgFile = Join-Path $repo 'config/metrics.psd1'
    if (Test-Path $cfgFile) { $cfg = Import-PowerShellDataFile -Path $cfgFile }
  } catch { Write-Warning "[SHADOW 9.2] Не вдалось прочитати config/metrics.psd1: $(# day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # знайдемо актуальний reports/<дата> (або останній на випадок нічного рану)
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json
      $fill   = [double]$m.FillRate_bySignals
      $minFill = 0.8  # тимчасово тут; у 9.3 винесемо в конфіг
      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } else {
        'GREEN'
      }
      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3}" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + $_.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END
.Exception.Message)" }

  $minFill    = if ($cfg -and $cfg.ContainsKey('MinFillRate'))       { [double]$cfg.MinFillRate }       else { 0.8 }
  $slipBudget = if ($cfg -and $cfg.ContainsKey('SlippageBudgetBps')) { [double]$cfg.SlippageBudgetBps } else { 1e9 }
  $teBudget   = if ($cfg -and $cfg.ContainsKey('TEBudgetBpsSD'))     { [double]$cfg.TEBudgetBpsSD }     else { 1e9 }

  # Визначимо актуальний reports/<дата>
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json

      $fill = if ($m.FillRate_bySignals -ne $null) { [double]$m.FillRate_bySignals } else { $null }
      $slipMed = if ($m.SlippageBps_Med   -ne $null) { [double]$m.SlippageBps_Med } else { $null }
      $teSd = if ($m.TEproxyBpsSD         -ne $null) { [double]$m.TEproxyBpsSD }   else { $null }

      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -ne $null -and $fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } elseif ($slipMed -ne $null -and [math]::Abs($slipMed) -gt $slipBudget) {
        "RED: SLIPPAGE_BUDGET_EXCEEDED (|$slipMed| > $slipBudget)"
      } elseif ($teSd -ne $null -and $teSd -gt $teBudget) {
        "RED: TE_BUDGET_EXCEEDED ($teSd > $teBudget)"
      } else {
        'GREEN'
      }

      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3} | SlipMed={4}bps | TE_SD={5}bps" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill,$slipMed,$teSd)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + # day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # знайдемо актуальний reports/<дата> (або останній на випадок нічного рану)
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json
      $fill   = [double]$m.FillRate_bySignals
      $minFill = 0.8  # тимчасово тут; у 9.3 винесемо в конфіг
      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } else {
        'GREEN'
      }
      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3}" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + $_.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END
.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END

.Exception.Message)
}
# << SHADOW-WEEKLY (9.4) END
.Exception.Message)" }

  $minFill    = if ($cfg -and $cfg.ContainsKey('MinFillRate'))       { [double]$cfg.MinFillRate }       else { 0.8 }
  $slipBudget = if ($cfg -and $cfg.ContainsKey('SlippageBudgetBps')) { [double]$cfg.SlippageBudgetBps } else { 1e9 }
  $teBudget   = if ($cfg -and $cfg.ContainsKey('TEBudgetBpsSD'))     { [double]$cfg.TEBudgetBpsSD }     else { 1e9 }

  # Визначимо актуальний reports/<дата>
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json

      $fill = if ($m.FillRate_bySignals -ne $null) { [double]$m.FillRate_bySignals } else { $null }
      $slipMed = if ($m.SlippageBps_Med   -ne $null) { [double]$m.SlippageBps_Med } else { $null }
      $teSd = if ($m.TEproxyBpsSD         -ne $null) { [double]$m.TEproxyBpsSD }   else { $null }

      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -ne $null -and $fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } elseif ($slipMed -ne $null -and [math]::Abs($slipMed) -gt $slipBudget) {
        "RED: SLIPPAGE_BUDGET_EXCEEDED (|$slipMed| > $slipBudget)"
      } elseif ($teSd -ne $null -and $teSd -gt $teBudget) {
        "RED: TE_BUDGET_EXCEEDED ($teSd > $teBudget)"
      } else {
        'GREEN'
      }

      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3} | SlipMed={4}bps | TE_SD={5}bps" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill,$slipMed,$teSd)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + # day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # знайдемо актуальний reports/<дата> (або останній на випадок нічного рану)
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json
      $fill   = [double]$m.FillRate_bySignals
      $minFill = 0.8  # тимчасово тут; у 9.3 винесемо в конфіг
      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } else {
        'GREEN'
      }
      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3}" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + $_.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# >> SHADOW-WEEKLY (9.4) START
try {
  $wDate = (Get-Date).ToString('yyyy-MM-dd')
  $repo  = Get-Location
  $weekly = Join-Path $repo 'tools/ShadowWeekly.ps1'
  if (Test-Path $weekly) {
    Write-Host "[SHADOW 9.4] Оновлюю тижневий дайджест за $wDate…"
    & $weekly -EndDate $wDate -Days 7 | Out-Host
  } else {
    Write-Warning "[SHADOW 9.4] Не знайдено tools/ShadowWeekly.ps1"
  }
} catch {
  Write-Warning ("[SHADOW 9.4] Error: " + # day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # Конфіг з порогами
  $cfg = $null
  try {
    $cfgFile = Join-Path $repo 'config/metrics.psd1'
    if (Test-Path $cfgFile) { $cfg = Import-PowerShellDataFile -Path $cfgFile }
  } catch { Write-Warning "[SHADOW 9.2] Не вдалось прочитати config/metrics.psd1: $(# day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # знайдемо актуальний reports/<дата> (або останній на випадок нічного рану)
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json
      $fill   = [double]$m.FillRate_bySignals
      $minFill = 0.8  # тимчасово тут; у 9.3 винесемо в конфіг
      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } else {
        'GREEN'
      }
      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3}" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + $_.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END
.Exception.Message)" }

  $minFill    = if ($cfg -and $cfg.ContainsKey('MinFillRate'))       { [double]$cfg.MinFillRate }       else { 0.8 }
  $slipBudget = if ($cfg -and $cfg.ContainsKey('SlippageBudgetBps')) { [double]$cfg.SlippageBudgetBps } else { 1e9 }
  $teBudget   = if ($cfg -and $cfg.ContainsKey('TEBudgetBpsSD'))     { [double]$cfg.TEBudgetBpsSD }     else { 1e9 }

  # Визначимо актуальний reports/<дата>
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json

      $fill = if ($m.FillRate_bySignals -ne $null) { [double]$m.FillRate_bySignals } else { $null }
      $slipMed = if ($m.SlippageBps_Med   -ne $null) { [double]$m.SlippageBps_Med } else { $null }
      $teSd = if ($m.TEproxyBpsSD         -ne $null) { [double]$m.TEproxyBpsSD }   else { $null }

      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -ne $null -and $fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } elseif ($slipMed -ne $null -and [math]::Abs($slipMed) -gt $slipBudget) {
        "RED: SLIPPAGE_BUDGET_EXCEEDED (|$slipMed| > $slipBudget)"
      } elseif ($teSd -ne $null -and $teSd -gt $teBudget) {
        "RED: TE_BUDGET_EXCEEDED ($teSd > $teBudget)"
      } else {
        'GREEN'
      }

      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3} | SlipMed={4}bps | TE_SD={5}bps" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill,$slipMed,$teSd)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + # day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # знайдемо актуальний reports/<дата> (або останній на випадок нічного рану)
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json
      $fill   = [double]$m.FillRate_bySignals
      $minFill = 0.8  # тимчасово тут; у 9.3 винесемо в конфіг
      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } else {
        'GREEN'
      }
      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3}" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + $_.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END
.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END

.Exception.Message)
}
# << SHADOW-WEEKLY (9.4) END
# << SHADOW-LIVE (9.2) END
# >> SHADOW-WEEKLY (9.4) START
try {
  $wDate = (Get-Date).ToString('yyyy-MM-dd')
  $repo  = Get-Location
  $weekly = Join-Path $repo 'tools/ShadowWeekly.ps1'
  if (Test-Path $weekly) {
    Write-Host "[SHADOW 9.4] Оновлюю тижневий дайджест за $wDate…"
    & $weekly -EndDate $wDate -Days 7 | Out-Host
  } else {
    Write-Warning "[SHADOW 9.4] Не знайдено tools/ShadowWeekly.ps1"
  }
} catch {
  Write-Warning ("[SHADOW 9.4] Error: " + # day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # Конфіг з порогами
  $cfg = $null
  try {
    $cfgFile = Join-Path $repo 'config/metrics.psd1'
    if (Test-Path $cfgFile) { $cfg = Import-PowerShellDataFile -Path $cfgFile }
  } catch { Write-Warning "[SHADOW 9.2] Не вдалось прочитати config/metrics.psd1: $(# day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # знайдемо актуальний reports/<дата> (або останній на випадок нічного рану)
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json
      $fill   = [double]$m.FillRate_bySignals
      $minFill = 0.8  # тимчасово тут; у 9.3 винесемо в конфіг
      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } else {
        'GREEN'
      }
      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3}" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + $_.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END
.Exception.Message)" }

  $minFill    = if ($cfg -and $cfg.ContainsKey('MinFillRate'))       { [double]$cfg.MinFillRate }       else { 0.8 }
  $slipBudget = if ($cfg -and $cfg.ContainsKey('SlippageBudgetBps')) { [double]$cfg.SlippageBudgetBps } else { 1e9 }
  $teBudget   = if ($cfg -and $cfg.ContainsKey('TEBudgetBpsSD'))     { [double]$cfg.TEBudgetBpsSD }     else { 1e9 }

  # Визначимо актуальний reports/<дата>
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json

      $fill = if ($m.FillRate_bySignals -ne $null) { [double]$m.FillRate_bySignals } else { $null }
      $slipMed = if ($m.SlippageBps_Med   -ne $null) { [double]$m.SlippageBps_Med } else { $null }
      $teSd = if ($m.TEproxyBpsSD         -ne $null) { [double]$m.TEproxyBpsSD }   else { $null }

      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -ne $null -and $fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } elseif ($slipMed -ne $null -and [math]::Abs($slipMed) -gt $slipBudget) {
        "RED: SLIPPAGE_BUDGET_EXCEEDED (|$slipMed| > $slipBudget)"
      } elseif ($teSd -ne $null -and $teSd -gt $teBudget) {
        "RED: TE_BUDGET_EXCEEDED ($teSd > $teBudget)"
      } else {
        'GREEN'
      }

      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3} | SlipMed={4}bps | TE_SD={5}bps" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill,$slipMed,$teSd)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + # day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # знайдемо актуальний reports/<дата> (або останній на випадок нічного рану)
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json
      $fill   = [double]$m.FillRate_bySignals
      $minFill = 0.8  # тимчасово тут; у 9.3 винесемо в конфіг
      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } else {
        'GREEN'
      }
      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3}" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + $_.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END
.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END

.Exception.Message)
}
# << SHADOW-WEEKLY (9.4) END
.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# >> SHADOW-WEEKLY (9.4) START
try {
  $wDate = (Get-Date).ToString('yyyy-MM-dd')
  $repo  = Get-Location
  $weekly = Join-Path $repo 'tools/ShadowWeekly.ps1'
  if (Test-Path $weekly) {
    Write-Host "[SHADOW 9.4] Оновлюю тижневий дайджест за $wDate…"
    & $weekly -EndDate $wDate -Days 7 | Out-Host
  } else {
    Write-Warning "[SHADOW 9.4] Не знайдено tools/ShadowWeekly.ps1"
  }
} catch {
  Write-Warning ("[SHADOW 9.4] Error: " + # day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # Конфіг з порогами
  $cfg = $null
  try {
    $cfgFile = Join-Path $repo 'config/metrics.psd1'
    if (Test-Path $cfgFile) { $cfg = Import-PowerShellDataFile -Path $cfgFile }
  } catch { Write-Warning "[SHADOW 9.2] Не вдалось прочитати config/metrics.psd1: $(# day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # знайдемо актуальний reports/<дата> (або останній на випадок нічного рану)
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json
      $fill   = [double]$m.FillRate_bySignals
      $minFill = 0.8  # тимчасово тут; у 9.3 винесемо в конфіг
      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } else {
        'GREEN'
      }
      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3}" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + $_.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END
.Exception.Message)" }

  $minFill    = if ($cfg -and $cfg.ContainsKey('MinFillRate'))       { [double]$cfg.MinFillRate }       else { 0.8 }
  $slipBudget = if ($cfg -and $cfg.ContainsKey('SlippageBudgetBps')) { [double]$cfg.SlippageBudgetBps } else { 1e9 }
  $teBudget   = if ($cfg -and $cfg.ContainsKey('TEBudgetBpsSD'))     { [double]$cfg.TEBudgetBpsSD }     else { 1e9 }

  # Визначимо актуальний reports/<дата>
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json

      $fill = if ($m.FillRate_bySignals -ne $null) { [double]$m.FillRate_bySignals } else { $null }
      $slipMed = if ($m.SlippageBps_Med   -ne $null) { [double]$m.SlippageBps_Med } else { $null }
      $teSd = if ($m.TEproxyBpsSD         -ne $null) { [double]$m.TEproxyBpsSD }   else { $null }

      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -ne $null -and $fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } elseif ($slipMed -ne $null -and [math]::Abs($slipMed) -gt $slipBudget) {
        "RED: SLIPPAGE_BUDGET_EXCEEDED (|$slipMed| > $slipBudget)"
      } elseif ($teSd -ne $null -and $teSd -gt $teBudget) {
        "RED: TE_BUDGET_EXCEEDED ($teSd > $teBudget)"
      } else {
        'GREEN'
      }

      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3} | SlipMed={4}bps | TE_SD={5}bps" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill,$slipMed,$teSd)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + # day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # знайдемо актуальний reports/<дата> (або останній на випадок нічного рану)
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json
      $fill   = [double]$m.FillRate_bySignals
      $minFill = 0.8  # тимчасово тут; у 9.3 винесемо в конфіг
      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } else {
        'GREEN'
      }
      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3}" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + $_.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END
.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END

.Exception.Message)
}
# << SHADOW-WEEKLY (9.4) END
# << SHADOW-LIVE (9.2) END
# >> SHADOW-WEEKLY (9.4) START
try {
  $wDate = (Get-Date).ToString('yyyy-MM-dd')
  $repo  = Get-Location
  $weekly = Join-Path $repo 'tools/ShadowWeekly.ps1'
  if (Test-Path $weekly) {
    Write-Host "[SHADOW 9.4] Оновлюю тижневий дайджест за $wDate…"
    & $weekly -EndDate $wDate -Days 7 | Out-Host
  } else {
    Write-Warning "[SHADOW 9.4] Не знайдено tools/ShadowWeekly.ps1"
  }
} catch {
  Write-Warning ("[SHADOW 9.4] Error: " + # day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # Конфіг з порогами
  $cfg = $null
  try {
    $cfgFile = Join-Path $repo 'config/metrics.psd1'
    if (Test-Path $cfgFile) { $cfg = Import-PowerShellDataFile -Path $cfgFile }
  } catch { Write-Warning "[SHADOW 9.2] Не вдалось прочитати config/metrics.psd1: $(# day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # знайдемо актуальний reports/<дата> (або останній на випадок нічного рану)
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json
      $fill   = [double]$m.FillRate_bySignals
      $minFill = 0.8  # тимчасово тут; у 9.3 винесемо в конфіг
      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } else {
        'GREEN'
      }
      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3}" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + $_.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END
.Exception.Message)" }

  $minFill    = if ($cfg -and $cfg.ContainsKey('MinFillRate'))       { [double]$cfg.MinFillRate }       else { 0.8 }
  $slipBudget = if ($cfg -and $cfg.ContainsKey('SlippageBudgetBps')) { [double]$cfg.SlippageBudgetBps } else { 1e9 }
  $teBudget   = if ($cfg -and $cfg.ContainsKey('TEBudgetBpsSD'))     { [double]$cfg.TEBudgetBpsSD }     else { 1e9 }

  # Визначимо актуальний reports/<дата>
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json

      $fill = if ($m.FillRate_bySignals -ne $null) { [double]$m.FillRate_bySignals } else { $null }
      $slipMed = if ($m.SlippageBps_Med   -ne $null) { [double]$m.SlippageBps_Med } else { $null }
      $teSd = if ($m.TEproxyBpsSD         -ne $null) { [double]$m.TEproxyBpsSD }   else { $null }

      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -ne $null -and $fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } elseif ($slipMed -ne $null -and [math]::Abs($slipMed) -gt $slipBudget) {
        "RED: SLIPPAGE_BUDGET_EXCEEDED (|$slipMed| > $slipBudget)"
      } elseif ($teSd -ne $null -and $teSd -gt $teBudget) {
        "RED: TE_BUDGET_EXCEEDED ($teSd > $teBudget)"
      } else {
        'GREEN'
      }

      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3} | SlipMed={4}bps | TE_SD={5}bps" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill,$slipMed,$teSd)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + # day.ps1 — v0.4 (strict idempotency, scheduler-DateTime, summary)
param(
    [string]$Goal,
    [datetime]$Date = (Get-Date).Date,
    [switch]$NonInteractive,
    [switch]$Force,

    # реєстрація планувальника
    [switch]$RegisterTask,
    [switch]$RegisterTaskOnly,              # зареєструвати й ВИЙТИ (без денного прогону)
    [string]$Time = "09:00",                # формат HH:mm (локальний час)
    [string]$TaskName = "ATS Day Cycle"
)

Write-Host "[info] day.ps1 v0.4 loaded" -ForegroundColor DarkGray

# --- корінь репо
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Resolve-Path .).Path }
Set-Location $RepoRoot

# --- дати/шляхи
$day         = $Date.ToString('yyyy-MM-dd')
$runDir      = Join-Path $RepoRoot "runs\$day\day-orchestrator"
$reportsDir  = Join-Path $RepoRoot "reports\$day"
$logsPath    = Join-Path $runDir "day-orchestrator.log"
$goalPath    = Join-Path $runDir "goal.txt"
$summaryPath = Join-Path $reportsDir "DaySummary-$day.md"

# --- структуру створюємо заздалегідь
$null = New-Item -ItemType Directory -Force -Path $runDir
$null = New-Item -ItemType Directory -Force -Path $reportsDir

function Register-ATSDayTask {
    param(
        [string]$TaskName,
        [string]$Time,
        [string]$Goal,
        [string]$RepoRoot
    )
    if (-not $IsWindows) { Write-Warning "Заплановані завдання доступні лише на Windows."; return }
    try {
        if (-not (Get-Module -ListAvailable -Name ScheduledTasks)) {
            Import-Module ScheduledTasks -ErrorAction Stop
        }
        # Час -> DateTime на сьогодні; якщо вже минув — переносимо на завтра
        $HH,$mm = $Time.Split(':')
        $start = Get-Date -Hour ([int]$HH) -Minute ([int]$mm) -Second 0
        if ($start -lt (Get-Date)) { $start = $start.AddDays(1) }

        $exe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
        if (-not $exe) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue)?.Source }
        if (-not $exe) { throw "Не знайдено pwsh/powershell у PATH." }

        $scriptPath = Join-Path $RepoRoot "day.ps1"
        $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -NonInteractive -Goal `"$Goal`""

        $action  = New-ScheduledTaskAction -Execute $exe -Argument $args
        $trigger = New-ScheduledTaskTrigger -Daily -At $start  # ВАЖЛИВО: DateTime, не TimeSpan

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Description "ATS day cycle orchestrator" -Force | Out-Null

        Write-Host "[ok] Scheduled Task '$TaskName' зареєстровано. Перша подія: $($start.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Green
    } catch {
        Write-Warning "Не вдалось зареєструвати завдання: $($_.Exception.Message)"
    }
}

# --- тільки реєстрація?
if ($RegisterTaskOnly -or $RegisterTask) {
    Register-ATSDayTask -TaskName $TaskName -Time $Time -Goal ($Goal ?? "Щоденний G4 цикл") -RepoRoot $RepoRoot
    if ($RegisterTaskOnly) { return }
}

# --- СТРОГА ІДЕМПОТЕНТНІСТЬ: якщо за день вже є html і не -Force, не запускаємо G4
$existingReport = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime | Select-Object -Last 1

if (-not $Force -and $existingReport) {
    if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }
    $reportLine = "**Report:** " + (Resolve-Path $existingReport.FullName)
    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Status:** SKIPPED (existing report; use -Force to rerun)",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[skip] Existing report found for $day → not rerunning (use -Force to override)." -ForegroundColor Yellow
    return
}

# --- goal (запитуємо лише якщо не NonInteractive)
if (-not $Goal -and -not $NonInteractive) {
    $Goal = Read-Host "Вкажи коротку ціль дня (наприклад: 'G4 PASS + чистий лог')"
}
if ($Goal) { Set-Content -Path $goalPath -Value $Goal -Encoding UTF8 }

# --- лог та основний прогін
$transcriptStarted = $false
try {
    Start-Transcript -Path $logsPath -Append -ErrorAction SilentlyContinue
    $transcriptStarted = $true

    $runner = Join-Path $RepoRoot "run.ps1"
    if (-not (Test-Path $runner)) { throw "Не знайдено $runner" }

    Write-Host "[run] Executing: & `"$runner`" -Gate G4" -ForegroundColor Cyan

    $global:LASTEXITCODE = $null
    & $runner -Gate G4
    $exit = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } elseif ($?) { 0 } else { 1 }

    # --- шукаємо звіт
    $report = Get-ChildItem -Path $reportsDir -Filter *.html -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 1

    # --- статус
    $status  = "CHECK"
    $gatesMd = Join-Path $RepoRoot "docs\gates.md"
    if (Test-Path $gatesMd) {
        $md = Get-Content $gatesMd -Raw
        $pattern = [regex]::Escape($day) + '.*?G4.*?(PASS|FAIL)'
        if     ($md -match $pattern) { $status = $Matches[1].ToUpper() }
        elseif ($exit -eq 0)         { $status = "PASS" }
    } elseif ($exit -eq 0)           { $status = "PASS" }

    # --- підсумок
    $reportLine = if ($report) { "**Report:** " + (Resolve-Path $report.FullName) }
                  else { "**Report:** (не знайдено html у reports\$day)" }

    $lines = @(
        "# Day Summary — $day",
        "",
        "**Goal:** " + ($Goal ?? "(не задано)"),
        "**Runner exit:** $exit",
        "**G4 status (heuristic):** $status",
        $reportLine,
        "",
        "_Log:_ $logsPath"
    )
    Set-Content -Path $summaryPath -Value ($lines -join "`r`n") -Encoding UTF8
    Write-Host "[ok] Summary written to $summaryPath" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    if ($transcriptStarted) { try { Stop-Transcript | Out-Null } catch { } }
}
# >> SHADOW-LIVE (9.2) START
# >> SHADOW-LIVE (9.2) START
try {
  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."
  $Date = (Get-Date).ToString('yyyy-MM-dd')
  $repo = Get-Location
  $shadowScript = Join-Path $repo 'tools/ShadowTrackerV0.ps1'
  if (Test-Path $shadowScript) {
    & $shadowScript -Date $Date | Out-Host
  } else {
    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"
  }

  # знайдемо актуальний reports/<дата> (або останній на випадок нічного рану)
  $reportDir = Join-Path $repo ("reports/" + $Date)
  if (-not (Test-Path $reportDir)) {
    $last = Get-ChildItem (Join-Path $repo 'reports') -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
    if ($last) { $reportDir = $last.FullName }
  }

  if ($reportDir -and (Test-Path $reportDir)) {
    $json = Join-Path $reportDir 'shadow-live.json'
    if (Test-Path $json) {
      $m = Get-Content $json -Raw | ConvertFrom-Json
      $fill   = [double]$m.FillRate_bySignals
      $minFill = 0.8  # тимчасово тут; у 9.3 винесемо в конфіг
      $flag = if ($m.SignalsTotal -eq 0) {
        'RED: NO_SIGNALS'
      } elseif ($fill -lt $minFill) {
        "RED: LOW_FILL_RATE ($fill < $minFill)"
      } else {
        'GREEN'
      }
      $flagPath = Join-Path $reportDir 'shadow-live.flag.txt'
      $flag | Set-Content -Path $flagPath -Encoding UTF8
      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3}" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill)
      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir 'shadow-live.html'))
    } else {
      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"
    }
  } else {
    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."
  }
} catch {
  Write-Warning ("[SHADOW 9.2] Error: " + $_.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END
.Exception.Message)
}
# << SHADOW-LIVE (9.2) END
# << SHADOW-LIVE (9.2) END

.Exception.Message)
}
# << SHADOW-WEEKLY (9.4) END


