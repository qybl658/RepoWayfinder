param([string]$SourceRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'install_reposcout.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Installer parsing failed.' }
$names = @('Clean-EnvValue','Protect-RepoWayfinderSecret','Unprotect-RepoWayfinderSecret','Write-RepoWayfinderLocalEnv','Get-RepoWayfinderGitHubTokenUrl','Test-RepoWayfinderGitHubToken','Read-RepoWayfinderGitHubToken','Configure-RepoWayfinderApis')
foreach ($fn in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($fn.Name -in $names) { . ([scriptblock]::Create($fn.Extent.Text)) }
}
function Assert([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Get-RepoWayfinderUiText([string]$zh,[string]$en) { return $zh }
function Read-VisibleChoice([string]$prompt) {
    if (-not $script:choices.Count) { throw 'Unexpected extra menu prompt.' }
    return $script:choices.Dequeue()
}
function Read-SecretOrSkip([string]$prompt) {
    if (-not $script:secrets.Count) { throw 'Unexpected secret prompt (possibly unwanted AI key request).' }
    return $script:secrets.Dequeue()
}
function Start-Process { param($FilePath,$ErrorAction); $script:opened.Add([string]$FilePath) }
function Invoke-WebRequest {
    param($Uri,$Headers,[switch]$UseBasicParsing,$TimeoutSec,$MaximumRedirection,$ErrorAction)
    Assert ($Uri -ceq 'https://api.github.com/user') 'Unexpected credential destination.'
    Assert ($MaximumRedirection -eq 0) 'Credential request must not follow redirects.'
    Assert ($TimeoutSec -eq 15) 'Missing bounded verification timeout.'
    $script:httpCalls++
    $code = if ($script:responses.Count) { $script:responses.Dequeue() } else { 200 }
    if ($code -eq 200) { return [pscustomobject]@{StatusCode=200;Content='{"login":"synthetic-user"}'} }
    $failure = [Exception]::new('synthetic request failure')
    if ($code -gt 0) { $failure | Add-Member NoteProperty Response ([pscustomobject]@{StatusCode=$code}) }
    throw $failure
}
function Reset-Case([string[]]$menu=@(),[string[]]$keys=@(),[int[]]$codes=@()) {
    $script:choices = [Collections.Generic.Queue[string]]::new()
    foreach ($item in $menu) { $script:choices.Enqueue($item) }
    $script:secrets = [Collections.Generic.Queue[string]]::new()
    foreach ($item in $keys) { $script:secrets.Enqueue($item) }
    $script:responses = [Collections.Generic.Queue[int]]::new()
    foreach ($item in $codes) { $script:responses.Enqueue($item) }
    $script:opened = [Collections.Generic.List[string]]::new()
    $script:httpCalls = 0
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('rw-api-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$projectDir = $testRoot
$localEnvPath = Join-Path $testRoot '.reposcout.env'
$SkipApiSetup = $false
$ForceApiSetup = $true
$NoUI = $false
try {
    # GitHub-only configuration must never prompt for an AI key; reject before retry.
    Set-Content -LiteralPath $localEnvPath -Encoding UTF8 -Value @('OPENROUTER_API_KEY_DPAPI=opaque-existing-ai','REPOSCOUT_AI_MODEL=existing-model','CUSTOM_SETTING=keep')
    Reset-Case @('1','1','2','2') @('synthetic-bad','synthetic-github') @(401,200)
    Configure-RepoWayfinderApis
    $saved = Get-Content -LiteralPath $localEnvPath -Raw -Encoding UTF8
    Assert ($saved.Contains('OPENROUTER_API_KEY_DPAPI=opaque-existing-ai') -and $saved.Contains('REPOSCOUT_AI_MODEL=existing-model') -and $saved.Contains('CUSTOM_SETTING=keep')) 'GitHub update replaced unrelated configuration.'
    Assert (-not $saved.Contains('synthetic-')) 'Plaintext token was saved.'
    $encrypted = ([regex]::Match($saved,'(?m)^GITHUB_TOKEN_DPAPI=(.+)$')).Groups[1].Value.Trim()
    Assert ((Unprotect-RepoWayfinderSecret $encrypted) -ceq 'synthetic-github') 'Saved GitHub token is not decryptable.'
    Assert ($script:httpCalls -eq 2) 'Invalid token retry was not exercised.'

    # AI-only updates preserve the original encrypted GitHub entry exactly.
    Reset-Case @('1','2','1') @('synthetic-ai')
    Configure-RepoWayfinderApis
    $saved = Get-Content -LiteralPath $localEnvPath -Raw -Encoding UTF8
    Assert ($saved.Contains("GITHUB_TOKEN_DPAPI=$encrypted")) 'AI update replaced the GitHub token.'
    Assert ($script:httpCalls -eq 0) 'AI update unnecessarily verified GitHub.'

    # Both selected, GitHub skipped: keep GitHub and still update AI.
    Reset-Case @('1','3','0','2') @('synthetic-openrouter')
    Configure-RepoWayfinderApis
    $saved = Get-Content -LiteralPath $localEnvPath -Raw -Encoding UTF8
    Assert ($saved.Contains("GITHUB_TOKEN_DPAPI=$encrypted") -and $saved.Contains('REPOSCOUT_AI_MODEL=deepseek/deepseek-chat')) 'Skipping GitHub erased it during a combined update.'

    # Network failure, API restriction, invalid token and explicit skip do not write.
    foreach ($code in @(0,403,429,401)) {
        $before = [IO.File]::ReadAllText($localEnvPath)
        Reset-Case @('1','1','2','0') @('synthetic-unverified') @($code)
        Configure-RepoWayfinderApis
        Assert ([IO.File]::ReadAllText($localEnvPath) -ceq $before) 'Unverified token changed saved configuration.'
    }
    foreach ($menu in @(@('1','1','0'),@('1','1','2'),@('3'))) {
        $before = [IO.File]::ReadAllText($localEnvPath)
        Reset-Case $menu @('')
        Configure-RepoWayfinderApis
        Assert ([IO.File]::ReadAllText($localEnvPath) -ceq $before) 'Cancellation changed saved configuration.'
    }

    # Opening the creation page uses GitHub's supported pre-fill URL and no extra permissions.
    Reset-Case @('1','1','1') @('synthetic-created') @(200)
    Configure-RepoWayfinderApis
    Assert ($script:opened.Count -eq 1) 'Creation page did not open exactly once.'
    $url = [uri]$script:opened[0]
    Assert ($url.Host -ceq 'github.com' -and $url.AbsolutePath -ceq '/settings/personal-access-tokens/new') 'Wrong creation page.'
    Assert ($url.Query.Contains('name=RepoWayfinder') -and $url.Query.Contains('expires_in=30') -and -not $url.Query.Contains('contents=') -and -not $url.Query.Contains('write')) 'Incorrect pre-fill or excess permissions.'

    # Browser launch failure leaves a working manual URL/paste path.
    function Start-Process { throw 'synthetic browser unavailable' }
    Reset-Case @('1','1','1') @('synthetic-manual') @(200)
    Configure-RepoWayfinderApis
    Assert ($script:httpCalls -eq 1) 'Browser failure prevented manual token entry.'

    # NoUI must not erase existing configuration, even with ForceApiSetup.
    $before = [IO.File]::ReadAllText($localEnvPath)
    $NoUI = $true
    Configure-RepoWayfinderApis
    Assert ([IO.File]::ReadAllText($localEnvPath) -ceq $before) 'NoUI overwrote existing configuration.'
    $NoUI = $false

    # Run the actual ConfigOnly entry in a separate PowerShell 5.1 process.
    $entryRoot = Join-Path $testRoot 'entry'
    New-Item -ItemType Directory -Path $entryRoot | Out-Null
    foreach ($name in @('install_reposcout.ps1','reposcout_ui.ps1','run_log_utils.ps1')) {
        Copy-Item -LiteralPath (Join-Path $SourceRoot $name) -Destination $entryRoot
    }
    Set-Content -LiteralPath (Join-Path $entryRoot '.reposcout-settings.json') -Encoding UTF8 -Value '{"ui_language":"en"}'
    @'
param([string]$Installer)
$ErrorActionPreference = 'Stop'
$global:apiEntryAnswers = [Collections.Generic.Queue[string]]::new()
foreach ($answer in @('1','1','2','synthetic-entry-token')) { $global:apiEntryAnswers.Enqueue($answer) }
function Add-Type { throw 'GUI is disabled in this isolated test process.' }
function Read-Host {
    param([string]$Prompt,[switch]$AsSecureString)
    if (-not $global:apiEntryAnswers.Count) { throw 'Unexpected prompt in GitHub-only entry.' }
    $answer = $global:apiEntryAnswers.Dequeue()
    if ($AsSecureString) { return ConvertTo-SecureString $answer -AsPlainText -Force }
    return $answer
}
function Invoke-WebRequest {
    param($Uri,$Headers,[switch]$UseBasicParsing,$TimeoutSec,$MaximumRedirection,$ErrorAction)
    if ($Uri -ne 'https://api.github.com/user' -or $Headers.Authorization -ne 'Bearer synthetic-entry-token') { throw 'Unexpected request.' }
    return [pscustomobject]@{StatusCode=200;Content='{"login":"synthetic-user"}'}
}
& $Installer -ConfigOnly -ForceApiSetup
if ($LASTEXITCODE -ne 0 -or $global:apiEntryAnswers.Count) { throw 'ConfigOnly entry did not finish.' }
'@ | Set-Content -LiteralPath (Join-Path $entryRoot 'invoke.ps1') -Encoding UTF8
    $entryOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $entryRoot 'invoke.ps1') -Installer (Join-Path $entryRoot 'install_reposcout.ps1') 2>&1 | Out-String
    Assert ($LASTEXITCODE -eq 0) "Actual ConfigOnly entry failed: $entryOutput"
    Assert ($entryOutput.Contains('GitHub token verified.') -and -not $entryOutput.Contains('synthetic-entry-token')) 'Entry did not verify, or printed the secret.'
    $entryConfig = [IO.File]::ReadAllText((Join-Path $entryRoot '.reposcout.env'))
    Assert ($entryConfig.Contains('GITHUB_TOKEN_DPAPI=') -and -not $entryConfig.Contains('OPENROUTER_API_KEY') -and -not $entryConfig.Contains('synthetic-entry-token')) 'GitHub-only entry saved unexpected configuration.'

    # Encryption failure must preserve the old file and never fall back to plaintext.
    function Protect-RepoWayfinderSecret([string]$value) { return '' }
    $failed = $false
    try { Write-RepoWayfinderLocalEnv -githubToken 'synthetic-failure' -aiKey '' -aiModel '' -skipped $false -updateOnly github } catch { $failed = $true }
    Assert ($failed -and [IO.File]::ReadAllText($localEnvPath) -ceq $before) 'Encryption failure did not preserve the previous file.'

    # Explicit clear still removes saved keys and their owned backups.
    Reset-Case @('2')
    Configure-RepoWayfinderApis
    $cleared = [IO.File]::ReadAllText($localEnvPath)
    Assert ($cleared.Contains('REPOSCOUT_API_SETUP_SKIPPED=1') -and -not $cleared.Contains('_DPAPI=') -and -not $cleared.Contains('GITHUB_TOKEN=')) 'Explicit clear retained a key.'
    Assert (@(Get-ChildItem -LiteralPath $projectDir -Filter '.reposcout.env.backup-*' -File).Count -eq 0) 'Explicit clear retained credential backups.'
    Write-Output 'PASS: separate/combined updates, validation failures, cancellation, browser fallback, NoUI and encryption failure.'
} finally {
    # Only this test's newly allocated directory is owned for cleanup.
    if ([IO.Path]::GetFullPath($testRoot) -ne [IO.Path]::GetFullPath($projectDir) -or (Split-Path -Leaf $testRoot) -notmatch '^rw-api-[0-9a-f]{32}$') { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
