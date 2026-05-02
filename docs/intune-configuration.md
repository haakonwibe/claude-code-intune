# Intune configuration

Reference for packaging the Win32 apps in this repo and configuring them in
the Microsoft Intune admin center. Each section maps to a tab/page in the
**Apps > Windows > Add > Windows app (Win32)** workflow.

## 1. Packaging

Each app's `package/` subfolder is the source for one Win32 app. Two
fetch scripts run before the build:

1. `.\source\Update-Tooling.ps1` — refreshes the
   [Microsoft Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool)
   at `source\IntuneWinAppUtil.exe`. Downloads and Authenticode-verifies
   the latest release.
2. `.\source\Update-Installers.ps1` — refreshes the per-app installer
   payloads bundled into the three system-context `.intunewin` files:
   the latest Git for Windows installer, VS Code System x64 installer,
   and PowerShell 7 MSI. Drops them into `apps\<app>\package\`. Claude
   Code's package has no bundled installer (its bootstrap is downloaded
   at install time on the device).

Both produce gitignored output, so each clone fetches its own. Re-run
`Update-Installers.ps1` whenever you want to bundle a newer upstream
version; rebuild and re-upload the affected `.intunewin` afterwards.

Build all four at once:

```
.\source\Build-AllPackages.ps1
```

Or invoke per-app:

```
.\source\IntuneWinAppUtil.exe -c apps\claude-code\package      -s Install.ps1 -o build\claude-code
.\source\IntuneWinAppUtil.exe -c apps\git-for-windows\package  -s Install.ps1 -o build\git-for-windows
.\source\IntuneWinAppUtil.exe -c apps\vscode\package           -s Install.ps1 -o build\vscode
.\source\IntuneWinAppUtil.exe -c apps\powershell-7\package     -s Install.ps1 -o build\powershell-7
```

`-c` is the source folder, `-s` is the setup file (used for naming), `-o` is
the output directory. The tool packages every file in the source folder
into the `.intunewin` — `Install.ps1`, `Uninstall.ps1`, and the bundled
installer for the three system-context apps. `Detect.ps1` lives one level
up at `apps/<app>/Detect.ps1`, intentionally outside `package/` so it is
not bundled — upload it via the detection-rules UI in section 4 instead.

## 2. Program (install/uninstall commands)

Identical for all four apps:

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

Default return codes are correct (0 = success, 1 = failure). The wrappers use
the `$installSucceeded` flag pattern so cleanup failures do not mask the
install/uninstall result — see [ARCHITECTURE.md](../ARCHITECTURE.md).

## 3. Requirements

Same for all four apps:

| Field                       | Value             |
|-----------------------------|-------------------|
| Operating system architecture | x64             |
| Minimum operating system    | Windows 10 1809   |

No additional requirement rules needed.

## 4. Detection rules

For every app: **Rules format = Use a custom detection script**, upload the
app's `Detect.ps1`.

| App             | Detection script                  | What it checks                                                    |
|-----------------|-----------------------------------|--------------------------------------------------------------------|
| Claude Code     | `apps/claude-code/Detect.ps1`     | Marker file `C:\ProgramData\Hawkweave\ClaudeCodeIntune\Markers\ClaudeCode.tag` exists  |
| Git for Windows | `apps/git-for-windows/Detect.ps1` | `C:\Program Files\Git\cmd\git.exe` exists                          |
| VS Code         | `apps/vscode/Detect.ps1`          | `C:\Program Files\Microsoft VS Code\Code.exe` exists               |
| PowerShell 7    | `apps/powershell-7/Detect.ps1`    | `C:\Program Files\PowerShell\7\pwsh.exe` exists                    |

Other detection-rule options:

- **Run script as 32-bit process on 64-bit clients**: leave unchecked.
  None of the four detection scripts depend on bitness —
  `ProgramData` and `Program Files` aren't WOW64-redirected for the
  paths these scripts check.
- **Enforce script signature check and run script silently**: No.

Detection scripts always run in **SYSTEM** context regardless of the install
context. Claude Code installs to a per-user profile that SYSTEM cannot
resolve to a single canonical path, so `Install.ps1` writes a marker file
to a system-wide location on success and `Detect.ps1` checks that marker.
See [ARCHITECTURE.md](../ARCHITECTURE.md), "Detection via marker files".

## 5. Dependencies

None. All four apps are independent Win32 assignments — leave the
**Dependencies** tab empty on every app, including Claude Code. Claude
Code runs without Git, and users who want a companion install it from
Company Portal on demand.

## 6. Assignments

Single target group: **Developers** (Entra ID security group).

| App             | Assignment type                           |
|-----------------|-------------------------------------------|
| Claude Code     | Available for enrolled devices            |
| Git for Windows | Available for enrolled devices            |
| VS Code         | Available for enrolled devices            |
| PowerShell 7    | Available for enrolled devices            |

`Available` puts the app in Company Portal so users install on demand.
Switch to `Required` if you want the app to install automatically on group
membership; for a curated dev toolkit, `Available` is usually the right
default.

## 7. Validation and troubleshooting

Logs on the managed device:

| Source                        | Path                                                                                  |
|-------------------------------|----------------------------------------------------------------------------------------|
| IME                           | `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log` |
| Script execution (AgentExec)  | `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\AgentExecutor.log`            |
| User-context wrapper log (CMTrace)   | `%LOCALAPPDATA%\Hawkweave\ClaudeCodeIntune\Logs\<App>-<Action>.log`                                 |
| System-context wrapper log (CMTrace) | `%ProgramData%\Hawkweave\ClaudeCodeIntune\Logs\<App>-<Action>.log`                                  |

State signal (Claude Code):

- The detection marker `C:\ProgramData\Hawkweave\ClaudeCodeIntune\Markers\ClaudeCode.tag` is what
  `Detect.ps1` reads. If Claude Code is installed but Intune reports it as
  not detected, check whether the marker exists and inspect its contents
  (timestamp, user, version, install path written by `Install.ps1`).

Sync caveats:

- After uploading or reconfiguring an app, Company Portal can take 5–15
  minutes to reflect the change. Force a sync via **Settings > Accounts >
  Access work or school > Info > Sync**, or from Company Portal's Settings
  page.
- The IME caches detection results between cycles. If a fresh install
  reports "not detected" right after install, wait one IME cycle (~1 hour)
  or trigger a sync; rerunning the install does not always clear the cache.
- Detection scripts running as SYSTEM may surface different results than
  manual runs in a user shell. When debugging, run the script via
  `psexec -s -i powershell.exe` or the equivalent to reproduce SYSTEM
  context.
