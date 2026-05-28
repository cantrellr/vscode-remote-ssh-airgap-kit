# Implementation Notes

## Bundle strategy

The workflow intentionally treats VS Code as a release bundle:

1. Windows desktop installer
2. Remote-SSH VSIX files
3. VS Code Server payload(s) for the exact editor commit
4. Remote-SSH exec CLI payload(s) for the exact editor commit
5. SHA256 manifest

That keeps package promotion and offline deployment deterministic.

## Commit resolution behavior

The Remote-SSH server payload is tied to the VS Code client commit hash, not merely a marketing version string.

The current packager resolves identity in this order:

1. Explicit `-Commit` (authoritative if supplied)
2. Explicit `-DownloadVsCodeInstaller` or implicit download default when neither installer source flag is supplied
3. `-VsCodeInstallerPath` + installer version lookup against update service
4. `code --version` fallback (including common `code.cmd` shim locations)

If no valid 40-character commit can be determined, packaging fails with a detailed error.

## Server artifact options

The packager supports these server payload IDs:

- `server-linux-x64` (default)
- `server-linux-arm64`

Each selected artifact is downloaded as `vscode-server-<artifact>-<commit>.tar.gz`.

For exec-server mode (default in modern Remote-SSH), matching CLI payloads are also downloaded automatically:

- `server-linux-x64` -> `cli-alpine-x64`
- `server-linux-arm64` -> `cli-alpine-arm64`

CLI payloads are stored as `vscode-cli-<artifact>-<commit>.tar.gz`.

## VSIX handling

If `-VsixDirectory` is omitted, the script defaults to `<repo-root>/staging/vsix`.

By default, the script downloads these extension IDs into `VsixDirectory`:

- `ms-vscode-remote.remote-ssh`
- `ms-vscode.remote-explorer`
- `ms-vscode-remote.remote-ssh-edit`

Use `-VsixExtensionIds` to override this set.

To skip automatic VSIX download and only use pre-existing local VSIX files, set `-VsixExtensionIds @()`.

If the configured VSIX directory does not exist, the script creates it.

If no VSIX files are present after the download step, packaging continues with a warning and produces a bundle containing installer + server payload + scripts/docs/templates.

## Output handling

If `-OutputDirectory` is omitted, the script defaults to `<repo-root>/output/production-YYYYMMDD`.

## Download transport strategy

For installer, VSIX, and server payload downloads, the script uses this order:

1. `aria2c.exe` (parallel segmented download)
2. `Start-BitsTransfer`
3. `Invoke-WebRequest`

This improves performance and resilience versus relying only on `Invoke-WebRequest`.

## Why server preloading is done per-user

Remote-SSH launches its server as the SSH user. The server files live under that user's home directory in `.vscode-server`. A machine-level install does not cover all users.

## Current server placement

Modern Remote-SSH logs commonly reference paths shaped like:

```text
~/.vscode-server/cli/servers/Stable-<commit>/server
```

In exec-server mode, Remote-SSH also expects a per-commit CLI binary at:

```text
~/.vscode-server/code-<commit>
```

The server preload script targets that layout first. It can also create the older:

```text
~/.vscode-server/bin/<commit>
```

layout for compatibility scenarios.

## Validation checklist

After offline install:

1. Confirm `code --version` works on the Windows client.
2. Confirm the Remote-SSH extension appears as installed.
3. Confirm the target user's Linux home directory contains:

```text
~/.vscode-server/cli/servers/Stable-<commit>/server
```

1. Confirm the target user's Linux home directory contains a commit-pinned CLI binary, typically:

```text
~/.vscode-server/code-<commit>
```

- Connect from VS Code using `Remote-SSH: Connect to Host...`.
- If Remote-SSH still tries to download `vscode_cli_*_cli.tar.gz`, verify the expected CLI artifact for that remote architecture was packaged and preloaded.
- If Remote-SSH still tries to download server payloads, verify the commit in the bundle manifest matches the editor client actually running in the air-gapped network.

## Repository-local transient paths

Current repository conventions:

- `staging/` is used for local VSIX staging.
- `output/` is used for generated bundle folders and ZIPs.

Both are intentionally ignored by Git in `.gitignore`.

## Offline installer defaults

The bundled install scripts now support no-parameter execution from the extracted bundle root:

- `./scripts/Install-VSCodeRemoteSshClientOffline.ps1` defaults `BundleRoot` to the parent directory of the script.
- `./scripts/Install-VSCodeRemoteSshServerOffline-Linux.sh` defaults `--bundle-root` to the parent directory of the script and resolves `--commit` from `manifest/bundle-manifest.json`.

## Recommended extension policy

For the first rollout, keep the air-gap set lean:

- Required: Remote - SSH
- Recommended: Remote Explorer
- Recommended: Remote - SSH: Editing Configuration Files

Add more VSIX packages later only when you know their runtime dependencies can also operate offline.
