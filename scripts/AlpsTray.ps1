<#
.SYNOPSIS
  Notification-area (tray) app for the Alps pointing stick: watches the Alps helper,
  restarts it when it stops, and puts the scripts in this folder behind buttons.
.DESCRIPTION
  Left-click the icon for the panel, right-click for a menu. The panel:
    - shows whether Apoint.exe, the Alps helper, is running. Apoint applies the stick
      middle-button setting. When it hangs, middle click stops working; Windows may
      close it later, and then nothing starts it until the next sign-in. With "Restart
      the helper if it stops" on (the default), the tray restarts it when it is gone
      or not responding, and tells you, at most 3 times in 10 minutes.
    - shows the last middle-button press Windows received and which device sent it.
      No new press when you click means the Alps side is broken, not the browser.
    - switches the stick middle button between middle click and scroll mode
      (Set-StickMiddleButton.ps1, which backs up the Alps key first, here to
      %APPDATA%\AlpsTray\backups).
    - recalibrates a drifting stick by restarting the touchpad device
      (Reset-PointingStick.ps1, after a UAC prompt), then restarts the helper.
    - opens the button test window (Watch-MiddleButton.ps1) and the read-only report
      (Get-TouchpadReport.ps1).
    - can start with Windows (HKCU Run value "AlpsTray").
  Nothing changes until you click; the work runs in hidden child processes so the
  panel stays responsive. Its own settings are in %APPDATA%\AlpsTray\settings.json
  and errors go to %APPDATA%\AlpsTray\tray.log. Only one copy runs at a time.
  Notifications use the app ID AlpsTray.PointingStick, registered under
  HKCU\Software\Classes\AppUserModelId so Windows names them "Alps pointing stick".
  The Win32 parts are C# in lib\*.cs, compiled when the script starts.
.PARAMETER Snapshot
  Save a picture of the panel to this .png file and exit. For docs and testing.
.EXAMPLE
  conhost.exe --headless powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\scripts\AlpsTray.ps1
  Starts it with no console window.
.EXAMPLE
  powershell -STA -ExecutionPolicy Bypass -File .\scripts\AlpsTray.ps1 -Snapshot $env:TEMP\panel.png
#>
param([string]$Snapshot)
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# Win32 helpers that PowerShell 5.1 can't call itself live in lib\*.cs, compiled here.
Add-Type -ReferencedAssemblies System.Windows.Forms -Path (Get-ChildItem (Join-Path $PSScriptRoot 'lib\*.cs')).FullName

$self = $PSCommandPath
$here = $PSScriptRoot
$dataDir = Join-Path $env:APPDATA 'AlpsTray'
$settingsFile = Join-Path $dataDir 'settings.json'
$logFile = Join-Path $dataDir 'tray.log'
$apointExe = Join-Path $env:SystemRoot 'System32\DellTPad\Apoint.exe'
$buttonKey = 'HKCU:\Software\Alps\Apoint\Button'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'AlpsTray'
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\AlpsTray', [ref]$created)
if (-not $created -and -not $Snapshot) { exit }

function Write-Log([string]$msg) {
  try {
    if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 256KB) {
      Move-Item -Force $logFile "$logFile.old"
    }
    Add-Content -Path $logFile -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg)
  } catch {}
}

# ---- settings and state

$S = @{ AutoRestart = $true }
if (Test-Path $settingsFile) {
  try {
    $j = Get-Content -Raw $settingsFile | ConvertFrom-Json
    if ($null -ne $j.AutoRestart) { $S.AutoRestart = [bool]$j.AutoRestart }
  } catch { Write-Log "settings.json unreadable, using defaults: $($_.Exception.Message)" }
}
function Save-Settings { [pscustomobject]$S | ConvertTo-Json | Set-Content -Encoding UTF8 $settingsFile }

$T = @{
  Started = Get-Date; Tick = 0; Jobs = New-Object System.Collections.ArrayList
  Restarts = New-Object System.Collections.ArrayList; WarnedDown = $false
  HiddenAt = [datetime]::MinValue; Status = $null; Watch = $null
}

