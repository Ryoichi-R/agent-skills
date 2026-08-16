---
name: cc-deep-dive-research
description: "cc-local-web-research が生成したレポート（result/research/research_*.md）を入力とし、各主張・トピックの具体的事例・統計データ・ケーススタディ・実装例を追加調査して精査レポートを生成する後段スキル。前提ファイルが存在しない場合は先に cc-local-web-research を実行する必要がある。キーワード: 精査レポート, 事例追加調査, ケーススタディ精査, deep dive レポート, 掘り下げ調査, research deep dive."
---

# cc-deep-dive-research

## 概要

`cc-local-web-research` の出力ファイルを入力として受け取り、各主張・トピックに対して具体的事例や裏付けデータを追加調査し、より実務に役立つ精査レポートを出力する。

## 外部依存

自己完結（self-contained）: workspace専用の `src/shared` や `WORKSPACE_ROOT` には依存しない。唯一の外部依存は兄弟Skill `cc-local-web-research` であり、自スキルの同梱構造（`scripts/` の親の、さらに親ディレクトリ＝skillsコンテナ）から相対解決する。この解決方式は開発レイアウトと公開plugin配布レイアウトの双方で同一ロジックが成立する。

| 変数名 | 環境変数名 | 相対パス（兄弟Skillルート基準） | 用途 | 互換バージョン | 非互換時の挙動 |
|--------|-----------|-----------|------|---------------|---------------|
| `$DD_COLLECT_SKILL_SOURCE_PATH` | `$env:DD_COLLECT_SKILL_SOURCE_PATH` | `scripts/collect_skill_source.ps1` | ローカル精査検索 | `>=1.0.0 <2.0.0`（上流未バージョン管理時はファイル存在のみで通過） | エラー停止 |
| `$DD_SOURCE_PRIORITY_PATH` | `$env:DD_SOURCE_PRIORITY_PATH` | `references/source-priority.md` | 信頼性評価基準 | `>=1.0.0 <2.0.0`（上流未バージョン管理時はファイル存在のみで通過） | エラー停止 |

### 兄弟Skill解決とoverride

`Resolve-SkillDependencies`（`DeepDiveResearch.psm1`）が兄弟Skillルートを既定解決する。既定を使わず明示的に別ルートを指定する場合は `resolve_dependencies.ps1 -LocalWebResearchRootOverride <path>` を使う。overrideもskillsコンテナ内であることとreparse point（symlink/junction）を経由しないことを検証し、コンテナ外への逸脱やreparse pointは `root_rejected:*` として拒否される。`resolve_dependencies.ps1` が失敗した場合は、別 platform 側の mirror へ手動で切り替えず、まず兄弟Skill側の `collect_skill_source.ps1` と `source-priority.md` の存在を確認する。Web 詳細調査の `WebSearch` / `WebFetch` 表記は Claude Code 用の抽象名であり、Codex セッションで利用可能な検索・取得ツールに読み替える。

### 起動時バリデーション

スキル起動時（ステップ1の前）に `scripts/resolve_dependencies.ps1` を実行し以下を検証する:
1. 依存テーブルの全パスが存在すること
2. バージョン互換性（`VERSION` ファイルが存在する場合のみ）

検証失敗時は stderr に構造化エラー（`dependency_unresolved: ...`）を出力し、終了コード2で処理を中断する（機能縮退は行わない）。成功・失敗どちらの場合も stdout には machine-readable な JSON（`schemaVersion`, `dependencies[]`, `paths`）を出力する。

## 権限要件

### Codex（`.codex/settings.json` 等、利用者環境のpermission設定）

| 操作 | 想定ティア | 説明 |
|------|--------|------|
| result/deepdive/ mkdir | `allow` | ディレクトリ作成 |
| .tmp_deepdive_* 書き込み | `allow` | 一時ファイル出力 |
| .tmp_deepdive_* → deepdive_* リネーム | `allow` | 確定出力 |
| .tmp_deepdive_* 削除 | `allow` | クリーンアップ |
| result/research/research_* 読み取り | `allow` | 入力ファイル参照 |

上記は本Skillが必要とする操作の想定ティアである。実際に承認プロンプトが発生するかどうかは、利用者自身のpermission設定（`.codex/settings.json` 等）に依存する。全操作が自動承認されることを本Skillが保証するものではない。

## 入力解決（research-output JSON 契約消費）

`cc-local-web-research` の出力を入力ファイルとして受け取り、パスを解決する。

### 入力解決手順

エージェントが以下の優先順位で入力パスを決定する（専用スクリプトは不要）:

1. **JSON ファイル経路**（最優先）: `result/research/.last_research_output.json` を Read で読み取り、`status` と `path` で判定
2. **明示パス引数**: ユーザーが直接ファイルパスを指定した場合はそれを使用
3. **最新ファイルフォールバック**: `result/research/` 配下の最新 `research_*Z*.md` を使用

