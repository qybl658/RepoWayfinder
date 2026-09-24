param(
    [ValidateSet('', 'protected', 'compatible')][string]$Mode = '',
    [switch]$AcknowledgeCompatibleRisk
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $projectDir 'reposcout_ui.ps1')
[void](Initialize-RepoWayfinderUiLanguage $projectDir)
$pythonExe = Join-Path $projectDir '.reposcout-venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
    Write-Host (Get-RepoWayfinderUiText '请先通过“点我启动RepoWayfinder.bat”准备程序环境，再选择部署模式。' 'Prepare the application through the main launcher before choosing a deployment mode.')
    exit 2
}
$modeArguments = @('--configure-deployment-mode')
if ($Mode) { $modeArguments += @('--deployment-mode', $Mode) }
if ($AcknowledgeCompatibleRisk) { $modeArguments += '--acknowledge-compatible-risk' }
& $pythonExe -u (Join-Path $projectDir 'main.py') @modeArguments
exit $LASTEXITCODE