function Get-Status {
  $p = Get-Process Apoint -ErrorAction SilentlyContinue | Select-Object -First 1
  $mode = $null
  try { $mode = (Get-ItemProperty $buttonKey -ErrorAction Stop).SPFunction3 } catch {}
  $since = $null; $hung = $false
  if ($p) {
    try { $since = $p.StartTime } catch {}
    # A freshly started Apoint is busy initialising; don't judge it for 20 s.
    # After that, a ping unanswered for 10 s means it has stopped handling messages.
    if (-not $since -or ((Get-Date) - $since).TotalSeconds -ge 20) {
      $hung = [HangProbe]::UnansweredSeconds($p.Id) -ge 10
    }
  }
  [pscustomobject]@{ Running = [bool]$p; Hung = $hung; Since = $since; Mode = $mode }
}
function Get-LastPressText {
  $w = $T.Watch
  if (-not $w -or -not $w.Count) { return 'no middle press seen since the tray started' }
  return 'last middle press {0:HH:mm:ss} from {1}' -f $w.Last, $w.LastFrom
}
function Get-ModeText($mode) {
  if ($mode -eq 14) { return 'middle click' }
  if ($mode -eq 16) { return 'scroll mode' }
  if ($null -eq $mode) { return 'no Alps settings' }
  return "code $mode"
}
function Get-RunCommand {
  '"{0}" --headless "{1}" -NoProfile -STA -ExecutionPolicy Bypass -File "{2}"' -f
    (Join-Path $env:SystemRoot 'System32\conhost.exe'), (Join-Path $PSHOME 'powershell.exe'), $self
}
function Test-StartWithWindows {
  $v = (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).$runName
  return [bool]($v -and $v.Contains($self))
}

# ---- child processes: run a script from this folder hidden, collect its output

function Start-Child {
  param([string]$Label, [string]$Script, [string]$ScriptArgs = '', [scriptblock]$Done, [switch]$Elevated)
  $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
  $out = Join-Path $env:TEMP ('alpstray-{0}.txt' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
  $inner = @'
$ErrorActionPreference = 'Stop'; $code = 0; $lines = New-Object System.Collections.ArrayList
try {
  & __SCRIPT__ __ARGS__ *>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.WarningRecord]) { [void]$lines.Add('WARNING: ' + $_.Message) }
    else { [void]$lines.Add([string]$_) }
  }
} catch { [void]$lines.Add('ERROR: ' + $_.Exception.Message); $code = 1 }
Set-Content -LiteralPath __OUT__ -Value $lines -Encoding UTF8
exit $code
'@
  $inner = $inner.Replace('__SCRIPT__', (& $q (Join-Path $here $Script))).Replace('__ARGS__', $ScriptArgs).Replace('__OUT__', (& $q $out))
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path $PSHOME 'powershell.exe'
  $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' +
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
  if ($Elevated) {
    $psi.UseShellExecute = $true; $psi.Verb = 'runas'
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  } else {
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  }
  try { $proc = [System.Diagnostics.Process]::Start($psi) }
  catch {
    Write-Log "$Label failed to start: $($_.Exception.Message)"
    & $Done 1 'Cancelled.'
    return
  }
  Write-Log "started: $Label"
  [void]$T.Jobs.Add(@{ Label = $Label; Proc = $proc; Out = $out; Done = $Done })
  Update-Ui
}

function Update-Jobs {
  foreach ($job in @($T.Jobs)) {
    if (-not $job.Proc.HasExited) { continue }
    $T.Jobs.Remove($job)
    $code = 1
    try { $code = $job.Proc.ExitCode } catch {}
    $text = ''
    if (Test-Path $job.Out) { $text = (Get-Content $job.Out) -join "`r`n"; Remove-Item $job.Out -ErrorAction SilentlyContinue }
    Write-Log "finished ($code): $($job.Label)  $($text -replace '\s+', ' ')"
    $T.Status = Get-Status
    & $job.Done $code $text
    Update-Ui
  }
}

