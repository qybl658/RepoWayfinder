function Initialize-RepoWayfinderUiLanguage([string]$ProjectDir) {
    if ($env:REPOSCOUT_UI_LANGUAGE -in @('zh-CN', 'en')) { return $env:REPOSCOUT_UI_LANGUAGE }
    $settingsPath = Join-Path $ProjectDir '.reposcout-settings.json'
    $language = 'zh-CN'
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$settings.ui_language -in @('zh-CN', 'en')) { $language = [string]$settings.ui_language }
        } catch {}
    }
    $env:REPOSCOUT_UI_LANGUAGE = $language
    return $language
}

function Get-RepoWayfinderUiText([string]$Chinese, [string]$English) {
    if ($env:REPOSCOUT_UI_LANGUAGE -eq 'en') { return $English }
    return $Chinese
}

function Read-RepoWayfinderExplicitYesNo([string]$Chinese, [string]$English) {
    while ($true) {
        Write-Host (Get-RepoWayfinderUiText $Chinese $English)
        Write-Host (Get-RepoWayfinderUiText '[1] 是    [2] 否（空回车不作决定）' '[1] Yes    [2] No (empty Enter does not decide)')
        $answer = (Read-Host).Trim().ToLowerInvariant()
        if ($answer -in @('1', 'y', 'yes', '是')) { return $true }
        if ($answer -in @('2', 'n', 'no', '否')) { return $false }
        Write-Host (Get-RepoWayfinderUiText '请输入 1 或 2。' 'Enter 1 or 2.')
    }
}
