# XcodeMCPProxy Architecture

## Summary
- `xcode-mcp-proxy-server` runs as the proxy server (HTTP/SSE; spawns `xcrun mcpbridge`).
- HTTP-capable MCP clients connect directly to the proxy server (default: `http://localhost:8765/mcp`).
- `xcode-mcp-proxy` runs as a STDIO adapter for clients that require STDIO, forwarding to the proxy server over HTTP/SSE.

## Diagrams

### Proxy Server (HTTP/SSE)
```mermaid
flowchart LR
  subgraph Clients["MCP clients (multiple)"]
    direction TB
    clientA(["Client A"])
    clientB(["Client B"])
    clientN(["Client N"])
  end
  proxy["xcode-mcp-proxy-server<br/>HTTP/SSE"]
  subgraph Upstreams["Upstream (mcpbridge pool)"]
    direction TB
    upstream1(["xcrun mcpbridge #1<br/>stdio JSON-RPC"])
    upstream2(["xcrun mcpbridge #2<br/>stdio JSON-RPC"])
    upstreamN(["xcrun mcpbridge #N<br/>stdio JSON-RPC"])
  end
  xcode["Xcode MCP server"]

  clientA -->|HTTP POST / SSE| proxy
  clientB -->|HTTP POST / SSE| proxy
  clientN -->|HTTP POST / SSE| proxy
  proxy -->|stdio JSON-RPC| upstream1
  proxy -->|stdio JSON-RPC| upstream2
  proxy -->|stdio JSON-RPC| upstreamN
  upstream1 <--> |MCP bridge| xcode
  upstream2 <--> |MCP bridge| xcode
  upstreamN <--> |MCP bridge| xcode
```

### STDIO Adapter (Optional)
```mermaid
flowchart LR
  subgraph A["Client Process A"]
    clientA(["Codex / Claude Code A"])
    adapterA["xcode-mcp-proxy A<br/>STDIO adapter"]
    clientA -->|NDJSON over STDIO| adapterA
  end

  subgraph B["Client Process B"]
    clientB(["Codex / Claude Code B"])
    adapterB["xcode-mcp-proxy B<br/>STDIO adapter"]
    clientB -->|NDJSON over STDIO| adapterB
  end

  proxy["xcode-mcp-proxy-server<br/>HTTP/SSE"]
  subgraph Upstreams["Upstream (mcpbridge pool)"]
    direction TB
    upstream1(["xcrun mcpbridge #1<br/>stdio JSON-RPC"])
    upstream2(["xcrun mcpbridge #2<br/>stdio JSON-RPC"])
    upstreamN(["xcrun mcpbridge #N<br/>stdio JSON-RPC"])
  end
  xcode["Xcode MCP server"]

  adapterA -->|HTTP POST / SSE| proxy
  adapterB -->|HTTP POST / SSE| proxy
  proxy -->|stdio JSON-RPC| upstream1
  proxy -->|stdio JSON-RPC| upstream2
  proxy -->|stdio JSON-RPC| upstreamN
  upstream1 <--> |MCP bridge| xcode
  upstream2 <--> |MCP bridge| xcode
  upstreamN <--> |MCP bridge| xcode
```

## Ports and Addressing
- `xcode-mcp-proxy-server` binds to `localhost:8765` by default (override via `--listen` / `--host` / `--port`, or env `LISTEN` / `HOST` / `PORT`).
- The proxy server writes the resolved endpoint to `~/Library/Caches/XcodeMCPProxy/endpoint.json`.
- `xcode-mcp-proxy` (STDIO adapter) resolves the upstream in this order:
  - `XCODE_MCP_PROXY_ENDPOINT`
  - discovery file (`~/Library/Caches/XcodeMCPProxy/endpoint.json`)
- default (`http://localhost:8765/mcp`)
