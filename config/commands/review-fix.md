# Review and fix a pull request

## 概要

PR に対して Claude による自動レビューサイクルを回し、品質を担保する仕組み。
3 つのロール（Reviewer / Coordinator / Implementer）が協調し、指摘の発見・精査・実装を繰り返す。

同一 PR に対して `/review-fix` を並行実行することはサポートしない。複数インスタンスを同時起動した場合の挙動は未定義（タイムスタンプディレクトリ衝突、Implementer push 競合等が発生しうる）。ロック機構は実装しないため、運用者が並行起動しないよう管理すること。

## 引数

```
/review-fix <PR番号>
```

- `<PR番号>`: 必須。レビュー対象の PR 番号（正の整数）。
- 非整数・負数・ゼロ・欠落は即エラーとし、サイクルを開始しない。
- Coordinator は引数を**前後の ASCII 空白文字を trim した上で**、正規表現 `^[1-9][0-9]*$` に対して検証する。trim 後にマッチしない場合は即エラーとする（例: `0`, `+5`, `5.0`, `05`, `５`, `5a` はいずれも不正）。
- **trim 対象の空白文字は ASCII 範囲の `[ \t\n\r\f\v]`（半角スペース / タブ / LF / CR / FF / VT）のみ。** Unicode 空白（NBSP `U+00A0`、全角空白 `U+3000`、ZWSP `U+200B` 等）は trim 対象外であり、これらが残った文字列は正規表現にマッチせず不正として即エラー扱いとする。実装言語に依存せず一意な挙動を保証する。
- trim を入れる理由: コピペ等で末尾に空白が混入したケース（例: `"5 "`, `" 5"`, `"5\t"`）で即エラーとすると UX フリクションが高い。一方、trim という 1 段階の内部正規化を経由することで最終的な regex マッチの一意性は保たれるため、厳密性を損なわずに UX を改善できる。
- 全角数字（例: `５`）は trim 対象外であり、trim 後も正規表現にマッチしないため不正として即エラーとする。

## 前提条件

以下の条件を満たす環境で実行されること。**各条件の具体的な検証手順は Coordinator が Preflight で実行する**（詳細は後述の「各ロールの責務 → Coordinator」セクションを正本として参照 — 本セクションは条件の列挙に留める）。

- **対象 PR が GitHub 上に存在し、参照可能であること。**
- **対象 PR が `origin` remote のブランチから作成されていること（origin-based PR）。** fork から作成された PR は本スキルのサポート対象外（remote 名の解決が `origin` 固定のため）。
- **対象 PR の state が `OPEN` であること。** Draft PR は `OPEN` として扱い許容する（後述の「設計判断: Draft PR を許容する」を参照）。
- **`/review` スキルが Coordinator・Reviewer サブエージェントの両環境で利用可能であること。** 未インストール環境では本スキルは動作しない（フォールバックは提供しない）。Coordinator が事前検知する手段はないため、未インストール時は Reviewer サブエージェント起動時の失敗として現れる（後述「部分的失敗時の振る舞い」参照）。
- **ローカルの作業ディレクトリが対象 PR のブランチにチェックアウト済みで、未 push のローカル変更がないこと。** Reviewer は GitHub 上の PR をレビューするため、最新コミットが push されている必要がある。具体的には以下の 2 条件を**両方**満たすこと:
    - 現在のブランチが PR ブランチと一致している（detached HEAD や別ブランチでないこと）。
    - 未 push のローカルコミットが存在せず、未ステージ・ステージ済み未コミットの変更もないこと。
- **checkout 責任の所在**: ユーザーは `/review-fix` 実行前に `gh pr checkout <PR番号>` 等で PR ブランチに**事前に切り替えておく必要がある**。Coordinator は Preflight (c-1) で現在の HEAD と PR ブランチ名の一致を検証し、不一致の場合はエラーメッセージで `gh pr checkout <PR番号>` を案内して即中断する（Coordinator は自動で checkout を実行しない — ユーザーのローカル未 push コミットを誤って破壊しないための設計）。

> **設計判断: Draft PR を許容する**
>
> 本スキルは Draft PR も対象に含める。実装上、Coordinator は `gh pr view <PR番号> --json state` の結果のみを検証し、**`isDraft` フィールドは参照しない**。理由は以下の通り:
>
> - Draft でもコードレビュー自体は可能であり、「Draft 段階でレビューサイクルを回して完成度を上げる」ユースケースを明示的にサポートしたい。
> - 現行の `gh` CLI および GitHub GraphQL API では、`state` は `OPEN` / `CLOSED` / `MERGED` の 3 値のみで Draft PR は `OPEN` として返される。そのため追加の `isDraft` 判定は不要。
> - 仮に将来の `gh` CLI / GitHub API 挙動変更で state が細分化された場合も、「Draft を許容する」という本仕様の意思決定は変わらず、検証ロジックの調整のみで対応する。

> **設計判断: Round 2 以降で `headRefName` / `isCrossRepository` を再検証しない**
>
> Round 2 以降の軽量再検証では **`state` のみ**を対象とし、`isCrossRepository` と `headRefName` は Round 1 の Preflight 時点から不変として再検証しない。理由は以下の通り:
>
> - PR の base/head 変更（fork 化、ブランチ名変更）は実務上稀で、発生頻度 × 検証コスト（毎ラウンド余計な `gh pr view` 呼び出し）のトレードオフで非検証を選択している。
> - 仮に Round 2 以降でブランチ名が変化した場合でも、Implementer の `git push origin HEAD:<PR ブランチ名>` 実行前の branch-match 検証（`git symbolic-ref --short HEAD` と渡された PR ブランチ名の比較）で不一致として検出される（異常時の実被害は Implementer 側で止まる）。
> - 仮に fork 化（`isCrossRepository` が `true` に変わる）した場合、Implementer の push は fork 先の remote が `origin` に設定されていない限り失敗する。このケースも事後検知できる。
> - 毎ラウンドの再検証を行わないことによる運用上の未検知リスクは限定的と判断し、軽量性を優先する。

> **Note（中断後の復旧）:**
>
> - Implementer の push 失敗等でサイクルが中断された場合、ローカルに未 push コミットが残る。次回 `/review-fix` 実行前に手動で `git push`（または `git reset --hard origin/<branch>` で破棄）して Preflight 条件を満たすこと。自動復旧は行わない。
> - **※ 警告: `git reset --hard origin/<branch>` はローカルの未 push コミットを破棄する破壊的操作である。** push したくないが残したい変更がある場合は、先に別ブランチへ退避（例: `git branch <退避ブランチ名>`）してから実行すること。退避せずに実行するとローカルの未 push コミットは復元不可能になる（`git reflog` で救える期間はあるが保証なし）。
> - 中断時に生成済みの `review_{n}_*.md` / `task_{n}.md` は削除しない（履歴として残す）。次回 `/review-fix` 実行は**新しいタイムスタンプディレクトリで Round 1 から再開**する（過去のタイムスタンプディレクトリは参照しない）。
> - 中断前に push 済みのローカルコミットは PR ブランチに残るため、次回 Round 1 の Reviewer は当該コミットを含む PR 状態に対してレビューを行う。

