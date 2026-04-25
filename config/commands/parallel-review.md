# Parallel review

PR の差分を 5 つの reviewer サブエージェントが独立に並列レビューし、重複指摘を union-find でクラスタリングし、多数決で集約してコンソールに出力する。結果はマークダウンレポートとしてコンソールに出力し、中間ファイルは保存しない。

**並行実行非サポート** — 同一 PR に対する `/parallel-review` の並行起動は検出しない（ユーザ責任）。詳細は「制限事項」セクション参照。

## Usage

```
/parallel-review <PR番号>
```

- `<PR番号>`: 必須。正の整数。前後の ASCII 空白を trim 後、正規表現 `^[1-9][0-9]{0,7}$` にマッチする必要がある（1〜8 桁、先頭ゼロ禁止、符号禁止、小数点禁止、全角数字禁止）。
- 不正な引数は即エラー終了（exit code 1）。

> **表記規約**: 本 spec 全体で `<PR番号>` は**構文プレースホルダ**として（コマンド例・引数埋め込み位置に使用）、`PR 番号` は**散文表現**として使い分ける。

## Flow

```
  ┌──────────────────────────────────────────────────────────────┐
  │ Preflight（引数検証・PR 存在確認・diff 取得）                │
  │  - 引数 trim + regex `^[1-9][0-9]{0,7}$`                    │
  │  - `gh pr view --json number,title,state` で PR 確認        │
  │  - `gh pr diff <PR番号>` で差分を 1 回取得                  │
  │  - 差分が空なら `No diff to review.` を出して正常終了       │
  └───────────┬──────────────────────────────────────────────────┘
              │
              ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ 並列レビュー（5 名の Reviewer を 1 メッセージで同時起動）     │
  │  各 Reviewer は Skill(skill="review", args="<PR番号>") を     │
  │  呼び出し、結果を JSON スキーマに再整形して返す              │
  │  Reviewer 1 〜 5 は独立し、互いの存在を知らない              │
  └───────────┬──────────────────────────────────────────────────┘
              │
              ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ 集約（Coordinator = メインセッション）                       │
  │  - JSON パース / 失敗 reviewer の記録                        │
  │  - union-find による重複クラスタリング                       │
  │  - 信頼度バケット分類（成功 reviewer 数 N を母数）           │
  └───────────┬──────────────────────────────────────────────────┘
              │
              ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ 出力（Markdown レポートをコンソールに出力）                  │
  │  - 凡例 + High/Medium/Low + Errors セクション                │
  │  - 中間ファイルは保存しない                                   │
  └──────────────────────────────────────────────────────────────┘
```

## 用語定義

| 用語 | 定義 |
|------|------|
| **Coordinator** | メインの Claude セッション。引数検証・diff 取得・並列起動・集約・出力を行う。 |
| **Reviewer** | Task ツールで起動するサブエージェント（5 名固定）。`Skill(skill="review", args="<PR番号>")` を呼び出し、結果を JSON で返す。 |
| **Finding** | Reviewer が指摘する 1 件の問題。`file` / `start_line` / `end_line` / `severity` / `category` / `summary` / `detail` から成る。 |
| **Cluster** | union-find で統合された同一論理的 Finding の集合。成功 reviewer 1 名以上の指摘をまとめる。 |
| **成功 reviewer** | JSON パース成功・タイムアウトせず結果を返した reviewer。findings ゼロも成功扱い。 |
| **失敗 reviewer** | Task ツール内部エラー・タイムアウト・JSON パース失敗のいずれかに該当する reviewer。 |

## Preflight 詳細

以下の (a)〜(c) を**記載の順序**で実行する。いずれかで失敗したら**その時点で即中断する**。

### (a) 引数検証

- 引数の前後の **ASCII 空白 `[ \t\r\n]`** を trim する（全角空白 `U+3000` / NBSP `U+00A0` / ZWSP `U+200B` 等の Unicode 空白は trim 対象外）。
- trim 後の値が正規表現 `^[1-9][0-9]{0,7}$` にマッチするか検証（1〜8 桁、先頭ゼロ禁止）。
- マッチしない場合は「引数が不正（`<入力値>`）。PR 番号は 1〜8 桁の正整数を指定してください」のエラーで終了（exit code 1）。
- **拒否される入力例**: 空文字 `""`、`0`、`+6`、`5.0`、`007`、`５`（全角）、`5a`、`123456789`（9 桁超過）。
- **シェルインジェクション対策**: trim + 正規表現マッチを通過した値のみを以降の処理に渡す。以下の全ての `gh` コマンド呼び出しで PR 番号は**位置引数として渡し、必ずダブルクォートで囲む**（例: `gh pr view "<PR番号>"`）。reviewer プロンプトに埋め込む PR 番号も Preflight 検証済みの値のみを使用する。

