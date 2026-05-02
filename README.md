# Claude Code for Intune

*I just wanted to see if I could wrap the user installer for Claude
Code into something actually usable for Company Portal.*

A small developer toolkit packaged as Win32 apps for the Intune Company
Portal. The main app is Claude Code. VS Code, PowerShell 7, and Git for
Windows come along as well.

The goal: give one Entra group ("Developers") an easy way to install
Claude Code on a managed Windows device, all through normal Intune
deployment.

## What is in the kit

| App             | Installer source                              | Context |
|-----------------|-----------------------------------------------|---------|
| Claude Code     | Anthropic bootstrap (`claude.ai/install.ps1`) | User    |
| Git for Windows | Direct installer (Inno Setup .exe)            | System  |
| VS Code         | Direct installer (Inno Setup .exe, System)    | System  |
| PowerShell 7    | Direct installer (MSI)                        | System  |

All four apps are separate installs in Intune. None of them is set up
as a Win32 dependency of any other. Claude Code works on its own.
Users can install the other three from Company Portal when they want
them.

## Repo layout

```
claude-code-intune/
├── README.md            # this file
├── apps/
│   ├── claude-code/
│   │   ├── README.md
│   │   ├── Detect.ps1            # uploaded to Intune on its own
│   │   └── package/              # input to IntuneWinAppUtil.exe
│   │       ├── Install.ps1
│   │       └── Uninstall.ps1
│   ├── git-for-windows/          # same shape, plus a bundled Git-*-64-bit.exe
│   ├── vscode/                   # same shape, plus a bundled VSCodeSetup-x64-*.exe
│   └── powershell-7/             # same shape, plus a bundled PowerShell-*-win-x64.msi
└── docs/
    └── intune-configuration.md   # how to package, set up, and assign the apps
```

The bundled installer files are gitignored.

## Building .intunewin packages

Two helper scripts run before the build:

1. `.\source\Update-Tooling.ps1` - downloads the latest
   [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
   into `source\IntuneWinAppUtil.exe` and checks the Authenticode
   signature.
2. `.\source\Update-Installers.ps1` - downloads the latest Git for
   Windows, VS Code (System x64), and PowerShell 7 installers into the
   per-app `package/` folders. Each one is signature-checked too.

Both scripts write files that are gitignored, so each clone downloads
its own.

Then build all four `.intunewin` packages at once:

```
.\source\Build-AllPackages.ps1
```

Or build one app on its own:

```
.\source\IntuneWinAppUtil.exe -c apps\<app>\package -s Install.ps1 -o build\<app>
```

`package/` is the folder that goes into the `.intunewin`. It holds the
install and uninstall scripts plus the bundled installer for the three
system-context apps. `Detect.ps1` is not packaged. It is uploaded to
Intune on its own as a custom detection script. See
[docs/intune-configuration.md](docs/intune-configuration.md) for the
full per-app build, setup, and assignment steps.

## Conventions

- PowerShell 5.1 only (the Intune Management Extension runs Windows
  PowerShell, not pwsh).
- Scripts re-launch themselves as 64-bit through `sysnative` when
  started as 32-bit.
- Logs are written in CMTrace format (open them in CMTrace or
  OneTrace). User-context logs go to
  `%LOCALAPPDATA%\Hawkweave\ClaudeCodeIntune\Logs`. System-context
  logs go to `%ProgramData%\Hawkweave\ClaudeCodeIntune\Logs`.
- Exit codes use a `$installSucceeded` flag. Cleanup steps cannot
  affect the install/uninstall result.

## Out of scope

- ARM64.
- Devices that are not joined to Entra ID.
- Sign-in automation. Users sign in to Claude Code themselves on first
  run.
- Managed-settings governance (maybe later).

## License

MIT - see [LICENSE](LICENSE).

*Not affiliated with Anthropic. "Claude" and "Claude Code" are trademarks
of Anthropic, PBC, used here only to identify the upstream product this
kit deploys.*
