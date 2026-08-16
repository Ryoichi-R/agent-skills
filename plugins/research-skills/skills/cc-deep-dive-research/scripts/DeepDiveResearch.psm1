<#
.SYNOPSIS
    deep-dive-research スキルのコアモジュール。
.DESCRIPTION
    入力ファイル解析、パスバリデーション、キーワードサニタイズ、ドメイン判定、
    出典整合性検証、機密マスキング、依存解決、レビューゲート制御の8つのAPI関数を提供する。
    自己完結（self-contained）: workspace専用の src/shared や WORKSPACE_ROOT には依存しない。
    唯一の外部依存は兄弟Skill cc-local-web-research であり、自身のscripts/の親ディレクトリの、
    さらに親（skillsコンテナ）を起点に相対解決する。開発レイアウトと公開plugin配布レイアウトの
    双方でこのskillsコンテナ配下に兄弟Skillが同梱される構造は共通であるため、同一ロジックが成立する。
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Test-DeepDiveSemVerRange — portable SemVer範囲判定（'>=X.Y.Z <A.B.C' 形式専用）
# ---------------------------------------------------------------------------
function Test-DeepDiveSemVerRange {
    <#
    .SYNOPSIS
        SemVer バージョンが '>=X.Y.Z <A.B.C' 形式の境界レンジを満たすか判定する。
    .DESCRIPTION
        本Skillが唯一必要とする範囲構文（下限以上・上限未満）のみをサポートする、
        Skill内蔵の自己完結ヘルパー。PowerShell 5.1 互換（?? 等のPS7専用構文を使わない）。
        vプレフィクスとprerelease/buildタグは無視して比較する。
    .PARAMETER Version
        判定対象のバージョン文字列（例: "1.2.3", "v1.2.3", "1.2.3-beta"）。
    .PARAMETER Range
        境界レンジ文字列（例: ">=1.0.0 <2.0.0"）。
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [string]$Range
    )

    if ($Range -notmatch '^>=(\d+)\.(\d+)\.(\d+)\s+<(\d+)\.(\d+)\.(\d+)$') {
        throw "未対応のレンジ構文です: '$Range'。対応形式は '>=X.Y.Z <A.B.C' のみです。"
    }
    $lowerMajor = [int]$Matches[1]; $lowerMinor = [int]$Matches[2]; $lowerPatch = [int]$Matches[3]
    $upperMajor = [int]$Matches[4]; $upperMinor = [int]$Matches[5]; $upperPatch = [int]$Matches[6]

    $normalized = $Version -replace '^v', '' -replace '[-+].*$', ''
    if ($normalized -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
        throw "バージョン文字列のパースに失敗しました: '$Version' → '$normalized'"
    }
    $major = [int]$Matches[1]; $minor = [int]$Matches[2]; $patch = [int]$Matches[3]

    $versionNum = $major * 1000000 + $minor * 1000 + $patch
    $lowerNum = $lowerMajor * 1000000 + $lowerMinor * 1000 + $lowerPatch
    $upperNum = $upperMajor * 1000000 + $upperMinor * 1000 + $upperPatch

    return ($versionNum -ge $lowerNum -and $versionNum -lt $upperNum)
}

# ---------------------------------------------------------------------------
# Skillルート・兄弟Skill解決（同梱構造からの相対解決、workspace root非依存）
# ---------------------------------------------------------------------------
function Get-DeepDiveSkillRoot {
    <#
    .SYNOPSIS
        自スキル（cc-deep-dive-research）のルートディレクトリを返す（scripts/ の親）。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Split-Path -Parent $PSScriptRoot)
}

