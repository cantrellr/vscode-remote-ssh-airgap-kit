#!/usr/bin/env bash
#
# Install-VSCodeRemoteSshServerOffline-Linux.sh
#
# Purpose:
#   Preload the VS Code Server payload and exec CLI on an air-gapped Linux SSH target.
#
# Intended use:
#   Run as the SAME Linux user that will be used for VS Code Remote-SSH connections.
#
# Example:
#   ./Install-VSCodeRemoteSshServerOffline-Linux.sh \
#     --bundle-root ./vscode-remote-ssh-airgap-bundle \
#     --commit 0958016b2af9f09bb4257e0df4a95e2f90590f9f
#
# Default no-parameter mode:
#   ./Install-VSCodeRemoteSshServerOffline-Linux.sh
#
# In no-parameter mode, the script uses:
#   - bundle root: parent directory of this script
#   - commit: value from ./manifest/bundle-manifest.json
#
# Optional:
#   --include-legacy-bin-layout
#     Also stages the older ~/.vscode-server/bin/<commit> layout.
#
set -euo pipefail

BUNDLE_ROOT=""
COMMIT=""
INCLUDE_LEGACY=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
  printf '[INFO] %s\n' "$*"
}

ok() {
  printf '[ OK ] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  Install-VSCodeRemoteSshServerOffline-Linux.sh \
    [--bundle-root <path>] \
    [--commit <40-char-vscode-commit>] \
    [--include-legacy-bin-layout]

Defaults when omitted:
  --bundle-root: parent directory of this script
  --commit: read from <bundle-root>/manifest/bundle-manifest.json
USAGE
}

detect_vscode_arch() {
  local uname_arch
  local bitness

  uname_arch="$(uname -m)"
  bitness="$(getconf LONG_BIT 2>/dev/null || echo 64)"

  case "$uname_arch" in
    x86_64)
      echo "x64"
      ;;
    armv7l|armv8l)
      echo "armhf"
      ;;
    arm64|aarch64)
      if [[ "$bitness" == "32" ]]; then
        echo "armhf"
      else
        echo "arm64"
      fi
      ;;
    *)
      fail "Unsupported architecture from uname -m: $uname_arch"
      ;;
  esac
}

find_bundle_archive() {
  local file_prefix="$1"
  local commit_lc
  local exact_path
  local fallback_path

  commit_lc="${COMMIT,,}"
  exact_path="$BUNDLE_ROOT/servers/${file_prefix}-${commit_lc}.tar.gz"
  if [[ -f "$exact_path" ]]; then
    echo "$exact_path"
    return 0
  fi

  fallback_path="$(find "$BUNDLE_ROOT/servers" -maxdepth 1 -type f -iname "${file_prefix}-${COMMIT}.tar.gz" | head -n 1 || true)"
  if [[ -n "$fallback_path" && -f "$fallback_path" ]]; then
    echo "$fallback_path"
    return 0
  fi

  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-root)
      BUNDLE_ROOT="${2:-}"
      shift 2
      ;;
    --commit)
      COMMIT="${2:-}"
      shift 2
      ;;
    --include-legacy-bin-layout)
      INCLUDE_LEGACY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

if [[ -z "$BUNDLE_ROOT" ]]; then
  BUNDLE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  log "No --bundle-root provided; defaulting to: $BUNDLE_ROOT"
fi

BUNDLE_ROOT="$(cd "$BUNDLE_ROOT" && pwd)"

if [[ -z "$COMMIT" ]]; then
  MANIFEST_PATH="$BUNDLE_ROOT/manifest/bundle-manifest.json"
  if [[ -f "$MANIFEST_PATH" ]]; then
    COMMIT="$(sed -nE 's/^[[:space:]]*"commit"[[:space:]]*:[[:space:]]*"([0-9a-fA-F]{40})".*/\1/p' "$MANIFEST_PATH" | head -n 1 || true)"
    if [[ -n "$COMMIT" ]]; then
      log "No --commit provided; using commit from manifest: ${COMMIT,,}"
    fi
  fi
fi

[[ -n "$COMMIT" ]] || fail "--commit was not provided and could not be read from $BUNDLE_ROOT/manifest/bundle-manifest.json."
[[ "$COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] || fail "Commit must be a 40-character hexadecimal VS Code commit hash."

if [[ "$(id -u)" -eq 0 ]]; then
  warn "Running as root. Remote-SSH is normally per-user. This will preload /root/.vscode-server unless root is truly your SSH user."
fi

VSCODE_ARCH="$(detect_vscode_arch)"

SERVER_ARTIFACT_CANDIDATES=()
case "$VSCODE_ARCH" in
  x64)
    SERVER_ARTIFACT_CANDIDATES=("server-linux-x64")
    ;;
  arm64)
    SERVER_ARTIFACT_CANDIDATES=("server-linux-arm64")
    ;;
  armhf)
    fail "No armhf server payload is supported by this bundle format. Build and use an arm64 or x64 target bundle."
    ;;
esac

SERVER_ARTIFACT=""
SERVER_ARCHIVE=""
for candidate in "${SERVER_ARTIFACT_CANDIDATES[@]}"; do
  archive_path="$(find_bundle_archive "vscode-server-$candidate" || true)"
  if [[ -n "$archive_path" && -f "$archive_path" ]]; then
    SERVER_ARTIFACT="$candidate"
    SERVER_ARCHIVE="$archive_path"
    break
  fi
done