### (b) PR 存在確認

- `gh pr view "<PR番号>" --json number,title,state` を実行し、PR の存在とタイトル・state を取得する。
- 外部コマンドが非 0 で終了した場合（PR 不在・認証エラー・ネットワーク障害）は、コマンド名と stderr を含むエラーで終了（exit code 3、PR 不在）。
- `state` は判定に使わず情報として保持する（closed/merged PR でも diff さえあればレビュー可能とする。開発者が過去 PR を遡って確認するユースケースを許容）。
- `title` は出力ヘッダに使用する。

### (c) 差分取得

- `gh pr diff "<PR番号>"` を実行し、差分を取得する。
- 外部コマンドが非 0 で終了した場合は (b) と同様にエラーで終了（exit code 3）。
- **差分が空（stdout が空または空行のみ）なら**、`No diff to review.` を出力して**正常終了**（exit code 0）。
- 取得した差分は**会話コンテキスト上で保持**し、reviewer プロンプトに埋め込む（各 reviewer が `gh pr diff` を重複実行しない — N+1 問題の回避）。

## Reviewer プロンプト

5 名の Reviewer を **1 メッセージ内に 5 個の Task tool_use として** 起動する（並列実行の必須条件）。`subagent_type` は **`general-purpose`** を使用する（選定理由: Skill ツールを呼び出し可能であること + サブエージェント独立性の担保）。

### プロンプト本体

5 名全員に**同一のプロンプト**を渡す。プロンプトには以下を必ず含める:

1. **PR 番号**（Preflight で検証済みの値）
2. **Preflight で取得した差分**（reviewer は自前で `gh pr diff` を呼ばない）
3. **Skill ツールでの明示呼び出し指示**: `Skill(skill="review", args="<PR番号>")` を呼び出すこと
4. **JSON スキーマ**（下記）
5. **JSON のみ出力する制約**（説明文・コードフェンスは含めない）

> あなたは独立した PR レビュアーです。他の reviewer の存在を考慮せず、以下の PR を独立にレビューしてください。
>
> **PR 番号**: `<PR番号>`
>
> **差分（Preflight で取得済み）**:
> ```
> <Preflight で取得した diff 全文>
> ```
>
> **手順**:
>
> 1. `Skill(skill="review", args="<PR番号>")` を**明示的に Skill ツールで呼び出して**レビューを実行する。自然言語で `/review <PR番号>` と書くだけではスキルは起動しない（no-op となる）点に注意。
> 2. `/review` は自由形式マークダウンで応答する前提で扱う。応答を解釈し、下記 JSON スキーマに**再整形**する。`/review` が独自の severity ラベルを付けていても継承せず、本 spec の severity 定義で**再分類**する。
> 3. 以下の JSON スキーマで結果を返す。**JSON のみを出力し、説明文や Markdown コードフェンスは含めない。**
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

### Skill 呼び出し失敗時の扱い

Reviewer の `Skill(skill="review", args="<PR番号>")` 呼び出しが以下のいずれかで失敗した場合、Reviewer は**失敗 reviewer** として扱われる:

- `/review` スキル未インストール
- Skill 内部エラー
- Task ツール内部エラー
- タイムアウト（後述）
- JSON パース不能な応答

**args 空渡し禁止**: `args` には PR 番号を**文字列として必ず**埋め込む。空文字 / 未置換テンプレート変数（例: `args=""`, `args="{pr_number}"`）での呼び出しは禁止（`/review` は args 空の場合 `gh pr list` へ分岐するため no-op となる）。

### タイムアウト

- Reviewer 1 名あたりのタイムアウトは **5 分**。超過した reviewer は失敗扱いとする。
- **リトライは行わない**（spec 単純化のため）。失敗 reviewer は成功 reviewer の母数から除外する。

## 集約ロジック

### JSON パース

