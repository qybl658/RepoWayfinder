param(
    [string]$Target = '',
    [switch]$UpdateExisting,
    [switch]$NoPause
)

# RepoWayfinder beginner launcher.
# It always switches to the directory where this script lives, so users do not need to cd manually.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $projectDir
$uiHelper = Join-Path $projectDir 'reposcout_ui.ps1'
if (-not (Test-Path -LiteralPath $uiHelper -PathType Leaf)) { throw "RepoWayfinder UI helper not found: $uiHelper" }
. $uiHelper
[void](Initialize-RepoWayfinderUiLanguage $projectDir)
$runLogTools = Join-Path $projectDir 'run_log_utils.ps1'
if (-not (Test-Path -LiteralPath $runLogTools -PathType Leaf)) { throw "Run-log helper not found: $runLogTools" }
. $runLogTools

$runLogPath = Join-Path $projectDir 'run.md'
$script:RepoWayfinderTranscriptStarted = $false
try {
    Set-Content -LiteralPath $runLogPath -Value '' -Encoding UTF8
    Start-Transcript -LiteralPath $runLogPath -Append -Force | Out-Null
    $script:RepoWayfinderTranscriptStarted = $true
    Write-Host (Get-RepoWayfinderUiText "完整运行记录：$runLogPath" "Run log: $runLogPath")
    Write-Host ''
} catch {
    $fallback = "RepoWayfinder run log could not start: $($_.Exception.Message)"
    Set-Content -LiteralPath $runLogPath -Value $fallback -Encoding UTF8
    Write-Host $fallback
}

function Initialize-RepoWayfinderLanguage {
    $settingsPath = Join-Path $projectDir '.reposcout-settings.json'
    $settings = [ordered]@{}
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $loaded = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($property in $loaded.PSObject.Properties) { $settings[$property.Name] = $property.Value }
        } catch {}
    }
    $language = [string]$settings['ui_language']
    if ($language -notin @('zh-CN','en')) {
        if ($NoPause) {
            $language = if ($env:REPOSCOUT_UI_LANGUAGE -eq 'en') { 'en' } else { 'zh-CN' }
        } else {
            Write-Host '语言 / Language'
            Write-Host ''
            Write-Host '[1] 简体中文'
            Write-Host '[2] English'
            do {
                Write-Host '请输入 1 或 2 / Enter 1 or 2:'
                $answer = (Read-Host).Trim()
            } until ($answer -in @('1','2'))
            $language = if ($answer -eq '2') { 'en' } else { 'zh-CN' }
        }
        $settings['ui_language'] = $language
        $temporary = "$settingsPath.tmp"
        $settings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $settingsPath -Force
    }
    $env:REPOSCOUT_UI_LANGUAGE = $language
}

function Pause-IfNeeded {
    if (-not $NoPause) {
        Write-Host ''
        Read-Host (Get-RepoWayfinderUiText '按 Enter 退出' 'Press Enter to exit')
    }
}

function Invoke-RepoWayfinderInstaller([string]$installerPath, [string[]]$installerArguments) {
    $powershellArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installerPath) + @($installerArguments)
    return (Invoke-RepoWayfinderPowerShellWithProgress $powershellArguments)
}

