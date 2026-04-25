# Parallel review

PR の差分を 5 つの reviewer エージェントが独立に並列レビューし、重複指摘をマージ・多数決で集約してコンソールに出力する。

## Usage

```
/parallel-review <PR番号>
```

- `<PR番号>`: 必須。正の整数（`^[1-9][0-9]*$`）。前後の ASCII 空白は trim する。
- 不正な引数は即エラー終了する。

## Flow

1. **Preflight** — PR 番号を検証し、`gh pr view <PR番号>` で PR の存在と差分の有無を確認する。差分が空なら `No diff to review.` と出して終了。
2. **並列レビュー** — Agent ツールで 5 つの reviewer を **同一メッセージ内に 5 個の tool_use として** 起動する（並列実行の必須条件）。各 reviewer は `review` スキル相当のレビューを実行し、JSON で結果を返す。
3. **集約** — 5 件の結果を重複マージ + 多数決で精査する。
4. **出力** — Markdown レポートをコンソールに出力する。中間ファイルは保存しない。

## Reviewer に渡すプロンプト

5 つの Agent 全てに同一プロンプトを渡す（subagent_type は `general-purpose`）:

> あなたは PR レビュアーです。GitHub PR #`<番号>` の差分を独立にレビューしてください。
>
> 1. `gh pr diff <番号>` で差分を取得する。
> 2. 以下の観点で問題を洗い出す: バグ / セキュリティ / パフォーマンス / 可読性 / テスト不足。
> 3. 結果を以下の JSON スキーマで返す。**JSON のみを出力し、説明文や Markdown コードフェンスは含めない。**
>
> ```json
> {
>   "findings": [
>     {
>       "file": "path/to/file.ts",
>       "start_line": 42,
>       "end_line": 45,
>       "severity": "high",
>       "category": "bug",
>       "summary": "1 行要約",
>       "detail": "詳細と改善提案"
>     }
>   ]
> }
> ```
>
> - `severity`: `high` / `medium` / `low`
> - `category`: `bug` / `security` / `performance` / `readability` / `test`
> - 指摘がない場合は `{"findings": []}` を返す。

## 集約ロジック

### 同一指摘の判定

以下を全て満たす 2 件の finding は同一とみなしてマージする:

- `file` が完全一致
- `[start_line, end_line]` の範囲がオーバーラップ
- `category` が一致

### マージ後の値

| フィールド | 採用ルール |
|---|---|
| `summary` | 最も短いものを採用 |
| `detail` | 全 reviewer の detail を箇条書きで列挙 |
| `severity` | 最も高いものを採用（high > medium > low） |
| `count` | マージされた reviewer 数 |

### 信頼度バケット

| バケット | 条件 | 解釈 |
|---|---|---|
| **High** | 3-5 reviewer が指摘 | 優先対応推奨 |
| **Medium** | 2 reviewer が指摘 | 要検討 |
| **Low** | 1 reviewer のみ | 参考 |

出力順は High → Medium → Low、各バケット内では severity の高い順。

## 出力フォーマット

```markdown
# Parallel Review — PR #<番号> <タイトル>

5 reviewers, N findings (High: X, Medium: Y, Low: Z)

## High confidence

### [high] src/foo.ts:42 — bug
> 1 行要約

- 4/5 reviewers
- Details:
  - <reviewer A の detail>
  - <reviewer B の detail>
  - ...

## Medium confidence
...

## Low confidence
...
```

## エラーハンドリング

| 状況 | 挙動 |
|---|---|
| 引数不正 | 即エラー終了 |
| `gh` 未認証 / PR 不在 | エラー出力後に終了 |
| 差分が空 | `No diff to review.` を出して終了 |
| 一部 reviewer 失敗 | 残りの結果で集約を継続し、レポート末尾に `⚠ N reviewer(s) failed` を注記 |
| 全 reviewer 失敗 | エラー出力後に終了 |
| JSON パース失敗 | 該当 reviewer の生出力を Low confidence の末尾に `Raw output (reviewer N)` として添える |

## 制限事項

- 同一 PR への並行起動は非サポート。
- 5 reviewer は固定。観点別分担はしない（同観点 5 並列で false positive を抑制する設計）。
