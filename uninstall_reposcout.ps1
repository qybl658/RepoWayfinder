param(
    [switch]$Yes,
    [switch]$RemovePython,
    [switch]$RemoveDocker,
    [switch]$RemoveNode,
    [switch]$KeepReports,
    [switch]$KeepApiConfig,
    [switch]$NoPause,
    [switch]$DryRun
)

# RepoWayfinder safe uninstaller.
# Removes RepoWayfinder-created project-local files. System Python is removed only when a RepoWayfinder install marker exists and the user confirms.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $projectDir
$uiHelper = Join-Path $projectDir 'reposcout_ui.ps1'
if (-not (Test-Path -LiteralPath $uiHelper -PathType Leaf)) { throw "RepoWayfinder UI helper not found: $uiHelper" }
. $uiHelper
[void](Initialize-RepoWayfinderUiLanguage $projectDir)

$venvDir = Join-Path $projectDir '.reposcout-venv'
$localEnvPath = Join-Path $projectDir '.reposcout.env'
$installStatePath = Join-Path $projectDir '.reposcout-install-state.json'
$reportsDir = Join-Path $projectDir 'reports'
$targetsDir = Join-Path $projectDir 'Projects'
$ownedTargetsPath = Join-Path $projectDir '.reposcout-owned-projects.json'
$repoScoutGitDir = Join-Path $projectDir '.reposcout-git'
$repoScoutPythonDir = Join-Path $projectDir '.reposcout-python'
$repoScoutToolsDir = Join-Path $projectDir '.reposcout-tools'
$prerequisiteStatePath = Join-Path $projectDir '.reposcout-prerequisites.json'
$settingsPath = Join-Path $projectDir '.reposcout-settings.json'
$settingsTempPath = Join-Path $projectDir '.reposcout-settings.json.tmp'

function Pause-IfNeeded {
    if (-not $NoPause) {
        Write-Host ''
        Read-Host (Get-RepoWayfinderUiText '按 Enter 退出' 'Press Enter to exit')
    }
}

