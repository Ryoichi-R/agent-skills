# 回答テンプレート

回答は以下の5セクションで構成する。セクション順序は固定。

### 1. ローカル情報

- skill-source から取得した根拠を記載する
- **各根拠はリンク内に行番号アンカーを含む Markdown リンク、L表記併記、VS Code URI の順で記述する**:
  `basename.md + <resolved-source-root>/path/to/file.md#L<start>-L<end> + (L<start>-L<end>) + VS Code URI + 引用テキスト`
- `<start>` / `<end>` は `collect_skill_source.ps1` 出力の `snippetStartLine` / `snippetEndLine` をそのまま用いる
- VS Code URI は `vscode://file/<絶対パス>:<start>` とし、空白・括弧・日本語等は URL エンコードする。PowerShell では `([Uri]::new('vscode://file/' + $path.Replace('\','/') + ':' + $start)).AbsoluteUri` で生成できる
- **重要**: `-SourceRoot`、`CC_LWR_SOURCE_ROOT`、既定値の順で解決した資料ルートの絶対パスを使用すること
- 同一ファイル内で別の箇所（snippet 外）を追加引用する場合は、メインエージェントが `Read` ツールで該当行を確認し、同じフォーマットで列挙する
- バックティック `` ` `` のみで囲んだ未リンク表記は禁止
- 該当情報がない場合は「ローカル資料に該当情報なし」と明記する

### 2. Web情報

- Web検索で取得した根拠を記載する
- 各根拠に URL を Markdown リンクで明記する（例: `[タイトル](https://example.com)`）。参照日も付記する
- 時点依存の情報（価格・バージョン・ニュース等）は最新性を説明する
- Web検索をスキップした場合は「Web検索: スキップ（ユーザー指示）」と明記する

### 3. 深堀りローカル情報

- Web検索結果から抽出したキーワードで再検索して発見した根拠を記載する
- 各根拠はローカル情報セクションと同じ形式で記述する:
  `basename.md + <resolved-source-root>/path/to/file.md#L<start>-L<end> + (L<start>-L<end>) + VS Code URI + 引用テキスト`
- 深堀りに使用したキーワードを冒頭に明記する
- ステップ1で取得済みのファイルは除外し、新規発見分のみ記載する
- スキップ時は「深堀り再検索: スキップ」、新規発見なしは「深堀り再検索で追加資料なし」と明記する

### 4. 結論

- ローカル情報、Web情報、深堀りローカル情報を統合した回答を記載する
- 矛盾がある場合は、どちらを採用したか理由とともに明記する
- 不確実な情報には「未確認」「要検証」等のラベルを付ける

### 5. 出典

全情報源を一覧化する。

| 種別           | 形式                                                                                |
| -------------- | ----------------------------------------------------------------------------------- |
| ローカル       | `[L1]`、ファイル名、解決済み絶対パスと行番号、L表記、VS Code URI                    |
| Web            | `[W1] [タイトル](URL)（参照日: YYYY-MM-DD）`                                        |
| 深堀りローカル | `[DL1]`、ファイル名、解決済み絶対パスと行番号、L表記、VS Code URI、深堀りキーワード |

リンク記法の注意:

- ローカルファイルは実行時に解決した資料ルート配下の絶対パスを使用する
- VS Code で原典を開けるよう、ローカル出典には `vscode://file/...:<start>` の補助リンクを必ず併記する。これは Markdown ビューアがローカル絶対パスをクリック可能リンクとして扱わない場合の補完である
- Web URL は `https://` で始まる完全 URL を使用する
- タイトルはファイル名（拡張子除く）または記事タイトルを使用する
- 統合例・サンプルでは、実在する特定資料の名称を使わず、`LLMの仕組み` のような汎用的な架空名称を使用する。実際の調査出力では、出典追跡性を保つため原資料の正式名称を改変しない
- パスに括弧・スペース等の特殊文字を含む場合は URL エンコードのみ許容（`%28` / `%29` / `%20`）。`<URL>` 形式は廃止

## 統合例

```markdown
## 1. ローカル情報

- `<resolved-source-root>/docs/llm-overview.md` の L120-L135（VS Code URIを併記）: LLMは入力をトークン列として処理する。

## 2. Web情報

- 基本的な処理段階は [LLMの仕組み](https://example.com/llm-mechanism) で説明されている。（参照日: 2026-02-15）

## 3. 深堀りローカル情報

深堀りキーワード: 「Attention」

- `<resolved-source-root>/docs/attention-mechanism.md` の L42-L58（VS Code URIを併記）: Attentionによる文脈処理の概要が記載されている。

## 4. 結論

ローカル資料と汎用解説を照合した結果、LLMの基本処理とAttentionの関係が確認できた。

## 5. 出典

- [L1] `<resolved-source-root>/docs/llm-overview.md` L120-L135（VS Code URIを併記）
- [W1] [LLMの仕組み](https://example.com/llm-mechanism)（参照日: 2026-02-15）
- [DL1] `<resolved-source-root>/docs/attention-mechanism.md` L42-L58（VS Code URIを併記、深堀りキーワード: Attention）
```

## JSON 出力仕様（Phase A: Markdown + JSON コメント併記）

Markdown 本文の末尾に以下の形式で構造化データを併記する。スキーマ定義は `references/output-schema.json` を参照。

```
<!-- JSON: {"sections":[...],"sources":[...],"conflict_resolution":{...},"metadata":{"step_number":4,"step_number_legacy":"5","schema_version":"1.0"}} -->
```

- `sections`: 5セクション（id: `local_info`, `web_info`, `deep_local_info`, `conclusion`, `sources`）
- `sources`: 出典配列（`url`（Web用）, `path`（ローカル用）, `title`, `source_type`: `web`|`local`, ローカル出典は `lines: {start, end}` を併記推奨）
- `conflict_resolution`: 矛盾検知結果（`detected`, `applied_rule`, `reason`）
- `metadata`: `step_number`(4), `step_number_legacy`("5"), `schema_version`("1.0")