## フロー

```
  ┌─────────────────────────┐
  │ PR 作成 / レビュー指示  │
  └───────────┬─────────────┘
              │
              ▼
  ┌──────────────────────────────────────────────────┐
  │ Preflight（サイクル開始時に 1 回のみ）           │
  │  - 引数検証（trim 後 regex `^[1-9][0-9]*$`）     │
  │  - 前提条件確認（PR 参照可否 + ローカル clean）  │
  │  - タイムスタンプディレクトリ作成                │
  │    ※ ディレクトリ作成は他検証が全 PASS 後のみ   │
  └───────────┬──────────────────────────────────────┘
              │
              ▼
  ┌──── Round n ──────────────────────────────────────────────────────────────────┐
  │                                                                              │
  │  ┌─── Reviewers（並列 K 名 = デフォルト 2 / Task ツールで同時起動）───┐    │
  │  │  各 Reviewer は Skill(skill="review", args="<PR番号>") を呼び出す    │    │
  │  │  Reviewer 1 → review_{n}_1.md                                       │    │
  │  │  Reviewer 2 → review_{n}_2.md                                       │    │
  │  │  …                                                                   │    │
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
  │  │ git commit + push        │                                      │       │
  │  └────────────┬─────────────┘                                      │       │
  │               │                                                    │       │
  └───────────────┼────────────────────────────────────────────────────┼───────┼┘
                  │                                                    │       │
                  ▼                                                    ▼       ▼
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │                           次の Round / 終了                                  │
  │  ※ Round 2 以降は各ラウンド開始時に `gh pr view --json state` を再検証し、   │
  │     OPEN 以外なら即中断（Coordinator 責務セクション参照）                    │
  └──────────────────────────────────────────────────────────────────────────────┘
   (max 10 rounds)
```

> **1 ラウンドの定義:** Reviewers（並列 K 名）→ Coordinator（統合・精査）→ Implementer（Accept 項目がない場合は Implementer をスキップ）の 1 サイクルを 1 ラウンドと数える。

## ディレクトリ構造

```
.claude/reviews/            # レビューアーティファクト（プロジェクト内に配置）
  <PR番号>/                 # PR ごとにディレクトリを分離（並行レビュー対応）
    <YYYYMMDD_HHMMSS>/     # 実行ごとにタイムスタンプディレクトリを作成（履歴保持）
      review_1_1.md         # Round 1, Reviewer 1
      review_1_2.md         # Round 1, Reviewer 2
      task_1.md             # Round 1 タスク（統合済み）
      review_2_1.md         # Round 2, Reviewer 1
      review_2_2.md         # Round 2, Reviewer 2
      task_2.md             # Round 2 タスク
      ...
```

> **Note:** レビューアーティファクトはプロジェクト内の `.claude/reviews/` 配下に保存される。`install.sh` を実行済みの場合、グローバル gitignore（`core.excludesFile`）に `.claude/reviews/` が自動追加されるため、各リポジトリでの手動設定は不要である。`install.sh` を実行していない環境で使用する場合は、**レビュー対象のリポジトリ**の `.gitignore` に `.claude/reviews/` を手動で追加すること。

### ナンバリング規則

- PR ごとに `.claude/reviews/<PR番号>/` ディレクトリを使用する。
- レビューサイクル開始時に **Coordinator** が `<YYYYMMDD_HHMMSS>` 形式のタイムスタンプディレクトリを新規作成する。過去のタイムスタンプディレクトリは削除しない（履歴として保持される）。不要になった古いタイムスタンプディレクトリはユーザーが手動で削除してよい。
- 同一タイムスタンプディレクトリ内では `review_1_1.md`, `review_1_2.md` → `task_1.md` → `review_2_1.md`, `review_2_2.md` → `task_2.md` … と連番で進む。
- ファイル命名規則: `review_{n}_{m}.md`（n = ラウンド番号, m = レビュアー番号）、`task_{n}.md`（n = ラウンド番号）。
- タイムスタンプは秒精度のため、同一 PR で 1 秒以内に複数回 `/review-fix` を起動した場合は `mkdir` 衝突で Preflight が失敗する。リトライは 1 秒以上待機すること。なお、本ツールは並行実行非サポート（前提条件参照）のため、衝突は通常発生しない。

## 各ロールの責務

### Reviewer

Reviewer サブエージェントは以下の **3 ステップ** を順に実行する:

1. **Skill 呼び出し (`/review` 実行)**
    - **Skill ツールでの明示呼び出し形式**: Reviewer サブエージェントのプロンプトには「`Skill(skill="review", args="<PR番号>")` を明示的に呼び出す」旨を必ず記載する。応答テキスト（自由形式マークダウン）を取得する。
    - **args 空渡し禁止**: `args` には PR 番号を必ず**文字列として**埋め込む。空文字列・未置換テンプレート変数（例: `args=""`, `args="{pr_number}"`）での Skill 呼び出しは行わない。`/review` スキルは args 空の場合 `gh pr list` へ分岐するため、no-op / 誤動作の原因となる。
    - **自然言語表現では起動しない (no-op) 理由**: 自然言語で `/review <PR番号>` と記載するだけでは Task ツール経由で起動されたサブエージェントからはスキルが起動されず、no-op となる点に注意。
    - **`/review` スキル可用性の前提**: この Skill 呼び出しはサブエージェントが `/review` を利用可能であることを前提とする（前提条件セクション参照）。

2. **テンプレート整形（本 spec の `review_{n}_{m}.md` テンプレートに再構築）**
    - 取得した `/review` 応答（自由形式マークダウン）を、本ドキュメントの「ファイルフォーマット → `review_{n}_{m}.md`」テンプレート（Summary / Findings（severity別） / Verdict）に整形する。
    - **`/review` スキルの出力形式前提**: 本 spec では `/review` は**自由形式のマークダウンテキスト**を返す前提で扱う。Reviewer は `/review` の出力文面を解釈し、本ドキュメントの「Severity レベルの定義」表に基づいて指摘を分類する。
    - **`/review` の severity ラベルは無視する（強い禁止）**: `/review` が内部的に独自の severity ラベル（例: `[HIGH]`, `priority: medium` 等）を付与している場合、**そのラベルは無視し、必ず本ドキュメントの「Severity レベルの定義」表のみを基準に再分類する**。`/review` のラベルを継承してはならない（ラベル変換ではなく、Reviewer 自身が本 spec 基準で分類し直す）。
    - これにより、`/review` が severity ラベルを付けていない場合も「本ドキュメント基準での分類を行う」という同一の手順で吸収される（初分類と再分類を区別しない）。
    - 将来 `/review` の出力形式が構造化データ（JSON 等）に変化した場合は、本 spec の Reviewer 責務セクションで前提を更新する。それまでは「マークダウンテキスト + 本 spec の severity 基準」を正本とする。