function Test-RepoWayfinderRuntime {
    $pythonExe = Join-Path $projectDir '.reposcout-venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $pythonExe)) { return $false }
    try {
        & $pythonExe -c "import requests, openai" | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}


function Test-RepoWayfinderGitAvailable {
    $localGitCmd = Join-Path $projectDir '.reposcout-git\cmd'
    $localGitUsrBin = Join-Path $projectDir '.reposcout-git\usr\bin'
    if (Test-Path -LiteralPath $localGitCmd) { $env:Path = $localGitCmd + ';' + $env:Path }
    if (Test-Path -LiteralPath $localGitUsrBin) { $env:Path = $localGitUsrBin + ';' + $env:Path }
    try {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($null -eq $git) { return $false }
        & $git.Source --version | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}
function Ensure-RepoWayfinderReady {
    $installer = Join-Path $projectDir 'install_reposcout.ps1'
    $localEnvPath = Join-Path $projectDir '.reposcout.env'
    if (-not (Test-Path -LiteralPath $installer)) { throw (Get-RepoWayfinderUiText "找不到安装脚本: $installer" "Installer not found: $installer") }

    if ((-not (Test-RepoWayfinderRuntime)) -or (-not (Test-RepoWayfinderGitAvailable))) {
        Write-Host (Get-RepoWayfinderUiText 'RepoWayfinder 运行环境或 Git 缺失/损坏，先自动安装/修复。' 'RepoWayfinder runtime or Git is missing/damaged. Automatic installation or repair will run first.')
        Write-Host (Get-RepoWayfinderUiText '这一步会创建 .reposcout-venv；如果新机没有 Python，会自动安装 Python；如果没有 Git，会下载项目本地 MinGit。' 'This creates .reposcout-venv, installs Python when absent, and downloads project-local MinGit when Git is absent.')
        $installArguments = @('-SkipApiSetup')
        if ($NoPause) { $installArguments += '-NoUI' }
        $installerExitCode = Invoke-RepoWayfinderInstaller -installerPath $installer -installerArguments $installArguments
        if ($installerExitCode -ne 0) { throw (Get-RepoWayfinderUiText "RepoWayfinder 环境安装/修复失败（状态码 $installerExitCode）。请看上面的具体错误。" "RepoWayfinder environment installation/repair failed (exit code $installerExitCode). Review the error above.") }
    }

    if (-not (Test-Path -LiteralPath $localEnvPath)) {
        Write-Host ''
        Write-Host (Get-RepoWayfinderUiText '还没有配置 RepoWayfinder API。现在打开配置向导；你也可以明确选择稍后配置。' 'RepoWayfinder API is not configured. The setup wizard will open; you may explicitly choose to configure it later.')
        $configArguments = @('-ConfigOnly', '-ForceApiSetup')
        if ($NoPause) { $configArguments += '-NoUI' }
        $configExitCode = Invoke-RepoWayfinderInstaller -installerPath $installer -installerArguments $configArguments
        if ($configExitCode -ne 0) { throw (Get-RepoWayfinderUiText "RepoWayfinder API 配置向导失败（状态码 $configExitCode）。" "RepoWayfinder API setup failed (exit code $configExitCode).") }
    }
}
function Get-LatestRepoWayfinderReport {
    $reportsDir = Join-Path $projectDir 'reports'
    if (-not (Test-Path -LiteralPath $reportsDir)) { return $null }
    $latestReport = Get-ChildItem -LiteralPath $reportsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $candidate = Join-Path $_.FullName 'deployment_result.json'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { Get-Item -LiteralPath $candidate }
    } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestReport) { return $latestReport.Directory }
    return $null
}

function Read-ReportSummary([string]$reportPath) {
    try {
        $jsonText = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8
        $report = $jsonText | ConvertFrom-Json
        return [pscustomobject]@{
            Repo = [string]$report.repo
            Action = [string]$report.action
            Reason = [string]$report.reason
            Guide = [string]$report.beginner_guide_path
            StartScript = [string]$report.start_script_path
            AnalysisBat = [string]$report.failure_analysis_bat_path
            AnalysisMd = [string]$report.failure_analysis_path
        }
    } catch {
        return [pscustomobject]@{ Repo=''; Action=''; Reason='无法读取 deployment_result.json'; Guide=''; StartScript=''; AnalysisBat=''; AnalysisMd='' }
    }
}

