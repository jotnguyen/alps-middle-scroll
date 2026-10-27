# Session log: how the diagnosis went

One session on 2026-10-18 with Claude Code on the affected laptop, in order, wrong
turns included. Times are local.

## 1. The question

"The middle button used to scroll: press it, then use the touchpad. Now it doesn't.
Drivers, Windows update, a Windows setting, or Firefox?"

## 2. Inventory (read-only)

- Found a Dell Latitude 7490 with an Alps dual-point touchpad in precision-touchpad
  mode, using the Alps "Dell Touchpad" driver 10.3201.101.216 (2021) and the Alps
  virtual HID device. Every device reported OK.
- The Alps helper processes were running. Their files dated from 2021, so the update
  hadn't replaced the driver.
- No Kernel-PnP events touched the touchpad since 2026-10-01.
- Firefox `prefs.js` had no `autoScroll` or `apz` lines, so it was on defaults.
- Update history showed **Windows 11 26H2 installed 2026-10-14**, after two failed 25H2
  attempts. That became the first suspect.
- The Alps registry showed `SPFunction3 = 16` on the stick's middle button. What that
  code meant was unknown at this point.

## 3. First capture: a timed hook (inconclusive)

A 90-second low-level mouse hook ran in the background while the user was asked to
test in Firefox. It logged three left clicks and nothing else.

Wrong turn: the user couldn't tell when the capture had started, so "no middle events"
might only have meant "no test yet". A timed capture you can't see is a bad test
harness.

## 4. Second capture: a visible test window

`Watch-MiddleButton.ps1` (then a scratch script) opens a window that shows each event
as it arrives, at the Raw Input and hook levels, with the sending device.

Wrong turn: the first run never opened. Add-Type treats compiler warnings as errors,
and a method named `Name` hid `Form.Name`. Renaming it to `DevName` fixed it.

Result, after the user confirmed they held the middle button and moved one finger:

- No middle-button event at any level.
- A stream of `WHEEL` events with no device handle and no injected flag.
- The test window scrolled.

So the hardware, the driver and the Windows input stack were all producing the
scroll. The fault was further along.

## 5. Splitting the confounders

Firefox 158 had also installed on 2026-10-14, five hours before 26H2. The user tried
Edge, and it **failed too**. That cleared Firefox. The common factor between Firefox
and Edge, and the difference from the test window, is DirectManipulation.

The touchpad settings key showed new build-26300 values (single-finger, auto and
boosted panning) and a last-write time of 2026-10-18 09:54. That's recorded as an open
question, not a cause.

## 6. Fix 2 first: Firefox off DirectManipulation

`apz.windows.use_direct_manipulation = false` went into `user.js`. After a Firefox
restart, holding the middle button and moving a finger scrolled again (user
confirmed). Afterwards `prefs.js` also held
`apz.windows.force_disable_direct_manipulation = true`. Where that came from is
unknown.

The user remembered setting `apz.windows.use_direct_manipulation` to `true` once, while
chasing a scroll-acceleration issue. `prefs.js` had shown no `apz` line, and `true` is
that pref's default, so that change hadn't caused this.

## 7. Fix 1: a real middle click

The user also wanted middle-click-to-close-tab. Scroll mode swallows the press, so the
middle button was switched to a plain middle click:

1. Exported `HKCU\Software\Alps\Apoint` to a `.reg` backup.
2. Set `SPFunction3` from 16 to 14. The value 14 was chosen because the touchpad's and
   the external mouse's middle buttons were already 14.
3. Restarted `Apoint`. `ApMsgFwd` refused to stop, which turned out not to matter.

The user confirmed that middle-click now closes tabs, and that the middle button
brings up Firefox's autoscroll: click once to toggle it, or hold and move.

## 8. Packaging and review

The scratch scripts became the four scripts in `scripts/`. Machine-specific paths
became parameters and environment variables, and personal data was kept out of the
repo, enforced by `scripts/hygiene.sh`.

Before the first push, a separate agent did an adversarial review and tested the
scripts, using fake Firefox profiles and `-WhatIf` runs. It found:

- **One blocker.** Windows PowerShell 5.1 read `user.js` as ANSI and wrote it back as
  UTF-8, which corrupted any non-ASCII line a little more on every run.