3. **書き出し（Write ツールで絶対パスに保存）**
    - Coordinator から指定された絶対パス（`<REVIEW_DIR>/review_{n}_{m}.md`）に Write ツールで書き出す。
    - **書き出しの主体は Reviewer サブエージェント自身であり、`/review` スキルではない**（`/review` は自由形式マークダウンを返すのみでファイル出力は行わない）。

**その他の Reviewer 規約:**

- 毎ラウンド、前ラウンドの情報を持たない状態でフレッシュにレビューする。
- 各 Reviewer は互いの存在を知らず、独立してレビューを行う。
- デフォルトで 2 名を並列起動する。Coordinator の判断で増減可能。

### Coordinator（メインの Claude または人間）

**Preflight 検証（前提条件セクションの条件を検証する正本手順。サイクル開始時に 1 回のみ実行）**

以下の (a)〜(d) を**記載の順序**で実行する。いずれかのステップで失敗したら、**その時点で即サイクルを中断する**（後続ステップは実行しない。タイムスタンプディレクトリ作成は全 PASS 後にのみ行う）。

> **外部コマンド自体の失敗時ハンドリング（Preflight 全ステップ共通）:**
>
> Preflight 内で実行する `gh pr view` / `git fetch` / `git symbolic-ref` / `git rev-list` / `git status` などの外部コマンドが **exit code 非 0 で終了した場合**（ネットワーク障害、認証エラー、remote 側ブランチ削除済み、gh トークン失効など「結果が得られないケース」）は、**コマンド名と stderr を含むエラーメッセージを出力して即サイクルを中断する**。リトライは行わない。これは「結果が `true`」「結果が `OPEN` 以外」といった**正常応答に基づく判定**とは別枠の扱いであり、仕様として明示的に区別する。以下の (a)〜(d) の各ステップで外部コマンドが失敗した場合も本ハンドリングが適用される。

- **(a) 引数検証**
    - 引数の前後の **ASCII 空白文字 `[ \t\n\r\f\v]`** を trim した上で、正規表現 `^[1-9][0-9]*$` にマッチすること（マッチしない場合は「引数が不正」のエラーで即中断）。Unicode 空白（NBSP / 全角空白 / ZWSP 等）および全角数字は trim 対象外であり、不正として扱う。詳細は「引数」セクション参照。
- **(b) PR 情報取得 + 参照可否・種別・state 検証**
    - `gh pr view <PR番号> --json isCrossRepository,state,headRefName` を実行し、`isCrossRepository` / `state` / PR ブランチ名 `<branch>` をまとめて取得する（※ 可読性のため本節以降では論理的に 3 フィールドをステップ分割して説明するが、実装上は上記のように 1 コールに集約してよい）。
    - `isCrossRepository` の値判定（**fail-safe**）: **`false` のみが origin-based PR として続行可能**。`true` の場合は「fork PR は現状サポート外」のエラーで即中断する。**`null` / 欠落 / その他の値が返った場合は fail-safe で fork PR 扱いとし、「`isCrossRepository` が想定外の値（`<取得値>`）。fork PR と見なして中断」の明示的エラーで即中断する**（将来の gh CLI 仕様変更や API エラーへの防御）。
    - `state` が `OPEN` 以外（`CLOSED` / `MERGED`）の場合は「PR state が <state> のためレビュー不可。再オープン後に再実行」のエラーで即中断する。
- **(c) ローカル clean 検証**
    - (c-1) `git symbolic-ref --short HEAD` の出力が (b) で取得した `<branch>` と一致すること。
        - 非 0 終了（detached HEAD）の場合は「HEAD が detached 状態のため `gh pr checkout <PR番号>` を実行してから再実行してください」のエラーで即中断。
        - 正常終了かつ `<branch>` と不一致の場合は「現在 <actual> にチェックアウト中。`gh pr checkout <PR番号>` を実行して `<branch>` に切り替えてから再実行してください」のエラーで即中断。
        - **このチェックを必須とする理由:** HEAD が偶然 `origin/<branch>` と同一コミットを指す別ブランチ（例: main が PR ブランチ先頭と同位置）にある場合、rev-list 単独では偽 PASS する。また Implementer の `git push origin HEAD:<branch>` で別ブランチのコミットが PR ブランチに上書きされる実被害を防ぐ。
        - **エラーメッセージに `gh pr checkout` を案内する理由:** 前提条件セクションで「ユーザー側で事前に checkout する」ことを要求しているため、エラー時には満たし方のヒントとして同コマンドを提示する（Coordinator は自動 checkout を行わない）。
    - (c-2) `git fetch origin <branch>` で remote-tracking ref を最新化する。
        - ※ `git fetch origin <branch>` は local の `refs/remotes/origin/<branch>` を更新する**副作用のあるコマンド**である（その他の local branch 状態には影響しない）。「Preflight は参照のみ」と誤解しないこと。
        - この fetch が無いと、別環境からの push 後に `origin/<branch>` が古いまま残り、後続の `rev-list` が「未 push コミットあり」と誤判定して Preflight が不当に abort する。
    - (c-3) 以下の**両方**の出力が空であること:
        - `git rev-list "origin/<branch>..HEAD"`（未 push コミットなし）。`@{u}`（upstream）は参照しない — Implementer が `git push origin HEAD:<branch>` を使うため upstream が未設定でも正常動作させるため。
        - `git status --porcelain`（未ステージ・ステージ済み未コミット変更なし）。
- **(d) タイムスタンプディレクトリ作成（上記 (a)〜(c) が全て PASS した後にのみ実行）**
    - まず `git rev-parse --show-toplevel` でリポジトリルートの絶対パスを取得する（本セクション以降「REPO_ROOT」と呼ぶ）。
    - `<REVIEW_DIR>` = `<REPO_ROOT>/.claude/reviews/<PR番号>/<YYYYMMDD_HHMMSS>/` の形で**絶対パスとして構築**する。
    - `mkdir -p <REVIEW_DIR>` を**絶対パス指定**で実行する。Coordinator の cwd が repo root でない場合（サブディレクトリから `/review-fix` を呼び出した場合など）や、ツール呼び出しで cwd リセットが発生する場合でも、絶対パス指定により意図しない場所への作成を防ぐ。
    - 以降 Reviewer / Implementer プロンプトに渡す絶対パスはすべてこの `<REVIEW_DIR>` を基底とする（既に絶対パスを渡す方針のため、Preflight 段階で絶対パス解決を統一する）。
    - **(a)〜(c) の前に作成しない理由:** fork PR 検出 (b) や detached HEAD 検出 (c-1) で中断した場合に無駄なディレクトリが残らないよう、全検証 PASS を作成の必要条件とする。