function Show-FailureHelp([int]$exitCode, [string]$target) {
    $latest = Get-LatestRepoWayfinderReport
    $summary = $null
    $analysisBatPath = ''
    $analysisMdPath = ''
    if ($latest) {
        $reportPath = Join-Path $latest.FullName 'deployment_result.json'
        $summary = Read-ReportSummary $reportPath
        $analysisBatPath = $summary.AnalysisBat
        if ([string]::IsNullOrWhiteSpace($analysisBatPath)) {
            $candidate = Join-Path $latest.FullName '点我分析这次失败原因.bat'
            if (Test-Path -LiteralPath $candidate) { $analysisBatPath = $candidate }
        }
        $analysisMdPath = $summary.AnalysisMd
        if ([string]::IsNullOrWhiteSpace($analysisMdPath)) {
            $analysisMdPath = Join-Path $latest.FullName 'ai_failure_analysis.md'
        }
    }

    Write-Host ''
    if (-not $analysisBatPath -or -not (Test-Path -LiteralPath $analysisBatPath)) {
        Write-Host (Get-RepoWayfinderUiText '本次没有进入目标项目执行阶段，因此不会生成项目失败分析。详细状态保留在最近的 deployment_result.json。' 'The target project did not reach execution, so no project-failure analysis will be generated. The latest deployment_result.json keeps the detailed status.')
        return
    }
    Write-Host (Get-RepoWayfinderUiText 'RepoWayfinder 运行失败。可以立即生成 ai_failure_analysis.md。' 'RepoWayfinder failed. You can generate ai_failure_analysis.md now.')
    if ($NoPause) {
        Write-Host (Get-RepoWayfinderUiText "非交互模式不会代替你确认生成。入口：$analysisBatPath" "Non-interactive mode will not approve generation for you. Launcher: $analysisBatPath")
        return
    }

    $generate = $false
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $message = Get-RepoWayfinderUiText "RepoWayfinder 运行失败。`n`n是否现在生成 ai_failure_analysis.md？`n`n报告目录和项目根目录的“错误分析”文件夹会各保存一份。发送给 AI 前请检查是否仍有敏感内容。" "RepoWayfinder failed.`n`nGenerate ai_failure_analysis.md now?`n`nOne copy will be saved with the report and another in the root error-analysis folder. Check it for sensitive content before sharing."
        $title = Get-RepoWayfinderUiText '生成 AI 失败分析' 'Generate AI failure analysis'
        $result = [System.Windows.Forms.MessageBox]::Show($message, $title, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        $generate = $result -eq [System.Windows.Forms.DialogResult]::Yes
    } catch {
        try {
            $answer = Read-Host (Get-RepoWayfinderUiText '是否现在生成 ai_failure_analysis.md？输入 y 生成，直接回车不生成' 'Generate ai_failure_analysis.md now? Enter y to generate; Enter alone skips')
            $generate = $answer -in @('y','Y','yes','YES','是','好')
        } catch {}
    }
    if (-not $generate) {
        Write-Host (Get-RepoWayfinderUiText '本次未生成；之后仍可双击报告目录里的失败分析 BAT。' 'Not generated now. You can still use the failure-analysis BAT in the report folder later.')
        return
    }
    $analysisScript = Join-Path $projectDir 'analyze_failure.ps1'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $analysisScript -NoOpen -ReportDir $latest.FullName -OutputPath $analysisMdPath
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $analysisMdPath -PathType Leaf)) {
        Write-Host (Get-RepoWayfinderUiText "已生成：$analysisMdPath" "Generated: $analysisMdPath")
        try { Start-Process -FilePath $analysisMdPath } catch {}
    } else {
        Write-Host (Get-RepoWayfinderUiText '生成失败，请稍后使用报告目录里的失败分析 BAT 重试。' 'Generation failed. Retry later with the failure-analysis BAT in the report folder.')
    }
}

