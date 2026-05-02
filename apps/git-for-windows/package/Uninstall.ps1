<#
.SYNOPSIS
    Uninstalls Git for Windows by invoking the installed Inno Setup
    uninstaller.

.DESCRIPTION
    Direct-installer Win32 package. Inno Setup leaves an unins000.exe
    alongside the install. Runs silently with /VERYSILENT /NORESTART.
    If unins000.exe isn't there, Git is already absent - uninstall
    reports success so re-runs and clean machines both report green.

    Logs in CMTrace format to: %ProgramData%\Hawkweave\ClaudeCodeIntune\Logs\GitForWindows-uninstall.log

.NOTES
    Independent of Claude Code. Removing Git through Company Portal has
    no effect on Claude Code itself.
#>

[CmdletBinding()]
param()

$AppDisplayName = 'GitForWindows'
$Action         = 'uninstall'

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
    $uninstaller = 'C:\Program Files\Git\unins000.exe'

    if (-not (Test-Path -LiteralPath $uninstaller)) {
        # Already absent - desired state met. Bail out green so re-runs
        # and clean machines don't report failure.
        Write-Log ("Uninstaller not present at {0}; treating as already-uninstalled." -f $uninstaller)
        $installSucceeded = $true
    } else {
        $uninstallArgs = @('/VERYSILENT', '/NORESTART')
        Write-Log ("Running: {0} {1}" -f $uninstaller, ($uninstallArgs -join ' '))
        # Inno Setup unins000.exe is GUI-subsystem; & doesn't wait on it.
        # See GitForWindows\Install.ps1 for the full rationale.
        $proc = Start-Process -FilePath $uninstaller -ArgumentList $uninstallArgs `
                              -Wait -PassThru -NoNewWindow
        $exitCode = $proc.ExitCode
        Write-Log ("Uninstaller exit code: {0}" -f $exitCode)

        if ($exitCode -eq 0 -or $exitCode -eq 3010) {
            $installSucceeded = $true
        } else {
            throw "Uninstaller failed with exit code $exitCode"
        }
    }
}
catch {
    Write-Log ("{0} failed: {1}" -f $Action, $_.Exception.Message) 3
    Write-Log ("Stack: {0}" -f $_.ScriptStackTrace) 3
}

if ($installSucceeded) { exit 0 } else { exit 1 }