**その他の責務**

- Reviewer サブエージェントを並列起動し、PR 番号・出力先絶対パス・フォーマット指示を渡す（diff テキスト自体は Coordinator が渡さない）。
- **Round 2 以降の `state` 再検証**: 各ラウンド開始時（Reviewer 起動前）に `gh pr view <PR番号> --json state -q .state` を再実行し、`OPEN` 以外（`CLOSED` / `MERGED`）が返された場合は「PR state が <state> に変化したためサイクルを中断」のメッセージで即終了する。これは Preflight の一部ではなく、長時間レビュー中に PR が手動で close/merge されるケースに備えた軽量な再検証である（`git push` は closed PR に対しても成功するため、気付かずに closed PR にコミットが積まれる実害を防ぐ）。Preflight の他項目（`isCrossRepository`, `headRefName` 等）の Round 2 以降での非再検証については後述の「設計判断: Round 2 以降で `headRefName` / `isCrossRepository` を再検証しない」を参照。外部コマンド失敗時の扱いは Preflight と同様（コマンド名・stderr を含むエラーで即中断）。
    - **idempotent 性の注記**: `gh pr view --json state` は軽量かつ idempotent な操作であり、同一ラウンド内で複数回実行されても問題ない（Round 開始時の通常検証と部分失敗時の診断検証は独立した目的を持つため、重複実行を最適化しない）。
- 全 Reviewer の `review_{n}_*.md` を読み込み、指摘を重複排除・統合する。同一の論理的問題に対して複数 Reviewer が異なる severity を付けた場合は、高い方を採用する。「同一の論理的問題」の判断基準: 同一のルートコーズに起因する指摘、または同一ファイル・同一関数に対する同種の懸念（例: 同じ関数のエラーハンドリング不足を別 Reviewer が別表現で指摘した場合）は同一とみなす。逆に、同じコード領域でも異なる種類の問題（例: null チェック欠如とエラーメッセージ不足）は別の指摘として扱う。
- Verdict を統合する（最も厳しいものを採用: Request Changes > Comment > Approve）。
- 統合した指摘に対して **Accept（対応する）** か **Reject（対応しない）** を判断し、**`<REVIEW_DIR>/task_{n}.md`（絶対パス）** に出力する。`review_{n}_*.md` と同じタイムスタンプディレクトリに配置すること。Finding ID は Coordinator が統合時に採番し直す。
- 過剰な指摘・スコープ外の提案・費用対効果の低い項目はフィルタリングする。**フィルタリングで除外した指摘も `task_{n}.md` の Reject セクションに記録する**（理由欄には「フィルタ: スコープ外」「フィルタ: 費用対効果不足」など、フィルタ除外である旨と具体的理由を明示する）。これは次項の「累計 2 回以上 Reject 判定」を機能させるため必須である（フィルタ除外が記録されないと、同じ指摘が毎ラウンド黙殺されて累計カウントに載らず、サイクルが無駄に継続する）。
- Reject には必ず理由を明記する。**累計カウント対象は「明示的 Reject」と「フィルタ除外」の両方を含む**（詳細は次項の累計 2 回以上 Reject 判定を参照）。
- Round 2 以降は、前ラウンドの修正が正しく行われたかを自身で検証する（Reviewer には前ラウンド情報を渡さない）。
- **同一論理的問題が累計 2 回以上 Reject された場合の判定**: Round 2 以降、Coordinator は統合後の指摘リストを**タイムスタンプディレクトリ内の全過去ラウンド `task_*.md`**（`task_1.md`〜`task_{n-1}.md`）の Reject 項目（**明示的 Reject・フィルタ除外の両方**を含む。および Accept 後も同一論理的問題として再発した項目）と比較する。同一論理的問題が**累計 2 回以上 Reject 候補となった場合**（直前ラウンドのみでなく、「Round 1, 2 で Reject → Round 3 で言及なし → Round 4 で再 Reject」のような非連続パターンも含む）、Coordinator は以下のいずれかを選択する:
    - (a) 当該指摘を残課題として Issue 化してサイクル終了する（記録を残して人間に判断を委ねる）。
    - (b) 人間にエスカレーションして対応方針を決定する。
    - **判定基準（Coordinator の総合判断）:** 「同一論理的問題か」の判定は、Finding タイトル文字列の類似性、対象ファイル/関数の一致、指摘の論点の一致を Coordinator が総合的に判断する。厳密な類似度閾値（文字列一致率など）は設けず、Coordinator が「実質的に同じ指摘か」を判断する。「同一の論理的問題」の一般的判断基準（前述の重複排除規則）を流用し、複数ラウンドに跨る判定に拡張する形となる。
- **Implementer 起動時の入力**: Implementer サブエージェントを起動する際は、`<REVIEW_DIR>/task_{n}.md` の絶対パス・`<REVIEW_DIR>/review_{n}_*.md` の絶対パス・PR 番号・PR ブランチ名（Preflight (b) で取得した `<branch>`）をプロンプトに含めて渡す。Implementer 側での `gh pr view` 再呼び出しを避けるため、Coordinator が取得済みの branch 名を再利用する。
- **Reviewer 成功数不足時の警告記録**: Reviewer の成功数が想定 K 未満（特に 1 名のみ成功）の場合、Coordinator は `<REVIEW_DIR>/task_{n}.md` の冒頭またはユーザー向けレポートに「Round n は K=◯ 中 ◯ 名のみ成功。統合品質が低下している可能性あり」を警告として記録する。暗黙に 1 名動作にフォールバックせず、必ず明示する。

### Implementer

- `task_{n}.md`（**絶対パス** `<REVIEW_DIR>/task_{n}.md`、Coordinator が起動時にプロンプトで渡す）の Accept 項目を実装する。**`task_{n}.md` が唯一の権威的な作業指示であり、ここに記載された Accept 項目のみが実装対象となる。**
- 指摘の背景や詳細なコンテキストが必要な場合は `<REVIEW_DIR>/review_{n}_*.md`（絶対パス）および設計ドキュメントを補助的に参照してよいが、`review_{n}_*.md` 内の指摘を独自に作業項目として扱ってはならない。
- PR ブランチに追加コミットし、リモートに push する（次ラウンドの Reviewer が `/review` で最新状態を参照できるようにするため、push は必須）。
- **PR ブランチ名の取得方針**: PR ブランチ名は **Coordinator が Implementer 起動時にプロンプトで渡す**（Coordinator の Preflight (b) で `gh pr view <PR番号> --json headRefName` 経由で取得済みのため再取得しない）。Implementer は渡された branch 名を防御的検証にのみ使用し、`gh pr view` の再実行は行わない。
- **開始時 HEAD の記録（START_HEAD）**: 実装開始時（Edit ツール等でファイル修正を始める前）に `git rev-parse HEAD` の出力を記録する（本 spec では `START_HEAD` と呼ぶ）。これは後続の並行書き込み検出で使用する基準点である。
- **`${START_HEAD}` はリテラル SHA として埋め込む**: Implementer は `git rev-parse HEAD` の出力（SHA 文字列）を**会話コンテキスト上で保持**し、後続のコマンドには**リテラルの SHA を直接埋め込む形**で実行する（例: 記録した値が `9ca8242df4ef3b7c5...` なら、後続の rev-list コマンドは `git rev-list "9ca8242df4ef3b7c5....origin/<PR ブランチ名>"` の形で実際の SHA を埋め込む — `..` は 2 点リーダー式のリビジョン範囲記法）。**サブエージェントの bash 呼び出しはシェル状態を跨がないため、`export START_HEAD=...` のような環境変数では持ち回せない**。spec 本文中の `${START_HEAD}` 表記は記法上のプレースホルダであり、実行時は必ずリテラル値に置換する。

