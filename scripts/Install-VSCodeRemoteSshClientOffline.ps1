<#
.SYNOPSIS
    Installs VS Code Remote-SSH VSIX files from an offline bundle and applies practical offline settings.

.DESCRIPTION
    Run this on the AIR-GAPPED Windows developer workstation after VS Code itself has been installed.

    The script:
      - Verifies `code` is available in PATH
      - Installs every .vsix file from the bundle's `vsix` folder
      - Merges offline-friendly settings into the user's VS Code settings.json

.NOTES
    This script does not silently install the VS Code desktop application. Install VS Code first from the bundle's installer.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$BundleRoot,

    [Parameter(Mandatory = $false)]
    [string]$CodeCommand = 'code'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Assert-CommandAvailable {
    param([string]$Command)

    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "Unable to find '$Command' in PATH. Install VS Code from the bundle's installer first, then rerun."
    }
}

function Set-OrAdd-VSCodeSetting {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$JsonValue
    )

    $escapedKey = [Regex]::Escape($Key)
    $pattern = '"' + $escapedKey + '"\s*:\s*("(?:\\.|[^"\\])*"|true|false|null|-?\d+(?:\.\d+)?)'

    if ([Regex]::IsMatch($Content, $pattern)) {
        return [Regex]::Replace(
            $Content,
            $pattern,
            '"' + $Key + '": ' + $JsonValue,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }

    $lastBrace = $Content.LastIndexOf('}')
    if ($lastBrace -lt 0) {
        throw "settings.json does not contain a closing brace. Refusing to modify it automatically."
    }

    $before = $Content.Substring(0, $lastBrace)
    $after  = $Content.Substring($lastBrace)

    $needsComma = $false
    $scan = $before.TrimEnd()
    if ($scan.Length -gt 0 -and -not $scan.EndsWith('{')) {
        $needsComma = $true
    }

    $separator = if ($needsComma) { ',' } else { '' }
    $insertion = "${separator}`r`n  `"$Key`": $JsonValue"
    return $before + $insertion + "`r`n" + $after
}

function Update-VSCodeSettingsFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Set-Content -LiteralPath $Path -Value "{`r`n  `"update.mode`": `"none`",`r`n  `"extensions.autoUpdate`": false,`r`n  `"extensions.autoCheckUpdates`": false`r`n}" -Encoding UTF8
        return
    }

    $backupPath = "$Path.airgap-backup-$(Get-Date -Format 'yyyyMMddHHmmss')"
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    Write-Info "Backed up existing settings.json to: $backupPath"

    $content = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($content)) {
        $content = "{}"
    }

    $content = Set-OrAdd-VSCodeSetting -Content $content -Key 'update.mode' -JsonValue '"none"'
    $content = Set-OrAdd-VSCodeSetting -Content $content -Key 'extensions.autoUpdate' -JsonValue 'false'
    $content = Set-OrAdd-VSCodeSetting -Content $content -Key 'extensions.autoCheckUpdates' -JsonValue 'false'

    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

Assert-CommandAvailable -Command $CodeCommand

$resolvedBundle = [System.IO.Path]::GetFullPath($BundleRoot)
$vsixDir = Join-Path $resolvedBundle 'vsix'
if (-not (Test-Path -LiteralPath $vsixDir -PathType Container)) {
    throw "VSIX folder was not found: $vsixDir"
}

$vsixFiles = Get-ChildItem -LiteralPath $vsixDir -Filter '*.vsix' -File | Sort-Object Name
if (-not $vsixFiles) {
    throw "No .vsix files found in '$vsixDir'."
}

Write-Info 'Installing offline VSIX packages...'
foreach ($vsix in $vsixFiles) {
    Write-Info "Installing $($vsix.Name)"
    & $CodeCommand --install-extension $vsix.FullName --force | Out-Host
    Write-Success "Installed: $($vsix.Name)"
}

$settingsDir = Join-Path $env:APPDATA 'Code\User'
$settingsPath = Join-Path $settingsDir 'settings.json'
New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null

Update-VSCodeSettingsFile -Path $settingsPath
Write-Success "Offline settings updated: $settingsPath"

Write-Host ''
Write-Success 'Client-side Remote-SSH installation is complete.'
Write-Host 'Next step: preload the VS Code Server payload on each Linux SSH target using the Linux script in this same bundle.' -ForegroundColor Green
