param(
    [switch]$NoOpen,
    [switch]$NoMirror,
    [switch]$SkipNetworkChecks,
    [string]$ReportDir = '',
    [string]$OutputPath = '',
    [string]$MirrorDirectory = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $projectDir
$reportsDir = Join-Path $projectDir 'reports'
if (-not (Test-Path -LiteralPath $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Redact-Text([string]$text) {
    if ($null -eq $text) { return '' }
    $patterns = @(
        '(?i)(OPENROUTER_API_KEY(?:_DPAPI)?\s*=\s*)[^\s\r\n]+',
        '(?i)(DEEPSEEK_API_KEY(?:_DPAPI)?\s*=\s*)[^\s\r\n]+',
        '(?i)(GITHUB_TOKEN(?:_DPAPI)?\s*=\s*)[^\s\r\n]+',
        '(?i)(api[_-]?key\s*[=:]\s*)[^\s\r\n]+',
        '(?i)(token\s*[=:]\s*)[^\s\r\n]+',
        'sk-[A-Za-z0-9_\-]{12,}',
        'sk-or-[A-Za-z0-9_\-]{12,}',
        'ghp_[A-Za-z0-9_]{20,}',
        'github_pat_[A-Za-z0-9_]{20,}'
    )
    $redacted = $text
    foreach ($pattern in $patterns) { $redacted = [regex]::Replace($redacted, $pattern, '$1***REDACTED***') }
    return $redacted
}

function Read-TextSafe([string]$path, [int]$maxChars = 50000) {
    if (-not (Test-Path -LiteralPath $path)) { return "文件不存在: $path" }
    try {
        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $text = Redact-Text $text
        if ($text.Length -gt $maxChars) { return $text.Substring(0, $maxChars) + "`n... 已截断，原文件更长 ..." }
        return $text
    } catch {
        return "读取失败: $path`n$($_.Exception.Message)"
    }
}

function Add-Section([System.Collections.Generic.List[string]]$lines, [string]$title, [string]$body) {
    $lines.Add('')
    $lines.Add("## $title")
    $lines.Add('')
    $lines.Add('```text')
    $lines.Add($body.TrimEnd())
    $lines.Add('```')
}

function Test-UrlBrief([string]$url) {
    try {
        $response = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 15
        return "$url => HTTP $($response.StatusCode)"
    } catch {
        return "$url => FAILED: $($_.Exception.Message)"
    }
}

$latestReportDir = $null
if (-not [string]::IsNullOrWhiteSpace($ReportDir)) {
    if (Test-Path -LiteralPath $ReportDir) {
        $latestReportDir = Get-Item -LiteralPath $ReportDir
    } else {
        throw "指定的报告目录不存在: $ReportDir"
    }
} elseif (Test-Path -LiteralPath $reportsDir) {
    $latestReportDir = Get-ChildItem -LiteralPath $reportsDir -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outPath = $OutputPath
} elseif ($latestReportDir) {
    $outPath = Join-Path $latestReportDir.FullName 'ai_failure_analysis.md'
} else {
    $outPath = Join-Path $reportsDir "ai_failure_analysis-$stamp.md"
}
$outParent = Split-Path -Parent $outPath
if (-not [string]::IsNullOrWhiteSpace($outParent) -and -not (Test-Path -LiteralPath $outParent)) {
    New-Item -ItemType Directory -Path $outParent -Force | Out-Null
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# RepoWayfinder 失败分析材料')
$lines.Add('')
$lines.Add('请把这个 Markdown 整个发给 AI，让 AI 根据日志判断失败原因并给出下一步修复方案。')
$lines.Add('')
$lines.Add('要求 AI 输出：')
$lines.Add('')
$lines.Add('1. 先给结论：失败卡在哪一阶段。')
$lines.Add('2. 区分是网络问题、环境问题、API 配置问题、目标项目问题，还是 RepoWayfinder 自身 bug。')
$lines.Add('3. 给小白可执行步骤，不要只说“检查环境”。')
$lines.Add('4. 如果怀疑 GitHub 国内网络问题，明确建议 VPN/代理或换网络。')
$lines.Add('5. 不要要求用户泄露真实 API key。')
$lines.Add('')
$lines.Add("生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$lines.Add("项目目录: $projectDir")
if ($latestReportDir) { $lines.Add("当前分析报告目录: $($latestReportDir.FullName)") }
$lines.Add("输出文件: $outPath")

$envInfo = @()
$envInfo += "PowerShell: $($PSVersionTable.PSVersion)"
try { $envInfo += "winget: $(& winget --version 2>&1)" } catch { $envInfo += 'winget: not available; RepoWayfinder should fall back to python.org/local tools' }
try { $envInfo += "Python launcher: $(& py --version 2>&1)" } catch { $envInfo += 'Python launcher: not available' }
try { $envInfo += "python: $(& python --version 2>&1)" } catch { $envInfo += 'python: not available' }
try { $envInfo += "RepoWayfinder venv python: $(& (Join-Path $projectDir '.reposcout-venv\Scripts\python.exe') --version 2>&1)" } catch { $envInfo += 'RepoWayfinder venv python: not available' }
try { $git = Get-Command git -ErrorAction SilentlyContinue; if ($git) { $envInfo += "git: $($git.Source) / $(& $git.Source --version 2>&1)" } else { $envInfo += 'git: not in PATH' } } catch { $envInfo += "git check failed: $($_.Exception.Message)" }
try { $localGit = Join-Path $projectDir '.reposcout-git\cmd\git.exe'; if (Test-Path -LiteralPath $localGit) { $envInfo += "RepoWayfinder local git: $localGit / $(& $localGit --version 2>&1)" } else { $envInfo += 'RepoWayfinder local git: not found' } } catch { $envInfo += "local git check failed: $($_.Exception.Message)" }
$skipNetwork = $SkipNetworkChecks -or $env:REPOSCOUT_SKIP_NETWORK_CHECKS -eq '1'
if ($skipNetwork) {
    $envInfo += 'Network checks: skipped by release validation.'
} else {
    $envInfo += Test-UrlBrief 'https://github.com'
    $envInfo += Test-UrlBrief 'https://codeload.github.com'
    $envInfo += Test-UrlBrief 'https://www.python.org'
    $envInfo += Test-UrlBrief 'https://github.com/git-for-windows/git/releases'
}
Add-Section $lines '本机环境和网络简查' ($envInfo -join "`n")

$runMd = Join-Path $projectDir 'run.md'
Add-Section $lines 'run.md' (Read-TextSafe $runMd 80000)

if ($latestReportDir) {
    foreach ($name in @('RUNNING.md','deployment_result.json','beginner_guide.md','full_guide.md')) {
        $p = Join-Path $latestReportDir.FullName $name
        Add-Section $lines "本次报告/$name" (Read-TextSafe $p 80000)
    }
} else {
    Add-Section $lines '报告目录' '没有找到 reports 下的报告目录。'
}

Add-Section $lines 'RepoWayfinder 根目录文件列表' ((Get-ChildItem -LiteralPath $projectDir -Force | Select-Object Name,Length,LastWriteTime | Out-String) | Out-String)

Set-Content -LiteralPath $outPath -Value $lines -Encoding UTF8
Write-Host "已生成 AI 失败分析材料: $outPath"
if (-not $NoMirror) {
    if ([string]::IsNullOrWhiteSpace($MirrorDirectory)) {
        $MirrorDirectory = if ([string]::IsNullOrWhiteSpace($env:REPOSCOUT_FAILURE_MIRROR_DIR)) { Join-Path $projectDir '错误分析' } else { $env:REPOSCOUT_FAILURE_MIRROR_DIR }
    }
    if (-not (Test-Path -LiteralPath $MirrorDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $MirrorDirectory -Force | Out-Null
    }
    $mirrorBase = if ($latestReportDir) { $latestReportDir.Name } else { "failure-$stamp" }
    $mirrorBase = [regex]::Replace($mirrorBase, '[^0-9A-Za-z._\-\u4e00-\u9fff]+', '-')
    $mirrorPath = Join-Path $MirrorDirectory "$mirrorBase-ai_failure_analysis.md"
    if ([IO.Path]::GetFullPath($mirrorPath) -ne [IO.Path]::GetFullPath($outPath)) {
        Copy-Item -LiteralPath $outPath -Destination $mirrorPath -Force
    }
    Write-Host "根目录副本: $mirrorPath"
}
Write-Host '请把这个 Markdown 整个发给 AI。里面已做基础脱敏，但发送前仍建议快速搜索 key/token/sk-。'
if (-not $NoOpen) {
    try { Start-Process -FilePath $outPath } catch {}
}
