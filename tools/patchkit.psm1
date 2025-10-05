# tools/patchkit.psm1 — minimal patch system (safe-by-default)
# Features: New-RepoSnapshot, Test-PatchSpec, Invoke-PatchSpec (AddFile/ReplaceText/DeletePath with backups)

#region helpers
function Get-RepoRoot {
  (Get-Item -LiteralPath (Get-Location)).FullName
}
function Join-UnderRoot {
  param([Parameter(Mandatory)][string]$Path)
  $root = Get-RepoRoot
  $full = Resolve-Path -LiteralPath (Join-Path $root $Path) -ErrorAction SilentlyContinue
  if (-not $full) { $full = Join-Path $root $Path } else { $full = $full.Path }
  if (-not ($full -like "$root*")) { throw "Path escapes repo root: $Path" }
  return $full
}
function New-DirSafe { param([string]$Path) if (-not (Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }
function Backup-Path {
  param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Target)
  $rel = (Resolve-Path -LiteralPath $Target).Path.Replace((Get-RepoRoot()),'').TrimStart('\','/')
  $dst = Join-Path "artifacts/patches/backups/$Id" $rel
  $dstDir = Split-Path -Parent $dst
  New-DirSafe -Path $dstDir
  if (Test-Path -LiteralPath $Target -PathType Leaf) { Copy-Item -LiteralPath $Target -Destination $dst -Force }
  elseif (Test-Path -LiteralPath $Target -PathType Container) { Copy-Item -LiteralPath $Target -Destination $dst -Recurse -Force }
}
#endregion

function New-RepoSnapshot {
  param([string[]]$Exclude = @('.git','runs','reports','artifacts/patches/backups'))
  $root = Get-RepoRoot
  $files = Get-ChildItem -LiteralPath $root -File -Recurse | Where-Object {
    $p = $_.FullName
    -not ($Exclude | ForEach-Object { $p -like (Join-Path $root $_) + '*' } | Where-Object { $_ })
  }
  $out = $files | ForEach-Object {
    [PSCustomObject]@{
      Path = $_.FullName.Replace($root,'').TrimStart('\','/')
      Hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
      Size = $_.Length
    }
  }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $snapPath = "artifacts/patches/snapshots/snapshot-$stamp.json"
  $out | ConvertTo-Json -Depth 4 | Out-File -FilePath $snapPath -Encoding UTF8
  return $snapPath
}

function Test-PatchSpec {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)
  $spec = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  if (-not $spec.Id)    { throw "Spec missing Id" }
  if (-not $spec.Title) { throw "Spec missing Title" }
  if (-not $spec.Changes) { throw "Spec missing Changes[]" }
  foreach($c in $spec.Changes){
    if (-not $c.Action) { throw "Change missing Action" }
    if (-not $c.Path)   { throw "Change missing Path" }
    $null = Join-UnderRoot -Path $c.Path # path traversal guard
    switch ($c.Action) {
      'AddFile'      { if (-not $c.Content) { throw "AddFile requires Content" } }
      'ReplaceText'  { if (-not $c.Pattern) { throw "ReplaceText requires Pattern" } }
      'DeletePath'   { } # ok
      default        { throw "Unsupported Action: $($c.Action)" }
    }
  }
  [PSCustomObject]@{ Ok = $true; Spec = $spec }
}

function Invoke-PatchSpec {
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][string]$Path)
  $test = Test-PatchSpec -Path $Path
  $spec = $test.Spec
  $id = $spec.Id
  $log = @()
  $log += "Patch $id — $($spec.Title)"
  $log += "When: $(Get-Date -Format 'u')"
  $log += "Spec: $Path"
  $log += "Snapshot: $(New-RepoSnapshot)"

  foreach($c in $spec.Changes){
    $target = Join-UnderRoot -Path $c.Path
    switch ($c.Action) {
      'AddFile' {
        if ($PSCmdlet.ShouldProcess($target,'AddFile')) {
          New-DirSafe -Path (Split-Path -Parent $target)
          if (Test-Path -LiteralPath $target) { Backup-Path -Id $id -Target $target }
          $content = if ($c.ContentBase64) { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($c.ContentBase64)) } else { [string]$c.Content }
          Set-Content -LiteralPath $target -Value $content -Encoding UTF8
          $log += "AddFile: $($c.Path)"
        }
      }
      'ReplaceText' {
        if ($PSCmdlet.ShouldProcess($target,'ReplaceText')) {
          if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "ReplaceText target not found: $($c.Path)" }
          Backup-Path -Id $id -Target $target
          $txt = Get-Content -LiteralPath $target -Raw
          $repl = [Regex]::Replace($txt, $c.Pattern, [string]$c.Replacement, [System.Text.RegularExpressions.RegexOptions]::Singleline)
          Set-Content -LiteralPath $target -Value $repl -Encoding UTF8
          $log += "ReplaceText: $($c.Path) pattern=$($c.Pattern)"
        }
      }
      'DeletePath' {
        if ($PSCmdlet.ShouldProcess($target,'DeletePath')) {
          if (Test-Path -LiteralPath $target) {
            Backup-Path -Id $id -Target $target
            Remove-Item -LiteralPath $target -Recurse -Force
            $log += "DeletePath: $($c.Path)"
          } else { $log += "DeletePath: $($c.Path) (already absent)" }
        }
      }
    }
  }

  $repDir = Join-Path 'reports' (Get-Date -Format 'yyyy-MM-dd')
  New-Item -ItemType Directory -Path $repDir -Force | Out-Null
  $md = @("# Patch Log — $id", "", "**Title:** $($spec.Title)", "**When:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')", "", "## Steps", "") + ($log | ForEach-Object { "- $_" })
  $out = Join-Path $repDir "patch-$id.md"
  $md -join "`r`n" | Out-File -LiteralPath $out -Encoding UTF8
  Write-Host "Patch applied. Log: $out" -ForegroundColor Green
  return $out
}

Export-ModuleMember -Function *-*
