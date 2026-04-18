# Review and fix a pull request

## 概要

PR に対して自動レビューサイクルを回し、品質を担保する仕組み。
3 つのロール（Reviewer / Coordinator / Implementer）が協調し、指摘の発見・精査・実装を繰り返す。
Reviewer には Claude（Task ツールで起動するサブエージェント）と codex CLI の 2 種類があり、引数で構成を指定できる。

## 引数

```
/review-fix [claude=N] [codex=M]
```

- `N`, `M` は 0 以上の整数。
- **引数なし** → 既定値 `claude=2 codex=0`（Claude Reviewer 2 名、codex なし）。
- **引数あり** → 明示されたキーのみ有効で、**未指定のキーは 0** として扱う。
  - 例: `/review-fix codex=2` → `claude=0 codex=2`（codex 2 名のみ）
  - 例: `/review-fix claude=3` → `claude=3 codex=0`（Claude 3 名のみ）
  - 例: `/review-fix claude=3 codex=1` → Claude 3 + codex 1 = 計 4 名
- **合計が 0 となる指定はエラー**（例: `claude=0 codex=0`、`codex=0` 単独、`claude=0` 単独）。エラー時は Coordinator が理由を明示してサイクルを開始しない。
  - エラー例: 「指定された引数では Reviewer が 0 名になります（`claude=0 codex=0`）。`claude` または `codex` のいずれかに 1 以上の整数を指定してください。」
- **引数バリデーション**: 以下はすべて **即エラー** として扱い、Coordinator は違反した入力原文と理由を含むエラーメッセージを出してサイクルを開始しない:
  - 非整数（例: `claude=abc`, `claude=1.5`）
  - 負数（例: `claude=-1`）
  - 値欠落（例: `claude=`）
  - 未知のキー（`claude` / `codex` 以外。例: `gemini=1`）
  - キー重複（例: `claude=1 claude=3`）
  - `claude` / `codex` は **大小文字を区別する**（`CLAUDE=2` や `Codex=1` は未知キー扱いでエラー）。
  - `=` の周囲に空白を入れない（`claude = 2` は不正）。トークン間の区切りは空白のみ。
- 引数は Round 1 以降すべてのラウンドで同じ構成を維持する（途中変更しない）。
  - **設計意図:** ラウンド間で Reviewer 構成を固定するのは、レビュー指摘の再現性と統合ロジックの単純化のため。ラウンド中に構成を変更したい場合は一度 `/review-fix` を終了し、異なる引数で再実行すること。

## フロー

