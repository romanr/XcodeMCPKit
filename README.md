# XcodeMCPProxy

An HTTP MCP proxy server that bridges to Xcode's MCP tools via `xcrun mcpbridge`.

Japanese documentation: [README.ja.md](README.ja.md)

## Usage

### Manual run

```
swift run xcode-mcp-proxy --listen 127.0.0.1:8765
```

By default the proxy eagerly initializes the upstream Xcode MCP session so the Xcode permission dialog appears when the proxy starts. Use `--lazy-init` to defer initialization until the first client request.

To target a specific Xcode process:

```
swift run xcode-mcp-proxy --xcode-pid 12345
```

### Convenience script

```
scripts/run_proxy.sh
```

Optional environment variables:

- `HOST` (default: `127.0.0.1`)
- `PORT` (default: `8765`)
- `LISTEN` (overrides host/port)
- `XCODE_PID` (optional)
- `LAZY_INIT` (set to any value to pass `--lazy-init`)

## Codex config

`~/.codex/config.toml`:

```
[mcp_servers.xcode]
url = "http://127.0.0.1:8765/mcp"
```

## Endpoints

- `POST /mcp` (JSON-RPC; responds with JSON or SSE and returns `Mcp-Session-Id`)
- `GET /mcp` (SSE; requires `Mcp-Session-Id` and `Accept: text/event-stream`)
- `GET /events`, `GET /mcp/events` (aliases for SSE)
- `DELETE /mcp` (close session)
- `GET /health`

## Multiple clients

The proxy runs a single upstream `mcpbridge` process and namespaces `id` per session.  
Clients should send a unique `Mcp-Session-Id` header. If omitted, the proxy will generate one and return it in the response header.

## License

MIT. See [LICENSE](LICENSE).