function Get-LastLine([string]$text) {
  $l = @($text -split "`r?`n" | Where-Object { $_.Trim() })
  if ($l.Count) { return $l[-1] } else { return '' }
}

# ---- actions

function Invoke-RestartHelper([string]$why) {
  $script:why = $why
  # Evidence for the next diagnosis: did middle presses still reach Windows?
  Write-Log "restart requested: $(Get-LastPressText)"
  Start-Child 'Restarting the Alps helper' 'Restart-AlpsHelper.ps1' -Done {
    param($code, $text)
    if ($T.Status.Running) {
      if ($script:why) { Send-Note Info $script:why } else { Send-Note Info 'The Alps helper is running.' }
    }
    else { Send-Note Warning ('Could not start the Alps helper. ' + (Get-LastLine $text)) }
  }
}

function Invoke-SetMode([string]$mode) {
  $target = @{ MiddleClick = 14; Scroll = 16 }[$mode]
  $script:target = $target
  $backups = Join-Path $dataDir 'backups'
  Start-Child "Switching the middle button to $(Get-ModeText $target)" 'Set-StickMiddleButton.ps1' "-Mode $mode -BackupDir '$($backups -replace "'", "''")'" -Done {
    param($code, $text)
    if ($T.Status.Mode -eq $script:target -and $T.Status.Running) { Send-Note Info "Middle button: $(Get-ModeText $script:target)." }
    else { Send-Note Warning ('Could not switch the middle button. ' + (Get-LastLine $text)) }
  }
}

function Invoke-Recalibrate {
  Send-Note Info 'Keep your fingers off the stick while the touchpad restarts.' -Quiet
  Start-Child 'Recalibrating the stick' 'Reset-PointingStick.ps1' -Elevated -Done {
    param($code, $text)
    if ($code -eq 0) { Invoke-RestartHelper 'Stick recalibrated, and the Alps helper restarted.' }
    else { Send-Note Warning ('Recalibration did not run. ' + (Get-LastLine $text)) }
  }
}

function Invoke-Report {
  Start-Child 'Building the report' 'Get-TouchpadReport.ps1' -Done {
    param($code, $text)
    $file = Join-Path $dataDir 'touchpad-report.txt'
    Set-Content -Path $file -Value $text -Encoding UTF8
    Start-Process notepad.exe -ArgumentList ('"{0}"' -f $file)
    Send-Note Info 'Report opened in Notepad. It changes nothing; read it before you share it.' -Quiet
  }
}

function Open-TestWindow {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path $PSHOME 'powershell.exe'
  $psi.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $here 'Watch-MiddleButton.ps1')
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  [void][System.Diagnostics.Process]::Start($psi)
}

function Set-StartWithWindows([bool]$on) {
  if ($on) { Set-ItemProperty -Path $runKey -Name $runName -Value (Get-RunCommand) }
  else { Remove-ItemProperty -Path $runKey -Name $runName -ErrorAction SilentlyContinue }
  Write-Log "start with Windows: $on"
}

# ---- watchdog: Apoint gone or hung -> restart it (or say so), with a startup grace and a cap

function Test-Helper {
  $T.Status = Get-Status
  $st = $T.Status
  $problem = $null
  if ($st.Running) {
    # The 10 s allowance in Get-Status already absorbs a busy moment.
    if ($st.Hung) { $problem = 'stopped responding' }
  } elseif ((Test-Path $apointExe) -and ((Get-Date) - $T.Started).TotalSeconds -ge 30) {
    # At sign-in the Alps service starts Apoint itself; the 30 s gives it time.
    $problem = 'stopped'
  }
  if (-not $problem) { $T.WarnedDown = $false; return }
  if ($T.Jobs.Count) { return }
  $cut = (Get-Date).AddMinutes(-10)
  foreach ($r in @($T.Restarts)) { if ($r -lt $cut) { $T.Restarts.Remove($r) } }
  if ($S.AutoRestart -and $T.Restarts.Count -lt 3) {
    [void]$T.Restarts.Add((Get-Date))
    Write-Log "Apoint $problem; restarting it"
    Invoke-RestartHelper "The Alps helper had $problem, which breaks the stick middle button. It is running again."
  } elseif (-not $T.WarnedDown) {
    $T.WarnedDown = $true
    $why = 'Auto-restart is off.'
    if ($S.AutoRestart) { $why = 'It failed 3 times in 10 minutes, so auto-restart is paused.' }
    Send-Note Warning "The Alps helper has $problem, so the stick middle button won't work. $why"
  }
}