[[ -n "$SERVER_ARCHIVE" && -f "$SERVER_ARCHIVE" ]] || fail "Matching server archive not found for commit $COMMIT under $BUNDLE_ROOT/servers. Tried: ${SERVER_ARTIFACT_CANDIDATES[*]}"

CLI_ARTIFACT_CANDIDATES=()
if [[ "$VSCODE_ARCH" == "armhf" ]]; then
  CLI_ARTIFACT_CANDIDATES=("cli-linux-armhf")
else
  CLI_ARTIFACT_CANDIDATES=("cli-alpine-$VSCODE_ARCH" "cli-linux-$VSCODE_ARCH")
fi

CLI_ARTIFACT=""
CLI_ARCHIVE=""
for candidate in "${CLI_ARTIFACT_CANDIDATES[@]}"; do
  archive_path="$(find_bundle_archive "vscode-cli-$candidate" || true)"
  if [[ -n "$archive_path" && -f "$archive_path" ]]; then
    CLI_ARTIFACT="$candidate"
    CLI_ARCHIVE="$archive_path"
    break
  fi
done

log "Using bundle root : $BUNDLE_ROOT"
log "Using commit      : ${COMMIT,,}"
log "Detected arch     : $VSCODE_ARCH"
log "Server artifact   : $SERVER_ARTIFACT"
log "Server archive    : $SERVER_ARCHIVE"
if [[ -n "$CLI_ARCHIVE" ]]; then
  log "CLI artifact      : $CLI_ARTIFACT"
  log "CLI archive       : $CLI_ARCHIVE"
else
  warn "No matching CLI archive found in bundle. Remote-SSH may still attempt to download vscode_cli_*_cli.tar.gz at first connect."
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log "Extracting server payload into temporary workspace..."
tar -xzf "$SERVER_ARCHIVE" -C "$TMP_DIR"

# Determine archive payload root robustly. Some tarballs include a top-level directory; others may not.
PAYLOAD_ROOT="$TMP_DIR"
shopt -s nullglob dotglob
entries=("$TMP_DIR"/*)
shopt -u dotglob
if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
  PAYLOAD_ROOT="${entries[0]}"
fi
shopt -u nullglob

[[ -d "$PAYLOAD_ROOT" ]] || fail "Unable to determine extracted payload root."

CURRENT_BASE="$HOME/.vscode-server/cli/servers/Stable-${COMMIT,,}"
CURRENT_TARGET="$CURRENT_BASE/server"
LEGACY_TARGET="$HOME/.vscode-server/bin/${COMMIT,,}"
CLI_TARGET=""

if [[ -n "$CLI_ARCHIVE" ]]; then
  log "Preloading Remote-SSH exec CLI..."
  CLI_TMP_DIR="$TMP_DIR/cli"
  rm -rf "$CLI_TMP_DIR"
  mkdir -p "$CLI_TMP_DIR"
  tar -xzf "$CLI_ARCHIVE" -C "$CLI_TMP_DIR"

  CLI_SOURCE="$(find "$CLI_TMP_DIR" -maxdepth 2 -type f | head -n 1 || true)"
  [[ -n "$CLI_SOURCE" && -f "$CLI_SOURCE" ]] || fail "CLI archive '$CLI_ARCHIVE' did not contain a CLI executable."

  CLI_BASENAME="$(basename "$CLI_SOURCE")"
  CLI_TARGET="$HOME/.vscode-server/${CLI_BASENAME}-${COMMIT,,}"

  mkdir -p "$HOME/.vscode-server"
  cp -f "$CLI_SOURCE" "$CLI_TARGET"
  chmod 700 "$CLI_TARGET" || true
  ok "Exec CLI populated: $CLI_TARGET"
fi

log "Preloading current Remote-SSH server layout..."
rm -rf "$CURRENT_TARGET"
mkdir -p "$CURRENT_TARGET"
cp -a "$PAYLOAD_ROOT"/. "$CURRENT_TARGET"/
chmod -R u+rwX,go-rwx "$CURRENT_BASE" || true
touch "$CURRENT_BASE/.airgap-preloaded"
ok "Current layout populated: $CURRENT_TARGET"

if [[ "$INCLUDE_LEGACY" -eq 1 ]]; then
  log "Preloading legacy Remote-SSH server layout..."
  rm -rf "$LEGACY_TARGET"
  mkdir -p "$LEGACY_TARGET"
  cp -a "$PAYLOAD_ROOT"/. "$LEGACY_TARGET"/
  chmod -R u+rwX,go-rwx "$LEGACY_TARGET" || true
  touch "$LEGACY_TARGET/.airgap-preloaded"
  ok "Legacy layout populated: $LEGACY_TARGET"
fi

if [[ -x "$CURRENT_TARGET/bin/code-server" ]]; then
  ok "Validation passed: code-server launcher found."
elif [[ -x "$CURRENT_TARGET/node" ]]; then
  ok "Validation passed: node runtime found."
else
  warn "Payload copied, but expected launch files were not detected. Review archive contents before connecting."
fi

cat <<EOF_SUMMARY

Offline VS Code Server preload complete.

Expected current path:
  $CURRENT_TARGET

Next step:
  From the air-gapped Windows workstation, open VS Code and run:
    Remote-SSH: Connect to Host...

If Remote-SSH still attempts to download a server payload, verify that:
  1. The VS Code client commit equals: ${COMMIT,,}
  2. The user connecting over SSH is: $(id -un)
  3. The staged server artifact matches remote arch ($VSCODE_ARCH): $SERVER_ARTIFACT
  4. The exec CLI exists at: ${CLI_TARGET:-"<not staged from bundle>"}
EOF_SUMMARY
