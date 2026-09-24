@echo off
chcp 65001 >nul
title RepoWayfinder Uninstaller
echo RepoWayfinder safe uninstaller
echo.
echo This removes RepoWayfinder-created local runtime/config/reports after confirmation.
echo It does not delete the source folder itself.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall_reposcout.ps1" %*
set "CODE=%ERRORLEVEL%"
if not "%CODE%"=="0" (
  echo.
  echo RepoWayfinder uninstall did not finish. Exit code: %CODE%
  pause
)
exit /b %CODE%

