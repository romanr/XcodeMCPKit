# XcodeMCPProxy

`xcrun mcpbridge` を上流に持つ HTTP MCP リレーサーバーです。  
Codex は `url` 接続に切り替え、承認ダイアログはリレー起動時のみで済む構成を想定しています。

## 使い方

### LaunchAgent で常駐

```
scripts/install.sh
```

停止・削除:

```
scripts/uninstall.sh
```

ログ:

```
~/Library/Logs/XcodeMCPProxy/proxy.log
```

### 手動起動

```
swift run xcode-mcp-proxy --listen 127.0.0.1:8765
```

`xcode` の対象を固定したい場合:

```
swift run xcode-mcp-proxy --xcode-pid 12345
```

## Codex 設定例

`~/.codex/config.toml`:

```
[mcp_servers.xcode]
url = "http://127.0.0.1:8765/mcp"
```

## エンドポイント

- `POST /mcp` (JSON-RPC)
- `GET /mcp/events` (SSE)
- `GET /health`

`Accept: text/event-stream` の `GET` でも SSE として扱います。

## 複数クライアント

クライアントごとに `Mcp-Session-Id` ヘッダを使ってください。  
未指定の場合はサーバーが生成し、レスポンスヘッダ `Mcp-Session-Id` で返します。

## 注意

- バッチ(JSON配列)は上流の応答が配列のときのみサポートします。
- `--session-id` を指定すると上流のセッションIDが固定されます。複数クライアント用途では未指定推奨です。
