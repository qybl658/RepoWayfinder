param(
    [Parameter(Mandatory=$true)][string]$ReportPath,
    [switch]$ConfigureDockerWindows,
    [switch]$UpdateWslKernel,
    [switch]$InstallWslComponents,
    [switch]$InspectWindowsFeatures,
    [string]$InspectionNonce = '',
    [string]$SetupLogPath = ''
)

# RepoWayfinder report-specific continuation helper.
# It prepares trusted Windows prerequisites when possible, then resumes the saved plan in the same report.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$reportsRoot = [IO.Path]::GetFullPath((Join-Path $projectDir 'reports')).TrimEnd('\')
$resolvedReport = [IO.Path]::GetFullPath($ReportPath)
if (-not $resolvedReport.StartsWith($reportsRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Resume report must stay under RepoWayfinder reports: $resolvedReport"
}
if (-not (Test-Path -LiteralPath $resolvedReport -PathType Leaf)) { throw "Deployment report not found: $resolvedReport" }
$uiHelper = Join-Path $projectDir 'reposcout_ui.ps1'
if (-not (Test-Path -LiteralPath $uiHelper -PathType Leaf)) { throw "RepoWayfinder UI helper not found: $uiHelper" }
. $uiHelper
try {
    $savedReport = Get-Content -LiteralPath $resolvedReport -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$savedReport.ui_language -in @('zh-CN', 'en')) { $env:REPOSCOUT_UI_LANGUAGE = [string]$savedReport.ui_language }
} catch {}
[void](Initialize-RepoWayfinderUiLanguage $projectDir)
. (Join-Path $projectDir 'run_log_utils.ps1')
$reportDir = Split-Path -Parent $resolvedReport
$dockerSetupMarker = Join-Path $reportDir 'docker_windows_setup.completed'
$prerequisiteStatePath = Join-Path $projectDir '.reposcout-prerequisites.json'
$featureSnapshotPath = Join-Path $reportDir 'windows_feature_snapshot.json'
$resolvedSetupLog = ''
if (-not [string]::IsNullOrWhiteSpace($SetupLogPath)) {
    $resolvedSetupLog = [IO.Path]::GetFullPath($SetupLogPath)
    if ((Split-Path -Parent $resolvedSetupLog) -ne $reportDir -or (Split-Path -Leaf $resolvedSetupLog) -ne 'docker_windows_setup.log') {
        throw "Docker setup log must be the report-local docker_windows_setup.log: $resolvedSetupLog"
    }
} elseif ($ConfigureDockerWindows -or $InstallWslComponents -or $UpdateWslKernel) {
    $resolvedSetupLog = Join-Path $reportDir 'docker_windows_setup.log'
}
$wslTools = Join-Path $projectDir 'wsl_status_utils.ps1'
if (-not (Test-Path -LiteralPath $wslTools -PathType Leaf)) { throw "WSL status helper not found: $wslTools" }
. $wslTools
$script:RepoWayfinderPrerequisiteEvents = New-Object 'System.Collections.Generic.List[object]'
$offerImmediateRestart = $false

function Add-RepoWayfinderPrerequisiteEvent([string]$action, [string]$status, [string]$detail) {
    $script:RepoWayfinderPrerequisiteEvents.Add([pscustomobject][ordered]@{
        kind = 'system_prerequisite_event'
        name = 'docker'
        action = $action
        status = $status
        detail = $detail
        recorded_at = (Get-Date).ToUniversalTime().ToString('o')
    }) | Out-Null
}

function Publish-RepoWayfinderPrerequisiteEvents {
    if ($script:RepoWayfinderPrerequisiteEvents.Count -gt 0) {
        $events = [object[]]$script:RepoWayfinderPrerequisiteEvents.ToArray()
        $env:REPOSCOUT_PREREQUISITE_EVENTS_JSON = ConvertTo-Json -InputObject $events -Compress -Depth 5
    }
}

function Get-RepoWayfinderWindowsFeatureState([string]$name) {
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction Stop
        if ($null -ne $feature) {
            $state = ([string]$feature.State).Trim().ToLowerInvariant()
            if ($state -in @('enabled','disabled','enablepending','disablepending')) { return $state }
        }
    } catch {}
    # CIM InstallState cannot distinguish Enabled from EnablePending.
    return 'unknown'
}

function Resolve-RepoWayfinderFeatureAction([string]$VmState, [string]$WslState, [bool]$LegacyWslFeatureRequired = $false) {
    $states = @($VmState.ToLowerInvariant())
    if ($LegacyWslFeatureRequired) { $states += $WslState.ToLowerInvariant() }
    if (@($states | Where-Object { $_ -in @('enablepending','disablepending') }).Count) { return 'restart_required' }
    if (@($states | Where-Object { $_ -notin @('enabled','disabled') }).Count) { return 'query_required' }
    if ($states -contains 'disabled') { return 'enable_required' }
    return 'already_enabled'
}

