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
   that get bundled into the three system-context `.intunewin` files:
   the latest Git for Windows installer, VS Code System x64
   installer, and PowerShell 7 MSI. They are placed in
   `apps\<app>\package\`. Claude Code's package has no bundled
   installer (its bootstrap is downloaded at install time on the
   device).

Both scripts write gitignored output, so each clone downloads its
own. Re-run `Update-Installers.ps1` when you want to bundle a newer
upstream version. Then rebuild and re-upload the affected
`.intunewin`.

Build all four at once:

```
.\source\Build-AllPackages.ps1
```

Or build per app:

```
.\source\IntuneWinAppUtil.exe -c apps\claude-code\package      -s Install.ps1 -o build\claude-code
.\source\IntuneWinAppUtil.exe -c apps\git-for-windows\package  -s Install.ps1 -o build\git-for-windows
.\source\IntuneWinAppUtil.exe -c apps\vscode\package           -s Install.ps1 -o build\vscode
.\source\IntuneWinAppUtil.exe -c apps\powershell-7\package     -s Install.ps1 -o build\powershell-7
```

`-c` is the source folder, `-s` is the setup file (used for naming),
`-o` is the output folder. The tool packages every file in the
source folder into the `.intunewin` - `Install.ps1`, `Uninstall.ps1`,
and the bundled installer for the three system-context apps.
`Detect.ps1` lives one level up at `apps/<app>/Detect.ps1`, on
purpose outside `package/` so it is not bundled. Upload it through
the detection-rules UI in section 4 instead.

## 2. Program (install/uninstall commands)

Same for all four apps:

| Field             | Value                                                                  |
|-------------------|------------------------------------------------------------------------|
| Install command   | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Install.ps1`  |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Uninstall.ps1`|
| Allow available uninstall | Yes                                                            |
| Install behavior  | See per-app context below                                              |
| Device restart behavior | No specific action                                               |

Per-app install behavior (context):

| App             | Install behavior |
|-----------------|------------------|
| Claude Code     | **User**         |
| Git for Windows | **System**       |
| VS Code         | **System**       |
| PowerShell 7    | **System**       |

The default return codes are correct (0 = success, 1 = failure). The
wrappers use a `$installSucceeded` flag pattern so cleanup errors
cannot hide the install or uninstall result.

## 3. Requirements

Same for all four apps:

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
| Claude Code     | `apps/claude-code/Detect.ps1`     | Marker file `C:\ProgramData\Hawkweave\ClaudeCodeIntune\Markers\ClaudeCode.tag` exists  |
| Git for Windows | `apps/git-for-windows/Detect.ps1` | `C:\Program Files\Git\cmd\git.exe` exists                          |
| VS Code         | `apps/vscode/Detect.ps1`          | `C:\Program Files\Microsoft VS Code\Code.exe` exists               |
| PowerShell 7    | `apps/powershell-7/Detect.ps1`    | `C:\Program Files\PowerShell\7\pwsh.exe` exists                    |

Other detection-rule options:

- **Run script as 32-bit process on 64-bit clients**: leave
  unchecked. None of the four detection scripts care about bitness -
  `ProgramData` and `Program Files` are not WOW64-redirected for the
  paths these scripts check.
- **Enforce script signature check and run script silently**: No.

Detection scripts always run as **SYSTEM**, no matter which context
the install ran as. Claude Code installs to a per-user profile that
SYSTEM cannot map to one fixed path. So `Install.ps1` writes a
marker file to a system-wide location on success and `Detect.ps1`
checks that marker.

## 5. Dependencies

None. All four apps are independent Win32 assignments. Leave the
**Dependencies** tab empty on every app, including Claude Code.
Claude Code runs without Git. Users who want one of the other apps
install it from Company Portal on demand.

## 6. Assignments

One target group: **Developers** (Entra ID security group).

| App             | Assignment type                           |
|-----------------|-------------------------------------------|
| Claude Code     | Available for enrolled devices            |
| Git for Windows | Available for enrolled devices            |
| VS Code         | Available for enrolled devices            |
| PowerShell 7    | Available for enrolled devices            |

`Available` puts the app in Company Portal so users install it when
they want it. Switch to `Required` if you want the app to install
automatically on group membership. For a small developer toolkit,
`Available` is usually the right choice.

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
