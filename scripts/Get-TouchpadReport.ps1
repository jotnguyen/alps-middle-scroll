<#
.SYNOPSIS
  Read-only report on the touchpad / pointing-stick input stack: hardware, drivers,
  Alps helper processes and settings, Windows precision-touchpad settings, recent
  feature updates, and the Firefox prefs that affect scrolling.
.DESCRIPTION
  Changes nothing. Device instance suffixes (which can hold serials or Bluetooth
  addresses) are cut off, so the output is safer to paste into an issue. Still read
  it before you share it.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\Get-TouchpadReport.ps1
#>
[CmdletBinding()]
param()

Add-Type @"
using System; using System.Runtime.InteropServices;
public static class RegKeyTime {
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode)] static extern int RegOpenKeyEx(UIntPtr h, string sub, int opt, int sam, out UIntPtr r);
  [DllImport("advapi32.dll")] static extern int RegQueryInfoKey(UIntPtr h, IntPtr c, IntPtr cl, IntPtr res, IntPtr sk, IntPtr msk, IntPtr mcl, IntPtr v, IntPtr mvn, IntPtr mvl, IntPtr sd, out long ft);
  [DllImport("advapi32.dll")] static extern int RegCloseKey(UIntPtr h);
  // Last-write time of a key under HKEY_CURRENT_USER, or null if it does not exist.
  public static DateTime? HkcuLastWrite(string sub) {
    UIntPtr k; if (RegOpenKeyEx(new UIntPtr(0x80000001u), sub, 0, 0x20019, out k) != 0) return null;
    long ft; RegQueryInfoKey(k, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out ft);
    RegCloseKey(k); return DateTime.FromFileTime(ft);
  }
}
"@

function Section($name) { Write-Output ''; Write-Output "=== $name" }
# HID\DELL081C&COL03\5&XXXXXXX&0&0002 -> HID\DELL081C&COL03. Bluetooth LE devices also
# carry their address in the hardware ID (..._D1F2A3B4C5D6&COL01), so blank that too.
function Strip-Instance($id) {
  (($id -split '\\')[0..1] -join '\') -replace '_[0-9A-Fa-f]{12}(?=&|$)', '_<addr>'
}
$pointing = 'touch|track|pointing|alps|synap|elan|i2c hid|mouse'

Section 'Machine'
$cs = Get-CimInstance Win32_ComputerSystem
$os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Output "$($cs.Manufacturer) $($cs.Model)"
Write-Output "Windows $($os.DisplayVersion), build $($os.CurrentBuild).$($os.UBR)"

Section 'Pointing devices (present)'
Get-PnpDevice -PresentOnly |
  Where-Object { $_.Class -in 'Mouse','HIDClass' -and ($_.FriendlyName -match $pointing -or $_.InstanceId -match 'VID_044E|DELL0') } |
  Sort-Object InstanceId |
  ForEach-Object { '{0,-4} {1,-38} {2}' -f $_.Status, $_.FriendlyName, (Strip-Instance $_.InstanceId) }

Section 'Drivers'
Get-CimInstance Win32_PnPSignedDriver |
  Where-Object { $_.DeviceName -match $pointing -or $_.Manufacturer -match 'alps' } |
  Sort-Object DeviceName |
  ForEach-Object { '{0,-36} {1,-18} {2,-14} {3}' -f $_.DeviceName, $_.DriverVersion, $_.InfName, $_.Manufacturer }

Section 'Alps helper processes'
$procs = Get-Process Apoint, ApntEx, ApMsgFwd, ApRemote, HidMonitorSvc -ErrorAction SilentlyContinue
if ($procs) { $procs | ForEach-Object { '{0,-14} started {1}' -f $_.ProcessName, $_.StartTime } }
else { Write-Output '(none running: no Alps driver, or it is not started)' }

Section 'Alps button settings (HKCU\Software\Alps\Apoint\Button)'
$btn = Get-ItemProperty 'HKCU:\Software\Alps\Apoint\Button' -ErrorAction SilentlyContinue
if ($btn) {
  foreach ($n in 'SPFunction1','SPFunction2','SPFunction3','ButtonFunction3','MouFunction3') {
    Write-Output ('{0,-16} {1}' -f $n, $btn.$n)
  }
  Write-Output 'SPFunction3 is the pointing-stick middle button: 16 = scroll mode, 14 = middle click (observed on a Latitude 7490).'
} else { Write-Output '(no Alps settings for this user)' }

Section 'Windows precision touchpad (HKCU\...\PrecisionTouchPad)'
$ptp = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad' -ErrorAction SilentlyContinue
if ($ptp) {
  $ptp.PSObject.Properties | Where-Object Name -notlike 'PS*' |
    ForEach-Object { '{0,-24} {1}' -f $_.Name, $_.Value }
} else { Write-Output '(not a precision touchpad, or no settings yet)' }

Section 'Registry keys last changed'
foreach ($k in 'Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad',
               'Software\Alps\Apoint\Button',
               'Software\Alps\Apoint\Stick',
               'Control Panel\Mouse') {
  $t = [RegKeyTime]::HkcuLastWrite($k)
  Write-Output ('{0,-22} {1}' -f $(if ($t) { $t } else { 'n/a' }), $k)
}

Section 'Recent Windows feature and driver updates'
try {
  $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
  $count = $searcher.GetTotalHistoryCount()
  if ($count -gt 0) {
    $searcher.QueryHistory(0, [Math]::Min($count, 200)) |
      Where-Object { $_.Title -notmatch 'Security Intelligence|Malicious Software|Defender' } |
      Select-Object -First 15 |
      ForEach-Object { '{0:yyyy-MM-dd HH:mm}  result={1}  {2}' -f $_.Date, $_.ResultCode, $_.Title }
    Write-Output 'result: 2 = succeeded, 4 = failed'
  }
} catch { Write-Output "(could not read update history: $($_.Exception.Message))" }

Section 'Firefox'
$ff = Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'
if (Test-Path $ff) { Write-Output "Firefox $((Get-Item $ff).VersionInfo.ProductVersion)" }
$profiles = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
if (Test-Path $profiles) {
  Get-ChildItem $profiles -Directory | ForEach-Object {
    # Folder is "<random id>.<name>"; print only the name, the id is unique to this install.
    $label = ($_.Name -split '\.', 2)[-1]
    foreach ($file in 'prefs.js', 'user.js') {
      $path = Join-Path $_.FullName $file
      if (Test-Path $path) {
        Select-String -Path $path -Pattern 'apz\.windows|general\.autoScroll|middlemouse' |
          Where-Object { $_.Line -notmatch 'services\.sync' } |
          ForEach-Object { "[$label] $file : $($_.Line)" }
      }
    }
  }
  Write-Output '(no lines above = Firefox defaults: DirectManipulation on, autoscroll on)'
}