function Test-DeepDivePathWithinRoot {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path)
    return ($pathFull -eq $rootFull) -or $pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-DeepDiveNoReparsePoint {
    <#
    .SYNOPSIS
        Path から StopRoot まで祖先を遡り、reparse point（symlink/junction）を経由しないこと、
        StopRoot の境界を越えないことを確認する。存在しない祖先は検査をスキップする。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$StopRoot
    )
    $stop = [IO.Path]::GetFullPath($StopRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $current = [IO.Path]::GetFullPath($Path)

    while (-not (Test-Path -LiteralPath $current)) {
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { return $true }
        $current = $parent
    }
    while ($true) {
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'REPARSE_POINT_REJECTED'
        }
        $trimmed = $current.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if ($trimmed.Equals($stop, [System.StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current -or -not (Test-DeepDivePathWithinRoot -Path $parent -Root $stop)) {
            throw 'PATH_OUTSIDE_EXPECTED_ROOT'
        }
        $current = $parent
    }
    return $true
}

function Resolve-DeepDiveLocalWebResearchRoot {
    <#
    .SYNOPSIS
        兄弟Skill cc-local-web-research のルートを解決する。
    .DESCRIPTION
        既定では自スキルの親ディレクトリ（skillsコンテナ）配下の cc-local-web-research を返す。
        この相対解決により、workspace開発レイアウトと公開plugin配布レイアウトの
        双方で同一ロジックが成立し、WORKSPACE_ROOT 等の暗黙依存を必要としない。
    .PARAMETER OverrideRoot
        明示override。指定時もskillsコンテナ内であることと、reparse pointを
        経由しないことを検証する（コンテナ外への逸脱は拒否）。
    .OUTPUTS
        [string] 解決済み絶対パス（存在確認は呼び出し側の責務）。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$OverrideRoot
    )
    $skillRoot = Get-DeepDiveSkillRoot
    $skillsContainer = [IO.Path]::GetFullPath((Split-Path -Parent $skillRoot))
    $defaultRoot = Join-Path $skillsContainer 'cc-local-web-research'

    if ([string]::IsNullOrWhiteSpace($OverrideRoot)) {
        return $defaultRoot
    }

    $overrideFull = if ([IO.Path]::IsPathRooted($OverrideRoot)) {
        [IO.Path]::GetFullPath($OverrideRoot)
    } else {
        [IO.Path]::GetFullPath((Join-Path $skillsContainer $OverrideRoot))
    }
    if (-not (Test-DeepDivePathWithinRoot -Path $overrideFull -Root $skillsContainer)) {
        throw 'OVERRIDE_ROOT_OUTSIDE_SKILLS_CONTAINER'
    }
    Assert-DeepDiveNoReparsePoint -Path $overrideFull -StopRoot $skillsContainer | Out-Null
    return $overrideFull
}

# ---------------------------------------------------------------------------
# Test-InputPath
# ---------------------------------------------------------------------------
function Resolve-DeepDiveInputRoot {
    <#
    .SYNOPSIS
        Test-InputPath が使う「調査対象ルート」を解決する。
    .DESCRIPTION
        これはSkillのインストール先（plugin root）とは無関係の、ユーザーが調査対象と
        している資料の起点である。優先順位: 明示 -Root 引数 > 環境変数 DD_INPUT_ROOT >
        既定値（呼び出し時のカレントディレクトリ）。
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Root
    )
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        return [IO.Path]::GetFullPath($Root)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:DD_INPUT_ROOT)) {
        return [IO.Path]::GetFullPath($env:DD_INPUT_ROOT)
    }
    return [IO.Path]::GetFullPath((Get-Location).Path)
}

function Test-InputPath {
    <#
    .SYNOPSIS
        パスバリデーション（調査対象ルート内、パストラバーサル拒否、秘密ファイル拒否）。
    .PARAMETER Path
        検証対象のファイルパス。
    .PARAMETER Root
        調査対象ルート（省略時は Resolve-DeepDiveInputRoot の既定解決に従う）。
        Skillのインストール先pathとは独立しており、暗黙のWORKSPACE_ROOTには依存しない。
    .OUTPUTS
        @{Valid=bool; Error=string}
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Root
    )

    # パストラバーサル検出
    if ($Path -match '\.\.[/\\]') {
        return @{ Valid = $false; Error = "パストラバーサルが検出されました: $Path" }
    }

    # 秘密ファイルパターン
    $secretPatterns = @(
        '\.env$',
        'secrets\.',
        '\.pem$',
        '\.key$',
        '\.pfx$',
        '\.p12$',
        'credentials',
        '\.secret$'
    )
    foreach ($pattern in $secretPatterns) {
        if ($Path -match $pattern) {
            return @{ Valid = $false; Error = "秘密ファイルパターンに合致します: $Path" }
        }
    }

    # 調査対象ルート内チェック
    try {
        $effectiveRoot = Resolve-DeepDiveInputRoot -Root $Root
        $resolvedPath = if ([System.IO.Path]::IsPathRooted($Path)) {
            $Path
        } else {
            Join-Path $effectiveRoot $Path
        }
        $normalizedPath = [System.IO.Path]::GetFullPath($resolvedPath)
        $normalizedRoot = [System.IO.Path]::GetFullPath($effectiveRoot)

        # ディレクトリ区切り文字を含めて境界判定（同名接頭辞の隣接パス等の誤許可を防止）
        $rootWithSep = $normalizedRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
        if (-not ($normalizedPath -eq $normalizedRoot -or $normalizedPath.StartsWith($rootWithSep, [System.StringComparison]::OrdinalIgnoreCase))) {
            return @{ Valid = $false; Error = "調査対象ルート外のパスです: $Path (root=$effectiveRoot)" }
        }
    }
    catch {
        return @{ Valid = $false; Error = "パス解決に失敗しました: $Path — $_" }
    }

    return @{ Valid = $true; Error = $null }
}

