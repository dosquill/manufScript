# Refactor Single-Process — Piano

Branch: `refactor/single-process`
Obiettivo: eliminare la logica self-respawn (parent → child PowerShell) e
sostituirla con una pipeline single-process orchestrata da funzioni
riusabili. Riduce overhead startup, unifica log file, elimina problema
doppio `Read-Host`, migliora leggibilità della main.

## Stato attuale (main branch)

- Main flow lineare ~600 righe in cui PRE-SCAN, APPLY, POST-SCAN, DIFF,
  POST-COPY, summary write e banner finale sono inline.
- Dry-run → prompt "Procedere SI?" → `& powershell.exe @childArgs` con
  `-Execute -PostDryRun`. Il child è un nuovo processo che fa l'intera
  pipeline da capo.
- 2 file di log generati (uno per dry-run, uno per execute child).
- Parametro interno `[switch]$PostDryRun` necessario per skippare la
  conferma "SI" nel child.
- Flag `$skipFinalRead` necessaria per non chiedere `Read-Host` due volte.

## Stato target (questo branch)

```
Setup (param, validation, paths, parsing, rulesPlan)
   │
   ├─ if (-not $Execute esplicito): menu dry-run/execute/esci
   │
   ├─ if (Execute esplicito da CLI): Invoke-CleanupRun -DoExecute
   │
   └─ else (dry-run, da menu o default):
        Invoke-CleanupRun                       # dry-run
        if (prompt "Procedere SI?"):
            Invoke-CleanupRun -DoExecute -SkipConfirm
   ↓
Exit, un solo Read-Host
```

Un solo processo, un solo file di log con header `[DRY-RUN]` e poi
`[EXECUTE]` appesi sequenzialmente.

## Funzioni da estrarre

| Nuova funzione | Sostituisce blocco | Argomenti chiave |
|----------------|--------------------|------------------|
| `Reset-PipelineState` | reset manuale dei counters all'inizio | nessuno |
| `Invoke-PreScan` | foreach pre-scan + log + Write-Host "Pre-scan" | `$rulesPlan` |
| `Invoke-Apply` | foreach apply + Write-Progress | `$rulesPlan, $DoExecute` |
| `Invoke-PostScan` | foreach post-scan + Write-Host "Post-scan" | `$rulesPlan` (solo se DoExecute) |
| `Invoke-Diff` | Compare-Object + verdict + Write-Host | `$BackupDir, $ManufRoot, $stats.Deleted` |
| `Invoke-PostCopy` | prompt + Backup-ManufRoot + count check | `$ManufRoot, $PostBackupDir, $NoPostBackup` |
| `Write-CleanupSummary` | costruzione $sb + AppendAllText | tutti gli stati |
| `Write-FinalBanner` | banner finale colorato | tutti gli stati |
| `Invoke-CleanupRun` | orchestra le funzioni sopra | `-DoExecute, -SkipConfirm` |

## Step di implementazione (commit atomici sul branch)

1. **Aggiungi `Reset-PipelineState`** (no-op a parte azzeramento counters)
   — niente di rotto, una funzione nuova in più.
2. **Estrai `Invoke-PreScan`** dal foreach pre-scan, sostituisci nel main
   con chiamata. Test: dry-run su Manuf di test deve produrre stesso
   conteggio (5494 file).
3. **Estrai `Invoke-Apply`** stesso pattern. Test E2E execute.
4. **Estrai `Invoke-PostScan`** stesso pattern.
5. **Estrai `Invoke-Diff`** stesso pattern.
6. **Estrai `Invoke-PostCopy`** stesso pattern.
7. **Estrai `Write-CleanupSummary`**.
8. **Estrai `Write-FinalBanner`**.
9. **Wrappa tutto in `Invoke-CleanupRun -DoExecute -SkipConfirm`**.
10. **Sostituisci il blocco self-respawn** con chiamata diretta a
    `Invoke-CleanupRun -DoExecute -SkipConfirm`. Rimuovi param
    `PostDryRun` (deprecato — non più necessario), rimuovi flag
    `$skipFinalRead` (non più necessaria perché c'è un solo `Read-Host`).
11. **Test E2E completo**: dry-run-no, dry-run-SI, execute esplicito,
    range retention, NoBackup, NoPostBackup. Tutti devono produrre
    stessi conteggi e stessi verdict del main branch.

## Verifiche per ogni step

- Parse: `[Parser]::ParseFile()` → no errors
- Sanity: dry-run su Manuf_template deve dare 5494 file candidati
- Encoding: log file UTF-16 LE leggibile
- Single Read-Host: niente doppio prompt finale
- Single log file: un solo `Logs\cleanup-<ts>.log` per intero ciclo
  dry-run + execute (se l'utente prosegue)

## Rischi noti

- Reset state tra dry-run e execute deve essere completo: se manca un
  contatore i conteggi della seconda run sono sporcati.
- L'override di `$Execute` dentro la funzione: PowerShell scoping può
  essere subdolo. Usare `$script:Execute` o passare `[bool]$DoExecute`
  esplicito ovunque.
- Banner di startup: 1 volta sola? O 2 (dry-run + execute)? Decisione:
  1 sola in cima, poi sotto-banner `[ESECUZIONE REALE IN CORSO]` per
  marcare il secondo giro.

## Out of scope (NON in questo refactor)

- Retention sui backup PRE e POST (deciso skip dall'utente).
- Read-Host non-interactive (script on-demand, no scheduler).
- Magic numbers configurabili (`/MT:16`, ecc.).
- Test path con spazi, UNC, drive di rete.

## Done

Il refactor è completo quando:
- `Cleanup-Manuf.ps1` ha main flow ≤ 50 righe (oggi ~600)
- Nessun riferimento a `& powershell.exe @childArgs`
- Nessun param `PostDryRun`
- Nessuna variabile `$skipFinalRead`
- Tutti i test E2E del main branch passano sul branch
- PR aperta verso `main` con changelog dettagliato
