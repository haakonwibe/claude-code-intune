<#
.SYNOPSIS
    Detection script for Visual Studio Code (system-context Intune install).

.DESCRIPTION
    The system-scope VS Code installer places Code.exe at:
        C:\Program Files\Microsoft VS Code\Code.exe

    Win32 detection runs in SYSTEM context, which has full access to
    C:\Program Files, so a Test-Path on the binary is sufficient.

    Intune Win32 detection script semantics:
      exit 0 with STDOUT output  -> app detected
      exit 0 with no STDOUT      -> app not detected
      non-zero exit              -> detection error

.NOTES
    User-scope installs (under %LOCALAPPDATA%\Programs\Microsoft VS Code)
    are intentionally NOT counted here. This Win32 app deploys the system
    variant; a per-user copy installed by hand is a separate concern and
    Intune should reinstall the managed version alongside it.
#>

[CmdletBinding()]
param()

$candidate = 'C:\Program Files\Microsoft VS Code\Code.exe'

if (Test-Path $candidate) {
    Write-Output "VS Code (system) detected at $candidate"
}
exit 0
