$ErrorActionPreference = 'Stop'
$work = Join-Path ([IO.Path]::GetTempPath()) ('RepoWayfinder-settings-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'settings_menu.ps1') -Destination $work
@'
function Initialize-RepoWayfinderUiLanguage { param($Path) }
function Get-RepoWayfinderUiText { param($Chinese,$English) return $English }
'@ | Set-Content -LiteralPath (Join-Path $work 'reposcout_ui.ps1') -Encoding UTF8
@'
function Invoke-RepoWayfinderPowerShellWithProgress {
    param($Arguments)
    Write-Host ('ROUTE:' + ($Arguments -join '|'))
    return 0
}
'@ | Set-Content -LiteralPath (Join-Path $work 'run_log_utils.ps1') -Encoding UTF8
$output = @('1','2','3','4','0') | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work 'settings_menu.ps1') 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw "Settings menu failed: $output" }
foreach ($route in @('run_reposcout.ps1|-ReturnToCaller|--configure-search','configure_reposcout_language.ps1','install_reposcout.ps1|-ConfigOnly|-ForceApiSetup','configure_reposcout_mode.ps1')) {
    if (-not $output.Contains($route)) { throw "Missing settings route $route : $output" }
}
Write-Host "PASS: four settings routes; API uses configuration-only mode; return exits. Evidence: $work"
