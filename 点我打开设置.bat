@echo off
setlocal
call "%~dp0command_path.cmd"
"%SystemRoot%\System32\chcp.com" 65001 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0settings_menu.ps1"
exit /b %errorlevel%