**コミットポリシー**

Implementer は各ラウンドの実装完了時に以下のポリシーに従って commit を作成する:

- **新規 commit を作成する**: 既存 commit の amend（`git commit --amend`）は行わない。push 履歴の一貫性確保（各ラウンドで何が行われたかを後から追跡可能にすること）のため、必ず新規 commit を積む。
- **コミットメッセージ形式**: 1 行目（subject）に**ラウンド番号を必ず含める**。推奨形式は `Address Round {n} review feedback on /review-fix spec`（対象 PR に応じて spec 名を置き換えてよい）。これにより後から `git log --grep "Round {n}"` でラウンド単位の追跡が可能となる。
    - **spec 名の決定ルール**: 「spec 名」は PR タイトルから抽出する（例: PR タイトル「Refactor /review-fix to take PR number and delegate to /review skill」なら spec 名は `/review-fix`）。PR タイトルから抽出困難な場合は、対象ファイルの主ディレクトリ名を使用してよい（例: `config/commands/<name>.md` が主たる変更対象なら spec 名は `/<name>`）。Implementer は Coordinator からのプロンプトに PR タイトルが含まれていることを期待し、必要に応じて抽出する。
- **粒度**: 原則として **1 ラウンド = 1 commit** を推奨する。実装規模が大きい場合は複数 commit に分割してもよいが、その場合も subject にラウンド番号を含めることで grep 可能性を保つこと。
- **signing**: 環境設定（`commit.gpgsign` 等）に従う。spec として署名を強制しない。
- **Co-Authored-By**: 既存リポジトリ慣習に従う。必須化はしない（リポジトリ慣習が無い場合は省略可）。

**push 実行前の検証（以下の 2 つを順に実施）**

- **(1) 現在ブランチ確認**: `git symbolic-ref --short HEAD` の出力が、Coordinator から渡された PR ブランチ名と一致することを確認する。不一致の場合は push せず、エラー内容を Coordinator に報告してサイクルを中断する（別ブランチのコミットが `git push origin HEAD:<PR ブランチ名>` で PR ブランチに上書きされる実被害を防ぐため）。
- **(2) 並行書き込み検出（START_HEAD ベース）**: `git fetch origin <PR ブランチ名>` で remote-tracking ref を最新化した後、`git rev-list "${START_HEAD}..origin/<PR ブランチ名>"` の出力が**空であること**を確認する。これは「Implementer が実装を開始した時点の HEAD（`START_HEAD`）から push 前までの間に、他者が `origin/<PR ブランチ名>` に push していないこと」を検証する。出力が空でない場合は「他者の push が割り込んだ可能性あり」と判断し、push せず Coordinator に以下のエラーメッセージで報告してサイクルを中断する: 「他者の push が割り込んだ可能性があります。`git pull --rebase origin <PR ブランチ名>` 後に `/review-fix` を再実行してください」。
    - **この方式を採る理由:** `git rev-list A..B` は「B から到達可能で A から到達不可能なコミット」を返す。`${START_HEAD}..origin/<PR ブランチ名>` は「`origin/<PR ブランチ名>` から到達可能で `START_HEAD` から到達不可能なコミット」 = 他者が並行 push したコミットを正確に返す。Implementer 自身の commit は local HEAD 側にのみ存在し `origin/<PR ブランチ名>` には未反映のため含まれない。結果として Implementer が 1 ラウンドで複数 commit を作成するケース（大規模な Accept 項目に対応する等）でも、自身が作成した commit 数に依存せず並行書き込みだけを正確に検出できる。逆向きの `origin/<PR ブランチ名>..${START_HEAD}` は「START_HEAD から辿れて origin から辿れない = Implementer 自身のコミット（push 前）または存在しない」を返し、並行 push を検出できない（典型シナリオで偽陰性）。
    - **※ 実装注意:** `${START_HEAD}` は spec 上の記法であり、実際にはリテラル SHA を埋め込んで実行する（前述「開始時 HEAD の記録（START_HEAD）」参照）。
- push コマンドは `git push origin HEAD:<PR ブランチ名>` を使用する（`<PR ブランチ名>` は Coordinator から渡されたもの）。`push.default` 設定・fork 元 PR・トラッキング設定に依存しないよう、引数なしの `git push` は使わない。事前検証で HEAD は PR ブランチ上にあることが保証されているが、別ブランチ上書き事故を二重に防ぐ防御的プログラミングとして明示形式 `HEAD:<PR ブランチ名>` に統一する。
- push が非 fast-forward・認証エラーなどで失敗した場合、Implementer はエラー内容を Coordinator に報告してサイクルを中断する。**force push（`git push -f`, `--force-with-lease` など）は行わない。** 強制更新が必要かどうかの判断は人間に委ねる。

**エラー報告プロトコル（Implementer → Coordinator）**

Implementer は push 失敗・branch 不一致・並行書き込み検出等のエラーが発生した場合、Task ツールの**応答テキスト**として以下の構造化フォーマットで Coordinator に返す:

```
エラー種別: <branch-mismatch / push-non-ff / 並行書き込み検出 / auth-error / その他>
詳細: <stderr 全文または抜粋>
推奨対処: <例: `gh pr checkout <PR番号>` を実行してから再実行 / `git pull --rebase origin <PR ブランチ名>` 後に再実行>
```

Coordinator はこの応答を解釈し、エラー種別と推奨対処をユーザー向けレポートに整形して伝達する。Implementer は独自にエラーログファイルを作成したり、Coordinator を経由せずにユーザーへ直接報告する手段を取らない（Task ツール応答が唯一の報告経路）。

## ロールの実行モデル

各ロールは **独立した Claude インスタンス** で実行する。Coordinator はメインセッション（ユーザーと会話している Claude）が担い、Reviewer と Implementer は Task ツールで別エージェント（サブエージェント）として起動する。

