# Process-local command path for RepoWayfinder packages.
# Matches Refresh-ProcessPath in install_reposcout.ps1, and also prepends Windows
# command directories plus tools shipped in this folder.
# Does not write User or Machine environment variables and does not create startup entries.

param(
    [switch]$Quiet
)

function Update-RepoWayfinderCommandPath {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [switch]$Quiet
    )

    $systemRoot = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($systemRoot)) { $systemRoot = 'C:\Windows' }

    $chunks = @(
        $env:Path,
        [Environment]::GetEnvironmentVariable('Path', 'User'),
        [Environment]::GetEnvironmentVariable('Path', 'Machine'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
    )
    $preferred = @(
        (Join-Path $BundleRoot 'runtime\python'),
        (Join-Path $BundleRoot 'scenario-kit\runtime'),
        (Join-Path $BundleRoot '.reposcout-venv\Scripts'),
        (Join-Path $BundleRoot '.reposcout-python'),
        (Join-Path $BundleRoot '.reposcout-git\cmd'),
        (Join-Path $BundleRoot '.reposcout-git\usr\bin'),
        (Join-Path $systemRoot 'System32\WindowsPowerShell\v1.0'),
        (Join-Path $systemRoot 'System32'),
        $systemRoot,
        (Join-Path $systemRoot 'System32\Wbem')
    )

    $ordered = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    function Add-CommandDir([string]$dir, [bool]$mustExist) {
        if ([string]::IsNullOrWhiteSpace($dir)) { return }
        $expanded = [Environment]::ExpandEnvironmentVariables($dir.Trim().Trim('"'))
        if ([string]::IsNullOrWhiteSpace($expanded)) { return }
        if ($mustExist) {
            $exists = $false
            try { $exists = Test-Path -LiteralPath $expanded -PathType Container } catch { $exists = $false }
            if (-not $exists) { return }
        }
        if ($seen.Add($expanded)) { [void]$ordered.Add($expanded) }
    }

    foreach ($dir in $preferred) { Add-CommandDir $dir $true }
    foreach ($chunk in $chunks) {
        if ([string]::IsNullOrWhiteSpace($chunk)) { continue }
        foreach ($dir in ($chunk -split ';')) { Add-CommandDir $dir $false }
    }

    if ($ordered.Count -lt 1) { throw '没有可用的命令路径。' }
    $env:Path = ($ordered -join ';')
    try {
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [Console]::OutputEncoding = $utf8
        $OutputEncoding = $utf8
    } catch {}

    if (-not $Quiet) {
        Write-Host '命令路径已准备好。'
        Write-Host '这一步只补当前这次启动能用的命令路径，不改系统设置，也不写启动项。'
        Write-Host '简单来说：就算这台电脑没配好 Path，后面的脚本也能找到 PowerShell 和本包自带的程序。'
        $next = ''
        foreach ($name in @('点我开始使用.bat', '点我启动DSH.bat', '点我启动RepoWayfinder.bat')) {
            if (Test-Path -LiteralPath (Join-Path $BundleRoot $name) -PathType Leaf) { $next = $name; break }
        }
        if ($next) { Write-Host "接下来双击 $next" }
        else { Write-Host '接下来按文件名前面的数字，从 2 开始依次双击。' }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $bundleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    Update-RepoWayfinderCommandPath -BundleRoot $bundleRoot -Quiet:$Quiet
}
