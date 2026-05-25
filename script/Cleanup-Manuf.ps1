<#
.SYNOPSIS
    Pulizia automatica file vecchi nella cartella Manuf (PowerShell 5.1+).

.DESCRIPTION
    Applica 7 regole di cancellazione definite nel documento "file da cancellare su manuf.docx".

    REGOLE APPLICATE (relative a -ManufRoot):
      R1  EventsManager\Data\PosteRestante*.xml             -> piu' vecchi di 6 mesi
      R2  EventsManager\Data\Events\*_NgcEventsData.xml/bak -> piu' vecchi di 6 mesi
      R3  EventsManager\Data\MarkerStore\<host>\Reporting*.xml -> piu' vecchi di 6 mesi
      R4  EventsManager\Data\Transit\*                      -> SEMPRE (file e sottocartelle)
      R5  Pilot\Data\LaPoste\PosteRestante_pilot*.xml       -> piu' vecchi di 6 mesi
      R6  Pilot\Data\Report\Reporting*.xml ; session*.xml   -> piu' vecchi di 6 mesi
      R7  Pilot\Data\Routine\<serial>*.zip                  -> piu' vecchi di 7 giorni

    SICUREZZA:
      - Default = dry-run (nessuna cancellazione, solo simulazione + log).
      - Per cancellare davvero serve -Execute. Operazione IRREVERSIBILE: non passa dal Cestino.
      - Validazione path: la cartella deve chiamarsi "Manuf" (case-insensitive).

    LOG:
      - File dettagliato per ogni run in <ManufRoot>\_cleanup-logs\cleanup-YYYYMMDD-HHmmss.log
      - Una riga per ogni file processato con timestamp, regola, tag (DRYRUN/DELETE/SKIP/ERROR).

.PARAMETER ManufRoot
    Path della cartella Manuf. Obbligatorio. Il nome della cartella deve essere "Manuf".

.PARAMETER Serial
    Seriale della macchina (prefisso dei file ZIP in Pilot\Data\Routine).
    Se omesso: auto-detect dai file presenti. Se ne trova >1 diverso, lo script si ferma
    chiedendo -Serial esplicito.

.PARAMETER Hostname
    Nome host della sottocartella MarkerStore da processare.
    Se omesso: auto-detect (deve esserci 1 sola sottocartella; se 0 -> fallback al
    COMPUTERNAME locale; se >1 -> errore, passa -Hostname esplicito).

.PARAMETER ReferenceDate
    Data di riferimento per calcolo cutoff. Default: oggi.
    Formati accettati:
      yyyy-MM-dd            -> ora impostata a 00:00:00 (mezzanotte)
      yyyy-MM-dd_HH-mm-ss   -> data + ora esplicita (trattini, non due punti)
    Esempi: 2026-05-25  oppure  2026-05-25_14-30-00
    I cutoff diventano: ReferenceDate - 6 mesi (regole 1,2,3,5,6) e - 7 giorni (regola 7).

.PARAMETER Execute
    Se presente, cancella davvero. Senza, solo simulazione (dry-run).

.PARAMETER LogDir
    Cartella per i summary. Default: <directory dello script>\_cleanup-logs.

.EXAMPLE
    .\Cleanup-Manuf.ps1 -ManufRoot 'C:\path\Manuf'
    Anteprima (dry-run) usando data di oggi, seriale e host auto-rilevati. Niente viene cancellato.

.EXAMPLE
    .\Cleanup-Manuf.ps1 -ManufRoot 'C:\path\Manuf' -Execute
    Cancellazione REALE. File rimossi in modo permanente (no Cestino).

.EXAMPLE
    .\Cleanup-Manuf.ps1 -ManufRoot 'C:\path\Manuf' -ReferenceDate '2025-01-01_00-00-00'
    Dry-run simulando di essere al 1 gennaio 2025 (utile per test).

.EXAMPLE
    .\Cleanup-Manuf.ps1 -ManufRoot 'C:\path\Manuf' -Serial '18FE5831' -Hostname 'FAIQ50-768000' -Execute
    Cancellazione reale con seriale e host espliciti (no auto-detect).

.NOTES
    Operazione irreversibile con -Execute: i file NON vanno nel Cestino.
    Raccomandato: sempre prima un dry-run, controllare il file summary, poi -Execute.
    Tra dry-run e -Execute non devono essere creati/modificati file in Manuf (altrimenti
    i conteggi divergono).
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ManufRoot,
    [string]$Serial,
    [string]$Hostname,
    [string]$ReferenceDate,
    [switch]$Execute,
    [string]$LogDir
)