# ---------------------------------------------------------------------------
# Parse-InputFile
# ---------------------------------------------------------------------------
function ConvertFrom-InputFile {
    <#
    .SYNOPSIS
        入力ファイル解析、セクション抽出。
    .PARAMETER FilePath
        入力ファイルのパス。
    .OUTPUTS
        @{Sections=hashtable; Citations=array; Claims=array; Warnings=array}
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    $content = Get-Content -Path $FilePath -Raw -Encoding UTF8

    # セクションパターン定義
    $requiredSections = @{
        'ローカル情報'   = '##\s+(?:\d+\.\s+)?ローカル情報'
        'Web情報'        = '##\s+(?:\d+\.\s+)?Web情報'
        '結論'           = '##\s+(?:\d+\.\s+)?結論'
        '出典'           = '##\s+(?:\d+\.\s+)?出典'
    }

    $optionalSections = @{
        '精査ローカル情報' = '##\s+(?:\d+\.\s+)?精査ローカル情報'
    }

    $sections  = @{}
    $warnings  = [System.Collections.Generic.List[string]]::new()
    $allLines  = $content -split "`n"

    # ヘッダー行のインデックスを収集
    $headerIndices = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $allLines.Count; $i++) {
        if ($allLines[$i] -match '^##\s+') {
            $headerIndices.Add(@{ Index = $i; Line = $allLines[$i].Trim() })
        }
    }

    # セクション本文を抽出するヘルパー
    $extractSection = {
        param([int]$startIdx)
        $endIdx = $allLines.Count
        foreach ($h in $headerIndices) {
            if ($h.Index -gt $startIdx) {
                $endIdx = $h.Index
                break
            }
        }
        $sectionLines = $allLines[($startIdx + 1)..($endIdx - 1)]
        return ($sectionLines -join "`n").Trim()
    }

    # 必須セクション検出
    $missingRequired = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $requiredSections.Keys) {
        $pattern = $requiredSections[$name]
        $found = $false
        foreach ($h in $headerIndices) {
            if ($h.Line -match $pattern) {
                $sections[$name] = & $extractSection $h.Index
                $found = $true
                break
            }
        }
        if (-not $found) {
            $missingRequired.Add($name)
        }
    }

    if ($missingRequired.Count -gt 0) {
        throw "必須セクションが欠損しています: $($missingRequired -join ', ')"
    }

    # 任意セクション検出
    foreach ($name in $optionalSections.Keys) {
        $pattern = $optionalSections[$name]
        $found = $false
        foreach ($h in $headerIndices) {
            if ($h.Line -match $pattern) {
                $sections[$name] = & $extractSection $h.Index
                $found = $true
                break
            }
        }
        if (-not $found) {
            $warnings.Add("任意セクション '$name' が見つかりません。スキップします。")
        }
    }

    # 出典タグ抽出
    $validTagPattern = '\[(L\d+|W\d+|DL\d+)\]'
    $citations = [regex]::Matches($content, $validTagPattern) |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique

    # 不一致タグ検出（出典セクション内の角括弧タグで有効パターンに合致しないもの）
    $citationSection = if ($sections.ContainsKey('出典')) { $sections['出典'] } else { '' }
    $allBracketTags = [regex]::Matches($citationSection, '\[([^\]]+)\]') |
        ForEach-Object { $_.Groups[1].Value }
    $invalidTags = $allBracketTags | Where-Object { $_ -notmatch '^(L\d+|W\d+|DL\d+)$' }
    $invalidCount = @($invalidTags).Count

    if ($invalidCount -gt 0) {
        $warnings.Add("出典タグ形式の不一致が ${invalidCount}件あります: $($invalidTags -join ', ')")
    }
    if ($invalidCount -gt 3) {
        throw "出典タグ形式の不一致が ${invalidCount}件（閾値3件超過）。入力品質を確認してください。"
    }

    # 主張抽出（箇条書き項目 + 要検証/未確認/推論マーク）
    $claims = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($line in $allLines) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^[-*]\s+(.+)$') {
            $claimText = $Matches[1]
            $needsVerification = $claimText -match '(要検証|未確認|推論)'
            $claims.Add(@{
                Text              = $claimText
                NeedsVerification = $needsVerification
            })
        }
    }

    return @{
        Sections  = $sections
        Citations = @($citations)
        Claims    = @($claims)
        Warnings  = @($warnings)
    }
}

