@echo off
REM ============================================================
REM   Launcher TEST (per sviluppo/QA)
REM   Punta a Data\Manuf accanto al .bat invece del path produzione
REM   C:\ProgramData\Lectra\Manuf.
REM
REM   Include range retention di test: tieni solo i file con
REM   LastWriteTime in [2018-01-01, 2019-01-01]. Tutto cio' che
REM   sta fuori da questa finestra viene cancellato (R7 e R4 ignorano
REM   il range come da design: R7 sempre 7g, R4 sempre).
REM
REM   Per uso cliente usare start.bat (no range, comportamento default).
REM ============================================================
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Cleanup-Manuf.ps1" -ManufRoot "%~dp0Data\Manuf" -RetentionStart 2018-01-01 -RetentionEnd 2019-01-01
exit /b %ERRORLEVEL%
