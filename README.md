# VS Code Remote-SSH Air-Gap Kit

This kit provides a repeatable workflow for preparing Visual Studio Code Remote - SSH for use in an air-gapped environment.

## Design target

The workflow is optimized for:

- Connected staging workstation: Windows system with Internet access.
- Air-gapped developer workstation: Windows system where VS Code will be installed and used.
- Remote targets: Linux SSH hosts, with server-linux-x64 as default and optional server-linux-arm64 packaging.

## Why a bundle is needed

Remote-SSH requires more than the desktop editor and local extension. At first SSH connection, VS Code needs:

- A version-matched VS Code Server payload on the remote host
- A version-matched Remote-SSH exec CLI bootstrap binary on the remote host

In an isolated network, these cannot be downloaded at connection time, so they must be staged in advance.

## Repository-local working folders

This repository is currently configured to treat the following as generated/staging content:

- staging/: source drop for downloaded VSIX files.
- output/: generated bundle folders and ZIP artifacts.

Both paths are ignored by Git in .gitignore.

## Bundle contents created by the packager

The packager creates a self-contained bundle like this:

```text
vscode-remote-ssh-airgap-bundle-<version>-<commit12>/
├── installers/
│   └── VSCodeUserSetup-*.exe or VSCodeSetup-*.exe
├── vsix/
│   ├── ms-vscode-remote.remote-ssh*.vsix
│   ├── ms-vscode.remote-explorer*.vsix
│   └── ms-vscode-remote.remote-ssh-edit*.vsix
├── servers/
│   └── vscode-server-<artifact>-<commit>.tar.gz
│   └── vscode-cli-<artifact>-<commit>.tar.gz
├── manifest/
│   ├── bundle-manifest.json
│   └── SHA256SUMS.txt
├── scripts/
├── templates/
├── docs/
├── README.md
└── README-OFFLINE-INSTALL.md
```

## Recommended minimum VSIX set

By default, the packager downloads these VSIX packages automatically from the Visual Studio Marketplace:

1. ms-vscode-remote.remote-ssh (required)
2. ms-vscode.remote-explorer (recommended)
3. ms-vscode-remote.remote-ssh-edit (recommended)

You can override this list with `-VsixExtensionIds`.

## Build workflow

### Option A: package from a local installer and local VSIX directory

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\New-VSCodeRemoteSshAirgapBundle.ps1 `
  -VsCodeInstallerPath 'E:\Staging\VSCodeUserSetup-x64-1.137.0.exe' `
  -VsixDirectory 'E:\Staging\VSCode-VSIX' `
  -OutputDirectory 'E:\Staging\Output'
```

### Option B: repository-local production run (download installer + infer commit)

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
$vsixDir = Join-Path $PWD 'staging\vsix'
$outDir  = Join-Path $PWD ("output\production-" + (Get-Date -Format 'yyyyMMdd'))

.\scripts\New-VSCodeRemoteSshAirgapBundle.ps1 `
  -DownloadVsCodeInstaller `
  -VsixDirectory $vsixDir `
  -OutputDirectory $outDir `
  -ServerArtifacts @('server-linux-x64') `
  -Force
```

### Option C: explicit commit pinning

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\New-VSCodeRemoteSshAirgapBundle.ps1 `
  -Commit '<40-char-vscode-commit>' `
  -VsCodeInstallerPath 'E:\Staging\VSCodeUserSetup-x64.exe' `
  -VsixDirectory 'E:\Staging\VSCode-VSIX' `
  -OutputDirectory 'E:\Staging\Output' `
  -ServerArtifacts @('server-linux-x64','server-linux-arm64')
```

### Option D: custom VSIX extension list

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\New-VSCodeRemoteSshAirgapBundle.ps1 `
  -VsixExtensionIds @(
    'ms-vscode-remote.remote-ssh',
    'ms-vscode-remote.remote-ssh-edit'
  ) `
  -ServerArtifacts @('server-linux-x64')
```

Notes:

- If neither VsCodeInstallerPath nor DownloadVsCodeInstaller is supplied, the script defaults to downloading the installer from InstallerUrl.
- If VsixDirectory is omitted, the script defaults to `<repo-root>/staging/vsix`.
- If OutputDirectory is omitted, the script defaults to `<repo-root>/output/production-YYYYMMDD`.
- VSIX packages listed in `VsixExtensionIds` are downloaded into `VsixDirectory` before bundling.
- To disable automatic VSIX download and use only existing local `.vsix` files, pass `-VsixExtensionIds @()`.
- Downloads prefer `aria2c.exe`, then fall back to `Start-BitsTransfer`, then `Invoke-WebRequest`.
- If VsixDirectory does not exist, the script creates it.
- If no VSIX files are present after the download step, packaging continues with a warning.
- ServerArtifacts accepts server-linux-x64 and server-linux-arm64.
- Matching exec CLI payloads are downloaded automatically for selected server artifacts.

## Air-gapped client workflow

1. Extract the ZIP bundle.
2. Install VS Code from the included installer.
3. Run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Install-VSCodeRemoteSshClientOffline.ps1
```

This installs VSIX files and applies offline settings:

- update.mode = none
- extensions.autoUpdate = false
- extensions.autoCheckUpdates = false

## Air-gapped Linux target workflow

Run the server preload script as the same Linux user who will connect through Remote-SSH:

```bash
chmod +x ./scripts/Install-VSCodeRemoteSshServerOffline-Linux.sh
./scripts/Install-VSCodeRemoteSshServerOffline-Linux.sh
```

By default, the Linux script auto-detects bundle root from its own location and reads commit from `manifest/bundle-manifest.json`.

Current preload path:

```text
~/.vscode-server/cli/servers/Stable-<commit>/server
```

Exec CLI preload path:

```text
~/.vscode-server/code-<commit>
```

Optional legacy compatibility layout:

```bash
./scripts/Install-VSCodeRemoteSshServerOffline-Linux.sh --include-legacy-bin-layout
```

```text
~/.vscode-server/bin/<commit>
```

## Operational rules that matter

- Package VS Code client, Remote-SSH extensions, server payload, and exec CLI payload as one release set.
- Stage server payload per remote Linux user account.
- Build a new bundle whenever you update VS Code in the air-gapped environment.

## Troubleshooting: vscode_cli downloads

If Remote-SSH still tries to download files such as `vscode_cli_alpine_x64_cli.tar.gz`, it usually means the per-commit exec CLI binary was not preloaded for that SSH user.

Check these on the remote host for the connecting user:

1. `~/.vscode-server/code-<commit>` exists and is executable.
2. `~/.vscode-server/cli/servers/Stable-<commit>/server` exists.
3. The `<commit>` matches `code --version` line 2 on the Windows client.

## Files in this kit

- scripts/New-VSCodeRemoteSshAirgapBundle.ps1
- scripts/Install-VSCodeRemoteSshClientOffline.ps1
- scripts/Install-VSCodeRemoteSshServerOffline-Linux.sh
- templates/settings.airgap.json
- templates/ssh_config.example
- docs/Implementation-Notes.md
- .gitignore
- LICENSE
