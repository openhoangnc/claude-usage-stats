[English](README.md) · **日本語** · [Tiếng Việt](README.vi.md) · [中文](README.zh.md)

# Claude Usage Stats

Claude Code の使用状況をひと目で確認できる、小さな macOS メニューバーアプリです。
`claude /usage` コマンドと同じ数値を、常に表示し続けます。

- **上段** — 現在の**セッション**使用率 %
- **下段** — 現在の**週間（全モデル）**使用率 %
- **クリック** — 3 つのウィンドウ（セッション、週間・全モデル、使用中モデルの週間上限）
  をまとめた詳細パネル。それぞれにプログレスバーと、ローカル時刻およびリセットまでの
  残り時間を示すリセット行が付きます。

![Claude Usage Stats のスクリーンショット](screenshot.png)

2 つのパーセンテージは**使用率の範囲に応じて自動的に色分け**されます。色は明るい／暗い
どちらのメニューバーに対しても **WCAG AAA**（コントラスト比 7:1 以上）を満たすことを
検証済みです。

| 範囲 | < 50 | 50–69 | 70–84 | 85–94 | ≥ 95 |
|------|------|-------|-------|-------|------|
| 色   | 緑 | ライム | ゴールド | オレンジ | 赤 |

## インストール

```bash
curl -fsSL https://raw.githubusercontent.com/openhoangnc/claude-usage-stats/main/install.sh | bash
```

最新のビルド済みリリースをダウンロードして `/Applications` にインストールし、起動します
— Xcode は不要です。（リリースがまだ存在しない場合は、ソースからのビルドにフォール
バックします。その際は Xcode コマンドラインツールが必要です。）メニューから**ログイン時に
起動**を有効にできます（インジケーターをクリック → Launch at Login）。

## アンインストール

```bash
curl -fsSL https://raw.githubusercontent.com/openhoangnc/claude-usage-stats/main/uninstall.sh | bash
```

## 仕組み

このアプリは、ローカルの `claude` CLI ツールから使用上限を取得します。負荷の軽い方法から
順に試します。

1. インタラクティブなログインシェルの `PATH`（`/bin/zsh -ilc`）で `claude` を探します
   （nvm/fnm/volta やカスタムプレフィックスも解決されます）。
2. `claude -p /usage`（ヘッドレス）を実行します。その出力に上限バーが含まれていれば、
   解析して表示し、完了です。
3. 含まれていない場合（最近の CLI バージョンではヘッドレス出力からバーが削除されました）、
   疑似ターミナル上でインタラクティブな `/usage` 画面を操作し、表示されたバーを読み取り、
   会話ターンを開始する前に終了します。そのためディスクには何も保存されず、使用統計にも
   影響しません。

取得は単一実行に制限され（同時に 2 つの `claude` プロセスが動くことはありません）、
使用上限エンドポイントのレート制限は一時的なバックオフとして扱い、エラーにはしません。

Keychain へのアクセスは不要です。アプリが認証情報に触れることはありません。

**初回起動：** `claude` がインストールされ、ログイン済みであれば、追加の権限なしで
そのまま動作します。

**コマンドが見つからない場合：** `claude` コマンドが利用できない場合、アプリはインストール
を促す警告パネルを表示します。

## ソースからビルドしてインストール

自分でビルドしたい場合は、リポジトリをクローンしてインストーラーを実行します。
ローカルのチェックアウトから実行すると、`install.sh` は現在のソースをユニバーサル
バイナリにコンパイルし、アプリを `/Applications` にインストールして起動します
— 何もダウンロードしないため、手元のコードそのものが動作します。

```bash
git clone https://github.com/openhoangnc/claude-usage-stats.git
cd claude-usage-stats
./install.sh
```

起動したら、メニューから**ログイン時に起動**を有効にできます（インジケーターを
クリック → Launch at Login）。

## 必要環境

- macOS 11 以降
- このマシンに `claude`（Claude CLI）がインストールされ、ログイン済みであること
- ビルドには Xcode コマンドラインツール（`swiftc`）

## デバッグ

```bash
# GUI なしで、メニューバー／パネルに表示される内容を出力します。
./ClaudeUsageStats.app/Contents/MacOS/ClaudeUsageStats --selftest

# 実際のビューから README 用スクリーンショットを再生成します。
./ClaudeUsageStats.app/Contents/MacOS/ClaudeUsageStats --screenshot screenshot.png
```

更新は 5 分ごと、およびメニューを開くたびに実行され、エラーが続くとバックオフします。
パネルのフッターにはデータが最後に更新された時刻が表示されます。
