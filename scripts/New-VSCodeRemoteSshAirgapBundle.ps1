<#
.SYNOPSIS
    Creates a repeatable VS Code Remote-SSH air-gap deployment bundle.

.DESCRIPTION
    This script is intended to run on a CONNECTED Windows staging workstation that:
      - Has Internet access
      - Has the exact target VS Code build installed

    The script:
      1. Reads the local VS Code version + commit hash from `code --version`
      2. Copies the specified VS Code installer into the bundle
            3. Downloads the configured VSIX packages (or uses existing local VSIX files)
                 and copies them into the bundle
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

    [Parameter(Mandatory = $false)]
    [string]$VsixDirectory,

    [Parameter(Mandatory = $false)]
    [string[]]$VsixExtensionIds = @(
        'ms-vscode-remote.remote-ssh',
        'ms-vscode.remote-explorer',
        'ms-vscode-remote.remote-ssh-edit'
    ),

    [Parameter(Mandatory = $false)]
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

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $downloadErrors = New-Object System.Collections.Generic.List[string]
    $destinationDirectory = Split-Path -Path $DestinationPath -Parent
    if ($destinationDirectory -and -not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
        Remove-Item -LiteralPath $DestinationPath -Force
    }

    $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
    if ($curl) {
        Write-Info "Downloading with curl.exe"
        try {
            $curlArgs = @('--fail', '--location', '--retry', '3', '--retry-delay', '2', '--output', $DestinationPath, $Url)
            & $curl.Source @curlArgs
            $curlExitCode = $LASTEXITCODE
            if ($curlExitCode -eq 0 -and (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) {
                return
            }
            $downloadErrors.Add("curl.exe failed with exit code $curlExitCode.") | Out-Null
        } catch {
            $downloadErrors.Add("curl.exe error: $($_.Exception.Message)") | Out-Null
        }

        if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
            Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        }
    } else {
        $downloadErrors.Add('curl.exe not found on PATH.') | Out-Null
    }

    $bits = Get-Command 'Start-BitsTransfer' -ErrorAction SilentlyContinue
    if ($bits) {
        Write-Info "Downloading with Start-BitsTransfer"
        try {
            Start-BitsTransfer -Source $Url -Destination $DestinationPath -ErrorAction Stop
            if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
                return
            }
            $downloadErrors.Add('Start-BitsTransfer completed without producing destination file.') | Out-Null
        } catch {
            $downloadErrors.Add("Start-BitsTransfer error: $($_.Exception.Message)") | Out-Null
        }

        if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
            Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        }
    } else {
        $downloadErrors.Add('Start-BitsTransfer command not available.') | Out-Null
    }

    Write-Info "Downloading with Invoke-WebRequest"
    $priorProgressPreference = $ProgressPreference
    try {
        $script:ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -UseBasicParsing -ErrorAction Stop
        if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
            return
        }
        $downloadErrors.Add('Invoke-WebRequest completed without producing destination file.') | Out-Null
    } catch {
        $downloadErrors.Add("Invoke-WebRequest error: $($_.Exception.Message)") | Out-Null
    } finally {
        $script:ProgressPreference = $priorProgressPreference
    }

    $detail = if ($downloadErrors.Count -gt 0) {
        "- " + ($downloadErrors -join "`n- ")
    } else {
        '- Unknown download failure.'
    }
    throw "Failed to download '$Url' to '$DestinationPath'.`n$detail"
}

function Get-VsixDownloadSpec {
    param([string]$ExtensionId)

    if ([string]::IsNullOrWhiteSpace($ExtensionId)) {
        throw "VSIX extension ID cannot be empty."
    }

    $normalized = $ExtensionId.Trim()
    $parts = $normalized.Split('.', 2)
    if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
        throw "Invalid VSIX extension ID '$ExtensionId'. Expected format '<publisher>.<extension>'."
    }

    $publisher = $parts[0]
    $extensionName = $parts[1]
    $canonicalExtensionId = "$publisher.$extensionName"

    return [PSCustomObject]@{
        ExtensionId = $canonicalExtensionId
        FileName    = "$canonicalExtensionId.latest.vsix"
        Url         = "https://marketplace.visualstudio.com/_apis/public/gallery/publishers/$publisher/vsextensions/$extensionName/latest/vspackage"
    }
}

