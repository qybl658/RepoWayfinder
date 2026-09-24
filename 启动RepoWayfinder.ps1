# Primary user-facing entry. Internal script names remain stable so existing
# installations and saved reports continue to work across the product rename.
& (Join-Path $PSScriptRoot 'start_reposcout.ps1') @args
exit $LASTEXITCODE
