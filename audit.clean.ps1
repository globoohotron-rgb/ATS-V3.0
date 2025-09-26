# audit.clean.ps1 — запускає пост-обробку останнього аудиту
$ErrorActionPreference = "Stop"
& "tools/audit/SanitizeAudit.ps1"
