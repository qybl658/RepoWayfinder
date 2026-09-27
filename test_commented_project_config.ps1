param([string]$PythonExecutable = (Join-Path $PSScriptRoot ".reposcout-venv/Scripts/python.exe"))
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'project_configuration.ps1') -DefineOnly -PythonExecutable $PythonExecutable
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('rwf-commented-config-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $fixture)
$example = "# OPENROUTER_API_KEY=`n# GOOGLE_API_KEY=example_value`n# OPENROUTER_BASE_URL=https://openrouter.ai/api/v1`n"
[IO.File]::WriteAllText((Join-Path $fixture '.env.example'),$example)
Initialize-TargetProjectConfigTemplates $fixture
$plan = Get-TargetProjectConfigPlan $fixture
$group = @($plan.Groups | Where-Object Recommended)
if ($group.Count -ne 1 -or $group[0].Provider -ne 'openrouter') { throw 'Missing template-order recommendation' }
$field = @($plan.Fields | Where-Object Key -eq 'OPENROUTER_API_KEY')[0]
$result=Save-TargetProjectConfigEdits $plan @{$field.Id='fixture-only-not-a-key'} $group[0].Id
$text=[IO.File]::ReadAllText((Join-Path $fixture '.env'))
if (-not $text.StartsWith($example) -or $text -notmatch '(?m)^OPENROUTER_API_KEY="fixture-only-not-a-key"' -or $text -match '(?m)^GOOGLE_API_KEY=') { throw 'Selected commented field was not saved independently' }
$reopened=Get-TargetProjectConfigPlan $fixture
if (-not @($reopened.Fields | Where-Object Key -eq 'OPENROUTER_API_KEY')[0].Configured) { throw 'Saved key not recognized' }
if ((Get-ProjectConfigDisplayValue $reopened $field).Value -ne '') { throw 'Secret shown in editor' }
'Commented template recommendation/save/reopen checks passed.'
