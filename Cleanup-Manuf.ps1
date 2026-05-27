#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ManufRoot = 'C:\ProgramData\Lectra\Manuf',
    [string]$ReferenceDate,
    [string]$RetentionStart,
    [string]$RetentionEnd,
    [switch]$Execute,
    [string]$BackupDir,
    [switch]$NoBackup,
    [string]$LogDir,
    # Path destinazione della copia POST-cleanup (Manuf ripulita).
    # Se non passato e in modalita' interattiva, viene chiesta a video con
    # fallback Desktop\Manuf_<timestamp>. Per disabilitare passare -NoPostBackup.
    [string]$PostBackupDir,
    [switch]$NoPostBackup,
    # Flag interno: settato quando lo script si rilancia da solo dopo un dry-run
    # confermato dall'utente, per saltare la conferma 'SI' duplicata.
    [switch]$PostDryRun
)

# Menu interattivo se -Execute NON e' stato passato esplicitamente.
# Trigger anche con altri parametri (es. -ManufRoot via start-test.bat): l'utente
# sceglie comunque dry-run vs execute via menu. Per saltare il menu da CLI:
#   powershell -File ... -Execute        -> esecuzione diretta
#   powershell -File ... -Execute:$false -> dry-run diretto
if (-not $PSBoundParameters.ContainsKey('Execute')) {
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host " Cleanup Manuf - modalita' interattiva" -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host " 1. Anteprima (dry-run)  - mostra cosa verrebbe cancellato"
    Write-Host " 2. Esegui cancellazione - cancella davvero (irreversibile)"
    Write-Host " 3. Esci"
    Write-Host ""
    $scelta = Read-Host "Scelta [1/2/3]"
    switch ($scelta) {
        '1' { $Execute = $false }
        '2' { $Execute = $true }
        '3' { Write-Host "Uscita."; exit 0 }
        default { Write-Host "Scelta non valida. Uscita." -ForegroundColor Yellow; exit 1 }
    }
}

$ErrorActionPreference = 'Stop'
$exitCode = 0

try {

# Validazione mutua esclusione e completezza
if ($ReferenceDate -and ($RetentionStart -or $RetentionEnd)) {
    throw "Parametri mutuamente esclusivi: -ReferenceDate non puo' coesistere con -RetentionStart/-RetentionEnd."
}
if (($RetentionStart -and -not $RetentionEnd) -or ($RetentionEnd -and -not $RetentionStart)) {
    throw "Se si usa il range retention vanno specificati ENTRAMBI -RetentionStart e -RetentionEnd."
}

if (-not (Test-Path -LiteralPath $ManufRoot -PathType Container)) {
    throw "ManufRoot non trovato o non e' una cartella: $ManufRoot"
}
$ManufRoot = (Resolve-Path -LiteralPath $ManufRoot).Path

# Guardrail: la cartella deve chiamarsi "Manuf" (case-insensitive)
$manufLeaf = Split-Path -Leaf $ManufRoot
if ($manufLeaf -inotmatch '^Manuf$') {
    throw "Cartella non valida. Atteso nome 'Manuf', trovato: '$manufLeaf'. Path: $ManufRoot"
}

# Hostname runtime (chiesto al sistema, non input utente)
$hostname = $env:COMPUTERNAME

if (-not $LogDir) { $LogDir = Join-Path $PSScriptRoot 'Logs' }
if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
$timestamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
# Un solo file di log per run: contiene sia il log robocopy (durante backup)
# sia il summary leggibile (appeso a fine esecuzione).
$script:logFile = Join-Path $LogDir "cleanup-$timestamp.log"
$logFile = $script:logFile

if (-not $BackupDir) {
    $BackupDir = "C:\ProgramData\Lectra\Manuf_backup_$timestamp"
}

# Stato globale per stats e per-regola
$script:stats = @{ Matched = 0; Deleted = 0; Skipped = 0; Errors = 0; DryRun = 0 }
$script:perRuleExpected = [ordered]@{ 'R1'=0; 'R2'=0; 'R3'=0; 'R4'=0; 'R5'=0; 'R6'=0; 'R7'=0 }
$script:perRuleDeleted  = [ordered]@{ 'R1'=0; 'R2'=0; 'R3'=0; 'R4'=0; 'R5'=0; 'R6'=0; 'R7'=0 }
$script:perRuleErrors   = [ordered]@{ 'R1'=0; 'R2'=0; 'R3'=0; 'R4'=0; 'R5'=0; 'R6'=0; 'R7'=0 }
$script:perRuleResidue  = [ordered]@{ 'R1'=0; 'R2'=0; 'R3'=0; 'R4'=0; 'R5'=0; 'R6'=0; 'R7'=0 }
$script:totalExpected = 0
$script:totalResidue  = 0

function Write-Log {
    # Scrive solo su file (script:logFile). Niente output a console: le poche righe
    # davvero utili a video sono stampate esplicitamente con Write-Host nei punti chiave.
    param([string]$Rule, [string]$Tag, [string]$Message)
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] [{2}] {3}" -f (Get-Date), $Rule, $Tag, $Message
    if ($script:logFile) {
        try { Add-Content -LiteralPath $script:logFile -Value $line -Encoding UTF8 } catch {}
    }
}

# Test centralizzato: il file va cancellato secondo cutoff classico O range retention.
function Test-ShouldDelete {
    param(
        [datetime]$When,
        [Nullable[datetime]]$KeepStart,
        [Nullable[datetime]]$KeepEnd,
        [Nullable[datetime]]$Cutoff
    )
    if ($KeepStart -and $KeepEnd) {
        return ($When -lt $KeepStart -or $When -gt $KeepEnd)
    }
    if ($Cutoff) {
        return ($When -lt $Cutoff)
    }
    return $true
}