# ---- look

[void][AlpsTrayNative]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({ param($s, $e) Write-Log "ERROR: $($e.Exception.Message)" })

$g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $scale = $g0.DpiX / 96; $g0.Dispose()
function Px([double]$n) { [int][Math]::Round($n * $scale) }
function Rgb([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }

$dark = $false
try { $dark = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize').AppsUseLightTheme -eq 0 } catch {}
if ($dark) {
  $Pal = @{ Back = Rgb '#202020'; Card = Rgb '#2D2D2D'; Hover = Rgb '#3A3A3A'; Border = Rgb '#454545'
          Fore = Rgb '#F3F3F3'; Dim = Rgb '#A6A6A6'; Ok = Rgb '#6CCB5F'; Warn = Rgb '#FCB900' }
} else {
  $Pal = @{ Back = Rgb '#F9F9F9'; Card = Rgb '#FFFFFF'; Hover = Rgb '#EDEDED'; Border = Rgb '#D0D0D0'
          Fore = Rgb '#1B1B1B'; Dim = Rgb '#5F5F5F'; Ok = Rgb '#0F7B0F'; Warn = Rgb '#9D5D00' }
}
$fontBody = New-Object System.Drawing.Font('Segoe UI', 9)
$fontTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
$fontHead = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$bullet = [string][char]0x25CF

# Tray icon: a dark keycap with the stick's red dot; amber ring and grey dot when the helper is down.
function New-TrayBitmap([bool]$ok, [int]$sz) {
  $bmp = New-Object System.Drawing.Bitmap $sz, $sz
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $r = $sz * 0.25; $w = $sz - 1.5
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $path.AddArc(0.5, 0.5, $r, $r, 180, 90); $path.AddArc($w - $r + 0.5, 0.5, $r, $r, 270, 90)
  $path.AddArc($w - $r + 0.5, $w - $r + 0.5, $r, $r, 0, 90); $path.AddArc(0.5, $w - $r + 0.5, $r, $r, 90, 90)
  $path.CloseFigure()
  $g.FillPath((New-Object System.Drawing.SolidBrush (Rgb '#2B2B2B')), $path)
  $ring = Rgb '#8C8C8C'; $dot = Rgb '#E3262E'
  if (-not $ok) { $ring = Rgb '#FCB900'; $dot = Rgb '#9A9A9A' }
  $g.DrawPath((New-Object System.Drawing.Pen($ring, [Math]::Max(1.0, $sz / 16))), $path)
  $d = $sz * 0.42; $o = ($sz - $d) / 2
  $g.FillEllipse((New-Object System.Drawing.SolidBrush $dot), [single]$o, [single]$o, [single]$d, [single]$d)
  $g.Dispose()
  return $bmp
}
function New-TrayIcon([bool]$ok) {
  $bmp = New-TrayBitmap $ok ([System.Windows.Forms.SystemInformation]::SmallIconSize.Width)
  $h = $bmp.GetHicon()
  $icon = ([System.Drawing.Icon]::FromHandle($h)).Clone()
  [void][AlpsTrayNative]::DestroyIcon($h); $bmp.Dispose()
  return $icon
}
$iconOk = New-TrayIcon $true
$iconDown = New-TrayIcon $false

# ---- panel

function New-Label([string]$text, $font, $color) {
  $l = New-Object System.Windows.Forms.Label
  $l.AutoSize = $true; $l.Text = $text; $l.Font = $font; $l.ForeColor = $color
  $l.MaximumSize = New-Object System.Drawing.Size((Px 300), 0)
  $l.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (Px 4))
  return $l
}
function New-Button([string]$text) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $text; $b.Font = $fontBody; $b.AutoSize = $true
  $b.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
  $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat; $b.UseVisualStyleBackColor = $false
  $b.BackColor = $Pal.Card; $b.ForeColor = $Pal.Fore
  $b.FlatAppearance.BorderColor = $Pal.Border; $b.FlatAppearance.MouseOverBackColor = $Pal.Hover
  $b.Padding = New-Object System.Windows.Forms.Padding((Px 6), (Px 2), (Px 6), (Px 2))
  $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, (Px 6), (Px 6))
  return $b
}
function New-Choice([string]$type, [string]$text) {
  $c = New-Object "System.Windows.Forms.$type"
  $c.Text = $text; $c.Font = $fontBody; $c.ForeColor = $Pal.Fore; $c.AutoSize = $true
  $c.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, (Px 2))
  return $c
}
function New-Row {
  $r = New-Object System.Windows.Forms.FlowLayoutPanel
  $r.AutoSize = $true; $r.WrapContents = $false; $r.Margin = New-Object System.Windows.Forms.Padding(0)
  return $r
}
function New-Head([string]$text) {
  $h = New-Label $text $fontHead $Pal.Dim
  $h.Margin = New-Object System.Windows.Forms.Padding(0, (Px 10), 0, (Px 4))
  return $h
}

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.ShowInTaskbar = $false; $form.TopMost = $true
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.AutoSize = $true; $form.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$form.BackColor = $Pal.Border; $form.Padding = New-Object System.Windows.Forms.Padding(1)
$form.Text = 'Alps pointing stick'

