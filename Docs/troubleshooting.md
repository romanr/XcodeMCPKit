# Troubleshooting

## `mcpbridge` cannot be executed
Quote from Apple documentation:

> In Terminal, use the xcrun mcpbridge command to configure the agentic coding tool to use Xcode Tools.

Reference: [Giving external agentic coding tools access to Xcode](https://developer.apple.com/documentation/Xcode/giving-agentic-coding-tools-access-to-xcode#Configure-external-coding-tools-to-use-the-MCP-server)

```bash
claude mcp add --transport stdio xcode -- xcrun mcpbridge
codex mcp add xcode -- xcrun mcpbridge
```

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

## Xcode dialog does not appear
Make sure `--lazy-init` is not set (when enabled, the dialog appears on the first request instead of at startup).

## `session not found`
Ensure the client is using the same session.
