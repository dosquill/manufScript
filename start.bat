@echo off
REM Copyright (c) 2026 Domenico Di Squillante
REM Licensed under MIT - see LICENSE
REM ============================================================
REM   Launcher Cleanup-Manuf.ps1
REM   Bypassa la ExecutionPolicy locale per evitare blocchi.
REM   Non richiede privilegi amministrativi.
REM ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Cleanup-Manuf.ps1"
exit /b %ERRORLEVEL%
