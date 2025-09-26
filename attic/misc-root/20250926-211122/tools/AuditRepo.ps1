param(
  [string[]]$ExcludeDirs = @(".git",".github","reports","runs",".vscode"),
  [double]$LargeMB = 5.0
)

$ErrorActionPreference = "Stop"
$root = (Get-Location).Path
$now  = Get-Date
$stamp = $now.ToString("yyyy-MM-dd_HHmm")
$auditDir = Join-Path $root ("reports/audit/" + $stamp)
New-Item -ItemType Directory -Path $auditDir -Force | Out-Null

function Is-TextFile([string]$p){ try { (Get-Content -Path $p -Raw -Encoding Byte -TotalCount 1024) -notcontains 0 } catch { $false } }
function Rel([string]$p){ $p.Substring($root.Length+1) }
function Esc([string]$s){ if([string]::IsNullOrEmpty($s)) { '' } else { [System.Security.SecurityElement]::Escape($s) } }

# 1) Файли
$all = Get-ChildItem -Path $root -Recurse -File -Force |
  Where-Object {
    $rel = Rel $_.FullName
    -not ($ExcludeDirs | ForEach-Object { $rel -like ("$_/*") -or $rel -eq $_ } | Where-Object { $_ }) `
    -and -not ($rel -like "reports/*" -or $rel -like "runs/*")
  }

$files = @()
foreach($f in $all){
  $rel = Rel $f.FullName
  $ext = [IO.Path]::GetExtension($f.Name).ToLower()
  $isPS = $ext -in @(".ps1",".psm1",".psd1")
  $sizeMB = [math]::Round($f.Length/1MB,3)
  $lines = $null
  if ($isPS -and (Is-TextFile $f.FullName)) { try { $lines = (Get-Content -Path $f.FullName).Count } catch {} }
  $hash = $null
  if ($f.Length -le [int](5MB)) { try { $hash = (Get-FileHash -Algorithm SHA1 -Path $f.FullName).Hash } catch {} }
  $files += [pscustomobject]@{
    Path=$f.FullName; Rel=$rel; Dir=(Split-Path $rel); Name=$f.Name; Ext=$ext
    SizeBytes=$f.Length; SizeMB=$sizeMB; Lines=$lines; SHA1=$hash; IsPS=$isPS; MTime=$f.LastWriteTime
  }
}

# 2) Підозрілі/великі
$backupLike = $files | Where-Object {
  $_.Name -match '\.bak($|\.)' -or $_.Name -match '(^|[-_.])bak($|[-_.])' -or
  $_.Name -match 'backup' -or $_.Name -match 'copy' -or $_.Name -match '\.(tmp|temp)$' -or
  $_.Name -match '\-bak\-'
}
$large = $files | Where-Object { $_.SizeMB -gt $LargeMB }

# 3) Дублі
$dups = $files | Where-Object SHA1 | Group-Object SHA1 | Where-Object Count -gt 1 |
  ForEach-Object {
    [pscustomobject]@{
      SHA1=$_.Name; Count=$_.Count; Files=($_.Group | Select-Object Rel,SizeMB,Name | Sort-Object Rel)
    }
  }

# 4) Референси з .ps1/.psm1 (regex + Join-Path)
$refEdges = @()
$psFiles = $files | Where-Object { $_.IsPS -and $_.Ext -ne ".psd1" }
$rxPath1 = '(?i)(?:\.\.?[\\/])?(config|scripts|tools|data|reports|runs|logs)[\\/][\w\.\-_/]+'         # прямі рядки шляхів
$rxPath2 = '(?i)Join-Path\s+[^\r\n]*?["'']((?:\.\.?[\\/])?(config|scripts|tools|data|reports|runs|logs)[^"'']+)["'']'  # Join-Path "tools/..."
foreach($pf in $psFiles){
  try {
    $txt = Get-Content -Path $pf.Path -Raw
    $m1 = [regex]::Matches($txt, $rxPath1) | ForEach-Object { $_.Value }
    $m2 = [regex]::Matches($txt, $rxPath2) | ForEach-Object { $_.Groups[1].Value }
    $uniq = @{}
    foreach($raw in ($m1 + $m2)){
      $norm = ($raw -replace '\\','/').TrimStart('./').Trim()
      if ($norm) { $uniq[$norm] = $true }
    }
    foreach($k in $uniq.Keys){
      $refEdges += [pscustomobject]@{ From=$pf.Rel; To=$k }
    }
  } catch {}
}

# 5) Досяжність від entrypoints (усі .ps1 у корені + стандартні + Shadow*)
$relSet = $files | ForEach-Object { $_.Rel }
$rootEntries = Get-ChildItem -Path $root -File -Filter *.ps1 | ForEach-Object { $_.Name }
$entryRel = @('day.ps1','week.ps1','dash.ps1','QC_case.ps1') +
            ($files | Where-Object { $_.Rel -like 'tools/Shadow*.ps1' } | Select-Object -ExpandProperty Rel) +
            $rootEntries
$entryRel = $entryRel | Select-Object -Unique | Where-Object { $relSet -contains $_ }

$edgeMap = $refEdges | Group-Object From -AsHashTable -AsString
$reachable = [System.Collections.Generic.HashSet[string]]::new()
$queue     = [System.Collections.Generic.Queue[string]]::new()
foreach($e in $entryRel){ $reachable.Add($e) | Out-Null; $queue.Enqueue($e) }

while($queue.Count -gt 0){
  $cur = $queue.Dequeue()
  if (-not $edgeMap.ContainsKey($cur)) { continue }
  foreach($edge in $edgeMap[$cur]){
    $cand = ($edge.To -replace '\\','/').Trim('/')

    # Спочатку точна відповідність Rel
    $found = $files | Where-Object { $_.Rel -eq $cand }

    # Якщо не знайшли — по імені файлу (leaf)
    if (-not $found) {
      $leaf = Split-Path $cand -Leaf
      if ($leaf) { $found = $files | Where-Object { $_.Name -ieq $leaf } }
    }

    foreach($f in $found){
      if (-not $reachable.Contains($f.Rel)) { $reachable.Add($f.Rel) | Out-Null; $queue.Enqueue($f.Rel) }
    }
  }
}

$unref = $files | Where-Object {
  $_.Rel -notin $reachable -and $_.Dir -notlike 'reports*' -and $_.Dir -notlike 'runs*'
}

# 6) Підсумок + JSON
$summary = [ordered]@{
  ScannedFiles      = $files.Count
  PSFiles           = ($files | Where-Object IsPS).Count
  BackupLike        = $backupLike.Count
  LargeFiles        = $large.Count
  DuplicateGroups   = ($dups | Measure-Object).Count
  EntryPoints       = $entryRel
  ReachableFiles    = $reachable.Count
  UnreferencedFiles = $unref.Count
  GeneratedAt       = $now
}
$result = [pscustomobject]@{
  Summary = $summary
  Files   = $files
  BackupLike = $backupLike | Select-Object Rel,Name,Dir,SizeMB
  LargeFiles = $large      | Select-Object Rel,Name,Dir,SizeMB
  Duplicates = $dups
  Refs    = $refEdges
  Unreferenced = $unref | Select-Object Rel,Name,Dir,SizeMB
}
($result | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $auditDir 'index.json') -Encoding UTF8

# 7) Рендер (фіксована Table())
function Table($rows, $cols){
  if(-not $rows){ return '' }
  $ths = ($cols | ForEach-Object { "<th>$($_)</th>" }) -join ''
  $trs = ($rows | ForEach-Object {
    $r = $_
    $tds = ($cols | ForEach-Object {
      $col = $_
      $v = $r.$col
      "<td>" + (Esc([string]$v)) + "</td>"
    }) -join ''
    "<tr>$tds</tr>"
  }) -join "`n"
  "<table><thead><tr>$ths</tr></thead><tbody>$trs</tbody></table>"
}

