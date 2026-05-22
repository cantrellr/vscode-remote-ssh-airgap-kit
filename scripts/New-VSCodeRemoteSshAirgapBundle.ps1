<#
.SYNOPSIS
    Creates a repeatable VS Code Remote-SSH air-gap deployment bundle.

.DESCRIPTION
    This script is intended to run on a CONNECTED Windows staging workstation that:
      - Has Internet access
      - Has the exact target VS Code build installed
      - Has the required VSIX files already downloaded from the VS Code Extensions view

    The script:
      1. Reads the local VS Code version + commit hash from `code --version`
      2. Copies the specified VS Code installer into the bundle
      3. Copies the supplied VSIX files into the bundle
      4. Downloads the exact matching VS Code Server tarball for Linux x64 by commit hash
      5. Generates a JSON manifest and SHA256 checksums
      6. Creates a ZIP package suitable for transfer into an air-gapped network

.NOTES
    Author: Air-gap packaging helper
    Target pattern: Windows VS Code client -> Linux x64 SSH hosts
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$VsCodeInstallerPath,

    [Parameter(Mandatory = $true)]
    [string]$VsixDirectory,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $false)]
    [ValidateSet('server-linux-x64', 'server-linux-arm64')]
    [string[]]$ServerArtifacts = @('server-linux-x64'),

    [Parameter(Mandatory = $false)]
    [string]$CodeCommand = 'code',

    [Parameter(Mandatory = $false)]
    [switch]$DownloadVsCodeInstaller,

    [Parameter(Mandatory = $false)]
    [string]$InstallerUrl = 'https://update.code.visualstudio.com/latest/win32-x64-user/stable',

    [Parameter(Mandatory = $false)]
    [switch]$Force
,
    [Parameter(Mandatory = $false)]
    [string]$Commit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Success {
    param([string]$Message)
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Get-VSCodeIdentity {
    param([string]$Command)

    $candidates = @()
    $candidates += $Command
    $candidates += "$Command.cmd"
    $candidates += "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd"
    $candidates += "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd"

    $lines = $null
    foreach ($cand in $candidates) {
        if (-not $cand) { continue }
        try {
            $output = & $cand --version 2>&1 | ForEach-Object { $_.ToString() }
        } catch {
            $output = @()
        }
        if ($output -and $output.Count -ge 2) {
            Write-Info "Using '$cand' to determine VS Code version"
            $lines = $output
            break
        }
    }

    if (-not $lines) {
        Write-Warn "Initial '$Command --version' output insufficient; attempted several shims with no success."
        try {
            $raw = & $Command --version 2>&1 | ForEach-Object { $_.ToString() }
        } catch {
            $raw = @()
        }
        $lines = $raw
    }

    if (-not $lines -or $lines.Count -lt 2) {
        $dump = if ($lines) { $lines -join "`n" } else { '<no output>' }
        throw "Unable to parse output from '$Command --version'. Output was: $dump"
    }

    $version = ($lines[0]).Trim()
    $commit  = ($lines[1]).Trim()

    if ($commit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "The VS Code commit hash did not look valid: '$commit'"
    }

    return [PSCustomObject]@{
        Version = $version
        Commit  = $commit.ToLowerInvariant()
    }
}

function Resolve-UpdateRedirectLocation {
    param([string]$Url)

    $location = $null
    try {
        $response = Invoke-WebRequest -Uri $Url -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
        $location = $response.Headers['Location']
        if (-not $location -and $response.BaseResponse -and $response.BaseResponse.ResponseUri) {
            $location = $response.BaseResponse.ResponseUri.AbsoluteUri
        }
    } catch {
        $webResponse = $_.Exception.Response
        if ($webResponse -and $webResponse.Headers) {
            $location = $webResponse.Headers['Location']
        }
        if (-not $location) {
            throw "Unable to query VS Code update service at '$Url'. $($_.Exception.Message)"
        }
    }

    if (-not $location) {
        throw "VS Code update service did not provide a redirect location for '$Url'."
    }

    return $location
}

function Resolve-VSCodeIdentityFromUpdateService {
    param(
        [string]$UpdateUrl,
        [string]$FallbackVersion = 'unknown'
    )

    $redirect = Resolve-UpdateRedirectLocation -Url $UpdateUrl
    $commitMatch = [regex]::Match($redirect, '/([0-9a-fA-F]{40})(?:/|$)')
    if (-not $commitMatch.Success) {
        throw "Unable to extract a 40-character VS Code commit hash from update redirect URL: $redirect"
    }

    $versionMatch = [regex]::Match($redirect, '-(?<version>\d+\.\d+\.\d+)(?:\D|$)')
    $resolvedVersion = if ($versionMatch.Success) { $versionMatch.Groups['version'].Value } else { $FallbackVersion }

    return [PSCustomObject]@{
        Version = $resolvedVersion
        Commit  = $commitMatch.Groups[1].Value.ToLowerInvariant()
    }
}

function Get-NormalizedVsCodeVersion {
    param([string]$VersionText)

    if ([string]::IsNullOrWhiteSpace($VersionText)) {
        return $null
    }

    $versionMatch = [regex]::Match($VersionText, '(?<version>\d+\.\d+\.\d+)')
    if ($versionMatch.Success) {
        return $versionMatch.Groups['version'].Value
    }

    return $null
}

function Get-VSCodeVersionFromInstaller {
    param([string]$InstallerPath)

    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
        throw "Installer path not found: $InstallerPath"
    }

    $installer = Get-Item -LiteralPath $InstallerPath
    $candidates = @(
        $installer.VersionInfo.ProductVersion,
        $installer.VersionInfo.FileVersion,
        $installer.Name
    )

    foreach ($candidate in $candidates) {
        $normalized = Get-NormalizedVsCodeVersion -VersionText $candidate
        if ($normalized) {
            return $normalized
        }
    }

    return $null
}

