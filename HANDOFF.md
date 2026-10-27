# Hand-off

Where this repo stands, for the next person or agent. Last updated 2026-10-27, late
afternoon, after the callback hang probe.

## Status: scroll fixed; middle click still drops out now and then

The original symptom was a Dell Latitude 7490 where holding the Alps pointing-stick
middle button and moving a finger no longer scrolled in Firefox or Edge. It started
around the Windows 11 26H2 feature update. Fix 1 solved that.

On 2026-10-27 a new problem showed up: middle click (close tab, open link in a new
tab) stopped working four times. The first time, Apoint had hung and Windows closed
it; that's proven. The other times aren't explained. `AlpsTray.ps1` now restarts a
dead or hung Apoint by itself, but the root cause is open. See follow-up 1.

| Item | State |
|---|---|
| Fix 1: stick middle button set to middle click (`SPFunction3` 16 → 14) | **Applied, user-confirmed.** Middle-click closes tabs. Firefox autoscroll works when you click once or hold and move. |
| Fix 2: Firefox DirectManipulation off | **Tried, worked, then rolled back.** Not needed with Fix 1. |
| Firefox two-finger swipe for back and forward | **Works** with Fix 1 and DirectManipulation on (user-confirmed) |
| Middle click lost again, 2026-10-27 | **Cause found:** `Apoint.exe` hung and Windows closed it, so nothing applied `SPFunction3` (still 14). Starting Apoint fixed it. `AlpsTray.ps1` now restarts it automatically (tested by stopping Apoint). |
| Lost again at 13:04 and about 14:20 the same day | **Cause unknown.** Apoint was running, with no hang event. The tray's first hang check restarted Apoint at 14:19:28, 14:19:52 and 14:24:28; those were probably false alarms, and killing Apoint may itself have made things worse. Its Raw Input tracker saw **no middle press at all** from 13:17 to 14:41, but nobody confirmed the user pressed the button in that time. |
| Hang check | **Third version, tested.** A `WM_NULL` sent with `SendMessageCallback`; restart if unanswered after 10 s, ignoring an Apoint younger than 20 s. A frozen Apoint was restarted 17 s after the freeze. Versions 1 (`IsHungAppWindow`) and 2 (`PostMessage` + `IsHungAppWindow`) never fired on a frozen Apoint. Version 1.5 (blocking `SendMessageTimeout`, 500 ms) fired, but too easily. |
| Adversarial review before publishing | Done. The blocker and every should-fix item were fixed before the first commit. |

## Read in this order

1. [README.md](README.md): symptom, cause, both fixes, scripts
2. [docs/hardware-and-software.md](docs/hardware-and-software.md): each layer of the
   input stack, the registry values and prefs, what was observed and what was inferred,
   and the open questions
3. [docs/session-log.md](docs/session-log.md): what was done, in order, wrong turns
   included, and the end state
4. [docs/lessons-learned.md](docs/lessons-learned.md): what to do first next time
5. [AGENTS.md](AGENTS.md): rules for working in this repo and on a real machine

## Scripts

| Script | Writes? |
|---|---|
| [scripts/Get-TouchpadReport.ps1](scripts/Get-TouchpadReport.ps1) | no |
| [scripts/Watch-MiddleButton.ps1](scripts/Watch-MiddleButton.ps1) | no; it opens a window and needs a person at the keyboard |
| [scripts/Set-StickMiddleButton.ps1](scripts/Set-StickMiddleButton.ps1) | HKCU Alps key, after a `.reg` backup; `-WhatIf` |
| [scripts/Set-FirefoxDirectManipulation.ps1](scripts/Set-FirefoxDirectManipulation.ps1) | `user.js`, after a `.bak` copy; `-WhatIf` |
| [scripts/Restart-AlpsHelper.ps1](scripts/Restart-AlpsHelper.ps1) | no files; restarts Apoint; `-WhatIf` |
| [scripts/Reset-PointingStick.ps1](scripts/Reset-PointingStick.ps1) | no files; restarts the touchpad device (admin); `-WhatIf` |
| [scripts/AlpsTray.ps1](scripts/AlpsTray.ps1) | only on a click, plus the Apoint watchdog; its own settings and log in `%APPDATA%\AlpsTray`, its notification app ID under `HKCU\Software\Classes\AppUserModelId` |
| [scripts/lib/](scripts/lib/) | no; C# for the tray (`HangProbe`, `MiddleWatch`, `AlpsTrayNative`), loaded with `Add-Type -Path`; CI compiles it |
| [scripts/hygiene.sh](scripts/hygiene.sh) | no; it is the privacy gate run by `.githooks/` and CI |

