#Requires -Version 5.1
<#
.SYNOPSIS
    Refresh IntuneWinAppUtil.exe - the only build-side binary this repo
    depends on - verify it, and drop it at its canonical location.

.DESCRIPTION
    Replaces the manual "find the latest IntuneWinAppUtil.exe on GitHub,
    download it, copy into place" flow with one command.

    Downloads IntuneWinAppUtil.exe from the latest release at
    microsoft/Microsoft-Win32-Content-Prep-Tool on GitHub, then verifies
    it via Authenticode before placing it. Verification rejects anything
    where:
      - Signature status is not 'Valid', or
      - Signer subject does not match Microsoft Corporation.

    Verify-then-move makes the placement effectively atomic: a bad
    download cannot half-overwrite a good existing copy. If verification
    fails the existing binary stays untouched.

    On success, source\tooling-versions.json is rewritten with the
    version, source URL, and timestamp. The manifest is gitignored - it
    describes local state that varies per clone.

    Idempotent in the always-fetch sense: re-running the script always
    re-downloads. There is no "skip if already current" comparison.
    Cost is ~1 MB per run.

.PARAMETER RepositoryRoot
    Repository root. Defaults to this script's parent (the repo root,
    since this script lives at <root>\source\Update-Tooling.ps1).

.PARAMETER WorkingDirectory
    Scratch directory for the staged download before verification.
    Defaults to a fresh subdirectory under $env:TEMP.

.EXAMPLE
    # Run from a PowerShell prompt at the repo root:
    .\source\Update-Tooling.ps1

.NOTES
    Project : claude-code-intune
#>
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Path $PSScriptRoot -Parent),

    [string] $WorkingDirectory = (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("update-tooling-" + [Guid]::NewGuid().ToString('N')))
)

$ErrorActionPreference = 'Stop'

$script:TargetPath        = Join-Path -Path $RepositoryRoot -ChildPath 'source\IntuneWinAppUtil.exe'
$script:ManifestPath      = Join-Path -Path $RepositoryRoot -ChildPath 'source\tooling-versions.json'
$script:GitHubReleasesUrl = 'https://api.github.com/repos/microsoft/Microsoft-Win32-Content-Prep-Tool/releases/latest'

function Write-Step {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Message)
    Write-Host ("[Update-Tooling] {0}" -f $Message)
}

function Invoke-DownloadWithRetry {
<#
.SYNOPSIS
    Download a URL to a file with up to N attempts and exponential backoff.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [string] $OutFile,
        [int] $MaxAttempts = 3
    )
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
            return
        }
        catch {
            if ($attempt -ge $MaxAttempts) {
                throw "Download failed for '$Uri' after $MaxAttempts attempts: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds ([math]::Pow(2, $attempt))
        }
    }
}

function Get-LatestIntuneWinAppUtilAsset {
<#
.SYNOPSIS
    Query the GitHub releases API for the latest IntuneWinAppUtil.exe
    download URL plus its version. Returns a hashtable with Url, Version,
    and Source ('release-asset' or 'raw-tag').

.DESCRIPTION
    GitHub API at /repos/<owner>/<repo>/releases/latest returns a JSON
    object with `tag_name` and an `assets[]` array. The maintainers used
    to attach `IntuneWinAppUtil.exe` as a release asset, but the current
    pattern (observed at v1.8.7) is to ship zero assets and keep the
    binary checked into the repo at the tag's commit.

    Resolution order:
      1. If the release has an asset named exactly 'IntuneWinAppUtil.exe',
         use its `browser_download_url`. This path stays correct if
         Microsoft ever re-attaches the binary to a release.
      2. Otherwise fall back to the tag-pinned raw URL on
         raw.githubusercontent.com:
            https://raw.githubusercontent.com/microsoft/Microsoft-Win32-Content-Prep-Tool/<tag>/IntuneWinAppUtil.exe
         which retrieves the binary from the repo at the tagged commit
         (more deterministic than pulling from `master`).

    Throws if the response shape is unexpected, or if neither resolution
    path produces a URL.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string] $ApiUrl = $script:GitHubReleasesUrl
    )

    Write-Step ("Querying GitHub releases API: {0}" -f $ApiUrl)
    $release = $null
    try {
        $release = Invoke-RestMethod -Uri $ApiUrl -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw "Failed to query GitHub releases API at '$ApiUrl': $($_.Exception.Message)"
    }

    if ($null -eq $release) {
        throw "GitHub releases API returned a null response for '$ApiUrl'."
    }
    if (-not $release.PSObject.Properties['tag_name']) {
        throw "GitHub releases API response missing 'tag_name' field. Response shape unexpected."
    }
    if (-not $release.PSObject.Properties['assets']) {
        throw "GitHub releases API response missing 'assets' array. Response shape unexpected."
    }

    $rawTag = [string]$release.tag_name
    if ([string]::IsNullOrWhiteSpace($rawTag)) {
        throw "GitHub releases API response has an empty 'tag_name'."
    }
    $version = $rawTag
    if ($version.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
        $version = $version.Substring(1)
    }

    # Preferred: a release asset named IntuneWinAppUtil.exe.
    $assets = @($release.assets)
    $match  = $assets | Where-Object { $_.name -eq 'IntuneWinAppUtil.exe' } | Select-Object -First 1
    if ($match) {
        if (-not $match.PSObject.Properties['browser_download_url']) {
            throw "Asset '$($match.name)' missing 'browser_download_url' field."
        }
        return @{
            Url     = [string]$match.browser_download_url
            Version = $version
            Source  = 'release-asset'
        }
    }

    # Fallback: tag-pinned raw URL. The maintainers stopped attaching the
    # .exe as a release asset around v1.8.7; the binary lives in the repo
    # at HEAD and at every tag's commit. Pin to the tag for determinism.
    $rawUrl = ('https://raw.githubusercontent.com/microsoft/Microsoft-Win32-Content-Prep-Tool/{0}/IntuneWinAppUtil.exe' -f $rawTag)
    Write-Step ("Release '{0}' has no IntuneWinAppUtil.exe asset; falling back to tag-pinned raw URL." -f $rawTag)
    return @{
        Url     = $rawUrl
        Version = $version
        Source  = 'raw-tag'
    }
}