function Get-RepoWayfinderBootId {
    try {
        $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        if ($null -ne $boot) { return ([datetime]$boot).ToUniversalTime().ToString('o') }
    } catch {}
    return ''
}

function Get-RepoWayfinderWindowsSetupState {
    if (-not (Test-Path -LiteralPath $prerequisiteStatePath -PathType Leaf)) { return $null }
    try {
        $state = Get-Content -LiteralPath $prerequisiteStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        return $state.windows_setup
    } catch { return $null }
}

function Set-RepoWayfinderWindowsSetupState([string]$status, [string[]]$features, [string]$detail) {
    $state = [ordered]@{version=1;project_dir=$projectDir;items=@()}
    if (Test-Path -LiteralPath $prerequisiteStatePath -PathType Leaf) {
        try {
            $loaded = Get-Content -LiteralPath $prerequisiteStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($property in $loaded.PSObject.Properties) { $state[$property.Name] = $property.Value }
        } catch {}
    }
    $state['version'] = 1
    $state['project_dir'] = $projectDir
    $state['updated_at'] = (Get-Date).ToUniversalTime().ToString('o')
    $state['windows_setup'] = [ordered]@{
        status = $status
        boot_id = Get-RepoWayfinderBootId
        features = @($features)
        detail = $detail
        report_path = $resolvedReport
        setup_log_path = $resolvedSetupLog
        recorded_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    $temporary = $prerequisiteStatePath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $prerequisiteStatePath -Force
    } catch {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        $stateError = "Could not persist Windows setup state: $($_.Exception.Message)"
        Write-Host $stateError
        if (-not [string]::IsNullOrWhiteSpace($resolvedSetupLog)) { Add-Content -LiteralPath $resolvedSetupLog -Value $stateError -Encoding UTF8 }
    }
}

function Invoke-DismFeature([string]$name) {
    Write-Host "Enabling Windows optional feature: $name"
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& dism.exe /online /enable-feature "/featurename:$name" /all /norestart 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
    }
    $output | Out-Host
    if (-not [string]::IsNullOrWhiteSpace($resolvedSetupLog)) {
        Add-Content -LiteralPath $resolvedSetupLog -Value "`r`n=== $name ===" -Encoding UTF8
        if ($output.Count -gt 0) { Add-Content -LiteralPath $resolvedSetupLog -Value ($output | Out-String) -Encoding UTF8 }
        Add-Content -LiteralPath $resolvedSetupLog -Value "Exit code: $code" -Encoding UTF8
    }
    if ($code -notin @(0, 3010)) { throw "DISM failed for $name with exit code $code" }
    return $code
}

if ($InspectWindowsFeatures) {
    if ($InspectionNonce -notmatch '^[0-9a-f]{32}$') { throw 'A fresh feature inspection request is required.' }
    [ordered]@{
        request_id = $InspectionNonce
        report_path = $resolvedReport
        boot_id = Get-RepoWayfinderBootId
        feature_state = Get-RepoWayfinderWindowsFeatureState 'VirtualMachinePlatform'
        wsl_feature_state = Get-RepoWayfinderWindowsFeatureState 'Microsoft-Windows-Subsystem-Linux'
        recorded_at = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $featureSnapshotPath -Encoding UTF8
    exit 0
}

if ($UpdateWslKernel) {
    if (-not [string]::IsNullOrWhiteSpace($resolvedSetupLog)) {
        Set-Content -LiteralPath $resolvedSetupLog -Value "RepoWayfinder elevated WSL update`r`nStarted: $((Get-Date).ToString('o'))`r`nCommand: wsl.exe --update" -Encoding UTF8
    }
    Write-Host 'Running the official WSL update command after explicit user confirmation...'
    $update = Invoke-RepoWayfinderWslCommand @('--update')
    if ($update.Text) {
        Write-Host $update.Text
        if (-not [string]::IsNullOrWhiteSpace($resolvedSetupLog)) { Add-Content -LiteralPath $resolvedSetupLog -Value $update.Text -Encoding UTF8 }
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedSetupLog)) { Add-Content -LiteralPath $resolvedSetupLog -Value "Exit code: $($update.ExitCode)" -Encoding UTF8 }
    if (-not $update.Available -or $update.ExitCode -ne 0) { exit 21 }
    exit 0
}