$root = New-Object System.Windows.Forms.FlowLayoutPanel
$root.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$root.WrapContents = $false; $root.AutoSize = $true; $root.BackColor = $Pal.Back
$root.Padding = New-Object System.Windows.Forms.Padding((Px 14), (Px 12), (Px 14), (Px 8))
$root.Margin = New-Object System.Windows.Forms.Padding(0)
$root.MinimumSize = New-Object System.Drawing.Size((Px 330), 0)
$form.Controls.Add($root)

$lblTitle = New-Label 'Alps pointing stick' $fontTitle $Pal.Fore
$lblHelper = New-Label '' $fontBody $Pal.Fore
$lblHelper.Margin = New-Object System.Windows.Forms.Padding(0, (Px 2), 0, 0)

$rbClick = New-Choice 'RadioButton' 'Middle click: close tabs, open links, autoscroll'
$rbScroll = New-Choice 'RadioButton' 'Scroll mode: hold and move (driver default)'
$lblPress = New-Label '' $fontBody $Pal.Dim
$lblPress.Margin = New-Object System.Windows.Forms.Padding(0, (Px 4), 0, 0)
$cbAuto = New-Choice 'CheckBox' 'Restart the helper if it stops'
$cbStart = New-Choice 'CheckBox' 'Start with Windows'

$btnRestart = New-Button 'Restart helper'
$btnCal = New-Button 'Recalibrate stick'
$row1 = New-Row; $row1.Controls.AddRange(@($btnRestart, $btnCal))
$btnTest = New-Button 'Button test'
$btnReport = New-Button 'Report'
$btnQuit = New-Button 'Quit'
$row2 = New-Row; $row2.Controls.AddRange(@($btnTest, $btnReport, $btnQuit))

$lblFoot = New-Label '' $fontBody $Pal.Dim
$lblFoot.Margin = New-Object System.Windows.Forms.Padding(0, (Px 2), 0, (Px 4))

$root.Controls.AddRange(@(
  $lblTitle, $lblHelper,
  (New-Head 'Middle button'), $rbClick, $rbScroll, $lblPress,
  (New-Head 'Helper'), $cbAuto, $cbStart,
  (New-Head 'Tools'), $row1, $row2,
  $lblFoot))