```powershell
# 入力解決の手順（エージェントが実行）
# $investigationRoot は Test-InputPath の調査対象ルートと同じ概念（既定はカレントディレクトリ）であり、
# Skillのインストール先パスとは無関係である。
# 1. JSON 経路を確認
$jsonPath = Join-Path $investigationRoot "result/research/.last_research_output.json"
if (Test-Path $jsonPath) {
    $lastOutput = Get-Content $jsonPath -Raw | ConvertFrom-Json
    if ($lastOutput.status -eq "success" -and (Test-Path $lastOutput.path)) {
        $inputFile = $lastOutput.path
        $resolveSource = "json"
    }
}
# 2. フォールバック: 最新ファイル
if (-not $inputFile) {
    $candidates = Get-ChildItem "result/research/research_*Z*.md" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending
    if ($candidates.Count -gt 0) {
        $inputFile = $candidates[0].FullName
        $resolveSource = "fallback"
    }
}
# 3. 入力なし → 中断
if (-not $inputFile) {
    Write-Error "入力ファイルが見つかりません。cc-local-web-research を先に実行してください。"
}
```

### status による分岐

- `resolveSource=json`: `.last_research_output.json` から path を取得。deep-dive を継続
- `resolveSource=fallback`: 最新ファイルを使用。並行実行時は別ジョブの成果物を参照するリスクあり
- 入力なし: 前段 research が失敗、またはファイル不在。deep-dive を**起動しない**

## アダプタ責務

外部依存の呼び出しは `scripts/DeepDiveResearch.psm1` の `Resolve-SkillDependencies` 関数が担当する。`scripts/resolve_dependencies.ps1` は同関数を呼ぶ薄いラッパー（CLIエントリポイント）であり、実装は単一箇所（`DeepDiveResearch.psm1`）に集約する。

アダプタの出力は stdout JSON の `paths` フィールドとして提供する。呼び出し元が JSON をパースし、自プロセスで環境変数を適用する:
```powershell
# resolve_dependencies.ps1 の stdout JSON をパース
$depJson = & pwsh -NoProfile -File $resolveScript 2>$null | ConvertFrom-Json
# 呼び出し元で環境変数に設定
$depJson.paths.PSObject.Properties | ForEach-Object {
    [System.Environment]::SetEnvironmentVariable($_.Name, $_.Value, 'Process')
}
# 設定される変数:
#   $env:DD_COLLECT_SKILL_SOURCE_PATH  — collect_skill_source.ps1 の絶対パス
#   $env:DD_SOURCE_PRIORITY_PATH       — source-priority.md の絶対パス
```

## 入力契約（v1）

### 必須セクション
| セクション | ヘッダーパターン | 説明 |
|-----------|-----------------|------|
| ローカル情報 | `## ローカル情報` または `## 1. ローカル情報` | ローカル資料から収集した情報 |
| Web情報 | `## Web情報` または `## 2. Web情報` | Web検索で収集した情報 |
| 結論 | `## 結論` または `## 4. 結論` | 調査結果のまとめ |
| 出典 | `## 出典` または `## 5. 出典` | 出典リスト |

### 任意セクション
| セクション | ヘッダーパターン | 説明 |
|-----------|-----------------|------|
| 精査ローカル情報 | `## 精査ローカル情報` または `## 3. 精査ローカル情報` | 精査検索で追加取得した情報 |

### 欠損時の挙動
- 必須セクションが欠損: エラーメッセージを表示し処理を中断する
- 任意セクションが欠損: 警告を表示し該当セクションをスキップして処理を続行する
- 出典タグ形式の不一致: `[L#]`, `[W#]`, `[DL#]` パターンに合致しないタグは無視し警告をログに出力する。不一致タグが3件を超えた場合はエラーとして処理を中断する

## ワークフロー（7ステップ）

```
入力ファイル（cc-local-web-research出力）の指定
    │
    ▼
ステップ1: 入力ファイル解析
  入力mdを読み込み、主張・トピック・薄い箇所を抽出
    │
    ▼
ステップ2: 調査トピック選定
  精査対象を優先順位付けして3〜5トピックに絞り込み
    │
    ▼
ステップ3: ローカル詳細調査
  collect_skill_source.ps1 で各トピックの具体的事例をスキャン
    │
    ▼
ステップ4: Web詳細調査
  各トピックに対しWebSearch/WebFetchで具体例・統計・判例等を収集
    │
    ▼
ステップ5: 統合・分析
  全情報を統合し、元の主張との整合性を確認
    │
    ▼
ステップ6: レポート出力（ドラフト）
  deepdive-answer-format.md に従い result/deepdive/ にファイル出力
    │
    ▼
ステップ7: Codexレビューゲート（最大3回）
  5観点で審査 → pass: false なら指摘に基づき修正 → 再審査
  3回以内に pass: true にならなければ警告付きで確定出力
```

