<#
.SYNOPSIS
    Detection script for PowerShell 7 (system-context Intune install).

.DESCRIPTION
    The PowerShell 7 MSI installs to a deterministic path:
        C:\Program Files\PowerShell\7\pwsh.exe

    Win32 detection runs in SYSTEM context, which has full access to
    C:\Program Files, so a Test-Path on the binary is sufficient.

    Note for context: an earlier version of this kit deployed PS7 via
    winget, which pulled the MSIX bundle and landed pwsh.exe under
    C:\Program Files\WindowsApps\Microsoft.PowerShell_<ver>_x64__... .
    The current direct-MSI install path is canonical and stable across
    7.x releases - no wildcard scan and no bitness self-elevation needed.

    Intune Win32 detection script semantics:
      exit 0 with STDOUT output  -> app detected
      exit 0 with no STDOUT      -> app not detected
      non-zero exit              -> detection error
#>

[CmdletBinding()]
param()

$candidate = 'C:\Program Files\PowerShell\7\pwsh.exe'

if (Test-Path $candidate) {
    Write-Output "PowerShell 7 detected at $candidate"
}
exit 0
