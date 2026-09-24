param(
    [switch]$SkipApiSetup,
    [switch]$ConfigOnly,
    [switch]$ForceApiSetup,
    [switch]$NoUI
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$uiHelper = Join-Path $projectDir 'reposcout_ui.ps1'
if (-not (Test-Path -LiteralPath $uiHelper -PathType Leaf)) { throw "RepoWayfinder UI helper not found: $uiHelper" }
. $uiHelper
[void](Initialize-RepoWayfinderUiLanguage $projectDir)
. (Join-Path $projectDir 'run_log_utils.ps1')
$venvDir = Join-Path $projectDir '.reposcout-venv'
$pythonExe = Join-Path $venvDir 'Scripts\python.exe'
$requirements = Join-Path $projectDir 'requirements.txt'
$localEnvPath = Join-Path $projectDir '.reposcout.env'
$installStatePath = Join-Path $projectDir '.reposcout-install-state.json'
$script:repoScoutInstalledPython = $false
$script:repoScoutPythonInstallMethod = ''
$pythonDirectInstallerVersion = '3.11.9'
$pythonDirectInstallerUrl = 'https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe'
$repoScoutPythonDir = Join-Path $projectDir '.reposcout-python'
$repoScoutPythonExe = Join-Path $repoScoutPythonDir 'python.exe'
$repoScoutGitDir = Join-Path $projectDir '.reposcout-git'
$repoScoutGitExe = Join-Path $repoScoutGitDir 'cmd\git.exe'
$mingitVersion = '2.55.0.2'
$mingitUrl = 'https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.2/MinGit-2.55.0.2-64-bit.zip'
$script:repoScoutInstalledGit = $false
$script:repoScoutGitInstallMethod = ''

function Show-RepoWayfinderMessage([string]$text, [string]$title='RepoWayfinder') {
    Write-Host $text
    if ($NoUI) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($text, $title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {}
}

trap {
    $message = "RepoWayfinder installer failed:`n$($_.Exception.Message)`n`n如果你是新手：请重新双击 点我启动RepoWayfinder.bat；如果仍失败，请把这段错误截图发给开发者。"
    try { Show-RepoWayfinderMessage $message 'RepoWayfinder 安装失败' } catch { Write-Host $message }
    exit 1
}
function Refresh-ProcessPath {
    $parts = @(
        $env:Path,
        [System.Environment]::GetEnvironmentVariable('Path','User'),
        [System.Environment]::GetEnvironmentVariable('Path','Machine'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $env:Path = ((($parts -join ';') -split ';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) -join ';'
}

function Test-CommandExists([string]$name) {
    Refresh-ProcessPath
    return $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

function Get-WingetCommand {
    Refresh-ProcessPath
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    $known = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $known) { return $known }
    return ''
}

function Get-LocalPythonCandidates {
    $candidates = @()
    if (Test-Path -LiteralPath $repoScoutPythonExe) { $candidates += $repoScoutPythonExe }
    $registryRoots = @(
        'Registry::HKEY_CURRENT_USER\Software\Python\PythonCore',
        'Registry::HKEY_LOCAL_MACHINE\Software\Python\PythonCore',
        'Registry::HKEY_LOCAL_MACHINE\Software\WOW6432Node\Python\PythonCore'
    )
    foreach ($registryRoot in $registryRoots) {
        if (-not (Test-Path -LiteralPath $registryRoot)) { continue }
        try {
            foreach ($versionKey in (Get-ChildItem -LiteralPath $registryRoot -ErrorAction SilentlyContinue)) {
                $installKeyPath = Join-Path $versionKey.PSPath 'InstallPath'
                if (-not (Test-Path -LiteralPath $installKeyPath)) { continue }
                $installKey = Get-Item -LiteralPath $installKeyPath -ErrorAction SilentlyContinue
                if ($null -eq $installKey) { continue }
                $registeredExecutable = [string]$installKey.GetValue('ExecutablePath')
                $registeredInstallPath = [string]$installKey.GetValue('')
                if ($registeredExecutable -and (Test-Path -LiteralPath $registeredExecutable -PathType Leaf)) {
                    $candidates += $registeredExecutable
                }
                if ($registeredInstallPath) {
                    $registeredPython = Join-Path $registeredInstallPath 'python.exe'
                    if (Test-Path -LiteralPath $registeredPython -PathType Leaf) { $candidates += $registeredPython }
                }
            }
        } catch {}
    }
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python'),
        (Join-Path $env:ProgramFiles 'Python*'),
        (Join-Path ${env:ProgramFiles(x86)} 'Python*')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($root in $roots) {
        try {
            Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $candidate = Join-Path $_.FullName 'python.exe'
                if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
            }
        } catch {}
    }
    return @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}
function Add-RepoWayfinderGitToPath {
    $paths = @()
    $gitCmd = Join-Path $repoScoutGitDir 'cmd'
    $gitUsrBin = Join-Path $repoScoutGitDir 'usr\bin'
    if (Test-Path -LiteralPath $gitCmd) { $paths += $gitCmd }
    if (Test-Path -LiteralPath $gitUsrBin) { $paths += $gitUsrBin }
    if ($paths.Count -gt 0) { $env:Path = ($paths -join ';') + ';' + $env:Path }
}

function Get-GitCommand {
    $forceLocalGit = ($env:REPOSCOUT_FORCE_LOCAL_GIT -eq '1')
    Add-RepoWayfinderGitToPath
    if ($forceLocalGit) {
        if (Test-Path -LiteralPath $repoScoutGitExe) { return $repoScoutGitExe }
        return ''
    }
    Add-RepoWayfinderGitToPath
    Refresh-ProcessPath
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    if (Test-Path -LiteralPath $repoScoutGitExe) { return $repoScoutGitExe }
    return ''
}

function Test-GitAvailable {
    $git = Get-GitCommand
    if ([string]::IsNullOrWhiteSpace($git)) { return $false }
    try {
        & $git --version | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Install-RepoWayfinderLocalGit {
    if (Test-GitAvailable) {
        Write-Host "Git already available: $(Get-GitCommand)"
        return
    }
    Write-Host ''
    Write-Host '未找到可用 git.exe，RepoWayfinder 将下载项目本地 MinGit。'
    Write-Host '这不会安装全局 Git，也不会修改系统 PATH；卸载 RepoWayfinder 时可一起删除。'
    Write-Host "下载地址: $mingitUrl"
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    $downloadDir = Join-Path ([System.IO.Path]::GetTempPath()) 'RepoWayfinder'
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    $zipPath = Join-Path $downloadDir "MinGit-$mingitVersion-64-bit.zip"
    $extractDir = Join-Path $downloadDir "MinGit-$mingitVersion-extract"
    try {
        Invoke-WebRequest -Uri $mingitUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 300
        if (-not (Test-Path -LiteralPath $zipPath)) { throw 'MinGit zip was not created' }
        $size = (Get-Item -LiteralPath $zipPath).Length
        if ($size -lt 10000000) { throw "MinGit zip is unexpectedly small: $size bytes" }
        if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
        if (Test-Path -LiteralPath $repoScoutGitDir) {
            $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            Move-Item -LiteralPath $repoScoutGitDir -Destination "$repoScoutGitDir.old-$timestamp"
        }
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
        $rootItems = @(Get-ChildItem -LiteralPath $extractDir -Force)
        if (($rootItems.Count -eq 1) -and $rootItems[0].PSIsContainer -and (Test-Path -LiteralPath (Join-Path $rootItems[0].FullName 'cmd\git.exe'))) {
            Move-Item -LiteralPath $rootItems[0].FullName -Destination $repoScoutGitDir
        } else {
            Move-Item -LiteralPath $extractDir -Destination $repoScoutGitDir
            $extractDir = ''
        }
        Add-RepoWayfinderGitToPath
        if (-not (Test-GitAvailable)) { throw 'MinGit extracted but git.exe still cannot run' }
        $script:repoScoutInstalledGit = $true
        $script:repoScoutGitInstallMethod = 'local-mingit'
        Write-Host "RepoWayfinder local Git ready: $(Get-GitCommand)"
    } catch {
        Show-RepoWayfinderMessage "Git 自动准备失败。`n`nRepoWayfinder 已尝试下载项目本地 MinGit，但没有成功：`n$($_.Exception.Message)`n`n你仍然可以继续使用 GitHub zip 下载兜底；如果下载仓库仍失败，请手动安装 Git for Windows：`nhttps://git-scm.com/download/win`n`n安装后重新双击 点我启动RepoWayfinder.bat。" 'RepoWayfinder Git 准备失败'
    } finally {
        try { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue } catch {}
        try { if ($extractDir -and (Test-Path -LiteralPath $extractDir)) { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    }
}
function Get-PythonVersionText([string]$pythonPath) {
    try { return ((& $pythonPath -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null | Out-String).Trim()) } catch { return '' }
}

function Resolve-PythonExecutable([string]$pythonPath) {
    if ([string]::IsNullOrWhiteSpace($pythonPath)) { return '' }
    try {
        $resolved = (& $pythonPath -c "import sys; print(sys.executable)" 2>$null | Out-String).Trim()
        if ($resolved -and (Test-Path -LiteralPath $resolved -PathType Leaf)) { return [IO.Path]::GetFullPath($resolved) }
    } catch {}
    if (Test-Path -LiteralPath $pythonPath -PathType Leaf) { return [IO.Path]::GetFullPath($pythonPath) }
    try {
        $command = Get-Command $pythonPath -ErrorAction SilentlyContinue
        if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) { return $command.Source }
    } catch {}
    return ''
}

function Find-CompatiblePython {
    $candidates = @()
    if ($env:REPOSCOUT_FORCE_LOCAL_PYTHON -eq '1') {
        if (Test-Path -LiteralPath $repoScoutPythonExe) { $candidates += $repoScoutPythonExe }
    } else {
        Refresh-ProcessPath
        try {
            $pyList = & py -0p 2>$null
            foreach ($line in $pyList) {
                $parts = $line.Trim() -split '\s+'
                if ($parts.Count -gt 0) {
                    $candidate = $parts[$parts.Count - 1]
                    if ($candidate -match '^[A-Za-z]:') { $candidates += $candidate }
                }
            }
        } catch {}
        $candidates += Get-LocalPythonCandidates
        $candidates += 'python'
    }
    foreach ($candidate in $candidates) {
        $version = Get-PythonVersionText $candidate
        if ($version -match '^3\.(11|12|13|14)$') {
            $resolved = Resolve-PythonExecutable $candidate
            if ($resolved) { return $resolved }
        }
    }
    return ''
}
function Find-CompatiblePythonAny {
    $hadForce = Test-Path Env:REPOSCOUT_FORCE_LOCAL_PYTHON
    $oldForce = $env:REPOSCOUT_FORCE_LOCAL_PYTHON
    try {
        Remove-Item Env:REPOSCOUT_FORCE_LOCAL_PYTHON -ErrorAction SilentlyContinue
        return Find-CompatiblePython
    } finally {
        if ($hadForce) { $env:REPOSCOUT_FORCE_LOCAL_PYTHON = $oldForce }
    }
}

function Describe-PythonDiscovery {
    $items = @()
    foreach ($candidate in (Get-LocalPythonCandidates + @('python'))) {
        try {
            $version = Get-PythonVersionText $candidate
            if (-not [string]::IsNullOrWhiteSpace($version)) { $items += "$candidate => $version" }
        } catch {}
    }
    if ($items.Count -eq 0) { return 'No Python candidates found by RepoWayfinder.' }
    return ($items -join "`n")
}

function Get-PythonRepairHints {
    $hints = [System.Collections.Generic.List[string]]::new()
    try {
        $pyList = & py -0p 2>$null
        foreach ($line in $pyList) {
            $parts = $line.Trim() -split '\s+'
            if ($parts.Count -gt 0) {
                $candidate = $parts[$parts.Count - 1]
                if (($candidate -match '^[A-Za-z]:') -and (-not (Test-Path -LiteralPath $candidate))) {
                    $hints.Add("py launcher points to missing Python: $candidate")
                }
            }
        }
    } catch {}
    try {
        foreach ($entry in (($env:Path -split ';') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            if (($entry -match '(?i)Python') -and (-not (Test-Path -LiteralPath $entry))) {
                $hints.Add("PATH contains missing Python directory: $entry")
            }
        }
    } catch {}
    if ($hints.Count -eq 0) {
        return 'No obvious broken Python PATH or py-launcher leftovers detected. If installer exit code is 1603, check Windows Settings > Apps for a broken Python entry.'
    }
    return ($hints | Select-Object -Unique | Select-Object -First 12) -join "`n"
}
function Install-PythonWithWinget([System.Collections.Generic.List[string]]$failures) {
    $winget = Get-WingetCommand
    if ([string]::IsNullOrWhiteSpace($winget)) {
        $failures.Add('winget not found in PATH or WindowsApps.')
        return $false
    }
    Write-Host "尝试通过 winget 安装 Python 3.11: $winget"
    try {
        $wingetCode = Invoke-RepoWayfinderNativeWithWait $winget @('install','--id','Python.Python.3.11','--source','winget','--scope','user','--accept-package-agreements','--accept-source-agreements')
        if ($wingetCode -eq 0) {
            $script:repoScoutInstalledPython = $true
            $script:repoScoutPythonInstallMethod = 'winget'
            Refresh-ProcessPath
            return $true
        }
        $failures.Add("winget returned exit code $wingetCode")
    } catch {
        $failures.Add("winget failed: $($_.Exception.Message)")
    }
    return $false
}

function Install-PythonWithDirectInstaller([System.Collections.Generic.List[string]]$failures) {
    Write-Host ''
    Write-Host "winget 不可用或安装失败，改用官方 Python 安装器自动下载。"
    Write-Host "下载地址: $pythonDirectInstallerUrl"
    Write-Host "安装方式：安装到 RepoWayfinder 项目本地目录，不修改系统 PATH：$repoScoutPythonDir"
    if (Test-Path -LiteralPath $repoScoutPythonExe) {
        $version = Get-PythonVersionText $repoScoutPythonExe
        if ($version -match '^3\.(11|12|13|14)$') {
            Write-Host "RepoWayfinder local Python already available: $repoScoutPythonExe ($version)"
            $script:repoScoutInstalledPython = $true
            $script:repoScoutPythonInstallMethod = 'python.org-local-installer'
            return $true
        }
    }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    $downloadDir = Join-Path ([System.IO.Path]::GetTempPath()) 'RepoWayfinder'
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    $installerPath = Join-Path $downloadDir "python-$pythonDirectInstallerVersion-amd64.exe"
    try {
        Invoke-WebRequest -Uri $pythonDirectInstallerUrl -OutFile $installerPath -UseBasicParsing -TimeoutSec 300
        if (-not (Test-Path -LiteralPath $installerPath)) { throw 'installer file was not created' }
        $size = (Get-Item -LiteralPath $installerPath).Length
        if ($size -lt 10000000) { throw "installer file is unexpectedly small: $size bytes" }
        if (Test-Path -LiteralPath $repoScoutPythonDir) {
            $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            Move-Item -LiteralPath $repoScoutPythonDir -Destination "$repoScoutPythonDir.old-$timestamp"
        }
        Write-Host 'Python 安装器下载完成，开始安装到 RepoWayfinder 本地目录。Windows 如果弹出确认，请允许。'
        $targetArgument = 'TargetDir="' + $repoScoutPythonDir + '"'
        $args = @('/quiet', 'InstallAllUsers=0', $targetArgument, 'PrependPath=0', 'Include_launcher=0', 'Include_pip=1', 'Include_tcltk=0', 'Include_test=0', 'SimpleInstall=1')
        $process = Start-Process -FilePath $installerPath -ArgumentList $args -PassThru -WindowStyle Hidden
        Wait-RepoWayfinderProcess $process
        if ($process.ExitCode -ne 0) { throw "official installer exit code $($process.ExitCode)" }
        if (-not (Test-Path -LiteralPath $repoScoutPythonExe)) {
            $registeredPython = Find-CompatiblePythonAny
            if ($registeredPython) {
                $failures.Add("official installer returned success without creating the requested local copy; using registered compatible Python instead: $registeredPython")
                $script:repoScoutInstalledPython = $false
                $script:repoScoutPythonInstallMethod = ''
                return $true
            }
            throw "local python.exe was not created and no registered compatible Python was found: $repoScoutPythonExe"
        }
        $version = Get-PythonVersionText $repoScoutPythonExe
        if ($version -notmatch '^3\.(11|12|13|14)$') { throw "local Python version is not compatible: $version" }
        $script:repoScoutInstalledPython = $true
        $script:repoScoutPythonInstallMethod = 'python.org-local-installer'
        return $true
    } catch {
        $message = $_.Exception.Message
        $failures.Add("official local installer failed: $message")
        if ($message -match '1603') {
            $failures.Add('official installer exit code 1603 usually means Windows Installer conflict or broken Python leftovers. Do not delete registry/PATH manually unless you know exactly what you are removing; use Windows Settings > Apps to repair/uninstall Python first.')
        }
        return $false
    } finally {
        try { Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue } catch {}
    }
}
function Install-PythonIfMissing {
    Write-Host ''
    Write-Host '未找到可用 Python 3.11-3.14，RepoWayfinder 将尝试自动安装 Python（用户级安装）。'
    Write-Host '优先使用 winget；如果 winget 不可用，会自动下载官方 Python 3.11.9 安装器到项目本地 .reposcout-python。'
    Write-Host '如果 Windows 弹出安装确认，请允许；这一步需要网络。'
    $failures = [System.Collections.Generic.List[string]]::new()
    $forceLocalPython = ($env:REPOSCOUT_FORCE_LOCAL_PYTHON -eq '1')

    $wingetOk = $false
    if (-not $forceLocalPython) {
        $wingetOk = Install-PythonWithWinget $failures
        $basePython = Find-CompatiblePythonAny
        if ($wingetOk -and -not [string]::IsNullOrWhiteSpace($basePython)) {
            Write-Host "Python ready after winget: $basePython"
            Write-RepoWayfinderInstallState -pythonInstalledByRepoWayfinder $true
            return
        }
        if ($wingetOk -and [string]::IsNullOrWhiteSpace($basePython)) {
            $failures.Add('winget reported success, but RepoWayfinder still could not find Python. Discovery:`n' + (Describe-PythonDiscovery))
        }
    } else {
        $failures.Add('REPOSCOUT_FORCE_LOCAL_PYTHON=1; skipped winget for local bootstrap test.')
    }

    $directOk = Install-PythonWithDirectInstaller $failures
    $basePython = Find-CompatiblePython
    if ($directOk -and -not [string]::IsNullOrWhiteSpace($basePython)) {
        Write-Host "Python ready after local installer: $basePython"
        Write-RepoWayfinderInstallState -pythonInstalledByRepoWayfinder $true
        return
    }
    if ($directOk -and [string]::IsNullOrWhiteSpace($basePython)) {
        $failures.Add('official installer reported success, but RepoWayfinder still could not find Python. Discovery:`n' + (Describe-PythonDiscovery))
    }

    $basePythonAny = Find-CompatiblePythonAny
    if (-not [string]::IsNullOrWhiteSpace($basePythonAny)) {
        Write-Host "Python found by final discovery: $basePythonAny"
        Write-RepoWayfinderInstallState -pythonInstalledByRepoWayfinder $script:repoScoutInstalledPython
        return
    }

    $failureText = ($failures | Select-Object -Last 10) -join "`n"
    $repairHints = Get-PythonRepairHints
    Show-RepoWayfinderMessage "Python 自动安装没有完成。`n`nRepoWayfinder 已尝试：`n1. winget 用户级安装 Python.Python.3.11（如果系统没有 winget，会自动跳过）`n2. 官方 python.org 安装器自动下载并安装本地 Python $pythonDirectInstallerVersion 到 .reposcout-python`n`n失败摘要：`n$failureText`n`n本机 Python 残留检查：`n$repairHints`n`n建议：`n1. 不要直接删除 Python 文件夹。`n2. 如果你之前手动删除过 Python，请先到 Windows 设置 > 应用 里卸载/修复残留 Python。`n3. 然后重新双击 点我启动RepoWayfinder.bat。`n4. 如果仍失败，再手动安装 Python 3.11-3.14：https://www.python.org/downloads/，并勾选 Add python.exe to PATH。" 'RepoWayfinder Python 安装失败'
    throw 'Python automatic installation failed.'
}
function Write-RepoWayfinderInstallState([bool]$pythonInstalledByRepoWayfinder) {
    $existingPythonInstalled = $false
    if (Test-Path -LiteralPath $installStatePath) {
        try {
            $existing = Get-Content -LiteralPath $installStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $existingPythonInstalled = [bool]$existing.python_installed_by_reposcout
        } catch {}
    }
    $state = [ordered]@{
        version = 1
        project_dir = $projectDir
        updated_at = (Get-Date).ToString('s')
        reposcout_venv_path = $venvDir
        reposcout_env_path = $localEnvPath
        venv_created_by_reposcout = (Test-Path -LiteralPath $pythonExe -PathType Leaf)
        python_installed_by_reposcout = ($pythonInstalledByRepoWayfinder -or $existingPythonInstalled)
        python_winget_package_id = 'Python.Python.3.11'
        python_install_method = $script:repoScoutPythonInstallMethod
        python_direct_installer_version = $pythonDirectInstallerVersion
        reposcout_python_path = $repoScoutPythonDir
        git_installed_by_reposcout = $script:repoScoutInstalledGit
        git_install_method = $script:repoScoutGitInstallMethod
        mingit_version = $mingitVersion
        reposcout_git_path = $repoScoutGitDir
        uninstall_script = (Join-Path $projectDir 'uninstall_reposcout.ps1')
    }
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $installStatePath -Encoding UTF8
}

function Convert-SecureStringToPlainText([securestring]$value) {
    if ($null -eq $value) { return '' }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($value)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) } }
}

function Clean-EnvValue([string]$value) {
    if ($null -eq $value) { return '' }
    return ($value -replace "`r", '' -replace "`n", '').Trim()
}

function Read-SecretOrSkip([string]$prompt) {
    Write-Host $prompt
    try {
        $secret = Read-Host -AsSecureString
        return Convert-SecureStringToPlainText $secret
    } catch {
        return Read-Host
    }
}

function Read-VisibleChoice([string]$prompt) {
    Write-Host $prompt
    return (Read-Host).Trim()
}

function Protect-RepoWayfinderSecret([string]$value) {
    $clean = Clean-EnvValue $value
    if ([string]::IsNullOrWhiteSpace($clean)) { return '' }
    try {
        $secure = ConvertTo-SecureString -String $clean -AsPlainText -Force
        return ConvertFrom-SecureString -SecureString $secure
    } catch {
        return ''
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
        return ''
    }
}

function Convert-ExistingRepoWayfinderEnvToDpapi {
    if (-not (Test-Path -LiteralPath $localEnvPath)) { return }
    $rawLines = Get-Content -LiteralPath $localEnvPath -Encoding UTF8
    $values = @{}
    $alreadyProtected = $false
    foreach ($line in $rawLines) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        $pair = $trimmed -split '=', 2
        if ($pair.Count -ne 2) { continue }
        $values[$pair[0].Trim()] = $pair[1].Trim()
        if ($pair[0].Trim().EndsWith('_DPAPI')) { $alreadyProtected = $true }
    }
    if ($alreadyProtected) { return }
    $githubToken = if ($values.ContainsKey('GITHUB_TOKEN')) { $values['GITHUB_TOKEN'] } else { '' }
    $aiKey = if ($values.ContainsKey('OPENROUTER_API_KEY')) { $values['OPENROUTER_API_KEY'] } elseif ($values.ContainsKey('DEEPSEEK_API_KEY')) { $values['DEEPSEEK_API_KEY'] } else { '' }
    $aiModel = if ($values.ContainsKey('REPOSCOUT_AI_MODEL')) { $values['REPOSCOUT_AI_MODEL'] } elseif ($values.ContainsKey('OPENROUTER_MODEL')) { $values['OPENROUTER_MODEL'] } elseif ($values.ContainsKey('DEEPSEEK_MODEL')) { $values['DEEPSEEK_MODEL'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($githubToken) -and [string]::IsNullOrWhiteSpace($aiKey)) { return }
    Write-Host 'Existing plaintext .reposcout.env detected. Converting secrets to Windows DPAPI format for this Windows user.'
    Write-RepoWayfinderLocalEnv $githubToken $aiKey $aiModel $false
}

function Write-RepoWayfinderLocalEnv([string]$githubToken, [string]$aiKey, [string]$aiModel, [bool]$skipped, [bool]$clearExisting=$false) {
    $lines = @(
        '# RepoWayfinder local API configuration.',
        '# SECURITY: Secret values are stored with Windows DPAPI for the current Windows user when possible.',
        '# If DPAPI cannot be used, rerun install_reposcout.ps1 -ForceApiSetup instead of editing this file by hand.',
        '# Delete this file to remove local RepoWayfinder API configuration.',
        ''
    )
    if ($skipped) { $lines += 'REPOSCOUT_API_SETUP_SKIPPED=1' }
    $githubTokenProtected = Protect-RepoWayfinderSecret $githubToken
    $aiKeyProtected = Protect-RepoWayfinderSecret $aiKey
    if (-not [string]::IsNullOrWhiteSpace($githubTokenProtected)) { $lines += "GITHUB_TOKEN_DPAPI=$githubTokenProtected" }
    elseif (-not [string]::IsNullOrWhiteSpace($githubToken)) { $lines += "GITHUB_TOKEN=$(Clean-EnvValue $githubToken)" }
    if (-not [string]::IsNullOrWhiteSpace($aiKeyProtected)) { $lines += "OPENROUTER_API_KEY_DPAPI=$aiKeyProtected" }
    elseif (-not [string]::IsNullOrWhiteSpace($aiKey)) { $lines += "OPENROUTER_API_KEY=$(Clean-EnvValue $aiKey)" }
    if (-not [string]::IsNullOrWhiteSpace($aiModel)) { $lines += "REPOSCOUT_AI_MODEL=$(Clean-EnvValue $aiModel)" }
    if ($clearExisting) {
        Remove-Item -LiteralPath $localEnvPath -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $projectDir -Filter '.reposcout.env.backup-*' -File -ErrorAction SilentlyContinue | Remove-Item -Force
    } elseif (Test-Path -LiteralPath $localEnvPath) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Move-Item -LiteralPath $localEnvPath -Destination "$localEnvPath.backup-$timestamp"
    }
    Set-Content -LiteralPath $localEnvPath -Value $lines -Encoding UTF8
    Write-Host (Get-RepoWayfinderUiText "RepoWayfinder 本地 API 配置已写入：$localEnvPath" "Local RepoWayfinder API config written: $localEnvPath")
    Write-Host (Get-RepoWayfinderUiText '密钥值不会显示。不要分享 .reposcout.env。' 'Secret values are not printed. Do not share .reposcout.env.')
}

function Configure-RepoWayfinderApis {
    if ($SkipApiSetup) { Write-Host 'Skipping API configuration because -SkipApiSetup was provided.'; return }
    if ((Test-Path -LiteralPath $localEnvPath) -and -not $ForceApiSetup) {
        Convert-ExistingRepoWayfinderEnvToDpapi
        Write-Host '.reposcout.env already exists; API setup not repeated.'
        return
    }
    if ($NoUI) {
        Write-Host 'No interactive API setup is available in -NoUI mode; recording a truthful no-key skip and continuing.'
        Write-RepoWayfinderLocalEnv -githubToken '' -aiKey '' -aiModel '' -skipped $true
        return
    }
    Write-Host ''
    $hasExistingConfig = Test-Path -LiteralPath $localEnvPath
    Write-Host (Get-RepoWayfinderUiText 'RepoWayfinder API 配置与更换向导' 'RepoWayfinder API setup and replacement wizard')
    Write-Host (Get-RepoWayfinderUiText '完整功能推荐配置一个 AI key（DeepSeek 或 OpenRouter）；GitHub token 始终可选。' 'For full features, configure one AI key (DeepSeek or OpenRouter). GitHub token is always optional.')
    Write-Host (Get-RepoWayfinderUiText '推荐平台：' 'Recommended services:')
    Write-Host '  GitHub Token: https://github.com/settings/personal-access-tokens'
    Write-Host '  DeepSeek API:  https://platform.deepseek.com/api_keys'
    Write-Host '  OpenRouter:    https://openrouter.ai/settings/keys'
    Write-Host ''
    Write-Host (Get-RepoWayfinderUiText '安全警告：API key 是秘密。不要发给别人，不要截图，不要提交 GitHub，不要放进报告。' 'Security: API keys are secrets. Do not share, screenshot, commit, or place them in reports.')
    Write-Host ''
    if ($hasExistingConfig) {
        Write-Host (Get-RepoWayfinderUiText '[1] 添加或更换 API key' '[1] Add or replace API key')
        Write-Host (Get-RepoWayfinderUiText '[2] 清除 RepoWayfinder 保存的全部 API key' '[2] Clear all RepoWayfinder API keys')
        Write-Host (Get-RepoWayfinderUiText '[3] 取消，保留现有配置' '[3] Cancel and keep existing config')
        do { $setupChoice = Read-VisibleChoice (Get-RepoWayfinderUiText '请输入 1、2 或 3；直接回车不会修改现有配置：' 'Enter 1, 2, or 3. Empty Enter does not modify existing config:') } until ($setupChoice -in @('1','2','3'))
        if ($setupChoice -eq '2') {
            Write-RepoWayfinderLocalEnv -githubToken '' -aiKey '' -aiModel '' -skipped $true -clearExisting $true
            Write-Host (Get-RepoWayfinderUiText '已清除 RepoWayfinder API key；基础/无 AI 路径仍可使用。' 'RepoWayfinder API keys were cleared. Basic non-AI paths remain available.')
            return
        }
        if ($setupChoice -eq '3') { Write-Host (Get-RepoWayfinderUiText '现有 API 配置保持不变。' 'Existing API config was kept.'); return }
    } else {
        Write-Host (Get-RepoWayfinderUiText '[1] 现在配置（完整功能推荐）' '[1] Configure now (recommended for full features)')
        Write-Host (Get-RepoWayfinderUiText '[2] 稍后配置（仅基础/无 AI 功能）' '[2] Configure later (basic non-AI features only)')
        do { $setupChoice = Read-VisibleChoice (Get-RepoWayfinderUiText '请输入 1 或 2；直接回车不会替你作决定：' 'Enter 1 or 2. Empty Enter does not decide for you:') } until ($setupChoice -in @('1','2'))
        if ($setupChoice -eq '2') {
            Write-RepoWayfinderLocalEnv -githubToken '' -aiKey '' -aiModel '' -skipped $true
            return
        }
    }
    $githubToken = Read-SecretOrSkip (Get-RepoWayfinderUiText '可选：粘贴 GITHUB_TOKEN；不需要时直接回车' 'Optional: paste GITHUB_TOKEN, or press Enter to skip')
    Write-Host ''
    Write-Host (Get-RepoWayfinderUiText 'AI API 平台：1=DeepSeek 官方（推荐中文用户），2=OpenRouter' 'AI API provider: 1=DeepSeek, 2=OpenRouter')
    do { $providerChoice = Read-VisibleChoice (Get-RepoWayfinderUiText '请输入 1 或 2；进入配置后不能用空输入静默跳过：' 'Enter 1 or 2. After entering setup, empty input cannot silently skip:') } until ($providerChoice -in @('1','2'))
    $aiKey = ''
    $aiModel = ''
    if ($providerChoice -eq '1') {
        while ([string]::IsNullOrWhiteSpace($aiKey)) {
            $aiKey = Read-SecretOrSkip (Get-RepoWayfinderUiText '粘贴 DeepSeek API key（不能为空；按 Ctrl+C 可取消向导）' 'Paste DeepSeek API key (required; press Ctrl+C to cancel)')
        }
        $aiModel = 'deepseek-v4-flash'
    } elseif ($providerChoice -eq '2') {
        while ([string]::IsNullOrWhiteSpace($aiKey)) {
            $aiKey = Read-SecretOrSkip (Get-RepoWayfinderUiText '粘贴 OpenRouter API key（不能为空；按 Ctrl+C 可取消向导）' 'Paste OpenRouter API key (required; press Ctrl+C to cancel)')
        }
        $aiModel = 'deepseek/deepseek-chat'
    }
    Write-RepoWayfinderLocalEnv -githubToken $githubToken -aiKey $aiKey -aiModel $aiModel -skipped $false
}

Write-Host (Get-RepoWayfinderUiText 'RepoWayfinder 安装器' 'RepoWayfinder installer')
Write-Host (Get-RepoWayfinderUiText "项目目录：$projectDir" "Project: $projectDir")

if ($ConfigOnly) {
    Configure-RepoWayfinderApis
    exit 0
}

if (-not (Test-Path -LiteralPath $requirements)) { throw "Missing requirements.txt: $requirements" }

$basePython = Find-CompatiblePython
if ([string]::IsNullOrWhiteSpace($basePython)) {
    Install-PythonIfMissing
    $basePython = Find-CompatiblePython
    if ([string]::IsNullOrWhiteSpace($basePython)) { $basePython = Find-CompatiblePythonAny }
    if ([string]::IsNullOrWhiteSpace($basePython)) { throw 'Python installed but still not found in PATH. Restart PowerShell or Windows, then rerun.' }
}


Install-RepoWayfinderLocalGit

$needsCreate = $true
if (Test-Path -LiteralPath $pythonExe) {
    $version = Get-PythonVersionText $pythonExe
    if ($version -match '^3\.(11|12|13|14)$') {
        $needsCreate = $false
        Write-Host "Existing RepoWayfinder venv OK: Python $version"
    }
}

if ($needsCreate) {
    if (Test-Path -LiteralPath $venvDir) {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Move-Item -LiteralPath $venvDir -Destination "$venvDir.old-$timestamp"
    }
    Write-Host "Creating RepoWayfinder venv with: $basePython"
    $venvOutput = (& $basePython -m venv $venvDir 2>&1 | Out-String).Trim()
    $venvExitCode = $LASTEXITCODE
    if ($venvOutput) { Write-Host $venvOutput }
    if ($venvExitCode -ne 0 -or -not (Test-Path -LiteralPath $pythonExe -PathType Leaf)) {
        $detail = if ($venvOutput) { $venvOutput } else { 'The Python process returned no diagnostic text.' }
        throw "Failed to create RepoWayfinder venv with '$basePython' (exit code $venvExitCode). Detail: $detail"
    }
}

Write-Host (Get-RepoWayfinderUiText '正在安装 RepoWayfinder 依赖……' 'Installing RepoWayfinder dependencies...')
& $pythonExe -m ensurepip | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'ensurepip failed.' }
& $pythonExe -m pip install --upgrade pip | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'pip upgrade failed.' }
& $pythonExe -m pip install -r $requirements | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'dependency installation failed.' }

Write-Host ''
Write-Host (Get-RepoWayfinderUiText 'RepoWayfinder 环境安装完成。' 'RepoWayfinder environment install complete.')
Write-RepoWayfinderInstallState -pythonInstalledByRepoWayfinder $script:repoScoutInstalledPython
Configure-RepoWayfinderApis