### ステップ1: 入力ファイル解析

- **入力パスバリデーション**: `Test-InputPath` で安全性検証（調査対象ルート外・パストラバーサル・秘密ファイル拒否）。調査対象ルートはSkillのインストール先とは無関係で、明示 `-Root` 引数 > 環境変数 `DD_INPUT_ROOT` > 既定値（呼び出し時のカレントディレクトリ）の優先順で解決する
- ユーザー指定のパスを Read で読み込む
- 入力契約v1に従い必須セクションの存在を検証
- 以下を抽出:
  - 主要な主張・アサーション
  - 「要検証」「未確認」「推論」と明示された箇所
  - 出典リスト
  - 結論セクションの要約ポイント

### ステップ2: 調査トピック選定

- 抽出した主張を以下の観点で評価:
  1. 根拠の薄さ: 出典が1つしかない主張、「推論」と注記された主張
  2. 具体例の欠如: 抽象的な記述で事例・数値がない箇所
  3. 実務的重要度: 結論に直結する主張を優先
- 3〜5個の精査トピックを決定

### ステップ3: ローカル詳細調査

- 検索キーワードを `Invoke-SanitizeKeyword` でサニタイズ
- 資料ルートは、元調査の `source_root`、環境変数 `CC_LWR_SOURCE_ROOT`、既定の `<repoRoot>/skill-source` の優先順で解決し、絶対パスとして `$sourceRoot` に保持する
- 解決した資料ルートが存在しない場合は検索を実行せず、`-SourceRoot` または `CC_LWR_SOURCE_ROOT` の設定を案内する
- 各トピックに対し `collect_skill_source.ps1` をアダプタ経由で実行:
  ```powershell
  pwsh $env:DD_COLLECT_SKILL_SOURCE_PATH `
      -Query "<サニタイズ済みキーワード>" `
      -SourceRoot $sourceRoot `
      -MaxFiles 5 `
      -MaxCharsPerFile 2000
  ```

- 検索インデックスは workspace cache（既定 `<repoRoot>/.cache/cc-local-web-research/search-index-<hash>.json`、`.gitignore` 済みで G: には生成しない）に保存される。既定で鮮度 TTL（`-IndexFreshnessTtlSeconds`、既定 600 秒）が有効で、TTL 窓内は再列挙をスキップする。精査で最新の追加資料を確実に拾いたい場合は `-ForceReindex` を付与する。保存先は `-IndexPath` または環境変数 `CC_LWR_CACHE_DIR` で上書きできる。

### ステップ4: Web詳細調査

- 各トピックに対し WebSearch を実行
- 検索クエリの設計指針: 事例・ケーススタディ・統計・データ等のキーワードを付加
- **ドメイン判定**: `Get-ContentDomain` で判定された戦略に基づきクエリを最適化
- **重複URL除外**: 既にWebFetch済みのURLは再取得しない
- **同一ドメイン偏重抑制**: 1ドメインあたりのWebFetch上限は2件
- **運用パラメータ**: WebSearch 30秒/WebFetch 60秒タイムアウト、リトライ最大2回、指数バックオフ
- **サーキットブレーカ**: 全体最大15リクエスト / 全体8分 / 連続5失敗で打ち切り

### ステップ5: 統合・分析

- 各トピックについて元の主張と新しい発見の整合性を確認
- 補強する事例 / 反する事例を明確に区別
- 信頼性評価: source-priority.md の基準を適用

### ステップ6: レポート出力（ドラフト）

- `deepdive-answer-format.md` に従い一時ファイル `result/deepdive/.tmp_deepdive_<タイムスタンプ>.md` として出力
- **機密マスキング**: `Invoke-MaskSensitiveData` で出力前にマスク適用
- **出典タグ整合性検証**: `Test-CitationIntegrity` で孤立タグを検出

### ステップ7: レビューゲート

#### ステップ7a: 評価（read-only）
- Codexで5観点（新規性・出典整合・具体性・構造準拠・論理整合）を評価
- `pass: true` 判定条件: severity `"p1"` が0件

#### ステップ7b: 修正（write）
- `pass: false` の場合、メインエージェントが指摘事項に基づきドラフトを修正
- 修正完了後ステップ7aに戻り再評価（最大3回）

#### 確定出力
- pass時: 一時ファイルを `result/deepdive/deepdive_<タイムスタンプ>.md` にリネーム
- 上限到達時: 未解決事項を `## レビュー未解決事項` セクションに付記して確定出力