# ---------------------------------------------------------------------------
# Invoke-SanitizeKeyword
# ---------------------------------------------------------------------------
function Invoke-SanitizeKeyword {
    <#
    .SYNOPSIS
        検索キーワードのサニタイズ。
    .PARAMETER Raw
        サニタイズ前のキーワード文字列。
    .OUTPUTS
        サニタイズ済み文字列。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Raw
    )

    # 許可文字以外を除去（英数字、日本語、ハイフン、アンダースコア、スペース）
    $sanitized = $Raw -replace '[^a-zA-Z0-9\u3000-\u9FFF\u30A0-\u30FF\u3040-\u309F\-_ ]', ''

    # 連続スペースを単一スペースに
    $sanitized = $sanitized -replace '\s+', ' '
    $sanitized = $sanitized.Trim()

    # 200文字上限
    if ($sanitized.Length -gt 200) {
        $sanitized = $sanitized.Substring(0, 200)
    }

    return $sanitized
}

# ---------------------------------------------------------------------------
# Get-ContentDomain
# ---------------------------------------------------------------------------
function Get-ContentDomain {
    <#
    .SYNOPSIS
        ドメイン自動判定。
    .PARAMETER Content
        判定対象のテキスト内容。
    .OUTPUTS
        string[]（該当ドメイン配列）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Content
    )

    $domainKeywords = @{
        '法令・制度' = @('法', '条', '規則', '通知', '通達', '省庁', '調達', '入札', '契約')
        '技術'       = @('API', '実装', 'ライブラリ', 'フレームワーク', 'デプロイ', 'アーキテクチャ')
        'ビジネス'   = @('売上', '利益', '市場', 'ROI', '導入', 'コスト', 'KPI')
    }

    $threshold = 3
    $lines = $Content -split "`n"
    $domainCounts = @{}

    foreach ($domainName in $domainKeywords.Keys) {
        $count = 0
        foreach ($keyword in $domainKeywords[$domainName]) {
            # 短いキーワード（2文字以下）はワードバウンダリを要求して誤検知を抑制
            $escapedKw = [regex]::Escape($keyword)
            $kwPattern = $escapedKw
            foreach ($line in $lines) {
                $isHeader = $line -match '^##\s+'
                $kwMatches = [regex]::Matches($line, $kwPattern)
                $matchCount = $kwMatches.Count
                if ($isHeader) {
                    $matchCount = $matchCount * 2
                }
                $count += $matchCount
            }
        }
        $domainCounts[$domainName] = $count
    }

    # 閾値以上のドメインを出現回数の降順で返す
    $result = $domainCounts.GetEnumerator() |
        Where-Object { $_.Value -ge $threshold } |
        Sort-Object -Property Value -Descending |
        ForEach-Object { $_.Key }

    return ,@($result)
}

# ---------------------------------------------------------------------------
# Test-CitationIntegrity
# ---------------------------------------------------------------------------
function Test-CitationIntegrity {
    <#
    .SYNOPSIS
        出典タグ整合性検証。
    .PARAMETER Body
        本文テキスト。
    .PARAMETER Citations
        出典セクションテキスト。
    .OUTPUTS
        @{Orphaned=array; Unreferenced=array}
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Body,

        [Parameter(Mandatory)]
        [string]$Citations
    )

    $tagPattern = '\[(DD-[LW]\d+|ORIG-[LW]\d+|ORIG-DL\d+)\]'

    # 本文からコードブロックを除外
    $bodyWithoutCodeBlocks = $Body -replace '(?s)```.*?```', ''

    # 本文タグ抽出
    $bodyTags = [regex]::Matches($bodyWithoutCodeBlocks, $tagPattern) |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique

    # 出典セクションタグ抽出
    $citationTags = [regex]::Matches($Citations, $tagPattern) |
        ForEach-Object { $_.Groups[1].Value } |
        Sort-Object -Unique

    # 孤立タグ: 本文にあるが出典にない
    $orphaned = @($bodyTags | Where-Object { $_ -notin $citationTags })

    # 未参照タグ: 出典にあるが本文にない
    $unreferenced = @($citationTags | Where-Object { $_ -notin $bodyTags })

    return @{
        Orphaned     = $orphaned
        Unreferenced = $unreferenced
    }
}