if ($ConfigureDockerWindows) {
    if (-not [string]::IsNullOrWhiteSpace($resolvedSetupLog)) {
        Set-Content -LiteralPath $resolvedSetupLog -Value "RepoWayfinder elevated Docker Windows setup`r`nStarted: $((Get-Date).ToString('o'))" -Encoding UTF8
    }
    $changedFeatures = @()
    try {
        $state = Get-RepoWayfinderWindowsFeatureState 'VirtualMachinePlatform'
        $action = Resolve-RepoWayfinderFeatureAction $state 'unknown' $false
        if ($action -eq 'restart_required') {
            Set-RepoWayfinderWindowsSetupState 'restart_required' @('VirtualMachinePlatform') 'A Windows feature change is pending; no DISM enable command was run.'
            exit 20
        }
        if ($action -eq 'query_required') {
            Set-RepoWayfinderWindowsSetupState 'query_required' @() 'The elevated Windows feature query was unavailable; no feature was changed.'
            exit 22
        }
        if ($action -eq 'enable_required') {
            $changedFeatures = @('VirtualMachinePlatform')
            $code = Invoke-DismFeature 'VirtualMachinePlatform'
            $state = Get-RepoWayfinderWindowsFeatureState 'VirtualMachinePlatform'
            if ($code -eq 3010 -or $state -in @('enablepending','disablepending')) {
                Set-RepoWayfinderWindowsSetupState 'restart_required' $changedFeatures 'Windows requires a restart before the feature change takes effect.'
                exit 20
            }
            if ($state -ne 'enabled') {
                Set-RepoWayfinderWindowsSetupState 'failed' $changedFeatures 'DISM finished, but the required feature was not verified as enabled.'
                exit 22
            }
        }
    } catch {
        $setupError = $_.Exception.Message
        if (-not [string]::IsNullOrWhiteSpace($resolvedSetupLog)) { Add-Content -LiteralPath $resolvedSetupLog -Value "`r`nERROR: $setupError" -Encoding UTF8 }
        try { Set-RepoWayfinderWindowsSetupState -status 'failed' -features $changedFeatures -detail $setupError } catch {
            if (-not [string]::IsNullOrWhiteSpace($resolvedSetupLog)) { Add-Content -LiteralPath $resolvedSetupLog -Value "State persistence error: $($_.Exception.Message)" -Encoding UTF8 }
        }
        throw $setupError
    }
    Set-Content -LiteralPath $dockerSetupMarker -Value ((Get-Date).ToString('s')) -Encoding UTF8
    Set-RepoWayfinderWindowsSetupState -status 'already_enabled' -features $changedFeatures -detail 'VirtualMachinePlatform was verified as enabled; the legacy WSL1 feature was not changed.'
    exit 0
}

if ($InstallWslComponents) {
    $installFeatureState = Get-RepoWayfinderWindowsFeatureState 'VirtualMachinePlatform'
    if ($installFeatureState -in @('enablepending','disablepending')) { exit 20 }
    if ($installFeatureState -eq 'unknown') { exit 22 }
    $installVersion = Invoke-RepoWayfinderWslCommand @('--version')
    if ((Get-RepoWayfinderWslPackageState $installVersion) -ne 'missing') { exit 22 }
    Set-Content -LiteralPath $resolvedSetupLog -Value "RepoWayfinder elevated WSL component installation`r`nStarted: $((Get-Date).ToString('o'))`r`nCommand: wsl.exe --install --no-distribution" -Encoding UTF8
    Write-Host 'Running the official WSL component installer without installing a Linux distribution...'
    $installed = Invoke-RepoWayfinderWslCommand @('--install', '--no-distribution')
    if ($installed.Text) {
        Write-Host $installed.Text
        Add-Content -LiteralPath $resolvedSetupLog -Value $installed.Text -Encoding UTF8
    }
    Add-Content -LiteralPath $resolvedSetupLog -Value "Exit code: $($installed.ExitCode)" -Encoding UTF8
    if (-not $installed.Available -or $installed.ExitCode -notin @(0,3010)) {
        Set-RepoWayfinderWindowsSetupState -status 'failed' -features @('wsl_components') -detail "wsl --install --no-distribution failed with exit code $($installed.ExitCode)."
        exit 22
    }
    $afterFeature = Get-RepoWayfinderWindowsFeatureState 'VirtualMachinePlatform'
    if ($installed.ExitCode -eq 3010 -or $afterFeature -in @('enablepending','disablepending')) {
        Set-RepoWayfinderWindowsSetupState 'restart_required' @('wsl_components') 'The WSL installer or fresh feature state requires a Windows restart.'
        exit 20
    }
    $afterInstall = Invoke-RepoWayfinderWslCommand @('--status')
    $afterVersion = Invoke-RepoWayfinderWslCommand @('--version')
    if ($afterFeature -ne 'enabled' -or (Get-RepoWayfinderWslPackageState $afterVersion) -ne 'installed' -or (-not $afterInstall.Available) -or $afterInstall.ExitCode -ne 0 -or (Test-RepoWayfinderWslInstallRequired $afterInstall.Text) -or (Test-RepoWayfinderWslUpdateRequired $afterInstall.Text) -or (Test-RepoWayfinderWslPlatformInactive $afterInstall.Text)) {
        Set-RepoWayfinderWindowsSetupState -status 'failed' -features @('wsl_components') -detail 'The WSL installer completed, but WSL readiness was not verified. Inspect its report-local log before retrying.'
        exit 22
    }
    Set-RepoWayfinderWindowsSetupState -status 'components_installed' -features @('wsl_components') -detail 'The official WSL component installer completed without installing a Linux distribution.'
    exit 0
}

