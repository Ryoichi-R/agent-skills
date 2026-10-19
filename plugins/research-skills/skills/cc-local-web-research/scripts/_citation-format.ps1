Set-StrictMode -Version Latest

function Get-LocalCitationPattern {
    return '\[[^\]]+\.md\]\((?:(?:[A-Za-z]:/)|/)[^)\s>]+\.md#L\d+-L\d+\)\s*\(L\d+-L\d+\)'
}

function Get-VsCodeCitationLinkPattern {
    return '\[VS Codeで開く\]\(vscode://file/(?:(?:[A-Za-z]:/)|/)[^)\s>]+\.md:\d+(?::\d+)?\)'
}