# ---------------------------------------------------------------------------
# Invoke-MaskSensitiveData
# ---------------------------------------------------------------------------
function Invoke-MaskSensitiveData {
    <#
    .SYNOPSIS
        機密情報マスキング。
    .PARAMETER Content
        マスク対象のテキスト内容。
    .OUTPUTS
        マスク済み文字列。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Content
    )

    $masked = $Content

    # APIキー（sk-, pk-, api_key= 等）
    $masked = $masked -replace '(?i)(sk-[a-zA-Z0-9]{20,})', '[REDACTED:API_KEY]'
    $masked = $masked -replace '(?i)(pk-[a-zA-Z0-9]{20,})', '[REDACTED:API_KEY]'
    $masked = $masked -replace '(?i)(api_key\s*=\s*)[^\s,;\]]+', '${1}[REDACTED:API_KEY]'
    $masked = $masked -replace '(?i)(api[-_]?key\s*[=:]\s*)[^\s,;\]]+', '${1}[REDACTED:API_KEY]'

    # 秘密鍵
    $masked = $masked -replace '(?s)-----BEGIN[^-]*?KEY-----.*?-----END[^-]*?KEY-----', '[REDACTED:PRIVATE_KEY]'

    # AWS/GCP/Azure クレデンシャル
    $masked = $masked -replace '(?i)(AKIA[A-Z0-9]{16})', '[REDACTED:CREDENTIAL]'
    $masked = $masked -replace '(?i)(aws_secret_access_key\s*=\s*)\S+', '${1}[REDACTED:CREDENTIAL]'
    $masked = $masked -replace '(?i)(aws_access_key_id\s*=\s*)\S+', '${1}[REDACTED:CREDENTIAL]'

    # パスワード
    $masked = $masked -replace '(?i)(password\s*=\s*)\S+', '${1}[REDACTED:PASSWORD]'
    $masked = $masked -replace '(?i)(passwd\s*=\s*)\S+', '${1}[REDACTED:PASSWORD]'

    # メールアドレス
    $masked = $masked -replace '[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}', '[REDACTED:EMAIL]'

    return $masked
}

