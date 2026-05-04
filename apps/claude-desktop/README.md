# Claude Desktop

Anthropic's Claude Desktop app, deployed via the bundled MSIX through
`Add-AppxProvisionedPackage` (the only install path that works for
the packaged service inside the MSIX; `Add-AppxPackage` fails with
0x80073D28). Optionally enables the Virtual Machine Platform Windows
feature for Cowork. Optionally writes the seven Anthropic-documented
HKLM policy values from `package/policies.json`.

## Layout

```
claude-desktop/
├── README.md                # this file
├── Detect.ps1               # uploaded to Intune on its own as the detection script
└── package/                 # input to IntuneWinAppUtil.exe
    ├── Install.ps1          # MSIX install + VMP + policies + detection key
    ├── Uninstall.ps1        # MSIX removal + cleanup; -RemoveVMP optional
    ├── policies.json        # the seven HKLM policy values (source of truth)
    ├── policies.schema.json
    └── Claude.msix          # gitignored; fetched by source\Update-Installers.ps1
```

`package/` is the source folder for `IntuneWinAppUtil.exe`.
`Detect.ps1` sits outside `package/` so it is not bundled into the
`.intunewin`. Upload it to the Intune detection-rule UI on its own
as a custom detection script.

## Intune configuration

| Field             | Value                                                                                       |
|-------------------|---------------------------------------------------------------------------------------------|
| Install command   | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Install.ps1`   |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Uninstall.ps1` |
| Install context   | **System**                                                                                  |
| Detection         | Custom script (upload `Detect.ps1`)                                                         |

`Install.ps1` accepts `-EnableCowork`. See
[Cowork (Virtual Machine Platform)](#cowork-virtual-machine-platform)
below for the full behavior and the multi-variant deployment pattern.

## Cowork (Virtual Machine Platform)

Pass `-EnableCowork` to `Install.ps1` to enable Virtual Machine
Platform, which Claude Desktop's Cowork sandbox requires:

```
powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Install.ps1 -EnableCowork
```

Behavior:

- **State check first.** If VMP is already `Enabled` or
  `EnablePending`, the script logs "no change" and continues with
  the rest of the install. Re-runs are safe and silent.
- **Hardware precheck only when needed.** When state is `Disabled`,
  the script checks SLAT and `VirtualizationFirmwareEnabled` via
  `Win32_Processor`. If either is missing, it soft-skips: install
  continues, Cowork is unavailable on the device, no install
  failure.
- **DISM enable.** On precheck pass, calls
  `Enable-WindowsOptionalFeature -Online -All -NoRestart`. If DISM
  reports `RestartNeeded`, the script exits **3010** instead of 0;
  Intune surfaces this as "Installed successfully, reboot required"
  in Company Portal via the **Device restart behavior** setting.

The same `.intunewin` can be uploaded as multiple Intune Win32 app
objects with different install command lines (Standard / Cowork),
each assigned to a different Entra group - useful for piloting
Cowork on a subset of devices without rebuilding the package.

**Hyper-V testing caveat**: nested-virt-enabled guests report
`SLAT = true` but `VirtualizationFirmwareEnabled = false` (a known
WMI quirk in guests; there is no virtual-firmware "enable VT-x"
toggle inside the guest). The precheck soft-skips on this even
though DISM enable would actually succeed. To validate the full
enable path, test on physical hardware - or manually call
`Enable-WindowsOptionalFeature` on the VM first and then deploy,
which puts the script onto the "VMP already enabled" branch.

## Detection signal

`Install.ps1` writes a `Version` REG_SZ to
`HKLM:\SOFTWARE\Hawkweave\ClaudeCodeIntune\Apps\ClaudeDesktop`
formatted as `<msix-version>+<policies-hash-short>` (e.g.
`1.5354.0+a3f9c2d1`). `Detect.ps1` reads this value and echoes it
to stdout. Changing `policies.json` produces a new hash suffix on
the next build, so policy-only changes redeploy automatically on
the next Intune sync.

## Policy governance

`package/policies.json` is the source of truth for the seven HKLM
values written by `Install.ps1` under
`HKLM:\SOFTWARE\Policies\Claude`. To change policies: edit
`policies.json`, rerun `.\source\Build-AllPackages.ps1`, upload the
new `build\claude-desktop\Install.intunewin` to the existing Intune
Win32 app (Properties > App information > Edit, replace the package
file). Detection picks up the new hash and Intune redeploys.

Anthropic's enterprise-config article documents the seven keys in
detail:
[Enterprise configuration for Claude Desktop](https://support.claude.com/en/articles/12622667-enterprise-configuration-for-claude-desktop).

## Uninstall

`Uninstall.ps1` performs:

1. **MSIX removal** in two calls:
   - `Remove-AppxProvisionedPackage` drops the provisioning entry
     so future logons do not auto-install the package.
   - `Remove-AppxPackage -AllUsers` removes per-user installs that
     already happened.

   Both are needed - provisioning removal alone leaves users who
   logged in while the package was provisioned with the app on
   their Start menu and the ability to launch it.
2. **HKLM policy values** under `HKLM:\SOFTWARE\Policies\Claude`.
   The parent key is dropped only if no other values or subkeys
   remain (so adjacent policy values written by GPO or Settings
   Catalog are preserved).
3. **Detection key** at
   `HKLM:\SOFTWARE\Hawkweave\ClaudeCodeIntune\Apps\ClaudeDesktop`
   removed entirely; Detect.ps1 then reports "not detected" on the
   next sync.

Pass `-RemoveVMP` to also disable Virtual Machine Platform - off
by default because VMP is shared with WSL2, Windows Sandbox, Docker
Desktop, and Hyper-V containers; disabling will break those
workloads on the device.

## Dependencies

None. Claude Desktop runs independently of the other apps in the
kit. Leave the Intune **Dependencies** tab empty. See
[docs/intune-configuration.md](../../docs/intune-configuration.md).
