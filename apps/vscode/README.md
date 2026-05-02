# Visual Studio Code

Installs Visual Studio Code (System x64) through the bundled Inno
Setup installer. Independent Intune assignment, not a dependency of
any other app in the kit.

## Layout

```
vscode/
├── README.md          # this file
├── Detect.ps1         # uploaded to Intune on its own as the detection script
└── package/           # input to IntuneWinAppUtil.exe
    ├── Install.ps1
    ├── Uninstall.ps1
    └── VSCodeSetup-x64-X.Y.Z.exe   # gitignored, downloaded by Update-Installers.ps1
```

`package/` is the source folder for `IntuneWinAppUtil.exe`.
`Detect.ps1` sits outside `package/` so it is not bundled into the
`.intunewin`. Upload it to the Intune detection-rule UI on its own
as a custom detection script.

The bundled `VSCodeSetup-x64-*.exe` is downloaded by
`source\Update-Installers.ps1` from
`https://code.visualstudio.com/sha/download?build=stable&os=win32-x64`,
which redirects to the versioned filename on the Microsoft CDN. It is
gitignored. Each clone downloads its own.

## Intune configuration

| Field             | Value                                                                  |
|-------------------|------------------------------------------------------------------------|
| Install command   | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Install.ps1`  |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Uninstall.ps1`|
| Install context   | **System**                                                             |
| Detection         | Custom script (upload `Detect.ps1`)                                    |

## Detection signal

`Detect.ps1` is a single
`Test-Path 'C:\Program Files\Microsoft VS Code\Code.exe'`. The
System x64 installer lands VS Code in
`C:\Program Files\Microsoft VS Code\`, which SYSTEM context can read
directly. User-scope installs (under
`%LOCALAPPDATA%\Programs\Microsoft VS Code`) are not detected on
purpose - this app deploys the system version.

## Notes

`Install.ps1` runs the bundled installer with `/MERGETASKS=!runcode`
to turn off the post-install "launch VS Code" task. Under SYSTEM
context that would launch in session 0 with no GUI.
