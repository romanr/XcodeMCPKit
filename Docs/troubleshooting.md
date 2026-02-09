# Troubleshooting

## `mcpbridge` cannot be executed
`xcode-mcp-proxy` spawns `xcrun mcpbridge` as an upstream process.
If it fails:

- Confirm Xcode is installed and selected (`xcode-select -p`).
- Confirm `xcrun mcpbridge -h` works in Terminal.

## `MCP client ... timed out`
Ensure the proxy is running. Increase `startup_timeout_sec` in the client config if needed.

## HTTP/SSE client cannot connect
Ensure the proxy is running. If the server uses an auto-assigned port, check
`~/Library/Caches/XcodeMCPProxy/endpoint.json`. Confirm `pid` is alive and
`updatedAt` is recent; stale data should be ignored.

## STDIO adapter cannot connect
Ensure the HTTP proxy is running.
If the server uses an auto-assigned port, confirm the discovery file exists at
`~/Library/Caches/XcodeMCPProxy/endpoint.json`, or set `XCODE_MCP_PROXY_ENDPOINT`
to the server URL (for example: `http://localhost:9000/mcp`).

## Codex `tools/call` times out after 60 seconds
Increase `tool_timeout_sec` in `~/.codex/config.toml` (this is client-side and separate from the proxy `--request-timeout`).

```toml
[mcp_servers.xcode]
command = "xcode-mcp-proxy"
args = ["--stdio"]
tool_timeout_sec = 300
```

## Codex shows `Transport closed` (then hangs)
If you see an error like:

- `tools/call failed: Transport closed`

it usually means the MCP server process (`xcode-mcp-proxy --stdio`) was terminated while Codex was waiting (often due to the default `tool_timeout_sec` being too short for slow Xcode operations).

- Set `tool_timeout_sec` (see above) to a value that covers the slowest Xcode tool calls you expect.
- Ensure the central proxy (`xcode-mcp-proxy-server`) is running and the discovery file is fresh: `~/Library/Caches/XcodeMCPProxy/endpoint.json`.
- If it keeps happening, restart the local processes:
  - `pkill -f xcode-mcp-proxy`
  - `pkill -f mcpbridge`

## Xcode dialog does not appear
Make sure `--lazy-init` is not set (when enabled, the dialog appears on the first request instead of at startup).

## `session not found`
Ensure the client is using the same session.