| ロール | 実行主体 | 並列数 | 理由 |
|--------|----------|--------|------|
| **Coordinator** | メインの Claude セッション | 1 | ユーザーとの対話・判断の主体であるため |
| **Reviewer** | Task ツールで起動するサブエージェント | K（デフォルト 2） | 複数の独立した視点でレビューし、指摘の取りこぼしを防ぐため |
| **Implementer** | Task ツールで起動するサブエージェント | 1 | 実装作業を分離し、Coordinator のコンテキストを消費しないため |

> **重要:** Coordinator 自身が Reviewer や Implementer を兼任してはならない。レビューの客観性と、コンテキスト分離による品質を担保するために、必ず別エージェントとして起動すること。

> **Note:** Reviewer を複数名起動する際は、Task ツールの呼び出しを **1 メッセージ内に複数含めて並列起動** すること。順次起動するとレイテンシが増大する。

> **部分的失敗時の振る舞い:** 並列起動した Reviewer の一部がタイムアウト・エラーで失敗した場合、成功した Reviewer のレビュー結果のみで続行する（最低 1 名成功で有効とする）。全員が失敗した場合はリトライを **1 回のみ** 行う。リトライ時は全 K 名を再実行する（失敗した Reviewer のみの再実行ではない）。リトライでも全員が失敗した場合はサイクルを中断して人間に判断を委ねる。
>
> **前提: 全 Reviewer サブエージェントは同一の `/review` 可用性を持つ。** 本 spec では Coordinator 環境の Skill 設定（`/review` がインストール済みであること）が全 Reviewer サブエージェントに継承される想定で設計している。「最低 1 名成功で有効」とするのは**ネットワーク一過性エラー・タイムアウト等の偶発的失敗**に対する許容であり、`/review` 未インストールに起因する失敗は本来発生しない前提である。万一 Reviewer サブエージェント環境で `/review` が未インストール/未到達な設定差異がある場合、本方針では不整合な統合結果を生みうるため、運用者は Coordinator・Reviewer 間の Skill 設定一致を確認すること。
>
> **成功数が K 未満の場合の警告記録:** 詳細は「各ロールの責務 → Coordinator」セクションの「Reviewer 成功数不足時の警告記録」項目を正本として参照（警告内容・出力先・フォールバック禁止の詳細はそちら）。
>
> **部分失敗/全失敗時の PR state 再検証:** 部分失敗または全失敗の場合、Coordinator は Round 2 以降の `state` 再検証と同等の `gh pr view <PR番号> --json state -q .state` を実行し、PR が `OPEN` でなくなっている場合は「PR state が <state> に変化したためサイクルを中断」のメッセージで即終了する。これにより `/review` スキル内部の `gh pr view` / `gh pr diff` が state 起因で失敗したケース（途中で close/merge された）を「ネットワーク障害」から切り分け可能とする。
>
> **全 K 名が失敗した際のエラーメッセージ:** リトライでも全員失敗した場合、Coordinator は中断時のメッセージに以下のように**複数の可能原因を列挙**して表示すること（単一原因固定だと他原因の際にユーザーを誤誘導するため）: 「全 Reviewer が失敗しました。以下の可能性があります: (1) Coordinator 環境では動作したが、サブエージェント環境で `/review` が呼び出せない設定差異（Coordinator・Reviewer 間の Skill 継承不整合）、(2) ネットワーク障害（`/review` スキル内部の `gh pr diff` / Claude API 接続失敗等）、(3) Task ツールのレート制限、(4) PR が途中で変更・削除された。サブエージェントのエラーログを確認してください」。Skill API レベルで未インストールを事前検知する手段が存在しないため、本スキルは「Reviewer 全員失敗」という事後的な症状から複数原因を示唆する方針を取る（事前検知の仕組みは追加しない）。

## Severity レベルの定義

| レベル | 基準 | 典型例 |
|--------|------|--------|
| **Critical** | リリースブロッカー。データ損失・セキュリティ脆弱性・本番障害に直結する | 認証バイパス、データ破壊、機密情報の漏洩 |
| **High** | 機能的なバグまたは重大な設計上の問題 | ロジックバグ、エッジケース未処理、型安全性の欠如 |
| **Medium** | 品質・保守性に影響するが機能は正しい | エラーハンドリング不足、テスト欠如、ドキュメント不整合 |
| **Low** | 改善が望ましいが緊急性は低い | 命名の改善、軽微な非効率、コメント不足 |
| **Nit** | 好みの範囲。対応しなくても問題ない | フォーマット、タイポ、スタイルの一貫性 |

> **Note（同時更新責務）:** 本表を変更する場合、Coordinator が Reviewer サブエージェントに渡すプロンプトに含める Severity 表の記述（「使い方 → Reviewer への入力」セクション、および「実行例 # 2」内の言及）も**同時に更新**すること。Coordinator は spec の現行版を参照元として明示し、静的コピーを最小限に抑えることを推奨（バージョンドリフト防止）。

## ファイルフォーマット

### review_{n}_{m}.md（Reviewer が出力）

**出力先: `<REVIEW_DIR>/review_{n}_{m}.md`（絶対パス）** — Coordinator が Preflight で作成したタイムスタンプディレクトリに配置すること。

