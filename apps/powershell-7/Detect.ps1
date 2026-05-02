<#
.SYNOPSIS
    Detection script for PowerShell 7 (system-context Intune install).

.DESCRIPTION
    The PowerShell 7 MSI installs to a deterministic path:
        C:\Program Files\PowerShell\7\pwsh.exe

    Win32 detection runs in SYSTEM context, which has full access to
    C:\Program Files, so a Test-Path on the binary is sufficient.

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
