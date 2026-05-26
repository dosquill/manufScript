@echo off
setlocal
REM ============================================================
REM   Updater - stile "git pull" sul branch main del repo pubblico.
REM   Scarica lo zip del repo, estrae in TEMP, copia tutti i file
REM   tracciati sopra quelli locali (incluso questo stesso .bat).
REM
REM   Per gestire il self-replace di update.bat usa un trampoline:
REM   scrive uno script PowerShell in %TEMP%, lo lancia in finestra
REM   separata e termina subito (sblocco file lock).
REM ============================================================

set "REPO_ZIP_URL=https://github.com/dosquill/manufScript/archive/refs/heads/main.zip"
set "TARGET_DIR=%~dp0"
set "HELPER=%TEMP%\manufScript-update-%RANDOM%-%RANDOM%.ps1"

REM Costruisce lo script PowerShell helper (qui i ^ servono per gli speciali).
(
echo $ErrorActionPreference = 'Stop'
echo $repoUrl   = '%REPO_ZIP_URL%'
echo $targetDir = '%TARGET_DIR%'
echo $tmpRoot   = Join-Path $env:TEMP ^('manufScript-update-' + ^(New-Guid^).Guid^)
echo $zipPath   = Join-Path $tmpRoot 'main.zip'
echo $extractTo = Join-Path $tmpRoot 'unzipped'
echo $backupDir = Join-Path $targetDir ^('_pre-update-backup-' + ^(Get-Date -Format 'yyyyMMdd-HHmmss'^)^)
echo.
echo Write-Host ''
echo Write-Host '============================================================' -ForegroundColor Cyan
echo Write-Host ' AGGIORNAMENTO repo manufScript' -ForegroundColor Cyan
echo Write-Host '============================================================' -ForegroundColor Cyan
echo Write-Host ^(' Sorgente : ' + $repoUrl^)
echo Write-Host ^(' Target   : ' + $targetDir^)
echo Write-Host ''
echo.
echo Start-Sleep -Seconds 1
echo New-Item -ItemType Directory -Path $tmpRoot -Force ^| Out-Null
echo.
echo try {
echo     Write-Host 'Download zip...' -ForegroundColor Cyan
echo     Invoke-WebRequest -Uri $repoUrl -OutFile $zipPath -UseBasicParsing
echo     Write-Host ^('  ' + ^(Get-Item $zipPath^).Length + ' bytes scaricati'^)
echo.
echo     Write-Host 'Estrazione...' -ForegroundColor Cyan
echo     Expand-Archive -LiteralPath $zipPath -DestinationPath $extractTo -Force
echo     $srcRoot = Get-ChildItem -LiteralPath $extractTo -Directory ^| Select-Object -First 1
echo     if ^(-not $srcRoot^) { throw 'zip estratto vuoto' }
echo.
echo     # Backup pre-update: copia i file correnti in _pre-update-backup-^<ts^>/
echo     Write-Host 'Backup pre-update...' -ForegroundColor Cyan
echo     New-Item -ItemType Directory -Path $backupDir -Force ^| Out-Null
echo     Get-ChildItem -LiteralPath $srcRoot.FullName -File ^| ForEach-Object {
echo         $existing = Join-Path $targetDir $_.Name
echo         if ^(Test-Path -LiteralPath $existing^) {
echo             Copy-Item -LiteralPath $existing -Destination ^(Join-Path $backupDir $_.Name^) -Force
echo         }
echo     }
echo.
echo     Write-Host 'Copia file aggiornati...' -ForegroundColor Cyan
echo     $count = 0
echo     Get-ChildItem -LiteralPath $srcRoot.FullName -File ^| ForEach-Object {
echo         Copy-Item -LiteralPath $_.FullName -Destination ^(Join-Path $targetDir $_.Name^) -Force
echo         Write-Host ^('  ' + $_.Name^)
echo         $count++
echo     }
echo.
echo     Write-Host ''
echo     Write-Host ^('OK: ' + $count + ' file aggiornati.'^) -ForegroundColor Green
echo     Write-Host ^('Backup pre-update in: ' + $backupDir^) -ForegroundColor Green
echo } catch {
echo     Write-Host ''
echo     Write-Host ^('ERRORE: ' + $_.Exception.Message^) -ForegroundColor Red
echo     Write-Host 'I file locali NON sono stati modificati.' -ForegroundColor Red
echo     $LASTEXITCODE = 1
echo } finally {
echo     if ^(Test-Path -LiteralPath $tmpRoot^) {
echo         Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
echo     }
echo     Write-Host ''
echo     Read-Host 'Premi INVIO per chiudere'
echo }
) > "%HELPER%"

REM Lancia il PowerShell helper in finestra separata, poi chiudi questo .bat
REM cosi' il file update.bat viene rilasciato e puo' essere sovrascritto.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HELPER%"
exit /b 0
