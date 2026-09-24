@echo off
chcp 65001 >nul
title RepoWayfinder Launcher
echo RepoWayfinder launcher
echo.
echo First run or broken environment: RepoWayfinder will auto-install/repair .reposcout-venv.
echo It does not modify global Python or system environment variables.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_reposcout.ps1" %*
set "CODE=%ERRORLEVEL%"
if not "%CODE%"=="0" (
  echo.
  echo RepoWayfinder did not finish. Exit code: %CODE%
  echo If no popup appeared, open the newest beginner_guide.md under reports.
  pause
)
exit /b %CODE%
