@echo off
:: Runs windows-optimize.ps1 as administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0windows-optimize.ps1"