```
  ┌─────────────────────────┐
  │ PR 作成 / レビュー指示  │
  └───────────┬─────────────┘
              │
              ▼
  ┌──── Round n ──────────────────────────────────────────────────────────────────┐
  │                                                                              │
  │  ┌─── Reviewers（Claude N 名 + codex M 名を並列起動）──────────────────┐    │
  │  │  Claude Reviewer 1..N → review_{n}_1.md … review_{n}_N.md           │    │
  │  │  codex Reviewer 1..M  → review_{n}_c1.md … review_{n}_cM.md         │    │
  │  └─────────────────────────┬────────────────────────────────────────────┘    │
  │                            │                                                 │
  │                            ▼                                                 │
  │  ┌─────────────────────────────────────────────────────────────────────┐     │
  │  │ Coordinator: 統合                                                   │     │
  │  │  - 全 review_{n}_*.md を読み込み・重複排除・統合                    │     │
  │  │  - Verdict 統合（最も厳しいものを採用）                             │     │
  │  │  - Finding ID を採番し直し                                          │     │
  │  └─────────────────────────┬───────────────────────────────────────────┘     │
  │                            │                                                 │
  │                            ▼                                                 │
  │  ┌─────────────────────────────────────────────────────────────────────────┐  │
  │  │ 統合 Verdict 分岐                                                      │  │
  │  └──────┬──────────────────────────────┬──────────────────┬────────────────┘  │
  │         │                              │                  │                   │
  │         ▼                              ▼                  ▼                   │
  │  ┌─────────────┐  ┌───────────────────────────────┐  ┌─────────────────────────────┐
  │  │ Request     │  │ Comment                       │  │ Approve                     │
  │  │ Changes     │  │                               │  │                             │
  │  │ → 継続確定  │  │ Coordinator 判断:             │  │ Coordinator: 最終判断       │
  │  │             │  │  Accept あり → 継続           │  │  残指摘を対応不要と判断?    │
  │  │             │  │  Accept なし → 終了可能       │  │                             │
  │  │             │  ├───────────────┬───────────────┤  ├──────────────┬──────────────┤
  │  │             │  │ Accept あり   │ Accept なし   │  │ No           │ Yes          │
  │  │             │  │ → 継続       │ → 終了可能    │  │ → 継続       │ → 終了       │
  │  └──────┬──────┘  └───────┬───────┴───────┬───────┘  └──────┬───────┴──────┬───────┘
  │         │                 │               │                 │              │
  │         └────────┬────────┘               └─────────────────┼──────┐       │
  │                  │ (継続する場合)                             │      │       │
  │                  ▼                                          │      │       │
  │  ┌──────────────────────────┐                               │      │       │
  │  │ Coordinator              │◄──────────────────────────────┘      │       │
  │  │ task_{n}.md を作成       │                                      │       │
  │  └────────────┬─────────────┘                                      │       │
  │               │                                                    │       │
  │               │ Accept = 0 → スキップ ──────────────────────────────┤       │
  │               │                                                    │       │
  │               ▼                                                    │       │
  │  ┌──────────────────────────┐                                      │       │
  │  │ Implementer              │                                      │       │
  │  │ Accept 項目を実装        │                                      │       │
  │  │ git commit               │                                      │       │
  │  └────────────┬─────────────┘                                      │       │
  │               │                                                    │       │
  └───────────────┼────────────────────────────────────────────────────┼───────┼┘
                  │                                                    │       │
                  ▼                                                    ▼       ▼
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │                           次の Round / 終了                                  │
  └──────────────────────────────────────────────────────────────────────────────┘
   (max 10 rounds)
```

> **1 ラウンドの定義:** Reviewers（Claude N 名 + codex M 名を並列）→ Coordinator（統合・精査）→ Implementer（Accept 項目がない場合は Implementer をスキップ）の 1 サイクルを 1 ラウンドと数える。

## ディレクトリ構造

```
.claude/reviews/            # レビューアーティファクト（プロジェクト内に配置）
  <PR番号>/                 # PR ごとにディレクトリを分離（並行レビュー対応）
    <YYYYMMDD_HHMMSS>/     # 実行ごとにタイムスタンプディレクトリを作成（履歴保持）
      review_1_1.md         # Round 1, Claude Reviewer 1
      review_1_2.md         # Round 1, Claude Reviewer 2
      review_1_c1.md        # Round 1, codex Reviewer 1（codex=M>=1 の場合）
      review_1_c2.md        # Round 1, codex Reviewer 2（codex=M>=2 の場合）
      task_1.md             # Round 1 タスク（統合済み）
      review_2_1.md         # Round 2, Claude Reviewer 1
      review_2_c1.md        # Round 2, codex Reviewer 1
      task_2.md             # Round 2 タスク
      ...
```

> **Note:** レビューアーティファクトはプロジェクト内の `.claude/reviews/` 配下に保存される。`install.sh` を実行済みの場合、グローバル gitignore（`core.excludesFile`）に `.claude/reviews/` が自動追加されるため、各リポジトリでの手動設定は不要である。`install.sh` を実行していない環境で使用する場合は、**レビュー対象のリポジトリ**の `.gitignore` に `.claude/reviews/` を手動で追加すること。

### ナンバリング規則

- PR ごとに `.claude/reviews/<PR番号>/` ディレクトリを使用する。
- レビューサイクル開始時に **Coordinator** が `<YYYYMMDD_HHMMSS>` 形式のタイムスタンプディレクトリを新規作成する。過去のタイムスタンプディレクトリは削除しない（履歴として保持される）。不要になった古いタイムスタンプディレクトリはユーザーが手動で削除してよい。
- 同一タイムスタンプディレクトリ内では `review_1_*.md` → `task_1.md` → `review_2_*.md` → `task_2.md` … と連番で進む。
- ファイル命名規則:
  - Claude Reviewer: `review_{n}_{m}.md`（n = ラウンド番号, m = Claude Reviewer 番号 1..N）
  - codex Reviewer: `review_{n}_c{k}.md`（n = ラウンド番号, k = codex Reviewer 番号 1..M。`c` プレフィックスで Claude と区別）
  - Task: `task_{n}.md`（n = ラウンド番号）

