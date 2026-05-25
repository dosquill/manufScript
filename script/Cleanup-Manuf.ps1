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
$script:perRuleExpected = [ordered]@{
    'R1' = 0; 'R2' = 0; 'R3' = 0; 'R4' = 0; 'R5' = 0; 'R6' = 0; 'R7' = 0
}
$script:perRuleDeleted = [ordered]@{
    'R1' = 0; 'R2' = 0; 'R3' = 0; 'R4' = 0; 'R5' = 0; 'R6' = 0; 'R7' = 0
}
$script:perRuleErrors = [ordered]@{
    'R1' = 0; 'R2' = 0; 'R3' = 0; 'R4' = 0; 'R5' = 0; 'R6' = 0; 'R7' = 0
}
$script:perRuleResidue = [ordered]@{
    'R1' = 0; 'R2' = 0; 'R3' = 0; 'R4' = 0; 'R5' = 0; 'R6' = 0; 'R7' = 0
}
$script:totalExpected = 0
$script:totalResidue = 0

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

# Helper per pre-scan e post-scan (re-scan di verifica).
# Get-MatchCount: stessa logica di Remove-ByPattern ma SOLO conteggio, niente delete.
function Get-MatchCount {
    param([string]$Dir, [string[]]$Patterns, [Nullable[datetime]]$Cutoff)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return 0 }
    if (-not $Patterns -or $Patterns.Count -eq 0) { return 0 }
    $tot = 0
    foreach ($p in $Patterns) {
        $files = @(Get-ChildItem -LiteralPath $Dir -Filter $p -File -ErrorAction SilentlyContinue)
        if ($null -ne $Cutoff) {
            $files = @($files | Where-Object { $_.LastWriteTime -lt $Cutoff })
        }
        $tot += $files.Count
    }
    return $tot
}

function Get-MatchCountTransit {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue).Count
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

# R3 — host detection (eseguita PRIMA della costruzione del rules plan)
# Priorita':
#   1. -Hostname esplicito
#   2. Auto-detect: prima sottocartella alfabetica di MarkerStore (con controprova Counters)
#   3. Fallback: 1 sola sottocartella MarkerStore -> usa quella
#   4. Fallback: MarkerStore vuota -> $env:COMPUTERNAME
$markerStoreRoot = Join-Path $ManufRoot 'EVENTSMANAGER\DATA\MARKERSTORE'
$r3Targets = @()

if (Test-Path -LiteralPath $markerStoreRoot -PathType Container) {
    $hostDirs = @(Get-ChildItem -LiteralPath $markerStoreRoot -Directory -ErrorAction SilentlyContinue)
    $hostNames = @($hostDirs | ForEach-Object { $_.Name })

    if ($Hostname) {
        $match = $hostDirs | Where-Object { $_.Name -ieq $Hostname }
        if ($match) {
            $r3Targets += $match.FullName
            Write-Log -Rule 'R3' -Tag 'INFO' -Message "Hostname override: $Hostname"
        } else {
            Write-Log -Rule 'R3' -Tag 'WARN' -Message "Hostname '$Hostname' non trovato in MarkerStore. Host disponibili: $($hostNames -join ', ')"
        }
    } else {
        if ($hostDirs.Count -gt 0) {
            $sortedDirs = $hostDirs | Sort-Object Name
            $picked = $sortedDirs[0]
            $r3Targets += $picked.FullName

            $counterMatch = @(Get-ChildItem -LiteralPath $markerStoreRoot -Filter "REPORTING_$($picked.Name)_Counters*.xml" -File -ErrorAction SilentlyContinue)
            $counterTag = if ($counterMatch.Count -gt 0) { "controprova Counters OK ($($counterMatch.Count) file)" } else { "controprova Counters assente" }

            if ($hostDirs.Count -eq 1) {
                Write-Log -Rule 'R3' -Tag 'INFO' -Message "Auto-detect host: $($picked.Name). $counterTag."
            } else {
                $others = ($sortedDirs | Select-Object -Skip 1 | ForEach-Object { $_.Name }) -join ', '
                Write-Log -Rule 'R3' -Tag 'INFO' -Message "Auto-detect host: $($picked.Name) (prima alfabetica; altre presenti ignorate: $others). $counterTag."
            }
        }

        if ($r3Targets.Count -eq 0) {
            $fallback = Join-Path $markerStoreRoot $env:COMPUTERNAME
            Write-Log -Rule 'R3' -Tag 'WARN' -Message "MarkerStore vuota. Fallback su `$env:COMPUTERNAME = $env:COMPUTERNAME"
            $r3Targets += $fallback
        }
    }
} else {
    Write-Log -Rule 'R3' -Tag 'SKIP' -Message "path non trovato: $markerStoreRoot"
}

