#Requires -Version 5.1
<#
.SYNOPSIS
    Fetch the latest installer or MSIX payload for each of the four
    payload-bundling apps in the kit (Git for Windows, VS Code System,
    PowerShell 7, Claude Desktop) and drop each one into its
    apps\<app>\package\ folder.

.DESCRIPTION
    Goes together with source\Update-Tooling.ps1. Where Update-Tooling.ps1
    refreshes the .intunewin build tool, this script refreshes the
    payloads that get bundled inside each .intunewin.

    Per-app sources:
      git-for-windows : GitHub releases API, repo git-for-windows/git;
                        first asset matching 'Git-*-64-bit.exe'.
      vscode          : https://code.visualstudio.com/sha/download
                        ?build=stable&os=win32-x64 . The URL 302s to a
                        versioned VSCodeSetup-x64-X.Y.Z.exe on the
                        microsoft.com CDN; we capture the redirected URL
                        to derive both the filename and the version.
      powershell-7    : GitHub releases API, repo PowerShell/PowerShell;
                        first non-prerelease release whose assets contain
                        a 'PowerShell-*-win-x64.msi'. /releases/latest is
                        not reliable here - Microsoft sometimes pushes
                        previews to that endpoint.
      claude-desktop  : https://claude.ai/api/desktop/win32/x64/msix/latest/redirect
                        302s to a versioned MSIX on Anthropic's CDN.
                        We follow the redirect to capture both the
                        resolved URL (manifest) and the version, parsed
                        from the URL path segment immediately before the
                        filename. Saved locally under the fixed name
                        'Claude.msix' inside apps\claude-desktop\package\.
                        arm64 equivalent is out of scope for actual
                        deployment but documented in
                        Get-ClaudeDesktopAsset for future reference.

    Each downloaded installer is Authenticode-verified before it leaves
    the staging directory. Status must be 'Valid' AND the signer's
    Subject must match an app-specific pattern (see $specs below). If
    verification fails the staged file never reaches the bundle folder,
    so prior bundled installers are left untouched. Mirrors the pattern
    in source\Update-Tooling.ps1 for IntuneWinAppUtil.exe.

    Each app's apps\<app>\package\ folder is cleaned of any prior
    installer match before the new file lands, so a stale older
    version cannot ride inside the next .intunewin alongside the
    current one. The bundled installer files are gitignored.

    On success, source\installer-versions.json is rewritten with a row
    per app (version, filename, source URL, download timestamp). The
    manifest is gitignored - it describes local state that varies per
    clone - and is written only after every download has completed and
    every file has been placed.

    Idempotent in the always-fetch sense: re-running re-downloads.

.PARAMETER RepositoryRoot
    Repository root. Defaults to this script's parent.

.PARAMETER WorkingDirectory
    Scratch directory for staged downloads. Defaults to a fresh temp dir.

.EXAMPLE
    # Run from a PowerShell prompt at the repo root, before Build-AllPackages.
    .\source\Update-Installers.ps1
    .\source\Build-AllPackages.ps1

.NOTES
    Project : claude-code-intune
#>
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Path $PSScriptRoot -Parent),

    [string] $WorkingDirectory = (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("update-installers-" + [Guid]::NewGuid().ToString('N')))
)

$ErrorActionPreference = 'Stop'

$script:UserAgent    = 'claude-code-intune Update-Installers'
$script:ManifestPath = Join-Path -Path $RepositoryRoot -ChildPath 'source\installer-versions.json'

function Write-Step {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Message)
    Write-Host ("[Update-Installers] {0}" -f $Message)
}

