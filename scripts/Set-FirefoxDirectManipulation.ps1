<#
.SYNOPSIS
  Turns Firefox's DirectManipulation touchpad path off or back on, via user.js.
.DESCRIPTION
  Off: Firefox takes touchpad scrolling as classic wheel messages instead of through
       Windows DirectManipulation. On the test machine this brought back the Alps
       "hold middle button + move finger" scroll after a Windows feature update.
       Cost: two-finger scrolling loses DirectManipulation's native smooth panning.
  On:  writes Firefox's defaults back into user.js.
  The script only adds or replaces its own lines (and any existing lines for the same
  two prefs) in user.js; other lines are kept, and the old file is saved as user.js.bak.
  Firefox reads user.js at startup, so restart Firefox afterwards. Supports -WhatIf.
.PARAMETER State
  Off or On.
.PARAMETER ProfileDir
  A Firefox profile folder. Default: the profile(s) named as an install default in
  %APPDATA%\Mozilla\Firefox\profiles.ini.
.EXAMPLE
  .\scripts\Set-FirefoxDirectManipulation.ps1 -State Off
.EXAMPLE
  .\scripts\Set-FirefoxDirectManipulation.ps1 -State On -ProfileDir "$env:APPDATA\Mozilla\Firefox\Profiles\<id>.default-release"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][ValidateSet('Off', 'On')][string]$State,
  [string[]]$ProfileDir
)
$ErrorActionPreference = 'Stop'

$prefs = if ($State -eq 'Off') {
  [ordered]@{ 'apz.windows.use_direct_manipulation' = 'false' }
} else {
  [ordered]@{ 'apz.windows.use_direct_manipulation' = 'true'; 'apz.windows.force_disable_direct_manipulation' = 'false' }
}
$marker = '// alps-middle-scroll:'

if (-not $ProfileDir) {
  $root = Join-Path $env:APPDATA 'Mozilla\Firefox'
  $ini = Join-Path $root 'profiles.ini'
  if (-not (Test-Path $ini)) { throw "No Firefox profiles.ini at $ini. Pass -ProfileDir." }
  # [Install<hash>] sections name the profile each Firefox install starts with.
  $section = ''
  $ProfileDir = foreach ($line in Get-Content $ini) {
    if ($line -match '^\[(.+)\]$') { $section = $Matches[1]; continue }
    if ($section -like 'Install*' -and $line -match '^Default=(.+)$') {
      $p = $Matches[1].Trim()
      if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $root ($p -replace '/', '\') }
    }
  }
  # Older layouts have no [Install*] section; fall back to the [Profile*] marked Default=1.
  if (-not $ProfileDir) {
    $section = ''; $path = $null; $rel = $true; $isDefault = $false
    $ProfileDir = foreach ($line in @(Get-Content $ini) + '[end]') {
      if ($line -match '^\[(.+)\]$') {
        if ($isDefault -and $path) { if ($rel) { Join-Path $root ($path -replace '/', '\') } else { $path } }
        $section = $Matches[1]; $path = $null; $rel = $true; $isDefault = $false; continue
      }
      if ($section -like 'Profile*') {
        if ($line -match '^Path=(.+)$') { $path = $Matches[1].Trim() }
        elseif ($line -match '^IsRelative=0') { $rel = $false }
        elseif ($line -match '^Default=1') { $isDefault = $true }
      }
    }
  }
  $ProfileDir = @($ProfileDir | Select-Object -Unique)
  if (-not $ProfileDir) { throw 'profiles.ini names no default profile. Pass -ProfileDir.' }
}

$utf8 = New-Object Text.UTF8Encoding $false
# Both prefs this script manages, whatever -State is, so switching never leaves an orphan.
$managed = '^\s*user_pref\(\s*"apz\.windows\.(use|force_disable)_direct_manipulation"'
$written = 0

foreach ($dir in $ProfileDir) {
  if (-not (Test-Path -LiteralPath $dir -PathType Container) -or
      (-not (Test-Path (Join-Path $dir 'prefs.js')) -and -not (Test-Path (Join-Path $dir 'times.json')))) {
    Write-Warning "Skipping $dir : does not look like a Firefox profile."
    continue
  }
  # .NET file calls resolve relative paths against the process directory, not the
  # PowerShell location, so resolve once here.
  $dir = Convert-Path -LiteralPath $dir
  $userJs = Join-Path $dir 'user.js'
  $text = if (Test-Path -LiteralPath $userJs) { [IO.File]::ReadAllText($userJs, $utf8) } else { '' }
  $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
  $body = $text.TrimEnd("`r", "`n")
  $lines = @(if ($body) { $body -split "`r?`n" })
  # Drop our earlier lines, keep everything else as it was.
  $kept = @($lines | Where-Object { $_ -notmatch $managed -and -not $_.StartsWith($marker) })
  $new = @("$marker DirectManipulation $State (run this script with -State On/Off to change it;")
  $new += "$marker deleting these lines does not undo it, because Firefox has copied them into prefs.js)"
  foreach ($k in $prefs.Keys) { $new += "user_pref(""$k"", $($prefs[$k]));" }
  if ($PSCmdlet.ShouldProcess($userJs, "set DirectManipulation $State")) {
    if (Test-Path -LiteralPath $userJs) { Copy-Item -LiteralPath $userJs "$userJs.bak" -Force }
    [IO.File]::WriteAllText($userJs, ((@($kept) + $new) -join $eol) + $eol, $utf8)
    Write-Output "Updated $userJs"
    $written++
  }
}
if ($written -and (Get-Process firefox -ErrorAction SilentlyContinue)) {
  Write-Output 'Firefox is running: close every Firefox window and start it again to apply.'
}
