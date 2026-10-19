<#
.SYNOPSIS
    YAML スカラーの安全な単一行ダブルクォート表現と、その逆変換。
.DESCRIPTION
    summary 等の文字列を frontmatter / サイドカー（*.meta.yaml）へ書き込む際、
    ':' / 改行 / '"' / '\' が YAML 構造を壊すのを防ぐための共通ヘルパ。
    呼び出し元スクリプトから dot-source して使用する（関数定義のみ・副作用なし）。
#>

# 文字列を単一行ダブルクォート YAML スカラーへ変換する。
# 改行/タブ→空白に単一行化し、バックスラッシュ→\\、ダブルクォート→\" の順でエスケープする。
function ConvertTo-YamlScalar {
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    $s = $Value -replace "`r`n", ' '
    $s = $s -replace "[`r`n`t]", ' '
    $s = $s.Replace('\', '\\').Replace('"', '\"')
    return '"' + $s + '"'
}

# ConvertTo-YamlScalar の逆変換。外側のダブルクォートを除去しアンエスケープする。
# 旧形式（無引用 / 単一引用 '...'）も後方互換で扱う。
function ConvertFrom-YamlScalar {
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if ($null -eq $Value) { return $null }
    $v = $Value.Trim()
    if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
        # エスケープ順の逆: \" を先に、続いて \\ を戻す
        return $v.Substring(1, $v.Length - 2).Replace('\"', '"').Replace('\\', '\')
    }
    if ($v.Length -ge 2 -and $v.StartsWith("'") -and $v.EndsWith("'")) {
        return $v.Substring(1, $v.Length - 2).Replace("''", "'")
    }
    return $v
}