## Possible follow-ups

Ordered roughly by value.

1. **Find out why middle click keeps dropping out.** Next time it fails, before
   restarting anything:
   - Open the tray panel and press the stick's middle button over it. If the "last
     middle press" time changes, the press reaches Windows and the browser is the
     place to look. If it doesn't, the Alps side is swallowing it.
   - Run `Watch-MiddleButton.ps1`, press the button a few times, close it, and read
     `%TEMP%\middle-button-test.log`. A `[raw] MIDDLE_DOWN` line shows the device that
     sent it. A `[hook]` line without `INJECTED` means hardware; with it, software.
   - Hypotheses, none proven: (a) Apoint hangs; proven once, and the tray now handles
     it. (b) `ApMsgFwd.exe` runs elevated, has been up since the last boot
     (2026-10-17), and can't be restarted as the user. It may hold stale state after
     Apoint restarts, which would fit "worked again only after a while". A reboot
     resets it; check whether the drop-outs stop. (c) In middle-click mode Apoint may
     post the click straight to the window, skipping the input stack. That would
     explain why the tracker saw nothing, and it can be checked with the test window.
   - Never confirmed: whether the user pressed the stick middle button between 13:17
     and 14:41. Ask.
2. **Pin down the original trigger.**
   - Find out when the gesture actually stopped working.
   - Find out what wrote Windows' `PrecisionTouchPad` key on 2026-10-18 09:54.
   - Optionally confirm 26H2 as the cause on a second machine, or before and after an
     update.
   - See "Still open" in [docs/hardware-and-software.md](docs/hardware-and-software.md).
3. **Watch the tray log.** `%APPDATA%\AlpsTray\tray.log` records every restart, with
   the last middle press seen before it. The tray's Recalibrate button ran once
   (UAC accepted, device back as OK, Apoint restarted after). Whether it cures the
   top-left stick drift for good is not known yet.
4. **Test Edge with Fix 1.** Its middle-click autoscroll should work the same way, but
   nobody has tried it.
5. **Test whether Fix 2 breaks Firefox's two-finger swipe for back and forward.** It's
   likely, since that swipe probably needs DirectManipulation. Then state it in the
   README as fact or drop it.
6. **Map more Alps function codes.** Only 14 (middle click) and 16 (scroll) were tried on
   `SPFunction3`. Read-only first, and back up before any write.
7. **Try other models.** Run `Get-TouchpadReport.ps1` on other Latitudes, or on
   Synaptics or ELAN pads, and record which ones show the same split between classic
   windows and DirectManipulation.
8. **Report it upstream** if it reproduces on a clean 26H2 machine. That would be
   Feedback Hub under input and touchpad for Windows, and possibly Dell for the Alps
   driver.
9. **Small leftovers from the review** (nits only):
   - `Set-FirefoxDirectManipulation.ps1` drops matching `user_pref` lines even inside
     `/* */` comments.
   - Backups go to `%TEMP%` by default, which Windows can clean. The tray app passes
     `%APPDATA%\AlpsTray\backups` instead.
   - CI compiles `scripts/lib/*.cs`, but not the C# still inline in
     `Get-TouchpadReport.ps1` and `Watch-MiddleButton.ps1`. Move it to `scripts/lib`
     when those scripts next change.

## Not in the repo, by design

- The owner's `.reg` backup of their Alps settings, and the test logs. `.gitignore`
  blocks `*.reg` and `*.log`.
- Anything identifying the machine or owner. `bash scripts/hygiene.sh` must print
  `hygiene-ok`.