function Remove-ByPattern {
    param(
        [string]$Rule,
        [string]$Dir,
        [string[]]$Patterns,
        [Nullable[datetime]]$Cutoff,
        [Nullable[datetime]]$KeepStart,
        [Nullable[datetime]]$KeepEnd,
        [switch]$Recurse
    )

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        Write-Log -Rule $Rule -Tag 'SKIP' -Message "path non trovato: $Dir"
        $script:stats.Skipped++
        return
    }

    $files = @()
    foreach ($pattern in $Patterns) {
        try {
            $found = Get-ChildItem -LiteralPath $Dir -Filter $pattern -File -Recurse:$Recurse -ErrorAction Stop
            if ($found) { $files += $found }
        } catch {
            Write-Log -Rule $Rule -Tag 'ERROR' -Message "Get-ChildItem fallito su $Dir con pattern $pattern : $($_.Exception.Message)"
            $script:stats.Errors++
        }
    }

    $files = @($files | Sort-Object -Property FullName -Unique)
    $total = $files.Count
    $i = 0
    $progressId = [Math]::Abs($Rule.GetHashCode()) % 1000

    foreach ($f in $files) {
        $i++
        if ($total -gt 0 -and ($i % 25 -eq 0 -or $i -eq $total)) {
            Write-Progress -Id $progressId -Activity "Regola $Rule" -Status "$i / $total" -PercentComplete (($i / $total) * 100)
        }

        if (-not (Test-ShouldDelete -When $f.LastWriteTime -KeepStart $KeepStart -KeepEnd $KeepEnd -Cutoff $Cutoff)) {
            continue
        }

        $script:stats.Matched++

        if ($Execute) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $script:stats.Deleted++
                $script:perRuleDeleted[$Rule]++
            } catch {
                Write-Log -Rule $Rule -Tag 'ERROR' -Message "$($f.FullName) : $($_.Exception.Message)"
                $script:stats.Errors++
                $script:perRuleErrors[$Rule]++
            }
        } else {
            $script:stats.DryRun++
        }
    }

    Write-Progress -Id $progressId -Activity "Regola $Rule" -Completed
}

function Clear-TransitFolder {
    param([string]$Rule, [string]$Dir)

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        Write-Log -Rule $Rule -Tag 'SKIP' -Message "path non trovato: $Dir"
        $script:stats.Skipped++
        return
    }

    try {
        $items = Get-ChildItem -LiteralPath $Dir -Force -ErrorAction Stop
    } catch {
        Write-Log -Rule $Rule -Tag 'ERROR' -Message "Get-ChildItem fallito su $Dir : $($_.Exception.Message)"
        $script:stats.Errors++
        return
    }

    $items = @($items)
    $total = $items.Count
    $i = 0
    $progressId = [Math]::Abs($Rule.GetHashCode()) % 1000

    foreach ($item in $items) {
        $i++
        if ($total -gt 0 -and ($i % 25 -eq 0 -or $i -eq $total)) {
            Write-Progress -Id $progressId -Activity "Regola $Rule (Transit)" -Status "$i / $total" -PercentComplete (($i / $total) * 100)
        }

        $script:stats.Matched++
        if ($Execute) {
            try {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                $script:stats.Deleted++
                $script:perRuleDeleted[$Rule]++
            } catch {
                Write-Log -Rule $Rule -Tag 'ERROR' -Message "$($item.FullName) : $($_.Exception.Message)"
                $script:stats.Errors++
                $script:perRuleErrors[$Rule]++
            }
        } else {
            $script:stats.DryRun++
        }
    }

    Write-Progress -Id $progressId -Activity "Regola $Rule (Transit)" -Completed
}

function Get-MatchCount {
    param(
        [string]$Dir,
        [string[]]$Patterns,
        [Nullable[datetime]]$Cutoff,
        [Nullable[datetime]]$KeepStart,
        [Nullable[datetime]]$KeepEnd,
        [switch]$Recurse
    )
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return 0 }
    if (-not $Patterns -or $Patterns.Count -eq 0) { return 0 }
    $tot = 0
    foreach ($p in $Patterns) {
        $files = @(Get-ChildItem -LiteralPath $Dir -Filter $p -File -Recurse:$Recurse -ErrorAction SilentlyContinue)
        $files = @($files | Where-Object {
            Test-ShouldDelete -When $_.LastWriteTime -KeepStart $KeepStart -KeepEnd $KeepEnd -Cutoff $Cutoff
        })
        $tot += $files.Count
    }
    return $tot
}

function Get-MatchCountTransit {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue).Count
}

# Backup via robocopy: multi-thread, retry, log su file. Ritorna l'exit code di robocopy
# (0..7 = OK; >=8 = errore).
function Backup-ManufRoot {
    param([string]$Source, [string]$Dest, [string]$LogFile)
    if (Test-Path -LiteralPath $Dest) {
        throw "Destinazione backup gia' esistente: $Dest. Specifica un -BackupDir diverso o cancella la precedente."
    }
    $rcArgs = @(
        $Source, $Dest,
        '/E', '/COPY:DAT', '/R:2', '/W:5', '/MT:16',
        '/NFL', '/NDL', '/NJH', '/NP',
        "/LOG+:$LogFile"
    )
    # Out-Null: silenzia output robocopy sulla console (il dettaglio va comunque
    # nel log via /LOG+:$LogFile). Pipeline di ritorno rimane pulita per $LASTEXITCODE.
    & robocopy @rcArgs | Out-Null
    return $LASTEXITCODE
}

