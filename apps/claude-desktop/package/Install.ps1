<#
.SYNOPSIS
    Install Claude Desktop via Add-AppxProvisionedPackage, optionally
    enable Virtual Machine Platform for Cowork, apply HKLM policies,
    and write the detection registry key. Single-file Win32 install
    entry point.

.DESCRIPTION
    The Claude Desktop MSIX contains a packaged service that fails
    with 0x80073D28 (ERROR_INSTALL_RESOURCEMANAGER_FAILED) when
    Intune tries to install it via the Line-of-business path
    (Add-AppxPackage). The only install path that works is
    Add-AppxProvisionedPackage with -SkipLicense -Regions 'all'.
    This script wraps that call plus the supporting work (VMP
    enable, policy writes, detection key) so the whole deployment
    can ship as one Win32 app.

    Logs in CMTrace format to:
        %ProgramData%\Hawkweave\ClaudeCodeIntune\Logs\ClaudeDesktop-Install.log
    (with %TEMP% fallback if the primary path is not writable; if
    even the fallback fails, logging silently degrades to console
    only - logging never blocks the install).

    Detection: writes
        HKLM:\SOFTWARE\Hawkweave\ClaudeCodeIntune\Apps\ClaudeDesktop
    with a Version REG_SZ set to "<msix-version>+<policies-hash-short>"
    (or just "<msix-version>" when -SkipPolicies is in effect).
    Intune's registry-based detection rule matches on this exact
    string, so a policies.json change automatically changes the
    detection version and triggers redeployment on the next sync.

    Exit codes:
        0    success.
        3010 success; reboot required to finalize VMP. Intune
             surfaces the prompt via "Device restart behavior".
        1    MSIX install failed, or detection registry write failed.
             Either is fatal - the device cannot be marked compliant.

.PARAMETER EnableCowork
    Enable the VirtualMachinePlatform Windows optional feature.
    Required for Claude Desktop's Cowork sandbox. May queue a soft
    reboot (the script returns 3010 in that case). Devices without
    SLAT or with CPU virtualization disabled in firmware soft-skip:
    Claude Desktop installs normally, the companion logs a Warning,
    Cowork is unavailable on that device. No install failure.

.PARAMETER SkipPolicies
    Skip the policy-write step and omit the policies hash from the
    detection key (so detection compares MSIX version only). Use
    when an external GPO or Intune Settings Catalog policy already
    manages the seven HKLM values under HKLM:\SOFTWARE\Policies\Claude.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$EnableCowork,
    [switch]$SkipPolicies
)

# Bitness self-check + sysnative re-launch. IME is a 32-bit process;
# without this re-launch, HKLM:\SOFTWARE access gets silently
# redirected to HKLM:\SOFTWARE\Wow6432Node, where Detect.ps1 (which
# runs 64-bit) cannot find anything Install.ps1 wrote.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $sysnative    = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath   = $MyInvocation.MyCommand.Path
    $relaunchArgs = @('-ExecutionPolicy','Bypass','-NoProfile','-WindowStyle','Hidden','-File',$scriptPath)
    if ($EnableCowork) { $relaunchArgs += '-EnableCowork' }
    if ($SkipPolicies) { $relaunchArgs += '-SkipPolicies' }
    & $sysnative @relaunchArgs
    exit $LASTEXITCODE
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Logging. Best-effort: never blocks the install.
# ---------------------------------------------------------------------------
$script:LogPath      = $null
$script:LogComponent = 'ClaudeDesktop-Install'

