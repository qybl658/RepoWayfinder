@echo off
chcp 65001 >nul
setlocal
set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\install_reposcout.ps1" -ConfigOnly -ForceApiSetup
set "CODE=%ERRORLEVEL%"
if not "%CODE%"=="0" pause
exit /b %CODE%