## 各ロールの責務

### Reviewer

Reviewer は実行主体により 2 種類に分かれるが、責務は共通である。

- PR の diff を読み、問題点・改善案を severity 付きで列挙する。
- 指定された出力先ファイルに `review_{n}_{m}.md` 形式の内容を出力する。
  - Claude Reviewer: `review_{n}_{m}.md`（m = 1..N）
  - codex Reviewer: `review_{n}_c{k}.md`（k = 1..M）
- 毎ラウンド、前ラウンドの情報を持たない状態でフレッシュにレビューする。
- 各 Reviewer は互いの存在を知らず、独立してレビューを行う。
- 起動数は引数 `claude=N codex=M` により決定される（既定は `claude=2 codex=0`）。

**Claude Reviewer**: Task ツール（`subagent_type: general-purpose`）で起動するサブエージェント。Coordinator が 1 メッセージ内で N 個の Task 呼び出しを並列発行する。

**codex Reviewer**: codex CLI（`codex review` サブコマンド）を Bash ツール経由で起動する外部プロセス。Coordinator が 1 メッセージ内で M 個の Bash 呼び出しを並列発行する。Claude Reviewer の Task 呼び出しと同一メッセージ内でまとめて並列起動してよい。

### Coordinator（メインの Claude または人間）

- 全 Reviewer の `review_{n}_*.md` を読み込み、指摘を重複排除・統合する。同一の論理的問題に対して複数 Reviewer が異なる severity を付けた場合は、高い方を採用する。「同一の論理的問題」の判断基準: 同一のルートコーズに起因する指摘、または同一ファイル・同一関数に対する同種の懸念（例: 同じ関数のエラーハンドリング不足を別 Reviewer が別表現で指摘した場合）は同一とみなす。逆に、同じコード領域でも異なる種類の問題（例: null チェック欠如とエラーメッセージ不足）は別の指摘として扱う。
- Verdict を統合する（最も厳しいものを採用: Request Changes > Comment > Approve）。
- 統合した指摘に対して **Accept（対応する）** か **Reject（対応しない）** を判断し、`task_{n}.md` に出力する。Finding ID は Coordinator が統合時に採番し直す。
- 過剰な指摘・スコープ外の提案・費用対効果の低い項目はフィルタリングする。
- Reject には必ず理由を明記する。
- Round 2 以降は、前ラウンドの修正が正しく行われたかを自身で検証する（Reviewer には前ラウンド情報を渡さない）。

### Implementer

- `task_{n}.md` の Accept 項目を実装する。**`task_{n}.md` が唯一の権威的な作業指示であり、ここに記載された Accept 項目のみが実装対象となる。**
- 指摘の背景や詳細なコンテキストが必要な場合は `review_{n}_*.md` および設計ドキュメントを補助的に参照してよいが、`review_{n}_*.md` 内の指摘を独自に作業項目として扱ってはならない。
- PR ブランチに追加コミットする。

## ロールの実行モデル

各ロールは **独立したインスタンス** で実行する。Coordinator はメインセッション（ユーザーと会話している Claude）が担い、Reviewer と Implementer は別プロセス／別エージェントとして起動する。

| ロール | 実行主体 | 並列数 | 理由 |
|--------|----------|--------|------|
| **Coordinator** | メインの Claude セッション | 1 | ユーザーとの対話・判断の主体であるため |
| **Reviewer (Claude)** | Task ツールで起動するサブエージェント | N（引数 `claude=N`、既定 2） | 複数の独立した視点でレビューし、指摘の取りこぼしを防ぐため |
| **Reviewer (codex)** | Bash ツールで起動する codex CLI プロセス | M（引数 `codex=M`、既定 0） | Claude とは異なるモデル／ツール視点を加え、ブラインドスポットを補完するため |
| **Implementer** | Task ツールで起動するサブエージェント | 1 | 実装作業を分離し、Coordinator のコンテキストを消費しないため |

> **重要:** Coordinator 自身が Reviewer や Implementer を兼任してはならない。レビューの客観性と、コンテキスト分離による品質を担保するために、必ず別エージェント／別プロセスとして起動すること。