$primaryLogDir = Join-Path $env:ProgramData 'Hawkweave\ClaudeCodeIntune\Logs'
$primaryLog    = Join-Path $primaryLogDir 'ClaudeDesktop-Install.log'
try {
    if (-not (Test-Path -LiteralPath $primaryLogDir)) {
        New-Item -ItemType Directory -Path $primaryLogDir -Force -ErrorAction Stop | Out-Null
    }
    [System.IO.File]::AppendAllText($primaryLog, '', [System.Text.Encoding]::UTF8)
    $script:LogPath = $primaryLog
}
catch {
    try {
        $fallbackLog = Join-Path $env:TEMP 'ClaudeDesktop-Install.log'
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

Write-Log 'Starting Claude Desktop install.'
Write-Log ('  Time         : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
Write-Log ('  Computer     : {0}' -f $env:COMPUTERNAME)
Write-Log ('  User         : {0}' -f $whoamiOutput)
Write-Log ('  PowerShell   : {0}' -f $PSVersionTable.PSVersion)
Write-Log ('  PSScriptRoot : {0}' -f $PSScriptRoot)
Write-Log ('  EnableCowork : {0}' -f [bool]$EnableCowork)
Write-Log ('  SkipPolicies : {0}' -f [bool]$SkipPolicies)
Write-Log ('  Log path     : {0}' -f $script:LogPath)

# Outcome flags. Initialized up front so Set-StrictMode does not trip
# on later checks.
$rebootPending     = $false
$coworkUnavailable = $false

# ---------------------------------------------------------------------------
# 3. Resolve paths and verify the MSIX exists.
# ---------------------------------------------------------------------------
$msixPath     = Join-Path $PSScriptRoot 'Claude.msix'
$policiesPath = Join-Path $PSScriptRoot 'policies.json'

if (-not (Test-Path -LiteralPath $msixPath)) {
    Write-Log -Message ("MSIX not found at '{0}'. Cannot continue." -f $msixPath) -Severity 'Error'
    exit 1
}
Write-Log ("MSIX located: {0}" -f $msixPath)

if (-not (Test-Path -LiteralPath $policiesPath)) {
    if (-not $SkipPolicies) {
        Write-Log -Message ("policies.json not found at '{0}'. Forcing -SkipPolicies and continuing." -f $policiesPath) -Severity 'Warning'
        $SkipPolicies = $true
    } else {
        Write-Log ("policies.json not found at '{0}' (-SkipPolicies set, expected)." -f $policiesPath)
    }
}

# ---------------------------------------------------------------------------
# 4. VMP enablement (only if -EnableCowork). State check first - if
#    VMP is already enabled or pending, no work needed and the
#    hardware precheck would give a false-negative because Hyper-V
#    (now active) masks virt extensions from Win32_Processor.
#    Otherwise hardware precheck, then enable. Soft-skip on missing
#    hardware; never abort the install.
# ---------------------------------------------------------------------------
if ($EnableCowork) {
    Write-Log 'EnableCowork requested. Checking VMP state...'

    $vmp = $null
    try {
        $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop
    } catch {
        Write-Log -Message ("VMP state query failed: {0}. Skipping VMP step; continuing with install." -f $_.Exception.Message) -Severity 'Error'
    }

    $shouldEnable = $false
    if ($vmp) {
        switch ($vmp.State) {
            'Enabled' {
                Write-Log 'VMP already enabled. No change.'
            }
            'EnablePending' {
                Write-Log -Message 'VMP enable is pending reboot from a prior request.' -Severity 'Warning'
                $rebootPending = $true
            }
            'DisablePending' {
                Write-Log -Message 'VMP has a pending disable from a prior request; re-enabling cancels it.' -Severity 'Warning'
                $shouldEnable = $true
            }
            'Disabled' {
                Write-Log 'VMP currently disabled. Will enable after hardware precheck.'
                $shouldEnable = $true
            }
            default {
                Write-Log -Message ("VMP in unexpected state '{0}'. Skipping enable; continuing with install." -f $vmp.State) -Severity 'Warning'
            }
        }
    }

    # Hardware precheck only when we actually need to enable.
    # Skipping this when VMP is already enabled is important - once
    # a hypervisor is running, Win32_Processor reports masked virt
    # bits even on capable hardware, so an unconditional precheck
    # would false-negative on re-runs.
    if ($shouldEnable) {
        $cpu = $null
        try {
            $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop |
                   Select-Object -First 1
        } catch {
            Write-Log -Message ("VMP precheck: Win32_Processor query failed: {0}. Treating as no Cowork." -f $_.Exception.Message) -Severity 'Error'
            $coworkUnavailable = $true
            $shouldEnable = $false
        }

        if (-not $coworkUnavailable -and $cpu) {
            if (-not $cpu.SecondLevelAddressTranslationExtensions) {
                Write-Log -Message 'VMP precheck: CPU does not advertise SLAT (Second Level Address Translation). Cowork unavailable on this device. Continuing without VMP.' -Severity 'Warning'
                $coworkUnavailable = $true
                $shouldEnable = $false
            }
            elseif (-not $cpu.VirtualizationFirmwareEnabled) {
                Write-Log -Message 'VMP precheck: CPU virtualization is disabled in firmware (BIOS/UEFI). Cowork unavailable on this device until enabled in firmware. Continuing without VMP.' -Severity 'Warning'
                $coworkUnavailable = $true
                $shouldEnable = $false
            }
        }
    }

    if ($shouldEnable) {
        try {
            $result = Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart -ErrorAction Stop
            if ($result.RestartNeeded) {
                Write-Log -Message 'VMP enabled. Reboot required to finalize.' -Severity 'Warning'
                $rebootPending = $true
            } else {
                Write-Log 'VMP enabled. No reboot required.'
            }
        } catch {
            Write-Log -Message ("VMP enable failed: {0}. Continuing with install." -f $_.Exception.Message) -Severity 'Error'
        }
    }
} else {
    Write-Log 'EnableCowork not set; skipping VMP step.'
}

# ---------------------------------------------------------------------------
# 5. MSIX install. Load-bearing: failure is fatal because policies
#    and detection have nothing to govern without the app on disk.
#    Add-AppxProvisionedPackage is the only path that works for
#    Anthropic's MSIX (the packaged service requires machine-wide
#    provisioning; Add-AppxPackage fails with 0x80073D28).
# ---------------------------------------------------------------------------
Write-Log ("Installing MSIX via Add-AppxProvisionedPackage: {0}" -f $msixPath)
try {
    Add-AppxProvisionedPackage -Online -PackagePath $msixPath -SkipLicense -Regions 'all' -ErrorAction Stop | Out-Null
    Write-Log 'MSIX install: ok.'
} catch {
    Write-Log -Message ("MSIX install failed: {0}" -f $_.Exception.Message) -Severity 'Error'
    Write-Log -Message ("Stack: {0}" -f $_.ScriptStackTrace) -Severity 'Error'
    exit 1
}

# ---------------------------------------------------------------------------
# 6. Policy application. Non-fatal: per-write failures log Warning
#    and the install continues. Bad JSON or missing root key skips
#    the policy step entirely.
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

if (-not $SkipPolicies) {
    Write-Log ("Applying HKLM policies from {0}..." -f $policiesPath)

    $parsed = $null
    try {
        $rawJson = Get-Content -LiteralPath $policiesPath -Raw -ErrorAction Stop
        $parsed = $rawJson | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log -Message ("Failed to parse '{0}': {1}. Skipping policy step; install continues." -f $policiesPath, $_.Exception.Message) -Severity 'Warning'
        $parsed = $null
    }

    if ($parsed) {
        try {
            if (-not (Test-Path -LiteralPath $PolicyKey)) {
                New-Item -Path $PolicyKey -Force -ErrorAction Stop | Out-Null
                Write-Log ("Created policy root key: {0}" -f $PolicyKey)
            }
        } catch {
            Write-Log -Message ("Failed to create policy root key '{0}': {1} (script may not be running elevated). Skipping policy writes; install continues." -f $PolicyKey, $_.Exception.Message) -Severity 'Warning'
            $parsed = $null
        }
    }

    if ($parsed) {
        foreach ($prop in $parsed.PSObject.Properties) {
            $name = $prop.Name
            if ($AllowedPolicyNames -notcontains $name) {
                Write-Log -Message ("Skipping non-whitelisted key '{0}'." -f $name) -Severity 'Warning'
                continue
            }
            $value = $prop.Value

            # Strict integer typing. JSON whole numbers parse as Int64
            # in PS5.1; anything else (decimals as Double, strings,
            # booleans) is rejected. We control policies.json, so a
            # string-quoted "24" should surface as a hand-edit mistake,
            # not silently coerce.
            $intValue = $null
            if ($value -is [int] -or $value -is [long] -or $value -is [byte] -or $value -is [short]) {
                $intValue = [int]$value
            }
            if ($null -eq $intValue) {
                Write-Log -Message ("Skipping '{0}': value '{1}' is not an integer." -f $name, $value) -Severity 'Warning'
                continue
            }
            if ($name -eq 'autoUpdaterEnforcementHours' -and ($intValue -lt 1 -or $intValue -gt 72)) {
                Write-Log -Message ("Skipping 'autoUpdaterEnforcementHours': value {0} is outside the allowed range 1..72." -f $intValue) -Severity 'Warning'
                continue
            }

            try {
                Set-ItemProperty -Path $PolicyKey -Name $name -Value $intValue -Type DWord -ErrorAction Stop
                Write-Log ("Wrote {0} = {1}" -f $name, $intValue)
            } catch {
                Write-Log -Message ("Failed to write '{0}' = {1}: {2}. Continuing with remaining policies." -f $name, $intValue, $_.Exception.Message) -Severity 'Warning'
            }
        }
    }
} else {
    Write-Log 'Skipping policy application (-SkipPolicies set or policies.json missing).'
}

# ---------------------------------------------------------------------------
# 7. Detection registry key. Composes "<msix-version>+<policies-hash-short>"
#    (or just "<msix-version>" with -SkipPolicies). Failure is fatal -
#    Intune cannot detect this install without the key.
# ---------------------------------------------------------------------------
$msixVersion = 'unknown'
try {
    $installed = Get-AppxProvisionedPackage -Online -ErrorAction Stop |
                 Where-Object { $_.DisplayName -like 'Claude*' } |
                 Select-Object -First 1
    if ($installed) {
        $msixVersion = [string]$installed.Version
        Write-Log ("Installed MSIX version: {0}" -f $msixVersion)
    } else {
        Write-Log -Message "Could not locate the installed Claude package via Get-AppxProvisionedPackage. Detection version will be 'unknown'." -Severity 'Warning'
    }
} catch {
    Write-Log -Message ("Failed to query installed package version: {0}. Detection version will be 'unknown'." -f $_.Exception.Message) -Severity 'Warning'
}

$detectionVersion = $msixVersion
if (-not $SkipPolicies -and (Test-Path -LiteralPath $policiesPath)) {
    try {
        $hash = Get-FileHash -LiteralPath $policiesPath -Algorithm SHA256 -ErrorAction Stop
        $hashShort = $hash.Hash.ToLowerInvariant().Substring(0, 8)
        $detectionVersion = '{0}+{1}' -f $msixVersion, $hashShort
    } catch {
        Write-Log -Message ("Failed to hash policies.json: {0}. Detection version will not include the policies hash." -f $_.Exception.Message) -Severity 'Warning'
    }
}

$DetectionKey = 'HKLM:\SOFTWARE\Hawkweave\ClaudeCodeIntune\Apps\ClaudeDesktop'
Write-Log ("Writing detection key: {0}\Version = '{1}'" -f $DetectionKey, $detectionVersion)
try {
    if (-not (Test-Path -LiteralPath $DetectionKey)) {
        New-Item -Path $DetectionKey -Force -ErrorAction Stop | Out-Null
    }
    Set-ItemProperty -Path $DetectionKey -Name 'Version' -Value $detectionVersion -Type String -ErrorAction Stop
    Write-Log 'Detection key write: ok.'
} catch {
    Write-Log -Message ("Detection key write failed: {0}. Aborting; Intune cannot detect this install." -f $_.Exception.Message) -Severity 'Error'
    exit 1
}

# ---------------------------------------------------------------------------
# 8. Final exit.
# ---------------------------------------------------------------------------
if ($rebootPending) {
    Write-Log -Message 'Final exit: 3010 (reboot pending).' -Severity 'Warning'
    exit 3010
}
Write-Log 'Final exit: 0.'
exit 0
