[CmdletBinding()]
param([string]$Root = '', [ValidateSet('zh-CN','en')][string]$Language = 'zh-CN', [string]$PythonExecutable = '', [switch]$DefineOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$ProgressPreference = 'SilentlyContinue'

function Resolve-ProjectConfigPython([string]$Requested = '') {
    $candidate = if ([string]::IsNullOrWhiteSpace($Requested)) { Join-Path $PSScriptRoot '.reposcout-venv\Scripts\python.exe' } else { $Requested }
    if (-not [IO.Path]::IsPathRooted($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw 'Project configuration needs the installed RepoWayfinder Python environment.'
    }
    return [IO.Path]::GetFullPath($candidate)
}

function Read-ProjectConfigText([string]$Path, [bool]$Toml) {
    if ($Toml) { return [IO.File]::ReadAllText($Path) }
    # Decode the full byte stream so a UTF-8 BOM remains U+FEFF and UTF-16 spans stay exact.
    return [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($Path))
}

function Get-ProjectConfigVersion([string]$Text) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToBase64String($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) }
    finally { $hash.Dispose() }
}

function Invoke-ProjectDotenvMetadata([string]$Text, [string]$Executable = '') {
    $parser = Resolve-ProjectConfigPython $(if ([string]::IsNullOrWhiteSpace($Executable)) { $PythonExecutable } else { $Executable })
    $helper = Join-Path $PSScriptRoot 'project_config.py'
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw 'The project configuration reader is missing.' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $parser
    $start.Arguments = '-I "' + $helper + '" metadata'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $utf8 = [Text.UTF8Encoding]::new($false)
    if ($null -ne $start.PSObject.Properties['StandardInputEncoding']) { $start.StandardInputEncoding = $utf8 }
    if ($null -ne $start.PSObject.Properties['StandardOutputEncoding']) { $start.StandardOutputEncoding = $utf8 }
    if ($null -ne $start.PSObject.Properties['StandardErrorEncoding']) { $start.StandardErrorEncoding = $utf8 }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'The project configuration reader could not be started.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $payload = ConvertTo-Json -InputObject $Text -Compress
        # Windows PowerShell 5 lacks ProcessStartInfo.StandardInputEncoding; write UTF-8 bytes directly.
        $payloadBytes = $utf8.GetBytes($payload + "`n")
        $stdin = $process.StandardInput.BaseStream
        $stdin.Write($payloadBytes, 0, $payloadBytes.Length)
        $stdin.Flush()
        $stdin.Close()
        if (-not $process.WaitForExit(10000)) {
            try { $process.Kill() } catch {}
            [void]$process.WaitForExit(2000)
            throw 'The project configuration reader exceeded the 10 second limit.'
        }
        $stdout = $stdoutTask.Result
        [void]$stderrTask.Result
        if ($process.ExitCode -ne 0) { throw 'The project configuration reader failed; project configuration was preserved.' }
        try { $metadata = ConvertFrom-Json -InputObject $stdout } catch { throw 'The project configuration reader returned invalid metadata.' }
        if ($null -eq $metadata -or $metadata.ok -ne $true) { throw 'The project configuration reader rejected the project configuration.' }
        return $metadata
    } finally { $process.Dispose() }
}

function Test-ProjectConfigSensitiveKey([string]$Key) {
    $lower = $Key.ToLowerInvariant()
    if ($lower -match '_(?:expiry_in_minutes|expires_in|expiration_time|ttl|lifetime|timeout|max_age)$') { return $false }
    if ($lower -match '(?:^|_)(?:secret|password|pass|token)(?:_|$)') { return $true }
    return $lower -match '(?:api_?keys?|speech_key|credential|credentials|auth|cookie|private_key|encryption_key)$'
}

