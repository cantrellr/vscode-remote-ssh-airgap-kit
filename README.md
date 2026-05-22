# VS Code Remote-SSH Air-Gap Kit

This kit provides a repeatable workflow for preparing Visual Studio Code Remote - SSH for use in an air-gapped environment.

## Design target

The workflow is optimized for:

- Connected staging workstation: Windows system with Internet access.
- Air-gapped developer workstation: Windows system where VS Code will be installed and used.
- Remote targets: Linux SSH hosts, with server-linux-x64 as default and optional server-linux-arm64 packaging.

## Why a bundle is needed

Remote-SSH requires more than the desktop editor and local extension. At first SSH connection, VS Code also needs a version-matched VS Code Server payload on the remote host. In an isolated network, that server payload cannot be downloaded at connection time, so it must be staged in advance.

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

Download these VSIX files on the connected staging workstation using Extensions view -> right-click -> Download VSIX:

1. ms-vscode-remote.remote-ssh (required)
2. ms-vscode.remote-explorer (recommended)
3. ms-vscode-remote.remote-ssh-edit (recommended)

## Build workflow

### Option A: package from a local installer and local VSIX directory

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\New-VSCodeRemoteSshAirgapBundle.ps1 `
  -VsCodeInstallerPath 'E:\Staging\VSCodeUserSetup-x64.exe' `
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

Notes:

- If VsixDirectory does not exist, the script creates it.
- If no VSIX files are present, packaging continues with a warning.
- ServerArtifacts accepts server-linux-x64 and server-linux-arm64.

## Air-gapped client workflow

1. Extract the ZIP bundle.
2. Install VS Code from the included installer.
3. Run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Install-VSCodeRemoteSshClientOffline.ps1 `
  -BundleRoot '.\vscode-remote-ssh-airgap-bundle-<version>-<commit12>'
```

This installs VSIX files and applies offline settings:

- update.mode = none
- extensions.autoUpdate = false
- extensions.autoCheckUpdates = false

## Air-gapped Linux target workflow

Run the server preload script as the same Linux user who will connect through Remote-SSH:

```bash
chmod +x ./scripts/Install-VSCodeRemoteSshServerOffline-Linux.sh
./scripts/Install-VSCodeRemoteSshServerOffline-Linux.sh \
  --bundle-root ./vscode-remote-ssh-airgap-bundle-<version>-<commit12> \
  --commit <commit-from-bundle-manifest>
```

Current preload path:

```text
~/.vscode-server/cli/servers/Stable-<commit>/server
```

Optional legacy compatibility layout:

```bash
./scripts/Install-VSCodeRemoteSshServerOffline-Linux.sh \
  --bundle-root ./vscode-remote-ssh-airgap-bundle-<version>-<commit12> \
  --commit <commit-from-bundle-manifest> \
  --include-legacy-bin-layout
```

```text
~/.vscode-server/bin/<commit>
```

## Operational rules that matter

- Package VS Code client, Remote-SSH extensions, and server payload as one release set.
- Stage server payload per remote Linux user account.
- Build a new bundle whenever you update VS Code in the air-gapped environment.

## Files in this kit

- scripts/New-VSCodeRemoteSshAirgapBundle.ps1
- scripts/Install-VSCodeRemoteSshClientOffline.ps1
- scripts/Install-VSCodeRemoteSshServerOffline-Linux.sh
- templates/settings.airgap.json
- templates/ssh_config.example
- docs/Implementation-Notes.md
- .gitignore
- LICENSE
