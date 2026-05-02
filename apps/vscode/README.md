# Visual Studio Code

Installs Visual Studio Code (System x64) via the bundled Inno Setup
installer. Companion app — independent assignment, not a dependency.

## Layout

```
vscode/
├── README.md          # this file
├── Detect.ps1         # uploaded to Intune separately as the detection script
└── package/           # input to IntuneWinAppUtil.exe
    ├── Install.ps1
    ├── Uninstall.ps1
    └── VSCodeSetup-x64-X.Y.Z.exe   # gitignored, fetched by Update-Installers.ps1
```

`package/` is the source folder for `IntuneWinAppUtil.exe`. `Detect.ps1`
sits outside `package/` so it is not bundled into the `.intunewin` —
upload it to the Intune detection-rule UI separately as a custom detection
script.

The bundled `VSCodeSetup-x64-*.exe` is fetched by
`source\Update-Installers.ps1` from
`https://code.visualstudio.com/sha/download?build=stable&os=win32-x64`,
which 302s to the versioned filename on the Microsoft CDN. It is
gitignored — each clone fetches its own.

## Intune configuration

| Field             | Value                                                                  |
|-------------------|------------------------------------------------------------------------|
| Install command   | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Install.ps1`  |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Uninstall.ps1`|
| Install context   | **System**                                                             |
| Detection         | Custom script (upload `Detect.ps1`)                                    |

## Detection signal

`Detect.ps1` is a single `Test-Path 'C:\Program Files\Microsoft VS Code\Code.exe'`.
The System x64 installer lands VS Code in
`C:\Program Files\Microsoft VS Code\`, which SYSTEM context can read
directly. User-scope installs (under
`%LOCALAPPDATA%\Programs\Microsoft VS Code`) are intentionally not
detected — this app deploys the system variant.

## Notes

Earlier versions of these scripts drove VS Code through `winget install
Microsoft.VisualStudioCode --scope=machine`. winget is unsupported in
SYSTEM context per Microsoft docs and fails on fresh Autopilot devices,
so the kit pivoted to bundling the installer directly. See
[ARCHITECTURE.md](../../ARCHITECTURE.md), "Direct installer Win32 packages".

`Install.ps1` invokes the bundled installer with `/MERGETASKS=!runcode`
to disable the post-install "launch VS Code" task — under SYSTEM context
that would launch in session 0 with no GUI.
