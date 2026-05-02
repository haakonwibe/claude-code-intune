# Git for Windows

Installs Git for Windows (machine scope) through the bundled Inno
Setup installer. Independent Intune assignment, not a dependency of
any other app in the kit.

## Layout

```
git-for-windows/
├── README.md          # this file
├── Detect.ps1         # uploaded to Intune on its own as the detection script
└── package/           # input to IntuneWinAppUtil.exe
    ├── Install.ps1
    ├── Uninstall.ps1
    └── Git-X.Y.Z-64-bit.exe   # gitignored, downloaded by Update-Installers.ps1
```

`package/` is the source folder for `IntuneWinAppUtil.exe`.
`Detect.ps1` sits outside `package/` so it is not bundled into the
`.intunewin`. Upload it to the Intune detection-rule UI on its own
as a custom detection script.

The bundled `Git-*-64-bit.exe` is downloaded by
`source\Update-Installers.ps1` from the latest
[git-for-windows/git GitHub release](https://github.com/git-for-windows/git/releases).
It is gitignored. Each clone downloads its own.

## Intune configuration

| Field             | Value                                                                  |
|-------------------|------------------------------------------------------------------------|
| Install command   | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Install.ps1`  |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Uninstall.ps1`|
| Install context   | **System**                                                             |
| Detection         | Custom script (upload `Detect.ps1`)                                    |

## Detection signal

`Detect.ps1` is a single `Test-Path 'C:\Program Files\Git\cmd\git.exe'`.
The machine-scope install lands the Git toolchain in
`C:\Program Files\Git\`, which SYSTEM context can read directly. No
marker file is needed.

## Notes

This app is an independent assignment to the Developers group, not a
Win32 dependency of Claude Code. Claude Code runs without Git. Users
who want it install it from Company Portal on demand.
