<#
.SYNOPSIS
  Restarts the Alps pointing-stick helper (Apoint.exe and its companions), or starts
  it if it is not running.
.DESCRIPTION
  Apoint applies the settings under HKCU\Software\Alps\Apoint, the stick middle button
  among them, and reads them only when it starts. If Apoint hangs, Windows closes it
  and nothing starts it again until the next sign-in. Without it the stick middle
  button stops working in browsers (observed on a Latitude 7490, with SPFunction3
  still set to middle click).
  Runs as the current user and needs no admin rights. Don't run it from an elevated
  window, or Apoint runs elevated too. Supports -WhatIf.
.EXAMPLE
  .\scripts\Restart-AlpsHelper.ps1
.EXAMPLE
  .\scripts\Restart-AlpsHelper.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference = 'Stop'

$apoint = Join-Path $env:SystemRoot 'System32\DellTPad\Apoint.exe'
if (-not (Test-Path $apoint)) {
  throw "Apoint.exe not found at $apoint. This script is for the Alps (Dell) pointing-stick driver."
}

$oldIds = @(Get-Process Apoint -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
if ($oldIds.Count) {
  if (-not $PSCmdlet.ShouldProcess('Apoint, ApntEx, ApMsgFwd, ApRemote', 'restart the Alps helper processes')) { return }
  # ApMsgFwd may refuse to stop (it can run elevated); Apoint restarting is what matters.
  Get-Process Apoint, ApntEx, ApMsgFwd, ApRemote -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  if (Get-Process Apoint -ErrorAction SilentlyContinue | Where-Object { $oldIds -contains $_.Id }) {
    Write-Warning 'Apoint would not stop (it may run elevated); sign out and back in to apply.'
    return
  }
} elseif (-not $PSCmdlet.ShouldProcess('Apoint', 'start the Alps helper (it is not running)')) {
  return
}

Start-Process $apoint
Start-Sleep -Seconds 4
if (Get-Process Apoint -ErrorAction SilentlyContinue) { Write-Output 'Alps helper running.' }
else { Write-Warning 'Apoint did not come back; sign out and back in.' }
