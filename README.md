# claude-recipes

ユーザー単位の Claude Code 設定（カスタムコマンドなど）を管理するリポジトリ。

## セットアップ

```bash
git clone https://github.com/nikifutaki/claude-recipes.git
cd claude-recipes
./install.sh
```

`config/` 内の各ファイルが `~/.claude/` にシンボリックリンクされます。
既存ファイルがある場合は `.backup.<timestamp>` としてバックアップされます。

## アンインストール

```bash
./uninstall.sh
```

シンボリックリンクを削除します。レビューアーティファクト（`.claude/reviews/`）の削除は別途:

```bash
rm -rf .claude/reviews/
```

## コマンド一覧

| コマンド | 説明 |
|----------|------|
| `/review-fix` | PR に対する AI レビューワークフロー。Reviewer / Coordinator / Implementer の 3 ロールで多ラウンドレビューサイクルを回す |

## リポジトリ構成

```
config/
└── commands/          # カスタムスラッシュコマンド → ~/.claude/commands/
    └── review-fix.md
install.sh             # config/ → ~/.claude/ へシンボリックリンクを作成
uninstall.sh           # シンボリックリンクの削除
```

## 設定の追加

`config/` 以下にファイルを追加して `./install.sh` を実行するだけです。
ディレクトリ構造がそのまま `~/.claude/` にマッピングされます。

```bash
# 例: 新しいコマンドを追加
vim config/commands/my-command.md
./install.sh
```
