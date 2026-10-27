# Lessons learned

## Diagnosing input problems

1. **Measure where the event dies before changing anything.** Raw Input shows what the
   input stack delivers. A low-level hook shows what apps receive and whether it was
   injected. Those two together cleared the hardware, the driver and Windows' own
   pipeline in a single test.
2. **Have one control app per delivery path.** A plain WinForms window gets classic
   wheel messages, and browsers get DirectManipulation. "Works in the plain window,
   fails in both browsers" pointed straight at the delivery path.
3. **Break up updates that land together.** Firefox 158 and Windows 26H2 arrived on the
   same day. Testing a second browser from a different vendor settled which one to
   blame in a minute.
4. **Check registry key last-write times.** Values have no timestamps, but keys do (see
   `RegQueryInfoKey` in `Get-TouchpadReport.ps1`). A key written after the update and
   before the complaint is a lead, even if it leads nowhere.
5. **No pref line in `prefs.js` means the default.** Firefox only writes prefs that
   differ from their defaults. "I once set it to true" is the same as never touching it
   when true is the default.
6. **Vendor helper processes hide behavior in the registry.** The Alps driver's scroll
   mode lives in one DWORD (`SPFunction3`). Compare it with the same function on the
   other devices (`ButtonFunction3`, `MouFunction3`) to guess what a value means.

## Running tests with a person at the keyboard

7. **Show the test, don't time it.** A 90-second background capture failed because the
   user couldn't see when it was running. A window that shows events live, and that
   you close when you're done, worked the first time it ran.
8. **Ask what they actually did.** "No middle-button events" could mean "the button is
   swallowed" or "they didn't press it". One question settled it.

## Tooling on Windows

9. **Add-Type compiles with warnings as errors.** A member that hides an inherited one
   (`Name` on a `Form`) stops the whole compile. Then `New-Object` fails, and the
   script carries on with a null object.
10. **Don't assume Python.** The `python` command can be the Microsoft Store stub. Use
    PowerShell or the editor instead.
11. **Back up before writing vendor registry keys.** `reg export` of the whole vendor key
    takes a second, and double-clicking the file restores it.
12. **Some vendor processes won't stop.** `ApMsgFwd` survived `Stop-Process`, which was
    fine. Restarting `Apoint` alone applied the new setting.

## Watchdogs

14. **Test a hang check against a frozen process, not a dead one.** `NtSuspendProcess`
    makes a realistic hang in a second, and `NtResumeProcess` undoes it. It showed that
    `IsHungAppWindow` never fires for a background helper with hidden windows, with or
    without a posted message. Only a real round trip worked: `SendMessageCallback`
    with a deadline.
15. **A watchdog that restarts things needs a high bar.** Half a second of silence,
    twice, restarted a healthy but busy Apoint. Give it seconds, not milliseconds,
    and leave a freshly started process alone for a while.
16. **Prove the probe can see before trusting "saw nothing".** A zero-distance
    `SendInput` move confirms a Raw Input listener is alive, without clicking anything.

## Publishing

13. **Strip identifiers, not just names.** Device instance IDs can carry Bluetooth
    addresses or serials, and Firefox profile folders carry a per-install ID.
    `Get-TouchpadReport.ps1` trims both, and `scripts/hygiene.sh` blocks profile
    paths, personal emails and long digit runs from being committed.
