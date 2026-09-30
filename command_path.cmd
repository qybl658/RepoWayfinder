@echo off
rem Process-only command path. Does not write the user or system Path.
if not defined SystemRoot set "SystemRoot=%windir%"
set "ComSpec=%SystemRoot%\System32\cmd.exe"
set "PATHEXT=.COM;.EXE;.BAT;.CMD;%PATHEXT%"
set "PATH=%SystemRoot%\System32\WindowsPowerShell\v1.0;%SystemRoot%\System32;%SystemRoot%\System32\Wbem;%SystemRoot%;%PATH%"
if exist "%~dp0runtime\python\python.exe" set "PATH=%~dp0runtime\python;%PATH%"
if exist "%~dp0scenario-kit\runtime\python.exe" set "PATH=%~dp0scenario-kit\runtime;%PATH%"
if exist "%~dp0.reposcout-python\python.exe" set "PATH=%~dp0.reposcout-python;%PATH%"
if exist "%~dp0.reposcout-venv\Scripts\python.exe" set "PATH=%~dp0.reposcout-venv\Scripts;%PATH%"
if exist "%~dp0.reposcout-git\cmd\git.exe" set "PATH=%~dp0.reposcout-git\cmd;%PATH%"
if exist "%~dp0.reposcout-git\usr\bin\bash.exe" set "PATH=%~dp0.reposcout-git\usr\bin;%PATH%"
exit /b 0