> **Note:** Reviewer を複数名起動する際は、Task ツール呼び出し（Claude 分）と Bash ツール呼び出し（codex 分）を **同一メッセージ内にまとめて並列発行** すること。順次起動するとレイテンシが増大する。

> **部分的失敗時の振る舞い:** 並列起動した Reviewer の一部がタイムアウト・エラーで失敗した場合、成功した Reviewer のレビュー結果のみで続行する（最低 1 名成功で有効とする）。全員が失敗した場合はリトライを **1 回のみ** 行う。リトライ時は全 `N + M` 名を再実行する（失敗した Reviewer のみの再実行ではない）。リトライでも全員が失敗した場合はサイクルを中断して人間に判断を委ねる。

## Severity レベルの定義

| レベル | 基準 | 典型例 |
|--------|------|--------|
| **Critical** | リリースブロッカー。データ損失・セキュリティ脆弱性・本番障害に直結する | 認証バイパス、データ破壊、機密情報の漏洩 |
| **High** | 機能的なバグまたは重大な設計上の問題 | ロジックバグ、エッジケース未処理、型安全性の欠如 |
| **Medium** | 品質・保守性に影響するが機能は正しい | エラーハンドリング不足、テスト欠如、ドキュメント不整合 |
| **Low** | 改善が望ましいが緊急性は低い | 命名の改善、軽微な非効率、コメント不足 |
| **Nit** | 好みの範囲。対応しなくても問題ない | フォーマット、タイポ、スタイルの一貫性 |

## ファイルフォーマット

### review_{n}_{m}.md / review_{n}_c{k}.md（Reviewer が出力）

> **Note:** `{id}` は Claude Reviewer では `1..N` の番号（整数そのまま）、codex Reviewer では `c1..cM` の形式（例: `c1`, `c2`）で読み替える。すなわち Claude では `{id} = {m}`、codex では `{id} = c{k}`。

```markdown
# Review {n}-{id}: PR #{PR番号} — {タイトル}

## Summary
{全体の所感・1〜3 行}

## Findings

### Critical
- **C-1**: {内容}

### High
- **H-1**: {内容}
- **H-2**: {内容}

### Medium
- **M-1**: {内容}

### Low
- **L-1**: {内容}

### Nit
- **N-1**: {内容}

<!-- 該当する指摘がない severity セクションは省略可 -->

## Verdict
{Approve / Request Changes / Comment}

```

### task_{n}.md（Coordinator が出力）

```markdown
# Task {n}: レビュー Round {n} への対応

{概要・1〜2 行}

## 対応する (Accept)

### H-1: {内容の要約}
{対応方針の説明}

### M-1: {内容の要約}
{対応方針の説明}

## 対応しない (Reject)

### L-1: {内容の要約}
{却下理由}

### N-1, N-2
{まとめて却下理由}
```

> **Note:** Accept 項目が 0 件の場合は「## 対応する (Accept)」セクションを、Reject 項目が 0 件の場合は「## 対応しない (Reject)」セクションを、それぞれ省略してよい。

> **Note:** `{内容の要約}` は、Coordinator が各 Reviewer の `review_{n}_*.md` の指摘内容を統合・重複排除した上で短く要約して付けるタイトルである。Finding ID は Coordinator が統合時に採番し直すため、個別の `review_{n}_{m}.md` の ID とは異なる場合がある。

## 終了条件

以下の **両方** を満たしたらサイクルを終了する:

1. **統合 Verdict が Approve となる。**
2. **Coordinator が残指摘（もしあれば）を対応不要と判断する。**

Approve が出ても Coordinator が残指摘に対応すべきと判断した場合はサイクルを継続する。この場合も Coordinator は `task_{n}.md` を作成し、Accept 項目があれば Implementer を経由する通常フローと同じ手順を踏む（フロー図の Approve/No は Request Changes / Comment の継続パスと同じ合流点に合流する）。

### Verdict の種類と判断基準

| Verdict | 意味 | サイクルへの影響 |
|---------|------|----------------|
| **Approve** | ブロッカーなし。マージ可能 | 終了条件①を満たす |
| **Request Changes** | 修正必須の問題あり | サイクル継続 |
| **Comment** | ブロッカーではないが改善余地あり | Coordinator の判断に委ねる（Accept 項目があればサイクル継続、なければ終了可能） |

### Verdict と Severity の対応規則

Reviewer は以下の規則に従って Verdict を決定すること:

