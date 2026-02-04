# XcodeMCPProxy

[日本語](README.ja.md)

An MCP proxy that exposes Xcode’s `mcpbridge` over HTTP(S) + SSE.  
The Xcode permission dialog appears once when the proxy starts.

## Quick Start

1. Start the proxy
   ```bash
   scripts/run_proxy.sh
   ```
2. Point your client to `http://127.0.0.1:8765/mcp`
3. Click **Allow** in Xcode’s permission dialog

## Features

- `mcpbridge` runs as a **single process**
- Multi-client support via `Mcp-Session-Id`
- JSON-RPC over HTTP + SSE (Streamable MCP)

## Usage

### Run Script

```bash
scripts/run_proxy.sh
```

Optional environment variables:

- `HOST` (default: `127.0.0.1`)
- `PORT` (default: `8765`)
- `LISTEN` (overrides host/port)
- `XCODE_PID` (optional)
- `LAZY_INIT` (set to any value to pass `--lazy-init`)

### Manual Start

```bash
swift run xcode-mcp-proxy --listen 127.0.0.1:8765
```

The proxy initializes the Xcode MCP session at startup so the permission dialog appears immediately. Use `--lazy-init` to defer initialization until the first client request.

To target a specific Xcode process:

```bash
swift run xcode-mcp-proxy --xcode-pid 12345
```

## Defaults

- Listen address: `127.0.0.1:8765`
- `mcpbridge` command: `xcrun`
- `mcpbridge` args: `mcpbridge`
- Request timeout: `30` seconds
- Max body size: `1048576` bytes
- Initialization: eager at startup

Environment variables:

- `MCP_XCODE_PID` (alternative to `--xcode-pid`)
- `MCP_XCODE_SESSION_ID` (fix the Xcode MCP session id)

## Options

| Option | Description |
|--------|-------------|
| `--listen host:port` | Listen address |
| `--host host` | Listen host |
| `--port port` | Listen port |
| `--upstream-command cmd` | `mcpbridge` command |
| `--upstream-args a,b,c` | `mcpbridge` args (comma-separated) |
| `--upstream-arg value` | Append a single `mcpbridge` arg |
| `--xcode-pid pid` | Xcode PID |
| `--session-id id` | Xcode MCP session id |
| `--max-body-bytes n` | Max request body size |
| `--request-timeout seconds` | Request timeout |
| `--lazy-init` | Delay initialization until first request |

## Client Config

**Claude Code** (`~/.claude/settings.json`):

```json
{ "mcpServers": { "xcode": { "url": "http://127.0.0.1:8765/mcp" } } }
```

**Codex** (`~/.codex/config.toml`):

```toml
[mcp_servers.xcode]
url = "http://127.0.0.1:8765/mcp"
```

## Endpoints

- `POST /mcp` (JSON-RPC; responds with JSON or SSE and returns `Mcp-Session-Id`)
- `GET /mcp` (SSE; requires `Mcp-Session-Id` and `Accept: text/event-stream`)
- `GET /events`, `GET /mcp/events` (SSE aliases)
- `DELETE /mcp` (close session)
- `GET /health`

## Sessions & Multiple Clients

- Use a **unique `Mcp-Session-Id` per client**.
- If `initialize` is sent without `Mcp-Session-Id`, the proxy generates one and returns it in the response header.
- For SSE, include `Mcp-Session-Id` on `GET /mcp`.

## Troubleshooting

- `MCP client ... timed out`  
  Ensure the proxy is running, then increase `startup_timeout_sec` if needed.

- Permission dialog does not appear  
  If `--lazy-init` is enabled, the dialog appears on the first request instead of startup.

- `session not found`  
  Verify the `Mcp-Session-Id` matches the session that was initialized.

## License

[LICENSE](LICENSE)
