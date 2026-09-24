# Generated for RepoWayfinder users.
# Purpose: run RepoWayfinder through its project-local .reposcout-venv.
param(
    [switch]$ReturnToCaller,
    [Parameter(Position=0, ValueFromRemainingArguments=$true)][string[]]$RepoWayfinderArguments
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$uiHelper = Join-Path $projectDir 'reposcout_ui.ps1'
if (-not (Test-Path -LiteralPath $uiHelper -PathType Leaf)) { throw "RepoWayfinder UI helper not found: $uiHelper" }
. $uiHelper
[void](Initialize-RepoWayfinderUiLanguage $projectDir)
. (Join-Path $projectDir 'run_log_utils.ps1')
$installer = Join-Path $projectDir 'install_reposcout.ps1'
$pythonExe = Join-Path $projectDir '.reposcout-venv\Scripts\python.exe'
$entrypoint = Join-Path $projectDir 'main.py'
$localEnvPath = if ([string]::IsNullOrWhiteSpace($env:REPOSCOUT_LOCAL_ENV_PATH)) {
    Join-Path $projectDir '.reposcout.env'
} else {
    [System.IO.Path]::GetFullPath($env:REPOSCOUT_LOCAL_ENV_PATH)
}
$script:RepoWayfinderLoadedConfigNames = @()

function Add-RepoWayfinderLocalGitToPath {
    $localGitDir = Join-Path $projectDir '.reposcout-git'
    $gitCmd = Join-Path $localGitDir 'cmd'
    $gitUsrBin = Join-Path $localGitDir 'usr\bin'
    $paths = @()
    if (Test-Path -LiteralPath $gitCmd) { $paths += $gitCmd }
    if (Test-Path -LiteralPath $gitUsrBin) { $paths += $gitUsrBin }
    if ($paths.Count -gt 0) {
        $env:Path = ($paths -join ';') + ';' + $env:Path
        Write-Verbose "Loaded RepoWayfinder local Git: $gitCmd"
    }
}
function Test-RepoWayfinderGitAvailable {
    try {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($null -eq $git) { return $false }
        & $git.Source --version | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Unprotect-RepoWayfinderSecret([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    try {
        $secure = ConvertTo-SecureString -String $value
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) } }
    } catch {
        Write-Host 'A DPAPI-protected secret could not be decrypted by this Windows user. Run install_reposcout.ps1 -ForceApiSetup to reconfigure keys.'
        return ''
    }
}
function Import-RepoWayfinderLocalEnv {
    if (-not (Test-Path -LiteralPath $localEnvPath)) { return }

    $loaded = @()
    foreach ($line in Get-Content -LiteralPath $localEnvPath -Encoding UTF8) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        $pair = $trimmed -split '=', 2
        if ($pair.Count -ne 2) { continue }
        $name = $pair[0].Trim()
        $value = $pair[1].Trim()
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
        if ($name.EndsWith('_DPAPI')) {
            $plainName = $name.Substring(0, $name.Length - 6)
            $plainValue = Unprotect-RepoWayfinderSecret $value
            if ([string]::IsNullOrWhiteSpace($plainValue)) { continue }
            [Environment]::SetEnvironmentVariable($plainName, $plainValue, 'Process')
            $loaded += $plainName
            continue
        }
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
        $loaded += $name
    }

    if ($loaded.Count -gt 0) {
        $script:RepoWayfinderLoadedConfigNames = @($loaded)
        Write-Verbose "Loaded local RepoWayfinder config names: $($loaded -join ', ')"

    }
}

if (-not (Test-Path -LiteralPath $entrypoint)) {
    throw "RepoWayfinder entrypoint not found: $entrypoint"
}

$isSavedReportResume = @($RepoWayfinderArguments) -contains '--resume-report'
if (-not $isSavedReportResume) {
    Import-RepoWayfinderLocalEnv
} else {
    Write-Host (Get-RepoWayfinderUiText '正在继续上次运行……' 'Continuing the previous run...')
}
if (-not [string]::IsNullOrWhiteSpace($env:REPOSCOUT_VALIDATE_LOCAL_ENV_ONLY)) {
    $requiredName = $env:REPOSCOUT_VALIDATE_LOCAL_ENV_ONLY.Trim()
    if ($script:RepoWayfinderLoadedConfigNames -notcontains $requiredName) {
        throw "RepoWayfinder local config validation did not load required variable: $requiredName"
    }
    Write-Host "RepoWayfinder local config validation passed for: $requiredName"
    if ($ReturnToCaller) { return }
    exit 0
}

