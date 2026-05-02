# claude-code-intune

A curated developer toolkit packaged as Win32 apps for deployment through the
Intune Company Portal. Claude Code is the anchor; VS Code, PowerShell 7, and
Git for Windows ride alongside it as companions.

The goal is to give a single Entra group ("Developers") a one-click path to a
working Claude Code setup on a managed Windows endpoint, without dropping out
of the standard Intune deployment model.

## What's in the kit

| App             | Installer source                              | Context | Role      |
|-----------------|-----------------------------------------------|---------|-----------|
| Claude Code     | Anthropic bootstrap (`claude.ai/install.ps1`) | User    | Anchor    |
| Git for Windows | Direct installer (Inno Setup .exe)            | System  | Companion |
| VS Code         | Direct installer (Inno Setup .exe, System)    | System  | Companion |
| PowerShell 7    | Direct installer (MSI)                        | System  | Companion |

All three companions are independent assignments to the same group, listed in
Company Portal as available apps. None is wired as a Win32 dependency of
Claude Code — Claude Code runs without Git, and users who want the companions
install them on demand.

The three system-context apps deploy the vendor's official installer
directly. Earlier iterations drove them through `winget install
--scope=machine`, but winget is unsupported in SYSTEM context per
Microsoft docs and fails on fresh Autopilot devices with
`STATUS_INVALID_IMAGE_FORMAT`. See [ARCHITECTURE.md](ARCHITECTURE.md),
"Why direct installers, not winget".

## Status

All four apps are implemented and lab-validated end-to-end on a fresh
Autopilot device: install succeeds via Company Portal, Intune detection
flips to "installed", and uninstall reverses cleanly. The three
system-context apps (Git for Windows, VS Code, PowerShell 7) were
ported from an earlier winget-wrapper pattern to direct vendor
installers, since winget is unsupported in SYSTEM context per Microsoft
docs (see [ARCHITECTURE.md](ARCHITECTURE.md), "Why direct installers,
not winget").

The Claude Code scripts handle the Windows / Intune gotchas documented in
[ARCHITECTURE.md](ARCHITECTURE.md): 32-bit IME execution, missing PATH update
from the bootstrap, REG_EXPAND_SZ preservation, PowerShell pipeline-to-scalar
collapse, and the SYSTEM-context winget limitation.

## Repo layout

```
claude-code-intune/
├── README.md            # this file
├── ARCHITECTURE.md      # design decisions, gotchas, deployment patterns
├── CLAUDE.md            # conventions for Claude Code when working in this repo
├── apps/
│   ├── claude-code/
│   │   ├── README.md
│   │   ├── Detect.ps1            # uploaded to Intune separately
│   │   └── package/              # input to IntuneWinAppUtil.exe
│   │       ├── Install.ps1
│   │       └── Uninstall.ps1
│   ├── git-for-windows/          # same shape, plus a bundled Git-*-64-bit.exe
│   ├── vscode/                   # same shape, plus a bundled VSCodeSetup-x64-*.exe
│   └── powershell-7/             # same shape, plus a bundled PowerShell-*-win-x64.msi
└── docs/
    └── intune-configuration.md   # packaging, dependencies, assignments
```

The bundled installer files are gitignored.

## Building .intunewin packages

Two fetch-and-verify scripts run before the build:

1. `.\source\Update-Tooling.ps1` — fetches and Authenticode-verifies
   the latest [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
   into `source\IntuneWinAppUtil.exe`.
2. `.\source\Update-Installers.ps1` — fetches the latest Git for Windows,
   VS Code (System x64), and PowerShell 7 installers into the per-app
   `package/` folders.

Both produce gitignored output, so each clone fetches its own.

Then build all four `.intunewin` packages in one shot:

```
.\source\Build-AllPackages.ps1
```

Or run a single app's command shape directly:

```
.\source\IntuneWinAppUtil.exe -c apps\<app>\package -s Install.ps1 -o build\<app>
```

`package/` is what gets bundled into the `.intunewin` — the install/uninstall
scripts plus the bundled installer for the three system-context apps.
`Detect.ps1` is not packaged; it uploads to Intune separately as a custom
detection script. See [docs/intune-configuration.md](docs/intune-configuration.md)
for the full per-app build, configuration, dependency, and assignment workflow.

## Conventions

- PowerShell 5.1 compatible (the Intune Management Extension runs Windows
  PowerShell, not pwsh).
- Scripts self-elevate to 64-bit via `sysnative` when launched 32-bit.
- Logs (CMTrace format, openable in CMTrace / OneTrace) go to
  `%LOCALAPPDATA%\Hawkweave\ClaudeCodeIntune\Logs` (user context) or `%ProgramData%\Hawkweave\ClaudeCodeIntune\Logs`
  (system context).
- Exit codes use a `$installSucceeded` flag, isolated from cleanup, so a
  cleanup failure can't mask install success or vice versa.

See [CLAUDE.md](CLAUDE.md) for the full set.

## Out of scope

- ARM64.
- Devices not joined to Entra ID.
- Automated authentication — users sign in to Claude Code themselves on first
  run.
- Managed-settings governance (potential follow-up).

## License

MIT — see [LICENSE](LICENSE).

*Not affiliated with Anthropic. "Claude" and "Claude Code" are trademarks
of Anthropic, PBC, used here only to identify the upstream product this
kit deploys.*
