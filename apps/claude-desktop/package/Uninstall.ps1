<#
.SYNOPSIS
    Uninstall Claude Desktop: remove the provisioned MSIX package,
    clean up HKLM policy values and the detection registry key,
    optionally disable Virtual Machine Platform. Single-file Win32
    uninstall entry point.

.DESCRIPTION
    Mirror of apps\claude-desktop\package\Install.ps1's structure:
    same logging conventions, same Write-Log function, same exit-code
    contract. Uninstall is best-effort - $ErrorActionPreference is
    'Continue' (not 'Stop') so individual cleanup steps run to
    completion even if one fails. Per-step try/catch handles
    individual errors.

    Logs in CMTrace format to:
        %ProgramData%\Hawkweave\ClaudeCodeIntune\Logs\ClaudeDesktop-Uninstall.log
    (with %TEMP% fallback if the primary path is not writable; if
    even the fallback fails, logging silently degrades to console
    only - logging never blocks the uninstall).

    Cleanup ordering:
      1. MSIX removal: Remove-AppxProvisionedPackage (drops the
         provisioning entry so future logons do not auto-install)
         followed by Remove-AppxPackage -AllUsers (removes any
         per-user installs that already happened). Both are needed -
         provisioning removal alone leaves existing users with the
         app on their Start menu and able to launch it.
      2. HKLM:\SOFTWARE\Policies\Claude values removed; parent key
         dropped only if no other values or subkeys remain.
      3. HKLM:\SOFTWARE\Hawkweave\ClaudeCodeIntune\Apps\ClaudeDesktop
         removed entirely (the detection key Install.ps1 writes).
      4. Optionally disable VirtualMachinePlatform if -RemoveVMP set.

    Exit codes:
        0    success.
        3010 success; reboot required (only when -RemoveVMP queued
             a VMP disable that needs a reboot to finalize).
        1    a critical step failed. Currently only MSIX removal
             flips this; subsequent cleanup steps log and continue
             without affecting the exit code. 3010 takes precedence
             over 1 (matches Install.ps1).

.PARAMETER RemoveVMP
    Disable the VirtualMachinePlatform Windows feature on uninstall.
    Off by default - VMP is shared with WSL2, Windows Sandbox, Docker
    Desktop, and Hyper-V containers. Toggling it off triggers a
    reboot and may break unrelated workloads. Set this only when you
    are sure no other software on the device relies on VMP.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$RemoveVMP
)

# Bitness self-check + sysnative re-launch. IME is a 32-bit process;
# without this re-launch, HKLM:\SOFTWARE access gets silently
# redirected to HKLM:\SOFTWARE\Wow6432Node, where Detect.ps1 (which
# runs 64-bit) cannot find anything Install.ps1 wrote.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $sysnative    = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath   = $MyInvocation.MyCommand.Path
    $relaunchArgs = @('-ExecutionPolicy','Bypass','-NoProfile','-WindowStyle','Hidden','-File',$scriptPath)
    if ($RemoveVMP) { $relaunchArgs += '-RemoveVMP' }
    & $sysnative @relaunchArgs
    exit $LASTEXITCODE
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# 1. Logging. Best-effort: never blocks the uninstall.
# ---------------------------------------------------------------------------
$script:LogPath      = $null
$script:LogComponent = 'ClaudeDesktop-Uninstall'