function ConvertTo-DotenvQuotedValue([string]$Value) {
    $encoded = $Value.Replace('\', '\\').Replace('"', '\"')
    $encoded = $encoded.Replace("`a", '\a').Replace("`b", '\b').Replace("`f", '\f').Replace([string][char]11, '\v')
    $encoded = $encoded.Replace("`n", '\n').Replace("`r", '\r').Replace("`t", '\t')
    return '"' + $encoded + '"'
}

function Get-ProjectConfigProfile([string]$Section, [string]$Key) {
    $lower = $Key.ToLowerInvariant()
    $sectionLower = $Section.ToLowerInvariant()
    $provider = if ($sectionLower -and $sectionLower -notin @('app','project','settings')) { $sectionLower } else { ($lower -split '_')[0] }
    if ($lower.StartsWith('api_route_') -and $sectionLower -in @('','app','project','settings')) { $provider = 'api_route' }
    if ($sectionLower -eq 'app' -and $lower -eq 'api_key') { $provider = 'project-access' }
    $purpose = 'other'
    if ($provider -in @('openai','deepseek','anthropic','gemini','google','moonshot','qwen','azure','volcengine','grok','minimax','mimo','cloudflare','modelscope','aihubmix','aimlapi','evolink','openrouter','api_route','oneapi','groq','pollinations','shengsuanyun','apimart','ollama')) { $purpose = 'text' }
    if ($provider -in @('pexels','pixabay','coverr','twelvelabs')) { $purpose = 'materials' }
    if ($provider -in @('wavespeed','ofox','metaso','loomloom') -or $lower -match 'image|seedance') { $purpose = 'video' }
    if ($sectionLower -match 'tts|speech|voice|elevenlabs|sonilo' -or ($sectionLower -eq 'azure' -and $lower -match '^speech_')) { $purpose = 'voice' }
    if ($provider -eq 'project-access' -or $provider -eq 'redis') { $purpose = 'access' }
    return [pscustomobject]@{ Provider = $provider; Purpose = $purpose; Group = $purpose + ':' + $provider }
}

function Get-ProjectConfigAssignments([string]$Text, [bool]$Toml, [string]$Executable = '') {
    if (-not $Toml) {
        $metadata = Invoke-ProjectDotenvMetadata $Text $Executable
        $errorLines = @($metadata.error_lines)
        if ($errorLines.Count -gt 0) { throw ('The dotenv parser rejected malformed lines: ' + ($errorLines -join ', ') + '.') }
        foreach ($field in @($metadata.fields)) {
            $start = [int]$field.value_start
            $end = [int]$field.value_end
            $line = [int]$field.line
            if ($field.key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
            if ($line -lt 1 -or $start -lt 0 -or $end -lt $start -or $end -gt $Text.Length -or $null -eq $field.PSObject.Properties['sensitive']) {
                throw 'The project configuration reader returned an invalid field span.'
            }
            if (-not [bool]$field.has_equal -and $start -ne $end) { throw 'The project configuration reader returned an invalid key-only field span.' }
            [pscustomobject]@{
                Section = ''; Key = [string]$field.key; Raw = $Text.Substring($start, $end - $start); Index = $line - 1
                ValueStart = $start; ValueEnd = $end; HasEqual = [bool]$field.has_equal; HasValue = [bool]$field.has_value
                Sensitive = [bool]$field.sensitive
                DisplayValue = if ($null -eq $field.display_value) { $null } else { [string]$field.display_value }
            }
        }
        return
    }
    $section = ''
    $index = 0
    foreach ($line in ($Text -replace '^\uFEFF','' -split "`r?`n")) {
        if ($Toml -and $line -match '^\s*\[([A-Za-z0-9_.-]+)\]\s*(?:#.*)?$') { $section = $Matches[1] }
        elseif ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
            # Raw values stay private to this parser and are never returned by the public plan.
            [pscustomobject]@{ Section = $section; Key = $Matches[1]; Raw = $Matches[2]; Index = $index; HasValue = Test-ProjectConfigValuePresent $Matches[2]; Sensitive = Test-ProjectConfigSensitiveKey $Matches[1]; DisplayValue = $null }
        }
        $index++
    }
}

function Test-ProjectConfigValuePresent([string]$Raw) {
    $value = ($Raw -replace '\s+#.*$','').Trim().Trim('"',"'").ToLowerInvariant()
    return $value -notin @('','[]','{}','none','null')
}

function Initialize-TargetProjectConfigTemplates([string]$ProjectRoot) {
    foreach ($pair in @(@('.env.example','.env'),@('config.example.toml','config.toml'))) {
        $template = Join-Path $ProjectRoot $pair[0]
        $target = Join-Path $ProjectRoot $pair[1]
        if ((Test-Path -LiteralPath $template -PathType Leaf) -and -not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $template -Destination $target }
    }
}

function Read-ProjectConfigTemplateText([string]$Path, [bool]$Toml) {
    $text = Read-ProjectConfigText $Path $Toml
    if (-not $Toml) { $text = [regex]::Replace($text, '(?m)^([ \t]*)#[ \t]*([A-Z][A-Z0-9_]*[ \t]*=)', '$1$2') }
    return $text
}

function Get-TargetProjectConfigPlan([string]$ProjectRoot) {
    $projectPath = [IO.Path]::GetFullPath($ProjectRoot)
    $fields = [Collections.Generic.List[object]]::new()
    $selected = @{}
    $versions = @{}
    foreach ($pair in @(@('.env.example','.env'),@('config.example.toml','config.toml'))) {
        $template = Join-Path $projectPath $pair[0]
        $target = Join-Path $projectPath $pair[1]
        if (-not (Test-Path -LiteralPath $template -PathType Leaf)) { continue }
        $toml = $pair[1].EndsWith('.toml')
        $templateFields = @(Get-ProjectConfigAssignments (Read-ProjectConfigTemplateText $template $toml) $toml)
        $existingFields = if (Test-Path -LiteralPath $target -PathType Leaf) {
            $existingText = Read-ProjectConfigText $target $toml
            $versions[$pair[1]] = Get-ProjectConfigVersion $existingText
            @(Get-ProjectConfigAssignments $existingText $toml)
        } else { @() }
        foreach ($selector in @('llm_provider','video_source')) {
            $matchesSelector = @($existingFields | Where-Object { $_.Key -eq $selector })
            if ($matchesSelector.Count -eq 1) {
                $value = if ($toml) { $matchesSelector[0].Raw.Trim().Trim('"',"'") } else { [string]$matchesSelector[0].DisplayValue }
                if ($value -match '^[A-Za-z0-9_-]{1,40}$') { $selected[$selector] = $value.ToLowerInvariant() }
            }
        }
        foreach ($field in $templateFields) {
            $sensitive = if ($toml) { Test-ProjectConfigSensitiveKey $field.Key } else { $field.Sensitive }
            $companion = $field.Key -match '(?i)(base_url|model_name|speech_region|account_id|gateway_id|api_version)$'
            if (-not $sensitive -and -not $companion -and $field.Key -notin @('llm_provider','video_source')) { continue }
            $profile = Get-ProjectConfigProfile $field.Section $field.Key
            if ($field.Section -and $field.Section -notin @('app','project','settings') -and @($templateFields | Where-Object { $_.Section -eq $field.Section -and $_.Key -match '^(voice_id|voices|speech_key)$' }).Count -gt 0) { $profile.Purpose = 'voice'; $profile.Group = 'voice:' + $profile.Provider }
            $sameTemplate = @($templateFields | Where-Object { $_.Section -eq $field.Section -and $_.Key -eq $field.Key })
            $sameExisting = @($existingFields | Where-Object { $_.Section -eq $field.Section -and $_.Key -eq $field.Key })
            $configured = $sameExisting.Count -eq 1 -and $(if ($toml) { Test-ProjectConfigValuePresent $sameExisting[0].Raw } else { $sameExisting[0].HasValue })
            $fields.Add([pscustomobject]@{
                Id = $pair[1] + '|' + $field.Section + '|' + $field.Key
                Target = $pair[1]; Section = $field.Section; Key = $field.Key
                Group = $profile.Group; Provider = $profile.Provider; Purpose = $profile.Purpose
                Sensitive = $sensitive; Configured = $configured; Ambiguous = $sameTemplate.Count -ne 1 -or $sameExisting.Count -gt 1
                IsArray = $field.Raw.Trim().StartsWith('[')
            })
        }
    }
    $groups = [Collections.Generic.List[object]]::new()
    foreach ($group in @($fields | Where-Object { $_.Sensitive -and -not $_.Ambiguous } | Group-Object Group)) {
        $first = $group.Group[0]
        $members = @($fields | Where-Object { $_.Group -eq $group.Name -and -not $_.Ambiguous -and $_.Key -notin @('llm_provider','video_source') } | Sort-Object @{Expression='Sensitive';Descending=$true},Key)
        $recommended = ($first.Purpose -eq 'text' -and $selected.ContainsKey('llm_provider') -and $selected['llm_provider'] -eq $first.Provider) -or ($first.Purpose -eq 'materials' -and $selected.ContainsKey('video_source') -and $selected['video_source'] -eq $first.Provider)
        $groups.Add([pscustomobject]@{ Id = $group.Name; Provider = $first.Provider; Purpose = $first.Purpose; Recommended = $recommended; Fields = $members })
    }
    if (@($groups | Where-Object Recommended).Count -eq 0) {
        $choice = @($groups | Where-Object { $_.Purpose -eq 'text' -and @($_.Fields | Where-Object Configured).Count -gt 0 } | Select-Object -First 1)
        if ($choice.Count -eq 0) { $choice = @($groups | Where-Object { $_.Purpose -eq 'text' } | Sort-Object @{Expression={ $fields.IndexOf($_.Fields[0]) }} | Select-Object -First 1) }
        if ($choice.Count) { $choice[0].Recommended = $true }
    }
    return [pscustomobject]@{ Root = $projectPath; FileVersions = $versions; Fields = @($fields); Groups = @($groups | Sort-Object @{Expression='Recommended';Descending=$true},@{Expression={if ($_.Purpose -eq 'text') {0} elseif ($_.Purpose -eq 'materials') {1} elseif ($_.Purpose -eq 'voice') {2} else {3}}},Provider) }
}

function Save-TargetProjectConfigEdits($Plan, [hashtable]$Values, [string]$SelectedGroup = '') {
    $updates = @{}
    foreach ($id in $Values.Keys) {
        $field = @($Plan.Fields | Where-Object { $_.Id -eq $id })
        if ($field.Count -ne 1 -or $field[0].Ambiguous) { throw 'Unknown or ambiguous project configuration field.' }
        if (-not [string]::IsNullOrWhiteSpace([string]$Values[$id])) { $updates[$id] = [string]$Values[$id] }
    }
    $group = @($Plan.Groups | Where-Object { $_.Id -eq $SelectedGroup })
    if ($group.Count -eq 1 -and $group[0].Purpose -in @('text','materials') -and @($group[0].Fields | Where-Object { $_.Sensitive -and ($_.Configured -or $updates.ContainsKey($_.Id)) }).Count -gt 0 -and $updates.Count -gt 0) {
        $selectorKey = if ($group[0].Purpose -eq 'text') { 'llm_provider' } else { 'video_source' }
        $selector = @($Plan.Fields | Where-Object { $_.Key -eq $selectorKey })
        if ($selector.Count -eq 1 -and -not $selector[0].Ambiguous) { $updates[$selector[0].Id] = $group[0].Provider }
    }
    $results = [Collections.Generic.List[object]]::new()
    foreach ($targetGroup in @($Plan.Fields | Where-Object { $updates.ContainsKey($_.Id) } | Group-Object Target)) {
        $path = Join-Path $Plan.Root $targetGroup.Name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Target configuration was not created from its template.' }
        if (((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Redirected project configuration paths are refused.' }
        $toml = $targetGroup.Name.EndsWith('.toml')
        $initial = Read-ProjectConfigText $path $toml
        if (-not $Plan.FileVersions.ContainsKey($targetGroup.Name) -or (Get-ProjectConfigVersion $initial) -cne $Plan.FileVersions[$targetGroup.Name]) {
            throw 'Project configuration changed while the editor was open; reopen it before saving.'
        }
        $lines = [Collections.Generic.List[string]]::new()
        if ($toml) { foreach ($line in ($initial -replace '^\uFEFF','' -split "`r?`n")) { $lines.Add($line) } }
        $assignments = @(Get-ProjectConfigAssignments $initial $toml)
        $replacements = [Collections.Generic.List[object]]::new()
        $appendLines = [Collections.Generic.List[string]]::new()
        foreach ($field in $targetGroup.Group) {
            $match = @($assignments | Where-Object { $_.Section -eq $field.Section -and $_.Key -eq $field.Key })
            if (-not $toml -and $match.Count -eq 0) {
                # A template may document optional keys only as comments. Append
                # only the selected field; leave all other examples inactive.
                $appendLines.Add($field.Key + '=' + (ConvertTo-DotenvQuotedValue $updates[$field.Id]))
                continue
            }
            if ($match.Count -ne 1) { throw 'Configuration changed or has an ambiguous field; nothing was saved.' }
            if ($toml) {
                $encoded = ConvertTo-Json -InputObject $updates[$field.Id] -Compress
                if ($field.IsArray) { $encoded = '[' + $encoded + ']' }
                $lines[$match[0].Index] = $field.Key + ' = ' + $encoded
            } else {
                $encoded = ConvertTo-DotenvQuotedValue $updates[$field.Id]
                $replacement = if ($match[0].HasEqual) { $encoded } else { ' = ' + $encoded }
                $replacements.Add([pscustomobject]@{ Start = $match[0].ValueStart; End = $match[0].ValueEnd; Text = $replacement })
            }
        }
        $updatedText = if ($toml) { $lines -join [Environment]::NewLine } else {
            $changed = $initial
            foreach ($replacement in @($replacements | Sort-Object Start -Descending)) {
                $changed = $changed.Substring(0, $replacement.Start) + $replacement.Text + $changed.Substring($replacement.End)
            }
            if ($appendLines.Count) { $changed += [Environment]::NewLine + ($appendLines -join [Environment]::NewLine) + [Environment]::NewLine }
            $changed
        }
        if ((Read-ProjectConfigText $path $toml) -cne $initial) { throw 'Concurrent project configuration edit; nothing was saved.' }
        $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        try {
            if ($toml) { [IO.File]::WriteAllText($temporary, $updatedText, [Text.UTF8Encoding]::new($false)) }
            else { [IO.File]::WriteAllBytes($temporary, [Text.UTF8Encoding]::new($false).GetBytes($updatedText)) }
            Move-Item -LiteralPath $temporary -Destination $path -Force
        } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
        foreach ($field in $targetGroup.Group) { $results.Add([pscustomobject]@{target=$field.Target;field=$field.Section+'.'+$field.Key;status='updated'}) }
    }
    return [pscustomobject]@{ status = if ($updates.Count) { 'updated' } else { 'preserved_empty' }; configuration = @($results) }
}

function Get-ProjectConfigDisplayValue($Plan, $Field) {
    if ($Field.Sensitive) { return [pscustomobject]@{Value='';Source='hidden'} }
    $toml = $Field.Target.EndsWith('.toml')
    foreach ($candidate in @(@($Field.Target,'current'),@($(if ($Field.Target -eq '.env') {'.env.example'} else {'config.example.toml'}),'project_default'))) {
        $path = Join-Path $Plan.Root $candidate[0]
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $assignment = @(Get-ProjectConfigAssignments $(if ($candidate[1] -eq 'project_default') { Read-ProjectConfigTemplateText $path $toml } else { Read-ProjectConfigText $path $toml }) $toml | Where-Object { $_.Section -eq $Field.Section -and $_.Key -eq $Field.Key })
        if ($assignment.Count -ne 1) { continue }
        if (-not $toml) {
            if (-not $assignment[0].HasValue) { continue }
            if ($null -eq $assignment[0].DisplayValue) { return [pscustomobject]@{Value='';Source='protected'} }
            return [pscustomobject]@{Value=[string]$assignment[0].DisplayValue;Source=$candidate[1]}
        }
        if (-not (Test-ProjectConfigValuePresent $assignment[0].Raw)) { continue }
        $raw = ($assignment[0].Raw -replace '\s+#.*$','').Trim()
        $value = if ($raw.StartsWith('"')) { try { ConvertFrom-Json -InputObject $raw } catch { $raw.Trim('"') } } else { $raw.Trim("'") }
        if ($value -isnot [string]) { continue }
        # Service URLs with embedded credentials remain hidden even though the field is normally public.
        if ($Field.Key -match 'base_url$' -and ($value -match '://[^/]*@|[?&](api_?key|token|secret|password|signature)=')) { return [pscustomobject]@{Value='';Source='protected'} }
        return [pscustomobject]@{Value=$value;Source=$candidate[1]}
    }
    return [pscustomobject]@{Value='';Source='manual'}
}

function Show-TargetProjectConfiguration([string]$ProjectRoot, [string]$UiLanguage, [scriptblock]$OnShown = $null) {
    $english = $UiLanguage -eq 'en'
    $text = { param($Zh,$En) if ($english) { $En } else { $Zh } }.GetNewClosure()
    Initialize-TargetProjectConfigTemplates $ProjectRoot
    $plan = Get-TargetProjectConfigPlan $ProjectRoot
    if ($plan.Groups.Count -eq 0) { return [pscustomobject]@{status='no_supported_fields';configuration=@()} }
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object Windows.Forms.Form
    $form.Font = New-Object Drawing.Font($(if ($english) {'Segoe UI'} else {'Microsoft YaHei UI'}),10)
    $form.Text = & $text '配置目标项目 API Key' 'Configure target project API keys'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $intro = New-Object Windows.Forms.Label
    $intro.SetBounds(20,14,700,44)
    $intro.Text = & $text '先选一家 AI 服务即可，其他 Key 按需填写。推荐项优先使用项目已选或已配置的服务，否则取模板中首个已识别的 AI 服务。留空保留原值。' 'Start with one AI provider. Prefer the selected/configured provider, otherwise the first recognized AI provider in the template. Other keys are optional; blank keeps existing values.'
    $form.Controls.Add($intro)
    $combo = New-Object Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'
    $combo.SetBounds(20,70,700,30)
    $purposeNames = @{text=@('AI 模型服务','AI model service');materials=@('视频素材搜索','Video material search');voice=@('语音合成','Speech synthesis');video=@('图像或视频生成','Image or video generation');access=@('项目访问保护','Project access protection');other=@('其他可选配置','Other optional configuration')}
    foreach ($group in $plan.Groups) {
        $purpose = $purposeNames[$group.Purpose]
        $name = (& $text $purpose[0] $purpose[1]) + ' · ' + $group.Provider
        if ($group.Recommended) { $name = (& $text '推荐：' 'Recommended: ') + $name }
        [void]$combo.Items.Add($name)
    }
    $form.Controls.Add($combo)
    $panel = New-Object Windows.Forms.Panel
    $panel.AutoScroll = $true
    $form.Controls.Add($panel)
    $save = New-Object Windows.Forms.Button
    $save.Text = & $text '保存当前提供商配置' 'Save provider settings'
    $save.DialogResult = [Windows.Forms.DialogResult]::OK
    $form.Controls.Add($save)
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = & $text '取消' 'Cancel'
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $cancel
    $form.Controls.Add($cancel)
    $tooltip = New-Object Windows.Forms.ToolTip
    $boxes = @{}
    $initialValues = @{}
    $combo.Add_SelectedIndexChanged({
        $panel.Controls.Clear(); $boxes.Clear(); $initialValues.Clear()
        $group = $plan.Groups[$combo.SelectedIndex]
        $y = 0
        foreach ($field in $group.Fields) {
            $display = Get-ProjectConfigDisplayValue $plan $field
            $friendly = if ($field.Key -match 'base_url$') { & $text '服务地址' 'Service URL' } elseif ($field.Key -match 'model_name$') { & $text '模型' 'Model' } elseif ($field.Key -eq 'speech_region') { & $text '服务区域' 'Service region' } elseif ($field.Key -match 'account_id$') { & $text '账号标识' 'Account ID' } elseif ($field.Key -match 'gateway_id$') { & $text '网关标识' 'Gateway ID' } elseif ($field.Key -match 'api_version$') { & $text '接口版本' 'API version' } elseif ($field.Key -match '(?i)(?:^|_)(?:password|pass)(?:_|$)') { & $text '密码' 'Password' } elseif ($field.Key -match '(?i)(?:^|_)token(?:_|$)') { & $text '访问令牌' 'Access token' } elseif ($field.Key -match '(?i)api_?keys?$|speech_key$') { 'API Key' } else { $field.Key }
            $label = New-Object Windows.Forms.Label
            $label.SetBounds(0,$y,240,22)
            $label.Text = $friendly
            $panel.Controls.Add($label)
            $tooltip.SetToolTip($label, $field.Target + ' · [' + $field.Section + '] ' + $field.Key)
            $state = New-Object Windows.Forms.Label
            $state.SetBounds(250,$y,430,22)
            $state.ForeColor = [Drawing.Color]::DimGray
            $state.Text = if ($field.Sensitive) { if ($field.Configured) { & $text '已配置；留空保留，输入新值才会更换' 'Configured; blank keeps it, a new value replaces it' } else { & $text '未填写；仅使用此提供商时需要' 'Empty; needed only for this provider' } } elseif ($display.Source -eq 'current') { & $text '已载入当前值，可修改' 'Current value loaded; editable' } elseif ($display.Source -eq 'project_default') { & $text '项目推荐默认值，可修改' 'Project default loaded; editable' } else { & $text '请按项目或提供商文档填写' 'Use the project or provider documentation' }
            $panel.Controls.Add($state)
            $box = New-Object Windows.Forms.TextBox
            $box.SetBounds(0,($y+25),680,28)
            $box.UseSystemPasswordChar = $field.Sensitive
            $box.Text = $display.Value
            $panel.Controls.Add($box)
            $boxes[$field.Id] = $box
            $initialValues[$field.Id] = $box.Text
            $hint = New-Object Windows.Forms.Label
            $hint.SetBounds(0,($y+57),680,26)
            $hint.Font = New-Object Drawing.Font($(if ($english) {'Segoe UI'} else {'Microsoft YaHei UI'}),9)
            $hint.ForeColor = [Drawing.Color]::DimGray
            $hint.Text = if ($field.Sensitive) { & $text '填写项目文档要求的密钥或密码；留空不改。' 'Enter the key or password required by the project; blank keeps it.' } elseif ($field.Key -match 'base_url$') { & $text '填写提供商文档中的 API 接入地址；通常保留已载入的项目默认值。' 'Use the API base URL from the provider documentation; usually keep the loaded project default.' } elseif ($field.Key -match 'model_name$') { & $text '使用该提供商支持的模型名称；通常保留项目默认值。' 'Use a model supported by this provider; usually keep the project default.' } else { & $text '通常保留已载入值；需要更改时请参考项目或提供商文档。' 'Usually keep the loaded value; consult the project or provider documentation before changing it.' }
            $panel.Controls.Add($hint)
            $y += 90
        }
        $panel.SetBounds(20,116,700,[Math]::Min($y,450))
        $buttonY = 116 + [Math]::Min($y,450) + 6
        $save.SetBounds(330,$buttonY,240,36)
        $cancel.SetBounds(590,$buttonY,130,36)
        $form.ClientSize = New-Object Drawing.Size(740,($buttonY+54))
    }.GetNewClosure())
    $combo.SelectedIndex = 0
    if ($null -ne $OnShown) { $form.Add_Shown({ [void](& $OnShown $form) }.GetNewClosure()) }
    try {
        if ($form.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return [pscustomobject]@{status='preserved_cancelled';configuration=@()} }
        $values = @{}
        foreach ($id in $boxes.Keys) { if ($boxes[$id].Text -cne $initialValues[$id]) { $values[$id] = $boxes[$id].Text } }
        return (Save-TargetProjectConfigEdits $plan $values $plan.Groups[$combo.SelectedIndex].Id)
    } finally { $tooltip.Dispose(); $form.Dispose() }
}
if (-not $DefineOnly) {
    try { Show-TargetProjectConfiguration $Root $Language | ConvertTo-Json -Depth 8 -Compress }
    catch { [Console]::Error.WriteLine('Target project configuration was not saved. Check permissions and configuration structure.'); exit 1 }
}
