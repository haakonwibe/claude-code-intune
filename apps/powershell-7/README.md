# PowerShell 7

Installs PowerShell 7 (machine scope) through the bundled MSI.
Independent Intune assignment, not a dependency of any other app in
the kit.

## Layout

```
powershell-7/
├── README.md          # this file
├── Detect.ps1         # uploaded to Intune on its own as the detection script
└── package/           # input to IntuneWinAppUtil.exe
    ├── Install.ps1
    ├── Uninstall.ps1
    └── PowerShell-X.Y.Z-win-x64.msi   # gitignored, downloaded by Update-Installers.ps1
```

`package/` is the source folder for `IntuneWinAppUtil.exe`.
`Detect.ps1` sits outside `package/` so it is not bundled into the
`.intunewin`. Upload it to the Intune detection-rule UI on its own
as a custom detection script.

The bundled `PowerShell-*-win-x64.msi` is downloaded by
`source\Update-Installers.ps1` from the latest non-prerelease
[PowerShell/PowerShell GitHub release](https://github.com/PowerShell/PowerShell/releases).
It is gitignored. Each clone downloads its own.

## Intune configuration

| Field             | Value                                                                  |
|-------------------|------------------------------------------------------------------------|
| Install command   | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Install.ps1`  |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Uninstall.ps1`|
| Install context   | **System**                                                             |
| Detection         | Custom script (upload `Detect.ps1`)                                    |

## Detection signal

`Detect.ps1` is a single
`Test-Path 'C:\Program Files\PowerShell\7\pwsh.exe'`. The MSI install
path is the same across 7.x releases, so no wildcard scan is needed.

## Notes

Install properties match
[Microsoft's documented machine-managed install recipe](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows#install-the-msi-package-with-command-line-options)
(ADD_PATH=1, ENABLE_PSREMOTING=0, REGISTER_MANIFEST=1, USE_MU=1,
ENABLE_MU=1, ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1).

`Uninstall.ps1` finds the installed ProductCode in the uninstall
registry rather than reading it from the bundled .msi. PowerShell 7
changes ProductCode every release. If the bundled .msi version drifts
past what is on the device, a packaging-time ProductCode would fail
with `ERROR_UNKNOWN_PRODUCT`. The registry lookup works no matter
which version is bundled.