$bk  = Table $result.BackupLike   @('Rel','Name','Dir','SizeMB')
$lg  = Table $result.LargeFiles   @('Rel','Name','Dir','SizeMB')
$dupRows = @()
foreach($g in $dups){
  $filesHtml = (($g.Files | ForEach-Object { "<div>" + (Esc($_.Rel)) + " (" + $_.SizeMB + " MB)</div>" }) -join '')
  $dupRows += [pscustomobject]@{ SHA1=$g.SHA1; Count=$g.Count; Files=$filesHtml }
}
$dup = Table $dupRows @('SHA1','Count','Files')
$ur  = Table $result.Unreferenced @('Rel','Name','Dir','SizeMB')

$html = @"
<!doctype html><html><head><meta charset='utf-8'>
<title>Repo Audit — $stamp</title>
<style>
body{font-family:ui-sans-serif,system-ui,Segoe UI,Arial;margin:20px}
h1{margin:0 0 8px}
.kv{display:grid;grid-template-columns:220px 1fr;gap:6px 12px;max-width:820px}
.kv div{padding:6px 8px;background:#f7f7f9;border:1px solid #eee;border-radius:8px}
table{border-collapse:collapse;margin-top:16px;font-size:13px}
td,th{border:1px solid #e5e5e5;padding:6px 8px} th{background:#fafafa}
.sub{margin-top:22px}
.small{color:#666;font-size:12px}
</style></head><body>
<h1>Repo Audit — $stamp</h1>
<div class='kv'>
  <div>ScannedFiles</div><div>$($summary.ScannedFiles)</div>
  <div>PSFiles</div><div>$($summary.PSFiles)</div>
  <div>BackupLike</div><div>$($summary.BackupLike)</div>
  <div>LargeFiles (&gt;$([math]::Round($LargeMB,2)) MB)</div><div>$($summary.LargeFiles)</div>
  <div>DuplicateGroups</div><div>$($summary.DuplicateGroups)</div>
  <div>ReachableFiles</div><div>$($summary.ReachableFiles)</div>
  <div>UnreferencedFiles</div><div>$($summary.UnreferencedFiles)</div>
  <div>EntryPoints</div><div>$([string]::Join(', ',$summary.EntryPoints))</div>
</div>

<div class='sub'><h2>Backup-like candidates</h2>$bk</div>
<div class='sub'><h2>Large files</h2>$lg</div>
<div class='sub'><h2>Duplicate groups</h2>$dup</div>
<div class='sub'><h2>Unreferenced candidates</h2>$ur</div>

<p class='small'>Edges: $($refEdges.Count). JSON: index.json. Excludes: $([string]::Join(', ',$ExcludeDirs)) + reports/runs.</p>
</body></html>
"@

$index = Join-Path $auditDir 'index.html'
$html | Set-Content -Path $index -Encoding UTF8
if (Test-Path $index) { Write-Host "AUDIT PASS => $index" } else { Write-Host "AUDIT WARN: render failed."; exit 1 }
