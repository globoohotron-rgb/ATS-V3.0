param(
  [Parameter(Mandatory=$true)][string]$Rules,
  [Parameter(Mandatory=$true)][string]$Verdict,
  [Parameter(Mandatory=$true)][string]$Evidence,
  [Parameter(Mandatory=$true)][string]$Gates
)

function Need([string]$p){ if(-not (Test-Path $p)){ throw "[selftest] missing: $p" } }
function Has([string]$p,[string]$tag){ (Get-Content $p -Raw) -match [regex]::Escape($tag) }

Need $Rules;    Need $Verdict;    Need $Evidence;    Need $Gates;

$ok = $true
if (-not (Has $Rules   '# >> G5-RULES START'))        { Write-Error '[selftest] Anchor not found in G5-rules.md'; $ok = $false }
if (-not (Has $Verdict '# >> G5-VERDICT-TPL START'))  { Write-Error '[selftest] Anchor not found in G5-Verdict.template.md'; $ok = $false }
if (-not (Has $Evidence '# >> G5-EVIDENCE-TPL START')){ Write-Error '[selftest] Anchor not found in G5-EvidencePack.template.md'; $ok = $false }
if (-not (Has $Gates   '# >> G5-RULES-LINK START'))   { Write-Error '[selftest] Anchor not found in gates.md'; $ok = $false }

if (-not $ok) { exit 1 } else { Write-Host '[selftest] G5 docs OK'; exit 0 }