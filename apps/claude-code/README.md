# Claude Code

Anthropic's Claude Code CLI, deployed via the official native installer
(`irm https://claude.ai/install.ps1 | iex`). Anchor app for the kit; the
three companion apps (Git for Windows, VS Code, PowerShell 7) support its
workflows.

## Layout

```
claude-code/
├── README.md          # this file
├── Detect.ps1         # uploaded to Intune separately as the detection script
└── package/           # input to IntuneWinAppUtil.exe
    ├── Install.ps1
    └── Uninstall.ps1
```

`package/` is the source folder for `IntuneWinAppUtil.exe`. `Detect.ps1`
sits outside `package/` so it is not bundled into the `.intunewin` —
upload it to the Intune detection-rule UI separately as a custom detection
script.

## Intune configuration

| Field             | Value                                                                  |
|-------------------|------------------------------------------------------------------------|
| Install command   | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Install.ps1`  |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File Uninstall.ps1`|
| Install context   | **User**                                                               |
| Detection         | Custom script (upload `Detect.ps1`)                                    |

## Detection signal

`Install.ps1` writes `C:\ProgramData\Hawkweave\ClaudeCodeIntune\Markers\ClaudeCode.tag` once
the binary exists, the version check passes, and the PATH update completes.
`Uninstall.ps1` removes the marker first thing. `Detect.ps1` is a single
`Test-Path` against the marker.

This avoids enumerating `C:\Users\*` from a SYSTEM-context detection script
to find a per-user binary. See [ARCHITECTURE.md](../../ARCHITECTURE.md),
"Detection via marker files".

## Robust and polite

Both scripts try hard not to leave the user's environment in a worse
state than they found it:

- **PATH writes are defensive.** Add/remove validate the registry value
  kind, preserve REG_EXPAND_SZ so `%USERPROFILE%`-style entries don't
  get expanded and frozen, normalize trailing backslash + case for
  dedup, and refuse to push PATH past 8000 chars rather than risk
  breaking legacy tools.
- **Failures degrade gracefully.** A PATH or marker-write failure logs
  a Type 2 warning but does not fail the install — the binary is
  installed and callable by full path either way.
- **Uninstall keeps user state.** `%USERPROFILE%\.claude` (settings,
  MCP configs, session history) is never touched; a reinstall picks it
  up unchanged. The PATH entry is only removed if `.local\bin` is
  empty after the binary is gone, so unrelated tools sharing the
  directory keep their PATH entry.

## Dependencies

None. Claude Code runs without Git or any other companion. Leave the
Intune **Dependencies** tab empty; the three companion apps (Git for
Windows, VS Code, PowerShell 7) are independent assignments to the same
group. See [docs/intune-configuration.md](../../docs/intune-configuration.md).