try {
    Initialize-RepoWayfinderLanguage
    if ([string]::IsNullOrWhiteSpace($Target) -and -not $NoPause) {
        . (Join-Path $projectDir 'root_menu.ps1')
        while ($true) {
            $menuChoice = Read-RepoWayfinderMainMenu
            if ($menuChoice -eq '1') { break }
            $menuResult = Invoke-RepoWayfinderMenuAction -Choice $menuChoice -ProjectDir $projectDir
            if ($menuChoice -in @('0','2')) { exit $menuResult }
        }
    }
    Write-Host ''
    Write-Host (Get-RepoWayfinderUiText '正在准备运行环境，请稍后……' 'Preparing the environment, please wait...')
    Write-Host ''

    $runner = Join-Path $projectDir 'run_reposcout.ps1'
    if (-not (Test-Path -LiteralPath $runner)) {
        throw (Get-RepoWayfinderUiText "找不到运行脚本: $runner" "Runner not found: $runner")
    }

    if ($env:REPOSCOUT_LAUNCHER_CAPTURE_TEST -ne '1') {
        Ensure-RepoWayfinderReady
    }

    if ([string]::IsNullOrWhiteSpace($Target)) {
        Write-Host (Get-RepoWayfinderUiText '输入 GitHub 地址、owner/repo、本地目录或搜索关键词。' 'Enter a GitHub URL, owner/repo, local folder, or keywords.')
        Write-Host (Get-RepoWayfinderUiText '直接按 Enter 试玩 2048：无需 Key，部署后在浏览器中用方向键玩。' 'Press Enter to try 2048: no API key; play with arrow keys in your browser.')
        Write-Host ''
        $Target = Read-Host (Get-RepoWayfinderUiText '目标仓库' 'Target repository')
    }

    if ([string]::IsNullOrWhiteSpace($Target)) {
        $Target = 'gabrielecirulli/2048'
        Write-Host (Get-RepoWayfinderUiText "使用演示仓库: $Target" "Using demo repository: $Target")
    } else {
        Write-Host (Get-RepoWayfinderUiText "使用你输入的目标: $Target" "Using target: $Target")
    }

    Write-Host ''
    Write-Host (Get-RepoWayfinderUiText '正在分析项目，请稍后……' 'Analyzing the project, please wait...')
    Write-Host ''

    $previousNonInteractive = $env:REPOSCOUT_NONINTERACTIVE
    try {
        if ($NoPause) {
            $env:REPOSCOUT_NONINTERACTIVE = '1'
        }
        $runnerArguments = @($Target)
        if ($UpdateExisting) { $runnerArguments += '--update-existing' }
        & $runner -ReturnToCaller @runnerArguments
        $exitCode = $LASTEXITCODE
    } finally {
        if ($null -eq $previousNonInteractive) {
            Remove-Item Env:REPOSCOUT_NONINTERACTIVE -ErrorAction SilentlyContinue
        } else {
            $env:REPOSCOUT_NONINTERACTIVE = $previousNonInteractive
        }
    }
    if ($exitCode -ne 0) {
        Write-Host ''
        Write-Host (Get-RepoWayfinderUiText "RepoWayfinder 返回非 0 状态码: $exitCode" "RepoWayfinder returned non-zero exit code: $exitCode")
        Show-FailureHelp -exitCode $exitCode -target $Target
    }
    exit $exitCode
} catch {
    Write-Host ''
    Write-Host (Get-RepoWayfinderUiText "启动器自身失败: $($_.Exception.Message)" "Launcher failure: $($_.Exception.Message)")
    Write-Host (Get-RepoWayfinderUiText "完整启动与环境安装输出已写入: $runLogPath" "Full launcher and environment output was written to: $runLogPath")
    Write-Host (Get-RepoWayfinderUiText '在 RepoWayfinder 主程序开始前发生的环境安装失败不是目标项目失败。' 'An environment failure before RepoWayfinder starts the target is not a target-project failure.')
    if (-not $NoPause) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [System.Windows.Forms.MessageBox]::Show("RepoWayfinder 启动器自身失败：`n$($_.Exception.Message)`n`n完整安装错误已经写入项目根目录 run.md。这是在目标项目运行前发生的 RepoWayfinder 环境问题，不代表目标项目失败。", 'RepoWayfinder 启动失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        } catch {}
    }
    exit 1
} finally {
    if ($script:RepoWayfinderTranscriptStarted) {
        try { Stop-Transcript | Out-Null } catch { Write-Host "Could not close run.md transcript: $($_.Exception.Message)" }
    }
    Repair-RepoWayfinderRunLog -Path $runLogPath | Out-Null
    Pause-IfNeeded
}


