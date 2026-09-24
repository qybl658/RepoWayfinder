# Compatibility entry: keep one launcher implementation so language and safety
# behavior cannot drift between the English and Chinese script names.
& (Join-Path $PSScriptRoot 'start_reposcout.ps1') @args
exit $LASTEXITCODE