$data = Get-Content -LiteralPath $resolvedReport -Raw -Encoding UTF8 | ConvertFrom-Json
$blocked = @($data.prerequisites | Where-Object { $_.status_after -ne 'ready' } | ForEach-Object { [string]$_.name })
$previouslyDeclined = @($data.prerequisites | Where-Object { $_.status_after -ne 'ready' -and $_.user_choice -eq 'declined' }).Count -gt 0
if (($blocked -contains 'docker') -and (-not $previouslyDeclined)) {
    Write-Host ''
    Write-Host '这个项目在等待 Docker 环境；项目命令尚未执行，因此当前不算项目失败。'
    $virtualization = $null
    try {
        $processors = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
        if ($processors.Count -gt 0) {
            $firmwareDisabled = @($processors | Where-Object { -not [bool]$_.VirtualizationFirmwareEnabled }).Count
            $virtualization = ($firmwareDisabled -eq 0)
        }
    } catch {}
    if ($virtualization -eq $false) {
        $hypervisorPresent = $null
        try { $hypervisorPresent = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent } catch {}
        $firmwareAssessment = Get-RepoWayfinderFirmwareAssessment $virtualization $hypervisorPresent
        $firmwareDetail = [string]$firmwareAssessment.Detail
        if ($firmwareAssessment.Status -eq 'satisfied') {
            Add-RepoWayfinderPrerequisiteEvent -action 'firmware_virtualization_check' -status $firmwareAssessment.Status -detail $firmwareDetail
            Write-Host 'Windows hypervisor is already active; ignoring the contradictory processor firmware flag and not requesting BIOS/UEFI changes.'
        } else {
            $env:REPOSCOUT_DOCKER_CONTEXT_DETAIL = $firmwareDetail
            Add-RepoWayfinderPrerequisiteEvent -action 'firmware_virtualization_check' -status $firmwareAssessment.Status -detail $firmwareDetail
            Write-Host '检测到固件虚拟化可能未启用。RepoWayfinder 无法安全修改 BIOS/UEFI。'
            Write-Host '请重启进入 BIOS/UEFI，启用 Intel VT-x/VT-d 或 AMD-V/SVM，然后回到这里再次双击继续 BAT。'
        }
    }
    $skipDockerPreparation = $false
    $initialWslStatus = Invoke-RepoWayfinderWslCommand @('--status')
    $initialWslVersion = Invoke-RepoWayfinderWslCommand @('--version')
    $initialWslEvidence = (([string]$initialWslStatus.Text) + [Environment]::NewLine + ([string]$initialWslVersion.Text)).Trim()
    $wslPackageState = Get-RepoWayfinderWslPackageState $initialWslVersion
    $wslInstallRequired = $initialWslStatus.Available -and (Test-RepoWayfinderWslInstallRequired $initialWslStatus.Text) -and $wslPackageState -eq 'missing'
    $wslUpdateRequired = $initialWslStatus.Available -and (Test-RepoWayfinderWslUpdateRequired $initialWslEvidence)
    $vmPlatformState = Get-RepoWayfinderWindowsFeatureState 'VirtualMachinePlatform'
    $currentBootId = Get-RepoWayfinderBootId
    $priorWindowsSetup = Get-RepoWayfinderWindowsSetupState
    $sameBootSetup = $null -ne $priorWindowsSetup -and -not [string]::IsNullOrWhiteSpace($currentBootId) -and [string]$priorWindowsSetup.boot_id -eq $currentBootId
    $pendingWindowsRestart = $sameBootSetup -and [string]$priorWindowsSetup.status -eq 'restart_required'
    $failedWindowsSetup = $sameBootSetup -and [string]$priorWindowsSetup.status -eq 'failed'
    $allowWindowsFeatures = $false
    $featureAction = Resolve-RepoWayfinderFeatureAction $vmPlatformState 'unknown' $false
    if ($featureAction -eq 'query_required' -and -not $pendingWindowsRestart) {
        Write-Host '暂时无法准确读取 Windows 功能状态。管理员检查只读取状态，不会安装或启用功能。'
        if (Read-RepoWayfinderExplicitYesNo '是否允许管理员只读检查？' 'Allow an administrator read-only Windows feature check?') {
            $nonce = [guid]::NewGuid().ToString('N')
            try {
                $inspectionArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),'-ReportPath',('"'+$resolvedReport+'"'),'-InspectWindowsFeatures','-InspectionNonce',$nonce)
                $inspection = Start-Process -FilePath powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $inspectionArgs -Wait -PassThru
                if ($inspection.ExitCode -eq 0 -and (Test-Path -LiteralPath $featureSnapshotPath -PathType Leaf)) {
                    $snapshot = Get-Content -LiteralPath $featureSnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ([string]$snapshot.request_id -eq $nonce -and [string]$snapshot.report_path -eq $resolvedReport) {
                        $vmPlatformState = [string]$snapshot.feature_state
                        $featureAction = Resolve-RepoWayfinderFeatureAction $vmPlatformState 'unknown' $false
                        Add-RepoWayfinderPrerequisiteEvent 'windows_feature_inspection' 'succeeded' ('Read-only feature state: '+$vmPlatformState)
                    }
                }
            } catch { Add-RepoWayfinderPrerequisiteEvent 'windows_feature_inspection' 'not_completed' 'The administrator read-only check did not complete; no Windows feature was changed.' }
        }
    }
    $vmPlatformReady = $featureAction -eq 'already_enabled'
    if ($pendingWindowsRestart -or $featureAction -eq 'restart_required') {
        $env:REPOSCOUT_DOCKER_WAIT_DETAIL = 'Windows 功能修改正在等待重启。请保存其他工作，重启后再继续；本次不会重复启用功能。'
        Write-Host $env:REPOSCOUT_DOCKER_WAIT_DETAIL
        Add-RepoWayfinderPrerequisiteEvent 'windows_optional_features' 'restart_required' $env:REPOSCOUT_DOCKER_WAIT_DETAIL
        $env:REPOSCOUT_SKIP_DOCKER_START = '1'
        $skipDockerPreparation = $true
        $offerImmediateRestart = $true
    } elseif ($featureAction -eq 'query_required') {
        $env:REPOSCOUT_DOCKER_WAIT_DETAIL = 'Windows 功能状态仍未确认；未修改或启动 Docker。请允许管理员只读检查，或在管理员 PowerShell 中检查 VirtualMachinePlatform 后再继续。'
        Write-Host $env:REPOSCOUT_DOCKER_WAIT_DETAIL
        Add-RepoWayfinderPrerequisiteEvent 'windows_optional_features' 'query_required' $env:REPOSCOUT_DOCKER_WAIT_DETAIL
        $env:REPOSCOUT_SKIP_DOCKER_START = '1'
        $skipDockerPreparation = $true
    } elseif ($wslInstallRequired) {
        Write-Host '已确认缺少 WSL 组件；下方可选择官方安装，它也会处理所需的虚拟机平台功能。'
        Add-RepoWayfinderPrerequisiteEvent 'windows_optional_features' 'delegated_to_wsl_installer' 'Package and service checks confirm the modern WSL package is absent; the official installer manages its prerequisites.'
    } elseif ($vmPlatformReady) {
        Write-Host 'Virtual Machine Platform 已启用；现代 WSL2 不需要启用旧 WSL1 功能。'
        Add-RepoWayfinderPrerequisiteEvent 'windows_optional_features' 'already_enabled' 'VirtualMachinePlatform is enabled; the legacy WSL1 optional feature is not required for modern WSL2.'
    } elseif ($failedWindowsSetup) {
        Write-Host '本次开机期间的 Windows 功能配置已失败，请先查看报告里的管理员日志。'
        $allowWindowsFeatures = Read-RepoWayfinderExplicitYesNo '是否明确重试一次管理员配置？' 'Explicitly retry the elevated Windows feature setup once?'
    } else {
        $allowWindowsFeatures = Read-RepoWayfinderExplicitYesNo '是否让 RepoWayfinder 以管理员权限启用 Virtual Machine Platform？' 'Allow RepoWayfinder to enable Virtual Machine Platform with administrator permission?'
    }
    if ($allowWindowsFeatures) {
            $setupLog = Join-Path $reportDir 'docker_windows_setup.log'
            try {
                $arguments = @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', ('"' + $PSCommandPath + '"'),
                    '-ReportPath', ('"' + $resolvedReport + '"'),
                    '-ConfigureDockerWindows',
                    '-SetupLogPath', ('"' + $setupLog + '"')
                )
                $elevated = Start-Process -FilePath powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -Wait -PassThru
                if ($elevated.ExitCode -eq 20) {
                    Write-Host ''
                    Write-Host 'Windows 功能已启用，但需要重启。重启后再次双击本报告目录里的继续部署 BAT；不会重新克隆或重新分析。'
                    $env:REPOSCOUT_DOCKER_WAIT_DETAIL = 'Virtual Machine Platform 的修改需要重启后生效。重启后再次双击本报告目录里的继续部署 BAT。'
                    Add-RepoWayfinderPrerequisiteEvent -action 'windows_optional_features' -status 'restart_required' -detail $env:REPOSCOUT_DOCKER_WAIT_DETAIL
                    $env:REPOSCOUT_SKIP_DOCKER_START = '1'
                    $skipDockerPreparation = $true
                    $offerImmediateRestart = $true
                } elseif ($elevated.ExitCode -ne 0) {
                    throw "Elevated Windows setup exited with code $($elevated.ExitCode)"
                } else {
                    Add-RepoWayfinderPrerequisiteEvent -action 'windows_optional_features' -status 'enabled' -detail 'VirtualMachinePlatform was enabled through the official DISM command.'
                }
            } catch {
                $setupTail = ''
                if (Test-Path -LiteralPath $setupLog -PathType Leaf) {
                    Write-Host "管理员配置详细日志：$setupLog"
                    $tailLines = @(Get-Content -LiteralPath $setupLog -Encoding UTF8 -Tail 16)
                    $tailLines | Out-Host
                    $setupTail = (($tailLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' | ')
                    if ($setupTail.Length -gt 1200) { $setupTail = $setupTail.Substring($setupTail.Length - 1200) }
                }
                Write-Host "Windows 功能自动配置没有完成：$($_.Exception.Message)"
                Write-Host '可手动用管理员 PowerShell 分别运行：'
                Write-Host '  dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart'
                Write-Host '然后重启 Windows，再双击继续部署 BAT。'
                $env:REPOSCOUT_DOCKER_WAIT_DETAIL = "Windows 功能自动配置没有完成：$($_.Exception.Message)。"
                if (-not [string]::IsNullOrWhiteSpace($setupTail)) { $env:REPOSCOUT_DOCKER_WAIT_DETAIL += " 管理员日志末尾：$setupTail。" }
                $env:REPOSCOUT_DOCKER_WAIT_DETAIL += ' 请按终端指引完成后再次双击继续部署 BAT。'
                Add-RepoWayfinderPrerequisiteEvent -action 'windows_optional_features' -status 'failed' -detail $env:REPOSCOUT_DOCKER_WAIT_DETAIL
                $env:REPOSCOUT_SKIP_DOCKER_START = '1'
                $skipDockerPreparation = $true
            }
    } elseif (-not $skipDockerPreparation -and -not $wslInstallRequired -and -not $vmPlatformReady) {
            Write-Host '已跳过 Windows 功能修改。完成 Virtual Machine Platform、虚拟化和 Docker 首次启动后，可再次双击继续。'
            $declinedDetail = '用户本次未授权修改 Virtual Machine Platform；项目仍在等待环境。'
            if (-not [string]::IsNullOrWhiteSpace($firmwareDetail)) { $declinedDetail += ' ' + $firmwareDetail }
            $env:REPOSCOUT_DOCKER_WAIT_DETAIL = $declinedDetail
            Add-RepoWayfinderPrerequisiteEvent -action 'windows_optional_features' -status 'declined' -detail $declinedDetail
            $env:REPOSCOUT_SKIP_DOCKER_START = '1'
            $skipDockerPreparation = $true
    }

    $wslStatus = $null
    $wslVersion = $null
    if (-not $skipDockerPreparation) {
        $wslStatus = $initialWslStatus
        $wslVersion = $initialWslVersion
    }
    if ($null -ne $wslStatus -and -not $wslStatus.Available) {
        $env:REPOSCOUT_DOCKER_WAIT_DETAIL = '系统找不到 wsl.exe，无法确认或安装 WSL。请完成 Windows Update 或修复 Windows 组件后再继续。'
        Add-RepoWayfinderPrerequisiteEvent -action 'wsl_command_discovery' -status 'missing' -detail $env:REPOSCOUT_DOCKER_WAIT_DETAIL
        $env:REPOSCOUT_SKIP_DOCKER_START = '1'
        $skipDockerPreparation = $true
    }
    if ($null -ne $wslStatus -and $wslInstallRequired) {
        Write-Host ''
        Write-Host '检测到缺少完整 WSL 组件；仅启用 Windows 可选功能或重复重启无法补齐。'
        Write-Host 'Windows 建议运行 wsl --install --no-distribution。它安装 WSL 组件，但不会替你安装 Linux 发行版。此操作需要管理员权限、网络，并可能要求重启。'
        $installAnswer = Read-Host '是否让 RepoWayfinder 执行官方 WSL 组件安装？直接回车表示否 [y/N]'
        if ($installAnswer -match '^(y|yes)$') {
            $setupLog = Join-Path $reportDir 'docker_windows_setup.log'
            try {
                $installArguments = @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', ('"' + $PSCommandPath + '"'),
                    '-ReportPath', ('"' + $resolvedReport + '"'),
                    '-InstallWslComponents',
                    '-SetupLogPath', ('"' + $setupLog + '"')
                )
                $componentInstall = Start-Process -FilePath powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $installArguments -Wait -PassThru
                if ($componentInstall.ExitCode -eq 20) {
                    $env:REPOSCOUT_DOCKER_WAIT_DETAIL = 'WSL 组件安装已完成，但 Windows 要求重启。重启后再次双击本报告目录里的继续部署 BAT。'
                    Add-RepoWayfinderPrerequisiteEvent -action 'wsl_install_no_distribution' -status 'restart_required' -detail $env:REPOSCOUT_DOCKER_WAIT_DETAIL
                    $offerImmediateRestart = $true
                    $env:REPOSCOUT_SKIP_DOCKER_START = '1'
                    $skipDockerPreparation = $true
                } elseif ($componentInstall.ExitCode -ne 0) {
                    throw "wsl --install --no-distribution exited with code $($componentInstall.ExitCode)"
                } else {
                    $wslStatus = Invoke-RepoWayfinderWslCommand @('--status')
                    $wslVersion = Invoke-RepoWayfinderWslCommand @('--version')
                    Add-RepoWayfinderPrerequisiteEvent -action 'wsl_install_no_distribution' -status 'succeeded' -detail 'The official WSL component installer completed without installing a Linux distribution.'
                }
            } catch {
                $env:REPOSCOUT_DOCKER_WAIT_DETAIL = "WSL 组件安装没有完成：$($_.Exception.Message)。管理员日志：$setupLog。请确认 Windows Update 和网络可用后再次继续。"
                Add-RepoWayfinderPrerequisiteEvent -action 'wsl_install_no_distribution' -status 'failed' -detail $env:REPOSCOUT_DOCKER_WAIT_DETAIL
                $env:REPOSCOUT_SKIP_DOCKER_START = '1'
                $skipDockerPreparation = $true
            }
        } else {
            $env:REPOSCOUT_DOCKER_WAIT_DETAIL = '系统缺少完整 WSL 组件；用户本次未授权执行 wsl --install --no-distribution。项目继续等待环境。'
            Add-RepoWayfinderPrerequisiteEvent -action 'wsl_install_no_distribution' -status 'declined' -detail $env:REPOSCOUT_DOCKER_WAIT_DETAIL
            $env:REPOSCOUT_SKIP_DOCKER_START = '1'
            $skipDockerPreparation = $true
        }
    }
    $wslUpdateEvidence = ''
    if ($null -ne $wslStatus) { $wslUpdateEvidence = [string]$wslStatus.Text }
    if ($null -ne $wslVersion) { $wslUpdateEvidence += [Environment]::NewLine + [string]$wslVersion.Text }
    if ($null -ne $wslStatus -and $wslStatus.Available -and (Test-RepoWayfinderWslUpdateRequired $wslUpdateEvidence)) {
        Write-Host ''
        Write-Host '检测到 WSL 版本或 WSL2 内核不满足当前 Docker Desktop；只重复启动或重装 Docker 无法解决。'
        Write-Host 'Windows 和 Docker 建议运行 wsl --update。此操作需要网络，可能触发 UAC、Windows Update 或重启。'
        $updateAnswer = Read-Host '是否让 RepoWayfinder 以管理员权限执行官方 wsl --update？直接回车表示否 [y/N]'
        if ($updateAnswer -match '^(y|yes)$') {
            try {
                $updateArguments = @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', ('"' + $PSCommandPath + '"'),
                    '-ReportPath', ('"' + $resolvedReport + '"'),
                    '-UpdateWslKernel',
                    '-SetupLogPath', ('"' + (Join-Path $reportDir 'docker_windows_setup.log') + '"')
                )
                $updated = Start-Process -FilePath powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $updateArguments -Wait -PassThru
                if ($updated.ExitCode -ne 0) { throw "wsl --update exited with code $($updated.ExitCode)" }
                $wslStatus = Invoke-RepoWayfinderWslCommand @('--status')
                $wslVersion = Invoke-RepoWayfinderWslCommand @('--version')
                Add-RepoWayfinderPrerequisiteEvent -action 'wsl_update' -status 'succeeded' -detail 'The official wsl --update command completed successfully after separate user authorization.'
            } catch {
                $env:REPOSCOUT_DOCKER_WAIT_DETAIL = "WSL 更新没有完成：$($_.Exception.Message)。请确认 Windows Update 未暂停且网络可用，然后再次双击继续部署 BAT。"
                Add-RepoWayfinderPrerequisiteEvent -action 'wsl_update' -status 'failed' -detail $env:REPOSCOUT_DOCKER_WAIT_DETAIL
                $env:REPOSCOUT_SKIP_DOCKER_START = '1'
            }
        } else {
            $env:REPOSCOUT_DOCKER_WAIT_DETAIL = '当前 WSL 版本或内核不满足 Docker；用户本次未授权执行 wsl --update。恢复 Windows Update/网络后再次双击继续部署 BAT，并在明确提示时选择是否更新。'
            Add-RepoWayfinderPrerequisiteEvent -action 'wsl_update' -status 'declined' -detail $env:REPOSCOUT_DOCKER_WAIT_DETAIL
            $env:REPOSCOUT_SKIP_DOCKER_START = '1'
        }
        $postUpdateEvidence = ([string]$wslStatus.Text) + [Environment]::NewLine + ([string]$wslVersion.Text)
        if ($wslStatus.Available -and (Test-RepoWayfinderWslUpdateRequired $postUpdateEvidence) -and [string]::IsNullOrWhiteSpace($env:REPOSCOUT_DOCKER_WAIT_DETAIL)) {
            $env:REPOSCOUT_DOCKER_WAIT_DETAIL = 'wsl --update 已执行，但系统仍报告 WSL 版本或内核不满足 Docker。请完成 Windows Update 或重启后，再次双击继续部署 BAT。'
            $env:REPOSCOUT_SKIP_DOCKER_START = '1'
        }
    }

    if (-not $skipDockerPreparation -and $null -ne $wslStatus -and $wslStatus.ExitCode -ne 0 -and -not $wslUpdateRequired) {
        $vmService = Get-RepoWayfinderWslServiceState @('vmcompute')
        $wslService = Get-RepoWayfinderWslServiceState @('WslService','LxssManager')
        if ($wslPackageState -eq 'installed' -and ($vmService -in @('stopped','disabled') -or $wslService -in @('stopped','disabled'))) {
            $env:REPOSCOUT_DOCKER_WAIT_DETAIL = "WSL 已安装，但相关服务未运行：vmcompute=$vmService，WSL=$wslService。请在 Windows 服务中检查并启动这些服务，再继续；无需重新安装 WSL。"
            Add-RepoWayfinderPrerequisiteEvent 'wsl_service_check' 'not_running' $env:REPOSCOUT_DOCKER_WAIT_DETAIL
        } else {
            $env:REPOSCOUT_DOCKER_WAIT_DETAIL = 'WSL 仍未就绪，现有证据不足以确认缺包或需要重启。请查看报告内的 WSL 状态和管理员日志后再继续。'
            Add-RepoWayfinderPrerequisiteEvent 'wsl_readiness' 'not_ready' $env:REPOSCOUT_DOCKER_WAIT_DETAIL
        }
        $env:REPOSCOUT_SKIP_DOCKER_START = '1'
        $skipDockerPreparation = $true
    }

    $dockerDesktop = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe'),
        (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if ($dockerDesktop -and $env:REPOSCOUT_SKIP_DOCKER_START -ne '1' -and (-not $skipDockerPreparation)) {
        Write-Host "Starting Docker Desktop: $dockerDesktop"
        $dockerWasRunning = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'Docker Desktop' }).Count -gt 0
        Start-Process -FilePath $dockerDesktop -WindowStyle Hidden | Out-Null
        if (-not $dockerWasRunning) { $env:REPOSCOUT_DOCKER_STARTED_BY_REPOSCOUT = '1' }
        Write-Host '如果 Docker 显示许可或首次启动窗口，请阅读并由你本人完成；RepoWayfinder 不会代替接受许可。'
    } else {
        if ($skipDockerPreparation) {
            Write-Host '本次未继续修改或启动 Docker 环境；RepoWayfinder 现在会把等待原因写回同一报告。'
        } else {
            Write-Host '未找到 Docker Desktop 程序。继续后 RepoWayfinder 会再次检查并在你点击本 BAT 的确认语义下尝试准备环境。'
        }
    }
}

