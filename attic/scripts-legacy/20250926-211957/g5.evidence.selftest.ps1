param()
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
$inv  = Join-Path $root "scripts\Invoke-G5WF.ps1"
$evid = Join-Path $root "scripts\g5.evidence.ps1"

# 1) Свіжий WF (demo), щоб точно були артефакти
try { & $inv -WFProfile demo | Out-Null } catch { Write-Host "[warn] WF run issue: $_" }

# 2) Генеруємо EvidencePack ТІЛЬКИ якщо вердикт REJECT.
#    Для перевірки механіки можна тимчасово додати -ForceVerdict REJECT
& $evid # -ForceVerdict REJECT