# Claude Code

Anthropic's Claude Code CLI, deployed through the official native
installer (`irm https://claude.ai/install.ps1 | iex`). The main app of
the kit. The three other apps (Git for Windows, VS Code, PowerShell 7)
help with the workflows.

## Layout

```
claude-code/
├── README.md          # this file
├── Detect.ps1         # uploaded to Intune on its own as the detection script
└── package/           # input to IntuneWinAppUtil.exe
    ├── Install.ps1
    └── Uninstall.ps1
```

`package/` is the source folder for `IntuneWinAppUtil.exe`.
`Detect.ps1` sits outside `package/` so it is not bundled into the
`.intunewin`. Upload it to the Intune detection-rule UI on its own as
a custom detection script.

## Intune configuration

| Field             | Value                                                                  |
|-------------------|------------------------------------------------------------------------|
| Install command   | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Install.ps1`  |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Uninstall.ps1`|
| Install context   | **User**                                                               |
| Detection         | Custom script (upload `Detect.ps1`)                                    |

## Detection signal

`Install.ps1` writes
`C:\ProgramData\Hawkweave\ClaudeCodeIntune\Markers\ClaudeCode.tag`
once the binary is in place, the version check passes, and the PATH
update is done. `Uninstall.ps1` removes the marker first.
`Detect.ps1` is a single `Test-Path` against the marker.

This way the SYSTEM-context detection script does not have to walk
`C:\Users\*` to find a per-user binary.

## Careful with the user's setup

Both scripts try not to leave the user's setup worse than they found
it:

- **PATH writes are careful.** Add and remove check the registry
  value kind, keep REG_EXPAND_SZ so `%USERPROFILE%`-style entries
  are not expanded and frozen, normalize trailing backslash and case
  for the duplicate check, and refuse to push PATH past 8000 chars
  to avoid breaking older tools.
- **Failures do not stop the install.** If a PATH update or marker
  write fails, the script writes a Type 2 warning but still reports
  install success. The binary is installed and runs from its full
  path in either case.
- **Uninstall keeps user state.** `%USERPROFILE%\.claude` (settings,
  MCP configs, session history) is never touched. A reinstall picks
  it up as-is. The PATH entry is only removed if `.local\bin` is
  empty after the binary is gone, so other tools sharing that folder
  keep their PATH entry.

## Dependencies

None. Claude Code runs without Git or any of the other apps in the
kit. Leave the Intune **Dependencies** tab empty. The three other
apps (Git for Windows, VS Code, PowerShell 7) are independent
assignments to the same group. See
[docs/intune-configuration.md](../../docs/intune-configuration.md).