function Test-MicrosoftSignedBinary {
<#
.SYNOPSIS
    Verify a binary is Authenticode-signed by Microsoft Corporation with
    a Valid status. Throws on any failure - no soft warnings.

.DESCRIPTION
    Authenticode verification gives signed-by + chain-valid + not-revoked
    in one call. Microsoft does not publish hashes for this binary, so
    signature verification is the strongest integrity check available
    without speculative cert pinning.

    IntuneWinAppUtil.exe currently signs as 'CN=Microsoft Corporation'.
    If the subject ever changes the script throws and the operator
    investigates - we don't speculatively add fallback patterns.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $DisplayName
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Authenticode verification: file not found at '$Path' for '$DisplayName'."
    }

    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ([string]$sig.Status -ne 'Valid') {
        throw "Authenticode verification failed for '$DisplayName': status='$($sig.Status)' message='$($sig.StatusMessage)'."
    }
    if ($null -eq $sig.SignerCertificate) {
        throw "Authenticode verification: no signer certificate present on '$DisplayName'."
    }
    $subject = [string]$sig.SignerCertificate.Subject
    if ($subject -notmatch 'CN=Microsoft Corporation') {
        throw "Unexpected signer for '$DisplayName': '$subject'. Expected subject containing 'CN=Microsoft Corporation'. If Microsoft changed the cert subject, investigate before relaxing this check."
    }
}

function Save-ToolingManifest {
<#
.SYNOPSIS
    Write source\tooling-versions.json with the resolved metadata.
    Called only after the binary has been verified AND placed at its
    canonical location, so the manifest never references a binary that
    isn't there.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ManifestPath,
        [Parameter(Mandatory)] [string] $RepositoryRoot,
        [Parameter(Mandatory)] [string] $TargetPath,
        [Parameter(Mandatory)] [string] $Version,
        [Parameter(Mandatory)] [string] $SourceUrl,
        [Parameter(Mandatory)] [string] $Source
    )
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    $relativePath = $TargetPath
    if ($relativePath.StartsWith($RepositoryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relativePath = $relativePath.Substring($RepositoryRoot.Length).TrimStart('\','/')
    }

    $manifest = [ordered]@{
        lastUpdated  = $now
        tool         = 'IntuneWinAppUtil.exe'
        path         = $relativePath
        version      = $Version
        sourceUrl    = $SourceUrl
        sourceType   = $Source
        downloadedAt = $now
    }
    $json = $manifest | ConvertTo-Json -Depth 4
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($ManifestPath, $json, $utf8Bom)
}

# Main flow
$null = New-Item -Path $WorkingDirectory -ItemType Directory -Force

Write-Step ("Repository root  : {0}" -f $RepositoryRoot)
Write-Step ("Working directory: {0}" -f $WorkingDirectory)
Write-Step ("Target path      : {0}" -f $script:TargetPath)
Write-Step ''

try {
    # Resolve the latest release asset URL and version.
    $asset = Get-LatestIntuneWinAppUtilAsset
    Write-Step ("Latest IntuneWinAppUtil release: {0} ({1})" -f $asset.Version, $asset.Source)

    # Phase 1: download to a temp path and verify before any placement
    # logic touches the canonical location. If verification fails, the
    # existing binary stays untouched.
    $tempPath = Join-Path -Path $WorkingDirectory -ChildPath 'IntuneWinAppUtil.exe'
    Write-Step ("Downloading from {0}" -f $asset.Url)
    Invoke-DownloadWithRetry -Uri $asset.Url -OutFile $tempPath
    Write-Step ("Verifying Authenticode signature")
    Test-MicrosoftSignedBinary -Path $tempPath -DisplayName 'IntuneWinAppUtil.exe'
    Write-Step ("  OK  IntuneWinAppUtil.exe version={0}" -f $asset.Version)

    # Phase 2: move into the canonical location.
    $targetDir = Split-Path -Path $script:TargetPath -Parent
    $null = New-Item -Path $targetDir -ItemType Directory -Force
    Write-Step ("Placing -> {0}" -f $script:TargetPath)
    Move-Item -LiteralPath $tempPath -Destination $script:TargetPath -Force

    # Phase 3: manifest. Only written after the binary is in place.
    Save-ToolingManifest `
        -ManifestPath $script:ManifestPath `
        -RepositoryRoot $RepositoryRoot `
        -TargetPath $script:TargetPath `
        -Version $asset.Version `
        -SourceUrl $asset.Url `
        -Source $asset.Source
    Write-Step ("Manifest updated: {0}" -f $script:ManifestPath)

    Write-Step ''
    Write-Step 'Done. Build a package with:'
    Write-Step '  .\source\IntuneWinAppUtil.exe -c apps\<app>\package -s Install.ps1 -o build\<app>'
}
finally {
    if (Test-Path -LiteralPath $WorkingDirectory) {
        Remove-Item -LiteralPath $WorkingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