- 各 Reviewer の応答を JSON として厳密にパースする。パース失敗（括弧不整合・スキーマ違反・余剰テキスト混入等）は失敗 reviewer 扱いとし、raw output を後述「出力フォーマット」の `## Errors` セクションに記録する。
- `findings` が空配列 `[]` の reviewer は**成功 reviewer 扱い**（findings ゼロと失敗を区別する）。

### 成功 reviewer 数と母数

- **成功 reviewer 数 N** = 5 − 失敗 reviewer 数
- N < 1（= 全員失敗）の場合は「全 reviewer 失敗」として exit code 2 で中断（後述「エラーハンドリング」参照）。
- 以下の集約処理では N を母数として扱う。

### union-find によるクラスタリング

- 各 Reviewer の findings を平坦化し、以下の条件を両方満たす 2 件を**直接ペア**とみなす:
  - `file` が完全一致
  - `[start_line, end_line]` の範囲がオーバーラップ（開区間でなく閉区間オーバーラップ: `a.start <= b.end && b.start <= a.end`）
- 直接ペアを**同じカテゴリ内でのみ**union-find で統合する（A と B、B と C がペアなら A/B/C を 1 クラスタに束ねる — 推移律）。
- 異なる `category` の指摘は同一クラスタにしない（`bug` と `readability` が同一行範囲でも別指摘として扱う）。

> **設計判断（カテゴリ別クラスタリング + summary 多様性の扱い）:**
>
> 同一範囲 + 同一カテゴリでも summary が異なるケース（例: 同じ関数への bug 指摘でも reviewer A は「null 未チェック」、reviewer B は「エラーメッセージ不足」と指摘）は、**範囲 + category のみで束ね、detail に全指摘を列挙する**方針をとる（シンプル優先）。summary の多様性はマージ後の `detail` セクションに保持する（下記「マージ後の値」参照）。

### マージ後の値

| フィールド | 採用ルール |
|---|---|
| `file` | 全員共通（クラスタ条件で保証） |
| `start_line` | クラスタ内の最小値 |
| `end_line` | クラスタ内の最大値 |
| `category` | 全員共通（クラスタ条件で保証） |
| `summary` | **最頻出 summary を採用。同数なら最長。tie-break は reviewer 番号の若い順**（情報損失を最小化するため）。 |
| `severity` | クラスタ内で最高のもの（high > medium > low）。各 reviewer 個別の severity は detail に残す。 |
| `detail` | 全 reviewer の詳細を箇条書きで列挙（各項目冒頭に `[reviewer N, severity]` を付記） |
| `count` | クラスタに属する reviewer 数（重複 reviewer は 1 としてカウント） |

### 信頼度バケット（成功 reviewer 数 N を母数とした比率ベース）

| バケット | 条件 | 解釈 |
|---|---|---|
| **High** | `count > N/2`（過半数） | 優先対応推奨 |
| **Medium** | `count >= 2` かつ High 未満 | 要検討 |
| **Low** | `count == 1` のみ | 参考 |

- 出力順: High → Medium → Low。各バケット内では severity の高い順（high > medium > low）、severity 同値では file 名 + start_line の昇順。
- **N=5 時の閾値**: High は `count >= 3`、Medium は `count == 2`、Low は `count == 1` となる（現行挙動と一致）。
- **N=3 時の閾値**: High は `count >= 2`、Medium は該当なし（`count >= 2 && count < 2` は不成立）、Low は `count == 1`。
- **N=1 時**: High は `count >= 1`、Medium / Low は該当なし（全 finding が High バケット扱い）。

## 出力フォーマット

出力はマークダウン形式でコンソールに直接出力する（中間ファイル不要）。

### 構造