```markdown
# Review {n}-{m}: PR #{PR番号} — {タイトル}

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

**出力先: `<REVIEW_DIR>/task_{n}.md`（絶対パス）** — `review_{n}_{m}.md` と同じタイムスタンプディレクトリに配置すること。

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

> **Note（Implementer スキップ時の次ラウンド挙動）:**
>
> Coordinator が全指摘を Reject して Accept ゼロでスキップした場合、Implementer による commit + push が発生しないため、**PR 内容は前ラウンドから変化しない**。結果として、次ラウンドの Reviewer（前ラウンドの情報を持たない）も同様の指摘を返す可能性が高い。**同一論理的問題が累計 2 回以上 Reject された場合**（Coordinator 責務セクションの判定基準を適用）、Coordinator は以下のいずれかを選択することを検討すべき:
>
> - 当該指摘を残課題として残したままサイクルを終了する（記録を残して人間に判断を委ねる）。
> - 人間にエスカレーションして対応方針を決定する。
>
> 単純に 10 ラウンド上限まで繰り返すと、同じ指摘で無駄にサイクルを消費することになる。

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

> **アーティファクトの保管方針:**
>
> 10 ラウンドに到達してサイクルを強制終了した場合も、生成済みのアーティファクト（`review_10_*.md`, `task_10.md` を含む全 `review_{n}_*.md` / `task_{n}.md`）は**削除しない**（履歴として保持する）。次回 `/review-fix` 実行は**新しいタイムスタンプディレクトリで Round 1 から再開**する（過去のタイムスタンプディレクトリは参照しない）。過去の履歴が不要になった場合はユーザーが手動で削除してよい。

## 使い方

各ロールを起動する際に、以下のコンテキストを渡す。

> **`<REVIEW_DIR>` の定義:** 本ドキュメントで使用する `<REVIEW_DIR>` は、Coordinator が Preflight で作成したタイムスタンプディレクトリの**絶対パス** `.claude/reviews/<PR番号>/<YYYYMMDD_HHMMSS>/` を指す。例えば PR #42 を仮に 2026-01-01 00:00:00 に実行した場合、`<REVIEW_DIR>` = `<リポジトリ絶対パス>/.claude/reviews/42/20260101_000000/` となる（日付・時刻は説明のための仮想例）。以降の「出力先絶対パス」指定ではこのプレースホルダを使う。**`<REVIEW_DIR>` は `review_{n}_{m}.md`（Reviewer が出力）と `task_{n}.md`（Coordinator が出力）の両方の出力先である** — 各ラウンドの全アーティファクトは同一タイムスタンプディレクトリに配置される。

### Reviewer への入力

**毎ラウンド共通（Round 1 以降すべて）:**

- PR 番号（Coordinator が引数から受け取ったもの）
- 出力先ファイルの**絶対パス**（`<REVIEW_DIR>/review_{n}_{m}.md`）
- ラウンド番号 (n) とレビュアー番号 (m)
- 出力フォーマット（本ドキュメントの「ファイルフォーマット」セクションの `review_{n}_{m}.md` テンプレート）
- **本ドキュメントの「Severity レベルの定義」表の全文**（Critical / High / Medium / Low / Nit の 5 行と各レベルの基準・典型例）
- **本ドキュメントの「Verdict と Severity の対応規則」表の全文**（Critical/High → Request Changes、Medium → Comment、Low/Nit のみ → Approve の 3 行、および「Medium 以上の指摘がある場合に Approve を出してはならない」旨の重要注記）

> **Severity 表・Verdict 対応表をプロンプトに含める理由:** Task ツール経由で起動される Reviewer サブエージェントは**メインセッションのコンテキストを参照できない**ため、本ドキュメントのリンクや参照だけではサブエージェントが表を読み取れず、「本ドキュメント基準での分類」要件が破綻する。Coordinator は両表の**全文**（見出し・罫線含む）をプロンプト本体に含めて渡す必要がある。

Reviewer サブエージェントは以下の手順で動く:

1. `Skill(skill="review", args="<PR番号>")` を明示的に呼び出して PR をレビューする（diff 取得・解析はスキル内部に委ねる）。**Skill ツール呼び出しの形式で指示する**こと — 詳細は「各ロールの責務 → Reviewer」セクションの no-op 注意書きを参照。
2. `/review` の出力を上記テンプレートに整形する（Summary / Findings（severity別） / Verdict）。この際、severity は本ドキュメントの「Severity レベルの定義」表に従って再分類する（詳細は「各ロールの責務 → Reviewer」セクション参照）。
3. 指定された絶対パスに書き出す。

> **設計意図 (1) — Reviewer に前ラウンド情報を渡さない理由:**
>
> アンカリングバイアスを防ぐため。前ラウンドの指摘に引きずられて「修正の検証」に偏り、新たな視点での問題発見が弱くなることを避ける。前ラウンドの修正検証は Coordinator が自身で行う。

> **設計意図 (2) — diff 取得経路として「各 Reviewer が `/review` 経由で自前取得」を採用する理由:**
>
> **採用した方式:** K 名の Reviewer がそれぞれ `/review` を呼び、スキル内部で `gh pr view` / `gh pr diff` を実行して diff を取得する。
>
> **検討した代替案:** Coordinator が 1 度だけ `gh pr diff` を実行してファイルに保存し、K 名の Reviewer に当該ファイルパスを渡して参照させる方式。
>
> **トレードオフ比較:**
>
> - **代替案のデメリット:** (a) 非構造化 diff（全 Reviewer が共有する 1 ファイル）を受け渡すため、truncate 検出が困難（diff の末尾が欠けても構文上検出できない）。文字エンコーディング差異による改変リスクも同様に持つ。(b) Coordinator が diff ファイルを作り、Reviewer が `cat`/`Read` で何度も参照する構造になり、ファイル作成 + 複数 read の**権限プロンプトが増える**。(c) `/review` スキルが内部で行う diff 取得・整形ロジックを Coordinator 側で再実装する形になり、`/review` の改善が自動伝播しなくなる（スキル再発明）。
> - **採用方式のデメリット:** K 名 × 1 ラウンドあたりの `gh pr view` / `gh pr diff` API 呼び出し回数が K 倍になる（`/review` スキルが内部で複数回呼ぶ場合さらに増える）。large repo / long diff ではレスポンスサイズも大きくなる。なお採用方式でも Coordinator が `review_{n}_{m}.md` を Read する経路があるが、こちらは**構造化されたフォーマット（1 ファイル 1 レビュアー、Summary/Findings/Verdict の決まった見出し）**のため、セクション欠落による truncate 検出が容易で改変リスクは低い。両方式ともファイル経由の受け渡しは避けられないが、「何を受け渡すか（非構造化 diff vs 構造化レビュー結果）」で truncate リスクの非対称性が生まれる。
> - **意思決定:** `gh pr view` / `gh pr diff` を allow リスト（常時許可設定）に含めることで権限プロンプトを抑制し、結果として K 倍の API 呼び出しコストを許容する。レビューロジックの単一ソース性と truncate リスク排除を優先。
>
> **運用上の調整余地:** 実運用で API レート制限やコストが問題になる場合は、Reviewer の並列数 K をデフォルトの 2 から 1 に下げる選択肢がある（Reviewer 責務セクションの「Coordinator の判断で増減可能」参照）。単一視点のみになるため指摘取りこぼしリスクとトレードオフ。

> **Note:** 複数 Reviewer には同一の入力（PR 番号）を渡す。各 Reviewer は互いの存在を知らない状態で独立にレビューを行う。

### Coordinator が判断時に参照する情報

Coordinator はメインセッションの Claude（またはユーザー）であり、サブエージェントとして起動されるわけではない。以下の情報はメインセッションのコンテキストとして既に保持しているか、直接参照できるものである。

- 全 Reviewer の `review_{n}_*.md`
- コードベースの知識（アーキテクチャ方針など）— メインセッションのコンテキストとして保持

### Implementer への入力

- **`<REVIEW_DIR>/task_{n}.md`（絶対パス）** — **主たる作業指示・唯一の権威的ソース。** Accept 項目のみが実装対象。
- **`<REVIEW_DIR>/review_{n}_*.md`（絶対パス、全 Reviewer 分）** — 補助的参照。Accept された指摘の背景理解・詳細コンテキスト確認用であり、作業指示としては扱わない。
- **PR 番号**（引数として受け取ったもの）
- **PR ブランチ名**（Coordinator の Preflight (b) で `gh pr view <PR番号> --json headRefName` 経由で取得済みのものをそのまま渡す。Implementer 側での `gh pr view` 再呼び出しは行わず、渡された branch 名を `git symbolic-ref --short HEAD` の出力と照合して防御的に検証するのみとする。詳細は「各ロールの責務 → Implementer」セクション参照）

### 実行例

ユーザーが Coordinator（メインの Claude）に `/review-fix <PR番号>` で実行を指示する。Coordinator は以下のようにサブエージェントを起動してサイクルを回す。

```
# 0. Coordinator: 引数検証 + 前提確認（Preflight フェーズ — サイクル開始時に 1 回のみ）
#    ※ 実行例は説明用の簡略表現であり、実装の正本は本文「各ロールの責務 → Coordinator」セクション。
#    ※ 特に `gh pr view` は実装上 1 コールに集約することを推奨（下記の集約呼び出し参照）。
#    ※ 「# 0」は Preflight (a)(b)(c)、「# 1」は Preflight (d) に相当。
#    - PR 番号を trim した上で正規表現 `^[1-9][0-9]*$` にマッチするか
#      （例: `0`, `+5`, `5.0`, `05`, `５` はいずれも不正。`"5 "` や `"5\t"` は trim 後に `5` となり有効）
#    - `gh pr view <PR番号> --json isCrossRepository,state,headRefName` を 1 コールで実行し、
#      `isCrossRepository` / `state` / `headRefName` を同時取得する（3 フィールドを 1 コールに集約）。
#      以降の論理ステップは取得済みの値を参照するのみ（追加 API 呼び出しはしない）:
#        * `isCrossRepository` が `false` か
#          （`true` の場合は fork PR であり、本スキルはサポート外。明示的なエラーで即中断する）
#        * `state` が `OPEN` か
#          （`CLOSED` / `MERGED` の場合は「PR state が <state> のためレビュー不可」で即中断する。
#           `state` フィールドは `OPEN` / `CLOSED` / `MERGED` のみを返すため、
#           Draft PR は `OPEN` として扱われ暗黙に許容される）
#        * `headRefName` を PR ブランチ名 `<branch>` として以降のステップで使用する
#    - 未 push のローカル変更がないか（以下の順序で検証）
#        1. PR ブランチ名 `<branch>` は上記の `gh pr view` 集約コールで取得済み
#        2. `git symbolic-ref --short HEAD` の出力が `<branch>` と一致するか検証
#           （`git symbolic-ref --short HEAD` が非 0 終了した場合は
#            「HEAD が detached 状態のため `<branch>` に `git checkout` してから再実行」で即中断する。
#            正常終了かつ不一致の場合は「現在 <actual> にチェックアウト中。`<branch>` に切り替えてから再実行」で即中断する。
#            このチェックが無いと、HEAD が偶然 `origin/<branch>` と同一コミットを指す別ブランチにある
#            場合に rev-list が偽 PASS し、Implementer の push で別ブランチのコミットが PR ブランチに
#            上書きされる実被害を招く）
#        3. `git fetch origin <branch>` で remote-tracking ref を最新化
#           （この fetch が無いと、別環境からの push 後に `origin/<branch>` が古いまま残り、
#            `rev-list` が「未 push コミットあり」と誤判定して Preflight が不当に abort する）
#        4. 以下の両方が空であることを確認
#            * `git rev-list "origin/<branch>..HEAD"` の出力が空（未 push コミットなし）
#              （`@{u}` は upstream 未設定時に破綻するため使わない）
#            * `git status --porcelain` の出力が空（未ステージ・ステージ済み未コミット変更なし）
#      いずれかを満たさない場合は警告してサイクルを中断する。