$script:resolvedHostnames = @($r3Targets | ForEach-Object { Split-Path -Leaf $_ })

# Rules plan: dati centralizzati per pre-scan, apply, post-scan.
$r3Dir = if ($r3Targets.Count -gt 0) { $r3Targets[0] } else { $null }
$r7Patterns = if ($resolvedSerial) { @("$resolvedSerial*.zip") } else { @() }
$rulesPlan = @(
    [pscustomobject]@{ Id='R1'; Dir=(Join-Path $ManufRoot 'EVENTSMANAGER\DATA');         Patterns=@('PosteRestante*.xml');                       Cutoff=$sixMonthsAgo; Mode='Pattern' },
    [pscustomobject]@{ Id='R2'; Dir=(Join-Path $ManufRoot 'EVENTSMANAGER\DATA\EVENTS');  Patterns=@('*_NGCEVENTSDATA.xml','*_NGCEVENTSDATA.bak'); Cutoff=$sixMonthsAgo; Mode='Pattern' },
    [pscustomobject]@{ Id='R3'; Dir=$r3Dir;                                              Patterns=@('Reporting*.xml');                           Cutoff=$sixMonthsAgo; Mode='Pattern' },
    [pscustomobject]@{ Id='R4'; Dir=(Join-Path $ManufRoot 'EVENTSMANAGER\DATA\TRANSIT'); Patterns=@();                                           Cutoff=$null;         Mode='Transit' },
    [pscustomobject]@{ Id='R5'; Dir=(Join-Path $ManufRoot 'PILOT\DATA\LAPOSTE');         Patterns=@('PosteRestante_pilot*.xml');                 Cutoff=$sixMonthsAgo; Mode='Pattern' },
    [pscustomobject]@{ Id='R6'; Dir=(Join-Path $ManufRoot 'PILOT\DATA\REPORT');          Patterns=@('Reporting*.xml','session*.xml');            Cutoff=$sixMonthsAgo; Mode='Pattern' },
    [pscustomobject]@{ Id='R7'; Dir=(Join-Path $ManufRoot 'PILOT\DATA\ROUTINE');         Patterns=$r7Patterns;                                   Cutoff=$oneWeekAgo;   Mode='Pattern' }
)

# PRE-SCAN: calcolo atteso per ogni regola PRIMA di applicare.
foreach ($rule in $rulesPlan) {
    if (-not $rule.Dir) { $script:perRuleExpected[$rule.Id] = 0; continue }
    if ($rule.Mode -eq 'Transit') {
        $script:perRuleExpected[$rule.Id] = Get-MatchCountTransit -Dir $rule.Dir
    } else {
        $script:perRuleExpected[$rule.Id] = Get-MatchCount -Dir $rule.Dir -Patterns $rule.Patterns -Cutoff $rule.Cutoff
    }
}
$script:totalExpected = ($script:perRuleExpected.Values | Measure-Object -Sum).Sum
Write-Log -Rule '---' -Tag 'PRESCAN' -Message ("Atteso totale: {0} file" -f $script:totalExpected)

# APPLY: esegui ogni regola.
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
        Remove-ByPattern -Rule $rule.Id -Dir $rule.Dir -Patterns $rule.Patterns -Cutoff $rule.Cutoff
    }
}

