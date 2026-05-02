<#
.SYNOPSIS
    Installs Claude Code via Anthropic's native installer (hardened).

.DESCRIPTION
    Logs in CMTrace format to: %LOCALAPPDATA%\Hawkweave\ClaudeCodeIntune\Logs\ClaudeCode-Install.log
#>

[CmdletBinding()]
param()

# Bitness self-check
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $sysnative  = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath = $MyInvocation.MyCommand.Path
    & $sysnative -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File $scriptPath
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'

# Logging - CMTrace format, user context
$logDir  = Join-Path $env:LOCALAPPDATA 'Hawkweave\ClaudeCodeIntune\Logs'
$logFile = Join-Path $logDir 'ClaudeCode-Install.log'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$script:LogFile      = $logFile
$script:LogComponent = 'ClaudeCode-Install'

function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [int]$Type = 1)
    $line = '<![LOG[{0}]LOG]!><time="{1}+000" date="{2}" component="{3}" context="" type="{4}" thread="{5}" file="">' -f $Message, (Get-Date -Format 'HH:mm:ss.fff'), (Get-Date -Format 'MM-dd-yyyy'), $script:LogComponent, $Type, $PID
    [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n", [System.Text.Encoding]::UTF8)
}

Write-Log ("Starting Claude Code install for {0}" -f $env:USERNAME)
Write-Log ("USERPROFILE: {0}" -f $env:USERPROFILE)

$bootstrap = Join-Path $env:TEMP 'claude-install.ps1'
$installSucceeded = $false

