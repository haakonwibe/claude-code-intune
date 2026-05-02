<#
.SYNOPSIS
    Detection script for Claude Code (Intune Win32, user-context install).

.DESCRIPTION
    Win32 detection runs in SYSTEM context, but Claude Code installs
    into a per-user profile. Instead of walking C:\Users\* and trying
    to figure out which profile is real, Install.ps1 writes a marker
    file to a system-wide path on success and Uninstall.ps1 removes
    it. Detection is then a single Test-Path.

    Intune Win32 detection script semantics:
      exit 0 with STDOUT output  -> app detected
      exit 0 with no STDOUT      -> app not detected
      non-zero exit              -> detection error
#>

[CmdletBinding()]
param()

$markerPath = 'C:\ProgramData\Hawkweave\ClaudeCodeIntune\Markers\ClaudeCode.tag'

if (Test-Path $markerPath) {
    Write-Output "Claude Code detected (marker: $markerPath)"
    exit 0
}
exit 0