$primaryLogDir = Join-Path $env:ProgramData 'Hawkweave\ClaudeCodeIntune\Logs'
$primaryLog    = Join-Path $primaryLogDir 'ClaudeDesktop-Uninstall.log'
try {
    if (-not (Test-Path -LiteralPath $primaryLogDir)) {
        New-Item -ItemType Directory -Path $primaryLogDir -Force -ErrorAction Stop | Out-Null
    }
    [System.IO.File]::AppendAllText($primaryLog, '', [System.Text.Encoding]::UTF8)
    $script:LogPath = $primaryLog
}
catch {
    try {
        $fallbackLog = Join-Path $env:TEMP 'ClaudeDesktop-Uninstall.log'
        [System.IO.File]::AppendAllText($fallbackLog, '', [System.Text.Encoding]::UTF8)
        $script:LogPath = $fallbackLog
    }
    catch {
        $script:LogPath = $null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Info','Warning','Error')] [string]$Severity = 'Info'
    )
    $type = switch ($Severity) { 'Info' { 1 } 'Warning' { 2 } 'Error' { 3 } }
    $line = '<![LOG[{0}]LOG]!><time="{1}+000" date="{2}" component="{3}" context="" type="{4}" thread="{5}" file="">' -f `
        $Message, (Get-Date -Format 'HH:mm:ss.fff'), (Get-Date -Format 'MM-dd-yyyy'), $script:LogComponent, $type, $PID
    if ($script:LogPath) { try { [System.IO.File]::AppendAllText($script:LogPath, ($line + "`r`n"), [System.Text.Encoding]::UTF8) } catch {} }
    $color = switch ($Severity) { 'Info' { 'White' } 'Warning' { 'Yellow' } 'Error' { 'Red' } }
    Write-Host $Message -ForegroundColor $color
}

# ---------------------------------------------------------------------------
# 2. Start banner.
# ---------------------------------------------------------------------------
$whoamiOutput = ''
try { $whoamiOutput = (& whoami 2>$null) } catch {}
if ([string]::IsNullOrWhiteSpace($whoamiOutput)) {
    $whoamiOutput = ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
}

Write-Log 'Starting Claude Desktop uninstall.'
Write-Log ('  Time         : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
Write-Log ('  Computer     : {0}' -f $env:COMPUTERNAME)
Write-Log ('  User         : {0}' -f $whoamiOutput)
Write-Log ('  PowerShell   : {0}' -f $PSVersionTable.PSVersion)
Write-Log ('  PSScriptRoot : {0}' -f $PSScriptRoot)
Write-Log ('  RemoveVMP    : {0}' -f [bool]$RemoveVMP)
Write-Log ('  Log path     : {0}' -f $script:LogPath)

# ---------------------------------------------------------------------------
# 3. Outcome flags. Initialized up front so Set-StrictMode does not
#    trip on the final exit checks.
# ---------------------------------------------------------------------------
$hardFailure   = $false
$rebootPending = $false

# ---------------------------------------------------------------------------
# 4. MSIX removal. Failure here flips $hardFailure but cleanup
#    continues - we still want to reset registry state even if the
#    package itself can't be removed (already removed out-of-band,
#    or a transient DISM error).
# ---------------------------------------------------------------------------
Write-Log 'Locating provisioned Claude packages...'
try {
    $packages = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop |
                  Where-Object { $_.DisplayName -like 'Claude*' })

    if ($packages.Count -eq 0) {
        Write-Log 'No provisioned Claude packages found; may already be uninstalled. Continuing with cleanup.'
    }
    foreach ($pkg in $packages) {
        Write-Log ("Removing provisioned package: {0} ({1})" -f $pkg.DisplayName, $pkg.PackageName)
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
            Write-Log ("Removed: {0}" -f $pkg.DisplayName)
        } catch {
            Write-Log -Message ("Failed to remove '{0}': {1}" -f $pkg.PackageName, $_.Exception.Message) -Severity 'Error'
            $hardFailure = $true
        }
    }
} catch {
    Write-Log -Message ("Failed to enumerate provisioned packages: {0}" -f $_.Exception.Message) -Severity 'Error'
    $hardFailure = $true
}

# Per-user package removal. Remove-AppxProvisionedPackage above
# removes the provisioning entry but does NOT touch packages that
# already installed for users who logged in while the package was
# provisioned - their Start-menu entries and launch capability
# persist. Enumerate -AllUsers and remove explicitly.
Write-Log 'Locating per-user Claude packages...'
try {
    $userPackages = @(Get-AppxPackage -AllUsers -Name 'Claude*' -ErrorAction Stop)
    if ($userPackages.Count -eq 0) {
        Write-Log 'No per-user Claude packages found.'
    }
    foreach ($pkg in $userPackages) {
        Write-Log ("Removing per-user package: {0} ({1})" -f $pkg.Name, $pkg.PackageFullName)
        try {
            Remove-AppxPackage -AllUsers -Package $pkg.PackageFullName -ErrorAction Stop
            Write-Log ("Removed per-user: {0}" -f $pkg.Name)
        } catch {
            Write-Log -Message ("Failed to remove per-user '{0}': {1}" -f $pkg.PackageFullName, $_.Exception.Message) -Severity 'Error'
            $hardFailure = $true
        }
    }
} catch {
    Write-Log -Message ("Failed to enumerate per-user packages: {0}" -f $_.Exception.Message) -Severity 'Error'
    $hardFailure = $true
}

# ---------------------------------------------------------------------------
# 5. Policy registry cleanup. Per-value Remove-ItemProperty with
#    -ErrorAction SilentlyContinue: absence is not a failure (a value
#    may not exist if Install partially failed). After the seven
#    removes, drop the parent key only if no remaining values AND no
#    subkeys.
# ---------------------------------------------------------------------------
$AllowedPolicyNames = @(
    'disableAutoUpdates',
    'autoUpdaterEnforcementHours',
    'isClaudeCodeForDesktopEnabled',
    'isDesktopExtensionEnabled',
    'isDesktopExtensionDirectoryEnabled',
    'isLocalDevMcpEnabled',
    'secureVmFeaturesEnabled'
)
$PolicyKey = 'HKLM:\SOFTWARE\Policies\Claude'

if (Test-Path -LiteralPath $PolicyKey) {
    Write-Log ("Cleaning up policy values under {0}..." -f $PolicyKey)
    foreach ($name in $AllowedPolicyNames) {
        Remove-ItemProperty -LiteralPath $PolicyKey -Name $name -ErrorAction SilentlyContinue
    }
    Write-Log ("Attempted removal of {0} whitelisted values." -f $AllowedPolicyNames.Count)

    try {
        $key = Get-Item -LiteralPath $PolicyKey -ErrorAction Stop
        $remainingValueCount = @($key.Property).Count
        $subkeys = @(Get-ChildItem -LiteralPath $PolicyKey -ErrorAction SilentlyContinue)

        if ($remainingValueCount -eq 0 -and $subkeys.Count -eq 0) {
            Remove-Item -LiteralPath $PolicyKey -Force -ErrorAction Stop
            Write-Log ("Removed empty policy root key: {0}" -f $PolicyKey)
        } else {
            Write-Log ("Leaving non-empty {0} key intact: contains {1} other value(s) and {2} subkey(s) not owned by this installer." -f $PolicyKey, $remainingValueCount, $subkeys.Count)
        }
    } catch {
        Write-Log -Message ("Post-cleanup key check failed: {0}. Continuing with uninstall." -f $_.Exception.Message) -Severity 'Warning'
    }
} else {
    Write-Log ("Policy root key '{0}' not present; nothing to clean up." -f $PolicyKey)
}

# ---------------------------------------------------------------------------
# 6. Detection registry key cleanup. Removes the entire ClaudeDesktop
#    subkey written by Install.ps1's step 7. Without the key,
#    Detect.ps1 returns "not detected" on the next sync.
# ---------------------------------------------------------------------------
$DetectionKey = 'HKLM:\SOFTWARE\Hawkweave\ClaudeCodeIntune\Apps\ClaudeDesktop'
if (Test-Path -LiteralPath $DetectionKey) {
    try {
        Remove-Item -LiteralPath $DetectionKey -Recurse -Force -ErrorAction Stop
        Write-Log ("Removed detection key: {0}" -f $DetectionKey)
    } catch {
        Write-Log -Message ("Failed to remove detection key '{0}': {1}. Continuing; Intune may keep reporting installed until next sync." -f $DetectionKey, $_.Exception.Message) -Severity 'Warning'
    }
} else {
    Write-Log ("Detection key '{0}' not present; nothing to clean up." -f $DetectionKey)
}

# ---------------------------------------------------------------------------
# 7. VMP removal (only if -RemoveVMP). Soft-skip if not set.
# ---------------------------------------------------------------------------
if ($RemoveVMP) {
    Write-Log -Message 'Disabling VMP. This is shared with WSL2, Windows Sandbox, Docker Desktop, and Hyper-V containers. Other features depending on VMP will stop working.' -Severity 'Warning'

    $shouldDisable = $false
    try {
        $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop
        switch ($vmp.State) {
            'Disabled' {
                Write-Log 'VMP already disabled. No change.'
            }
            'DisablePending' {
                Write-Log -Message 'VMP disable is pending reboot from a prior request.' -Severity 'Warning'
                $rebootPending = $true
            }
            'EnablePending' {
                Write-Log -Message 'VMP has a pending enable from a prior request; disabling cancels it.' -Severity 'Warning'
                $shouldDisable = $true
            }
            'Enabled' {
                Write-Log 'VMP currently enabled. Disabling.'
                $shouldDisable = $true
            }
            default {
                Write-Log -Message ("VMP in unexpected state '{0}'. Skipping disable; continuing with uninstall." -f $vmp.State) -Severity 'Warning'
            }
        }
    } catch {
        Write-Log -Message ("VMP state query failed: {0}. Continuing with uninstall." -f $_.Exception.Message) -Severity 'Error'
    }

    if ($shouldDisable) {
        try {
            $result = Disable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -ErrorAction Stop
            if ($result.RestartNeeded) {
                Write-Log -Message 'VMP disabled. Reboot required to finalize.' -Severity 'Warning'
                $rebootPending = $true
            } else {
                Write-Log 'VMP disabled. No reboot required.'
            }
        } catch {
            Write-Log -Message ("VMP disable failed: {0}. Continuing with uninstall." -f $_.Exception.Message) -Severity 'Error'
        }
    }
} else {
    Write-Log 'RemoveVMP not set; leaving VMP intact.'
}

# ---------------------------------------------------------------------------
# 8. Final exit. 3010 > 1 > 0 precedence (matches Install.ps1).
# ---------------------------------------------------------------------------
if ($rebootPending) {
    Write-Log -Message 'Final exit: 3010 (reboot pending).' -Severity 'Warning'
    exit 3010
}
if ($hardFailure) {
    Write-Log -Message 'Final exit: 1 (a critical step failed; see log above).' -Severity 'Warning'
    exit 1
}
Write-Log 'Final exit: 0.'
exit 0
