@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tune-wifi.ps1" %*
echo.
pause
