param(
    [switch]$NoPause,
    [switch]$OpenOnly,
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$reportsRoot = Join-Path $projectDir 'reports'

function Test-PathInside([string]$Child,[string]$Parent) {
    $childPath = [IO.Path]::GetFullPath($Child)
    $parentPath = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return $childPath.StartsWith($parentPath + '\',[StringComparison]::OrdinalIgnoreCase)
}

if ($OpenOnly) {
    if (-not (Test-Path -LiteralPath $reportsRoot -PathType Container)) { [void](New-Item -ItemType Directory -Path $reportsRoot) }
    Write-Host "全部运行结果: $reportsRoot"
    Write-Host '按名称降序排列：最新部署在前；文件夹名前缀为部署开始时间。'
    if (-not $NoOpen) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList @($reportsRoot)
        # Apply only to this Explorer view, never the user's global folder defaults.
        try {
            $shell = New-Object -ComObject Shell.Application
            $sorted = $false
            for ($attempt = 0; $attempt -lt 12 -and -not $sorted; $attempt++) {
                foreach ($window in @($shell.Windows())) {
                    try {
                        if ([string]$window.Document.Folder.Self.Path -ieq $reportsRoot) {
                            $window.Document.SortColumns = 'prop:-System.ItemNameDisplay;'
                            $sorted = $true
                        }
                    } catch {}
                }
                if (-not $sorted) { Start-Sleep -Milliseconds 200 }
            }
            if (-not $sorted) { Write-Host '如未自动排序，可右键选择“排序方式 → 名称 → 递减”。' }
        } catch { Write-Host '可右键选择“排序方式 → 名称 → 递减”。' }
    }
    exit 0
}

$selected = $null
if (Test-Path -LiteralPath $reportsRoot -PathType Container) {
    $reportFiles = @(Get-ChildItem -LiteralPath $reportsRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $candidate = Join-Path $_.FullName 'deployment_result.json'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate }
    } | Sort-Object LastWriteTime -Descending)
    foreach ($reportFile in $reportFiles) {
        $directory = $reportFile.Directory
        $reportPath = $reportFile.FullName
        try { $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ([string]$report.action -ne 'WAITING_ENVIRONMENT' -or [bool]$report.project_execution_started) { continue }
        $resumeBat = [string]$report.resume_bat_path
        if ([string]::IsNullOrWhiteSpace($resumeBat)) { $resumeBat = Join-Path $directory.FullName '继续部署这个项目.bat' }
        if (-not (Test-Path -LiteralPath $resumeBat -PathType Leaf)) { continue }
        if (-not (Test-PathInside -Child $resumeBat -Parent $directory.FullName)) { continue }
        if ([IO.Path]::GetFileName($resumeBat) -ne '继续部署这个项目.bat') { continue }
        $selected = [pscustomobject]@{ Report=$reportPath; ResumeBat=[IO.Path]::GetFullPath($resumeBat); Directory=$directory.FullName }
        break
    }
}

if ($null -eq $selected) {
    if ($OpenOnly) { Write-Host '还没有找到部署报告。请先双击 点我启动RepoWayfinder.bat。' }
    else { Write-Host '没有找到可安全继续的等待报告。请先双击 点我启动RepoWayfinder.bat。' }
    if (-not $NoPause) { Read-Host '按 Enter 退出' | Out-Null }
    exit 2
}

Write-Host '即将继续最近一次仍在等待环境的部署：'
Write-Host "报告: $($selected.Report)"
Write-Host '后续可能出现 UAC、Docker 许可或重启选择；这些仍需要你本人明确同意。'
Write-Host '只有上次部署明确提示“等待环境”时才需要继续。'
if (-not $NoPause) {
    $confirmation = Read-Host '确认要继续时请输入“继续”；直接回车或输入其他内容会安全退出'
    if ($confirmation -ne '继续') {
        Write-Host '已取消，没有执行任何部署命令。'
        exit 0
    }
}
$resumeBat = [string]$selected.ResumeBat
& $resumeBat
exit $LASTEXITCODE
