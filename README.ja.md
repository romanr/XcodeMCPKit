# XcodeMCPKit

[English](README.md)

Xcode MCP (mcpbridge) の MCPプロキシ。  
Xcode のダイアログが、プロキシ起動時に一度だけ表示されるよう設計しています。

## クイックスタート

1. プロキシを起動
   ```bash
   xcode-mcp-proxy-server
   ```
2. Xcode の許可ダイアログが出たら **Allow**

## アーキテクチャ

プロセス構成は [アーキテクチャ](Docs/architecture.md) を参照してください。

## インストール

```bash
swift run -c release xcode-mcp-proxy-install
```

既定では `~/.local/bin` に `xcode-mcp-proxy` と `xcode-mcp-proxy-server` がインストールされます。`PATH` に入っていない場合は追加してください。

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

配置先を変更したい場合:

```bash
./.build/release/xcode-mcp-proxy-install --prefix "$HOME/.local"
# または
./.build/release/xcode-mcp-proxy-install --bindir "$HOME/bin"
```

## 使い方

### サーバー

起動方法は「クイックスタート」を参照してください。

#### デフォルト値

- command: `xcrun`
- args: `mcpbridge`
- request timeout: `300` seconds（`0` で無制限）
- max body size: `1048576` bytes
- initialization: eager at startup
- モード: 既定は HTTP。`--stdio` 指定時は STDIO
#### 環境変数

- `MCP_XCODE_PID`（`--xcode-pid` の代替）
- `MCP_XCODE_SESSION_ID`（Xcode MCP セッション ID を固定。通常は不要）
- `MCP_LOG_LEVEL`（ログレベル: trace|debug|info|notice|warning|error|critical）

ログは stderr に出力されます。

#### オプション

| オプション | 説明 |
|-----------|------|
| `--upstream-command cmd` | `mcpbridge` コマンド |
| `--upstream-args a,b,c` | `mcpbridge` 引数（カンマ区切り） |
| `--upstream-arg value` | `mcpbridge` 引数を1つ追加 |
| `--xcode-pid pid` | 対象 Xcode の PID |
| `--session-id id` | Xcode MCP セッション ID（通常は不要） |
| `--max-body-bytes n` | 最大ボディサイズ |
| `--request-timeout seconds` | リクエストタイムアウト（`0` で無制限） |
| `--lazy-init` | 初回リクエストまで初期化を遅延 |
| `--stdio` | STDIO モードで起動 |

### クライアント

#### 設定

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

`xcode-mcp-proxy` が `PATH` にない場合はフルパスを指定してください。

## トラブルシューティング

[Troubleshooting](Docs/troubleshooting.md)

## ライセンス

[LICENSE](LICENSE)