```markdown
# Parallel Review — PR #<番号> <タイトル>

<成功/失敗 reviewer 表記>, <総 finding 数> findings (High: X, Medium: Y, Low: Z)

## 凡例

- **severity**: `high`（バグ/セキュリティ等の重大問題） / `medium`（品質影響） / `low`（軽微・好み）
- **category**: `bug` / `security` / `performance` / `readability` / `test`
- **信頼度バケット**: High = 成功 reviewer の過半数, Medium = 2 名以上かつ過半数未満, Low = 1 名のみ
- **count 分母**: 成功 reviewer 数（例: `3/5 reviewers (5 succeeded)` または `3/3 reviewers (2 failed)`）

## High confidence

### [high/bug] src/foo.ts:L42-45
> 1 行要約（最頻出または最長）

- 4/5 reviewers (5 succeeded)
- Details:
  - [reviewer 1, high] <detail>
  - [reviewer 2, high] <detail>
  - [reviewer 4, medium] <detail>
  - [reviewer 5, high] <detail>

## Medium confidence

### [medium/readability] src/bar.ts:L10-12
> 1 行要約

- 2/3 reviewers (3 succeeded, 2 failed)
- Details:
  - [reviewer 1, medium] <detail>
  - [reviewer 3, medium] <detail>

## Low confidence

### [low/test] src/baz.ts:L88-90
> 1 行要約

- 1/5 reviewers (5 succeeded)
- Details:
  - [reviewer 2, low] <detail>

## Errors

- **Reviewer 3**: JSON parse failed. Raw output (truncated to 50 lines):
  ```
  <raw output、50 行まで>
  ```
- **Reviewer 5**: Timeout after 5 minutes.
```

### 見出しと表記の規約

- 見出し形式: `### [<severity>/<category>] <file>:L<start_line>-<end_line>`。severity / category はラベル付きで、スラッシュで区切る。
- **count 分母**は**成功 reviewer 数**を使う。表記形式: `count/N reviewers (N succeeded)`（全員成功時）または `count/N reviewers (N succeeded, M failed)`（部分失敗時）。
- サマリ行冒頭の `5 reviewers, N findings ...` は部分失敗時 `<N>/5 reviewers succeeded, N findings ...` と表記する。

### Errors セクション

- **信頼度バケットとは独立したセクション**として末尾に配置する（raw output を Low confidence 内に混ぜない）。
- JSON パース失敗 reviewer の raw output は**最大 50 行で truncate** する（機密・巨大出力対策）。truncate した場合は `(truncated to 50 lines)` を注記。
- タイムアウト・Task ツール内部エラーは raw output がないため、エラー種別のみを記載する。
- 全員成功時は `## Errors` セクションを省略してよい。

## エラーハンドリング

### 失敗の定義

以下のいずれかに該当する reviewer を**失敗 reviewer** とする:

- Task ツール内部エラー（起動失敗・通信断等）
- タイムアウト（5 分超過）
- JSON パース失敗（括弧不整合・スキーマ違反・余剰テキスト混入）

`findings` が空配列 `[]` の reviewer は**成功扱い**（「findings なし」と「失敗」を区別する）。

### 部分失敗の扱い

- 1 名以上成功していれば集約を継続する（母数 N を動的に計算）。
- 失敗 reviewer はレポート末尾の `## Errors` セクションに記録する。
- サマリ行に成功数と失敗数を明示する（例: `3/5 reviewers succeeded, 2 failed`）。

### 全員失敗の扱い

- N=0（5 名全員失敗）の場合は集約せず、`## Errors` セクションのみを出力して exit code 2 で中断する。
- リトライは行わない（spec 単純化のため、ユーザが再実行する）。

### Exit code 定義

| exit code | 意味 |
|---|---|
| **0** | 正常終了（findings あり・なし・差分空の全てを含む） |
| **1** | 引数不正（trim + regex マッチ失敗） |
| **2** | 全 reviewer 失敗 |
| **3** | PR 不在・`gh` 認証エラー・ネットワーク障害（Preflight の外部コマンド失敗全般） |

### 外部コマンド失敗時の扱い

- Preflight 内の `gh pr view` / `gh pr diff` が非 0 で終了した場合、コマンド名・stderr を含むエラーで exit code 3 で中断。リトライは行わない。

## テストシナリオ

以下のケースで期待挙動を検証する。各ケースは「入力 → 主要操作 → 期待出力の要点」の箇条書きで記載する。

### 1. 正常系（5 reviewer 成功、重複あり）

