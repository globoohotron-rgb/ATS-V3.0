#requires -Version 7
param(
  [switch]$Restore,   # попередній перегляд без дій (дефолт); з -Restore виконує відкат
  [switch]$Overwrite  # якщо файл уже існує в місці призначення — дозволити перезапис
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Say($m,$lvl="INFO"){
  $t=Get-Date -Format "HH:mm:ss"
  if($lvl -eq "ERR"){Write-Host "$t [$lvl] $m" -ForegroundColor Red}
  elseif($lvl -eq "WARN"){Write-Host "$t [$lvl] $m" -ForegroundColor Yellow}
  else{Write-Host "$t [$lvl] $m" -ForegroundColor Green}
}

$qs = Get-ChildItem .\.trash -Recurse -File -Filter *.quarantined -ErrorAction SilentlyContinue
if(-not $qs){ Say "Quarantined файлів не знайдено — все чисто." ; exit 0 }

foreach($q in $qs){
  # ім'я без ".quarantined"
  $base = [IO.Path]::GetFileNameWithoutExtension($q.Name)
  # base64 починається після останньої крапки
  $idx = $base.LastIndexOf('.')
  if($idx -lt 0){ Say "Пропускаю: $($q.FullName) (не можу парсити)" "WARN"; continue }
  $b64 = $base.Substring($idx+1)

  try{
    $orig = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
  } catch {
    Say "Пропускаю: $($q.FullName) (погане base64)" "WARN"; continue
  }

  $destDir = Split-Path -Parent $orig
  if(-not (Test-Path $destDir)){ New-Item -ItemType Directory -Force -Path $destDir | Out-Null }

  if(Test-Path $orig -and -not $Overwrite){
    Say "Існує: $orig — пропустив (додай -Overwrite, щоб перезаписати)" "WARN"
    continue
  }

  if($Restore){
    Move-Item -LiteralPath $q.FullName -Destination $orig -Force
    Say "Відновлено → $orig"
  } else {
    Say "Буде відновлено → $orig (додай -Restore для виконання)"
  }
}

Say "Готово."
