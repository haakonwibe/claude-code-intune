<#
.SYNOPSIS
    Uninstalls PowerShell 7 (machine scope) by discovering the installed
    ProductCode in the uninstall registry and invoking msiexec /x.

.DESCRIPTION
    Direct-installer Win32 package; see ARCHITECTURE.md ("Direct
    installer Win32 packages") for the pivot from winget.

    PowerShell 7's MSI changes ProductCode every release, so resolving
    the ProductCode from the bundled .msi at uninstall time is fragile:
    if the admin re-ran source\Update-Installers.ps1 and rebuilt the
    .intunewin between an install and a later uninstall on the same
    device, the bundled .msi's ProductCode no longer matches what's on
    disk and msiexec returns 1605 (ERROR_UNKNOWN_PRODUCT). Discovering
    the installed ProductCode from
    HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall sidesteps
    that - the registry key name IS the ProductCode for MSI-installed
    products.

    If no installed PS7 is found, success is reported (re-runs and clean
    machines both report green).

    Logs in CMTrace format to: %ProgramData%\Hawkweave\ClaudeCodeIntune\Logs\PowerShell7-uninstall.log
#>

[CmdletBinding()]
param()

$AppDisplayName = 'PowerShell7'
$Action         = 'uninstall'

# Bitness self-check - see ARCHITECTURE.md, gotcha "32-bit IME execution".
# Also necessary for reading the 64-bit Uninstall hive without WOW6432
# redirection.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $sysnative  = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath = $MyInvocation.MyCommand.Path
    & $sysnative -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File $scriptPath
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'

$logDir  = Join-Path $env:ProgramData 'Hawkweave\ClaudeCodeIntune\Logs'
$logFile = Join-Path $logDir ("{0}-{1}.log" -f $AppDisplayName, $Action)
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$script:LogFile      = $logFile
$script:LogComponent = "{0}-{1}" -f $AppDisplayName, $Action

function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [int]$Type = 1)
    $line = '<![LOG[{0}]LOG]!><time="{1}+000" date="{2}" component="{3}" context="" type="{4}" thread="{5}" file="">' -f $Message, (Get-Date -Format 'HH:mm:ss.fff'), (Get-Date -Format 'MM-dd-yyyy'), $script:LogComponent, $Type, $PID
    [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n", [System.Text.Encoding]::UTF8)
}

Write-Log ("Starting {0} for {1} as {2}" -f $Action, $AppDisplayName, $env:USERNAME)

$installSucceeded = $false

try {
    $uninstallRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'

    # Walk the uninstall hive and pick any product whose DisplayName
    # matches PowerShell 7 (x64). DisplayName has been 'PowerShell 7-x64'
    # since 7.5 and 'PowerShell 7.4-x64' on 7.4.x - the wildcard absorbs
    # both. Subkey name is the ProductCode for MSI-installed products
    # (validated by the GUID-shape regex).
    $product = $null
    $keys = Get-ChildItem -Path $uninstallRoot -ErrorAction SilentlyContinue
    foreach ($key in $keys) {
        $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $props) { continue }
        if ($props.DisplayName -like 'PowerShell 7*-x64*' -and
            $key.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
            $product = [pscustomobject]@{
                ProductCode    = $key.PSChildName
                DisplayName    = $props.DisplayName
                DisplayVersion = $props.DisplayVersion
            }
            break
        }
    }

    if ($null -eq $product) {
        Write-Log "No installed PowerShell 7 (x64) found in uninstall registry; treating as already-uninstalled."
        $installSucceeded = $true
    } else {
        Write-Log ("Found installed product: {0} {1} ({2})" -f $product.DisplayName, $product.DisplayVersion, $product.ProductCode)
        $uninstallArgs = @('/x', $product.ProductCode, '/quiet', '/norestart')
        Write-Log ("Running: msiexec.exe {0}" -f ($uninstallArgs -join ' '))
        # Match the launch pattern in Install.ps1 - Start-Process -Wait
        # -PassThru for reliable exit-code capture across all installer
        # subsystems.
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $uninstallArgs `
                              -Wait -PassThru -NoNewWindow
        $exitCode = $proc.ExitCode
        Write-Log ("msiexec exit code: {0}" -f $exitCode)

        # MSI codes:
        #   0    success
        #   1605 unknown product (race: another process uninstalled mid-flight)
        #   1614 already uninstalled
        #   1641 success-reboot-initiated
        #   3010 success-reboot-required
        if ($exitCode -in @(0, 1605, 1614, 1641, 3010)) {
            $installSucceeded = $true
        } else {
            throw "msiexec /x failed with exit code $exitCode"
        }
    }
}
catch {
    Write-Log ("{0} failed: {1}" -f $Action, $_.Exception.Message) 3
    Write-Log ("Stack: {0}" -f $_.ScriptStackTrace) 3
}

if ($installSucceeded) { exit 0 } else { exit 1 }
