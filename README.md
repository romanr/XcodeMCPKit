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

Replace `xcrun mcpbridge` with `xcode-mcp-proxy`:

**Codex**

```bash
codex mcp remove xcode
codex mcp add xcode -- xcode-mcp-proxy --stdio
```

**Claude Code**

```bash
claude mcp remove xcode
claude mcp add --transport stdio xcode -- xcode-mcp-proxy --stdio
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
- upstream processes: `1` (spawns multiple `mcpbridge` processes when increased)
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

Note: when using `--upstream-processes` > 1, fixing the session id via `--session-id` / `MCP_XCODE_SESSION_ID` can help reduce permission dialog prompts in Xcode.

#### Options

| Option | Description |
|--------|-------------|
| `--upstream-command cmd` | `mcpbridge` command |
| `--upstream-args a,b,c` | `mcpbridge` args (comma-separated) |
| `--upstream-arg value` | Append a single `mcpbridge` arg |
| `--upstream-processes n` | Spawn `n` upstream `mcpbridge` processes (default: 1, max: 10) |
| `--xcode-pid pid` | Xcode PID |
| `--session-id id` | Xcode MCP session ID (usually not needed) |
| `--max-body-bytes n` | Max request body size |
| `--request-timeout seconds` | Request timeout (`0` disables) |
| `--lazy-init` | Delay initialization until first request |
| `--stdio` | Run in STDIO mode |

## Troubleshooting

[Troubleshooting](Docs/troubleshooting.md)

## References

- [MCP / Xcode MCP Benchmark Notes](Docs/mcp-benchmark.md)
- [MCP Connection Permission Dialog Investigation](Docs/mcp-permission-dialog-investigation.md)

## License

[LICENSE](LICENSE)
