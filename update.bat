@echo off
setlocal
REM Copyright (c) 2026 Domenico Di Squillante
REM Licensed under MIT - see LICENSE
REM ============================================================
REM   Updater - stile "git pull" sul branch main del repo pubblico.
REM   1) Chiede a GitHub API qual e' il SHA del commit corrente di main.
REM   2) Lo confronta con quello salvato in .last-update-sha locale.
REM      - Match  -> sei gia' aggiornato, exit.
REM      - Diverso -> scarica zip, estrae, sostituisce i file locali.
REM
REM   Per gestire il self-replace di update.bat usa un trampoline:
REM   scrive uno script PowerShell in %TEMP%, lo lancia in finestra
REM   separata e termina subito (sblocco file lock).
REM ============================================================

set "REPO_API_URL=https://api.github.com/repos/dosquill/manufScript/commits/main"
set "REPO_ZIP_URL=https://github.com/dosquill/manufScript/archive/refs/heads/main.zip"
set "TARGET_DIR=%~dp0"
set "HELPER=%TEMP%\manufScript-update-%RANDOM%-%RANDOM%.ps1"

REM Costruisce lo script PowerShell helper (qui i ^ servono per gli speciali).
(
echo $ErrorActionPreference = 'Stop'
echo [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
echo $apiUrl    = '%REPO_API_URL%'
echo $repoUrl   = '%REPO_ZIP_URL%'
echo $targetDir = '%TARGET_DIR%'
echo $shaFile   = Join-Path $targetDir '.last-update-sha'
echo $tmpRoot   = Join-Path $env:TEMP ^('manufScript-update-' + ^(New-Guid^).Guid^)
echo $zipPath   = Join-Path $tmpRoot 'main.zip'
echo $extractTo = Join-Path $tmpRoot 'unzipped'
echo $backupDir = Join-Path $targetDir ^('_pre-update-backup-' + ^(Get-Date -Format 'yyyyMMdd-HHmmss'^)^)
echo.
echo Write-Host ''
echo Write-Host '============================================================' -ForegroundColor Cyan
echo Write-Host ' AGGIORNAMENTO repo manufScript' -ForegroundColor Cyan
echo Write-Host '============================================================' -ForegroundColor Cyan
echo Write-Host ^(' Target   : ' + $targetDir^)
echo Write-Host ''
echo.
echo Start-Sleep -Seconds 1
echo.
echo try {
echo     Write-Host 'Verifica versione tramite GitHub API...' -ForegroundColor Cyan
echo     $headers = @{ 'User-Agent' = 'manufScript-updater' }
echo     $remoteSha = $null
echo     try {
echo         $resp = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 10
echo         $remoteSha = $resp.sha
echo     } catch {
echo         Write-Host ^('  WARN: API non raggiungibile ^(' + $_.Exception.Message + '^). Procedo col download forzato.'^) -ForegroundColor Yellow
echo     }
echo     $localSha = if ^(Test-Path -LiteralPath $shaFile^) { ^(Get-Content -LiteralPath $shaFile -Raw^).Trim^(^) } else { $null }
echo.
echo     if ^($remoteSha^) { Write-Host ^('  Remote SHA: ' + $remoteSha.Substring^(0,7^)^) }
echo     if ^($localSha^)  { Write-Host ^('  Local  SHA: ' + $localSha.Substring^(0,7^)^) } else { Write-Host '  Local  SHA: ^(mai aggiornato^)' }
echo.
echo     if ^($remoteSha -and $localSha -and $remoteSha -eq $localSha^) {
echo         Write-Host ''
echo         Write-Host 'Sei gia all''ultima versione. Niente da scaricare.' -ForegroundColor Green
echo         Write-Host ''
echo         Read-Host 'Premi INVIO per chiudere'
echo         exit 0
echo     }
echo.
echo     New-Item -ItemType Directory -Path $tmpRoot -Force ^| Out-Null
echo     Write-Host 'Download zip...' -ForegroundColor Cyan
echo     Invoke-WebRequest -Uri $repoUrl -OutFile $zipPath -UseBasicParsing
echo     Write-Host ^('  ' + ^(Get-Item $zipPath^).Length + ' bytes scaricati'^)
echo.
echo     Write-Host 'Estrazione...' -ForegroundColor Cyan
echo     Expand-Archive -LiteralPath $zipPath -DestinationPath $extractTo -Force
echo     $srcRoot = Get-ChildItem -LiteralPath $extractTo -Directory ^| Select-Object -First 1
echo     if ^(-not $srcRoot^) { throw 'zip estratto vuoto' }
echo.
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
echo     if ^($remoteSha^) {
echo         Set-Content -LiteralPath $shaFile -Value $remoteSha -Encoding ASCII -NoNewline
echo         Write-Host ^('SHA salvato: ' + $remoteSha.Substring^(0,7^)^) -ForegroundColor Green
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
