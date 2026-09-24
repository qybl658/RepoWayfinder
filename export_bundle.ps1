$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'reposcout_ui.ps1')
[void](Initialize-RepoWayfinderUiLanguage $root)
Write-Host (Get-RepoWayfinderUiText '打包已验证的 Python 项目' 'Package a verified Python project')
Write-Host (Get-RepoWayfinderUiText '需要部署报告与该项目的打包配置。配置指定源码版本、启动入口、运行时和依赖；详见 README 的打包说明。' 'Requires a deployment report and a reviewed bundle profile with source revision, entrypoint, runtime and dependencies. See the README.')
$report = (Read-Host (Get-RepoWayfinderUiText '部署报告 JSON 路径（回车返回）' 'Deployment report JSON path (Enter to return)')).Trim().Trim('"')
if (-not $report) { exit 0 }
$profile = (Read-Host (Get-RepoWayfinderUiText '打包配置 JSON 路径' 'Bundle profile JSON path')).Trim().Trim('"')
$output = (Read-Host (Get-RepoWayfinderUiText '保存为新的 ZIP 路径' 'New output ZIP path')).Trim().Trim('"')
if (-not $profile -or -not $output) { exit 0 }
& (Join-Path $root 'run_reposcout.ps1') -ReturnToCaller --export-report $report --bundle-profile $profile --bundle-output $output
exit $LASTEXITCODE
