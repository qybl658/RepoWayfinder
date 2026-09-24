# Helpers for reading Windows 10 wsl.exe output without mojibake.

function Invoke-RepoWayfinderWslCommand([string[]]$Arguments) {
    $wslPath = $null
    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($null -ne $wsl) { $wslPath = $wsl.Source }
    if ([string]::IsNullOrWhiteSpace($wslPath) -and -not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        foreach ($candidate in @(
            (Join-Path $env:SystemRoot 'Sysnative\wsl.exe'),
            (Join-Path $env:SystemRoot 'System32\wsl.exe')
        )) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $wslPath = $candidate; break }
        }
    }
    if ([string]::IsNullOrWhiteSpace($wslPath)) {
        return [pscustomobject]@{ Available=$false; ExitCode=-1; Text='wsl.exe is not available.' }
    }
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $wslPath
    $startInfo.Arguments = ($Arguments -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    try {
        $startInfo.StandardOutputEncoding = [Text.Encoding]::Unicode
        $startInfo.StandardErrorEncoding = [Text.Encoding]::Unicode
    } catch {}
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Could not start wsl.exe.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timeout = if ($Arguments -contains '--install' -or $Arguments -contains '--update') { 900000 } else { 30000 }
        if (-not $process.WaitForExit($timeout)) {
            try { $process.Kill() } catch {}
            return [pscustomobject]@{ Available=$true; ExitCode=-2; Text='The WSL command timed out; its result is unknown.' }
        }
        $text = (($stdout.Result + [Environment]::NewLine + $stderr.Result) -replace "`0", '').Trim()
        return [pscustomobject]@{ Available=$true; ExitCode=$process.ExitCode; Text=$text }
    } finally { $process.Dispose() }
}

function Get-RepoWayfinderWslServiceState([string[]]$Names) {
    $queryFailed = $false
    foreach ($name in $Names) {
        try {
            $service = Get-Service -Name $name -ErrorAction Stop
            if ($null -eq $service) { continue }
            if ($service.PSObject.Properties.Name -contains 'StartType' -and [string]$service.StartType -eq 'Disabled') { return 'disabled' }
            if ([string]$service.Status -eq 'Running') { return 'running' }
            if ([string]$service.Status -eq 'Stopped') { return 'stopped' }
            return 'unknown'
        } catch {
            if ($_.CategoryInfo.Category -ne [Management.Automation.ErrorCategory]::ObjectNotFound -and $_.FullyQualifiedErrorId -notmatch 'NoServiceFoundForGivenName') { $queryFailed = $true }
        }
    }
    if ($queryFailed) { return 'unknown' }
    return 'missing'
}

function Get-RepoWayfinderWslPackageState($VersionResult) {
    if ($null -ne $VersionResult -and $VersionResult.Available -and $VersionResult.ExitCode -eq 0 -and $VersionResult.Text -match '(?im)^\s*WSL\s+(?:version|版本)\s*[:：]\s*\d+\.\d+') { return 'installed' }
    $service = Get-RepoWayfinderWslServiceState @('WslService')
    if ($service -in @('running','stopped','disabled')) { return 'installed' }
    try {
        $packages = @(Get-AppxPackage -Name 'MicrosoftCorporationII.WindowsSubsystemForLinux' -ErrorAction Stop)
        if ($packages.Count -gt 0) { return 'installed' }
        if ($service -eq 'missing') { return 'missing' }
    } catch {}
    return 'unknown'
}

function Test-RepoWayfinderWslKernelMissing([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $normalized = ($Text -replace "`0", '').Trim()
    if ($normalized -match '(?i)wsl(?:\.exe)?\s+--update') { return $true }
    if ($normalized -match '(?i)(kernel|内核).*(missing|not found|缺失|找不到).*(update|更新)') { return $true }
    return $false
}

function Test-RepoWayfinderWslUpdateRequired([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $normalized = ($Text -replace "`0", '').Trim()
    if ($normalized -match '(?is)wsl(?:\.exe)?\s+--update|wsl\s+(?:needs|requires)\s+(?:an?\s+)?update|wsl.{0,60}(?:too old|out of date|过旧|需要更新)') { return $true }
    if ($normalized -match '(?im)^\s*WSL\s+(?:version|版本)\s*[:：]\s*(\d+)\.(\d+)\.(\d+)') {
        $installed = [version]("$($Matches[1]).$($Matches[2]).$($Matches[3])")
        return $installed -lt [version]'2.1.5'
    }
    return $false
}

function Test-RepoWayfinderWslInstallRequired([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $normalized = ($Text -replace "`0", '').Trim()
    # Do not treat every mention of --install as a missing WSL package. Windows also
    # prints that command when only virtualization or VirtualMachinePlatform is off.
    if ($normalized -notmatch '(?i)wsl(?:\.exe)?\s+--install') { return $false }
    if (Test-RepoWayfinderWslPlatformInactive $normalized) { return $false }
    if (Test-RepoWayfinderWslKernelMissing $normalized) { return $false }
    if ($normalized -match '(?is)(?:wsl|windows subsystem for linux|适用于\s*linux\s*的\s*windows\s*子系统).{0,100}(?:is not installed|isn''t installed|not installed|未安装|没有安装)') { return $true }
    if ($normalized -match '(?is)(?:is not installed|isn''t installed|not installed|未安装|尚未安装|没有安装).{0,40}(?:wsl|windows subsystem for linux|适用于\s*linux\s*的\s*windows\s*子系统)') { return $true }
    # Windows wording varies by build. A status result that explicitly says a
    # component is not installed and points to the WSL installer is sufficient once
    # platform-only and kernel-only diagnostics have been excluded above.
    if ($normalized -match '(?is)(?:is not installed|isn''t installed|not installed|未安装|尚未安装|没有安装)') { return $true }
    return $false
}

function Test-RepoWayfinderWslPlatformInactive([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $normalized = ($Text -replace "`0", '').Trim()
    return $normalized -match '(?is)(?:wsl\s*2|wsl2).{0,120}(?:无法启动|不支持|not supported)|hcs_e_hyperv_not_installed|enablevirtualization|(?:virtual machine platform|虚拟机平台).{0,120}(?:not enabled|未启用)'
}

function Get-RepoWayfinderFirmwareAssessment([object]$VirtualizationFirmwareEnabled, [object]$HypervisorPresent) {
    if ($VirtualizationFirmwareEnabled -ne $false) { return $null }
    if ($HypervisorPresent -eq $true) {
        return [pscustomobject]@{
            Status = 'satisfied'
            Detail = 'VirtualizationFirmwareEnabled=false, but HypervisorPresent=True confirms the Windows hypervisor is active. No BIOS/UEFI action is requested.'
        }
    }
    return [pscustomobject]@{
        Status = 'user_boundary'
        Detail = "Windows read-only processor signals report VirtualizationFirmwareEnabled=false; HypervisorPresent=$HypervisorPresent. RepoWayfinder cannot safely change BIOS/UEFI. Inspect firmware virtualization settings and restart before retrying."
    }
}
