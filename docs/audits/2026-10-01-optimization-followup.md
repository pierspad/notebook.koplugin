# Ottimizzazioni dopo la revisione — 1 ottobre 2026

Questa fase segue la [revisione iniziale](2026-10-01-maintenance-benchmark-updates.md).
La branch `dev` è stata sincronizzata con `origin/dev`, senza commit in ingresso.
Le modifiche precedenti sono conservate. Baseline recuperabile prima di questa
fase: `/tmp/notebook-optimization-baseline/lua`; diff dei file tracked:
`/tmp/notebook-optimization-baseline/tracked.patch`.
Nessun commit, pubblicazione, installazione nel plugin attivo o riavvio di KOReader.

## Modifiche mantenute

### Sfondi PDF: riusare due raster con un budget

`lua/pdfbackground.lua` conservava un solo raster. Alternare pagina intera e
miniatura, o due pagine dello stesso PDF, richiedeva ogni volta apertura e
rendering MuPDF. La cache mantiene ora due raster recenti, con chiavi esplicite
per file, pagina e dimensioni, entro un budget di 12 MiB.

Il primo caricamento e i pixel prodotti da MuPDF restano invariati. Prima di
un miss si liberano le entry necessarie. Un raster singolo più grande del
budget, per esempio zoom 2x, viene conservato **da solo**, come prima:
12 MiB non è quindi un tetto assoluto allo zoom. La memoria totale comprende
anche cache del canvas, testo, bitmap temporanee e lavoro interno di MuPDF.
La nuova cache può mantenere un raster in più rispetto alla versione precedente.

Dimensione, modifica, cambio, inode e device del file invalidano le entry.
Questo rileva una normale sostituzione atomica con lo stesso nome. Non è un
hash dei contenuti: modifiche in-place della stessa dimensione entro lo stesso
tick dei timestamp possono sfuggire. Controllare tutto il PDF a ogni ridisegno
costerebbe troppo; il file compagno è normalmente immutabile. Lo stat aggiuntivo
per ogni accesso comporta un piccolo costo, incluso nelle misure warm.

### Caricamento: validare i punti in un solo passaggio

In `lua/documentstorage.lua` le coordinate erano attraversate tre volte:
validità delle chiavi, presenza degli elementi, validità dei valori.
Un passaggio verifica ora chiavi intere nell'intervallo atteso, valori numerici
finiti e numero degli indici. Le chiavi sono uniche: esattamente N chiavi in
1..N dimostrano che non ci sono buchi. Restano tutti i controlli su numero dei
punti, colori, dimensioni e contorni degli evidenziatori.

Struttura di `Document:load()`, formato bitser, ricostruzione dei tratti e
comportamento del salvataggio sono conservati. Si legge ancora tutto il file.

## Tentativi scartati

### Lettura di una sola pagina per la miniatura

Il prototipo `loadPreview()` validava tutte le pagine ma costruiva gli oggetti
Stroke soltanto per quella corrente, oppure la prima con tratti se la corrente
era vuota. I test verificavano template, origine, dimensioni, background,
rifiuto del salvataggio parziale e validazione delle pagine nascoste.
I PNG erano identici alla versione precedente.

Il formato bitser richiedeva comunque lettura e decodifica dell'intero file.
Il guadagno isolato della miniatura era di circa il 3%, mentre alcune prove
complete mostravano rallentamenti del 17–18%. Il percorso aggiuntivo e le
interazioni con le trace JIT non sono giustificati da un risultato così incerto.
Il prototipo è stato rimosso: `thumbnail.lua` e l'API di caricamento restano
quelle della baseline di questa fase. Per un guadagno maggiore occorre valutare
separatamente un formato indicizzato o miniature aggiornate fuori dal percorso
critico, con migrazione e gestione degli errori esplicite.

### Riuso del proxy nel rendering scalato

Il rendering scalato costruisce una tabella e due closure per ogni tratto.
Il prototipo riutilizzava un solo proxy locale per chiamata, aggiornando stile,
tinta, contorni, bounds e fase del tratteggio. I pixel restavano identici anche
su pagine miste. Una prova isolata mostrava un piccolo guadagno, ma nelle prove
complete comparivano rallentamenti del rendering scalato fino al 48%, dello
zoom fino al 18% e dell'export PDF fino al 20%.

È stato rimosso dal codice finale. La topologia delle trace JIT impedisce di
attribuire automaticamente ogni variazione a quel proxy; resta comunque
insufficiente l'evidenza per mantenerlo. `renderer.lua` coincide con la baseline
all'inizio di questa fase, inclusa l'ottimizzazione di clipping già verificata
nella revisione iniziale.

## Metodo e limiti

Misure native sul Kindle Scribe via SSH, con fixture temporanee, BlitBuffer e
MuPDF del runtime installato. Non si leggono notebook personali e non si
richiedono refresh al pannello. Storage: `/tmp`, non una prova sulla memoria
USB del Kindle. Sono misure offscreen, non latenza della penna o batteria.

Nove campioni dopo un warm-up; mediana CPU in millisecondi. Con nove campioni il
p95 coincide con il massimo e non descrive in modo affidabile le code. Si sono
conservate anche baseline intermedie per isolare validazione, preview e proxy.
Il governor e le trace JIT possono produrre risultati discordanti fra prove
isolate e complete; non si dichiarano miglioramenti universali.