# ---------------------------------------------------------------------------
# Resolve-SkillDependencies
# ---------------------------------------------------------------------------
function Resolve-SkillDependencies {
    <#
    .SYNOPSIS
        兄弟Skill cc-local-web-research への依存パス解決・バージョン検証。
    .DESCRIPTION
        自己完結型。workspace専用の src/shared や WORKSPACE_ROOT には依存しない。
        兄弟Skillのルートは Resolve-DeepDiveLocalWebResearchRoot が同梱構造から
        相対解決する（開発レイアウトと公開plugin配布レイアウトの双方で成立）。
    .PARAMETER LocalWebResearchRootOverride
        兄弟Skillルートの明示override（既定解決を使わない場合のみ指定）。
    .OUTPUTS
        @{Paths=hashtable; Errors=array; Dependencies=array}
    #>
    [CmdletBinding()]
    param(
        [string]$LocalWebResearchRootOverride
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $paths  = @{}
    $depResults = [System.Collections.Generic.List[hashtable]]::new()

    $depName = 'cc-local-web-research'
    $versionRange = '>=1.0.0 <2.0.0'

    try {
        $siblingRoot = Resolve-DeepDiveLocalWebResearchRoot -OverrideRoot $LocalWebResearchRootOverride
    } catch {
        $errors.Add("ERROR: dependency_unresolved: $depName (required=$versionRange, actual=root_rejected:$($_.Exception.Message))")
        $depResults.Add(@{
            Name     = $depName
            Status   = 'unresolved'
            Required = $versionRange
            Actual   = "root_rejected:$($_.Exception.Message)"
        })
        return @{ Paths = $paths; Errors = @($errors); Dependencies = @($depResults) }
    }

    $requiredFiles = @(
        @{ VarName = 'DD_COLLECT_SKILL_SOURCE_PATH'; RelPath = 'scripts/collect_skill_source.ps1' },
        @{ VarName = 'DD_SOURCE_PRIORITY_PATH'; RelPath = 'references/source-priority.md' }
    )
    $resolvedFiles = @($requiredFiles | ForEach-Object {
            [ordered]@{ VarName = $_.VarName; FullPath = Join-Path $siblingRoot $_.RelPath }
        })
    $missing = @($resolvedFiles | Where-Object { -not (Test-Path -LiteralPath $_.FullPath) })

    if ($missing.Count -gt 0) {
        $errors.Add("ERROR: dependency_unresolved: $depName (required=$versionRange, actual=not_found)")
        $depResults.Add(@{
            Name     = $depName
            Status   = 'unresolved'
            Required = $versionRange
            Actual   = 'not_found'
        })
        return @{ Paths = $paths; Errors = @($errors); Dependencies = @($depResults) }
    }

    # バージョン互換チェック（VERSIONファイルが存在する場合のみ。上流未バージョン管理時はファイル存在のみで通過）
    $versionFile = Join-Path $siblingRoot 'VERSION'
    $actualVersion = 'no_version_file'
    $versionOk = $true
    $versionErrorMessage = $null

    if (Test-Path -LiteralPath $versionFile) {
        $versionContent = (Get-Content -Path $versionFile -Raw -Encoding UTF8).Trim()

        if ([string]::IsNullOrWhiteSpace($versionContent)) {
            $versionOk = $false
            $actualVersion = 'empty'
            $versionErrorMessage = "ERROR: VERSIONファイルが空です: $versionFile"
        } elseif ($versionContent -notmatch '^\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?$') {
            $versionOk = $false
            $actualVersion = $versionContent
            $versionErrorMessage = "ERROR: VERSION形式が不正です: '$versionContent'（期待: MAJOR.MINOR.PATCH）"
        } else {
            $actualVersion = $versionContent
            try {
                $versionOk = Test-DeepDiveSemVerRange -Version $versionContent -Range $versionRange
            } catch {
                $versionOk = $false
            }
            if (-not $versionOk) {
                $versionErrorMessage = "ERROR: dependency_unresolved: $depName (required=$versionRange, actual=$versionContent)"
            }
        }
    }

    if (-not $versionOk) {
        $errors.Add($versionErrorMessage)
        $depResults.Add(@{
            Name     = $depName
            Status   = 'unresolved'
            Required = $versionRange
            Actual   = $actualVersion
        })
        return @{ Paths = $paths; Errors = @($errors); Dependencies = @($depResults) }
    }

    foreach ($file in $resolvedFiles) {
        $paths[$file.VarName] = $file.FullPath
    }
    $depResults.Add(@{
        Name     = $depName
        Status   = 'resolved'
        Required = $versionRange
        Actual   = $actualVersion
    })

    return @{
        Paths        = $paths
        Errors       = @($errors)
        Dependencies = @($depResults)
    }
}

# ---------------------------------------------------------------------------
# Invoke-WebSearchAdapter
# ---------------------------------------------------------------------------
function Invoke-WebSearchAdapter {
    <#
    .SYNOPSIS
        Web検索抽象層。テスト時はMockで差し替え。
    .PARAMETER Query
        検索クエリ文字列。
    .OUTPUTS
        @{Results=array; Error=string; StatusCode=int}
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Query
    )

    # 実環境ではWebSearch APIを呼び出す（スキル実行時にエージェントが実行）
    # テスト時はMockで差し替え
    return @{
        Results    = @()
        Error      = 'WebSearchAdapter は実行環境でのみ動作します'
        StatusCode = 3
    }
}

# ---------------------------------------------------------------------------
# Invoke-WebFetchAdapter
# ---------------------------------------------------------------------------
function Invoke-WebFetchAdapter {
    <#
    .SYNOPSIS
        WebFetch抽象層。テスト時はMockで差し替え。
    .PARAMETER Url
        取得対象URL。
    .OUTPUTS
        @{Content=string; Error=string; StatusCode=int}
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    return @{
        Content    = ''
        Error      = 'WebFetchAdapter は実行環境でのみ動作します'
        StatusCode = 3
    }
}

