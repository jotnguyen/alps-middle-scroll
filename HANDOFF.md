# Hand-off

Where this repo stands, for the next person or agent. Last updated 2026-10-27, after the
tray app.

## Status: solved on the test machine

The symptom was a Dell Latitude 7490 where holding the Alps pointing-stick middle
button and moving a finger no longer scrolled in Firefox or Edge. It started around
the Windows 11 26H2 feature update.

| Item | State |
|---|---|
| Fix 1: stick middle button set to middle click (`SPFunction3` 16 → 14) | **Applied, user-confirmed.** Middle-click closes tabs. Firefox autoscroll works when you click once or hold and move. |
| Fix 2: Firefox DirectManipulation off | **Tried, worked, then rolled back.** Not needed with Fix 1. |
| Firefox two-finger swipe for back and forward | **Works** with Fix 1 and DirectManipulation on (user-confirmed) |
| Middle click lost again, 2026-10-27 | **Cause found:** `Apoint.exe` hung and Windows closed it, so nothing applied `SPFunction3` (still 14). Starting Apoint fixed it. `AlpsTray.ps1` now restarts it automatically (tested by stopping Apoint). |
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
| [scripts/AlpsTray.ps1](scripts/AlpsTray.ps1) | only on a click, plus the Apoint watchdog; its own settings and log in `%APPDATA%\AlpsTray` |
| [scripts/hygiene.sh](scripts/hygiene.sh) | no; it is the privacy gate run by `.githooks/` and CI |

## Possible follow-ups

Ordered roughly by value.

1. **Pin down the trigger.**
   - Find out when the gesture actually stopped working.
   - Find out what wrote Windows' `PrecisionTouchPad` key on 2026-10-18 09:54.
   - Optionally confirm 26H2 as the cause on a second machine, or before and after an
     update.
   - See "Still open" in [docs/hardware-and-software.md](docs/hardware-and-software.md).
2. **Find out why Apoint hangs.** It hung on 2026-10-27 (Application Hang, event 1002).
   `AlpsTray.ps1` logs every restart to `%APPDATA%\AlpsTray\tray.log`, so how often it
   happens will show there. The tray's Recalibrate button ran once on the test machine
   (UAC accepted, device back as OK, Apoint restarted after). Whether it fixes the
   top-left drift for good is not known yet.
3. **Test Edge with Fix 1.** Its middle-click autoscroll should work the same way, but
   nobody has tried it.
4. **Test whether Fix 2 breaks Firefox's two-finger swipe for back and forward.** It's
   likely, since that swipe probably needs DirectManipulation. Then state it in the
   README as fact or drop it.
5. **Map more Alps function codes.** Only 14 (middle click) and 16 (scroll) were tried on
   `SPFunction3`. Read-only first, and back up before any write.
6. **Try other models.** Run `Get-TouchpadReport.ps1` on other Latitudes, or on
   Synaptics or ELAN pads, and record which ones show the same split between classic
   windows and DirectManipulation.
7. **Report it upstream** if it reproduces on a clean 26H2 machine. That would be
   Feedback Hub under input and touchpad for Windows, and possibly Dell for the Alps
   driver.
8. **Small leftovers from the review** (nits only):
   - `Set-FirefoxDirectManipulation.ps1` drops matching `user_pref` lines even inside
     `/* */` comments.
   - Backups go to `%TEMP%` by default, which Windows can clean. The tray app passes
     `%APPDATA%\AlpsTray\backups` instead.
   - CI parses the scripts but doesn't compile the `Add-Type` C#.

## Not in the repo, by design

- The owner's `.reg` backup of their Alps settings, and the test logs. `.gitignore`
  blocks `*.reg` and `*.log`.
- Anything identifying the machine or owner. `bash scripts/hygiene.sh` must print
  `hygiene-ok`.
