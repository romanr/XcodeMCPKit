#!/bin/bash
set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8765}"
LISTEN="${LISTEN:-$HOST:$PORT}"
XCODE_PID="${XCODE_PID:-}"
LAZY_INIT="${LAZY_INIT:-}"

ARGS=(--listen "$LISTEN")
if [[ -n "$XCODE_PID" ]]; then
  ARGS+=(--xcode-pid "$XCODE_PID")
fi
if [[ -n "$LAZY_INIT" ]]; then
  ARGS+=(--lazy-init)
fi

exec swift run xcode-mcp-proxy "${ARGS[@]}"
