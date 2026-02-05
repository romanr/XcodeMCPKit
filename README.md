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
- request timeout: `300` seconds (`0` disables)
- max body size: `1048576` bytes
- initialization: eager at startup
- mode: HTTP by default; STDIO when `--stdio` is set

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

## Troubleshooting

[Troubleshooting](Docs/troubleshooting.md)

## License

[LICENSE](LICENSE)
