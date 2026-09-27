param()
$ErrorActionPreference = 'Stop'
$projectDir = $PSScriptRoot
. (Join-Path $projectDir 'reposcout_ui.ps1')
. (Join-Path $projectDir 'run_log_utils.ps1')
[void](Initialize-RepoWayfinderUiLanguage $projectDir)
while ($true) {
    Write-Host ''
    Write-Host (Get-RepoWayfinderUiText '设置' 'Settings')
    Write-Host (Get-RepoWayfinderUiText '[1] 搜索与历史' '[1] Search and history')
    Write-Host (Get-RepoWayfinderUiText '[2] 语言' '[2] Language')
    Write-Host (Get-RepoWayfinderUiText '[3] AI / API 配置' '[3] AI / API configuration')
    Write-Host (Get-RepoWayfinderUiText '[4] 部署模式' '[4] Deployment mode')
    Write-Host (Get-RepoWayfinderUiText '[0] 返回' '[0] Back')
    $choice = (Read-Host (Get-RepoWayfinderUiText '请输入编号' 'Enter a number')).Trim()
    $script = ''
    $extra = @()
    switch ($choice) {
        '0' { exit 0 }
        '1' { $script = 'run_reposcout.ps1'; $extra = @('-ReturnToCaller','--configure-search') }
        '2' { $script = 'configure_reposcout_language.ps1' }
        '3' { $script = 'install_reposcout.ps1'; $extra = @('-ConfigOnly','-ForceApiSetup') }
        '4' { $script = 'configure_reposcout_mode.ps1' }
        default { continue }
    }
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $projectDir $script)) + $extra
    $result = Invoke-RepoWayfinderPowerShellWithProgress $arguments
    if ($result -ne 0) { Write-Host (Get-RepoWayfinderUiText "该设置未完成（$result）。" "Setting not completed ($result).") }
    [void](Initialize-RepoWayfinderUiLanguage $projectDir)
}
