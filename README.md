# XcodeMCPKit

[日本語](README.ja.md)

An MCP proxy for Xcode MCP (mcpbridge).  
Designed so the Xcode permission dialog appears once when the proxy starts.

## Quick Start

1. Start the proxy
   ```bash
   xcode-mcp-proxy-server
   ```
2. Click **Allow** in Xcode’s permission dialog

## Architecture

See [Architecture](Docs/architecture.md) for the process overview.

## Installation

```bash
swift run -c release xcode-mcp-proxy-install
```

By default, `xcode-mcp-proxy` and `xcode-mcp-proxy-server` are installed to `~/.local/bin`. Add it to your `PATH` if needed.

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

To change the destination:

```bash
./.build/release/xcode-mcp-proxy-install --prefix "$HOME/.local"
# or
./.build/release/xcode-mcp-proxy-install --bindir "$HOME/bin"
```

## Usage

### Server

See Quick Start for how to launch.

#### Defaults

- command: `xcrun`
- args: `mcpbridge`
- listen: `localhost:0` (auto-assign port)
- request timeout: `300` seconds (`0` disables)
- max body size: `1048576` bytes
- initialization: eager at startup
- mode: HTTP by default; STDIO adapter when `--stdio` is set

#### Environment Variables

- `MCP_XCODE_PID` (alternative to `--xcode-pid`)
- `MCP_XCODE_SESSION_ID` (fixes the Xcode MCP session ID; usually not needed)
- `MCP_LOG_LEVEL` (log level: trace|debug|info|notice|warning|error|critical)

Logs are written to stderr.

#### Options

| Option | Description |
|--------|-------------|
| `--upstream-command cmd` | `mcpbridge` command |
| `--upstream-args a,b,c` | `mcpbridge` args (comma-separated) |
| `--upstream-arg value` | Append a single `mcpbridge` arg |
| `--xcode-pid pid` | Xcode PID |
| `--session-id id` | Xcode MCP session ID (usually not needed) |
| `--max-body-bytes n` | Max request body size |
| `--request-timeout seconds` | Request timeout (`0` disables) |
| `--lazy-init` | Delay initialization until first request |
| `--stdio` | Run in STDIO mode |

### Client

#### Config

**Claude Code** (`~/.claude/settings.json`):

```json
{
  "mcpServers": {
    "xcode": {
      "command": "xcode-mcp-proxy"
    }
  }
}
```

**Codex** (`~/.codex/config.toml`):

```toml
[mcp_servers.xcode]
command = "xcode-mcp-proxy"
args = ["--stdio"]
```

If `xcode-mcp-proxy` is not on your `PATH`, use the full path.

#### HTTP/SSE Client Resolution

The proxy writes a discovery file at startup:
`~/Library/Caches/XcodeMCPProxy/endpoint.json`

HTTP/SSE clients should read `url` from this file to locate the active proxy endpoint.

```json
{
  "url": "http://localhost:51234/mcp",
  "host": "localhost",
  "port": 51234,
  "pid": 12345,
  "updatedAt": "2026-02-05T12:34:56Z"
}
```

`host`/`port` are informational, `pid` can be used to check liveness, and `updatedAt` is the last write time (ISO 8601).

#### STDIO Upstream Resolution

When `--stdio` is used without a URL, the upstream is resolved in this order:

1. `XCODE_MCP_PROXY_ENDPOINT` (http/https URL; STDIO adapter override)
2. Discovery file: `~/Library/Caches/XcodeMCPProxy/endpoint.json`
3. Fallback: `http://localhost:8765/mcp`

The server writes the discovery file at startup with the actual port. `XCODE_MCP_PROXY_ENDPOINT` only affects STDIO adapters.

## Troubleshooting

[Troubleshooting](Docs/troubleshooting.md)

## References

- [MCP / Xcode MCP Benchmark Notes](Docs/mcp-benchmark.md)
- [MCP Connection Permission Dialog Investigation](Docs/mcp-permission-dialog-investigation.md)

## License

[LICENSE](LICENSE)
