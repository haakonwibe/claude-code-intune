#Requires -Version 5.1
<#
.SYNOPSIS
    Build .intunewin packages for all four apps in one shot.

.DESCRIPTION
    Runs source\IntuneWinAppUtil.exe against apps\<app>\package for each
    of the four apps and writes the result to build\<app>. Equivalent to
    typing the four per-app commands from docs\intune-configuration.md
    section 1 by hand, in sequence.

    Per app:
      - Any prior .intunewin in build\<app>\ is removed first, so
        IntuneWinAppUtil never has to prompt for an overwrite.
      - IntuneWinAppUtil runs with -q (quiet mode) and its stdout/stderr
        are captured to temp files, so the per-file copy chatter doesn't
        flood the console. On non-zero exit the captured output is
        replayed for diagnosis.
      - The script fails fast at the first non-zero exit so the bad
        app's output is the last thing on screen.

    If source\IntuneWinAppUtil.exe is missing, run
    .\source\Update-Tooling.ps1 first to download and verify it.

.EXAMPLE
    .\source\Build-AllPackages.ps1

.NOTES
    Project : claude-code-intune
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$tool     = Join-Path -Path $repoRoot -ChildPath 'source\IntuneWinAppUtil.exe'
if (-not (Test-Path -LiteralPath $tool)) {
    throw "IntuneWinAppUtil.exe not found at '$tool'. Run .\source\Update-Tooling.ps1 first."
}

$apps = @('claude-code','git-for-windows','vscode','powershell-7')
foreach ($app in $apps) {
    $source = Join-Path -Path $repoRoot -ChildPath "apps\$app\package"
    $out    = Join-Path -Path $repoRoot -ChildPath "build\$app"

    if (Test-Path -LiteralPath $out) {
        # Clear any prior .intunewin so IntuneWinAppUtil does not prompt
        # to overwrite. Leaves any sibling files alone.
        Get-ChildItem -LiteralPath $out -File -Filter '*.intunewin' -ErrorAction SilentlyContinue |
            Remove-Item -Force
    } else {
        $null = New-Item -ItemType Directory -Path $out -Force
    }

    Write-Host ("[Build-AllPackages] {0}" -f $app)

    $toolArgs   = @('-c', $source, '-s', 'Install.ps1', '-o', $out, '-q')
    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $tool -ArgumentList $toolArgs `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile
        if ($proc.ExitCode -ne 0) {
            $captured = @()
            if (Test-Path -LiteralPath $stdoutFile) { $captured += Get-Content -LiteralPath $stdoutFile }
            if (Test-Path -LiteralPath $stderrFile) { $captured += Get-Content -LiteralPath $stderrFile }
            if ($captured.Count -gt 0) {
                Write-Host '  --- IntuneWinAppUtil output ---'
                $captured | ForEach-Object { Write-Host ("    {0}" -f $_) }
                Write-Host '  --- end output ---'
            }
            throw "IntuneWinAppUtil failed for '$app' with exit code $($proc.ExitCode)"
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }

    $produced = Get-ChildItem -LiteralPath $out -Filter '*.intunewin' -File |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($produced) {
        Write-Host ("  -> {0}" -f $produced.FullName)
    }
}

Write-Host ''
Write-Host '[Build-AllPackages] Done. Four packages built under build\<app>\.'
