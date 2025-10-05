# --- A1 FIX (robust script:repRoot) ---
$script:__here = $PSScriptRoot
if (-not $script:__here) { try { $script:__here = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {} }
if (-not $script:__here) { $script:__here = (Get-Location).Path }
$script:repRoot = Split-Path -Parent $script:__here
# --- /A1 FIX ---
# --- A1 FIX (robust repRoot): handle null $PSScriptRoot under Pester ---
$__here = $PSScriptRoot
if (-not $__here) { try { $__here = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {} }
if (-not $__here) { $__here = (Get-Location).Path }
$script:repRoot = Split-Path -Parent $__here
# --- /A1 FIX ---