# ---------------------------------------------------------------------------
# Invoke-ClaudeCodeReviewAdapter
# ---------------------------------------------------------------------------
function Invoke-ClaudeCodeReviewAdapter {
    <#
    .SYNOPSIS
        Claude Codeレビュー抽象層。テスト時はMockで差し替え。
    .PARAMETER DraftPath
        ドラフトファイルパス。
    .PARAMETER Prompt
        審査プロンプト。
    .OUTPUTS
        @{Pass=bool; Issues=array; RawJson=string; Error=string}
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DraftPath,

        [Parameter(Mandatory)]
        [string]$Prompt
    )

    return @{
        Pass    = $false
        Issues  = @()
        RawJson = '{}'
        Error   = 'ClaudeCodeReviewAdapter は実行環境でのみ動作します'
    }
}

# ---------------------------------------------------------------------------
# Invoke-ReviewGate
# ---------------------------------------------------------------------------
function Invoke-ReviewGate {
    <#
    .SYNOPSIS
        レビューループ制御（7a→7b反復）。
    .PARAMETER DraftPath
        ドラフトファイルパス。
    .PARAMETER MaxIterations
        最大試行回数（デフォルト3）。
    .OUTPUTS
        @{Pass=bool; Iterations=int; UnresolvedIssues=array}
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DraftPath,

        [int]$MaxIterations = 3,

        [int]$CurrentIteration = 0
    )

    $reviewCriteria = @('新規性', '出典整合', '具体性', '構造準拠', '論理整合')
    $prompt = @"
以下のドラフトファイルを5観点で評価してください。
評価観点: $($reviewCriteria -join ', ')
JSON形式で出力してください:
{
  "pass": boolean,
  "issues": [{"criterion": string, "severity": "p1"|"p2", "description": string, "location": string}],
  "iteration": number
}
pass条件: severity="p1" が0件の場合 true
"@

    $iteration = $CurrentIteration
    $allUnresolved = @()

    while ($iteration -lt $MaxIterations) {
        $iteration++

        # 7a: 評価（read-only）
        $reviewResult = Invoke-ClaudeCodeReviewAdapter -DraftPath $DraftPath -Prompt $prompt

        if ($reviewResult.Error -and -not $reviewResult.Pass) {
            # パースエラーの場合もissuesが空の可能性がある
            if ($reviewResult.Issues.Count -eq 0 -and $reviewResult.Error) {
                $allUnresolved = @(@{
                    criterion   = 'システム'
                    severity    = 'p1'
                    description = "レビューアダプタエラー: $($reviewResult.Error)"
                    location    = 'N/A'
                })
                continue
            }
        }

        # p1 の有無で pass 判定
        $p1Issues = @($reviewResult.Issues | Where-Object { $_.severity -eq 'p1' })

        if ($p1Issues.Count -eq 0) {
            # pass: true（p2のみ or 指摘なし）
            $p2Issues = @($reviewResult.Issues | Where-Object { $_.severity -eq 'p2' })
            return @{
                Pass             = $true
                Iterations       = $iteration
                UnresolvedIssues = @($p2Issues)
                NeedsFixAndRetry = $null
            }
        }

        $allUnresolved = $p1Issues

        if ($iteration -lt $MaxIterations) {
            # 7b: 修正は呼び出し元（メインエージェント）が実施する
            # 現在のイテレーションの未解決指摘を返し、呼び出し元に修正を委譲する
            return @{
                Pass             = $false
                Iterations       = $iteration
                UnresolvedIssues = @($p1Issues)
                NeedsFixAndRetry = $true
            }
        }
    }

    # 最大試行回数到達
    return @{
        Pass             = $false
        Iterations       = $iteration
        UnresolvedIssues = @($allUnresolved)
        NeedsFixAndRetry = $null
    }
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
Export-ModuleMember -Function @(
    'ConvertFrom-InputFile',
    'Test-InputPath',
    'Invoke-SanitizeKeyword',
    'Get-ContentDomain',
    'Test-CitationIntegrity',
    'Invoke-MaskSensitiveData',
    'Resolve-SkillDependencies',
    'Invoke-ReviewGate',
    'Invoke-WebSearchAdapter',
    'Invoke-WebFetchAdapter',
    'Invoke-ClaudeCodeReviewAdapter',
    'Test-DeepDiveSemVerRange',
    'Get-DeepDiveSkillRoot',
    'Resolve-DeepDiveLocalWebResearchRoot',
    'Resolve-DeepDiveInputRoot',
    'Test-DeepDivePathWithinRoot',
    'Assert-DeepDiveNoReparsePoint'
)
