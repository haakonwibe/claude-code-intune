<#
.SYNOPSIS
    Installs Visual Studio Code (System x64) via the bundled Inno Setup
    installer.

.DESCRIPTION
    Direct-installer Win32 package. The installer .exe is fetched into
    apps\vscode\package\ by source\Update-Installers.ps1 at packaging
    time and bundled into the .intunewin alongside this script.

    Logs in CMTrace format to: %ProgramData%\Hawkweave\ClaudeCodeIntune\Logs\VSCode-install.log
#>

[CmdletBinding()]
param()

$AppDisplayName = 'VSCode'
$Action         = 'install'

# Bitness self-check.
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
    # Locate the bundled installer next to this script.
    $candidates = Get-ChildItem -Path $PSScriptRoot -Filter 'VSCodeSetup-x64-*.exe' `
                                -File -ErrorAction SilentlyContinue |
                      Sort-Object Name -Descending
    if ($candidates.Count -eq 0) {
        throw "Bundled VS Code installer (VSCodeSetup-x64-*.exe) not found in $PSScriptRoot. Run .\source\Update-Installers.ps1 and rebuild the .intunewin."
    }
    $installer = $candidates[0]
    Write-Log ("Using installer: {0}" -f $installer.Name)

    # Inno Setup silent flags:
    #   /VERYSILENT          no UI
    #   /NORESTART           don't reboot; Intune handles restart policy
    #   /MERGETASKS=!runcode disables the "launch VS Code after install"
    #                        post-task; under SYSTEM context VS Code
    #                        would launch in session 0 with no GUI.
    $installArgs = @(
        '/VERYSILENT',
        '/NORESTART',
        '/MERGETASKS=!runcode'
    )
    Write-Log ("Running: {0} {1}" -f $installer.Name, ($installArgs -join ' '))
    # Inno Setup installers are GUI-subsystem .exe files. PowerShell's call
    # operator (&) does NOT wait on GUI-subsystem processes - it returns
    # immediately and $LASTEXITCODE is never set. Start-Process -Wait waits
    # regardless of subsystem and -PassThru gives a reliable .ExitCode.
    $proc = Start-Process -FilePath $installer.FullName -ArgumentList $installArgs `
                          -Wait -PassThru -NoNewWindow
    $exitCode = $proc.ExitCode
    Write-Log ("Installer exit code: {0}" -f $exitCode)

    if ($exitCode -eq 0 -or $exitCode -eq 3010) {
        $installSucceeded = $true
    } else {
        throw "Installer failed with exit code $exitCode"
    }
}
catch {
    Write-Log ("{0} failed: {1}" -f $Action, $_.Exception.Message) 3
    Write-Log ("Stack: {0}" -f $_.ScriptStackTrace) 3
}

if ($installSucceeded) { exit 0 } else { exit 1 }