La prima prova desktop `benchmark-optimization-desktop.json` si è sovrapposta
parzialmente alle suite sullo stesso host e non è conclusiva.
`benchmark-optimization-desktop-final.json` è stata eseguita senza suite
concorrenti. I test desktop durante benchmark SSH usavano una CPU distinta.

I file con suffisso `kindle`, `kindle-final` e `kindle-accepted` conservano prove
di versioni intermedie, compresi prototipi poi rimossi. Il nome `accepted` fu
usato dopo la rimozione del proxy, ma prima della rimozione della preview:
**non rappresenta il codice finale**. In quella prova la baseline del rendering
di testo/forme impiegava circa 39 secondi contro circa 185 ms della variante,
una discrepanza enorme in codice di fatto immutato: quel rapporto non è un
guadagno attribuibile alle ottimizzazioni. Rimangono candidati di regressione
nei confronti completi, documentati nei JSON; non si sostiene che ogni caso
sia migliorato o che tutte le variazioni siano regressioni algoritmiche.

Heap delta non misura allocazioni totali o picco. Alcune miniature mostravano
una heap delta maggiore dopo il prototipo perché il collector liberava oggetti
in momenti differenti. I risultati non sono una prova di riduzione della RAM.
La cache PDF ha un budget esplicito e test di eviction; la validazione in un
passaggio riduce i giri sui dati, senza introdurre cache persistenti.

## Harness e verifiche

L'harness aggiunge i casi PDF con alternanza di dimensioni/pagine e un caso
separato per il caricamento usato dalle miniature (nella versione finale è un
caricamento completo). `--baseline-extended` permette il confronto dei casi
estesi su baseline compatibili. Ogni caso registra lo stato JIT effettivo prima
e dopo, oltre al profilo richiesto, e scrive il nome del caso su stderr per
orientare la diagnosi degli errori. Lo stato JIT globale non dimostra da solo
che ogni singola funzione sia compilata.

`tools/check-native.py` ripete i confronti via SSH in directory temporanee,
senza installare il codice nel plugin attivo. Le comparazioni di pixel sono
indipendenti dalle inferenze sulle prestazioni.

- `make verify`: 46 suite; 78 file Lua senza warning/errori.
- `make check-package`: ZIP locale valido, versione ancora `v1.5.0-dev.3`, non pubblicata.
- 672 confronti del renderer: grayscale/RGB, quattro rotazioni, quattro scale,
  tre offset, penne, forme e pagine con tratti misti.
- 29 confronti delle miniature/PDF: PNG completi, clipping, rotazioni e alternanza.
- Test della cache: dimensioni e pagine vicine, sostituzione del file, limiti,
  raster oltre budget, cleanup ripetuto e recupero da errore MuPDF.
- Test della persistenza: array sparsi/chiavi extra, coordinate non finite,
  colori e contorni, nessuna sostituzione dello stato aperto dopo un errore.

```sh
python3 tools/benchmark.py --ssh root@KINDLE --baseline /path/to/baseline-lua --filter load/ --jit both
python3 tools/benchmark.py --ssh root@KINDLE --baseline /path/to/baseline-lua --baseline-extended --extended --filter background/pdf --jit on
python3 tools/check-native.py --ssh root@KINDLE --baseline /path/to/baseline-lua
```

## Risultati del codice finale sul Kindle

Questi report confrontano la baseline iniziale con il codice mantenuto, senza
preview parziale e senza proxy riutilizzato. Sono prove isolate per famiglia
di casi, non una promessa di miglioramento di ogni flusso UI.

| Caso | JIT | Prima CPU ms | Dopo CPU ms | Riduzione |
|---|---|---:|---:|---:|
| `load/full-notebook` | on | 101.997 | 90.624 | 11.2% |
| `load/full-notebook` | off | 1225.850 | 1100.166 | 10.3% |
| `background/pdf-cold` | on | 407.236 | 406.057 | 0.3% |
| `background/pdf-warm` | on | 6.987 | 5.986 | 14.3% |
| `background/pdf-alternating-size` | on | 420.142 | 7.019 | 98.3% |
| `background/pdf-alternating-page` | on | 807.963 | 12.563 | 98.4% |

Fonti: [caricamento](results/benchmark-optimization-load-final.json), [PDF](results/benchmark-optimization-pdf-final.json).

SHA-256 dei moduli Lua di produzione per entrambe le prove: `6bdb6ee9e60a01efe0ed9237543667bc28d2c84bd2424305b1767c825f8de3fc`.

Il risultato warm PDF varia di circa 1 ms; il beneficio sostanziale resta
eliminare rendering ripetuti quando cambia pagina o dimensione. Il cold rimane
circa 406 ms: non si attribuisce alla cache un'accelerazione di MuPDF.

Gli ultimi [confronti nativi sul Kindle](results/native-optimization-final.txt)
verificano il codice finale: 672 confronti del renderer e 29 delle miniature/PDF,
con gli stessi pixel e PNG della baseline. Le directory temporanee sono state
rimosse al termine delle prove.