| 最も高い Severity | Verdict |
|-------------------|---------|
| **Critical** または **High** | **Request Changes** |
| **Medium** | **Comment** |
| **Low** / **Nit** のみ | **Approve** |

> **重要:** Medium 以上の指摘がある場合に Approve を出してはならない。Medium の指摘は「機能は正しいが品質・保守性に影響する」レベルであり、Coordinator が対応要否を判断する機会を確保するために、最低でも Comment とすること。

### 複数 Reviewer の Verdict 統合ルール

複数 Reviewer の Verdict は、**最も厳しいものを採用** するルールで統合する:

| 順位 | Verdict | 意味 |
|------|---------|------|
| 1（最も厳しい） | **Request Changes** | 1 名でも Request Changes → 統合 Verdict は Request Changes |
| 2 | **Comment** | Request Changes なし & 1 名以上が Comment → 統合 Verdict は Comment |
| 3（最も緩い） | **Approve** | 全員が Approve → 統合 Verdict は Approve |

> **例:** Reviewer 1 が Approve、Reviewer 2 が Comment の場合、統合 Verdict は Comment となる。Coordinator はこの統合 Verdict に基づいてフロー図の分岐に進む。

### 10 ラウンド到達時のエスカレーション

レビューが 10 ラウンドに達した場合は無限ループ防止のためサイクルを強制終了し、**人間が介入して判断する**。残課題を Issue 化するなど、手動で対応方針を決定すること。

## 使い方

各ロールを起動する際に、以下のコンテキストを渡す。

### Reviewer への入力

**毎ラウンド共通（Round 1 以降すべて）:**

- PR diff（`git diff <base>...<head>`）— 最新のコミットを含む差分を毎ラウンド渡す
- レビュアー番号と出力先ファイルパス — Coordinator が各 Reviewer に割り当てる
  - Claude: `review_{n}_{m}.md`（m = 1..N）
  - codex: `review_{n}_c{k}.md`（k = 1..M）
- 出力フォーマット仕様（本ドキュメントの「review_{n}_{m}.md / review_{n}_c{k}.md（Reviewer が出力）」セクションで定義されたテンプレート）

> **設計意図:** Reviewer に前ラウンドの情報を渡さないのは、アンカリングバイアスを防ぐため。前ラウンドの指摘に引きずられて「修正の検証」に偏り、新たな視点での問題発見が弱くなることを避ける。前ラウンドの修正検証は Coordinator が自身で行う。

> **Note:** 複数 Reviewer には同一の入力（PR diff）を渡す。各 Reviewer は互いの存在を知らない状態で独立にレビューを行う。

> **base / diff の決定手順（Claude / codex 共通）:** Coordinator はサイクル開始時に一度だけ `gh pr view <PR番号> --json baseRefName -q .baseRefName`（相当の手段）で base ブランチ名を取得し、同じく一度だけ `git diff <base>...<head>` で diff テキストを生成する。以降すべての Reviewer（Claude / codex 共に）にはこの **同じ diff テキスト** を入力として渡す。codex に `--base <BRANCH>` オプションでブランチ名を渡す方式は採用しない（codex にも diff テキストをプロンプト内に埋め込んで渡す。詳細は「codex Reviewer の起動」を参照）。

> **共通ルール（出力先パス）:** Task ツール（Claude）および Bash ツール（codex）に渡す出力先ファイルパスは **必ず絶対パス** で指定すること。Coordinator はサイクル開始時にタイムスタンプディレクトリの絶対パスを変数（例: `<REVIEW_DIR>`）として決定し、全 Reviewer 呼び出しで共通に用いる。相対パスを用いると、Bash ツールの cwd が毎回リセットされる環境でリダイレクト先が迷子になる。

#### Claude Reviewer の起動（Task ツール）

Coordinator は Task ツール（`subagent_type: general-purpose`）で各 Claude Reviewer を起動する。プロンプトには上記の入力一式（PR diff、出力先パス、出力フォーマット仕様）を埋め込む。

#### codex Reviewer の起動（Bash ツール）

Coordinator は `codex review` サブコマンドを Bash ツール経由で起動する。