# Modalita' interattiva: se nessun param passato, mostra menu.
if (-not $ManufRoot) {
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host " Cleanup Manuf - modalita' interattiva" -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host " 1. Anteprima (dry-run) - mostra cosa verrebbe cancellato"
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

    $ManufRoot = Read-Host "Path cartella Manuf (es. C:\path\Manuf)"
    if (-not $ManufRoot) { Write-Host "Path mancante. Uscita." -ForegroundColor Yellow; exit 1 }
    $ManufRoot = $ManufRoot.Trim('"').Trim("'")

    Write-Host ""
    Write-Host "Parametri opzionali (premi INVIO per auto-detect):"
    $userSerial = Read-Host "Seriale macchina"
    if ($userSerial) { $Serial = $userSerial }
    $userHostname = Read-Host "Nome Host"
    if ($userHostname) { $Hostname = $userHostname }
    Write-Host ""
}

$ErrorActionPreference = 'Stop'
$exitCode = 0

try {

if (-not (Test-Path -LiteralPath $ManufRoot -PathType Container)) {
    throw "ManufRoot non trovato o non e' una cartella: $ManufRoot"
}
$ManufRoot = (Resolve-Path -LiteralPath $ManufRoot).Path

# Guardrail: la cartella deve chiamarsi "Manuf" (case-insensitive)
$manufLeaf = Split-Path -Leaf $ManufRoot
if ($manufLeaf -inotmatch '^Manuf$') {
    throw "Cartella non valida. Atteso nome 'Manuf', trovato: '$manufLeaf'. Path: $ManufRoot"
}

if (-not $LogDir) { $LogDir = Join-Path $PSScriptRoot '_cleanup-logs' }
if (-not (Test-Path -LiteralPath $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
$summaryFile = Join-Path $LogDir ("cleanup-{0:yyyyMMdd-HHmmss}.summary.txt" -f (Get-Date))

$script:stats = @{ Matched = 0; Deleted = 0; Skipped = 0; Errors = 0; DryRun = 0 }
$script:perRule = [ordered]@{
    'R1' = 0; 'R2' = 0; 'R3' = 0; 'R4' = 0; 'R5' = 0; 'R6' = 0; 'R7' = 0
}
$script:perRuleDeleted = [ordered]@{
    'R1' = 0; 'R2' = 0; 'R3' = 0; 'R4' = 0; 'R5' = 0; 'R6' = 0; 'R7' = 0
}
$script:perRuleErrors = [ordered]@{
    'R1' = 0; 'R2' = 0; 'R3' = 0; 'R4' = 0; 'R5' = 0; 'R6' = 0; 'R7' = 0
}
$script:perRuleDryRun = [ordered]@{
    'R1' = 0; 'R2' = 0; 'R3' = 0; 'R4' = 0; 'R5' = 0; 'R6' = 0; 'R7' = 0
}

function Write-Log {
    param([string]$Rule, [string]$Tag, [string]$Message)
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] [{2}] {3}" -f (Get-Date), $Rule, $Tag, $Message
    Write-Host $line
}

function Remove-ByPattern {
    param(
        [string]$Rule,
        [string]$Dir,
        [string[]]$Patterns,
        [Nullable[datetime]]$Cutoff
    )

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        Write-Log -Rule $Rule -Tag 'SKIP' -Message "path non trovato: $Dir"
        $script:stats.Skipped++
        return
    }

    $files = @()
    foreach ($pattern in $Patterns) {
        try {
            $found = Get-ChildItem -LiteralPath $Dir -Filter $pattern -File -ErrorAction Stop
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

        if ($Cutoff -and $f.LastWriteTime -ge $Cutoff) { continue }

        $script:stats.Matched++
        if ($script:perRule.Contains($Rule)) { $script:perRule[$Rule]++ }

        if ($Execute) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $script:stats.Deleted++
                if ($script:perRuleDeleted.Contains($Rule)) { $script:perRuleDeleted[$Rule]++ }
            } catch {
                Write-Log -Rule $Rule -Tag 'ERROR' -Message "$($f.FullName) : $($_.Exception.Message)"
                $script:stats.Errors++
                if ($script:perRuleErrors.Contains($Rule)) { $script:perRuleErrors[$Rule]++ }
            }
        } else {
            $script:stats.DryRun++
            if ($script:perRuleDryRun.Contains($Rule)) { $script:perRuleDryRun[$Rule]++ }
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
        if ($script:perRule.Contains($Rule)) { $script:perRule[$Rule]++ }
        if ($Execute) {
            try {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                $script:stats.Deleted++
                if ($script:perRuleDeleted.Contains($Rule)) { $script:perRuleDeleted[$Rule]++ }
            } catch {
                Write-Log -Rule $Rule -Tag 'ERROR' -Message "$($item.FullName) : $($_.Exception.Message)"
                $script:stats.Errors++
                if ($script:perRuleErrors.Contains($Rule)) { $script:perRuleErrors[$Rule]++ }
            }
        } else {
            $script:stats.DryRun++
            if ($script:perRuleDryRun.Contains($Rule)) { $script:perRuleDryRun[$Rule]++ }
        }
    }

    Write-Progress -Id $progressId -Activity "Regola $Rule (Transit)" -Completed
}

# Reference date: default = oggi. Override via -ReferenceDate.
# Formati accettati:
#   yyyy-MM-dd            -> ora = 00:00:00 (mezzanotte)
#   yyyy-MM-dd_HH-mm-ss   -> ora esplicita (trattini, non due punti)
[string[]]$allowedDateFormats = @('yyyy-MM-dd_HH-mm-ss', 'yyyy-MM-dd')
if ($ReferenceDate) {
    try {
        $now = [datetime]::ParseExact(
            [string]$ReferenceDate,
            [string[]]$allowedDateFormats,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None
        )
    } catch {
        throw "ReferenceDate formato non valido: '$ReferenceDate'. Formati accettati: $($allowedDateFormats -join ' | ') (esempi: 2026-05-25 oppure 2026-05-25_14-30-00)"
    }
    $dateSource = "override: $ReferenceDate"
} else {
    $now = Get-Date
    $dateSource = 'now'
}
$sixMonthsAgo = $now.AddMonths(-6)
$oneWeekAgo   = $now.AddDays(-7)

$mode = if ($Execute) { 'EXECUTE' } else { 'DRY-RUN' }
Write-Log -Rule '---'  -Tag 'START'  -Message "Mode=$mode ManufRoot=$ManufRoot Host=$env:COMPUTERNAME"
Write-Log -Rule '---'  -Tag 'REFDATE' -Message ("Ref={0:yyyy-MM-dd HH:mm:ss} Source={1}" -f $now, $dateSource)
Write-Log -Rule '---'  -Tag 'CUTOFF' -Message ("6m={0:yyyy-MM-dd HH:mm:ss} 7d={1:yyyy-MM-dd HH:mm:ss}" -f $sixMonthsAgo, $oneWeekAgo)

# Serial resolution: -Serial esplicito > auto-detect da Pilot\Data\Routine\*.zip
$routineDir = Join-Path $ManufRoot 'PILOT\DATA\ROUTINE'
$resolvedSerial = $null
if ($Serial) {
    $resolvedSerial = $Serial
    Write-Log -Rule '---' -Tag 'SERIAL' -Message "override: $Serial"
} elseif (Test-Path -LiteralPath $routineDir -PathType Container) {
    $zipFiles = @(Get-ChildItem -LiteralPath $routineDir -Filter '*.zip' -File -ErrorAction SilentlyContinue)
    if ($zipFiles.Count -eq 0) {
        Write-Log -Rule '---' -Tag 'SERIAL' -Message "WARN: nessun zip in Routine. R7 sara' skippato."
    } else {
        $prefixes = @($zipFiles | ForEach-Object { ($_.Name -split '_')[0] } | Sort-Object -Unique)
        if ($prefixes.Count -eq 1) {
            $resolvedSerial = $prefixes[0]
            Write-Log -Rule '---' -Tag 'SERIAL' -Message "auto-detect: $resolvedSerial (1 prefisso unico in $($zipFiles.Count) zip)"
        } else {
            throw "Auto-detect seriale: trovati $($prefixes.Count) prefissi diversi in Routine ($($prefixes -join ', ')). Passa -Serial esplicito per disambiguare."
        }
    }
} else {
    Write-Log -Rule '---' -Tag 'SERIAL' -Message "WARN: Routine non trovata. R7 sara' skippato."
}

# Conferma interattiva per -Execute (anti-typo / anti-doppio-click)
if ($Execute) {
    Write-Host ""
    Write-Host "==============================================================" -ForegroundColor Yellow
    Write-Host " MODALITA' -EXECUTE: cancellazione PERMANENTE (no Cestino)" -ForegroundColor Yellow
    Write-Host " Cartella : $ManufRoot" -ForegroundColor Yellow
    Write-Host " Riferim. : $($now.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Yellow
    if ($resolvedSerial) {
        Write-Host " Seriale  : $resolvedSerial" -ForegroundColor Yellow
    } else {
        Write-Host " Seriale  : (non risolto, R7 saltato)" -ForegroundColor Yellow
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

# R1
Remove-ByPattern -Rule 'R1' `
    -Dir (Join-Path $ManufRoot 'EVENTSMANAGER\DATA') `
    -Patterns @('PosteRestante*.xml') `
    -Cutoff $sixMonthsAgo

# R2
Remove-ByPattern -Rule 'R2' `
    -Dir (Join-Path $ManufRoot 'EVENTSMANAGER\DATA\EVENTS') `
    -Patterns @('*_NGCEVENTSDATA.xml', '*_NGCEVENTSDATA.bak') `
    -Cutoff $sixMonthsAgo

# R3 — host detection
# Priorita':
#   1. -Hostname esplicito
#   2. Auto-detect dai filename "REPORTING_<host>_Counters*.xml" in MarkerStore
#      + controprova con sottocartella omonima
#   3. Fallback: 1 sola sottocartella MarkerStore -> usa quella
#   4. Fallback: MarkerStore vuota -> $env:COMPUTERNAME
$markerStoreRoot = Join-Path $ManufRoot 'EVENTSMANAGER\DATA\MARKERSTORE'
$r3Targets = @()

if (Test-Path -LiteralPath $markerStoreRoot -PathType Container) {
    $hostDirs = @(Get-ChildItem -LiteralPath $markerStoreRoot -Directory -ErrorAction SilentlyContinue)
    $hostNames = @($hostDirs | ForEach-Object { $_.Name })

    if ($Hostname) {
        # override esplicito
        $match = $hostDirs | Where-Object { $_.Name -ieq $Hostname }
        if ($match) {
            $r3Targets += $match.FullName
            Write-Log -Rule 'R3' -Tag 'INFO' -Message "Hostname override: $Hostname"
        } else {
            Write-Log -Rule 'R3' -Tag 'WARN' -Message "Hostname '$Hostname' non trovato in MarkerStore. Host disponibili: $($hostNames -join ', ')"
        }
    } else {
        # Step 1: scegli prima sottocartella host (ordinata alfabeticamente)
        # Es. MarkerStore = { FAIQ50-768000, Vector-IQ50 } -> picka FAIQ50-768000
        if ($hostDirs.Count -gt 0) {
            $sortedDirs = $hostDirs | Sort-Object Name
            $picked = $sortedDirs[0]
            $r3Targets += $picked.FullName

            # Controprova: esistono file "REPORTING_<host>_Counters*.xml" in MarkerStore root?
            $counterMatch = @(Get-ChildItem -LiteralPath $markerStoreRoot -Filter "REPORTING_$($picked.Name)_Counters*.xml" -File -ErrorAction SilentlyContinue)
            $counterTag = if ($counterMatch.Count -gt 0) { "controprova Counters OK ($($counterMatch.Count) file)" } else { "controprova Counters assente" }

            if ($hostDirs.Count -eq 1) {
                Write-Log -Rule 'R3' -Tag 'INFO' -Message "Auto-detect host: $($picked.Name). $counterTag."
            } else {
                $others = ($sortedDirs | Select-Object -Skip 1 | ForEach-Object { $_.Name }) -join ', '
                Write-Log -Rule 'R3' -Tag 'INFO' -Message "Auto-detect host: $($picked.Name) (prima alfabetica; altre presenti ignorate: $others). $counterTag."
            }
        }

        # Step 2: se step 1 non ha riempito $r3Targets, prova fallback su sottocartelle
        if ($r3Targets.Count -eq 0) {
            if ($hostDirs.Count -eq 1) {
                $r3Targets += $hostDirs[0].FullName
                Write-Log -Rule 'R3' -Tag 'INFO' -Message "Fallback: 1 sola sottocartella MarkerStore: $($hostNames[0])"
            } elseif ($hostDirs.Count -gt 1) {
                throw "MarkerStore contiene $($hostDirs.Count) sottocartelle host: $($hostNames -join ', '). Nessun file REPORTING_*_Counters*.xml per disambiguare. Passa -Hostname esplicito."
            } else {
                $fallback = Join-Path $markerStoreRoot $env:COMPUTERNAME
                Write-Log -Rule 'R3' -Tag 'WARN' -Message "MarkerStore vuota. Fallback su `$env:COMPUTERNAME = $env:COMPUTERNAME"
                $r3Targets += $fallback
            }
        }
    }
} else {
    Write-Log -Rule 'R3' -Tag 'SKIP' -Message "path non trovato: $markerStoreRoot"
    $script:stats.Skipped++
}

$script:resolvedHostnames = @($r3Targets | ForEach-Object { Split-Path -Leaf $_ })

foreach ($t in $r3Targets) {
    Remove-ByPattern -Rule 'R3' `
        -Dir $t `
        -Patterns @('Reporting*.xml') `
        -Cutoff $sixMonthsAgo
}

# R4 — TRANSIT: tutto, sempre
Clear-TransitFolder -Rule 'R4' `
    -Dir (Join-Path $ManufRoot 'EVENTSMANAGER\DATA\TRANSIT')

# R5
Remove-ByPattern -Rule 'R5' `
    -Dir (Join-Path $ManufRoot 'PILOT\DATA\LAPOSTE') `
    -Patterns @('PosteRestante_pilot*.xml') `
    -Cutoff $sixMonthsAgo

# R6
Remove-ByPattern -Rule 'R6' `
    -Dir (Join-Path $ManufRoot 'PILOT\DATA\REPORT') `
    -Patterns @('Reporting*.xml', 'session*.xml') `
    -Cutoff $sixMonthsAgo

# R7 — ROUTINE: tutti i zip del seriale tranne ultima settimana
if ($resolvedSerial) {
    Remove-ByPattern -Rule 'R7' `
        -Dir (Join-Path $ManufRoot 'PILOT\DATA\ROUTINE') `
        -Patterns @("$resolvedSerial*.zip") `
        -Cutoff $oneWeekAgo
} else {
    Write-Log -Rule 'R7' -Tag 'SKIP' -Message "Seriale non risolto, R7 saltato."
    $script:stats.Skipped++
}

Write-Log -Rule '---' -Tag 'SUMMARY' -Message ("Matched={0} Deleted={1} DryRun={2} Skipped={3} Errors={4}" -f `
    $script:stats.Matched, $script:stats.Deleted, $script:stats.DryRun, $script:stats.Skipped, $script:stats.Errors)
Write-Log -Rule '---' -Tag 'END' -Message "Summary: $summaryFile"

# Genera file summary leggibile
$ruleDescriptions = [ordered]@{
    'R1' = 'PosteRestante*.xml in EventsManager\Data         (>6 mesi)'
    'R2' = 'NgcEventsData xml + bak in Events                (>6 mesi)'
    'R3' = 'Reporting*.xml in MarkerStore\<host>             (>6 mesi)'
    'R4' = 'Tutto in Transit (file + sottocartelle)          (sempre)'
    'R5' = 'PosteRestante_Pilot*.xml in LaPoste              (>6 mesi)'
    'R6' = 'Reporting*.xml e session*.xml in Report          (>6 mesi)'
    'R7' = "ZIP $resolvedSerial* in Routine                  (>7 giorni)"
}
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("===================================================================")
$titolo = if ($Execute) { ' ESITO CANCELLAZIONE (EXECUTE)' } else { ' ANTEPRIMA (DRY-RUN)' }
[void]$sb.AppendLine($titolo)
[void]$sb.AppendLine("===================================================================")
[void]$sb.AppendLine(" Cartella   : $ManufRoot")
[void]$sb.AppendLine((" Data run   : {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date)))
[void]$sb.AppendLine((" Riferim.   : {0:yyyy-MM-dd HH:mm:ss} ({1})" -f $now, $dateSource))
[void]$sb.AppendLine((" Cutoff 6m  : {0:yyyy-MM-dd}" -f $sixMonthsAgo))
[void]$sb.AppendLine((" Cutoff 7d  : {0:yyyy-MM-dd}" -f $oneWeekAgo))
if ($resolvedSerial) {
    [void]$sb.AppendLine(" Seriale    : $resolvedSerial")
} else {
    [void]$sb.AppendLine(" Seriale    : (non risolto)")
}
if ($script:resolvedHostnames -and $script:resolvedHostnames.Count -gt 0) {
    [void]$sb.AppendLine(" Hostname   : $($script:resolvedHostnames -join ', ')")
} else {
    [void]$sb.AppendLine(" Hostname   : (non risolto)")
}
[void]$sb.AppendLine("")

$actualMap = if ($Execute) { $script:perRuleDeleted } else { $script:perRuleDryRun }
$actualLabel = if ($Execute) { 'cancellati' } else { ' simulati' }
[void]$sb.AppendLine(" Risultato per regola (atteso = file trovati dallo scan):")
foreach ($r in $script:perRule.Keys) {
    $atteso = $script:perRule[$r]
    $effettivo = $actualMap[$r]
    $errori = $script:perRuleErrors[$r]
    $delta = $effettivo - $atteso
    $deltaStr = if ($delta -gt 0) { "+$delta" } else { "$delta" }
    [void]$sb.AppendLine(("   {0}  {1}  atteso {2,6}  {3} {4,6}  errori {5,3}  delta {6,5}" -f `
        $r, $ruleDescriptions[$r].PadRight(54), $atteso, $actualLabel, $effettivo, $errori, $deltaStr))
}
[void]$sb.AppendLine("")
$totAtteso = $script:stats.Matched
$totEffettivo = if ($Execute) { $script:stats.Deleted } else { $script:stats.DryRun }
$totErrori = $script:stats.Errors
$totDelta = $totEffettivo - $totAtteso
$totDeltaStr = if ($totDelta -gt 0) { "+$totDelta" } else { "$totDelta" }
[void]$sb.AppendLine((" TOTALE  atteso {0}   {1} {2}   errori {3}   delta {4}" -f $totAtteso, $actualLabel.Trim(), $totEffettivo, $totErrori, $totDeltaStr))
$esito = if ($totErrori -eq 0 -and $totDelta -eq 0) {
    'OK (atteso == effettivo, nessun errore)'
} else {
    "KO (atteso $totAtteso, effettivo $totEffettivo, errori $totErrori, delta $totDeltaStr)"
}
[void]$sb.AppendLine((" ESITO   {0}" -f $esito))
[void]$sb.AppendLine((" Saltati : {0} cartelle/pattern" -f $script:stats.Skipped))
[void]$sb.AppendLine("")
[void]$sb.AppendLine(" Summary: $summaryFile")
[void]$sb.AppendLine("===================================================================")

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($summaryFile, $sb.ToString(), $utf8NoBom)

# Esito finale evidente per l'utente
Write-Host ""
Write-Host ($sb.ToString())
Write-Host ""

$bAtteso = $script:stats.Matched
$bEffettivo = if ($Execute) { $script:stats.Deleted } else { $script:stats.DryRun }
$bDelta = $bEffettivo - $bAtteso
$bDeltaStr = if ($bDelta -gt 0) { "+$bDelta" } else { "$bDelta" }
$bColor = if ($script:stats.Errors -eq 0 -and $bDelta -eq 0) { 'Green' } else { 'Red' }

Write-Host "==============================================================" -ForegroundColor $bColor
if ($Execute) {
    Write-Host (" EXECUTE: atteso {0}  cancellati {1}  errori {2}  delta {3}" -f $bAtteso, $bEffettivo, $script:stats.Errors, $bDeltaStr) -ForegroundColor $bColor
} else {
    Write-Host (" DRY-RUN: atteso {0}  simulati {1}  delta {2}  (nessuna cancellazione)" -f $bAtteso, $bEffettivo, $bDeltaStr) -ForegroundColor $bColor
}
if ($script:stats.Errors -eq 0 -and $bDelta -eq 0) {
    Write-Host " ESITO: OK (atteso == effettivo)" -ForegroundColor Green
} else {
    Write-Host (" ESITO: KO  errori={0}  delta={1}" -f $script:stats.Errors, $bDeltaStr) -ForegroundColor Red
    $exitCode = 1
}
Write-Host " Summary: $summaryFile" -ForegroundColor $bColor
Write-Host "==============================================================" -ForegroundColor $bColor

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
