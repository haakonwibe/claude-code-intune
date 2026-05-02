# Architecture

## Goal
Curated developer toolkit deployed via Intune Company Portal.
Single Entra group ("Developers") receives the kit. Claude Code is the
anchor; VS Code, PowerShell 7, and Git for Windows are companions.

## Kit composition

| App             | Installer source                              | Context | Role      |
|-----------------|-----------------------------------------------|---------|-----------|
| Claude Code     | Anthropic bootstrap (`claude.ai/install.ps1`) | User    | Anchor    |
| Git for Windows | Direct installer (Inno Setup .exe)            | System  | Companion |
| VS Code         | Direct installer (Inno Setup .exe, System)    | System  | Companion |
| PowerShell 7    | Direct installer (MSI)                        | System  | Companion |

## Deployment patterns

Two patterns, both Win32 apps:

1. **Native installer wrapper** (Claude Code only)
   - Invokes `irm https://claude.ai/install.ps1 | iex` via wrapper
   - User context, since the installer is per-user
   - Wrapper handles PATH, since the bootstrap doesn't on Windows

2. **Direct installer Win32 packages** (VS Code, PowerShell 7, Git for Windows)
   - The vendor's official installer (`.exe` for Inno Setup, `.msi` for
     PowerShell 7) is fetched into `apps/<app>/package/` by
     `source/Update-Installers.ps1` and bundled into the `.intunewin`.
   - System context, machine scope.
   - Per-app `Install.ps1` finds the bundled installer next to itself
     (via `$PSScriptRoot` + glob) and invokes it silently with the
     appropriate flag set.
   - `Uninstall.ps1` invokes the installed uninstaller — `unins000.exe`
     for Inno Setup apps, `msiexec /x <ProductCode>` for PS7. PS7 uses
     a registry-discovered ProductCode rather than the bundled .msi's
     ProductCode, because PS7 changes ProductCode every release; if the
     bundled .msi version drifts past what's installed on the device,
     a packaging-time-bound ProductCode would fail.

The bundled installer files (`apps/*/package/*.exe`,
`apps/*/package/*.msi`) and the version manifest
(`source/installer-versions.json`) are gitignored — each clone fetches
its own.

## Why direct installers, not winget

Earlier iterations of this kit drove the three system-context apps
through `winget install --scope=machine`. That doesn't survive contact
with fresh Autopilot devices.

