@echo off
rem Double-click launcher for install.ps1 (keep this file ASCII-only).
rem Usage: install.bat [device-ip] [-OverwriteConfig]
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
