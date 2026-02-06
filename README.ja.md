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

`xcrun mcpbridge` を削除して、`xcode-mcp-proxy` を登録します:

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
- upstream processes: `1`（増やすと `mcpbridge` を複数プロセス起動）
- listen: `localhost:0`（自動割り当て）
- request timeout: `300` seconds（`0` で無制限）
- max body size: `1048576` bytes
- initialization: eager at startup
- モード: 既定は HTTP。`--stdio` 指定時は STDIO
#### 環境変数

- `MCP_XCODE_PID`（`--xcode-pid` の代替）
- `MCP_XCODE_SESSION_ID`（Xcode MCP セッション ID を固定。通常は不要）
- `MCP_LOG_LEVEL`（ログレベル: trace|debug|info|notice|warning|error|critical）

ログは stderr に出力されます。

Note: `--upstream-processes` > 1 を使う場合、`--session-id` / `MCP_XCODE_SESSION_ID` でセッション ID を固定すると、Xcode の許可ダイアログを減らせる場合があります。

#### オプション

| オプション | 説明 |
|-----------|------|
| `--upstream-command cmd` | `mcpbridge` コマンド |
| `--upstream-args a,b,c` | `mcpbridge` 引数（カンマ区切り） |
| `--upstream-arg value` | `mcpbridge` 引数を1つ追加 |
| `--upstream-processes n` | upstream `mcpbridge` を `n` プロセス起動（default: 1, max: 10） |
| `--xcode-pid pid` | 対象 Xcode の PID |
| `--session-id id` | Xcode MCP セッション ID（通常は不要） |
| `--max-body-bytes n` | 最大ボディサイズ |
| `--request-timeout seconds` | リクエストタイムアウト（`0` で無制限） |
| `--lazy-init` | 初回リクエストまで初期化を遅延 |
| `--stdio` | STDIO モードで起動 |

## トラブルシューティング

[Troubleshooting](Docs/troubleshooting.md)

## 参考資料

- [MCP / Xcode MCP Benchmark Notes](Docs/mcp-benchmark.md)
- [MCP Connection Permission Dialog Investigation](Docs/mcp-permission-dialog-investigation.md)

## ライセンス

[LICENSE](LICENSE)
