@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0no-portal-popup.ps1" %*
echo.
pause
