# Intune configuration

How to package the Win32 apps in this repo and set them up in the
Microsoft Intune admin center. Each section maps to a tab or page in
the **Apps > Windows > Add > Windows app (Win32)** workflow.

## 1. Packaging

Each app's `package/` subfolder is the source for one Win32 app. Two
helper scripts run before the build:

1. `.\source\Update-Tooling.ps1` - updates
   [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
   at `source\IntuneWinAppUtil.exe`. Downloads the latest release and
   checks the Authenticode signature.
2. `.\source\Update-Installers.ps1` - updates the per-app installers
   that get bundled into four `.intunewin` files: the latest Git for
   Windows installer, VS Code System x64 installer, PowerShell 7 MSI,
   and Claude Desktop MSIX. They are placed in `apps\<app>\package\`.
   Claude Code's package has no bundled installer (its bootstrap is
   downloaded at install time on the device).

Both scripts write gitignored output, so each clone downloads its
own. Re-run `Update-Installers.ps1` when you want to bundle a newer
upstream version. Then rebuild and re-upload the affected
`.intunewin`.

Build all five at once:

```
.\source\Build-AllPackages.ps1
```

Or build per app:

```
.\source\IntuneWinAppUtil.exe -c apps\claude-code\package      -s Install.ps1 -o build\claude-code
.\source\IntuneWinAppUtil.exe -c apps\git-for-windows\package  -s Install.ps1 -o build\git-for-windows
.\source\IntuneWinAppUtil.exe -c apps\vscode\package           -s Install.ps1 -o build\vscode
.\source\IntuneWinAppUtil.exe -c apps\powershell-7\package     -s Install.ps1 -o build\powershell-7
.\source\IntuneWinAppUtil.exe -c apps\claude-desktop\package   -s Install.ps1 -o build\claude-desktop
```

`-c` is the source folder, `-s` is the setup file (used for naming),
`-o` is the output folder. The tool packages every file in the
source folder into the `.intunewin` - `Install.ps1`, `Uninstall.ps1`,
and the bundled installer or MSIX for the four system-context apps
(Claude Desktop also bundles `policies.json` and
`policies.schema.json`). `Detect.ps1` lives one level up at
`apps/<app>/Detect.ps1`, on purpose outside `package/` so it is not
bundled. Upload it through the detection-rules UI in section 4
instead.

## 2. Program (install/uninstall commands)

Same for all five apps:

| Field             | Value                                                                                       |
|-------------------|---------------------------------------------------------------------------------------------|
| Install command   | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Install.ps1`   |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Uninstall.ps1` |
| Allow available uninstall | Yes                                                                                 |
| Install behavior  | See per-app context below                                                                   |
| Device restart behavior | No specific action                                                                    |

Per-app install behavior (context):

| App             | Install behavior |
|-----------------|------------------|
| Claude Code     | **User**         |
| Git for Windows | **System**       |
| VS Code         | **System**       |
| PowerShell 7    | **System**       |
| Claude Desktop  | **System**       |

The default return codes are correct (0 = success, 1 = failure).
Claude Desktop's `Install.ps1` additionally returns 3010 if
`-EnableCowork` triggered a VMP enable that requires a reboot to
finalize - Intune surfaces the prompt via the **Device restart
behavior** setting. All scripts isolate cleanup-step errors from
the main exit code, so a failed cleanup never hides install or
uninstall success or failure.

For Claude Desktop, you may want to deploy the same `.intunewin` as
multiple Intune Win32 app objects with different install command
lines, each targeting a different Entra group:

| Variant   | Install command                                                                                                | Typical use |
|-----------|----------------------------------------------------------------------------------------------------------------|-------------|
| Standard  | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Install.ps1`                      | Policies only, no Cowork. Default for most users. |
| Cowork    | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Install.ps1 -EnableCowork`        | Pilot group with VMP-capable hardware. Triggers a soft reboot on first install. |

Same `.intunewin`, multiple app entries; only the install command
line and the assignment group differ.

## 3. Requirements

Same for all five apps:

| Field                       | Value             |
|-----------------------------|-------------------|
| Operating system architecture | x64             |
| Minimum operating system    | Windows 10 1809   |

No extra requirement rules are needed.

## 4. Detection rules

For every app: **Rules format = Use a custom detection script**.
Upload the app's `Detect.ps1`.

| App             | Detection script                  | What it checks                                                    |
|-----------------|-----------------------------------|--------------------------------------------------------------------|
| Claude Code     | `apps/claude-code/Detect.ps1`     | Marker file `C:\ProgramData\Hawkweave\ClaudeCodeIntune\Markers\ClaudeCode.tag` exists |
| Git for Windows | `apps/git-for-windows/Detect.ps1` | `C:\Program Files\Git\cmd\git.exe` exists                          |
| VS Code         | `apps/vscode/Detect.ps1`          | `C:\Program Files\Microsoft VS Code\Code.exe` exists               |
| PowerShell 7    | `apps/powershell-7/Detect.ps1`    | `C:\Program Files\PowerShell\7\pwsh.exe` exists                    |
| Claude Desktop  | `apps/claude-desktop/Detect.ps1`  | `Version` REG_SZ at `HKLM:\SOFTWARE\Hawkweave\ClaudeCodeIntune\Apps\ClaudeDesktop` exists (echoed to stdout) |

Other detection-rule options:

- **Run script as 32-bit process on 64-bit clients**: leave
  unchecked. None of the kit's detection scripts care about bitness -
  `ProgramData` and `Program Files` are not WOW64-redirected for the
  paths these scripts check.
- **Enforce script signature check and run script silently**: No.

Detection scripts always run as **SYSTEM**, no matter which context
the install ran as. Claude Code installs to a per-user profile that
SYSTEM cannot map to one fixed path. So `Install.ps1` writes a
marker file to a system-wide location on success and `Detect.ps1`
checks that marker.

## 5. Dependencies

None. All five apps are independent Win32 assignments. Leave the
**Dependencies** tab empty on every app, including Claude Code.
Claude Code runs without Git. Users who want one of the other apps
install it from Company Portal on demand.

## 6. Assignments

One target group: **Developers** (Entra ID security group).

| App             | Assignment type                                                  |
|-----------------|------------------------------------------------------------------|
| Claude Code     | Available for enrolled devices                                   |
| Git for Windows | Available for enrolled devices                                   |
| VS Code         | Available for enrolled devices                                   |
| PowerShell 7    | Available for enrolled devices                                   |
| Claude Desktop  | Available for enrolled devices (or Required for broader rollout) |

`Available` puts the app in Company Portal so users install it when
they want it. Switch to `Required` if you want the app to install
automatically on group membership. For a small developer toolkit,
`Available` is usually the right choice; for Claude Desktop on a
managed device fleet, `Required` may make more sense if the app is
meant to be on every developer's device by default.

## 7. Checks and troubleshooting

Logs on the managed device:

| Source                               | Path                                                                                  |
|--------------------------------------|----------------------------------------------------------------------------------------|
| IME                                  | `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log` |
| Script execution (AgentExec)         | `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log`            |
| User-context wrapper log (CMTrace)   | `%LOCALAPPDATA%\Hawkweave\ClaudeCodeIntune\Logs\<App>-<Action>.log`                    |
| System-context wrapper log (CMTrace) | `%ProgramData%\Hawkweave\ClaudeCodeIntune\Logs\<App>-<Action>.log`                     |

State signal (Claude Code):

- The detection marker
  `C:\ProgramData\Hawkweave\ClaudeCodeIntune\Markers\ClaudeCode.tag`
  is what `Detect.ps1` reads. If Claude Code is installed but Intune
  says it is not detected, check that the marker is there and look
  at what is in it (timestamp, user, version, install path written
  by `Install.ps1`).

State signal (Claude Desktop):

- The detection key
  `HKLM:\SOFTWARE\Hawkweave\ClaudeCodeIntune\Apps\ClaudeDesktop` has
  a `Version` REG_SZ written by `Install.ps1`, formatted as
  `<msix-version>+<policies-hash-short>` (e.g. `1.5354.0+a3f9c2d1`).
  `Detect.ps1` reads this value and echoes it to stdout. Changing
  `apps\claude-desktop\package\policies.json` and rebuilding the
  `.intunewin` produces a new hash suffix, so detection automatically
  reports "needs update" on the next sync.

Sync notes:

- After uploading or reconfiguring an app, Company Portal can take
  5-15 minutes to reflect the change. Force a sync from **Settings >
  Accounts > Access work or school > Info > Sync**, or from the
  Settings page in Company Portal.
- The IME caches detection results between cycles. If a new install
  says "not detected" right after install, wait one IME cycle
  (about one hour) or trigger a sync. Re-running the install does
  not always clear the cache.
- Detection scripts running as SYSTEM can give different results
  than manual runs in a user shell. When debugging, run the script
  through `psexec -s -i powershell.exe` or similar to get SYSTEM
  context.

### Claude Desktop notes

**Updating policies**: edit
`apps\claude-desktop\package\policies.json`, rerun
`.\source\Build-AllPackages.ps1`, and upload the new
`build\claude-desktop\Install.intunewin` to the existing Intune
Win32 app (Properties > App information > Edit, replace the package
file). The hash suffix in the detection key changes, so detection
reports "needs update" and Intune redeploys on the next sync.

**AppLocker**: per Anthropic's deploy article, AppLocker may
restrict MSIX packages by default. If pilot installs fail silently
with no useful error in the IME log, verify the tenant's AppLocker
policy allows MSIX installs or whitelists Anthropic's Claude Desktop
publisher. AppLocker is the first thing to check when MSIX rollout
misbehaves on a subset of devices.

**Uninstall behavior**: `Uninstall.ps1` removes both the
provisioned MSIX (`Remove-AppxProvisionedPackage`) and any per-user
installs (`Remove-AppxPackage -AllUsers`). Both calls are needed -
provisioning removal alone leaves users who already had the package
installed with the app on their Start menu and able to launch it.
The seven HKLM policy values and the detection key are also
removed. Virtual Machine Platform is left **intact** by default;
pass `-RemoveVMP` (via the uninstall command of a separate Win32
app variant) to disable it. Warning: VMP is shared with WSL2,
Windows Sandbox, Docker Desktop, and Hyper-V containers; disabling
will break those workloads on the device.

**Anthropic references**:
[Deploy Claude Desktop for Windows](https://support.claude.com/en/articles/12622703-deploy-claude-desktop-for-windows),
[Enterprise configuration for Claude Desktop](https://support.claude.com/en/articles/12622667-enterprise-configuration-for-claude-desktop).