# Parsing reference date / range retention. Solo formato yyyy-MM-dd (ora 00:00:00).
$allowedDateFormat = 'yyyy-MM-dd'
if ($ReferenceDate) {
    try {
        $now = [datetime]::ParseExact(
            $ReferenceDate, $allowedDateFormat,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None)
    } catch {
        throw "ReferenceDate formato non valido: '$ReferenceDate'. Formato atteso: $allowedDateFormat (esempio: 2026-05-25)"
    }
    $dateSource = "override: $ReferenceDate"
} else {
    $now = (Get-Date).Date
    $dateSource = 'oggi'
}

$retentionMode = 'default'
$keepStartDate = $null
$keepEndDate   = $null
if ($RetentionStart -and $RetentionEnd) {
    try {
        $keepStartDate = [datetime]::ParseExact(
            $RetentionStart, $allowedDateFormat,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None)
    } catch {
        throw "RetentionStart formato non valido: '$RetentionStart'. Formato atteso: $allowedDateFormat"
    }
    try {
        $keepEndDate = [datetime]::ParseExact(
            $RetentionEnd, $allowedDateFormat,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None)
    } catch {
        throw "RetentionEnd formato non valido: '$RetentionEnd'. Formato atteso: $allowedDateFormat"
    }
    if ($keepStartDate -gt $keepEndDate) {
        throw "RetentionStart ($RetentionStart) non puo' essere posteriore a RetentionEnd ($RetentionEnd)."
    }
    $retentionMode = 'range'
}

$sixMonthsAgo = $now.AddMonths(-6)
$oneWeekAgo   = $now.AddDays(-7)

# Auto-detect seriale (prefisso degli zip in Pilot\Data\Routine)
$routineDir = Join-Path $ManufRoot 'PILOT\DATA\ROUTINE'
$resolvedSerial = $null
if (Test-Path -LiteralPath $routineDir -PathType Container) {
    $zipFiles = @(Get-ChildItem -LiteralPath $routineDir -Filter '*.zip' -File -ErrorAction SilentlyContinue)
    if ($zipFiles.Count -gt 0) {
        $prefixes = @($zipFiles | ForEach-Object { ($_.Name -split '_')[0] } | Sort-Object -Unique)
        if ($prefixes.Count -eq 1) {
            $resolvedSerial = $prefixes[0]
        } else {
            throw "Auto-detect seriale: trovati $($prefixes.Count) prefissi diversi in Routine ($($prefixes -join ', ')). Atteso 1 solo seriale per host. Possibile data corruption - verificare manualmente."
        }
    }
}

