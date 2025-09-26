@{
  Id   = '20250925-9_2-shadow'
  Name = 'Integrate ShadowTracker into day.ps1 with RED flags'
  Steps = @(
    @{
      Type = 'EnsureBlock'
      Path = 'day.ps1'
      Start= '# >> SHADOW-LIVE (9.2) START'
      End  = '# << SHADOW-LIVE (9.2) END'
      Lines = @(
        '# >> SHADOW-LIVE (9.2) START',
        'try {',
        '  Write-Host "[SHADOW 9.2] Збираю метрики shadow-live..."',
        '  $Date = (Get-Date).ToString(''yyyy-MM-dd'')',
        '  $repo = Get-Location',
        '  $shadowScript = Join-Path $repo ''tools/ShadowTrackerV0.ps1''',
        '  if (Test-Path $shadowScript) {',
        '    & $shadowScript -Date $Date | Out-Host',
        '  } else {',
        '    Write-Warning "[SHADOW 9.2] Не знайдено tools/ShadowTrackerV0.ps1"',
        '  }',
        '',
        '  # знайдемо актуальний reports/<дата> (або останній на випадок нічного рану)',
        '  $reportDir = Join-Path $repo ("reports/" + $Date)',
        '  if (-not (Test-Path $reportDir)) {',
        '    $last = Get-ChildItem (Join-Path $repo ''reports'') -Directory -ErrorAction SilentlyContinue |',
        '            Sort-Object Name -Descending | Select-Object -First 1',
        '    if ($last) { $reportDir = $last.FullName }',
        '  }',
        '',
        '  if ($reportDir -and (Test-Path $reportDir)) {',
        '    $json = Join-Path $reportDir ''shadow-live.json''',
        '    if (Test-Path $json) {',
        '      $m = Get-Content $json -Raw | ConvertFrom-Json',
        '      $fill   = [double]$m.FillRate_bySignals',
        '      $minFill = 0.8  # тимчасово тут; у 9.3 винесемо в конфіг',
        '      $flag = if ($m.SignalsTotal -eq 0) {',
        '        ''RED: NO_SIGNALS''',
        '      } elseif ($fill -lt $minFill) {',
        '        "RED: LOW_FILL_RATE ($fill < $minFill)"',
        '      } else {',
        '        ''GREEN''',
        '      }',
        '      $flagPath = Join-Path $reportDir ''shadow-live.flag.txt''',
        '      $flag | Set-Content -Path $flagPath -Encoding UTF8',
        '      Write-Host ("[SHADOW 9.2] Flag: {0} | Signals={1} | Orders={2} | FillRate={3}" -f $flag,$m.SignalsTotal,$m.OrdersTotal,$fill)',
        '      Write-Host ("[SHADOW 9.2] HTML: " + (Join-Path $reportDir ''shadow-live.html''))',
        '    } else {',
        '      Write-Warning "[SHADOW 9.2] Не знайдено shadow-live.json у $reportDir"',
        '    }',
        '  } else {',
        '    Write-Warning "[SHADOW 9.2] Немає каталогу reports/<дата>."',
        '  }',
        '} catch {',
        '  Write-Warning ("[SHADOW 9.2] Error: " + $_.Exception.Message)',
        '}',
        '# << SHADOW-LIVE (9.2) END'
      )
    }
  )
  QC = @{ Command = 'pwsh'; Args = @('-NoProfile','-Command','"Write-Host ''QC: spec parsed''"') }
}