# 1. Coordinator: タイムスタンプディレクトリを作成（Preflight フェーズの一部 — サイクル開始時に 1 回のみ）
#    .claude/reviews/<PR番号>/<YYYYMMDD_HHMMSS>/ を作成。過去のディレクトリは削除しない。

# 2. Coordinator: Reviewer サブエージェントを並列起動（毎ラウンド）
#    Task ツール（subagent_type: general-purpose）で K 名の Reviewer を
#    **1 メッセージ内で同時に** 起動。各 Reviewer には
#    PR 番号・出力先絶対パス（<REVIEW_DIR>/review_1_1.md 等）・
#    ラウンド番号・レビュアー番号・出力フォーマット・
#    **「Severity レベルの定義」表全文**・**「Verdict と Severity の対応規則」表全文**
#    を渡す（severity 表・Verdict 対応表は Task ツール経由のサブエージェントが
#    メインセッションのコンテキストを参照できないため、プロンプト本体に全文含める）。
#    Reviewer サブエージェントは
#    `Skill(skill="review", args="<PR番号>")` を明示的に呼び出すよう指示する
#    （自然言語で `/review <PR番号>` と書くだけではスキルは起動しない）。

# 3. Coordinator: 全 review_1_*.md を読み込み、統合・精査し <REVIEW_DIR>/task_1.md を作成（毎ラウンド）
#    指摘の重複排除・Verdict 統合・Accept / Reject の判断はメインセッションで行う。
#    出力先は <REVIEW_DIR>/task_{n}.md（絶対パス）。
#    Round 2 以降は:
#      - 各ラウンド開始時（Reviewer 起動前）に `gh pr view <PR番号> --json state -q .state` を再実行して
#        `OPEN` を維持しているか検証（`OPEN` 以外なら即中断）。
#      - タイムスタンプディレクトリ内の全過去 task_*.md の Reject 項目と比較し、
#        同一論理的問題が累計 2 回以上 Reject 候補となった場合は終了/エスカレーションを判断する。

# 4. Implementer: Accept 項目がある場合、Coordinator が Implementer サブエージェントを起動（毎ラウンド）
#    Task ツールで別 Claude を起動し、<REVIEW_DIR>/task_1.md の Accept 項目を実装させる。
#    Implementer にはプロンプトで task_{n}.md / review_{n}_*.md の絶対パスと
#    PR ブランチ名（Preflight (b) で取得済みのもの）を渡す。
#    Implementer の手順:
#      - 実装開始前（Edit 開始前）に `git rev-parse HEAD` で START_HEAD を記録
#      - Accept 項目を実装し、コミットポリシー（新規 commit・subject にラウンド番号）に従い commit を作成
#      - push 前に以下を実施:
#          * `git symbolic-ref --short HEAD` が PR ブランチ名と一致することを確認
#          * `git fetch origin <PR ブランチ名>` 実行後、
#            `git rev-list "${START_HEAD}..origin/<PR ブランチ名>"` の出力が空であることを確認
#            （並行書き込み検出 — 空でない場合は他者の push 割り込みと判断して中断）
#            ※ `${START_HEAD}` はリテラル SHA として埋め込む（環境変数として持ち回さない）
#      - その後 `git push origin HEAD:<PR ブランチ名>` で push して完了とする。

# 5. 次ラウンド: 再び Reviewer サブエージェントを並列起動 → 終了条件を満たすまで繰り返し
```