$runner = Join-Path $projectDir 'run_reposcout.ps1'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "RepoWayfinder runner not found: $runner" }
if ($previouslyDeclined) {
    Write-Host '上次选择了不安装；RepoWayfinder 会再次询问且默认仍为不安装。'
    Remove-Item Env:REPOSCOUT_RESUME_CONFIRMED -ErrorAction SilentlyContinue
} else {
    $env:REPOSCOUT_RESUME_CONFIRMED = '1'
}
Write-Host ''
Write-Host '继续同一份部署计划和报告；不会重新选择仓库或调用 AI 重新规划。'
Publish-RepoWayfinderPrerequisiteEvents
$runnerExitCode = Invoke-RepoWayfinderPowerShellWithProgress @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'--resume-report',$resolvedReport)
if ($offerImmediateRestart) {
    if ($runnerExitCode -ne 0) {
        Write-Host '等待状态未能完整写回报告，因此 RepoWayfinder 本次不会自动重启。请先保留此窗口并检查上面的错误。'
    } else {
        Write-Host ''
        Write-Host '等待状态和继续部署入口已经保存。重启会立即关闭正在运行的程序，请先保存其他工作。'
        $restartAnswer = Read-Host '是否现在立即重启 Windows？请输入 y 才会重启，直接回车暂不重启 [y/N]'
        if ($restartAnswer -match '^(y|yes)$') {
            $shutdown = Join-Path $env:SystemRoot 'System32\shutdown.exe'
            if (-not (Test-Path -LiteralPath $shutdown -PathType Leaf)) {
                Write-Host '找不到 Windows shutdown.exe；请手动重启，之后再次双击本报告目录里的继续部署 BAT。'
                exit 1
            }
            Write-Host '正在重启 Windows。开机后再次双击本报告目录里的继续部署 BAT。'
            & $shutdown /r /t 0
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Windows 没有接受重启请求（退出码 $LASTEXITCODE）。请手动重启后继续。"
                exit 1
            }
        } else {
            Write-Host '本次暂不重启。准备好后请手动重启；开机后再次双击本报告目录里的继续部署 BAT。'
        }
    }
}
exit $runnerExitCode