- **Smaller problems:**
  - a wrong "delete these lines to undo" note
  - Bluetooth LE addresses surviving the report's ID trimming
  - a real device instance suffix in a code comment
  - a relative `-ProfileDir` being resolved two different ways
  - README claims that went past the evidence

All were fixed before the first commit.

## 9. Rolling back Fix 2

The user asked whether Firefox's two-finger swipe for back and forward had ever
worked, and whether these changes affected it. Firefox has shipped that gesture on
Windows since version 105, and it probably depends on DirectManipulation. With Fix 1
in place, Fix 2 was rolled back (`-State On`) so both gestures could be tested
together.

After a Firefox restart, the user confirmed that **both gestures work**:

- two-finger swipe for back and forward
- middle-button autoscroll and middle-click to close a tab

So Fix 1 alone is enough, and the end state keeps DirectManipulation on. Nobody tested
whether the swipe gesture worked while Fix 2 was in place.

## 10. Middle click stopped again (2026-10-27)

Nine days later, middle-click to close a tab stopped working again. `SPFunction3` was
still 14. What had changed: `Apoint.exe` wasn't running. That morning the Application
log had an Application Hang event (1002), where Windows reported that Apoint stopped
responding and was closed, and a matching Windows Error Reporting `AppHangB1` event.
Nothing starts Apoint again until the next sign-in, and without it the setting isn't
applied. Starting `Apoint.exe` brought `ApntEx` and `ApRemote` back with it.

Why Apoint hung is unknown. The same day the user also reported the stick drifting
toward the top left. Nothing links the two.

Three scripts came out of it:

- `scripts/Restart-AlpsHelper.ps1`: the restart logic, pulled out of
  `Set-StickMiddleButton.ps1`, which now calls it.
- `scripts/Reset-PointingStick.ps1`: restarts the touchpad device
  (`pnputil /restart-device` on the parent of the "Dell Touchpad" collection) so a
  drifting stick recalibrates.
- `scripts/AlpsTray.ps1`: a tray app that restarts Apoint when it disappears and puts
  the other scripts behind buttons. Tested by stopping Apoint: the tray logged it, and
  Apoint was back as soon as the tray's 30-second startup grace period ended.

Testing caught two `-WhatIf` traps. `ForEach-Object Id` (the member-name form) asks
ShouldProcess before it reads each property, so under `-WhatIf` it returned nothing.
`Get-PnpDeviceProperty` also honors `-WhatIf`, so it needs `-WhatIf:$false` for a
read. And PowerShell variable names ignore case: a loop variable `$c` shadowed the
color table `$C`.

## 11. A third time, without a hang event (2026-10-27, 13:04)

Middle-click to open a link in a new tab stopped working again that afternoon. This
time Apoint was still running, the tray never saw it disappear, and Windows logged no
new hang event. Restarting the helper from the tray brought it back, but the user
said it took a while to start working again. What broke is unproven. The likely
answer is Apoint hung but not yet closed: Windows logs event 1002 only when it closes
a hung app itself, and the tray's restart killed it first.

The tray only watched for Apoint disappearing, so it got two additions:

- **A hang check.** The first version used `IsHungAppWindow` on Apoint's (hidden)
  windows. A test that froze Apoint (`NtSuspendProcess`) showed it never fires.
  Windows counts a thread that gets no messages as "waiting for input", not hung. The
  check now sends each Apoint UI thread a `WM_NULL` with `SendMessageTimeout` (500 ms):
  healthy answered in 34 ms, frozen timed out, and resumed answered in 3 ms. In the
  tray, a frozen Apoint was restarted 8 s after the freeze.
- **The last middle press**, from Raw Input with the sending device, shown in the
  panel and written to the log on every restart. Next time it breaks, that tells
  whether presses still reached Windows.

The tray's notifications also stopped saying "Windows PowerShell". They now go out as
WinRT toasts under their own app ID, `AlpsTray.PointingStick`, registered in HKCU with
a display name and icon.

The C# moved out of the script into `scripts/lib/*.cs`, loaded with `Add-Type -Path`,
and CI now compiles it.

## End state on the test machine

| Setting | Value |
|---|---|
| Alps `SPFunction3` | 14 (middle click) |
| Firefox `apz.windows.use_direct_manipulation` | true, written by the script into `user.js` |
| Firefox `apz.windows.force_disable_direct_manipulation` | false, written by the script into `user.js` |