function Add-ToUserPath {
<#
.SYNOPSIS
    Append a directory to HKCU\Environment\Path, preserving the
    REG_EXPAND_SZ / REG_SZ value kind and broadcasting WM_SETTINGCHANGE
    so new processes see the update.

.DESCRIPTION
    Hardened against the cases that can silently corrupt PATH:

      - Rejects unsupported registry value kinds (anything other than
        REG_SZ / REG_EXPAND_SZ). PATH should never be REG_DWORD etc.;
        if it is, refuse to touch it rather than overwriting.
      - Refuses to write a value longer than the safety limit
        (8000 chars). The hard registry limit on REG_SZ/REG_EXPAND_SZ
        is ~16K, but values past 8K start breaking cmd.exe, the System
        Properties UI, and assorted legacy tools. Better to leave the
        binary off PATH (caller treats this throw as non-fatal) than
        to push the user into that territory.
      - Validates $Directory: non-empty/non-whitespace, no embedded
        semicolon (which would split into multiple entries and corrupt
        the value).
      - Normalizes trailing backslash + case for the dedup check so
        'C:\foo' and 'C:\foo\' resolve as the same entry.
      - Strips empty/whitespace-only entries from the rewritten value
        (benign cleanup - empty PATH entries are bugs and break tools
        like Get-Command on PowerShell 5.1).

    The standard [Environment]::SetEnvironmentVariable API expands
    %USERPROFILE%-style entries on write and silently corrupts them,
    which is why this writes through Microsoft.Win32.Registry directly.

.OUTPUTS
    [bool] $true if PATH was updated, $false if $Directory was already
    present (after normalization).
#>
    param(
        [Parameter(Mandatory)] [string]$Directory
    )

    if ([string]::IsNullOrWhiteSpace($Directory)) {
        throw "Add-ToUserPath: Directory is null or whitespace."
    }
    if ($Directory.IndexOf(';') -ge 0) {
        throw "Add-ToUserPath: Directory '$Directory' contains ';' (the PATH separator)."
    }

    $regPath = 'HKCU:\Environment'
    $key = Get-Item -LiteralPath $regPath

    $hasPath = $key.Property -contains 'Path'
    if ($hasPath) {
        $rawValue  = $key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
        $valueKind = $key.GetValueKind('Path')
    } else {
        $rawValue  = ''
        # Default for a new HKCU PATH is REG_EXPAND_SZ so that entries
        # like %USERPROFILE%\... resolve correctly.
        $valueKind = [Microsoft.Win32.RegistryValueKind]::ExpandString
    }

    if ($valueKind -ne [Microsoft.Win32.RegistryValueKind]::String -and
        $valueKind -ne [Microsoft.Win32.RegistryValueKind]::ExpandString) {
        throw ("Add-ToUserPath: HKCU\Environment\Path has unexpected value kind '{0}' (expected REG_SZ or REG_EXPAND_SZ)." -f $valueKind)
    }
    if ($null -eq $rawValue) { $rawValue = '' }
    if ($rawValue -isnot [string]) {
        throw ("Add-ToUserPath: HKCU\Environment\Path value is not a string (got {0})." -f $rawValue.GetType().FullName)
    }

    # Force array semantics. Without @(), a single-element pipeline
    # collapses to a scalar and += does string concatenation.
    $entries = @(
        $rawValue -split ';' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )

    # Normalized comparison: trailing backslash stripped, case-insensitive.
    $normTarget = $Directory.TrimEnd('\').ToLowerInvariant()
    foreach ($e in $entries) {
        if ($e.TrimEnd('\').ToLowerInvariant() -eq $normTarget) {
            return $false
        }
    }

    $newEntries = $entries + $Directory
    $newValue   = $newEntries -join ';'

    # Safety cap. See .DESCRIPTION for rationale.
    $safetyLimit = 8000
    if ($newValue.Length -gt $safetyLimit) {
        throw ("Add-ToUserPath: refusing to update PATH - resulting length {0} chars exceeds safety limit {1}. Add '{2}' to PATH manually." -f $newValue.Length, $safetyLimit, $Directory)
    }

    [Microsoft.Win32.Registry]::SetValue(
        'HKEY_CURRENT_USER\Environment',
        'Path',
        $newValue,
        $valueKind
    )

    # Broadcast WM_SETTINGCHANGE so new processes see the change
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

try {
    Write-Log ("Downloading bootstrap script to {0}" -f $bootstrap)
    Invoke-WebRequest -Uri 'https://claude.ai/install.ps1' `
                      -OutFile $bootstrap `
                      -UseBasicParsing

    if (-not (Test-Path $bootstrap)) {
        throw "Bootstrap script not written to $bootstrap"
    }
    Write-Log ("Bootstrap script size: {0} bytes" -f (Get-Item $bootstrap).Length)

    Write-Log "Executing bootstrap..."
    # The bootstrap emits Unicode (warning sign, arrows, checkmarks) in
    # its output. PowerShell decodes child-process stdout through
    # [Console]::OutputEncoding, which defaults to the OEM codepage
    # (CP437/CP850) and mis-decodes the bootstrap's UTF-8 bytes into
    # mojibake before they ever reach Write-Log. Force UTF-8 so the
    # log file gets the right characters.
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    # Bootstrap output occasionally has blank lines for visual spacing;
    # CMTrace renders empty entries as noise, so strip them at the pipe
    # boundary. The Where-Object filter is what makes Write-Log's
    # non-empty Mandatory string parameter safe.
    & $bootstrap 2>&1 |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { Write-Log $_.ToString() }

    $claudePath = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (-not (Test-Path $claudePath)) {
        throw "Bootstrap completed without errors, but $claudePath was not found."
    }

    $version = & $claudePath --version 2>&1
    Write-Log ("Installed: {0}" -f $claudePath)
    Write-Log ("Version: {0}" -f $version)

    # Ensure claude.exe is on the user's PATH.
    # Anthropic's bootstrap detects PATH state but doesn't modify it on
    # Windows; it just prints instructions. For a managed deployment we
    # have to handle it ourselves.
    $claudeBinDir = Join-Path $env:USERPROFILE '.local\bin'
    try {
        if (Add-ToUserPath -Directory $claudeBinDir) {
            Write-Log ("Added {0} to user PATH" -f $claudeBinDir)
        } else {
            Write-Log ("{0} already in user PATH" -f $claudeBinDir)
        }
    }
    catch {
        # Treat PATH failure as non-fatal: the binary is installed and
        # callable via full path. Surface a warning, don't fail the install.
        Write-Log ("PATH update failed (non-fatal): {0}" -f $_.Exception.Message) 2
    }

    # Write the detection marker - see ARCHITECTURE.md "Detection via marker files".
    # By this point the binary exists and the version check passed, so the install
    # has fundamentally succeeded. A marker-write failure is a detection concern,
    # not an install concern, so it stays non-fatal.
    try {
        $markerDir  = 'C:\ProgramData\Hawkweave\ClaudeCodeIntune\Markers'
        $markerPath = Join-Path $markerDir 'ClaudeCode.tag'
        New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
        $markerContent = @"
Installed: $(Get-Date -Format o)
User: $env:USERDOMAIN\$env:USERNAME
Version: $version
Location: $claudePath
"@
        Set-Content -Path $markerPath -Value $markerContent -Force
        Write-Log ("Wrote detection marker: {0}" -f $markerPath)
    }
    catch {
        Write-Log ("Marker write failed (non-fatal, install succeeded): {0}" -f $_.Exception.Message) 2
    }

    $installSucceeded = $true
}
catch {
    Write-Log ("Install failed: {0}" -f $_.Exception.Message) 3
    Write-Log ("Stack: {0}" -f $_.ScriptStackTrace) 3
}

# Cleanup runs regardless, isolated from install exit code.
Remove-Item $bootstrap -Force -ErrorAction SilentlyContinue

if ($installSucceeded) { exit 0 } else { exit 1 }
