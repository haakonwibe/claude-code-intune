# Claude Code instructions for claude-code-intune

## Context

This repo holds Win32 app deployment scripts for Intune. Each app under
`apps/<app-name>/` has:

- `Detect.ps1` at the app root — uploaded to Intune separately as a custom
  detection script (not bundled into the `.intunewin`).
- `package/Install.ps1` and `package/Uninstall.ps1` — packaged into a
  `.intunewin` by `IntuneWinAppUtil.exe -c apps\<app>\package`.
- `package/<bundled-installer>` — the three system-context apps each
  bundle a vendor installer (`Git-*-64-bit.exe`,
  `VSCodeSetup-x64-*.exe`, `PowerShell-*-win-x64.msi`) fetched on demand
  by `source\Update-Installers.ps1`. Gitignored; each clone fetches its
  own. Claude Code's `package/` has no bundled installer.
- `README.md` — per-app summary, Intune fields, and detection signal.

The architecture, design decisions, and known gotchas are in
ARCHITECTURE.md. Read it before making changes.

## Conventions

- PowerShell 5.1 compatibility required (IME runs Windows PowerShell, not pwsh)
- All scripts self-elevate to 64-bit via sysnative when launched 32-bit.
  Once they re-launch into 64-bit PowerShell, idiomatic Remove-Item is
  fine for filesystem cleanup.
- Logging in CMTrace format via an inline `Write-Log` function to
  %LOCALAPPDATA%\Hawkweave\ClaudeCodeIntune\Logs (user) or %ProgramData%\Hawkweave\ClaudeCodeIntune\Logs (system);
  Type 1 = info, Type 2 = non-fatal warning, Type 3 = failure / catch path
- Exit code logic uses a $installSucceeded flag, isolated from cleanup
- Pipeline assignments wrap in @() to preserve array semantics
- HKCU\Environment writes preserve REG_EXPAND_SZ via [Microsoft.Win32.Registry]
- Deployed scripts (apps/*) stay ASCII-only. PS5.1 in the IME reads
  BOM-less .ps1 files as Windows-1252; a single em dash or smart quote
  in a string literal breaks the parse. Use `-` not `—`, `'` not `'`, etc.

## What's already validated in lab

All four apps are lab-validated end-to-end on a fresh Autopilot device:
install via Company Portal succeeds, Intune detection flips to
"installed", and uninstall reverses cleanly.

The three system-context apps (Git for Windows, VS Code, PowerShell 7)
were originally winget wrappers; they have since been ported to direct
vendor installers because winget is unsupported in SYSTEM context per
Microsoft docs (see ARCHITECTURE.md, "Why direct installers, not
winget"). The direct-installer scripts follow the same conventions as
Claude Code (bitness self-elevation, CMTrace logging,
`$installSucceeded` flag, `Start-Process -Wait -PassThru` for reliable
exit-code capture).

All four apps are independent assignments to the Developers group — no
Win32 dependency wiring. Git for Windows is a companion alongside VS
Code and PowerShell 7; users install it on demand. See
`docs/intune-configuration.md` section 5.

## Out of scope (don't touch)

- Anything that adds new gotcha handling not described in ARCHITECTURE.md.
  The findings list in ARCHITECTURE.md plus the marker-file detection
  approach are what we've validated.
- ARM64, non-Entra-joined devices, automated authentication.
- Managed-settings governance (potential follow-up).

## Style

- Comment-based help on every script (Synopsis, Description, Notes)
- Inline comments for non-obvious choices, especially the gotcha mitigations
  (point to ARCHITECTURE.md by name, not by gotcha number)
- No emojis in script output
- `Write-Log` (defined inline) for log content in deployed scripts. The
  maintainer scripts under `source/` use `Write-Host` for interactive
  feedback since they aren't packaged into a `.intunewin`.