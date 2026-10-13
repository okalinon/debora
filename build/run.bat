@echo off
:: Debora launcher: opens the window with administrator rights
:: (without rights: one UAC request straight for Debora, no second pass through this file)
net session >nul 2>&1
if %errorlevel% neq 0 (
    set "D9_SCRIPT=%~dp0Debora.ps1"
    powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"' + $env:D9_SCRIPT + '\" -Gui')"
    exit /b
)
cd /d "%~dp0"
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Debora.ps1" -Gui
