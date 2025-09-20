Set-StrictMode -Version Latest

function Get-OrderLogPath {
  [CmdletBinding()] param([object]$Context,[string]$OverrideDir)
  $d=(Get-Date).ToString("yyyy-MM-dd")
  if($Context -and $Context.PSObject.Properties.Name -contains "RunDir" -and (Test-Path $Context.RunDir)) { $dir=$Context.RunDir }
  elseif($OverrideDir) { $dir=$OverrideDir }
  else { $dir = Join-Path (Join-Path "runs" $d) "run-manual" }
  if(-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Join-Path $dir "orders.log.csv"
}

function Initialize-OrderLog {
  [CmdletBinding()] param([string]$Path)
  if(-not (Test-Path $Path)) {
    New-Item -ItemType File -Force -Path $Path | Out-Null
    "timestamp,symbol,side,qty,price,reason,risk_state" | Set-Content -LiteralPath $Path
  }
}

function Write-OrderLog {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Symbol,
    [Parameter(Mandatory=$true)][ValidateSet("Buy","Sell","Short","Cover")][string]$Side,
    [double]$Qty=0,[double]$Price=0,[string]$Reason="",[string]$Risk_State="",
    [object]$Context,[string]$OverrideDir
  )
  $p = Get-OrderLogPath -Context $Context -OverrideDir $OverrideDir
  Initialize-OrderLog -Path $p
  $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  $line = "{0},{1},{2},{3},{4},{5},{6}" -f $ts,$Symbol,$Side,
          ([double]::Parse($Qty.ToString())),([double]::Parse($Price.ToString())),
          $Reason.Replace(",",";"),$Risk_State.Replace(",",";")
  Add-Content -LiteralPath $p -Value $line
  return $p
}

Export-ModuleMember -Function Get-OrderLogPath,Initialize-OrderLog,Write-OrderLog