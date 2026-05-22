# VS Code Remote-SSH Air-Gap Kit

This kit provides a repeatable workflow for preparing **Visual Studio Code Remote - SSH** for use in an air-gapped environment.

## Design target

The first-pass workflow is optimized for:

- **Connected staging workstation:** Windows system with Internet access and VS Code installed.
- **Air-gapped developer workstation:** Windows system where VS Code will be installed and used.
- **Remote targets:** Linux x64 SSH hosts, such as Ubuntu 24.04 LTS servers.

## Why a bundle is needed

Remote-SSH requires more than the desktop editor and the local extension. When the first SSH session is created, VS Code also needs a **version-matched VS Code Server payload** on the remote host. In an isolated network, that server payload cannot be downloaded at connection time, so it must be staged in advance.

## Bundle contents created by the packager

The packager script creates a portable bundle like this:

```text
vscode-remote-ssh-airgap-bundle/
├── installers/
│   └── VSCodeUserSetup-*.exe or VSCodeSetup-*.exe
├── vsix/
│   ├── ms-vscode-remote.remote-ssh*.vsix
│   ├── ms-vscode.remote-explorer*.vsix
│   └── ms-vscode-remote.remote-ssh-edit*.vsix
├── servers/
│   └── vscode-server-server-linux-x64-<commit>.tar.gz
├── manifest/
│   ├── bundle-manifest.json
│   └── SHA256SUMS.txt
└── README-OFFLINE-INSTALL.md
```

## Recommended minimum VSIX set

Download these VSIX files on the connected staging workstation using **Extensions view → right-click → Download VSIX**:

1. `ms-vscode-remote.remote-ssh` — required Remote-SSH extension.
2. `ms-vscode.remote-explorer` — strongly recommended UI for managing remote hosts.
3. `ms-vscode-remote.remote-ssh-edit` — recommended syntax/intellisense support for SSH config files.

## Staging workflow

1. Install the exact VS Code build you want to use in the air gap on the connected staging workstation.
2. Download the VSIX files listed above into a folder, for example `C:\Staging\VSCode-VSIX`.
3. Download or retain the VS Code Windows installer you plan to deploy offline.
4. Run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\New-VSCodeRemoteSshAirgapBundle.ps1 `
  -VsCodeInstallerPath 'E:\Staging\VSCodeUserSetup-x64.exe' `
  -VsixDirectory 'E:\Staging\VSCode-VSIX' `
  -OutputDirectory 'E:\Staging\Output'
```

5. Transfer the generated ZIP bundle into the air-gapped network.

## Air-gapped client workflow

1. Extract the ZIP bundle.
2. Install VS Code from the included installer.
3. Run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\Install-VSCodeRemoteSshClientOffline.ps1 `
  -BundleRoot '.\vscode-remote-ssh-airgap-bundle'
```

This installs the VSIX files and applies practical offline settings:

- `update.mode = none`
- `extensions.autoUpdate = false`
- `extensions.autoCheckUpdates = false`

## Air-gapped Linux target workflow

Run the server preload script **as the same Linux user who will connect through Remote-SSH**:

```bash
chmod +x ./scripts/Install-VSCodeRemoteSshServerOffline-Linux.sh
./scripts/Install-VSCodeRemoteSshServerOffline-Linux.sh \
  --bundle-root ./vscode-remote-ssh-airgap-bundle \
  --commit <commit-from-bundle-manifest>
```

The script preloads the current Remote-SSH server path:

```text
~/.vscode-server/cli/servers/Stable-<commit>/server
```

It also supports an optional legacy compatibility layout:

```bash
./scripts/Install-VSCodeRemoteSshServerOffline-Linux.sh \
  --bundle-root ./vscode-remote-ssh-airgap-bundle \
  --commit <commit-from-bundle-manifest> \
  --include-legacy-bin-layout
```

That additionally populates:

```text
~/.vscode-server/bin/<commit>
```

## Operational rules that matter

- **The VS Code client build, Remote-SSH extension, and VS Code Server payload should be packaged as one controlled release set.** Do not mix-and-match builds casually.
- **Each remote target user needs the server payload staged in that user’s home directory.** Remote-SSH is per-user, not system-wide.
- **When you update VS Code in the air gap, build a new bundle.** A new editor build usually means a new server commit hash.
- **Ubuntu 24.04 LTS is a good fit.** Current VS Code Server builds require newer Linux runtime baselines than some older enterprise distributions.

## Files in this kit

- `scripts/New-VSCodeRemoteSshAirgapBundle.ps1`
- `scripts/Install-VSCodeRemoteSshClientOffline.ps1`
- `scripts/Install-VSCodeRemoteSshServerOffline-Linux.sh`
- `templates/settings.airgap.json`
- `templates/ssh_config.example`
- `docs/Implementation-Notes.md`
