# XcodeMCPKit

[English](README.md)

Xcode MCP (mcpbridge) の MCPプロキシ。  
Xcode のダイアログが、プロキシ起動時に一度だけ表示されるよう設計しています。

## クイックスタート

1. プロキシサーバーを起動
   ```bash
   xcode-mcp-proxy-server
   ```
2. Xcode の許可ダイアログが出たら **Allow**

## アーキテクチャ

プロセス構成は [アーキテクチャ](Docs/architecture.md) を参照してください。

## インストール

### 1. バイナリをインストール

#### ソースからビルドしてインストール

```bash
swift run -c release xcode-mcp-proxy-install
```

#### GitHub Releases からインストール

各リリースタグ（`v*`）では、次のファイルを公開します:

- `xcode-mcp-proxy.tar.gz`（universal binary）
- `xcode-mcp-proxy-darwin-arm64.tar.gz`
- `xcode-mcp-proxy-darwin-x86_64.tar.gz`
- `SHA256SUMS.txt`

例:

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

プラットフォーム別アーカイブを使いたい場合は、次のいずれかを選べます:

- `xcode-mcp-proxy.tar.gz`: universal binary
- `xcode-mcp-proxy-darwin-arm64.tar.gz`: Apple Silicon
- `xcode-mcp-proxy-darwin-x86_64.tar.gz`: Intel

#### 任意: インストール先を変更

```bash
./.build/release/xcode-mcp-proxy-install --prefix "$HOME/.local"
# または
./.build/release/xcode-mcp-proxy-install --bindir "$HOME/bin"
```

### 2. インストール先を `PATH` に追加

既定では `~/.local/bin` に `xcode-mcp-proxy` と `xcode-mcp-proxy-server` がインストールされます。

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### 3. MCP クライアントに登録

`xcrun mcpbridge` を削除して、用途に応じて以下のいずれかを登録します:

#### Codex

```bash
codex mcp remove xcode
# 推奨: Streamable HTTP
codex mcp add xcode --url http://localhost:8765/mcp

# 代替: STDIO
codex mcp add xcode -- xcode-mcp-proxy
```

#### Claude Code

```bash
claude mcp remove xcode
claude mcp add --transport stdio xcode -- xcode-mcp-proxy
```

## 使い方

### プロキシサーバー: `xcode-mcp-proxy-server`

起動方法は「クイックスタート」を参照してください。

#### デフォルト値

- command: `xcrun`
- args: `mcpbridge`
- upstream processes: `1`（増やすと `mcpbridge` を複数プロセス起動）
- listen: `localhost:8765`
- request timeout: `300` seconds（`0` で無制限）
- max body size: `1048576` bytes
- initialization: eager at startup
- discovery: `~/Library/Caches/XcodeMCPProxy/endpoint.json`
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
| `--force-restart` | listen ポートが使用中の場合、既存の `xcode-mcp-proxy-server` を終了して起動し直す |

### アダプタ: `xcode-mcp-proxy`

#### オプション

| オプション | 説明 |
|-----------|------|
| `--request-timeout seconds` | HTTP リクエストタイムアウト（`0` で無制限） |
| `--url url` | 上流 URL を明示（例: `http://localhost:9000/mcp`） |

#### 環境変数

- `XCODE_MCP_PROXY_ENDPOINT`（上流 URL を上書き。`--url` が優先）

## トラブルシューティング

[Troubleshooting](Docs/troubleshooting.md)

## 参考資料

- [MCP / Xcode MCP Benchmark Notes](Docs/mcp-benchmark.md)
- [MCP Connection Permission Dialog Investigation](Docs/mcp-permission-dialog-investigation.md)

## ライセンス

[LICENSE](LICENSE)
