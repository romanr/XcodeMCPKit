#!/bin/bash
set -euo pipefail

PLIST_DEST="$HOME/Library/LaunchAgents/com.kn.XcodeMCPProxy.plist"
INSTALL_DIR="$HOME/Library/Application Support/XcodeMCPProxy"

launchctl bootout "gui/$UID" "$PLIST_DEST" >/dev/null 2>&1 || true
rm -f "$PLIST_DEST"
rm -rf "$INSTALL_DIR"
