# PowerShell 7

Installs PowerShell 7 (machine scope) via the bundled MSI. Companion
app — independent assignment, not a dependency.

## Layout

```
powershell-7/
├── README.md          # this file
├── Detect.ps1         # uploaded to Intune separately as the detection script
└── package/           # input to IntuneWinAppUtil.exe
    ├── Install.ps1
    ├── Uninstall.ps1
    └── PowerShell-X.Y.Z-win-x64.msi   # gitignored, fetched by Update-Installers.ps1
```

`package/` is the source folder for `IntuneWinAppUtil.exe`. `Detect.ps1`
sits outside `package/` so it is not bundled into the `.intunewin` —
upload it to the Intune detection-rule UI separately as a custom detection
script.

The bundled `PowerShell-*-win-x64.msi` is fetched by
`source\Update-Installers.ps1` from the latest non-prerelease
[PowerShell/PowerShell GitHub release](https://github.com/PowerShell/PowerShell/releases).
It is gitignored — each clone fetches its own.

## Intune configuration

| Field             | Value                                                                  |
|-------------------|------------------------------------------------------------------------|
| Install command   | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Install.ps1`  |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Uninstall.ps1`|
| Install context   | **System**                                                             |
| Detection         | Custom script (upload `Detect.ps1`)                                    |

## Detection signal

`Detect.ps1` is a single `Test-Path 'C:\Program Files\PowerShell\7\pwsh.exe'`.
The MSI install path is deterministic across 7.x releases, so no
wildcard scan is needed.

## Notes

Earlier versions of these scripts drove PS7 through `winget install
Microsoft.PowerShell --scope=machine`. The winget community manifest
ships an MSIX bundle that lands pwsh.exe under
`C:\Program Files\WindowsApps\Microsoft.PowerShell_<ver>_x64__8wekyb3d8bbwe\`,
which forced a wildcard detection plus bitness self-elevation past
WOW64 redirection. winget is also unsupported in SYSTEM context per
Microsoft docs; the kit pivoted to bundling the official MSI directly.
See [ARCHITECTURE.md](../../ARCHITECTURE.md), "Direct installer Win32
packages".

Install properties match
[Microsoft's documented machine-managed install recipe](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows#install-the-msi-package-with-command-line-options)
(ADD_PATH=1, ENABLE_PSREMOTING=0, REGISTER_MANIFEST=1, USE_MU=1,
ENABLE_MU=1, ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1).

`Uninstall.ps1` discovers the installed ProductCode in the uninstall
registry rather than reading it from the bundled .msi. PS7 changes
ProductCode every release; if the bundled .msi version drifts past
what's installed on a device, a packaging-time-bound ProductCode would
fail with `ERROR_UNKNOWN_PRODUCT`. The registry-discovery approach
works regardless of which version is bundled.
