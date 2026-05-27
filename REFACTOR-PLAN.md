# Refactor Single-Process — Completato

Branch: `refactor/single-process`
Stato: DONE.

## Decisione finale (deviazione dal piano originale)

Il piano originale prevedeva estrazione di 8 funzioni (`Invoke-PreScan`,
`Invoke-Apply`, `Invoke-PostScan`, `Invoke-Diff`, `Invoke-PostCopy`,
`Write-CleanupSummary`, `Write-FinalBanner`, `Invoke-CleanupRun`) per
permettere allo script di fare dry-run + execute nello stesso processo.

L'utente ha scelto una soluzione molto piu' semplice: **eliminare il
self-respawn e basta**, demandando all'utente il rilancio manuale.

Razionale (chiarezza mentale > automazione):
- Un solo flusso lineare per run.
- Niente codice morto da mantenere (orchestrator, reset state, etc).
- L'utente cliente vede sempre lo stesso menu, sempre nello stesso modo.
- Niente flag interni (`-PostDryRun`), niente guard di esecuzione
  (`$skipFinalRead`), niente process spawning.

## Cosa cambia per l'utente

Prima:
1. Doppio-click `start.bat`
2. Menu → `1` (dry-run)
3. Script mostra anteprima
4. Prompt: "Procedere SI?" → se SI, child spawn → execute
5. Read-Host finale del child

Adesso:
1. Doppio-click `start.bat`
2. Menu → `1` (dry-run)
3. Script mostra anteprima
4. Messaggio: "Per cancellazione reale: rilancia start.bat e premi 2"
5. Read-Host finale → exit
6. (Utente rilancia) Doppio-click `start.bat`
7. Menu → `2` (esegui)
8. Conferma SI → execute

Un click extra per l'utente, ma flusso lineare e prevedibile.

## Modifiche al codice

| File | Righe | Modifica |
|------|-------|----------|
| `Cleanup-Manuf.ps1` | param block | Rimosso `[switch]$PostDryRun` |
| `Cleanup-Manuf.ps1` | init | Rimosso `$skipFinalRead = $false` + commento |
| `Cleanup-Manuf.ps1` | Execute confirm (~425) | Rimosso branch `if ($PostDryRun)` |
| `Cleanup-Manuf.ps1` | Post dry-run (~805) | Sostituito blocco self-respawn (~40 LOC) con messaggio "rilancia, premi 2" (~18 LOC) |
| `Cleanup-Manuf.ps1` | finally | Rimosso guard `if (-not $skipFinalRead)` |

Diff totale: **-65 righe, +27 righe** (38 LOC nette in meno).

## Verifica

- Parse: `[Parser]::ParseFile()` → no errors
- Dry-run su `Data\Manuf` con range 2018-2019: 2330 file candidati,
  messaggio post-dry-run corretto, un solo Read-Host finale
- Nessun residuo `PostDryRun` / `skipFinalRead` / `childArgs` /
  `powershell.exe @` nel file

## Step pianificati MA NON applicati (out of scope)

Le 8 funzioni helper del piano originale non sono state estratte. Se in
futuro serve far girare dry-run + execute nello stesso processo (es. per
schedulazione o test E2E), il piano resta valido in git history
(`git show <commit-iniziale-branch>:REFACTOR-PLAN.md`).