function Show-RepoWayfinderMessage([string]$text, [string]$title='RepoWayfinder') {
    Write-Host $text
    if ($NoPause -or $DryRun) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($text, $title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {}
}

function Confirm-Action([string]$prompt, [bool]$defaultYes=$false) {
    if ($Yes) { return $true }
    return (Read-RepoWayfinderExplicitYesNo $prompt $prompt)
}

function Remove-RepoWayfinderOwnedTargets {
    if (-not (Test-Path -LiteralPath $ownedTargetsPath -PathType Leaf)) {
        Write-Host (Get-RepoWayfinderUiText '没有可信的目标项目所有权清单；为避免误删，保留 Projects。' 'No trusted target ownership manifest exists; preserving Projects to avoid deleting user data.')
        return
    }
    try { $manifest = Get-Content -LiteralPath $ownedTargetsPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-Host (Get-RepoWayfinderUiText '目标所有权清单无法读取；保留 Projects。' 'Target ownership manifest is unreadable; preserving Projects.'); return }
    $root = [IO.Path]::GetFullPath($targetsDir).TrimEnd('\')
    foreach ($relative in @($manifest.paths)) {
        if ([string]::IsNullOrWhiteSpace([string]$relative) -or [string]$relative -match '[\\/]' -or [string]$relative -in @('.', '..')) { continue }
        $target = [IO.Path]::GetFullPath((Join-Path $root ([string]$relative)))
        if (-not $target.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }
        Remove-ProjectPath $target (Get-RepoWayfinderUiText "RepoWayfinder 下载的目标项目 $relative" "RepoWayfinder-owned target $relative")
    }
    if ((Test-Path -LiteralPath $targetsDir) -and -not (Get-ChildItem -LiteralPath $targetsDir -Force | Select-Object -First 1)) {
        Remove-ProjectPath $targetsDir (Get-RepoWayfinderUiText '空的目标项目目录' 'empty target directory')
    }
    Remove-ProjectPath $ownedTargetsPath (Get-RepoWayfinderUiText '目标项目所有权清单' 'target ownership manifest')
}

function Test-PathInsideProject([string]$path) {
    $fullProject = [System.IO.Path]::GetFullPath($projectDir).TrimEnd('\')
    $fullPath = [System.IO.Path]::GetFullPath($path).TrimEnd('\')
    if ($fullPath -eq $fullProject) { return $false }
    return $fullPath.StartsWith($fullProject + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-ProjectPath([string]$path, [string]$label) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    if (-not (Test-PathInsideProject $path)) {
        throw "拒绝删除项目外路径: $path"
    }
    if ($DryRun) {
        Write-Host "DRY RUN would remove ${label}: $path"
        return
    }
    Write-Host "删除 ${label}: $path"
    Remove-Item -LiteralPath $path -Recurse -Force
}

function Read-InstallState {
    if (-not (Test-Path -LiteralPath $installStatePath)) { return $null }
    try {
        return Get-Content -LiteralPath $installStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Host "安装标记读取失败，将按保守模式处理: $installStatePath"
        return $null
    }
}

function Remove-RepoWayfinderDockerImages {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($null -eq $docker) { return }
    try {
        $images = & docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' 2>$null |
            Where-Object { $_ -match '^reposcout-[^\s]+ ' }
    } catch {
        return
    }
    if (-not $images) { return }
    Write-Host ''
    Write-Host (Get-RepoWayfinderUiText '检测到 RepoWayfinder 可能创建过的 Docker 镜像：' 'Possible RepoWayfinder-created Docker images:')
    foreach ($image in $images) { Write-Host "  $image" }
    if ($DryRun) { Write-Host 'DRY RUN would ask before removing reposcout-* Docker images.'; return }
    if (Confirm-Action (Get-RepoWayfinderUiText '是否删除这些 reposcout-* Docker 镜像？' 'Remove these reposcout-* Docker images?') $false) {
        foreach ($image in $images) {
            $parts = $image -split '\s+'
            if ($parts.Count -ge 2) {
                & docker rmi -f $parts[1] | Out-Host
            }
        }
    }
}

function Get-PythonRegistryUninstallEntries([string]$versionPrefix) {
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entries = @()
    foreach ($root in $roots) {
        try {
            $entries += Get-ItemProperty -Path $root -ErrorAction SilentlyContinue |
                Where-Object {
                    ($_.DisplayName -match "Python $versionPrefix") -and
                    ($_.Publisher -match 'Python|Python Software Foundation' -or $_.DisplayName -match 'Python') -and
                    ($_.UninstallString)
                }
        } catch {}
    }
    return $entries
}

function Split-UninstallCommand([string]$commandLine) {
    $commandLine = ($commandLine -as [string]).Trim()
    if ([string]::IsNullOrWhiteSpace($commandLine)) { return $null }
    if ($commandLine -match '^"([^"]+)"\s*(.*)$') {
        return [pscustomobject]@{ Exe = $matches[1]; Args = $matches[2] }
    }
    $parts = $commandLine -split '\s+', 2
    return [pscustomobject]@{ Exe = $parts[0]; Args = if ($parts.Count -gt 1) { $parts[1] } else { '' } }
}

function ConvertTo-OfficialPythonUninstallArgs([string]$exe, [string]$args) {
    $result = ($args -as [string]).Trim()
    $exeName = [System.IO.Path]::GetFileName($exe)
    if ($exeName -match '(?i)^msiexec(\.exe)?$') {
        $result = $result -replace '(?i)(^|\s)/I', ' /X'
        if ($result -notmatch '(?i)(^|\s)/X') { $result = "/X $result" }
        if ($result -notmatch '(?i)(^|\s)/qn(\s|$)') { $result = "$result /qn" }
        if ($result -notmatch '(?i)(^|\s)/norestart(\s|$)') { $result = "$result /norestart" }
        return $result.Trim()
    }
    if ($result -notmatch '(?i)(^|\s)/uninstall(\s|$)') { $result = "$result /uninstall" }
    if ($result -notmatch '(?i)(^|\s)/quiet(\s|$)|(^|\s)/passive(\s|$)|(^|\s)/qn(\s|$)') { $result = "$result /quiet" }
    if ($result -notmatch '(?i)(^|\s)/norestart(\s|$)') { $result = "$result /norestart" }
    return $result.Trim()
}

function Invoke-OfficialPythonUninstallEntry($entry, [string]$label) {
    $cmd = ''
    if ($entry.PSObject.Properties.Name -contains 'QuietUninstallString' -and -not [string]::IsNullOrWhiteSpace($entry.QuietUninstallString)) {
        $cmd = [string]$entry.QuietUninstallString
    } else {
        $cmd = [string]$entry.UninstallString
    }
    $split = Split-UninstallCommand $cmd
    if ($null -eq $split) { return $false }
    $exe = $split.Exe
    $args = ConvertTo-OfficialPythonUninstallArgs $exe $split.Args
    Write-Host "Run official Python uninstaller for ${label}: $($entry.DisplayName)"
    if ($DryRun) {
        Write-Host "DRY RUN would run: $exe $args"
        return $true
    }
    try {
        $process = Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru
        if ($process.ExitCode -eq 0) { return $true }
        Write-Host "Official Python uninstaller exit code: $($process.ExitCode)"
        return $false
    } catch {
        Write-Host "Official Python uninstaller failed: $($_.Exception.Message)"
        return $false
    }
}

function Test-PathInsideOrEqual([string]$child, [string]$parent) {
    if ([string]::IsNullOrWhiteSpace($child) -or [string]::IsNullOrWhiteSpace($parent)) { return $false }
    try {
        $fullChild = [System.IO.Path]::GetFullPath($child).TrimEnd('\')
        $fullParent = [System.IO.Path]::GetFullPath($parent).TrimEnd('\')
        return ($fullChild -eq $fullParent) -or $fullChild.StartsWith($fullParent + '\', [System.StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Get-RepoWayfinderLocalPythonUninstallEntries {
    $entries = Get-PythonRegistryUninstallEntries ''
    $matched = @()
    foreach ($entry in $entries) {
        $installLocation = ''
        if ($entry.PSObject.Properties.Name -contains 'InstallLocation') { $installLocation = [string]$entry.InstallLocation }
        $uninstallString = [string]$entry.UninstallString
        $quietString = if ($entry.PSObject.Properties.Name -contains 'QuietUninstallString') { [string]$entry.QuietUninstallString } else { '' }
        if ((Test-PathInsideOrEqual $installLocation $repoScoutPythonDir) -or
            ($uninstallString -like "*$repoScoutPythonDir*") -or
            ($quietString -like "*$repoScoutPythonDir*")) {
            $matched += $entry
        }
    }
    return $matched
}

function Invoke-RepoWayfinderPythonInstallerFallback($state) {
    $version = if ($null -ne $state) { [string]$state.python_direct_installer_version } else { '' }
    if ($version -notmatch '^3\.\d+\.\d+$') {
        Write-Host '安装标记里没有可信的 Python 完整版本，无法安全重新下载官方卸载器。'
        return $false
    }
    $url = "https://www.python.org/ftp/python/$version/python-$version-amd64.exe"
    $downloadDir = Join-Path ([IO.Path]::GetTempPath()) 'RepoWayfinder'
    $installerPath = Join-Path $downloadDir "python-$version-amd64.exe"
    Write-Host "未找到本地卸载登记；准备从 python.org 重新下载同版本官方安装器：$version"
    if ($DryRun) {
        Write-Host "DRY RUN would download $url and run the official uninstaller for $repoScoutPythonDir"
        return $true
    }
    try {
        New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
        Invoke-WebRequest -Uri $url -OutFile $installerPath -UseBasicParsing -TimeoutSec 300
        if ((Get-Item -LiteralPath $installerPath).Length -lt 10000000) { throw 'downloaded installer is unexpectedly small' }
        $args = @('/uninstall', '/quiet', '/norestart', 'InstallAllUsers=0', "TargetDir=$repoScoutPythonDir")
        $process = Start-Process -FilePath $installerPath -ArgumentList $args -Wait -PassThru
        return ($process.ExitCode -in @(0, 3010))
    } catch {
        Write-Host "重新下载官方 Python 卸载器失败：$($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
    }
}
function Uninstall-RepoWayfinderLocalPython($state) {
    if (-not (Test-Path -LiteralPath $repoScoutPythonDir)) { return $true }
    Write-Host ''
    Write-Host 'RepoWayfinder local Python detected: .reposcout-python'
    Write-Host 'RepoWayfinder will run the official Python uninstaller before cleaning the project-local folder.'
    $entries = Get-RepoWayfinderLocalPythonUninstallEntries
    $ok = $false
    foreach ($entry in @($entries)) {
        if (Invoke-OfficialPythonUninstallEntry $entry '.reposcout-python') { $ok = $true }
    }
    if (-not $ok) { $ok = Invoke-RepoWayfinderPythonInstallerFallback $state }
    if ($DryRun) { return $ok }
    if ($ok) {
        for ($attempt = 1; $attempt -le 3 -and (Test-Path -LiteralPath $repoScoutPythonDir); $attempt++) {
            try {
                Remove-ProjectPath $repoScoutPythonDir 'RepoWayfinder local Python leftover folder after official uninstall'
            } catch {
                if ($attempt -eq 3) { throw }
                Start-Sleep -Seconds 1
            }
        }
        return (-not (Test-Path -LiteralPath $repoScoutPythonDir))
    }
    Write-Host '官方 Python 卸载没有完成；已保留 .reposcout-python 和安装标记，避免造成更难修复的残留。'
    Write-Host '请关闭仍在使用该 Python 的终端或进程，再重新运行卸载器。'
    return $false
}
function Read-PrerequisiteState {
    if (-not (Test-Path -LiteralPath $prerequisiteStatePath)) { return $null }
    try {
        $value = Get-Content -LiteralPath $prerequisiteStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([IO.Path]::GetFullPath([string]$value.project_dir).TrimEnd('\') -ne [IO.Path]::GetFullPath($projectDir).TrimEnd('\')) {
            Write-Host '前置环境安装标记不属于当前 RepoWayfinder 目录；为安全起见不会卸载共享软件。'
            return $null
        }
        return $value
    } catch {
        Write-Host "前置环境安装标记读取失败；不会卸载共享软件：$($_.Exception.Message)"
        return $null
    }
}

function Get-RegisteredSharedPackageEntries([string]$name) {
    $roots = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $pattern = if ($name -eq 'docker') { '^Docker Desktop$' } else { '^Node\.js' }
    $entries = @()
    foreach ($root in $roots) {
        try { $entries += Get-ItemProperty -Path $root -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $pattern } } catch {}
    }
    return @($entries)
}

function ConvertTo-RegisteredMsiUninstallArgs([string]$command, [string]$arguments) {
    $combined = "$command $arguments"
    if ($combined -match '(?i)\{[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\}') {
        # Use the registered MSI product code explicitly. Passing the raw
        # uninstall string through an automatic PowerShell variable caused
        # msiexec to interpret the current project directory as its target.
        return "/x $($matches[0]) /qn /norestart"
    }
    return ConvertTo-OfficialPythonUninstallArgs 'msiexec.exe' $arguments
}

function Invoke-RecordedPackageUninstall([string]$packageId, [string]$label, [string]$name) {
    if ($DryRun) {
        Write-Host "DRY RUN would uninstall recorded package: $packageId ($label)"
        return $true
    }
    if (@(Get-RegisteredSharedPackageEntries $name).Count -eq 0) {
        Write-Host "$label 已不存在；清理 RepoWayfinder 安装标记。"
        return $true
    }
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -ne $winget) {
        Write-Host "正在通过 winget 卸载 RepoWayfinder 有安装记录的共享环境：$label"
        & $winget.Source uninstall --id $packageId --exact --silent --accept-source-agreements | Out-Host
        $wingetExitCode = $LASTEXITCODE
        if (@(Get-RegisteredSharedPackageEntries $name).Count -eq 0) { return $true }
        Write-Host "winget 卸载 $label 退出码：$wingetExitCode；软件仍有 Windows 登记，继续使用官方卸载登记。"
    }
    $entries = @(Get-RegisteredSharedPackageEntries $name | Where-Object { $_.UninstallString })
    foreach ($entry in $entries) {
        $command = if (-not [string]::IsNullOrWhiteSpace([string]$entry.QuietUninstallString)) { [string]$entry.QuietUninstallString } else { [string]$entry.UninstallString }
        $split = Split-UninstallCommand $command
        if ($null -eq $split) { continue }
        $uninstallArguments = [string]$split.Args
        if ([IO.Path]::GetFileName($split.Exe) -match '(?i)^msiexec(\.exe)?$') {
            $uninstallArguments = ConvertTo-RegisteredMsiUninstallArgs $command $uninstallArguments
        } elseif ($name -eq 'docker' -and $uninstallArguments -notmatch '(?i)(^|\s)uninstall(\s|$)') {
            $uninstallArguments = ($uninstallArguments + ' uninstall').Trim()
        }
        try {
            Write-Host "正在运行 Windows 登记的 $label 卸载程序。"
            Write-Host "卸载命令：$($split.Exe) $uninstallArguments"
            $process = Start-Process -FilePath $split.Exe -ArgumentList $uninstallArguments -Wait -PassThru
            Write-Host "$label 登记卸载程序退出码：$($process.ExitCode)"
            if (@(Get-RegisteredSharedPackageEntries $name).Count -eq 0) { return $true }
        } catch { Write-Host "$label 登记卸载程序失败：$($_.Exception.Message)" }
    }
    if ($name -eq 'docker') {
        $dockerInstaller = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop Installer.exe'
        if (Test-Path -LiteralPath $dockerInstaller -PathType Leaf) {
            try {
                Write-Host '正在运行 Docker Desktop 官方安装器的 uninstall 模式。'
                $process = Start-Process -FilePath $dockerInstaller -ArgumentList 'uninstall' -Wait -PassThru
                Write-Host "Docker 官方卸载器退出码：$($process.ExitCode)"
                if (@(Get-RegisteredSharedPackageEntries $name).Count -eq 0) { return $true }
            } catch { Write-Host "Docker 官方卸载器失败：$($_.Exception.Message)" }
        }
    }
    if (@(Get-RegisteredSharedPackageEntries $name).Count -eq 0) { return $true }
    Write-Host "未能自动卸载 $label。已保留安装标记；请在 Windows 设置 > 应用中卸载后重试。"
    return $false
}
function Remove-RepoWayfinderInstalledPrerequisites($state) {
    if ($null -eq $state -or $null -eq $state.items) { return $true }
    $hadFailure = $false
    $remaining = [Collections.Generic.List[object]]::new()
    foreach ($item in @($state.items)) {
        $name = [string]$item.name
        $recorded = [bool]$item.installed_by_reposcout
        if (-not $recorded -or $name -notin @('docker', 'node')) { $remaining.Add($item); continue }
        $label = if ($name -eq 'docker') { 'Docker Desktop' } else { 'Node.js LTS' }
        $packageId = if ([string]::IsNullOrWhiteSpace([string]$item.package_id)) {
            if ($name -eq 'docker') { 'Docker.DockerDesktop' } else { 'OpenJS.NodeJS.LTS' }
        } else { [string]$item.package_id }
        $requested = if ($name -eq 'docker') { [bool]$RemoveDocker } else { [bool]$RemoveNode }
        if (-not $requested) {
            Write-Host ''
            Write-Host "检测到 $label 是 RepoWayfinder 经你确认后安装的共享环境。"
            if ($name -eq 'docker') { Write-Host (Get-RepoWayfinderUiText '卸载 Docker Desktop 可能影响其他项目和本机容器/镜像数据。' 'Removing Docker Desktop may affect other projects and local container/image data.') }
            if (-not (Confirm-Action (Get-RepoWayfinderUiText "是否卸载 $label？" "Uninstall $label?") $false)) {
                Write-Host (Get-RepoWayfinderUiText "已保留 $label。" "Kept $label.")
                $remaining.Add($item)
                continue
            }
        }
        if (-not (Invoke-RecordedPackageUninstall $packageId $label $name)) { $remaining.Add($item); $hadFailure = $true }
    }
    if ($DryRun) { return $true }
    if ($remaining.Count -eq 0) {
        Remove-ProjectPath $prerequisiteStatePath 'RepoWayfinder 前置环境安装标记'
    } else {
        $state.items = @($remaining)
        $state.updated_at = (Get-Date).ToString('s')
        $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $prerequisiteStatePath -Encoding UTF8
    }
    return (-not $hadFailure)
}
function Remove-RepoWayfinderInstalledPython($state) {
    $pythonPackageId = 'Python.Python.3.11'
    $pythonVersion = '3.11'
    $markedInstalled = $false
    if ($null -ne $state) {
        $markedInstalled = [bool]$state.python_installed_by_reposcout
        if (-not [string]::IsNullOrWhiteSpace($state.python_winget_package_id)) { $pythonPackageId = [string]$state.python_winget_package_id }
        if (-not [string]::IsNullOrWhiteSpace($state.python_direct_installer_version)) { $pythonVersion = ([string]$state.python_direct_installer_version).Substring(0,4) }
    }

    $pythonInstallMethod = ''
    if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace($state.python_install_method)) {
        $pythonInstallMethod = [string]$state.python_install_method
    }
    if ($pythonInstallMethod -eq 'python.org-local-installer') {
        Write-Host ''
        Write-Host 'Python 是 RepoWayfinder 安装到项目本地 .reposcout-python 的；本卸载器会优先调用官方 Python 卸载程序，而不是直接删除 Python 文件夹。'
        return
    }

    if (-not $markedInstalled) {
        Write-Host ''
        Write-Host '没有检测到“Python 是 RepoWayfinder 自动安装”的标记。'
        Write-Host '为避免误删你本来就在用的 Python，卸载器不会自动删除系统 Python。'
        Write-Host "如果你确定要手动删除，可在 Windows 设置 - 应用 中卸载 Python $pythonVersion，或运行：winget uninstall --id $pythonPackageId --scope user"
        return
    }

    if (-not $RemovePython) {
        Write-Host ''
        Write-Host "检测到 RepoWayfinder 可能自动安装过 Python $pythonVersion。"
        if (-not (Confirm-Action '是否同时卸载这个用户级 Python？如果其他项目也在用 Python，建议选 n。' $false)) {
            Write-Host '已保留系统 Python。'
            return
        }
    }

    if ($DryRun) { Write-Host "DRY RUN would uninstall RepoWayfinder-installed Python $pythonVersion"; return }

    $uninstalled = $false
    $entries = Get-PythonRegistryUninstallEntries $pythonVersion
    foreach ($entry in $entries) {
        if (Invoke-OfficialPythonUninstallEntry $entry "Python $pythonVersion") { $uninstalled = $true; break }
    }

    if (-not $uninstalled) {
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($null -ne $winget) {
            Write-Host "Official Python uninstaller was not found or failed; falling back to winget: $pythonPackageId"
            & $winget.Source uninstall --id $pythonPackageId --scope user | Out-Host
            if ($LASTEXITCODE -eq 0) { $uninstalled = $true }
        }
    }

    if ($uninstalled) {
        Write-Host "Python $pythonVersion 卸载命令已完成。"
    } else {
        Write-Host "未能自动卸载 Python $pythonVersion。请从 Windows 设置 - 应用 里手动卸载 Python。"
    }
}
try {
    Write-Host (Get-RepoWayfinderUiText 'RepoWayfinder 一键卸载器' 'RepoWayfinder uninstaller')
    Write-Host (Get-RepoWayfinderUiText "项目目录：$projectDir" "Project: $projectDir")
    Write-Host ''
    Write-Host (Get-RepoWayfinderUiText '它会逐项询问是否清理 RepoWayfinder 创建的环境、配置、报告、拥有所有权记录的目标项目和可选 Docker 镜像。' 'It asks explicitly before removing RepoWayfinder-created environments, config, reports, ownership-recorded targets, and optional Docker images.')
    Write-Host (Get-RepoWayfinderUiText '它不会删除 RepoWayfinder 源码或没有可信所有权记录的项目。' 'It does not delete RepoWayfinder source or targets without trusted ownership evidence.')
    Write-Host ''

    $state = Read-InstallState
    $prerequisiteState = Read-PrerequisiteState
    $localPythonCleanupComplete = -not (Test-Path -LiteralPath $repoScoutPythonDir)
    $uninstallIncomplete = $false

    if (Confirm-Action (Get-RepoWayfinderUiText '删除 RepoWayfinder 自己的 Python 虚拟环境 .reposcout-venv 和旧备份环境？' 'Remove RepoWayfinder Python venv and old venv backups?') $false) {
        Remove-ProjectPath $venvDir 'RepoWayfinder 虚拟环境'
        Get-ChildItem -LiteralPath $projectDir -Directory -Filter '.reposcout-venv.old-*' -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-ProjectPath $_.FullName 'RepoWayfinder 旧虚拟环境备份' }
    }

    if (Confirm-Action (Get-RepoWayfinderUiText '卸载 RepoWayfinder 本地 Python .reposcout-python（优先运行官方卸载程序）并删除旧备份？' 'Uninstall RepoWayfinder local Python through its official uninstaller and remove old backups?') $false) {
        $localPythonCleanupComplete = [bool](Uninstall-RepoWayfinderLocalPython $state)
        if (-not $localPythonCleanupComplete) { $uninstallIncomplete = $true }
        Get-ChildItem -LiteralPath $projectDir -Directory -Filter '.reposcout-python.old-*' -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-ProjectPath $_.FullName 'RepoWayfinder 本地 Python 旧备份' }
    }

    if (Confirm-Action (Get-RepoWayfinderUiText '删除 RepoWayfinder 本地 Git .reposcout-git 和旧备份？' 'Remove RepoWayfinder local Git and old backups?') $false) {
        Remove-ProjectPath $repoScoutGitDir 'RepoWayfinder 本地 Git'
        Get-ChildItem -LiteralPath $projectDir -Directory -Filter '.reposcout-git.old-*' -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-ProjectPath $_.FullName 'RepoWayfinder 本地 Git 旧备份' }
    }

    if (Confirm-Action (Get-RepoWayfinderUiText '删除 RepoWayfinder 项目本地 pnpm/yarn 工具 .reposcout-tools？' 'Remove RepoWayfinder project-local pnpm/yarn tools?') $false) {
        Remove-ProjectPath $repoScoutToolsDir 'RepoWayfinder 项目本地 Node 工具'
    }

    Remove-ProjectPath $settingsPath 'RepoWayfinder 部署模式设置'
    Remove-ProjectPath $settingsTempPath 'RepoWayfinder 部署模式临时设置'

    if (-not $KeepApiConfig) {
        Write-Host ''
        Write-Host (Get-RepoWayfinderUiText '本地 API 配置可能包含密钥。' 'Local API config may contain secrets.')
        if (Confirm-Action (Get-RepoWayfinderUiText '删除 .reposcout.env 和全部备份？' 'Remove .reposcout.env and all backups?') $false) {
            Remove-ProjectPath $localEnvPath 'RepoWayfinder 本地 API 配置'
            Get-ChildItem -LiteralPath $projectDir -File -Filter '.reposcout.env.backup-*' -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-ProjectPath $_.FullName 'RepoWayfinder API 配置备份' }
        }
    } else {
        Write-Host (Get-RepoWayfinderUiText '已按参数保留 .reposcout.env。' 'Kept .reposcout.env as requested.')
    }

    if (-not $KeepReports) {
        Write-Host ''
        Write-Host (Get-RepoWayfinderUiText 'reports 包含运行日志、教程和报告内 Demo 环境；目标项目位于 Projects，另行确认。' 'reports contains logs, guides, and report-local demo environments. Downloaded targets are under Projects and are confirmed separately.')
        if (Confirm-Action (Get-RepoWayfinderUiText '删除 reports 目录？' 'Remove the reports directory?') $false) {
            Remove-ProjectPath $reportsDir (Get-RepoWayfinderUiText 'RepoWayfinder 运行报告' 'RepoWayfinder reports')
        }
    } else {
        Write-Host (Get-RepoWayfinderUiText '已按参数保留 reports。' 'Kept reports as requested.')
    }

    Write-Host ''
    if (Confirm-Action (Get-RepoWayfinderUiText '删除 RepoWayfinder 所有权清单中记录的下载目标项目？没有记录的目录会保留。' 'Remove downloaded targets recorded in RepoWayfinder ownership manifest? Unrecorded directories are preserved.') $false) {
        Remove-RepoWayfinderOwnedTargets
    }

    Remove-RepoWayfinderDockerImages
    $prerequisiteCleanupComplete = [bool](Remove-RepoWayfinderInstalledPrerequisites $prerequisiteState)
    if (-not $prerequisiteCleanupComplete) { $uninstallIncomplete = $true }
    Remove-RepoWayfinderInstalledPython $state

    if ($localPythonCleanupComplete) {
        Remove-ProjectPath $installStatePath 'RepoWayfinder 安装标记'
    } else {
        Write-Host (Get-RepoWayfinderUiText 'RepoWayfinder 本地 Python 尚未清理完成；已保留安装标记，修复占用或安装器问题后可再次运行卸载器。' 'RepoWayfinder local Python cleanup is incomplete. Its install marker was preserved so uninstall can be retried after resolving the installer or file lock.')
    }

    if ($uninstallIncomplete) {
        Show-RepoWayfinderMessage (Get-RepoWayfinderUiText "RepoWayfinder 卸载未完全完成。`n`n至少一个明确请求的 Python/Docker/Node 卸载失败；对应安装标记已保留。`n请按上方提示修复占用、winget 或安装器问题后重新运行卸载器。" "RepoWayfinder uninstall is incomplete.`n`nAt least one explicitly requested Python/Docker/Node uninstall failed. Its ownership marker was preserved.`nResolve the installer, winget, or file-lock issue shown above and retry.") (Get-RepoWayfinderUiText 'RepoWayfinder 卸载未完成' 'RepoWayfinder uninstall incomplete')
        exit 1
    }

    Write-Host ''
    if ($DryRun) {
        Show-RepoWayfinderMessage (Get-RepoWayfinderUiText "RepoWayfinder DryRun 完成。`n`n这次只是模拟卸载，没有删除任何文件。`n真正卸载请双击 点我卸载RepoWayfinder.bat，或去掉 -DryRun 参数。" "RepoWayfinder DryRun completed.`n`nNo files were removed. To uninstall, run the uninstall BAT or remove -DryRun.") (Get-RepoWayfinderUiText 'RepoWayfinder DryRun 完成' 'RepoWayfinder DryRun completed')
    } else {
        Show-RepoWayfinderMessage (Get-RepoWayfinderUiText "RepoWayfinder 本地卸载完成。`n`n已按你的选择清理项目内运行环境、配置、报告和有所有权记录的目标。`n如需删除源码，请手动删除整个文件夹：`n$projectDir" "RepoWayfinder local uninstall completed.`n`nSelected runtime, config, report, and ownership-recorded target data was cleaned.`nTo remove the source, manually delete this folder:`n$projectDir") (Get-RepoWayfinderUiText 'RepoWayfinder 卸载完成' 'RepoWayfinder uninstall completed')
    }
    exit 0
} catch {
    $message = Get-RepoWayfinderUiText "RepoWayfinder 卸载失败:`n$($_.Exception.Message)`n`n为避免误删，卸载器已停止。请把这段错误发给开发者。" "RepoWayfinder uninstall failed:`n$($_.Exception.Message)`n`nThe uninstaller stopped to avoid unsafe deletion. Share this error with the developer."
    try { Show-RepoWayfinderMessage $message (Get-RepoWayfinderUiText 'RepoWayfinder 卸载失败' 'RepoWayfinder uninstall failed') } catch { Write-Host $message }
    exit 1
} finally {
    Pause-IfNeeded
}