function Sync-VsixPackages {
    param(
        [string]$DestinationDirectory,
        [string[]]$ExtensionIds
    )

    if (-not (Test-Path -LiteralPath $DestinationDirectory)) {
        New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    }

    $normalizedIds = @($ExtensionIds |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Sort-Object -Unique)

    if (-not $normalizedIds -or $normalizedIds.Count -eq 0) {
        Write-Warn 'No VSIX extension IDs were configured for download.'
        return
    }

    foreach ($extensionId in $normalizedIds) {
        $spec = Get-VsixDownloadSpec -ExtensionId $extensionId
        $destination = Join-Path $DestinationDirectory $spec.FileName

        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            Write-Info "VSIX already present, skipping download: $($spec.FileName)"
            continue
        }

        Write-Info "Downloading VSIX package '$($spec.ExtensionId)'..."
        Invoke-DownloadFile -Url $spec.Url -DestinationPath $destination
        Write-Success "VSIX downloaded: $($spec.FileName)"
    }
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
$useDownloadedInstaller = $DownloadVsCodeInstaller.IsPresent
$kitRoot = Split-Path -Parent $PSScriptRoot

if (-not $useDownloadedInstaller -and -not $VsCodeInstallerPath) {
    $useDownloadedInstaller = $true
    Write-Warn "Neither -VsCodeInstallerPath nor -DownloadVsCodeInstaller was provided. Defaulting to installer download from '$InstallerUrl'."
}

if (-not $VsixDirectory) {
    $VsixDirectory = Join-Path $kitRoot 'staging\vsix'
    Write-Warn "No -VsixDirectory was provided. Defaulting to '$VsixDirectory'."
}

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $kitRoot ("output\production-{0}" -f (Get-Date -Format 'yyyyMMdd'))
    Write-Warn "No -OutputDirectory was provided. Defaulting to '$OutputDirectory'."
}

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

    if ($useDownloadedInstaller) {
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
if ($useDownloadedInstaller) {
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
            Invoke-DownloadFile -Url $InstallerUrl -DestinationPath $installerDest
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

Sync-VsixPackages -DestinationDirectory $VsixDirectory -ExtensionIds $VsixExtensionIds

$vsixFiles = Get-ChildItem -LiteralPath $VsixDirectory -Filter '*.vsix' -File -ErrorAction SilentlyContinue | Sort-Object Name
if (-not $vsixFiles -or $vsixFiles.Count -eq 0) {
    Write-Warn "No .vsix files found in '$VsixDirectory' after VSIX download step. Continuing without VSIX packages."
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
        Invoke-DownloadFile -Url $url -DestinationPath $serverDest
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
.\scripts\Install-VSCodeRemoteSshClientOffline.ps1
```

## Air-gapped Linux SSH target

Run as the exact Linux account that will be used from VS Code Remote-SSH:

```bash
chmod +x ./scripts/Install-VSCodeRemoteSshServerOffline-Linux.sh
./scripts/Install-VSCodeRemoteSshServerOffline-Linux.sh
```

The Linux script defaults to bundle-root auto-detection and commit lookup from `manifest/bundle-manifest.json`.
'@

$offlineReadme = $offlineReadme -replace '__VSCODE_VERSION__', $identity.Version -replace '__VSCODE_COMMIT__', $identity.Commit

Set-Content -LiteralPath (Join-Path $bundleRoot 'README-OFFLINE-INSTALL.md') -Value $offlineReadme -Encoding UTF8

# Copy scripts + templates into the final bundle so the ZIP is self-contained.
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
