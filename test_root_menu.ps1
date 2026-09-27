$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ('RepoWayfinder-menu-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
foreach ($name in @('start_reposcout.ps1','root_menu.ps1','reposcout_ui.ps1','run_log_utils.ps1')) {
    Copy-Item -LiteralPath (Join-Path $source $name) -Destination $work
}
function Assert-Menu($Condition, $Message) { if (-not $Condition) { throw $Message } }
'{"ui_language":"en"}' | Set-Content -LiteralPath (Join-Path $work '.reposcout-settings.json') -Encoding UTF8
@'
param([switch]$ReturnToCaller, [Parameter(ValueFromRemainingArguments=$true)][string[]]$TargetArgs)
Write-Host ('DEPLOY_ARGS:' + ($TargetArgs -join '|'))
$global:LASTEXITCODE = 0
'@ | Set-Content -LiteralPath (Join-Path $work 'run_reposcout.ps1') -Encoding UTF8
@'
param([switch]$OpenOnly, [switch]$NoPause)
Write-Output ('MENU_ACTION:' + $OpenOnly)
exit 7
'@ | Set-Content -LiteralPath (Join-Path $work 'continue_last_deployment.ps1') -Encoding UTF8
"Write-Host 'SETTINGS_OPENED'; exit 0" | Set-Content -LiteralPath (Join-Path $work 'settings_menu.ps1') -Encoding UTF8
$previousCapture = $env:REPOSCOUT_LAUNCHER_CAPTURE_TEST
$previousLanguage = $env:REPOSCOUT_UI_LANGUAGE
try {
    $env:REPOSCOUT_LAUNCHER_CAPTURE_TEST = '1'
    $env:REPOSCOUT_UI_LANGUAGE = 'en'
    foreach ($choice in @('0','2')) {
        $output = $choice | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work 'start_reposcout.ps1') 2>&1 | Out-String
        $expected = if ($choice -eq '0') { 0 } else { 7 }
        Assert-Menu ($LASTEXITCODE -eq $expected) "Menu $choice lost exit code: $output"
        Assert-Menu ($output.Contains('[3] Open all run results (reports)') -and $output.Contains('[4] Deployment history') -and $output.Contains('[5] Settings')) 'Main menu is missing an action.'
        if ($choice -ne '0') { Assert-Menu ($output.Contains('MENU_ACTION:' + ($choice -eq '3'))) "Wrong navigation: $output" }
    }
    $output = @('1','local/demo') | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work 'start_reposcout.ps1') 2>&1 | Out-String
    Assert-Menu ($LASTEXITCODE -eq 0 -and $output.Contains('DEPLOY_ARGS:local/demo')) "Deploy choice lost target: $output"
    $output = @('1','') | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work 'start_reposcout.ps1') 2>&1 | Out-String
    Assert-Menu ($LASTEXITCODE -eq 0 -and $output.Contains('DEPLOY_ARGS:gabrielecirulli/2048')) "Default demo route failed: $output"
    foreach ($choice in @('3','4','5','7')) {
        $output = @($choice,'0') | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work 'start_reposcout.ps1') 2>&1 | Out-String
        $marker = if ($choice -eq '3') { 'MENU_ACTION:True' } elseif ($choice -eq '4') { 'DEPLOY_ARGS:--history' } elseif ($choice -eq '7') { 'DEPLOY_ARGS:--weekly-trending' } else { 'SETTINGS_OPENED' }
        Assert-Menu ($LASTEXITCODE -eq 0 -and $output.Contains($marker)) "Navigation failed to return to menu: $output"
        Assert-Menu (([regex]::Matches($output, [regex]::Escape('[1] Deploy a project'))).Count -ge 2) "Menu was not displayed again: $output"
    }
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work 'start_reposcout.ps1') -Target 'local/direct' -NoPause 2>&1 | Out-String
    Assert-Menu ($LASTEXITCODE -eq 0 -and $output.Contains('DEPLOY_ARGS:local/direct') -and -not $output.Contains('[1] Deploy')) "Explicit target unexpectedly enters menu: $output"
    Copy-Item -LiteralPath (Join-Path $source 'continue_last_deployment.ps1') -Destination $work -Force
    $target = Join-Path $work 'actual project'
    [void](New-Item -ItemType Directory -Path $target)
    foreach ($name in @('valid','invalid')) { [void](New-Item -ItemType Directory -Path (Join-Path $work "reports\$name")) }
    $validReport = Join-Path $work 'reports\valid\deployment_result.json'
    @{repo_path=$target} | ConvertTo-Json | Set-Content -LiteralPath $validReport -Encoding UTF8
    Start-Sleep -Milliseconds 50
    @{repo_path='relative\invalid'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $work 'reports\invalid\deployment_result.json') -Encoding UTF8
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work 'continue_last_deployment.ps1') -OpenOnly -NoOpen -NoPause 2>&1 | Out-String
    Assert-Menu ($LASTEXITCODE -eq 0 -and $output.Contains((Join-Path $work 'reports')) -and -not $output.Contains((Join-Path $work 'reports\invalid')) -and -not $output.Contains($target)) "Open-last failed to select latest report folder independently of source path: $output"
    foreach ($removed in @('打开上次部署目录.bat','继续未完成的部署（仅在程序提示时使用）.bat')) {
        Assert-Menu (-not (Test-Path -LiteralPath (Join-Path $source $removed))) "Duplicate root entry remains: $removed"
    }
    Write-Host "PASS: menu navigation, explicit target, exit codes, valid project selection. Evidence: $work"
} finally {
    $env:REPOSCOUT_LAUNCHER_CAPTURE_TEST = $previousCapture
    $env:REPOSCOUT_UI_LANGUAGE = $previousLanguage
}
