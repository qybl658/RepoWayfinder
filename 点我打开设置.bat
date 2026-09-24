@echo off
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0settings_menu.ps1"
exit /b %errorlevel%
