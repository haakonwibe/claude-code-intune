<#
.SYNOPSIS
    Installs PowerShell 7 (machine scope) via the bundled MSI.

.DESCRIPTION
    Direct-installer Win32 package. The .msi is fetched into
    apps\powershell-7\package\ by source\Update-Installers.ps1 at
    packaging time and bundled into the .intunewin alongside this
    script. winget is unsupported in SYSTEM context per Microsoft docs;
    see ARCHITECTURE.md ("Direct installer Win32 packages") for the
    pivot rationale.

    Property values match Microsoft's documented machine-managed install
    recipe:
      learn.microsoft.com/powershell/scripting/install/install-powershell-on-windows
      #install-the-msi-package-with-command-line-options

    The MSI lands pwsh.exe at the deterministic path
    C:\Program Files\PowerShell\7\pwsh.exe - no MSIX wildcard scan
    needed for detection.

    Logs in CMTrace format to: %ProgramData%\Hawkweave\ClaudeCodeIntune\Logs\PowerShell7-install.log
#>

[CmdletBinding()]
param()

$AppDisplayName = 'PowerShell7'
$Action         = 'install'

# Bitness self-check - see ARCHITECTURE.md, gotcha "32-bit IME execution".
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
    # Locate the bundled .msi next to this script.
    $candidates = Get-ChildItem -Path $PSScriptRoot -Filter 'PowerShell-*-win-x64.msi' `
                                -File -ErrorAction SilentlyContinue |
                      Sort-Object Name -Descending
    if ($candidates.Count -eq 0) {
        throw "Bundled PowerShell 7 MSI (PowerShell-*-win-x64.msi) not found in $PSScriptRoot. Run .\source\Update-Installers.ps1 and rebuild the .intunewin."
    }
    $msi = $candidates[0]
    Write-Log ("Using installer: {0}" -f $msi.Name)

    # Microsoft-documented machine-install recipe. ENABLE_PSREMOTING=0 is
    # the conservative default - admins enable WinRM via separate policy
    # if they need it. ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1 mirrors what
    # users get from the official docs flow.
    # Build the argument line as a single string with explicit quoting
    # around the MSI path. PowerShell 5.1's `Start-Process -ArgumentList
    # <array>` does NOT auto-quote individual elements that contain
    # spaces - it space-joins them. If $msi.FullName ever sits under a
    # path with a space, the array form would split it across multiple
    # tokens and msiexec would fail. A single-string -ArgumentList is
    # passed through verbatim, so we control the quoting ourselves.
    $argLine = '/i "{0}" /quiet /norestart ADD_PATH=1 ENABLE_PSREMOTING=0 REGISTER_MANIFEST=1 USE_MU=1 ENABLE_MU=1 ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1' -f $msi.FullName
    Write-Log ("Running: msiexec.exe {0}" -f $argLine)
    # Start-Process -Wait -PassThru for reliable exit-code capture on
    # GUI-subsystem executables (see ARCHITECTURE.md, finding 7).
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $argLine `
                          -Wait -PassThru -NoNewWindow
    $exitCode = $proc.ExitCode
    Write-Log ("msiexec exit code: {0}" -f $exitCode)

    # MSI: 0 success, 1641 success-reboot-initiated, 3010 success-reboot-required.
    if ($exitCode -in @(0, 1641, 3010)) {
        $installSucceeded = $true
    } else {
        throw "msiexec /i failed with exit code $exitCode"
    }
}
catch {
    Write-Log ("{0} failed: {1}" -f $Action, $_.Exception.Message) 3
    Write-Log ("Stack: {0}" -f $_.ScriptStackTrace) 3
}

if ($installSucceeded) { exit 0 } else { exit 1 }
