#!/usr/bin/env bash
#
# Install-VSCodeRemoteSshServerOffline-Linux.sh
#
# Purpose:
#   Preload the VS Code Server payload on an air-gapped Linux SSH target.
#
# Intended use:
#   Run as the SAME Linux user that will be used for VS Code Remote-SSH connections.
#
# Example:
#   ./Install-VSCodeRemoteSshServerOffline-Linux.sh \
#     --bundle-root ./vscode-remote-ssh-airgap-bundle \
#     --commit 0958016b2af9f09bb4257e0df4a95e2f90590f9f
#
# Optional:
#   --include-legacy-bin-layout
#     Also stages the older ~/.vscode-server/bin/<commit> layout.
#
set -euo pipefail

BUNDLE_ROOT=""
COMMIT=""
INCLUDE_LEGACY=0

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
    --bundle-root <path> \
    --commit <40-char-vscode-commit> \
    [--include-legacy-bin-layout]
USAGE
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

[[ -n "$BUNDLE_ROOT" ]] || fail "--bundle-root is required."
[[ -n "$COMMIT" ]] || fail "--commit is required."
[[ "$COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] || fail "Commit must be a 40-character hexadecimal VS Code commit hash."

if [[ "$(id -u)" -eq 0 ]]; then
  warn "Running as root. Remote-SSH is normally per-user. This will preload /root/.vscode-server unless root is truly your SSH user."
fi

BUNDLE_ROOT="$(cd "$BUNDLE_ROOT" && pwd)"
SERVER_ARCHIVE="$BUNDLE_ROOT/servers/vscode-server-server-linux-x64-${COMMIT,,}.tar.gz"

if [[ ! -f "$SERVER_ARCHIVE" ]]; then
  # Try case-insensitive / alternative lookup for defensive handling.
  SERVER_ARCHIVE="$(find "$BUNDLE_ROOT/servers" -maxdepth 1 -type f -iname "vscode-server-server-linux-x64-${COMMIT}.tar.gz" | head -n 1 || true)"
fi

[[ -n "$SERVER_ARCHIVE" && -f "$SERVER_ARCHIVE" ]] || fail "Matching Linux x64 server archive not found for commit $COMMIT under $BUNDLE_ROOT/servers."

log "Using bundle root : $BUNDLE_ROOT"
log "Using commit      : ${COMMIT,,}"
log "Using archive     : $SERVER_ARCHIVE"

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
  3. The server archive was staged for Linux x64
EOF_SUMMARY