**winget is unsupported in SYSTEM context per Microsoft docs.** The
[Microsoft.WinGet troubleshooting page](https://learn.microsoft.com/windows/package-manager/winget/troubleshooting#exit-codes)
states this directly. In lab the failure manifests as
`STATUS_INVALID_IMAGE_FORMAT` (`0xC000007B`) on freshly-enrolled
devices: winget is an MSIX-packaged app and its activation fails when
the IME runs it under the SYSTEM token before the
`Microsoft.DesktopAppInstaller` package has staged into the SYSTEM
profile. Direct installers — vendor-published `.exe` and `.msi` files —
are the supported path for SYSTEM-context Win32 deployment, and that's
what this kit uses.

The user-context Claude Code app stays on its native installer wrapper
(`irm | iex`), which never went through winget.

## Detection via marker files

Intune Win32 detection scripts run in SYSTEM context regardless of the
install context. For user-context installs — Claude Code is the only one
in the kit — the binary lives in a per-user profile under `%USERPROFILE%`,
which SYSTEM cannot resolve to a single canonical path.

Rather than have detection enumerate `C:\Users\*` and reason about
redirected, temporary, and system profile types, the install writes a
marker file to a deterministic system-wide path on success:

    C:\ProgramData\Hawkweave\ClaudeCodeIntune\Markers\ClaudeCode.tag

Detection is then a single `Test-Path` against the marker. Install writes
the marker non-fatally (a marker-write failure does not fail the install,
only the detection signal). Uninstall removes the marker first, also
non-fatally.

This pattern applies to Claude Code only. The three system-context apps
detect against their actual install paths — `C:\Program Files\Git\cmd\git.exe`,
`C:\Program Files\Microsoft VS Code\Code.exe`,
`C:\Program Files\PowerShell\7\pwsh.exe` — which SYSTEM can read directly.

## Dependency graph

None. All four apps are independent Win32 assignments to the same Entra
group, surfaced in Company Portal as available apps. Claude Code does
not declare Git for Windows (or any other companion) as an Intune Win32
dependency — Claude Code runs without Git, and users who want a
companion install it on demand.

## Findings the implementation must handle

1. **IME runs 32-bit PowerShell**: scripts must self-elevate via sysnative
   when launched 32-bit on a 64-bit OS. Self-elevation also resolves the
   8.3 short-path normalization quirks that broke Remove-Item under 32-bit
   on profiles with dotted usernames — once the script re-launches into
   64-bit, idiomatic Remove-Item is fine.
2. **Bootstrap doesn't update PATH on Windows**: native installer wrapper
   must add %USERPROFILE%\.local\bin to HKCU\Environment\Path.
3. **REG_EXPAND_SZ preservation**: PATH must be written back with the
   same value kind it was read with, or %USERPROFILE%-style entries break.
4. **PowerShell pipeline-to-scalar collapse**: single-element pipeline
   results must be wrapped in @() to preserve array semantics.
5. **winget is unsupported in SYSTEM context** (Microsoft docs;
   verified in lab by `STATUS_INVALID_IMAGE_FORMAT` failure on fresh
   Autopilot devices). The three system-context apps bundle direct
   vendor installers instead.
6. **GUI-subsystem .exe + PowerShell `&` returns immediately**:
   PowerShell does not wait on Windows-GUI-subsystem executables
   launched via the call operator, so `$LASTEXITCODE` is never set and
   the wrapper reports failure while the installer is still running.
   Use `Start-Process -Wait -PassThru` and read `.ExitCode`. Affects
   the Inno Setup `.exe` installers (Git for Windows, VS Code) and
   their `unins000.exe` uninstallers; PS7's msiexec calls follow the
   same pattern for uniformity.

## Logging

All scripts log to:
- User-context: %LOCALAPPDATA%\Hawkweave\ClaudeCodeIntune\Logs\<App>-<Action>.log
- System-context: %ProgramData%\Hawkweave\ClaudeCodeIntune\Logs\<App>-<Action>.log

Logs are written in CMTrace format via a small inline `Write-Log`
function. Each entry is wrapped in `<![LOG[...]LOG]!>` with `time`,
`date`, `component`, `type`, and `thread` attributes, so CMTrace and
OneTrace pick the columns up directly. `Type=1` is informational, `2`
is a non-fatal warning (e.g. PATH update failure during install), `3`
is the failure / catch path. External command output (the Claude Code
bootstrap) is piped through `Write-Log` so it lands in the same log
instead of going only to stdout. The direct-installer scripts don't
pipe installer stdout — Inno Setup and msiexec write their own per-run
logs and the wrapper records the start line and exit code.

Exit code is independent of cleanup; success/failure flag pattern.

## Repo layout

```
claude-code-intune/
├── README.md
├── ARCHITECTURE.md
├── CLAUDE.md
├── apps/
│   ├── claude-code/
│   │   ├── README.md
│   │   ├── Detect.ps1            # uploaded to Intune separately
│   │   └── package/              # input to IntuneWinAppUtil.exe
│   │       ├── Install.ps1
│   │       └── Uninstall.ps1
│   ├── git-for-windows/
│   │   ├── README.md
│   │   ├── Detect.ps1
│   │   └── package/
│   │       ├── Install.ps1
│   │       ├── Uninstall.ps1
│   │       └── Git-X.Y.Z-64-bit.exe        # gitignored, fetched on demand
│   ├── vscode/
│   │   ├── README.md
│   │   ├── Detect.ps1
│   │   └── package/
│   │       ├── Install.ps1
│   │       ├── Uninstall.ps1
│   │       └── VSCodeSetup-x64-X.Y.Z.exe   # gitignored, fetched on demand
│   └── powershell-7/
│       ├── README.md
│       ├── Detect.ps1
│       └── package/
│           ├── Install.ps1
│           ├── Uninstall.ps1
│           └── PowerShell-X.Y.Z-win-x64.msi # gitignored, fetched on demand
├── source/
│   ├── Update-Tooling.ps1        # fetches IntuneWinAppUtil.exe
│   ├── Update-Installers.ps1     # fetches the three bundled installers
│   ├── Build-AllPackages.ps1
│   ├── IntuneWinAppUtil.exe      # gitignored
│   ├── tooling-versions.json     # gitignored
│   └── installer-versions.json   # gitignored
└── docs/
    └── intune-configuration.md   # packaging, dependencies, assignments
```

## Out of scope

- ARM64 support
- Non-Entra-joined devices
- Authentication automation (users authenticate Claude Code themselves)
- Managed settings governance (potential follow-up post)
