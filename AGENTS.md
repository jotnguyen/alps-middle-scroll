# AGENTS.md: alps-middle-scroll

A public repo: the diagnosis and fixes for a Dell Latitude Alps middle-button scroll
that stopped working in browsers, plus the PowerShell scripts that found them. Start
with `HANDOFF.md`: the current status, the reading order, and the possible follow-ups.

## Non-negotiables

- **Nothing personal in git.** No real `C:\Users\<name>` paths (use `%USERPROFILE%`,
  `%APPDATA%`, `$env:TEMP`), no personal emails, no Firefox profile folder IDs, no
  device instance IDs past the hardware ID, no serials or MAC addresses.
  `bash scripts/hygiene.sh` must print `hygiene-ok`. The hooks in `.githooks/` run it
  on every commit and every commit message (`git config core.hooksPath .githooks`).
  Never bypass them with `--no-verify`.
- **No AI attribution** in commits or PRs: no `Co-Authored-By` or "Generated with"
  trailers. Commit with the repo's local noreply identity.
- **No vendor code.** Don't copy Alps, Dell or Mozilla files here. The scripts only read
  and write settings.

## Working on a real machine

- **Read-only first.** `Get-TouchpadReport.ps1` and `Watch-MiddleButton.ps1` change
  nothing. Use them before proposing a change.
- **Ask before changing anything,** and use `-WhatIf` to show the plan.
  `Set-StickMiddleButton.ps1` backs up `HKCU\Software\Alps\Apoint` before it writes.
  `Set-FirefoxDirectManipulation.ps1` touches only its own lines in `user.js`.
- **Don't kill the user's browser.** Tell them to restart it.
- **Show interactive tests.** When a test needs the user to press something, open a
  visible window (`Watch-MiddleButton.ps1`) instead of running a timed background
  capture, and ask what they actually did.

## Code style

- Windows PowerShell 5.1 compatible: no `??`, no `?.`, no ternary.
- ASCII only in `.ps1` files. 5.1 reads UTF-8 without a BOM as ANSI.
- Comment-based help at the top of each script, and `SupportsShouldProcess` on
  anything that writes.
- Inline C# via `Add-Type` compiles with warnings as errors, so don't hide inherited
  members (for example `Name` on a `Form`).

## Checks

```bash
bash scripts/hygiene.sh
```

```powershell
Get-ChildItem scripts\*.ps1 | ForEach-Object { $e = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e); "$($_.Name): $($e.Count) parse errors" }
```