Add-RepoWayfinderLocalGitToPath
if (-not (Test-RepoWayfinderGitAvailable)) {
    Write-Host 'RepoWayfinder Git is not ready. Running installer to prepare local MinGit...'
    $installerCode = Invoke-RepoWayfinderPowerShellWithProgress @('-ExecutionPolicy','Bypass','-File',$installer,'-SkipApiSetup')
    if ($installerCode -ne 0) { throw 'RepoWayfinder Git preparation failed.' }
    Add-RepoWayfinderLocalGitToPath
}

if (-not (Test-Path -LiteralPath $pythonExe)) {
    Write-Host 'RepoWayfinder dependencies are not installed yet. Running installer first...'
    $installerCode = Invoke-RepoWayfinderPowerShellWithProgress @('-ExecutionPolicy','Bypass','-File',$installer)
    if ($installerCode -ne 0) { throw 'RepoWayfinder installer failed.' }
    Add-RepoWayfinderLocalGitToPath
}

try {
    & $pythonExe -c "import requests, openai, dotenv" | Out-Null
} catch {
    Write-Host 'RepoWayfinder dependency import check failed. Repairing environment...'
    $installerCode = Invoke-RepoWayfinderPowerShellWithProgress @('-ExecutionPolicy','Bypass','-File',$installer)
    if ($installerCode -ne 0) { throw 'RepoWayfinder installer repair failed.' }
    Add-RepoWayfinderLocalGitToPath
}

if ($RepoWayfinderArguments.Count -eq 0) {
    Write-Host (Get-RepoWayfinderUiText '新手入口：' 'Beginner entry:')
    Write-Host (Get-RepoWayfinderUiText '  双击 点我启动RepoWayfinder.bat' '  Double-click 点我启动RepoWayfinder.bat')
    Write-Host (Get-RepoWayfinderUiText '  或运行: powershell -ExecutionPolicy Bypass -File .\启动RepoWayfinder.ps1' '  Or run: powershell -ExecutionPolicy Bypass -File .\启动RepoWayfinder.ps1')
    Write-Host ''
    Write-Host (Get-RepoWayfinderUiText '高级用法：' 'Advanced usage:')
    Write-Host '  powershell -ExecutionPolicy Bypass -File .\run_reposcout.ps1 owner/repo'
    Write-Host '  powershell -ExecutionPolicy Bypass -File .\run_reposcout.ps1 https://github.com/owner/repo'
    Write-Host ''
    Write-Host 'Tip: set GITHUB_TOKEN to avoid GitHub API rate limits; set OPENROUTER_API_KEY or DEEPSEEK_API_KEY for AI planning.'
    Write-Host 'Local config file: .reposcout.env; do not share it if it contains keys.'
    if ($ReturnToCaller) { return }
    exit 0
}

$previousProgress = $env:REPOSCOUT_PROGRESS
$previousErrorAction = $ErrorActionPreference
$renderer = New-RepoWayfinderTerminalRenderer
try {
    $env:REPOSCOUT_PROGRESS = '1'
    # Windows PowerShell 5 wraps native stderr in ErrorRecord; exit code owns failure.
    $ErrorActionPreference = 'Continue'
    & $pythonExe -u $entrypoint @RepoWayfinderArguments 2>&1 |
        ForEach-Object { Write-RepoWayfinderTerminalLine $renderer ($_.ToString()) }
    $repoScoutExitCode = [int]$LASTEXITCODE
} finally {
    Clear-RepoWayfinderTerminalWait $renderer
    $env:REPOSCOUT_PROGRESS = $previousProgress
    $ErrorActionPreference = $previousErrorAction
}
$global:LASTEXITCODE = $repoScoutExitCode
if ($ReturnToCaller) { return }
exit $repoScoutExitCode