$tips = New-Object System.Windows.Forms.ToolTip
$tips.SetToolTip($btnRestart, 'Stop and start Apoint, the Alps helper that applies the button settings.')
$tips.SetToolTip($btnCal, 'Restart the touchpad device so a drifting stick takes a new rest position. Asks for admin.')
$tips.SetToolTip($btnTest, 'Open a window that logs every middle-button, wheel and click event. Changes nothing.')
$tips.SetToolTip($btnReport, 'Read-only report on drivers, Alps settings and updates, opened in Notepad.')

# ---- tray icon and menu

$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = $iconOk; $ni.Text = 'Alps pointing stick'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('Open panel')
$miOpen.Font = New-Object System.Drawing.Font($miOpen.Font, [System.Drawing.FontStyle]::Bold)
[void]$menu.Items.Add('-')
$miRestart = $menu.Items.Add('Restart Alps helper')
$miCal = $menu.Items.Add('Recalibrate stick...')
[void]$menu.Items.Add('-')
$miQuit = $menu.Items.Add('Quit')
$ni.ContextMenuStrip = $menu

# Notifications go out under their own app ID so Windows shows "Alps pointing stick"
# instead of "Windows PowerShell". The ID is registered per user, with the tray icon.
$aumid = 'AlpsTray.PointingStick'
function Register-AppId {
  $png = Join-Path $dataDir 'icon.png'
  $bmp = New-TrayBitmap $true 64; $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  $key = "HKCU:\Software\Classes\AppUserModelId\$aumid"
  if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
  Set-ItemProperty -Path $key -Name DisplayName -Value 'Alps pointing stick'
  Set-ItemProperty -Path $key -Name IconUri -Value $png
  [void][AlpsTrayNative]::SetCurrentProcessExplicitAppUserModelID($aumid)
}
function Show-Toast([string]$text) {
  $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
  $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
  $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
  $xml.LoadXml(('<toast><visual><binding template="ToastGeneric"><text>{0}</text></binding></visual></toast>' -f
    [Security.SecurityElement]::Escape($text)))
  [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show(
    (New-Object Windows.UI.Notifications.ToastNotification $xml))
}

function Send-Note {
  param([string]$Kind, [string]$Text, [switch]$Quiet)
  $T.LastNote = '{0:HH:mm}  {1}' -f (Get-Date), $Text
  if (-not $Quiet -and -not $form.Visible) {
    try { Show-Toast $Text }
    catch {
      Write-Log "toast failed, using a balloon: $($_.Exception.Message)"
      $ni.ShowBalloonTip(6000, 'Alps pointing stick', $Text, [System.Windows.Forms.ToolTipIcon]::$Kind)
    }
  }
  Update-Ui
}

function Update-Ui {
  $st = $T.Status
  if (-not $st) { return }
  $busy = $T.Jobs.Count -gt 0
  if ($st.Running -and -not $st.Hung) {
    $since = ''
    if ($st.Since) { $since = ' since {0:ddd HH:mm}' -f $st.Since }
    $lblHelper.Text = "$bullet  Helper (Apoint) running$since"; $lblHelper.ForeColor = $Pal.Ok
    $ni.Icon = $iconOk
  } else {
    $state = 'not running'
    if ($st.Running) { $state = 'not responding' }
    $lblHelper.Text = "$bullet  Helper (Apoint) $($state): the middle button won't work"; $lblHelper.ForeColor = $Pal.Warn
    $ni.Icon = $iconDown
  }
  $press = Get-LastPressText
  $lblPress.Text = $press.Substring(0, 1).ToUpper() + $press.Substring(1) + '. Press it over this panel to test.'
  $tip = 'Alps stick: ' + (Get-ModeText $st.Mode)
  if (-not $st.Running) { $tip += ', helper stopped' }
  elseif ($st.Hung) { $tip += ', helper not responding' }
  $ni.Text = $tip.Substring(0, [Math]::Min(63, $tip.Length))
  # While a switch runs, keep the choice the user just clicked.
  if (-not $busy) {
    $rbClick.Checked = ($st.Mode -eq 14)
    $rbScroll.Checked = ($st.Mode -eq 16)
  }
  $cbAuto.Checked = $S.AutoRestart
  $cbStart.Checked = Test-StartWithWindows
  foreach ($c in @($rbClick, $rbScroll, $btnRestart, $btnCal, $btnReport, $miRestart, $miCal)) { $c.Enabled = -not $busy }
  if ($busy) { $lblFoot.Text = ($T.Jobs[0].Label + '...') }
  elseif ($T.LastNote) { $lblFoot.Text = $T.LastNote }
  else { $lblFoot.Text = 'Left-click the tray icon for this panel, right-click for the menu.' }
}

function Show-Panel {
  if ($form.Visible) { $form.Hide(); return }
  # A click on the icon first deactivates (hides) an open panel; don't reopen it.
  if (((Get-Date) - $T.HiddenAt).TotalMilliseconds -lt 400) { return }
  $T.Status = Get-Status
  Update-Ui
  $wa = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
  $form.Location = New-Object System.Drawing.Point(-32000, -32000)
  $form.Show()
  $form.Location = New-Object System.Drawing.Point(($wa.Right - $form.Width - (Px 12)), ($wa.Bottom - $form.Height - (Px 12)))
  $form.Activate()
}

# ---- events

$form.Add_Deactivate({ $form.Hide(); $T.HiddenAt = Get-Date })
$ni.Add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Panel } })
$miOpen.Add_Click({ Show-Panel })

