#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_NAME="xcode-mcp-proxy"
BUILD_DIR="$ROOT/.build/release"
INSTALL_DIR="$HOME/Library/Application Support/XcodeMCPProxy/bin"
LOG_DIR="$HOME/Library/Logs/XcodeMCPProxy"
PLIST_SRC="$ROOT/LaunchAgents/com.kn.XcodeMCPProxy.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.kn.XcodeMCPProxy.plist"

swift build -c release

mkdir -p "$INSTALL_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"
cp "$BUILD_DIR/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk 'NR==1 {print $2}')"
if [[ -n "${IDENTITY:-}" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$INSTALL_DIR/$BIN_NAME"
else
  codesign --force --sign - "$INSTALL_DIR/$BIN_NAME"
fi

sed "s|__BIN_PATH__|$INSTALL_DIR/$BIN_NAME|g; s|__LOG_DIR__|$LOG_DIR|g" "$PLIST_SRC" > "$PLIST_DEST"

launchctl bootout "gui/$UID" "$PLIST_DEST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID" "$PLIST_DEST"
launchctl kickstart -k "gui/$UID/com.kn.XcodeMCPProxy"
