@echo off
REM ============================================================
REM   Launcher TEST (per sviluppo/QA)
REM   Punta a una cartella Manuf di test accanto al .bat invece
REM   del path produzione C:\ProgramData\Lectra\Manuf.
REM   Per uso cliente usare start.bat.
REM ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Cleanup-Manuf.ps1" -ManufRoot "%~dp0Data\Manuf"
exit /b %ERRORLEVEL%