- **入力**: `/parallel-review 42` (PR #42 は OPEN、差分あり)
- **挙動**: Preflight PASS → 5 名並列起動 → 全員成功 → union-find でクラスタリング → バケット分類
- **期待出力**:
  - サマリ: `5 reviewers, 8 findings (High: 2, Medium: 3, Low: 3)`
  - High バケットに 4/5 および 3/5 で指摘された 2 件
  - Medium バケットに 2/5 で指摘された 3 件
  - Low バケットに 1/5 の 3 件
  - `## Errors` セクションなし
  - exit code 0

### 2. 一部 reviewer 失敗（3/5 成功）

- **入力**: `/parallel-review 42` (2 名が JSON パース失敗、3 名が成功)
- **挙動**: N=3 として集約。閾値: High は `count >= 2`、Medium は該当なし、Low は `count == 1`
- **期待出力**:
  - サマリ: `3/5 reviewers succeeded, 4 findings (High: 1, Medium: 0, Low: 3)`
  - 各 finding の count 表記: `2/3 reviewers (3 succeeded, 2 failed)` 等
  - `## Errors` セクションに Reviewer X/Y の raw output（50 行まで）
  - exit code 0

### 3. 全 reviewer 失敗

- **入力**: `/parallel-review 42` (全員タイムアウトまたはパース失敗)
- **期待出力**:
  - エラーメッセージ + `## Errors` セクション
  - 信頼度バケット（High/Medium/Low）は出力しない
  - exit code 2

### 4. JSON パース失敗

- **入力**: `/parallel-review 42` (Reviewer 3 が説明文混じりの応答を返す)
- **期待出力**:
  - Reviewer 3 は失敗 reviewer として母数から除外（N=4）
  - `## Errors` セクションに Reviewer 3 の raw output（最大 50 行で truncate、`(truncated to 50 lines)` 注記）
  - exit code 0（他 reviewer が成功しているため）

### 5. 差分空

- **入力**: `/parallel-review 42` (PR #42 に差分なし)
- **期待出力**:
  - `No diff to review.` のみ出力
  - Reviewer を起動しない
  - exit code 0

### 6. A-B-C 推移律ケース（union-find）

- **入力**: 3 件の finding A/B/C があり、A-B および B-C が直接ペア条件を満たす（A-C 単独では範囲オーバーラップせず）
- **期待**: A/B/C が 1 クラスタに統合される（`count = 3`）。start_line = min(A.start, B.start, C.start)、end_line = max(A.end, B.end, C.end)

### 7. 同一範囲・同一カテゴリでの summary 多様性

- **入力**: reviewer 1 が `{file: foo.ts, range: L10-15, category: bug, summary: "null 未チェック"}`, reviewer 2 が `{file: foo.ts, range: L12-18, category: bug, summary: "エラーメッセージ不足"}`
- **期待**: 範囲オーバーラップ + 同カテゴリなので 1 クラスタに統合。`summary` は最頻出（同数のため）→ 最長 → `エラーメッセージ不足`。detail に両方を `[reviewer N, severity]` 付きで列挙。

### 8. 引数 edge case

| 入力 | 期待 |
|---|---|
| `""` | exit code 1（空文字） |
| `"0"` | exit code 1（ゼロ不可） |
| `"+6"` | exit code 1（符号付き） |
| `"007"` | exit code 1（先頭ゼロ） |
| `"５"` | exit code 1（全角数字） |
| `"123456789"` | exit code 1（9 桁超過） |
| `" 42 "` | exit code 0（ASCII 空白は trim 対象） |
| `"42 42"` | exit code 1（NBSP は trim 対象外） |

## 制限事項

- **5 reviewer 固定**: 観点別分担はしない（同一観点 5 並列で false positive 抑制を狙う設計）。
- **コスト**: 1 実行あたり LLM コールは**約 5 倍 + 集約コスト**（各 reviewer が `/review` を内部呼び出しし、Coordinator が集約するため）。通常の `/review` 単発実行よりコストが高い点に留意。
- **同一 PR 並行起動**: 検出手段は設けない。**ユーザ責任**で並行起動を避けること（2 つの `/parallel-review` を同一 PR に対して同時実行しても警告は出ないが、コンソール出力が混在する）。
- **リトライなし**: reviewer のタイムアウト・失敗は再試行しない。ユーザが再実行する。
- **中間ファイルなし**: `review_{n}_{m}.md` のようなアーティファクトは保存しない（`/review-fix` と異なる方針。`/parallel-review` は 1 回限りのコンソール出力が目的）。
- **PR state 不問**: closed / merged PR でも差分があればレビュー可能（過去 PR 確認ユースケースを許容）。
- **`/review` スキル可用性の前提**: 全 reviewer サブエージェントで `/review` が利用可能であること。未インストール環境では reviewer が失敗 reviewer として現れる（事前検知手段なし）。