**プリフライト（`codex=M>=1` の場合に必須）:** Reviewer を起動する前に、Coordinator は `command -v codex` 相当で codex CLI の存在を確認する。見つからない場合は、具体的なインストール手順（例: 「codex CLI が見つかりませんでした。インストール方法は https://github.com/openai/codex を参照してください。」）を添えてエラーを返し、サイクル開始前に中断する。

**プロンプト渡し方式（必須ルール）:** codex に渡すプロンプトは、シェル展開による事故やコマンド注入（PR タイトル・diff に含まれうる `` ` ``, `$`, `"`, 改行）を避けるため、以下のいずれかの方式で渡すこと:

1. **stdin 経由（推奨）:** Coordinator は Write ツールで `<REVIEW_DIR>/prompt_{n}_c{k}.md` 等の一時プロンプトファイルを作成し、そのファイルを `<` で stdin に接続する。
2. **シングルクォート付きヒアドキュメント:** `codex review - << 'PROMPT_EOF' ... PROMPT_EOF`（終端子をシングルクォートで囲むことが必須。囲まないとヒアドキュメント内でシェル展開が起きる）。

**ダブルクォート付きコマンドライン引数渡し（例: `codex review "<INSTRUCTIONS>"`）は仕様として禁止する。** PR タイトル・diff などの未信頼文字列は必ず Write ツール経由でファイルに書き、シェル引数として直接展開させないこと。

**基本形（stdin 方式、推奨）:**

```bash
codex review - < <REVIEW_DIR>/prompt_{n}_c{k}.md > <REVIEW_DIR>/review_{n}_c{k}.md 2> <REVIEW_DIR>/review_{n}_c{k}.err
```

- `<REVIEW_DIR>` は Coordinator がサイクル開始時に決定したタイムスタンプディレクトリの **絶対パス**（例: `/abs/path/to/repo/.claude/reviews/<PR番号>/<YYYYMMDD_HHMMSS>`）。Bash ツールへ渡す全パスは必ず絶対パスで指定する。
- `codex review` には `--base` を **渡さない**。codex 0.121.0 時点で `--base <BRANCH>` と `[PROMPT]`（`-` 含む）は同時指定できないため、base ブランチ情報・diff テキストは **プロンプトファイル内に埋め込んで stdin から渡す**。
- `<REVIEW_DIR>/prompt_{n}_c{k}.md` の中身は Coordinator が生成し、以下を含める:
  - 出力フォーマット仕様（本ドキュメントの該当テンプレート抜粋）
  - PR 番号・PR タイトル（シェル引数として渡さず、ファイル本文として書く）
  - Coordinator が事前に `git diff <base>...<head>` で取得した **diff テキスト本体**（Claude Reviewer に渡すものと同一）
  - 出力指示（冒頭 `# Review {n}-c{k}: PR #{PR番号} — {タイトル}`、severity 分類、末尾 `## Verdict` セクション、Severity と Verdict の対応規則に従うこと）
- 複数の codex Reviewer を起動する場合は、各プロセスで `k` の値を変え、プロンプトファイル・出力ファイル・エラーファイルを分ける。

**失敗検知ルール:** codex は非対話的プロセスとして走るため、以下の検知を必ず行い、失敗／不適合の出力は **glob（`review_{n}_*.md`）に拾われないようにする**:

1. **終了コード非 0** → その Reviewer は失敗扱い。
2. **出力ファイルに `## Verdict` 行が含まれない**、または **ファイルサイズが著しく小さい（概ね 100 バイト未満）** → 不適合として破棄。
3. 失敗・不適合の場合は、当該 `review_{n}_c{k}.md` を `.failed` 拡張子にリネーム（例: `review_{n}_c{k}.md.failed`）するか削除して、`review_{n}_*.md` glob の対象から外す。
4. stderr は `review_{n}_c{k}.err` に退避し、デバッグ用に保持する（成功・失敗を問わず残してよい）。
5. 上記のうちいずれかを満たした Reviewer については「部分的失敗時の振る舞い」ルールに従う。

**Claude Reviewer についても同様の原則を適用する:** Task ツールで起動した Claude Reviewer がエラー／タイムアウトで結果を返せなかった場合、Coordinator は当該出力ファイル（生成されていれば）を削除または `.failed` にリネームし、以降の `review_{n}_*.md` glob に拾われないようにする。

**codex 出力フォーマットの逸脱ハンドリング:** codex は必ずしも上記テンプレート通りに出力するとは限らない。Coordinator は以下の方針で許容／破棄を判定する:

