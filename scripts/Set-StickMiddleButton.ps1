<#
.SYNOPSIS
  Switches the Alps pointing-stick middle button between a real middle click and
  the driver's scroll mode, then restarts the Alps helper so it takes effect.
.DESCRIPTION
  Sets HKCU\Software\Alps\Apoint\Button\SPFunction3 for the current user:
    MiddleClick = 14  the button sends a normal middle click, so browsers get
                      middle-click-to-close-tab and their own autoscroll.
    Scroll      = 16  the driver's default on this machine: the press is swallowed
                      and holding it turns finger movement into scrolling.
  The values were observed on a Dell Latitude 7490 with Alps driver 10.3201.101.216;
  Alps does not document them. The whole HKCU\Software\Alps\Apoint key is exported
  to a .reg backup first. Double-click that file to restore it.
  Needs no admin rights. Supports -WhatIf.
.PARAMETER Mode
  MiddleClick or Scroll.
.PARAMETER BackupDir
  Folder for the .reg backup. Default: %TEMP%
.PARAMETER NoRestart
  Change the setting but do not restart the Alps helper (it then applies at next sign-in).
.EXAMPLE
  .\scripts\Set-StickMiddleButton.ps1 -Mode MiddleClick
.EXAMPLE
  .\scripts\Set-StickMiddleButton.ps1 -Mode Scroll -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][ValidateSet('MiddleClick', 'Scroll')][string]$Mode,
  [string]$BackupDir = $env:TEMP,
  [switch]$NoRestart
)
$ErrorActionPreference = 'Stop'

$key = 'HKCU:\Software\Alps\Apoint\Button'
$value = @{ MiddleClick = 14; Scroll = 16 }[$Mode]
$apoint = Join-Path $env:SystemRoot 'System32\DellTPad\Apoint.exe'

if (-not (Test-Path $key)) {
  throw "No Alps settings at $key. This script is for the Alps (Dell) pointing-stick driver."
}
$current = (Get-ItemProperty $key).SPFunction3
Write-Output "SPFunction3 is $current; target $value ($Mode)."
if ($current -eq $value) {
  Write-Output 'Already set. Nothing to do. (If an earlier run used -NoRestart, sign out and back in.)'
  if (-not (Get-Process Apoint -ErrorAction SilentlyContinue)) {
    Write-Warning 'The Alps helper (Apoint) is not running, so the setting is not applied. Run Restart-AlpsHelper.ps1.'
  }
  return
}

if ($PSCmdlet.ShouldProcess($key, "back up HKCU\Software\Alps\Apoint, set SPFunction3 = $value")) {
  if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir | Out-Null }
  $backup = Join-Path $BackupDir ("alps-apoint-backup-{0:yyyyMMdd-HHmmss}.reg" -f (Get-Date))
  & reg.exe export 'HKCU\Software\Alps\Apoint' $backup /y | Out-Null
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $backup)) { throw "Backup failed; nothing changed." }
  Write-Output "Backup: $backup"
  Set-ItemProperty $key -Name SPFunction3 -Value $value -Type DWord
  Write-Output "SPFunction3 is now $((Get-ItemProperty $key).SPFunction3)."
}

if ($NoRestart) {
  if (-not $WhatIfPreference) { Write-Output 'Not restarting the Alps helper; the change applies at next sign-in.' }
  return
}
if (-not (Test-Path $apoint)) { Write-Warning "Apoint.exe not found at $apoint; sign out and back in to apply."; return }
& (Join-Path $PSScriptRoot 'Restart-AlpsHelper.ps1')