function Invoke-DownloadWithRetry {
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
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing `
                              -UserAgent $script:UserAgent -ErrorAction Stop
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

function Get-GitHubReleaseAsset {
<#
.SYNOPSIS
    Resolve a single asset's download URL and version from a GitHub repo.

.DESCRIPTION
    Walks the repo's /releases endpoint (paginated, default page size)
    and returns the first release whose assets contain a name matching
    -AssetPattern AND whose prerelease flag is false (when -StableOnly
    is set). Without -StableOnly, /releases/latest is used.

    git-for-windows publishes releases with the bare version as the tag
    name and one main installer asset; /releases/latest is fine.

    PowerShell/PowerShell sometimes pushes previews to /releases/latest;
    we walk /releases and pick the first non-prerelease.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $AssetPattern,
        [switch] $StableOnly
    )

    if ($StableOnly) {
        $apiUrl = "https://api.github.com/repos/$Owner/$Repo/releases"
        Write-Step ("Querying GitHub releases (stable-only): {0}" -f $apiUrl)
        $releases = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing `
                                      -UserAgent $script:UserAgent -ErrorAction Stop
        $releases = @($releases) | Where-Object { -not $_.prerelease -and -not $_.draft }
        if (-not $releases -or $releases.Count -eq 0) {
            throw "No non-prerelease releases found at '$apiUrl' (page 1). Increase pagination if Microsoft pushed several previews in a row."
        }
    } else {
        $apiUrl = "https://api.github.com/repos/$Owner/$Repo/releases/latest"
        Write-Step ("Querying GitHub releases (latest): {0}" -f $apiUrl)
        $latest = Invoke-RestMethod -Uri $apiUrl -UseBasicParsing `
                                    -UserAgent $script:UserAgent -ErrorAction Stop
        $releases = @($latest)
    }

    foreach ($release in $releases) {
        $tag = [string]$release.tag_name
        $version = $tag
        if ($version.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) {
            $version = $version.Substring(1)
        }
        $assets = @($release.assets) | Where-Object { $_.name -like $AssetPattern }
        $match = $assets | Select-Object -First 1
        if ($match) {
            return @{
                Url      = [string]$match.browser_download_url
                Version  = $version
                Filename = [string]$match.name
                Tag      = $tag
            }
        }
    }
    throw "No release asset matching '$AssetPattern' found in '$Owner/$Repo'."
}

function Get-VSCodeStableAsset {
<#
.SYNOPSIS
    Resolve the System x64 installer URL and filename for VS Code stable.

.DESCRIPTION
    code.visualstudio.com serves a 302 from the build-aliased URL to a
    versioned filename on vscode.download.prss.microsoft.com. We need the
    redirected filename (it carries the version) and the absolute URL.
    HttpWebRequest with AllowAutoRedirect=true follows redirects and
    surfaces the final URL on ResponseUri without us needing to parse
    Location headers ourselves.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $aliasUrl = 'https://code.visualstudio.com/sha/download?build=stable&os=win32-x64'
    Write-Step ("Resolving VS Code stable redirect: {0}" -f $aliasUrl)

    $req = [System.Net.HttpWebRequest]::Create($aliasUrl)
    $req.AllowAutoRedirect           = $true
    $req.MaximumAutomaticRedirections = 5
    $req.UserAgent                    = $script:UserAgent
    $req.Method                       = 'HEAD'

    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        # Some CDNs reject HEAD; retry with GET and abandon the body.
        Write-Step "HEAD rejected; retrying with GET (response body discarded)"
        $req2 = [System.Net.HttpWebRequest]::Create($aliasUrl)
        $req2.AllowAutoRedirect           = $true
        $req2.MaximumAutomaticRedirections = 5
        $req2.UserAgent                    = $script:UserAgent
        $req2.Method                       = 'GET'
        $resp = $req2.GetResponse()
    }

    try {
        $finalUri = [Uri]$resp.ResponseUri
    } finally {
        $resp.Close()
    }

    $filename = [System.IO.Path]::GetFileName($finalUri.AbsolutePath)
    if ($filename -notmatch '^VSCodeSetup-x64-(.+)\.exe$') {
        throw "Unexpected VS Code installer filename '$filename' from URL '$finalUri'. Expected pattern 'VSCodeSetup-x64-X.Y.Z.exe'."
    }
    $version = $Matches[1]

    return @{
        Url      = [string]$finalUri
        Version  = $version
        Filename = $filename
    }
}

function Get-ClaudeDesktopAsset {
<#
.SYNOPSIS
    Resolve the latest Claude Desktop MSIX (x64) URL.

.DESCRIPTION
    https://claude.ai/api/desktop/win32/x64/msix/latest/redirect
    serves a 302 to a versioned MSIX URL on Anthropic's CDN of the
    form
    https://downloads.claude.ai/releases/win32/x64/<version>/Claude-<hash>.msix.
    We follow the redirect with GET (Anthropic's redirect endpoint
    rejects HEAD), capture ResponseUri, and pull the version out of
    the URL path - the path segment immediately before the filename.

    Always saves locally as the fixed name 'Claude.msix' (not the
    versioned upstream filename) inside apps\claude-desktop\package\.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    # arm64 (out of scope; kit is x64-only): https://claude.ai/api/desktop/win32/arm64/msix/latest/redirect
    $aliasUrl = 'https://claude.ai/api/desktop/win32/x64/msix/latest/redirect'
    Write-Step ("Resolving Claude Desktop redirect: {0}" -f $aliasUrl)

    # GET, not HEAD: Anthropic's redirect endpoint rejects HEAD. The
    # response body is discarded - we only need the redirected URL.
    $req = [System.Net.HttpWebRequest]::Create($aliasUrl)
    $req.AllowAutoRedirect            = $true
    $req.MaximumAutomaticRedirections = 5
    $req.UserAgent                    = $script:UserAgent
    $req.Method                       = 'GET'

    $resp = $req.GetResponse()
    try {
        $finalUri = [Uri]$resp.ResponseUri
    } finally {
        $resp.Close()
    }

    $resolvedFilename = [System.IO.Path]::GetFileName($finalUri.AbsolutePath)

    # Version is in the URL path segment before the filename, e.g.
    #   /releases/win32/x64/1.5354.0/Claude-<hash>.msix
    # Try the path first; fall back to filename matching only if the
    # path layout ever changes.
    $version = 'unknown'
    if ($finalUri.AbsolutePath -match '/(\d+\.\d+\.\d+)/') {
        $version = $Matches[1]
    } elseif ($resolvedFilename -match '(\d+\.\d+(?:\.\d+){0,2})') {
        $version = $Matches[1]
    }

    return @{
        Url      = [string]$finalUri
        Version  = $version
        Filename = 'Claude.msix'
    }
}

function Test-SignedBinary {
<#
.SYNOPSIS
    Verify a binary is Authenticode-signed with a Valid status and a
    signer subject matching the expected pattern. Throws on any failure
    - no soft warnings.

.DESCRIPTION
    Authenticode verification gives signed-by + chain-valid +
    not-revoked in one call. The bundled installers are vendor-signed
    (Git for Windows by its maintainer, VS Code and PS7 by Microsoft);
    without this check, a CDN compromise or wrong-file substitution
    would land silently in the .intunewin.

    -ExpectedSignerPattern is matched against the cert's Subject as a
    regex. Pick a stable substring (vendor name, not the full DN) so
    routine cert renewals don't trip the check; investigate any throw
    rather than relaxing the pattern reflexively.

    Works for both PE (.exe) and MSI files - Get-AuthenticodeSignature
    handles both formats.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $DisplayName,
        [Parameter(Mandatory)] [string] $ExpectedSignerPattern
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
    if ($subject -notmatch $ExpectedSignerPattern) {
        throw "Unexpected signer for '$DisplayName': '$subject'. Expected subject matching '$ExpectedSignerPattern'. Investigate before relaxing this check."
    }
}

function Save-InstallerInPackage {
<#
.SYNOPSIS
    Move a downloaded installer into apps\<app>\package\, removing any
    prior file matching the same glob first so older versions don't ride
    along inside the next .intunewin build.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StagedPath,
        [Parameter(Mandatory)] [string] $TargetDir,
        [Parameter(Mandatory)] [string] $Filename,
        [Parameter(Mandatory)] [string] $CleanupGlob
    )
    $null = New-Item -Path $TargetDir -ItemType Directory -Force

    # Wipe any prior installer matching the glob so old + new don't both
    # end up in the .intunewin.
    $stale = Get-ChildItem -Path $TargetDir -Filter $CleanupGlob -File -ErrorAction SilentlyContinue
    foreach ($item in $stale) {
        Write-Step ("Removing stale: {0}" -f $item.Name)
        Remove-Item -LiteralPath $item.FullName -Force
    }

    $finalPath = Join-Path -Path $TargetDir -ChildPath $Filename
    Move-Item -LiteralPath $StagedPath -Destination $finalPath -Force
    return $finalPath
}

function Save-InstallerManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $ManifestPath,
        [Parameter(Mandatory)] [object[]] $Entries
    )
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $manifest = [ordered]@{
        lastUpdated = $now
        installers  = $Entries
    }
    $json = $manifest | ConvertTo-Json -Depth 6
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($ManifestPath, $json, $utf8Bom)
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

$null = New-Item -Path $WorkingDirectory -ItemType Directory -Force

Write-Step ("Repository root  : {0}" -f $RepositoryRoot)
Write-Step ("Working directory: {0}" -f $WorkingDirectory)
Write-Step ''

# Per-app spec. Order is download-then-place; if any download fails we
# stop before placing anything, leaving prior bundled installers alone.
# ExpectedSignerPattern values are regexes matched against the signer
# cert's Subject. Patterns are deliberately narrow on the vendor name
# (the stable part) and lenient on everything else (CN/O/L/S/C, cert
# renewals, etc.). If a vendor's signer ever genuinely changes,
# Test-SignedBinary throws and the operator updates the pattern after
# investigating - we don't relax these reflexively.
$specs = @(
    @{
        App                   = 'git-for-windows'
        Resolver              = { Get-GitHubReleaseAsset -Owner 'git-for-windows' -Repo 'git' -AssetPattern 'Git-*-64-bit.exe' }
        CleanupGlob           = 'Git-*-64-bit.exe'
        # Git for Windows is signed by the project maintainer Johannes
        # Schindelin (cert subject typically contains
        # CN="Open Source Developer, Johannes Schindelin"). Matching on
        # the maintainer's name is more stable than the full DN.
        ExpectedSignerPattern = 'Johannes Schindelin'
    },
    @{
        App                   = 'vscode'
        Resolver              = { Get-VSCodeStableAsset }
        CleanupGlob           = 'VSCodeSetup-x64-*.exe'
        ExpectedSignerPattern = 'CN=Microsoft Corporation'
    },
    @{
        App                   = 'powershell-7'
        Resolver              = { Get-GitHubReleaseAsset -Owner 'PowerShell' -Repo 'PowerShell' -AssetPattern 'PowerShell-*-win-x64.msi' -StableOnly }
        CleanupGlob           = 'PowerShell-*-win-x64.msi'
        ExpectedSignerPattern = 'CN=Microsoft Corporation'
    },
    @{
        App                   = 'claude-desktop'
        Resolver              = { Get-ClaudeDesktopAsset }
        CleanupGlob           = 'Claude.msix'
        # Anthropic signs Claude Desktop with an Azure Trusted Signing
        # certificate (CA-trusted, short-lived). Match on the publisher
        # name only - the full Subject rotates with each cert renewal.
        ExpectedSignerPattern = 'Anthropic'
    }
)

try {
    # Phase 1: resolve metadata + download every installer to the staging
    # dir. Nothing touches apps\<app>\package\ until all three succeed.
    $resolved = @()
    foreach ($spec in $specs) {
        $app = $spec.App
        Write-Step ("---- {0} ----" -f $app)
        $info = & $spec.Resolver
        Write-Step ("  version  : {0}" -f $info.Version)
        Write-Step ("  filename : {0}" -f $info.Filename)
        Write-Step ("  url      : {0}" -f $info.Url)

        $staged = Join-Path -Path $WorkingDirectory -ChildPath $info.Filename
        Write-Step ("  downloading -> {0}" -f $staged)
        Invoke-DownloadWithRetry -Uri $info.Url -OutFile $staged

        # Verify before the file leaves the staging dir. On failure we
        # throw, the finally{} cleans the staging dir, and any prior
        # bundled installer in apps\<app>\package\ stays untouched.
        Write-Step ("  verifying signature (expect: {0})" -f $spec.ExpectedSignerPattern)
        Test-SignedBinary -Path $staged -DisplayName $info.Filename `
                          -ExpectedSignerPattern $spec.ExpectedSignerPattern
        Write-Step ("  OK  signed by expected signer")

        $resolved += [pscustomobject]@{
            App         = $app
            Version     = $info.Version
            Filename    = $info.Filename
            Url         = $info.Url
            StagedPath  = $staged
            CleanupGlob = $spec.CleanupGlob
        }
    }

    # Phase 2: place every installer atomically per file. We don't roll
    # back on partial failure here - if a Move fails mid-flight, the
    # operator re-runs and idempotency takes over.
    $entries = @()
    foreach ($r in $resolved) {
        $targetDir = Join-Path -Path $RepositoryRoot -ChildPath ("apps\{0}\package" -f $r.App)
        Write-Step ("Placing {0} -> {1}" -f $r.Filename, $targetDir)
        $final = Save-InstallerInPackage -StagedPath $r.StagedPath `
                                          -TargetDir $targetDir `
                                          -Filename $r.Filename `
                                          -CleanupGlob $r.CleanupGlob

        $relativePath = $final
        if ($relativePath.StartsWith($RepositoryRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relativePath = $relativePath.Substring($RepositoryRoot.Length).TrimStart('\','/')
        }

        $entries += [ordered]@{
            app          = $r.App
            version      = $r.Version
            filename     = $r.Filename
            path         = $relativePath
            sourceUrl    = $r.Url
            downloadedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
    }

    # Phase 3: manifest. Written only after every binary is in place.
    Save-InstallerManifest -ManifestPath $script:ManifestPath -Entries $entries
    Write-Step ("Manifest updated: {0}" -f $script:ManifestPath)

    Write-Step ''
    Write-Step 'Done. Build packages with:'
    Write-Step '  .\source\Build-AllPackages.ps1'
}
finally {
    if (Test-Path -LiteralPath $WorkingDirectory) {
        Remove-Item -LiteralPath $WorkingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
