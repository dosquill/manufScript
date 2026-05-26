====================================================================
 CLEANUP-MANUF - documentazione utente
====================================================================

 COS'E'
 ------
 Script per la pulizia automatica della cartella Manuf di Lectra.
 Cancella file vecchi secondo 7 regole definite. Sicuro by default:
 in modalita' anteprima non cancella niente; in modalita' reale
 fa prima un backup completo della cartella Manuf.


 COME SI LANCIA
 --------------
 Doppio-click su  start.bat
 Si apre un menu:
   1. Anteprima (dry-run)   - mostra cosa verrebbe cancellato
   2. Esegui cancellazione  - cancella davvero (con backup automatico)
   3. Esci


 LE 7 REGOLE
 -----------
 R1  EventsManager\Data\PosteRestante*.xml                > 6 mesi
 R2  EventsManager\Data\Events\*_NgcEventsData*           > 6 mesi
 R3  EventsManager\Data\MarkerStore\<host>\Reporting*.xml > 6 mesi
     (applicato a TUTTI gli host presenti in MarkerStore,
      utile quando il PC ha cambiato hostname nel tempo)
 R4  EventsManager\Data\Transit\*                         sempre
 R5  Pilot\Data\LaPoste\PosteRestante_pilot*.xml          > 6 mesi
 R6  Pilot\Data\Report\Reporting*.xml + session*.xml      > 6 mesi
 R7  Pilot\Data\Routine\<serial>*.zip                     > 7 giorni
     (il seriale e' rilevato automaticamente dai file ZIP)


 BACKUP AUTOMATICO
 -----------------
 In modalita' "Esegui cancellazione" lo script copia TUTTA la
 cartella Manuf in:
   C:\ProgramData\Lectra\Manuf_backup_<data-ora>
 prima di cancellare. Se il backup fallisce, la cancellazione NON
 parte e viene segnalato l'errore.

 Metodo di copia: robocopy multi-thread (veloce, con retry e log).
 La copia preserva file, sottocartelle, attributi e timestamp.


 VERIFICA POST-CLEANUP
 ---------------------
 Alla fine dello script viene fatto un confronto reale tra la copia
 di backup e la cartella Manuf appena pulita. Lo script verifica:
   - i file realmente spariti coincidono con quelli che doveva
     cancellare (conteggio empirico vs conteggio atteso)
   - nessun file extra e' apparso durante l'esecuzione (no race)

 Se anche un solo file diverge, l'esito finale e' KO e viene scritto
 il dettaglio nel summary.


 RANGE RETENTION (opzionale, avanzato)
 -------------------------------------
 Per cancellare tutto cio' che e' FUORI da una finestra temporale
 esplicita (invece del default "ultimi 6 mesi"):

   powershell -File Cleanup-Manuf.ps1 -RetentionStart 2025-01-01 -RetentionEnd 2026-05-26

 Tiene i file con data tra le due indicate, cancella il resto.
 R7 (ZIP Routine 7g) e R4 (Transit sempre) non sono coinvolti dal
 range.


 AGGIORNAMENTO DELLO SCRIPT
 --------------------------
 Doppio-click su  update.bat
 Scarica lo zip dell'ultima versione del repo da GitHub (branch main)
 e sostituisce TUTTI i file locali (Cleanup-Manuf.ps1, start.bat,
 start-test.bat, README.txt, RegoleCancellazione.docx e update.bat
 stesso). Funziona come un "git pull" semplificato.

 Una copia di tutti i file pre-aggiornamento viene salvata in:
   _pre-update-backup-<data-ora>\
 utile per rollback se qualcosa va storto.

 Serve una connessione internet attiva. Se il download fallisce, i
 file locali NON vengono modificati.

 Note tecniche (per sviluppatori):
 - L'update si gestisce in due tempi: il .bat lancia uno script
   PowerShell temporaneo in una finestra separata e si chiude
   immediatamente, cosi' lo script puo' sovrascrivere anche update.bat
   stesso (un .bat in esecuzione non puo' modificare se stesso).
 - Lo zip viene scaricato in %TEMP% e cancellato a fine update.


 LOG E SUMMARY
 -------------
 Ogni esecuzione produce due file in  Logs\  :
   cleanup-<data-ora>.summary.txt   (esito leggibile da uomo)
   cleanup-<data-ora>.robocopy.log  (dettaglio del backup)

 Il summary contiene: parametri usati, conteggi per regola, esito
 finale OK / KO, info backup, info diff.


 PROBLEMI COMUNI
 ---------------
 "ManufRoot non trovato"
    La cartella  C:\ProgramData\Lectra\Manuf  non esiste su questa
    macchina. Verificare il path effettivo.

 "Auto-detect seriale: trovati N prefissi diversi"
    Ci sono ZIP con prefissi diversi nella cartella Routine.
    Possibile data corruption, contattare assistenza.

 "Backup file count mismatch"
    Robocopy ha copiato un numero diverso di file rispetto alla
    sorgente. Cancellazione abortita. Riprovare; se persiste,
    verificare permessi e spazio disco.

 "ESITO: KO -- vedere summary"
    Almeno una verifica e' fallita (cancellazione incompleta,
    residuo, errori, o diff). Aprire il summary per i dettagli.


====================================================================