# POST-SCAN (solo execute): re-scan con gli stessi criteri per verificare residuo.
# Verifica genuina: se residuo > 0, qualcosa e' sfuggito (race, pattern incompleto, delete silently failed).
if ($Execute) {
    foreach ($rule in $rulesPlan) {
        if (-not $rule.Dir) { $script:perRuleResidue[$rule.Id] = 0; continue }
        if ($rule.Mode -eq 'Transit') {
            $script:perRuleResidue[$rule.Id] = Get-MatchCountTransit -Dir $rule.Dir
        } else {
            if (-not $rule.Patterns -or $rule.Patterns.Count -eq 0) { $script:perRuleResidue[$rule.Id] = 0; continue }
            $script:perRuleResidue[$rule.Id] = Get-MatchCount -Dir $rule.Dir -Patterns $rule.Patterns -Cutoff $rule.Cutoff
        }
    }
    $script:totalResidue = ($script:perRuleResidue.Values | Measure-Object -Sum).Sum
    Write-Log -Rule '---' -Tag 'POSTSCAN' -Message ("Residuo totale: {0} file" -f $script:totalResidue)
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

if ($Execute) {
    [void]$sb.AppendLine(" Risultato per regola (atteso=pre-scan, cancellati=delete OK, residuo=post-scan):")
    foreach ($r in $script:perRuleExpected.Keys) {
        $atteso     = [int]$script:perRuleExpected[$r]
        $cancellati = [int]$script:perRuleDeleted[$r]
        $residuo    = [int]$script:perRuleResidue[$r]
        $errori     = [int]$script:perRuleErrors[$r]
        $verdict = if ($cancellati -eq $atteso -and $residuo -eq 0 -and $errori -eq 0) { '[OK]' } else { '[KO]' }
        [void]$sb.AppendLine(("   {0}  {1}  atteso {2,6}  cancellati {3,6}  residuo {4,4}  errori {5,3}  {6}" -f `
            $r, $ruleDescriptions[$r].PadRight(54), $atteso, $cancellati, $residuo, $errori, $verdict))
    }
    [void]$sb.AppendLine("")
    $totAtteso     = [int]$script:totalExpected
    $totCancellati = [int]$script:stats.Deleted
    $totResiduo    = [int]$script:totalResidue
    $totErrori     = [int]$script:stats.Errors
    [void]$sb.AppendLine((" TOTALE  atteso {0}   cancellati {1}   residuo {2}   errori {3}" -f $totAtteso, $totCancellati, $totResiduo, $totErrori))
    $esitoOk = ($totCancellati -eq $totAtteso) -and ($totResiduo -eq 0) -and ($totErrori -eq 0)
    if ($esitoOk) {
        [void]$sb.AppendLine(" ESITO   OK (cancellati == atteso && residuo == 0 && errori == 0)")
    } else {
        [void]$sb.AppendLine((" ESITO   KO (cancellati {0}/{1}, residuo {2}, errori {3})" -f $totCancellati, $totAtteso, $totResiduo, $totErrori))
    }
} else {
    [void]$sb.AppendLine(" Anteprima per regola (file che sarebbero cancellati):")
    foreach ($r in $script:perRuleExpected.Keys) {
        $atteso = [int]$script:perRuleExpected[$r]
        [void]$sb.AppendLine(("   {0}  {1}  trovati {2,6}" -f $r, $ruleDescriptions[$r].PadRight(54), $atteso))
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine((" TOTALE  trovati {0} file" -f [int]$script:totalExpected))
    [void]$sb.AppendLine(" NOTA    in dry-run nessuna verifica reale. Esito disponibile solo con -Execute (post-scan).")
}
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

$bAtteso  = [int]$script:totalExpected
$bErrori  = [int]$script:stats.Errors

if ($Execute) {
    $bCancellati = [int]$script:stats.Deleted
    $bResiduo    = [int]$script:totalResidue
    $bOk = ($bCancellati -eq $bAtteso) -and ($bResiduo -eq 0) -and ($bErrori -eq 0)
    $bColor = if ($bOk) { 'Green' } else { 'Red' }
    Write-Host "==============================================================" -ForegroundColor $bColor
    Write-Host (" EXECUTE: atteso {0} / cancellati {1} / residuo {2} / errori {3}" -f $bAtteso, $bCancellati, $bResiduo, $bErrori) -ForegroundColor $bColor
    if ($bOk) {
        Write-Host " ESITO: OK (cancellati == atteso, residuo == 0, nessun errore)" -ForegroundColor Green
    } else {
        Write-Host " ESITO: KO -- vedere summary per dettagli per regola" -ForegroundColor Red
        $exitCode = 1
    }
    Write-Host " Summary: $summaryFile" -ForegroundColor $bColor
    Write-Host "==============================================================" -ForegroundColor $bColor
} else {
    Write-Host "==============================================================" -ForegroundColor Cyan
    Write-Host (" DRY-RUN: {0} file candidati alla cancellazione. NESSUNA cancellazione eseguita." -f $bAtteso) -ForegroundColor Cyan
    Write-Host " Verifica reale (re-scan post-cancellazione) solo con -Execute." -ForegroundColor Cyan
    Write-Host " Summary: $summaryFile" -ForegroundColor Cyan
    Write-Host "==============================================================" -ForegroundColor Cyan
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
