<#
.SYNOPSIS
    Detection script for Claude Desktop. Reports the deployed version
    to Intune by reading the detection registry key Install.ps1 wrote.

.DESCRIPTION
    Intune Win32 script-based detection contract:
        any output to stdout, exit 0 -> detected
        no output to stdout, exit 0  -> not detected
        non-zero exit                -> detection error (retry loop)

    All paths exit 0; stdout presence is the signal. Diagnostics go
    to stderr via Write-Error.

    Detection trusts what Install.ps1 wrote. When the .intunewin is
    rebuilt with a new MSIX or a changed policies.json, Install.ps1
    computes a new version string and writes it to the registry; the
    registry value differs from the prior deployment's value, and
    Intune treats the app as "needs update" because the detection
    output changes. The hash/version composition lives in
    Install.ps1, not here.
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest

$key = 'HKLM:\SOFTWARE\Hawkweave\ClaudeCodeIntune\Apps\ClaudeDesktop'

try {
    $version = (Get-ItemProperty -LiteralPath $key -Name 'Version' -ErrorAction Stop).Version
    if ($version) {
        Write-Output ("ClaudeDesktop {0}" -f $version)
    }
}
catch [System.Management.Automation.ItemNotFoundException], [System.Management.Automation.PSArgumentException] {
    # Key or value missing - expected pre-install or post-uninstall
    # state. Silent: empty stdout signals "not detected" to Intune.
}
catch {
    Write-Error ("Detect.ps1: unexpected error reading '{0}\Version': {1}" -f $key, $_.Exception.Message)
}

exit 0
