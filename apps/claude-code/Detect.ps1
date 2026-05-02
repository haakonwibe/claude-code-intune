<#
.SYNOPSIS
    Detection script for Claude Code (Intune Win32, user-context install).

.DESCRIPTION
    Win32 detection runs in SYSTEM context, but Claude Code installs into
    a per-user profile. Rather than enumerate C:\Users\* and reason about
    redirected, temporary, or system profile types, Install.ps1 writes a
    marker file to a deterministic system-wide path on success and
    Uninstall.ps1 removes it. Detection is then a single Test-Path.

    See ARCHITECTURE.md, "Detection via marker files", for the rationale.

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
