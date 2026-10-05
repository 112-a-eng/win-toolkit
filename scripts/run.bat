@echo off
rem ============================================================
rem  Windows Command Toolkit - launcher (ASCII only, no BOM)
rem  Double-click this file to open the interactive menu.
rem  The Chinese menu itself is rendered by menu.ps1.
rem ============================================================
chcp 65001 >nul 2>&1
title Windows Command Toolkit

set "HERE=%~dp0"
set "MENU=%HERE%menu.ps1"

if not exist "%MENU%" (
    echo [ERROR] menu.ps1 not found. Keep this file next to the scripts.
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%MENU%" %*
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo [INFO] script exit code: %RC%
    pause
)
exit /b %RC%
