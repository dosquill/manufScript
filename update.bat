@echo off
setlocal
REM ============================================================
REM   Updater Cleanup-Manuf.ps1
REM   Scarica l'ultima versione da GitHub (repo pubblico).
REM   La versione precedente viene salvata come .bak per rollback.
REM ============================================================
set "REPO_URL=https://raw.githubusercontent.com/dosquill/manufScript/main/Cleanup-Manuf.ps1"
set "TARGET=%~dp0Cleanup-Manuf.ps1"
set "BACKUP=%~dp0Cleanup-Manuf.ps1.bak"
set "TMP=%~dp0Cleanup-Manuf.ps1.new"

echo.
echo ============================================================
echo  AGGIORNAMENTO Cleanup-Manuf.ps1
echo ============================================================
echo  Sorgente: %REPO_URL%
echo.

if exist "%TARGET%" (
    copy /Y "%TARGET%" "%BACKUP%" >nul
    echo Backup vecchia versione: %BACKUP%
)

echo Download in corso...
curl -L -f -s -o "%TMP%" "%REPO_URL%"
if errorlevel 1 (
    echo.
    echo ERRORE: download fallito. Verifica la connessione internet.
    if exist "%TMP%" del "%TMP%"
    echo.
    pause
    exit /b 1
)

move /Y "%TMP%" "%TARGET%" >nul
echo OK: Cleanup-Manuf.ps1 aggiornato.
echo.
pause
endlocal
