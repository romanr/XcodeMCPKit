# XcodeMCPProxy

`xcrun mcpbridge` を上流に持つ HTTP MCP リレーサーバーです。

英語版（正本）: [README.md](README.md)

## 使い方

### 手動起動

```
swift run xcode-mcp-proxy --listen 127.0.0.1:8765
```

既定では上流の Xcode MCP セッションを起動時に初期化し、Xcode の許可ダイアログがプロキシ起動時に出るようにしています。必要なら `--lazy-init` で初期化を遅延できます。

Xcode の対象を固定する場合:

```
swift run xcode-mcp-proxy --xcode-pid 12345
```

### 便利スクリプト

```
scripts/run_proxy.sh
```

任意の環境変数:

- `HOST` (既定: `127.0.0.1`)
- `PORT` (既定: `8765`)
- `LISTEN` (host/port を上書き)
- `XCODE_PID` (任意)
- `LAZY_INIT` (`--lazy-init` を付与)

## Codex 設定例

`~/.codex/config.toml`:

```
[mcp_servers.xcode]
url = "http://127.0.0.1:8765/mcp"
```

## エンドポイント

- `POST /mcp` (JSON-RPC。JSON か SSE で応答し `Mcp-Session-Id` を返します)
- `GET /mcp` (SSE。`Mcp-Session-Id` と `Accept: text/event-stream` が必要)
- `GET /events`, `GET /mcp/events` (SSE の別名)
- `DELETE /mcp` (セッション終了)
- `GET /health`

## 複数クライアント

上流の `mcpbridge` は 1 回だけ起動し共有します。  
セッションごとに `id` を名前空間化するため、`Mcp-Session-Id` をクライアントごとに分けてください。  
未指定の場合はサーバーが生成し、レスポンスヘッダ `Mcp-Session-Id` で返します。

## ライセンス

MIT。詳細は [LICENSE](LICENSE) を参照してください。
