# XcodeMCPKit

[日本語](README.ja.md)

An MCP proxy for Xcode MCP (mcpbridge).  
Designed so the Xcode permission dialog appears once when the proxy starts.

## Quick Start

1. Start the proxy server
   ```bash
   xcode-mcp-proxy-server
   ```
2. Click **Allow** in Xcode’s permission dialog

## Architecture

See [Architecture](Docs/architecture.md) for the process overview.

## Installation

### 1. Install the binaries

#### Build from source

```bash
swift run -c release xcode-mcp-proxy-install
```

#### Install from GitHub Releases

Each release tag (`v*`) publishes:

- `xcode-mcp-proxy.tar.gz` (universal binary)
- `xcode-mcp-proxy-darwin-arm64.tar.gz`
- `xcode-mcp-proxy-darwin-x86_64.tar.gz`
- `SHA256SUMS.txt`

Example:

```bash
VERSION=v0.1.0
BASE_URL="https://github.com/lynnswap/XcodeMCPKit/releases/download/${VERSION}"

ARCHIVE="xcode-mcp-proxy.tar.gz"
curl -fL -O "${BASE_URL}/${ARCHIVE}"
curl -fL -O "${BASE_URL}/SHA256SUMS.txt"
grep "  ${ARCHIVE}\$" SHA256SUMS.txt | shasum -a 256 -c

tar -xzf "${ARCHIVE}"
mkdir -p "${HOME}/.local/bin"
cp bin/* "${HOME}/.local/bin/"
chmod +x "${HOME}/.local/bin/xcode-mcp-proxy" \
         "${HOME}/.local/bin/xcode-mcp-proxy-server" \
         "${HOME}/.local/bin/xcode-mcp-proxy-install"
```

If you prefer a platform-specific archive, choose one of:

- `xcode-mcp-proxy.tar.gz`: universal binary
- `xcode-mcp-proxy-darwin-arm64.tar.gz`: Apple Silicon
- `xcode-mcp-proxy-darwin-x86_64.tar.gz`: Intel

#### Optional: change the installation destination

```bash
./.build/release/xcode-mcp-proxy-install --prefix "$HOME/.local"
# or
./.build/release/xcode-mcp-proxy-install --bindir "$HOME/bin"
```

### 2. Add the install directory to your `PATH`

By default, `xcode-mcp-proxy` and `xcode-mcp-proxy-server` are installed to `~/.local/bin`.

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### 3. Register the proxy in your MCP client

Replace `xcrun mcpbridge` with one of the following:

#### Codex

```bash
codex mcp remove xcode
# Recommended: Streamable HTTP
codex mcp add xcode --url http://localhost:8765/mcp

# Alternative: STDIO
codex mcp add xcode -- xcode-mcp-proxy
```

#### Claude Code

```bash
claude mcp remove xcode
claude mcp add --transport stdio xcode -- xcode-mcp-proxy
```

## Usage

### Proxy Server: `xcode-mcp-proxy-server`

See Quick Start for how to launch.

#### Defaults

- command: `xcrun`
- args: `mcpbridge`
- upstream processes: `1` (spawns multiple `mcpbridge` processes when increased)
- listen: `localhost:8765`
- request timeout: `300` seconds (`0` disables)
- max body size: `1048576` bytes
- initialization: eager at startup
- discovery: `~/Library/Caches/XcodeMCPProxy/endpoint.json`

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
| `--force-restart` | If the listen port is in use, terminate an existing `xcode-mcp-proxy-server` and restart |

### Adapter: `xcode-mcp-proxy`

#### Options

| Option | Description |
|--------|-------------|
| `--request-timeout seconds` | HTTP request timeout (`0` disables) |
| `--url url` | Explicit upstream URL (example: `http://localhost:9000/mcp`) |

#### Environment Variables

- `XCODE_MCP_PROXY_ENDPOINT` (override upstream URL; `--url` takes precedence)

## Troubleshooting

[Troubleshooting](Docs/troubleshooting.md)

## References

- [MCP / Xcode MCP Benchmark Notes](Docs/mcp-benchmark.md)
- [MCP Connection Permission Dialog Investigation](Docs/mcp-permission-dialog-investigation.md)

## License

[LICENSE](LICENSE)
