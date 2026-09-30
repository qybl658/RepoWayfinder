param(
    [Parameter(Mandatory=$true)][string]$Script,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$ScriptArguments
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'configure_command_path.ps1')
Update-RepoWayfinderCommandPath -BundleRoot $PSScriptRoot -Quiet
& $Script @ScriptArguments
if (-not $?) { exit 1 }
