@echo off
rem ============================================================
rem  Windows Toolkit - GUI launcher (ASCII only, no BOM)
rem  Double-click this file to open the graphical toolkit.
rem ============================================================
chcp 65001 >nul 2>&1
title Windows Toolkit GUI

set "HERE=%~dp0"
set "GUI="

rem This folder holds exactly one .ps1 (the GUI); other scripts are in .\scripts\
rem Discover it by wildcard so this file stays pure ASCII and encoding-proof.
for %%F in ("%HERE%*.ps1") do if not exist "%GUI%" set "GUI=%%~fF"

if not exist "%GUI%" (
    echo [ERROR] GUI script not found. Keep this file next to the toolkit.
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%GUI%"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo [INFO] exit code: %RC%
    pause
)
exit /b %RC%