<#
.SYNOPSIS
    Uninstalls Claude Code by removing the binary and version state.

.DESCRIPTION
    Removes the items written by Anthropic's native installer:
      %USERPROFILE%\.local\bin\claude.exe
      %USERPROFILE%\.local\share\claude

    Does NOT remove %USERPROFILE%\.claude. That directory holds user
    settings, MCP server configs, and session history. A reinstall will
    pick those up unchanged, which is usually what users want.

    Also cleans the user's PATH entry for .local\bin if that directory
    is empty after uninstall (i.e., no other tools share the location).

    Logs in CMTrace format to: %LOCALAPPDATA%\Hawkweave\ClaudeCodeIntune\Logs\ClaudeCode-Uninstall.log
#>

[CmdletBinding()]
param()

if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $sysnative  = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath = $MyInvocation.MyCommand.Path
    & $sysnative -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File $scriptPath
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Continue'

# Logging - CMTrace format, user context
$logDir  = Join-Path $env:LOCALAPPDATA 'Hawkweave\ClaudeCodeIntune\Logs'
$logFile = Join-Path $logDir 'ClaudeCode-Uninstall.log'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$script:LogFile      = $logFile
$script:LogComponent = 'ClaudeCode-Uninstall'

function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [int]$Type = 1)
    $line = '<![LOG[{0}]LOG]!><time="{1}+000" date="{2}" component="{3}" context="" type="{4}" thread="{5}" file="">' -f $Message, (Get-Date -Format 'HH:mm:ss.fff'), (Get-Date -Format 'MM-dd-yyyy'), $script:LogComponent, $Type, $PID
    [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n", [System.Text.Encoding]::UTF8)
}

function Remove-FromUserPath {
<#
.SYNOPSIS
    Remove a directory from HKCU\Environment\Path. Mirror of
    Install.ps1's Add-ToUserPath: same value-kind preservation, same
    REG_EXPAND_SZ handling, same defensive validation.

.DESCRIPTION
    Hardened against:
      - Missing Path value (returns $false, nothing to do).
      - Unsupported value kinds (REG_DWORD etc.) - refuse to touch
        rather than overwriting.
      - Non-string raw value (defensive type check).
      - Trailing-backslash / case mismatch in PATH entries -
        normalized comparison so 'C:\foo' and 'C:\foo\' both match.

    Empty/whitespace-only entries already in PATH are dropped on
    rewrite (benign cleanup; empty entries break some tools). No
    length check on remove - we're only ever shrinking PATH.

    See Install.ps1's Add-ToUserPath for why this writes through
    Microsoft.Win32.Registry directly rather than
    [Environment]::SetEnvironmentVariable (which expands variables).

.OUTPUTS
    [bool] $true if PATH was modified, $false if $Directory was not
    present.
#>
    param(
        [Parameter(Mandatory)] [string]$Directory
    )

    if ([string]::IsNullOrWhiteSpace($Directory)) {
        throw "Remove-FromUserPath: Directory is null or whitespace."
    }

    $regPath = 'HKCU:\Environment'
    $key = Get-Item -LiteralPath $regPath

    if (-not ($key.Property -contains 'Path')) {
        return $false  # nothing to clean
    }

    $valueKind = $key.GetValueKind('Path')
    if ($valueKind -ne [Microsoft.Win32.RegistryValueKind]::String -and
        $valueKind -ne [Microsoft.Win32.RegistryValueKind]::ExpandString) {
        throw ("Remove-FromUserPath: HKCU\Environment\Path has unexpected value kind '{0}' (expected REG_SZ or REG_EXPAND_SZ)." -f $valueKind)
    }

    $rawValue = $key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    if ($null -eq $rawValue -or $rawValue -eq '') { return $false }
    if ($rawValue -isnot [string]) {
        throw ("Remove-FromUserPath: HKCU\Environment\Path value is not a string (got {0})." -f $rawValue.GetType().FullName)
    }

    $entries = @(
        $rawValue -split ';' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )

    # Normalized comparison: trailing backslash stripped, case-insensitive.
    $normTarget = $Directory.TrimEnd('\').ToLowerInvariant()
    $kept = @($entries | Where-Object { $_.TrimEnd('\').ToLowerInvariant() -ne $normTarget })
    if ($kept.Count -eq $entries.Count) {
        return $false  # not present
    }

    $newValue = $kept -join ';'

    [Microsoft.Win32.Registry]::SetValue(
        'HKEY_CURRENT_USER\Environment',
        'Path',
        $newValue,
        $valueKind
    )

    $signature = @'
[DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    if (-not ('Win32.NativeMethods' -as [type])) {
        Add-Type -MemberDefinition $signature -Name NativeMethods -Namespace Win32
    }
    $result = [UIntPtr]::Zero
    [Win32.NativeMethods]::SendMessageTimeout(
        [IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment',
        2, 5000, [ref]$result
    ) | Out-Null

    return $true
}

Write-Log ("Starting Claude Code uninstall for {0}" -f $env:USERNAME)

# Remove the detection marker first. Non-fatal: if marker removal fails,
# detection may keep reporting "installed" until the next install or
# uninstall, but it does not block the rest of uninstall.
$markerPath = 'C:\ProgramData\Hawkweave\ClaudeCodeIntune\Markers\ClaudeCode.tag'
if (Test-Path $markerPath) {
    try {
        Remove-Item $markerPath -Force -ErrorAction SilentlyContinue
        Write-Log ("Removed marker: {0}" -f $markerPath)
    } catch {
        Write-Log ("Failed to remove marker (non-fatal): {0}" -f $_.Exception.Message) 2
    }
}

$claudeBin    = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
$claudeShare  = Join-Path $env:USERPROFILE '.local\share\claude'
$localBinDir  = Join-Path $env:USERPROFILE '.local\bin'

# Remove the binary
if (Test-Path $claudeBin) {
    try {
        Remove-Item -Path $claudeBin -Force
        Write-Log ("Removed: {0}" -f $claudeBin)
    }
    catch {
        Write-Log ("Failed to remove {0}: {1}" -f $claudeBin, $_.Exception.Message) 2
    }
} else {
    Write-Log ("Not found (skipping): {0}" -f $claudeBin)
}

# Remove version state directory
if (Test-Path $claudeShare) {
    try {
        Remove-Item -Path $claudeShare -Recurse -Force
        Write-Log ("Removed: {0}" -f $claudeShare)
    }
    catch {
        Write-Log ("Failed to remove {0}: {1}" -f $claudeShare, $_.Exception.Message) 2
    }
} else {
    Write-Log ("Not found (skipping): {0}" -f $claudeShare)
}

# Clean PATH entry only if .local\bin is now empty
if (Test-Path $localBinDir) {
    $remaining = Get-ChildItem -Path $localBinDir -Force -ErrorAction SilentlyContinue
    if (-not $remaining) {
        try {
            if (Remove-FromUserPath -Directory $localBinDir) {
                Write-Log ("Removed PATH entry: {0}" -f $localBinDir)
            }
            Remove-Item -Path $localBinDir -Force
            Write-Log ("Removed empty directory: {0}" -f $localBinDir)
        }
        catch {
            Write-Log ("PATH cleanup failed: {0}" -f $_.Exception.Message) 2
        }
    } else {
        Write-Log ("Leaving PATH and {0} alone (other items present)." -f $localBinDir)
    }
}

Write-Log "Uninstall complete"
exit 0