$rbClick.Add_Click({ if ($T.Status.Mode -ne 14) { Invoke-SetMode 'MiddleClick' } })
$rbScroll.Add_Click({ if ($T.Status.Mode -ne 16) { Invoke-SetMode 'Scroll' } })
$cbAuto.Add_Click({
  $S.AutoRestart = $cbAuto.Checked; Save-Settings; $T.WarnedDown = $false
  Write-Log "auto-restart: $($S.AutoRestart)"
})
$cbStart.Add_Click({ Set-StartWithWindows $cbStart.Checked; Update-Ui })

$btnRestart.Add_Click({ Invoke-RestartHelper '' })
$miRestart.Add_Click({ Invoke-RestartHelper '' })
$btnCal.Add_Click({ $form.Hide(); Invoke-Recalibrate })
$miCal.Add_Click({ Invoke-Recalibrate })
$btnTest.Add_Click({ $form.Hide(); Open-TestWindow })
$btnReport.Add_Click({ Invoke-Report })

$quit = {
  $timer.Stop(); $ni.Visible = $false; $ni.Dispose()
  Write-Log 'quit'
  [System.Windows.Forms.Application]::Exit()
}
$btnQuit.Add_Click($quit)
$miQuit.Add_Click($quit)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
  try {
    Update-Jobs
    $T.Tick++
    if ($T.Tick % 3 -eq 0) { Test-Helper }
    # Every second while open, so a test press over the panel shows up right away.
    if ($form.Visible) { Update-Ui }
  } catch { Write-Log "tick: $($_.Exception.Message)" }
})

# ---- run

$T.Status = Get-Status
if ($Snapshot) {
  Update-Ui
  $form.Location = New-Object System.Drawing.Point(-32000, -32000)
  $form.Show(); [System.Windows.Forms.Application]::DoEvents()
  $bmp = New-Object System.Drawing.Bitmap $form.Width, $form.Height
  $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
  $bmp.Save($Snapshot, [System.Drawing.Imaging.ImageFormat]::Png)
  $form.Close(); $ni.Dispose()
  Write-Output "Saved $Snapshot ($($form.Width) x $($form.Height))"
  return
}

Write-Log "started (pid $PID)"
try { Register-AppId } catch { Write-Log "app ID not registered: $($_.Exception.Message)" }
$T.Watch = New-Object MiddleWatch
$ni.Visible = $true
$timer.Start()
Update-Ui
[System.Windows.Forms.Application]::Run()
$mutex.ReleaseMutex()
