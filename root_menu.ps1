# Shared navigation for the interactive launcher. Configuration lives in root tools.
function Read-RepoWayfinderMainMenu {
    Write-Host ''
    Write-Host 'RepoWayfinder'
    Write-Host ''
    Write-Host (Get-RepoWayfinderUiText '[1] 部署新项目' '[1] Deploy a project')
    Write-Host (Get-RepoWayfinderUiText '[2] 继续上次运行' '[2] Continue last run')
    Write-Host (Get-RepoWayfinderUiText '[3] 打开全部运行结果（reports）' '[3] Open all run results (reports)')
    Write-Host (Get-RepoWayfinderUiText '[4] 部署历史' '[4] Deployment history')
    Write-Host (Get-RepoWayfinderUiText '[5] 设置' '[5] Settings')
    Write-Host (Get-RepoWayfinderUiText '[6] 打包已验证项目' '[6] Package a verified project')
    Write-Host (Get-RepoWayfinderUiText '[7] 新项目 Top 10（近30天）' '[7] New projects Top 10 (last 30 days)')
    Write-Host (Get-RepoWayfinderUiText '[0] 退出' '[0] Exit')
    Write-Host ''
    do { $choice = (Read-Host (Get-RepoWayfinderUiText '请输入编号' 'Enter a number')).Trim() } until ($choice -in @('0','1','2','3','4','5','6','7'))
    return $choice
}

function Invoke-RepoWayfinderMenuAction([string]$Choice, [string]$ProjectDir) {
    switch ($Choice) {
        '0' { return 0 }
        '2' { return (Invoke-RepoWayfinderPowerShellWithProgress @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $ProjectDir 'continue_last_deployment.ps1'))) }
        '3' { return (Invoke-RepoWayfinderPowerShellWithProgress @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $ProjectDir 'continue_last_deployment.ps1'),'-OpenOnly','-NoPause')) }
        '4' { return (Invoke-RepoWayfinderPowerShellWithProgress @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $ProjectDir 'run_reposcout.ps1'),'-ReturnToCaller','--history')) }
        '5' { return (Invoke-RepoWayfinderPowerShellWithProgress @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $ProjectDir 'settings_menu.ps1'))) }
        '6' { return (Invoke-RepoWayfinderPowerShellWithProgress @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $ProjectDir 'export_bundle.ps1'))) }
        '7' { return (Invoke-RepoWayfinderPowerShellWithProgress @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $ProjectDir 'run_reposcout.ps1'),'-ReturnToCaller','--weekly-trending')) }
        default { throw 'The deploy action belongs to the main launcher.' }
    }
}
