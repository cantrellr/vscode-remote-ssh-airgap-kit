# Implementation Notes

## Bundle strategy

The workflow intentionally treats VS Code as a release bundle:

1. Windows desktop installer
2. Remote-SSH VSIX files
3. VS Code Server tarball for the exact editor commit
4. SHA256 manifest

That keeps package promotion and offline deployment deterministic.

## Why the commit hash matters

The Remote-SSH server payload is tied to the VS Code client commit hash, not merely a marketing version string. The packager runs `code --version`, captures the commit line, and downloads the matching server tarball from the VS Code update service.

## Why server preloading is done per-user

Remote-SSH launches its server as the SSH user. The server files live under that user's home directory in `.vscode-server`. A machine-level install does not cover all users.

## Current server placement

Modern Remote-SSH logs commonly reference paths shaped like:

```text
~/.vscode-server/cli/servers/Stable-<commit>/server
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

4. Connect from VS Code using `Remote-SSH: Connect to Host...`.
5. If Remote-SSH still tries to download server payloads, verify the commit in the bundle manifest matches the editor client actually running in the air-gapped network.

## Recommended extension policy

For the first rollout, keep the air-gap set lean:

- Required: Remote - SSH
- Recommended: Remote Explorer
- Recommended: Remote - SSH: Editing Configuration Files

Add more VSIX packages later only when you know their runtime dependencies can also operate offline.
