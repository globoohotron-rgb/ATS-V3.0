@{
  Id   = '20250920-G3-052-risk-softstop'
  Name = 'G3/5.2 — risk soft-stop (daylimit/maxdd)'
  Steps = @(
    @{
      Type='EnsureBlock'; Path='scripts/ats.psm1';
      Start='# >> RISK SOFT-STOP'; End='# << RISK SOFT-STOP';
      Lines=@(
        'Set-StrictMode -Version Latest',
        '',
        'function New-RiskState {',
        '  [CmdletBinding()]',
        '  param([double]$MaxLossDay=100.0,[double]$MaxDD=150.0)',
        '  $state = [pscustomobject]@{ pnl_day=0.0; peak=0.0; trough=0.0; maxdd=0.0; tripped=$false; reason=""; maxloss_day=$MaxLossDay; maxdd_limit=$MaxDD }',
        '  return $state',
        '}',
        '',
        'function Update-RiskState {',
        '  [CmdletBinding()]',
        '  param([double]$PnL,[object]$State)',
        '  $State.pnl_day += $PnL',
        '  if ($State.pnl_day -gt $State.peak) { $State.peak = $State.pnl_day }',
        '  if ($State.pnl_day -lt $State.trough) { $State.trough = $State.pnl_day }',
        '  $dd = $State.peak - $State.pnl_day',
        '  if ($dd -gt $State.maxdd) { $State.maxdd = $dd }',
        '  if (-not $State.tripped) {',
        '    if ($State.pnl_day -le -$State.maxloss_day) { $State.tripped = $true; $State.reason = "day_limit" }',
        '    elseif ($State.maxdd -ge $State.maxdd_limit) { $State.tripped = $true; $State.reason = "maxdd" }',
        '  }',
        '  return $State',
        '}',
        '',
        'function Risk-ShouldStop {',
        '  [CmdletBinding()] param([object]$State)',
        '  return [bool]$State.tripped',
        '}'
      )
    },
    @{
      Type='EnsureBlock'; Path='docs/formats.md';
      Start='<!-- >> RISK-HANDLES FORMAT -->'; End='<!-- << RISK-HANDLES FORMAT -->';
      Lines=@(
        '## Risk handles (paper mode)',
        '',
        '- **State fields**: `pnl_day`, `peak`, `trough`, `maxdd`, `tripped`, `reason`, `maxloss_day`, `maxdd_limit`.',
        '- **Trip rules**: `pnl_day <= -maxloss_day` → `reason=day_limit`; `maxdd >= maxdd_limit` → `reason=maxdd`.',
        '- **Artifact (QC/demo)**: `runs/_tests_risk/risk_report.json`.',
        ''
      )
    }
  )
  QC = @{
    Command = 'pwsh';
    Args    = @(
      '-NoProfile','-Command',
      'New-Item -ItemType Directory -Force -Path "runs/_tests_risk" | Out-Null; ' +
      '$p = "runs/_tests_risk/risk_report.json"; ' +
      '$s = [pscustomobject]@{ pnl_day=0.0; peak=0.0; trough=0.0; maxdd=0.0; tripped=$false; reason=""; maxloss_day=100.0; maxdd_limit=150.0 }; ' +
      'function _u([double]$q){ $script:s = $s; $s.pnl_day += $q; if($s.pnl_day -gt $s.peak){$s.peak=$s.pnl_day}; if($s.pnl_day -lt $s.trough){$s.trough=$s.pnl_day}; $dd=$s.peak-$s.pnl_day; if($dd -gt $s.maxdd){$s.maxdd=$dd}; if(-not $s.tripped){ if($s.pnl_day -le -$s.maxloss_day){$s.tripped=$true; $s.reason="day_limit"} elseif($s.maxdd -ge $s.maxdd_limit){$s.tripped=$true; $s.reason="maxdd"} } }; ' +
      '_u -50; _u -60; _u -10; ' +
      '$s | ConvertTo-Json | Set-Content -LiteralPath $p; ' +
      'if (-not $s.tripped) { throw "risk not tripped" }'
    )
  }
}