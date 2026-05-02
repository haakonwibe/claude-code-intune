<#
.SYNOPSIS
    Detection script for Git for Windows (system-context Intune install).

.DESCRIPTION
    Git for Windows (machine scope) installs to:
        C:\Program Files\Git\cmd\git.exe

    Win32 detection runs in SYSTEM context, which has full access to
    C:\Program Files, so a Test-Path on the binary is sufficient.

    Intune Win32 detection script semantics:
      exit 0 with STDOUT output  -> app detected
      exit 0 with no STDOUT      -> app not detected
      non-zero exit              -> detection error
#>

[CmdletBinding()]
param()

$candidate = 'C:\Program Files\Git\cmd\git.exe'

if (Test-Path $candidate) {
    Write-Output "Git for Windows detected at $candidate"
}
exit 0
