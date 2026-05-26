# Cleanup-Manuf

Script PowerShell per la pulizia automatica della cartella `Manuf` di Lectra.
Cancella file vecchi secondo 7 regole definite. Sicuro by-default: in modalità
anteprima non cancella niente; in modalità reale crea prima un backup completo
e verifica empiricamente l'esito.

---

## Come si lancia

Doppio-click su **`start.bat`**. Si apre un menu:

1. **Anteprima (dry-run)** — mostra cosa verrebbe cancellato, senza toccare nulla
2. **Esegui cancellazione** — cancella davvero, con backup automatico
3. **Esci**

Dopo l'anteprima viene chiesto se procedere con la cancellazione vera. Si
risponde `SI` per confermare o qualsiasi altra cosa per uscire senza modifiche.

---

## Regole di cancellazione

**Fonte originale**: documento *"FILE DA CANCELLARE NELLA CARTELLA MANUF"*
fornito dal cliente.

### Specifica testuale del documento

```
\EVENTSMANAGER\DATA\(PosteRestante*.xml)                  (rif. data)
\EVENTSMANAGER\DATA\EVENTS\(*_NGCEVENTSDATA.xml;
                            *_NGCEVENTSDATA.bak)          (rif. data)
\EVENTSMANAGER\DATA\MARKERSTORE\(nome host)\
                               (Reporting*.xml)           (rif. data)
\EVENTSMANAGER\DATA\TRANSIT\*.*                           (sempre)
 PILOT\DATA\LAPOSTE\(PosteRestante_pilot*.xml)            (rif. data)
 PILOT\DATA\REPORT\(Reporting*.xml; session*.xml)         (rif. data)
 PILOT\DATA\ROUTINE\((SERIALE MACCHINA)*.zip)             (tutti i file zip
                                                          tranne quelli
                                                          dell'ultima
                                                          settimana)

(rif. data) = tutti i file più vecchi di 6 mesi
```

### Mapping regola → implementazione

| ID | Path | Pattern | Cutoff |
|----|------|---------|--------|
| R1 | `EventsManager\Data\` | `PosteRestante*.xml` | > 6 mesi |
| R2 | `EventsManager\Data\Events\` | `*_NgcEventsData.xml` + `.bak` | > 6 mesi |
| R3 | `EventsManager\Data\MarkerStore\<host>\` | `Reporting*.xml` | > 6 mesi |
| R4 | `EventsManager\Data\Transit\` | tutto (file + sottocartelle) | sempre |
| R5 | `Pilot\Data\LaPoste\` | `PosteRestante_pilot*.xml` | > 6 mesi |
| R6 | `Pilot\Data\Report\` | `Reporting*.xml` + `session*.xml` | > 6 mesi |
| R7 | `Pilot\Data\Routine\` | `<seriale>*.zip` | > 7 giorni |

### Note sull'implementazione

- **R3 multi-host**: la specifica menziona "(nome host)" al singolare; lo
  script itera invece **tutte le sottocartelle host** presenti in
  `MarkerStore\`. Motivo: lo stesso PC nel tempo può aver cambiato hostname
  (es. `FAIQ50-768000`, `Vector-IQ50`) e tutte le cartelle vanno pulite
  uniformemente.

- **R3 non ricorsiva**: la pulizia tocca solo i file `Reporting*.xml` *direct
  children* di ciascun host. Sottocartelle come `Photo\` restano intatte come
  da specifica del documento.

- **R7 auto-detect seriale**: lo script legge i file `*.zip` in `Routine\` e
  prende il prefisso (parte prima del primo `_`). Se trova prefissi diversi
  → errore (possibile data corruption).

- **R4 e R7 escluse dalla range retention**: la feature opzionale
  `-RetentionStart` / `-RetentionEnd` non tocca queste regole. R4 cancella
  sempre, R7 mantiene sempre il proprio cutoff di 7 giorni.

- **"Più vecchi di X"** = `LastWriteTime` anteriore al cutoff, calcolato da
  una data di riferimento (default: oggi).

---

## Backup automatico pre-cancellazione

In modalità execute lo script copia **tutta** la cartella `Manuf` prima di
cancellare, dentro:

```
C:\ProgramData\Lectra\Manuf_backup_<data-ora>
```

- Metodo: `robocopy` multi-thread (`/MT:16`), preserva file/cartelle/attributi/timestamp.
- Verifica integrità: il count file sorgente deve coincidere col count
  destinazione. In caso di mismatch la cancellazione **non** parte.
- Per saltare il backup (sconsigliato): aprire `start.bat` e aggiungere
  `-NoBackup` al comando.

---

## Verifica post-cancellazione (diff)

Dopo la cancellazione lo script confronta il backup con la cartella `Manuf`
appena pulita tramite `Compare-Object`:

- I file presenti nel backup ma non più in `Manuf` = realmente cancellati.
- I file presenti in `Manuf` ma non nel backup = aggiunti durante l'esecuzione
  (anomalia: race condition o bug).

Verdetto OK se `spariti == stats.Deleted` **e** `aggiunti == 0`. Se anche un
solo controllo fallisce, l'esito finale è KO.

---

## Range retention (opzionale, avanzato)

Per cancellare tutto ciò che è **fuori** da una finestra temporale esplicita
(invece del default "ultimi 6 mesi"):

```powershell
powershell -File Cleanup-Manuf.ps1 -RetentionStart 2025-01-01 -RetentionEnd 2026-05-26
```

Tiene i file con `LastWriteTime` in `[Start, End]`, cancella tutto il resto.
R7 (ZIP Routine, 7 giorni) e R4 (Transit, sempre) non sono coinvolti.

---

## Aggiornamento dello script

Doppio-click su **`update.bat`**. Scarica lo zip dell'ultima versione del repo
da GitHub (branch `main`) e sostituisce **tutti** i file locali. Funziona come
un "git pull" semplificato.

Una copia di tutti i file pre-aggiornamento viene salvata in:
```
_pre-update-backup-<data-ora>\
```
utile per rollback se qualcosa va storto.

Serve una connessione internet attiva. Se il download fallisce, i file locali
**non** vengono modificati.

### Note tecniche

- L'update si gestisce in due tempi: il `.bat` lancia uno script PowerShell
  temporaneo in una finestra separata e si chiude immediatamente, così lo
  script può sovrascrivere anche `update.bat` stesso (un `.bat` in esecuzione
  non può modificare sé stesso).
- Lo zip viene scaricato in `%TEMP%` e cancellato a fine update.

---

## Log e summary

Ogni esecuzione produce **un solo file**:

```
Logs\cleanup-<data-ora>.log
```

Contiene sia il log del backup `robocopy` (se eseguito) sia il summary
leggibile dell'esito (separati da un banner `SUMMARY ESECUZIONE`).

---

## Problemi comuni

**`ManufRoot non trovato`**
La cartella `C:\ProgramData\Lectra\Manuf` non esiste su questa macchina.
Verificare il path effettivo.

**`Auto-detect seriale: trovati N prefissi diversi`**
Ci sono file ZIP con prefissi diversi nella cartella `Routine\`. Possibile
data corruption — contattare l'assistenza.

**`Backup file count mismatch`**
`robocopy` ha copiato un numero di file diverso dalla sorgente. La
cancellazione è abortita. Riprovare; se persiste, verificare permessi e
spazio disco.

**`ESITO: KO -- vedere summary`**
Almeno una verifica è fallita (cancellazione incompleta, residuo, errori, o
diff KO). Aprire il file di log per i dettagli.
