param(
    [ValidateSet('', 'zh-CN', 'en')]
    [string]$Language = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$settingsPath = Join-Path $projectDir '.reposcout-settings.json'
$settings = [ordered]@{}
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    try {
        $loaded = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $loaded.PSObject.Properties) { $settings[$property.Name] = $property.Value }
    } catch {}
}

if (-not $Language) {
    Write-Host '语言 / Language'
    Write-Host ''
    Write-Host '[1] 简体中文'
    Write-Host '[2] English'
    do {
        Write-Host ''
        Write-Host '请输入 1 或 2 / Enter 1 or 2:'
        $answer = (Read-Host).Trim()
    } until ($answer -in @('1', '2'))
    $Language = if ($answer -eq '2') { 'en' } else { 'zh-CN' }
}

$settings['ui_language'] = $Language
$temporary = "$settingsPath.tmp"
$settings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
Move-Item -LiteralPath $temporary -Destination $settingsPath -Force
if ($Language -eq 'en') {
    Write-Host 'RepoWayfinder language changed to English. Future launches will use this choice.'
} else {
    Write-Host 'RepoWayfinder 语言已改为简体中文，后续启动会继续使用此选择。'
}