# Enumera TUTTI gli host in MarkerStore (R3 multi-host)
$markerStoreRoot = Join-Path $ManufRoot 'EVENTSMANAGER\DATA\MARKERSTORE'
$markerStoreHosts = @()
if (Test-Path -LiteralPath $markerStoreRoot -PathType Container) {
    $markerStoreHosts = @(Get-ChildItem -LiteralPath $markerStoreRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
}
$markerStoreHostNames = @($markerStoreHosts | ForEach-Object { $_.Name })

# Banner di startup
$modeLabel = if ($Execute) { 'EXECUTE' } else { 'DRY-RUN' }
$retentionLabel = if ($retentionMode -eq 'range') {
    "range [{0:yyyy-MM-dd} .. {1:yyyy-MM-dd}] + R7 7g + R4 sempre" -f $keepStartDate, $keepEndDate
} else {
    "default 6m + R7 7g + R4 sempre"
}
$backupLabel = if (-not $Execute) {
    "(skip - dry-run)"
} elseif ($NoBackup) {
    "DISABILITATO (-NoBackup)"
} else {
    $BackupDir
}
$markerLabel = if ($markerStoreHostNames.Count -gt 0) { $markerStoreHostNames -join ', ' } else { '(nessuna sottocartella)' }
$serialLabel = if ($resolvedSerial) { $resolvedSerial } else { '(non risolto - R7 skip)' }

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " CLEANUP-MANUF" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host (" Modalita'      : {0}" -f $modeLabel)
Write-Host (" Cartella Manuf : {0}" -f $ManufRoot)
Write-Host (" Hostname       : {0}" -f $hostname)
Write-Host (" Seriale        : {0}" -f $serialLabel)
Write-Host (" MarkerStore    : {0}" -f $markerLabel)
Write-Host (" Riferimento    : {0:yyyy-MM-dd} ({1})" -f $now, $dateSource)
Write-Host (" Retention      : {0}" -f $retentionLabel)
Write-Host (" Backup         : {0}" -f $backupLabel)
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Log -Rule '---' -Tag 'START'     -Message "Mode=$modeLabel ManufRoot=$ManufRoot Host=$hostname Serial=$serialLabel"
Write-Log -Rule '---' -Tag 'REFDATE'   -Message ("Ref={0:yyyy-MM-dd} Source={1}" -f $now, $dateSource)
Write-Log -Rule '---' -Tag 'RETENTION' -Message $retentionLabel
Write-Log -Rule '---' -Tag 'CUTOFF'    -Message ("6m={0:yyyy-MM-dd} 7d={1:yyyy-MM-dd}" -f $sixMonthsAgo, $oneWeekAgo)
Write-Log -Rule '---' -Tag 'MARKER'    -Message ("MarkerStore hosts: {0}" -f $markerLabel)

# Conferma -Execute
if ($Execute) {
    if ($PostDryRun) {
        # L'utente ha gia' confermato dopo il dry-run nello stesso flusso, salta la doppia conferma.
        Write-Log -Rule '---' -Tag 'CONFIRM' -Message "Esecuzione confermata via dry-run preview (PostDryRun)"
    } else {
        Write-Host "==============================================================" -ForegroundColor Yellow
        Write-Host " MODALITA' -EXECUTE: cancellazione PERMANENTE (no Cestino)" -ForegroundColor Yellow
        if (-not $NoBackup) {
            Write-Host (" Backup automatico in: {0}" -f $BackupDir) -ForegroundColor Yellow
        } else {
            Write-Host " ATTENZIONE: backup DISABILITATO (-NoBackup)" -ForegroundColor Red
        }
        Write-Host "==============================================================" -ForegroundColor Yellow
        $confirm = Read-Host "Confermare la cancellazione? Scrivere 'SI' (qualsiasi altra risposta annulla)"
        if ($confirm -cne 'SI') {
            Write-Log -Rule '---' -Tag 'ABORT' -Message "Esecuzione annullata dall'utente (risposta: '$confirm')"
            Write-Host "Esecuzione annullata." -ForegroundColor Cyan
            return
        }
        Write-Log -Rule '---' -Tag 'CONFIRM' -Message "Utente ha confermato -Execute"
    }
}

# Backup pre-esecuzione (solo -Execute, opt-out con -NoBackup)
$backupExitCode = $null
$backupSrcCount = 0
$backupDstCount = 0
$backupStatus   = 'N/A (dry-run)'
if ($Execute -and -not $NoBackup) {
    Write-Log -Rule '---' -Tag 'BACKUP' -Message "Avvio robocopy: $ManufRoot -> $BackupDir"
    Write-Host "Backup in corso (robocopy /MT:16). Attendere..." -ForegroundColor Cyan
    $backupExitCode = Backup-ManufRoot -Source $ManufRoot -Dest $BackupDir -LogFile $logFile
    if ($backupExitCode -ge 8) {
        throw "Backup fallito. Robocopy exit code = $backupExitCode. Log: $logFile. Delete NON eseguito."
    }
    $backupSrcCount = @(Get-ChildItem -LiteralPath $ManufRoot -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    $backupDstCount = @(Get-ChildItem -LiteralPath $BackupDir -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    if ($backupSrcCount -ne $backupDstCount) {
        throw "Backup file count mismatch: sorgente=$backupSrcCount destinazione=$backupDstCount. Delete NON eseguito. Log: $logFile"
    }
    $backupStatus = "OK (robocopy exit=$backupExitCode, file=$backupDstCount)"
    Write-Log -Rule '---' -Tag 'BACKUP' -Message "OK exit=$backupExitCode src=$backupSrcCount dst=$backupDstCount"
    Write-Host (" Backup OK: {0} ({1} file)" -f $BackupDir, $backupDstCount) -ForegroundColor Green
} elseif ($Execute -and $NoBackup) {
    $backupStatus = 'disabilitato (-NoBackup)'
}

# Costruzione rules plan
$useRange   = ($retentionMode -eq 'range')
$rangeStart = if ($useRange) { $keepStartDate } else { $null }
$rangeEnd   = if ($useRange) { $keepEndDate }   else { $null }
$r7Patterns = if ($resolvedSerial) { @("$resolvedSerial*.zip") } else { @() }

$rulesPlan = @()
$rulesPlan += [pscustomobject]@{ Id='R1'; Dir=(Join-Path $ManufRoot 'EVENTSMANAGER\DATA');         Patterns=@('PosteRestante*.xml');                       Cutoff=$sixMonthsAgo; KeepStart=$rangeStart; KeepEnd=$rangeEnd; Mode='Pattern'; Recurse=$false }
$rulesPlan += [pscustomobject]@{ Id='R2'; Dir=(Join-Path $ManufRoot 'EVENTSMANAGER\DATA\EVENTS');  Patterns=@('*_NGCEVENTSDATA.xml','*_NGCEVENTSDATA.bak'); Cutoff=$sixMonthsAgo; KeepStart=$rangeStart; KeepEnd=$rangeEnd; Mode='Pattern'; Recurse=$false }
foreach ($h in $markerStoreHosts) {
    # R3: solo direct children dell'host, come da specifica letterale del documento
    # cliente. Multi-host SI (itera ogni host folder), ma niente recursive in sub-dir
    # (es. Photo\) — quelle restano intatte.
    $rulesPlan += [pscustomobject]@{ Id='R3'; Dir=$h.FullName; Patterns=@('Reporting*.xml'); Cutoff=$sixMonthsAgo; KeepStart=$rangeStart; KeepEnd=$rangeEnd; Mode='Pattern'; Recurse=$false }
}
$rulesPlan += [pscustomobject]@{ Id='R4'; Dir=(Join-Path $ManufRoot 'EVENTSMANAGER\DATA\TRANSIT'); Patterns=@();                                           Cutoff=$null;         KeepStart=$null;       KeepEnd=$null;     Mode='Transit'; Recurse=$false }
$rulesPlan += [pscustomobject]@{ Id='R5'; Dir=(Join-Path $ManufRoot 'PILOT\DATA\LAPOSTE');         Patterns=@('PosteRestante_pilot*.xml');                 Cutoff=$sixMonthsAgo; KeepStart=$rangeStart; KeepEnd=$rangeEnd; Mode='Pattern'; Recurse=$false }
$rulesPlan += [pscustomobject]@{ Id='R6'; Dir=(Join-Path $ManufRoot 'PILOT\DATA\REPORT');          Patterns=@('Reporting*.xml','session*.xml');            Cutoff=$sixMonthsAgo; KeepStart=$rangeStart; KeepEnd=$rangeEnd; Mode='Pattern'; Recurse=$false }
$rulesPlan += [pscustomobject]@{ Id='R7'; Dir=(Join-Path $ManufRoot 'PILOT\DATA\ROUTINE');         Patterns=$r7Patterns;                                   Cutoff=$oneWeekAgo;   KeepStart=$null;       KeepEnd=$null;     Mode='Pattern'; Recurse=$false }

# Avviso esplicito se MarkerStore vuota / inesistente
if ($markerStoreHosts.Count -eq 0) {
    Write-Log -Rule 'R3' -Tag 'SKIP' -Message "MarkerStore vuota o non trovata: $markerStoreRoot"
    $script:stats.Skipped++
}

# PRE-SCAN: conteggio atteso per ogni regola (R3 aggrega su tutti gli host con +=)
foreach ($k in @($script:perRuleExpected.Keys)) { $script:perRuleExpected[$k] = 0 }
foreach ($rule in $rulesPlan) {
    if (-not $rule.Dir) { continue }
    if ($rule.Mode -eq 'Transit') {
        $script:perRuleExpected[$rule.Id] = Get-MatchCountTransit -Dir $rule.Dir
    } else {
        $cnt = Get-MatchCount -Dir $rule.Dir -Patterns $rule.Patterns -Cutoff $rule.Cutoff -KeepStart $rule.KeepStart -KeepEnd $rule.KeepEnd -Recurse:$rule.Recurse
        $script:perRuleExpected[$rule.Id] = [int]$script:perRuleExpected[$rule.Id] + [int]$cnt
    }
}
$script:totalExpected = ($script:perRuleExpected.Values | Measure-Object -Sum).Sum
Write-Log -Rule '---' -Tag 'PRESCAN' -Message ("Atteso totale: {0} file" -f $script:totalExpected)
Write-Host (" Pre-scan: {0} file candidati" -f $script:totalExpected) -ForegroundColor Cyan

# APPLY
foreach ($rule in $rulesPlan) {
    if (-not $rule.Dir) {
        Write-Log -Rule $rule.Id -Tag 'SKIP' -Message "regola saltata (path/host non risolti)."
        $script:stats.Skipped++
        continue
    }
    if ($rule.Mode -eq 'Transit') {
        Clear-TransitFolder -Rule $rule.Id -Dir $rule.Dir
    } else {
        if (-not $rule.Patterns -or $rule.Patterns.Count -eq 0) {
            Write-Log -Rule $rule.Id -Tag 'SKIP' -Message "regola saltata (nessun pattern, es. seriale non risolto)."
            $script:stats.Skipped++
            continue
        }
        Remove-ByPattern -Rule $rule.Id -Dir $rule.Dir -Patterns $rule.Patterns -Cutoff $rule.Cutoff -KeepStart $rule.KeepStart -KeepEnd $rule.KeepEnd -Recurse:$rule.Recurse
    }
}

# POST-SCAN (solo execute): re-scan con stessi criteri per verificare residuo.
if ($Execute) {
    foreach ($k in @($script:perRuleResidue.Keys)) { $script:perRuleResidue[$k] = 0 }
    foreach ($rule in $rulesPlan) {
        if (-not $rule.Dir) { continue }
        if ($rule.Mode -eq 'Transit') {
            $script:perRuleResidue[$rule.Id] = Get-MatchCountTransit -Dir $rule.Dir
        } else {
            if (-not $rule.Patterns -or $rule.Patterns.Count -eq 0) { continue }
            $cnt = Get-MatchCount -Dir $rule.Dir -Patterns $rule.Patterns -Cutoff $rule.Cutoff -KeepStart $rule.KeepStart -KeepEnd $rule.KeepEnd -Recurse:$rule.Recurse
            $script:perRuleResidue[$rule.Id] = [int]$script:perRuleResidue[$rule.Id] + [int]$cnt
        }
    }
    $script:totalResidue = ($script:perRuleResidue.Values | Measure-Object -Sum).Sum
    Write-Log -Rule '---' -Tag 'POSTSCAN' -Message ("Residuo totale: {0} file" -f $script:totalResidue)
    $rcCol = if ($script:totalResidue -eq 0) { 'Green' } else { 'Red' }
    Write-Host (" Post-scan: residuo {0} file" -f $script:totalResidue) -ForegroundColor $rcCol
}

# DIFF post-cleanup: confronta backup vs Manuf pulita con Compare-Object.
# Verifica empirica: i file realmente spariti dal disco devono corrispondere a stats.Deleted.
$diffOk             = $true
$reallyDeletedCount = 0
$reallyAddedCount   = 0
$reallyAddedSample  = ''
# Stato iniziale del diff. Sovrascritto sotto se il confronto e' davvero eseguito.
$diffStatus = if (-not $Execute) {
    'N/A (dry-run, niente da confrontare)'
} elseif ($NoBackup) {
    'N/A (-NoBackup: nessun backup di riferimento per il confronto)'
} else {
    'N/A (backup non riuscito)'
}

if ($Execute -and -not $NoBackup -and $null -ne $backupExitCode) {
    Write-Log -Rule '---' -Tag 'DIFF' -Message "Compare-Object backup vs Manuf pulita..."
    $bkLen = $BackupDir.Length
    $mfLen = $ManufRoot.Length
    $bk = @(Get-ChildItem -LiteralPath $BackupDir -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName.Substring($bkLen).TrimStart('\').ToLowerInvariant() })
    $mf = @(Get-ChildItem -LiteralPath $ManufRoot  -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName.Substring($mfLen).TrimStart('\').ToLowerInvariant() })

    $diff = @(Compare-Object -ReferenceObject $bk -DifferenceObject $mf)
    $reallyDeleted = @($diff | Where-Object SideIndicator -eq '<=' | Select-Object -ExpandProperty InputObject)
    $reallyAdded   = @($diff | Where-Object SideIndicator -eq '=>' | Select-Object -ExpandProperty InputObject)
    $reallyDeletedCount = $reallyDeleted.Count
    $reallyAddedCount   = $reallyAdded.Count

    $diffOk = ($reallyDeletedCount -eq $script:stats.Deleted) -and ($reallyAddedCount -eq 0)
    if ($diffOk) {
        $diffStatus = "OK (spariti=$reallyDeletedCount == stats.Deleted=$($script:stats.Deleted), aggiunti=0)"
    } else {
        $diffStatus = "KO (spariti=$reallyDeletedCount, stats.Deleted=$($script:stats.Deleted), aggiunti=$reallyAddedCount)"
        if ($reallyAddedCount -gt 0) {
            $reallyAddedSample = ($reallyAdded | Select-Object -First 5) -join ' | '
            Write-Log -Rule '---' -Tag 'DIFF' -Message "Primi file inattesi: $reallyAddedSample"
        }
    }
    Write-Log -Rule '---' -Tag 'DIFF' -Message $diffStatus
    $diffCol = if ($diffOk) { 'Green' } else { 'Red' }
    Write-Host (" Diff: {0}" -f $diffStatus) -ForegroundColor $diffCol
}

# Copia POST-cleanup della Manuf ripulita in path utente (Desktop default).
# Scopo: snapshot della Manuf pulita per archivio/backup ufficiale del cliente,
# senza i file vecchi che rallentavano la copia manuale via Explorer.
# Backup PRE in ProgramData resta come safety net.
$postBackupStatus = 'N/A (no execute / diff KO)'
if ($Execute -and $diffOk -and -not $NoPostBackup) {
    if (-not $PostBackupDir) {
        $defaultDest = Join-Path ([Environment]::GetFolderPath('Desktop')) "Manuf_$timestamp"
        Write-Host ""
        Write-Host "==============================================================" -ForegroundColor Cyan
        Write-Host " Copia POST-cleanup della Manuf pulita" -ForegroundColor Cyan
        Write-Host "==============================================================" -ForegroundColor Cyan
        Write-Host (" Default (INVIO per accettare): {0}" -f $defaultDest)
        $userPath = Read-Host "Path destinazione (INVIO = default, q = salta)"
        if ($userPath -eq 'q' -or $userPath -eq 'Q') {
            $PostBackupDir = $null
            $postBackupStatus = 'saltata da utente'
            Write-Log -Rule '---' -Tag 'POSTCOPY' -Message "Saltata da utente (q)"
        } elseif ([string]::IsNullOrWhiteSpace($userPath)) {
            $PostBackupDir = $defaultDest
        } else {
            $PostBackupDir = $userPath.Trim('"').Trim("'")
        }
    }

    if ($PostBackupDir) {
        if (Test-Path -LiteralPath $PostBackupDir) {
            Write-Log -Rule '---' -Tag 'POSTCOPY' -Message "Destinazione gia' esistente, skip: $PostBackupDir"
            $postBackupStatus = "KO (destinazione gia' esistente: $PostBackupDir)"
            Write-Host (" ATTENZIONE: {0} gia' esiste, copia saltata." -f $PostBackupDir) -ForegroundColor Yellow
        } else {
            Write-Log -Rule '---' -Tag 'POSTCOPY' -Message "Copia: $ManufRoot -> $PostBackupDir"
            Write-Host (" Copia in corso (robocopy /MT:16) -> {0}" -f $PostBackupDir) -ForegroundColor Cyan
            try {
                $pcCode = Backup-ManufRoot -Source $ManufRoot -Dest $PostBackupDir -LogFile $logFile
                if ($pcCode -ge 8) {
                    $postBackupStatus = "KO (robocopy exit=$pcCode)"
                    Write-Log -Rule '---' -Tag 'POSTCOPY' -Message "FAIL exit=$pcCode"
                    Write-Host (" Copia FALLITA (robocopy exit={0})" -f $pcCode) -ForegroundColor Red
                } else {
                    $pcCount = @(Get-ChildItem -LiteralPath $PostBackupDir -Recurse -File -Force -ErrorAction SilentlyContinue).Count
                    $postBackupStatus = "OK (file=$pcCount, robocopy exit=$pcCode) -> $PostBackupDir"
                    Write-Log -Rule '---' -Tag 'POSTCOPY' -Message "OK exit=$pcCode file=$pcCount"
                    Write-Host (" Copia OK: {0} ({1} file)" -f $PostBackupDir, $pcCount) -ForegroundColor Green
                }
            } catch {
                $postBackupStatus = "KO ($($_.Exception.Message))"
                Write-Log -Rule '---' -Tag 'POSTCOPY' -Message "EXCEPTION: $($_.Exception.Message)"
            }
        }
    }
} elseif ($Execute -and $NoPostBackup) {
    $postBackupStatus = 'disabilitato (-NoPostBackup)'
} elseif ($Execute -and -not $diffOk) {
    $postBackupStatus = 'N/A (diff KO, copia non eseguita)'
}

Write-Log -Rule '---' -Tag 'SUMMARY' -Message ("Matched={0} Deleted={1} DryRun={2} Skipped={3} Errors={4}" -f `
    $script:stats.Matched, $script:stats.Deleted, $script:stats.DryRun, $script:stats.Skipped, $script:stats.Errors)
Write-Log -Rule '---' -Tag 'END'     -Message "Summary: $logFile"

# Generazione summary leggibile su file
$r3HostList = if ($markerStoreHostNames.Count -gt 0) { $markerStoreHostNames -join ', ' } else { '(none)' }
$r7Desc = if ($resolvedSerial) { "ZIP $resolvedSerial* in Routine (>7 giorni)" } else { 'ZIP * in Routine (seriale non risolto - SKIP)' }
$ruleDescriptions = [ordered]@{
    'R1' = 'PosteRestante*.xml in EventsManager\Data         (>6m / range)'
    'R2' = 'NgcEventsData xml + bak in Events                (>6m / range)'
    'R3' = "Reporting*.xml in MarkerStore (>6m/range)  host: $r3HostList"
    'R4' = 'Tutto in Transit (file + sottocartelle)          (sempre)'
    'R5' = 'PosteRestante_Pilot*.xml in LaPoste              (>6m / range)'
    'R6' = 'Reporting*.xml e session*.xml in Report          (>6m / range)'
    'R7' = $r7Desc
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("===================================================================")
$titolo = if ($Execute) { ' ESITO CANCELLAZIONE (EXECUTE)' } else { ' ANTEPRIMA (DRY-RUN)' }
[void]$sb.AppendLine($titolo)
[void]$sb.AppendLine("===================================================================")
[void]$sb.AppendLine(" Cartella   : $ManufRoot")
[void]$sb.AppendLine(" Hostname   : $hostname")
[void]$sb.AppendLine((" Data run   : {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date)))
[void]$sb.AppendLine((" Riferim.   : {0:yyyy-MM-dd} ({1})" -f $now, $dateSource))
[void]$sb.AppendLine(" Retention  : $retentionLabel")
[void]$sb.AppendLine((" Cutoff 6m  : {0:yyyy-MM-dd}" -f $sixMonthsAgo))
[void]$sb.AppendLine((" Cutoff 7d  : {0:yyyy-MM-dd}" -f $oneWeekAgo))
if ($resolvedSerial) {
    [void]$sb.AppendLine(" Seriale    : $resolvedSerial")
} else {
    [void]$sb.AppendLine(" Seriale    : (non risolto)")
}
[void]$sb.AppendLine(" MarkerStore: $r3HostList")
[void]$sb.AppendLine(" Backup     : $backupStatus")
if ($Execute -and -not $NoBackup -and $null -ne $backupExitCode) {
    [void]$sb.AppendLine(" Backup path: $BackupDir")
}
[void]$sb.AppendLine(" Diff       : $diffStatus")
if (-not $diffOk -and $reallyAddedSample) {
    [void]$sb.AppendLine("              file inattesi (primi 5): $reallyAddedSample")
}
[void]$sb.AppendLine(" Post-copy  : $postBackupStatus")
[void]$sb.AppendLine("")

if ($Execute) {
    [void]$sb.AppendLine(" Risultato per regola (atteso=pre-scan, cancellati=delete OK, residuo=post-scan):")
    foreach ($r in $script:perRuleExpected.Keys) {
        $atteso     = [int]$script:perRuleExpected[$r]
        $cancellati = [int]$script:perRuleDeleted[$r]
        $residuo    = [int]$script:perRuleResidue[$r]
        $errori     = [int]$script:perRuleErrors[$r]
        $verdict = if ($cancellati -eq $atteso -and $residuo -eq 0 -and $errori -eq 0) { '[OK]' } else { '[KO]' }
        [void]$sb.AppendLine(("   {0}  {1}  atteso {2,6}  cancellati {3,6}  residuo {4,4}  errori {5,3}  {6}" -f `
            $r, $ruleDescriptions[$r].PadRight(70), $atteso, $cancellati, $residuo, $errori, $verdict))
    }
    [void]$sb.AppendLine("")
    $totAtteso     = [int]$script:totalExpected
    $totCancellati = [int]$script:stats.Deleted
    $totResiduo    = [int]$script:totalResidue
    $totErrori     = [int]$script:stats.Errors
    [void]$sb.AppendLine((" TOTALE  atteso {0}   cancellati {1}   residuo {2}   errori {3}" -f $totAtteso, $totCancellati, $totResiduo, $totErrori))
    $esitoOk = ($totCancellati -eq $totAtteso) -and ($totResiduo -eq 0) -and ($totErrori -eq 0) -and $diffOk
    if ($esitoOk) {
        [void]$sb.AppendLine(" ESITO   OK (cancellati == atteso && residuo == 0 && errori == 0 && diff OK)")
    } else {
        [void]$sb.AppendLine((" ESITO   KO (cancellati {0}/{1}, residuo {2}, errori {3}, diffOk={4})" -f $totCancellati, $totAtteso, $totResiduo, $totErrori, $diffOk))
    }
} else {
    [void]$sb.AppendLine(" Anteprima per regola (file che sarebbero cancellati):")
    foreach ($r in $script:perRuleExpected.Keys) {
        $atteso = [int]$script:perRuleExpected[$r]
        [void]$sb.AppendLine(("   {0}  {1}  trovati {2,6}" -f $r, $ruleDescriptions[$r].PadRight(70), $atteso))
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine((" TOTALE  trovati {0} file" -f [int]$script:totalExpected))
    [void]$sb.AppendLine(" NOTA    in dry-run nessuna verifica reale. Esito disponibile solo con -Execute (post-scan).")
}
[void]$sb.AppendLine((" Saltati : {0} cartelle/pattern" -f $script:stats.Skipped))
[void]$sb.AppendLine("")
[void]$sb.AppendLine(" Log: $logFile")
[void]$sb.AppendLine("===================================================================")

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
# Se il file ha gia' contenuto (log robocopy del backup), il summary va appeso
# preceduto da un separatore visivo. Se il file non esiste, AppendAllText lo crea.
$summarySection = "`r`n" + ('=' * 67) + "`r`n SUMMARY ESECUZIONE`r`n" + ('=' * 67) + "`r`n" + $sb.ToString()
[System.IO.File]::AppendAllText($logFile, $summarySection, $utf8NoBom)

# La tabella completa per-regola e' nel summary file. A console solo il banner
# finale sintetico (sotto), per non sommergere l'utente di dettagli.

# Banner finale
$bAtteso = [int]$script:totalExpected
$bErrori = [int]$script:stats.Errors

if ($Execute) {
    $bCancellati = [int]$script:stats.Deleted
    $bResiduo    = [int]$script:totalResidue
    $bOk = ($bCancellati -eq $bAtteso) -and ($bResiduo -eq 0) -and ($bErrori -eq 0) -and $diffOk
    $bColor = if ($bOk) { 'Green' } else { 'Red' }
    Write-Host "==============================================================" -ForegroundColor $bColor
    Write-Host (" EXECUTE: atteso {0} / cancellati {1} / residuo {2} / errori {3}" -f $bAtteso, $bCancellati, $bResiduo, $bErrori) -ForegroundColor $bColor
    if ($bOk) {
        Write-Host " ESITO: OK (cancellati == atteso, residuo == 0, nessun errore, diff OK)" -ForegroundColor Green
    } else {
        Write-Host " ESITO: KO -- vedere summary per dettagli per regola" -ForegroundColor Red
        $exitCode = 1
    }
    if (-not $NoBackup -and $null -ne $backupExitCode) {
        Write-Host (" Backup : {0}" -f $BackupDir) -ForegroundColor $bColor
    } else {
        Write-Host " Backup : disabilitato (-NoBackup)" -ForegroundColor $bColor
    }
    Write-Host (" Diff   : {0}" -f $diffStatus) -ForegroundColor $bColor
    Write-Host (" Copia  : {0}" -f $postBackupStatus) -ForegroundColor $bColor
    Write-Host " Summary: $logFile" -ForegroundColor $bColor
    Write-Host "==============================================================" -ForegroundColor $bColor
} else {
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host (" DRY-RUN: {0} file candidati alla cancellazione. NESSUNA cancellazione eseguita." -f $bAtteso) -ForegroundColor Cyan
    Write-Host " Summary: $logFile" -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan

    # Prompt post-dry-run: chiedi se procedere con la cancellazione reale.
    # Se l'utente conferma, lo script si rilancia da solo con gli stessi parametri
    # piu' -Execute -PostDryRun (per saltare la conferma 'SI' duplicata).
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Yellow
    Write-Host " Vuoi procedere con la CANCELLAZIONE REALE adesso?" -ForegroundColor Yellow
    if (-not $NoBackup) {
        Write-Host " (verra' creato automaticamente il backup completo prima)" -ForegroundColor Yellow
    } else {
        Write-Host " (ATTENZIONE: backup DISABILITATO via -NoBackup)" -ForegroundColor Red
    }
    Write-Host "==============================================================" -ForegroundColor Yellow
    $proceed = Read-Host "Procedere? Scrivere 'SI' (qualsiasi altra risposta termina senza cancellare)"
    if ($proceed -ceq 'SI') {
        Write-Log -Rule '---' -Tag 'PROCEED' -Message "Utente ha confermato execute via dry-run preview. Rilancio in modalita' execute."
        Write-Host ""
        Write-Host "Rilancio in modalita' EXECUTE..." -ForegroundColor Cyan

        # Costruisci la lista argomenti riportando i parametri originali, senza -Execute,
        # e aggiungendo -Execute -PostDryRun.
        $childArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
        foreach ($k in $PSBoundParameters.Keys) {
            if ($k -eq 'Execute' -or $k -eq 'PostDryRun') { continue }
            $v = $PSBoundParameters[$k]
            if ($v -is [switch]) {
                if ($v.IsPresent) { $childArgs += "-$k" }
            } else {
                $childArgs += "-$k", "$v"
            }
        }
        $childArgs += '-Execute'
        $childArgs += '-PostDryRun'

        & powershell.exe @childArgs
        $exitCode = $LASTEXITCODE
    } else {
        Write-Log -Rule '---' -Tag 'END' -Message "Utente non ha proseguito con execute dopo dry-run."
        Write-Host "Nessuna cancellazione effettuata. Uscita." -ForegroundColor Cyan
    }
}

} catch {
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Red
    Write-Host " ERRORE: lo script si e' fermato." -ForegroundColor Red
    Write-Host " $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "==============================================================" -ForegroundColor Red
    $exitCode = 1
} finally {
    Write-Host ""
    Read-Host "Premi INVIO per uscire"
}
exit $exitCode