function New-CleanDirectory {
    param(
        [string]$Path,
        [switch]$Overwrite
    )

    if (Test-Path -LiteralPath $Path) {
        if (-not $Overwrite) {
            throw "Output path already exists: $Path. Use -Force to overwrite."
        }
        Remove-Item -LiteralPath $Path -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Path | Out-Null
}

function Get-Sha256Line {
    param([string]$FilePath, [string]$RelativePath)

    $hash = Get-FileHash -LiteralPath $FilePath -Algorithm SHA256
    return "$($hash.Hash.ToLowerInvariant())  $RelativePath"
}

$downloadedInstallerTemp = $null

if ($Commit) {
    if ($Commit -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Provided commit did not look valid: '$Commit'"
    }
    $identity = [PSCustomObject]@{
        Version = 'provided'
        Commit  = $Commit.ToLowerInvariant()
    }
    Write-Info "Using provided VS Code commit: $($identity.Commit)"
} else {
    $identity = $null
    $identityErrors = New-Object System.Collections.Generic.List[string]

    if ($DownloadVsCodeInstaller) {
        try {
            $identity = Resolve-VSCodeIdentityFromUpdateService -UpdateUrl $InstallerUrl -FallbackVersion 'latest'
            Write-Info "Resolved VS Code identity from installer URL: $InstallerUrl"
        } catch {
            $identityErrors.Add("Installer URL lookup failed: $($_.Exception.Message)") | Out-Null
        }
    }

    if ($VsCodeInstallerPath -and -not $identity) {
        if (-not (Test-Path -LiteralPath $VsCodeInstallerPath -PathType Leaf)) {
            throw "Installer path not found for identity lookup: $VsCodeInstallerPath"
        }

        $installerVersion = $null
        try {
            $installerVersion = Get-VSCodeVersionFromInstaller -InstallerPath $VsCodeInstallerPath
        } catch {
            $identityErrors.Add("Installer version extraction failed: $($_.Exception.Message)") | Out-Null
        }

        if ($installerVersion) {
            $lookupUrl = "https://update.code.visualstudio.com/$installerVersion/win32-x64-user/stable"
            try {
                $identity = Resolve-VSCodeIdentityFromUpdateService -UpdateUrl $lookupUrl -FallbackVersion $installerVersion
                Write-Info "Resolved VS Code identity from installer version $installerVersion"
            } catch {
                $identityErrors.Add("Installer version lookup failed: $($_.Exception.Message)") | Out-Null
            }
        } else {
            $identityErrors.Add("Could not determine a VS Code version from installer '$VsCodeInstallerPath'.") | Out-Null
        }
    }

    if (-not $identity) {
        try {
            $identity = Get-VSCodeIdentity -Command $CodeCommand
        } catch {
            $identityErrors.Add("Installed VS Code lookup failed: $($_.Exception.Message)") | Out-Null
        }
    }

    if (-not $identity) {
        $details = if ($identityErrors.Count -gt 0) {
            '- ' + ($identityErrors -join "`n- ")
        } else {
            '- No identity lookup attempts were made.'
        }
        throw "Unable to determine VS Code commit hash for bundle generation.`nUse -Commit <40-char-hash>, install VS Code so '$CodeCommand --version' works, or use -DownloadVsCodeInstaller.`n$details"
    }

    Write-Info "VS Code version detected: $($identity.Version)"
    Write-Info "VS Code commit detected : $($identity.Commit)"
}

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null

$bundleName = "vscode-remote-ssh-airgap-bundle-$($identity.Version)-$($identity.Commit.Substring(0,12))"
$bundleRoot = Join-Path $resolvedOutput $bundleName
$zipPath    = "$bundleRoot.zip"

if (Test-Path -LiteralPath $zipPath) {
    if (-not $Force) {
        throw "ZIP already exists: $zipPath. Use -Force to overwrite."
    }
    Remove-Item -LiteralPath $zipPath -Force
}

New-CleanDirectory -Path $bundleRoot -Overwrite:$Force

$installerDir = Join-Path $bundleRoot 'installers'
$vsixDir      = Join-Path $bundleRoot 'vsix'
$serverDir    = Join-Path $bundleRoot 'servers'
$manifestDir  = Join-Path $bundleRoot 'manifest'

New-Item -ItemType Directory -Path $installerDir, $vsixDir, $serverDir, $manifestDir | Out-Null

Write-Info 'Preparing VS Code installer...'
if ($DownloadVsCodeInstaller) {
    Write-Info "Preparing installer from $InstallerUrl..."
    $installerName = Split-Path -Path $InstallerUrl -Leaf
    if (-not ($installerName -and $installerName -like '*.exe')) { $installerName = 'VSCodeUserSetup-x64.exe' }
    $installerDest = Join-Path $installerDir $installerName
    if ($downloadedInstallerTemp -and (Test-Path -LiteralPath $downloadedInstallerTemp -PathType Leaf)) {
        Copy-Item -LiteralPath $downloadedInstallerTemp -Destination $installerDest -Force
        Remove-Item -LiteralPath $downloadedInstallerTemp -Force -ErrorAction SilentlyContinue
        Write-Success "Installer downloaded: $installerName"
    } else {
        try {
            Invoke-WebRequest -Uri $InstallerUrl -OutFile $installerDest -UseBasicParsing
        }
        catch {
            throw "Failed to download installer from '$InstallerUrl'. $($_.Exception.Message)"
        }
        if (-not (Test-Path -LiteralPath $installerDest -PathType Leaf)) {
            throw "Installer download did not produce a file: $installerDest"
        }
        Write-Success "Installer downloaded: $installerName"
    }
} else {
    if (-not $VsCodeInstallerPath) {
        throw "No installer provided. Use -VsCodeInstallerPath or -DownloadVsCodeInstaller to download the installer."
    }
    if (-not (Test-Path -LiteralPath $VsCodeInstallerPath -PathType Leaf)) {
        throw "Installer path not found: $VsCodeInstallerPath"
    }
    $installerName = Split-Path -Path $VsCodeInstallerPath -Leaf
    $installerDest = Join-Path $installerDir $installerName
    Copy-Item -LiteralPath $VsCodeInstallerPath -Destination $installerDest -Force
    Write-Success "Installer copied: $installerName"
}

if (-not (Test-Path -LiteralPath $VsixDirectory)) {
    Write-Warn "VSIX directory not found: $VsixDirectory - creating it now."
    New-Item -ItemType Directory -Path $VsixDirectory -Force | Out-Null
}

$vsixFiles = Get-ChildItem -LiteralPath $VsixDirectory -Filter '*.vsix' -File -ErrorAction SilentlyContinue | Sort-Object Name
if (-not $vsixFiles -or $vsixFiles.Count -eq 0) {
    Write-Warn "No .vsix files found in '$VsixDirectory'. Continuing without VSIX packages."
    $vsixFiles = @()
}

Write-Info 'Copying VSIX packages into bundle...'
$copiedVsix = @()
foreach ($vsix in $vsixFiles) {
    $dest = Join-Path $vsixDir $vsix.Name
    Copy-Item -LiteralPath $vsix.FullName -Destination $dest -Force
    $copiedVsix += $vsix.Name
    Write-Success "VSIX copied: $($vsix.Name)"
}

$downloadedServers = @()
foreach ($artifact in $ServerArtifacts) {
    $serverFileName = "vscode-server-$artifact-$($identity.Commit).tar.gz"
    $serverDest = Join-Path $serverDir $serverFileName
    $url = "https://update.code.visualstudio.com/commit:$($identity.Commit)/$artifact/stable"

    Write-Info "Downloading server payload '$artifact' for commit $($identity.Commit)..."
    try {
        Invoke-WebRequest -Uri $url -OutFile $serverDest -UseBasicParsing
    }
    catch {
        throw "Failed to download '$artifact' from '$url'. $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $serverDest -PathType Leaf)) {
        throw "Server download did not produce a file: $serverDest"
    }

    $downloadedServers += [PSCustomObject]@{
        Artifact = $artifact
        FileName = $serverFileName
        Url      = $url
    }
    Write-Success "Server payload downloaded: $serverFileName"
}

$offlineReadme = @'
# Offline install summary

This bundle was built from:

- VS Code version: __VSCODE_VERSION__
- VS Code commit : __VSCODE_COMMIT__

## Air-gapped Windows client

1. Install VS Code from the `installers` folder.
2. Run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Install-VSCodeRemoteSshClientOffline.ps1 -BundleRoot '<path-to-this-bundle>'
```

## Air-gapped Linux SSH target

Run as the exact Linux account that will be used from VS Code Remote-SSH:

```bash
chmod +x ./scripts/Install-VSCodeRemoteSshServerOffline-Linux.sh
./scripts/Install-VSCodeRemoteSshServerOffline-Linux.sh \
    --bundle-root '<path-to-this-bundle>' \
    --commit '__VSCODE_COMMIT__'
```
'@

$offlineReadme = $offlineReadme -replace '__VSCODE_VERSION__', $identity.Version -replace '__VSCODE_COMMIT__', $identity.Commit

Set-Content -LiteralPath (Join-Path $bundleRoot 'README-OFFLINE-INSTALL.md') -Value $offlineReadme -Encoding UTF8

# Copy scripts + templates into the final bundle so the ZIP is self-contained.
$kitRoot = Split-Path -Parent $PSScriptRoot
Copy-Item -LiteralPath (Join-Path $kitRoot 'scripts')   -Destination $bundleRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $kitRoot 'templates') -Destination $bundleRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $kitRoot 'docs')      -Destination $bundleRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $kitRoot 'README.md') -Destination $bundleRoot -Force

$manifest = [PSCustomObject]@{
    schemaVersion = '1.0'
    generatedUtc  = [DateTime]::UtcNow.ToString('o')
    vscode        = [PSCustomObject]@{
        version = $identity.Version
        commit  = $identity.Commit
    }
    installer     = [PSCustomObject]@{
        fileName = $installerName
    }
    vsixFiles     = $copiedVsix
    serverPayloads = $downloadedServers
    recommendedOfflineSettings = [PSCustomObject]@{
        'update.mode' = 'none'
        'extensions.autoUpdate' = $false
        'extensions.autoCheckUpdates' = $false
    }
}

$manifestPath = Join-Path $manifestDir 'bundle-manifest.json'
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Success 'Manifest generated.'

Write-Info 'Generating SHA256 checksums...'
$checksumLines = New-Object System.Collections.Generic.List[string]
$bundleFiles = Get-ChildItem -LiteralPath $bundleRoot -Recurse -File | Sort-Object FullName
foreach ($file in $bundleFiles) {
    $relative = $file.FullName.Substring($bundleRoot.Length).TrimStart('\','/') -replace '\\','/'
    $checksumLines.Add((Get-Sha256Line -FilePath $file.FullName -RelativePath $relative))
}

$checksumPath = Join-Path $manifestDir 'SHA256SUMS.txt'
$checksumLines | Set-Content -LiteralPath $checksumPath -Encoding ASCII
Write-Success 'SHA256 checksum file generated.'

Write-Info 'Creating ZIP package...'
Compress-Archive -Path (Join-Path $bundleRoot '*') -DestinationPath $zipPath -Force
Write-Success "Bundle ZIP created: $zipPath"
Write-Success "Bundle folder retained: $bundleRoot"

Write-Host ''
Write-Host 'Next step: transfer the ZIP into the air-gapped network and follow README-OFFLINE-INSTALL.md.' -ForegroundColor Green
