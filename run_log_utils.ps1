# Helpers for the user-facing latest-run log.

function New-RepoWayfinderTerminalRenderer {
    param(
        [Nullable[bool]]$Interactive = $null,
        [scriptblock]$Emit = { param($Text) [Console]::Write($Text) },
        [scriptblock]$EmitLog = { param($Text) Write-Host $Text },
        [bool]$ForwardFrames = ($env:REPOSCOUT_PROGRESS_FORWARD -eq '1')
    )
    $useConsole = if ($null -eq $Interactive) { -not [Console]::IsOutputRedirected } else { [bool]$Interactive }
    return [pscustomobject]@{ Interactive = $useConsole; Emit = $Emit; EmitLog = $EmitLog; ForwardFrames = $ForwardFrames; Visible = $false; Width = 0 }
}

function Clear-RepoWayfinderTerminalWait($Renderer) {
    if ($Renderer.Visible) {
        [void](& $Renderer.Emit ("`r" + (' ' * $Renderer.Width) + "`r"))
        $Renderer.Visible = $false
        $Renderer.Width = 0
    }
}

function Write-RepoWayfinderTerminalLine($Renderer, [string]$Line) {
    if ($Line -eq '__RWF_WAIT_END__' -or $Line.StartsWith('__RWF_WAIT__')) {
        if ($Renderer.ForwardFrames) { [Console]::WriteLine($Line); return }
        if ($Line -eq '__RWF_WAIT_END__') { Clear-RepoWayfinderTerminalWait $Renderer; return }
        if ($Renderer.Interactive -and $Line -match '^__RWF_WAIT__([0-9]{1,10})$') {
            $english = $env:REPOSCOUT_UI_LANGUAGE -eq 'en'
            $text = if ($english) { 'Waiting ' + $Matches[1] + ' seconds' } else { '等待 ' + $Matches[1] + ' 秒' }
            $width = $text.Length + $(if ($english) { 0 } else { 3 })
            [void](& $Renderer.Emit ("`r" + $text + (' ' * [Math]::Max(0, $Renderer.Width - $width))))
            $Renderer.Visible = $true
            $Renderer.Width = $width
        }
        return
    }
    Clear-RepoWayfinderTerminalWait $Renderer
    [void](& $Renderer.EmitLog $Line)
}

function ConvertTo-RepoWayfinderNativeArgument([string]$Argument) {
    $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-RepoWayfinderPowerShellWithProgress([string[]]$Arguments) {
    $renderer = New-RepoWayfinderTerminalRenderer
    $previousForward = $env:REPOSCOUT_PROGRESS_FORWARD
    $previousErrorAction = $ErrorActionPreference
    try {
        $env:REPOSCOUT_PROGRESS_FORWARD = '1'
        $ErrorActionPreference = 'Continue'
        & powershell.exe @Arguments 2>&1 |
            ForEach-Object { Write-RepoWayfinderTerminalLine $renderer ($_.ToString()) }
        return [int]$LASTEXITCODE
    } finally {
        Write-RepoWayfinderTerminalLine $renderer '__RWF_WAIT_END__'
        Clear-RepoWayfinderTerminalWait $renderer
        $env:REPOSCOUT_PROGRESS_FORWARD = $previousForward
        $ErrorActionPreference = $previousErrorAction
    }
}

function Invoke-RepoWayfinderNativeWithWait([string]$Program, [string[]]$Arguments) {
    $renderer = New-RepoWayfinderTerminalRenderer
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Program
    $start.Arguments = (@($Arguments | ForEach-Object { ConvertTo-RepoWayfinderNativeArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = [Diagnostics.Process]::Start($start)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $stdout = $process.StandardOutput.ReadLineAsync()
    $stderr = $process.StandardError.ReadLineAsync()
    $nextPulse = 1
    try {
        while (-not $process.HasExited -or $null -ne $stdout -or $null -ne $stderr) {
            if ($null -ne $stdout -and $stdout.IsCompleted) {
                $line = $stdout.GetAwaiter().GetResult()
                if ($null -eq $line) { $stdout = $null } else {
                    Write-RepoWayfinderTerminalLine $renderer $line
                    $stdout = $process.StandardOutput.ReadLineAsync()
                }
            }
            if ($null -ne $stderr -and $stderr.IsCompleted) {
                $line = $stderr.GetAwaiter().GetResult()
                if ($null -eq $line) { $stderr = $null } else {
                    Write-RepoWayfinderTerminalLine $renderer $line
                    $stderr = $process.StandardError.ReadLineAsync()
                }
            }
            $seconds = [int][Math]::Floor($watch.Elapsed.TotalSeconds)
            if (-not $process.HasExited -and $seconds -ge $nextPulse) {
                Write-RepoWayfinderTerminalLine $renderer ('__RWF_WAIT__' + $seconds)
                $nextPulse = $seconds + 1
            }
            if (-not $process.HasExited -or $null -ne $stdout -or $null -ne $stderr) { Start-Sleep -Milliseconds 50 }
        }
        $process.WaitForExit()
        return [int]$process.ExitCode
    } finally {
        Write-RepoWayfinderTerminalLine $renderer '__RWF_WAIT_END__'
        Clear-RepoWayfinderTerminalWait $renderer
        $watch.Stop()
        $process.Dispose()
    }
}

function Wait-RepoWayfinderProcess($Process) {
    $renderer = New-RepoWayfinderTerminalRenderer
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        while (-not $Process.WaitForExit(1000)) {
            Write-RepoWayfinderTerminalLine $renderer ('__RWF_WAIT__' + [int][Math]::Floor($watch.Elapsed.TotalSeconds))
        }
        $Process.WaitForExit()
    } finally {
        Write-RepoWayfinderTerminalLine $renderer '__RWF_WAIT_END__'
        Clear-RepoWayfinderTerminalWait $renderer
        $watch.Stop()
    }
}

function Repair-RepoWayfinderRunLog([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        $eligiblePattern = '[\u3400-\u9fff\u3000-\u303f\uff00-\uffef]'
        $pairPattern = '(?<glyph>[\u3400-\u9fff\u3000-\u303f\uff00-\uffef])\k<glyph>'
        $cleaned = [regex]::Replace($text, '[^\r\n]+', {
            param($match)
            $line = $match.Value
            $eligibleCount = [regex]::Matches($line, $eligiblePattern).Count
            if ($eligibleCount -lt 6) { return $line }

            $pairCount = [regex]::Matches($line, $pairPattern).Count
            if ($pairCount -lt 3 -or (($pairCount * 2.0) / $eligibleCount) -lt 0.8) {
                return $line
            }
            [regex]::Replace($line, $pairPattern, '${glyph}')
        })

        $cleaned = [regex]::Replace(
            $cleaned,
            '继{1,2}续{1,2}部{1,2}署{1,2}这{1,2}个{1,2}[\s\u3000]*项{1,2}目{1,2}\.bat',
            '继续部署这个项目.bat'
        )

        if ($cleaned -eq $text) { return $false }
        $utf8Bom = New-Object Text.UTF8Encoding($true)
        [IO.File]::WriteAllText($Path, $cleaned, $utf8Bom)
        return $true
    } catch {
        Write-Host "Could not normalize run.md: $($_.Exception.Message)"
        return $false
    }
}
