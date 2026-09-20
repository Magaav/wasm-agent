@echo off
setlocal
if /I "%~1"=="setup" goto managed
if /I "%~1"=="doctor" goto managed
if /I "%~1"=="ui" goto managed
"%~dp0..\wa.exe" %*
exit /b %ERRORLEVEL%
:managed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\first-run.ps1" %*
exit /b %ERRORLEVEL%