- **許容する逸脱**（Coordinator が統合時にマッピング）:
  - 冒頭見出し（`# Review {n}-c{k}: ...`）が欠ける
  - Severity が P1/P2/P3 など代替表記で書かれている
  - 本文冒頭に Summary 相当の前置き（1〜3 行程度）が挿入されている
- **破棄する逸脱**（上記「失敗検知ルール」に従い `.failed` 化 or 削除）:
  - 出力ファイルが空
  - 終了コードが非 0
  - Approve / Request Changes / Comment のいずれにも読み取れる最終判定（`## Verdict` 相当）が存在しない
- **Severity マッピング指針:** `P1` → High 以上、`P2` → Medium、`P3` / `nit` → Low / Nit。Coordinator は `task_{n}.md` の採番時に統合 Severity を再決定する。

### Coordinator が判断時に参照する情報

Coordinator はメインセッションの Claude（またはユーザー）であり、サブエージェントとして起動されるわけではない。以下の情報はメインセッションのコンテキストとして既に保持しているか、直接参照できるものである。

- 全 Reviewer の `review_{n}_*.md`
- コードベースの知識（アーキテクチャ方針など）— メインセッションのコンテキストとして保持

### Implementer への入力

- `task_{n}.md`（**主たる作業指示・唯一の権威的ソース。** Accept 項目のみが実装対象）
- `review_{n}_*.md`（補助的参照。Accept された指摘の背景理解・詳細コンテキスト確認用であり、作業指示としては扱わない）

### 実行例

ユーザーが Coordinator（メインの Claude）に対してレビューワークフローの実行を指示する。Coordinator は以下のようにサブエージェント／外部プロセスを起動してサイクルを回す。

```
# 0. Coordinator が引数を解釈
#    /review-fix の引数から N（claude=）と M（codex=）を決定する。
#    引数なし → N=2, M=0。
#    引数あり → 明示された値のみ有効、未指定は 0。N+M=0 はエラーでサイクル中断。

# 1. Coordinator がタイムスタンプディレクトリを作成
#    .claude/reviews/<PR番号>/<YYYYMMDD_HHMMSS>/ を作成。
#    過去のディレクトリは削除しない。

# 2. Coordinator が Reviewer を並列起動（1 メッセージ内にまとめて発行）
#    事前に: `gh pr view <PR番号> --json baseRefName -q .baseRefName` で base を取得し、
#    `git diff <base>...<head>` で diff テキストを一度だけ生成する。
#    codex=M>=1 の場合は `command -v codex` でプリフライトを行い、
#    見つからなければインストール手順を添えて中断する。
#    - Claude Reviewer（N 名）: Task ツール（subagent_type: general-purpose）
#      を N 個並べて呼び出し、review_1_1.md … review_1_N.md を生成。
#      プロンプトには上で取得した diff テキストを埋め込む。
#    - codex Reviewer（M 名）: Bash ツールで
#      `codex review - < <REVIEW_DIR>/prompt_1_c{k}.md > <REVIEW_DIR>/review_1_c{k}.md 2> <REVIEW_DIR>/review_1_c{k}.err`
#      形式のコマンドを M 個並べて呼び出し、review_1_c1.md … review_1_cM.md を生成。
#      プロンプトファイルは Write ツールで事前作成し、Claude に渡したものと同じ
#      diff テキストを埋め込む（`--base` は渡さない）。出力先は絶対パス。
#    Task 呼び出しと Bash 呼び出しは同一メッセージ内に混在させて同時発行する。
#    起動後、終了コード非 0 や `## Verdict` 欠落 / 極端に小さいファイルは
#    `.failed` にリネームするか削除し、`review_1_*.md` glob から外す。

# 3. Coordinator 自身が全 review_1_*.md を読み込み、統合・精査し task_1.md を作成
#    指摘の重複排除・Verdict 統合・Accept / Reject の判断はメインセッションで行う。
#    Claude 出力と codex 出力を区別せず、同一の統合ルールを適用する。

# 4. Accept 項目がある場合、Coordinator が Implementer サブエージェントを起動
#    Task ツールで別 Claude を起動し、task_1.md の Accept 項目を実装させる。

# 5. 再び Reviewer を並列起動 → 終了条件を満たすまで繰り返し
```
