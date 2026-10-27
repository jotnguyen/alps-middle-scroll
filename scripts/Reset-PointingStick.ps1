<#
.SYNOPSIS
  Restarts the touchpad and pointing-stick device so the stick recalibrates, for a
  pointer that drifts by itself.
.DESCRIPTION
  A pointing stick treats its current reading as "no force" whenever it thinks nobody
  is touching it. If that happens while something presses on it, the pointer drifts.
  Restarting the device makes it take a new rest reading.
  Keep your fingers off the stick until it comes back, a few seconds. The touchpad and
  stick stop briefly; the keyboard and touch screen keep working.
  Finds the parent of the Alps "Dell Touchpad" HID collection (on a Latitude 7490, the
  I2C HID device ACPI\DELL081C) and restarts it with pnputil /restart-device.
  Needs admin rights. Afterwards, restart the Alps helper as yourself with
  Restart-AlpsHelper.ps1, not from the elevated window. Supports -WhatIf, which needs
  no admin rights.
.EXAMPLE
  .\scripts\Reset-PointingStick.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference = 'Stop'

$col = Get-PnpDevice -PresentOnly -FriendlyName 'Dell Touchpad' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $col) { throw 'No "Dell Touchpad" device found. This script is for the Alps (Dell) touchpad driver.' }
$parent = (Get-PnpDeviceProperty -InstanceId $col.InstanceId -KeyName DEVPKEY_Device_Parent -WhatIf:$false).Data
if (-not $parent) { throw "Could not find the parent device of $($col.FriendlyName)." }
# Print only the hardware ID; the instance suffix is unique to this machine.
$hwid = ($parent -split '\\')[0..1] -join '\'
Write-Output "Touchpad device: $hwid"

if ($PSCmdlet.ShouldProcess($hwid, 'restart the device (pnputil /restart-device)')) {
  $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Restarting a device needs admin rights. Run this from an elevated PowerShell.'
  }
  Write-Output 'Restarting. Keep your fingers off the stick for a few seconds.'
  & pnputil.exe /restart-device $parent | Out-Null
  if ($LASTEXITCODE -eq 3010) { Write-Warning 'Windows wants a reboot to finish restarting the device.' }
  elseif ($LASTEXITCODE -ne 0) { throw "pnputil failed with exit code $LASTEXITCODE." }
  Start-Sleep -Seconds 3
  Write-Output "Device status: $((Get-PnpDevice -InstanceId $parent).Status)"
}
