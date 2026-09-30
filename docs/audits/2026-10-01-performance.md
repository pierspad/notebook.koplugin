# Notebook: audit di performance, correttezza e integrazione del remoto

Data: 1 ottobre 2026. Base verificata: `origin/dev`, commit `38fcfd5`,
versione `v1.5.0-dev.2`. Le modifiche descritte sono state preparate per il commit e il push su `dev`
su richiesta dell’utente. Nessuna installazione sul dispositivo.

Questo rapporto sostituisce l'audit iniziale fatto sulla vecchia copia locale.
Le sue raccomandazioni non erano tutte applicabili alla versione attuale.
L'obiettivo è eliminare lavoro ridondante mantenendo geometria, pixel,
ordine dei tratti, input, undo/redo e compatibilità dei quaderni.

## 1. Sincronizzazione e conservazione del lavoro

La copia locale era sul ramo `dev`, a `1b9fa79`, e mancavano **49 commit**
rispetto a `origin/dev`. Il remoto `main` era a `7ea3553`; il ramo `dev`
comprendeva anche i successivi interventi sulla navigazione e sulla versione
nell'intestazione. È stato mantenuto il ramo già seguito, senza passare a main.

Prima dell'integrazione sono stati salvati file modificati e non tracciati,
patch, stato Git, hash e HEAD originale in:

```
.git/codex-backups/sync-20260930T231346Z/
```

Lo stash `codex: preserve local work before remote sync 2026-10-01` è ancora
presente. Il pull è stato un fast-forward. Una seconda fetch, a fine lavoro,
ha confermato zero commit di differenza tra HEAD e upstream.

I conflitti sono stati risolti confrontando le responsabilità della nuova
architettura:

- Conservata la validazione locale dei documenti, adattandola a RGB, testo,
  sfondi PDF e dimensioni pagina presenti nel remoto.
- Conservate le protezioni locali sulle operazioni della libreria: symlink,
  errori di copia e chiusura, propagazione dei fallimenti di cancellazione.
- Spostata la correzione delle collisioni nella condivisione in
  `galleryexport.lua`, dove il remoto ha trasferito queste operazioni.
- Conservate le suite locali `storage` e `persistence` e integrate nel Makefile.
- Accettata la rimozione remota del vecchio piano del tuning dock. La copia
  locale del piano resta nel backup e nello stash.
- Sostituito il vecchio benchmark di prototipi: cancellazione multipla e carta
  puntinata erano già ottimizzate nel remoto; applicare i vecchi prototipi alla
  nuova sorgente avrebbe confrontato algoritmi o ancoraggi sbagliati.

`README.md` cita effettivamente `./install.sh` nel workspace locale che contiene
più plugin. Non è un file tracciato in Notebook e non risulta nella sua storia
Git; nel workspace di questo PC non è presente. Un pull di Notebook non può
recuperare quel file esterno. Non è stato ricreato un installer per supposizione.

`AGENTS.md` ora prescrive fetch/pull dell'upstream prima di ogni lavoro,
con controllo del ramo, backup dello stato sporco e riconciliazione esplicita
in caso di divergenza. Il file era escluso da Git tramite `.git/info/exclude`; viene ora incluso
nel commit richiesto, così la regola si trasferisce anche sugli altri PC.

## 2. Risultati applicati

| Intervento | Effetto | Prova principale |
|---|---|---|
| Bounds del lazo calcolati una volta per ricerca | Eliminato il costo ripetuto proporzionale a tratti × vertici | Equivalenza con il remoto, poligoni irregolari/degeneri e contatore delle letture |
| Cache pagina consultata prima del ripristino della carta | Una sola copia completa sul framebuffer per hit con sfondo già corrente | Pixel identici con veri blitbuffer, backend C/Lua e test delle copie |
| CRC32 XOPP con tabella di 256 elementi | Un aggiornamento CRC per byte invece di otto iterazioni sui bit | XOPP byte per byte identico al remoto, CRC indipendente e `gzip -t` |
| Validazione RGB di penne ed evidenziatori | Il lavoro locale recuperato non rifiuta più i quaderni della nuova versione | Save/load con RGB, testo Unicode, sfondi PDF e vero codec bitser |
| Nomi univoci nella condivisione | Notebook, export omonimi e PDF allegati a XOPP non si sovrascrivono nello staging | File reali, collisioni case-insensitive, nomi con suffissi e callback di preparazione |
| Hash cache: errori di lettura/chiusura | Nessuna chiave costruita da una lettura incompleta dichiarata fallita | Fault injection su open/read/close e invalidazione a parità di timestamp/dimensione |
| XOPP: errori di lettura/chiusura | Non vengono dichiarati riusciti file falliti in chiusura o PDF copiati parzialmente | Fault injection e conservazione dell'export precedente se fallisce la chiusura primaria |

Gli interventi prestazionali non cambiano la densità dei punti, gli intervalli di
refresh, il formato dei quaderni, il campionamento del lazo o gli algoritmi di
rasterizzazione dell'inchiostro. Le correzioni I/O intervengono su condizioni di
fallimento, non sul contenuto prodotto quando l'operazione riesce.

### Lazo: complessità e invarianti

Prima `isStrokeSelected` ricostruiva il bounding box dell'intero poligono per
ciascun tratto. Con N tratti e V vertici, soltanto questa fase costava O(NV).
Adesso la ricerca lo calcola una volta e lo passa a un helper interno:
O(V + N) per la rejection, oltre al costo dei punti effettivamente campionati.
Il ray casting sui candidati conserva il suo costo O(SV).

Non vengono memorizzati bounds tra gesti diversi: non c'è una nuova cache da
invalidare. La funzione pubblica per un singolo tratto resta disponibile.
Sono rimasti identici il controllo dei bounds, la distanza di campionamento,
la continuità tra segmenti, il controllo dell'ultimo punto e l'ordine dei risultati.

Il test che misura le coordinate del poligono falliva prima con 4.400 letture
per 200 tratti lontani; ora quelle letture dipendono soltanto dai quattro
vertici. Gli altri test comprendono linee raddrizzate, curve concave, V,
intersezioni senza estremi interni, loop invertiti, vuoti e degeneri.
Il benchmark confronta anche la nuova funzione con la sorgente originale
`38fcfd5`, evitando un semplice confronto tra due API del medesimo helper.

### Cache pagina: evitare una copia senza perdere lo sfondo

Prima, ogni hit eseguiva il blit della carta e subito dopo il blit della
pagina completa, che contiene già quella stessa carta. La prima copia era
interamente sovrascritta.

Ora si cerca prima l'entry. Se anche lo sfondo corrente è già valido,
viene copiata soltanto la pagina. Quando si torna da una pagina con carta
diversa, viene invece ricostruita la cache dello sfondo **anche se** esiste
la bitmap completa della pagina: la gomma usa quello sfondo per ricostruire
piccoli rettangoli. Saltare questo passaggio avrebbe prodotto una regressione
visibile solo dopo il successivo intervento della gomma.

Restano invariati chiavi, revisioni, limite di memoria, eviction LRU,
liberazione delle bitmap e bypass durante selezioni, preview e batch.
Una copia invece di due significa metà delle copie complete in quel percorso;
non significa metà della latenza complessiva di scrittura o refresh del pannello.

### CRC32 XOPP

Il polinomio e il contenuto gzip non cambiano. La tabella viene costruita alla
prima esportazione e riusata: 256 × 8 passaggi iniziali, poi un lookup per byte.
Il costo passa da otto iterazioni per byte a una. L'allocazione aggiunta è una
sola piccola tabella, indipendente dalla dimensione del notebook.

L'export completo di testo Unicode è stato confrontato byte per byte con il
remoto. Un test più grande attraversa più blocchi DEFLATE da 65.535 byte,
ricostruisce il payload, verifica CRC32 con l'algoritmo indipendente sui bit,
verifica ISIZE, escaping XML e accettazione da parte di gzip.

## 3. Misure riproducibili

Sistema di misura: CPU desktop x64, LuaJIT 2.1.1788856981.
I numeri sono mediane, non stime del tempo sul Kindle. I risultati variano con
carico, JIT e cache CPU; nessuna soglia temporale fragile è stata aggiunta ai test.

Ultimo run del benchmark sulla sorgente finale, con JIT attivo:

| Scenario | Remoto prima | Working tree dopo | Rapporto |
|---|---:|---:|---:|
| Lazo, 20 tratti / 20 vertici | 0,0140 ms | 0,0024 ms | 5,72× |
| Lazo, 2.000 tratti / 200 vertici | 10,7727 ms | 0,4951 ms | 21,76× |
| Lazo, 2.000 tratti / loop che racchiude tutto | 20,0085 ms | 9,3500 ms | 2,14× |
| Lazo, 2.000 tratti / loop lontano | 10,7024 ms | 0,1156 ms | 92,62× |
| XOPP, testo Unicode grande, writer completo | 38,1290 ms | 17,2948 ms | 2,20× |

La distribuzione conta: se tutti i tratti sono candidati, il ray casting resta
costoso e il guadagno è minore; se quasi tutti sono lontani, viene rimosso quasi
tutto il lavoro inutile. Non è corretto estrapolare il caso più favorevole
a ogni uso del lazo.

Un run separato del lazo con JIT disabilitato ha misurato, per 2.000 tratti e
200 vertici, 35,4515 → 1,8835 ms. Anche senza compilazione il lavoro eliminato
produce un vantaggio. Quel run precede soltanto gli ulteriori interventi XOPP.

Con il vero `libblitbuffer` di KOReader, cache calda e pagina BB8 da 1860×2480:
**1,0116 → 0,3108 ms**, circa **3,25×** nel solo `paintTo` della pagina cached.
Il test usa sette campioni da 100 paint; non invia refresh al display.

Comandi dalla directory del plugin:

```sh
luajit tools/bench-performance-audit.lua
luajit tools/bench-performance-audit.lua --jit-off
luajit tools/check-persistence-codec.lua ../koreader-src/base/ffi/bitser.lua
```

`tools/check-page-cache.lua` usa un runtime KOReader già configurato e la
sorgente baseline di `canvasrender.lua`, come indicato all'inizio del file.
La baseline è stata salvata in `.git/codex-backups/canvasrender-upstream.lua`.
I riferimenti terzi sono stati letti e il loro runtime esistente è stato usato
solo per prove fuori schermo: nessuna modifica o build nei progetti fratelli.

## 4. Analisi dei percorsi che determinano la fluidità

### 4.1 Input, pressione e avvio del tratto

Moduli: `stylusbridge`, `stylusinput`, `touchinput`, `pressure`, `penpressure`,
`canvas`, `zoomcanvas`.

- Gli eventi stylus vengono gestiti prima dei gesti: gli eventi realmente
  consumati non diventano swipe o tap che cambiano pagina durante la scrittura.
- La rotazione viene applicata su una copia dello slot solo quando necessaria.
- Vengono scartati contatti capacitivi/palmo e frame di sola prossimità.
- Il controllo della finestra superiore evita di disegnare dietro un dialogo.
- I cambi di tool chiudono un tratto e ne iniziano uno omogeneo.
- Il bridge ripristina handler, callback e slot al termine; la sospensione
  arresta il bridge e la ripresa lo riattiva senza disegnare sulla cover.
- La pressione arriva dallo slot; solo quando manca si interroga il digitizer
  fisico. Il fallback è corretto ma aggiunge un ioctl per campione pertinente.

Non sono state aumentate soglie di jitter, distanza o scarto degli outlier:
sono modifiche alla traccia e al palm rejection, non ottimizzazioni pure.
I test `palm`, `interaction`, `tools`, `zoom`, `suspend` coprono questi contratti.
Il costo effettivo dell'ioctl va misurato sull'hardware prima di introdurre
una frequenza ridotta, che cambierebbe la risposta alla pressione.

### 4.2 Rasterizzazione e ritaglio

Moduli: `renderer`, `penink`, `highlightink`, `geometryink`, `polygonink`, `raster`.

La nuova versione ha già eliminato molte delle vecchie stampate sovrapposte:
la penna costruisce span per riga; rettangoli e cerchi regolari usano primitive;
forme trasformate usano scanline; l'evidenziatore evita di riprocessare parti
costanti già coperte. Il percorso RGB è distinto e la matita conserva grana
in coordinate coerenti anche nei viewport.

Le ridipinture parziali scartano tratti per bounds e, per tratti lunghi,
blocchi del chunk index. Il renderer ritaglia segmenti/viewport senza alterare
il reticolo di campionamento rilevante. `Raster.rect` protegge il caso nativo
in cui lo stride del padre potrebbe far scrivere una riga oltre il viewport.

Prove native eseguite: clipping in grigio/RGB, rotazioni 0–3, viewport larghi
1/2/13 pixel, backend C/Lua, fineliner/fountain/pencil e forme RGB ruotate.
Sono passati anche i test sulle righe puntinate con 240 clip frazionari,
fuori schermo e vuoti. Non è stato reintrodotto il vecchio prototipo della carta.

Costo residuo: matita e blending RGB possono lavorare per pixel; il costo
aumenta con area e zoom. Sostituire questi percorsi senza equivalenza pixel
è rischioso: potrebbe cambiare densità della grana o sovrapposizione del marker.

### 4.3 Scheduling e refresh e-ink

Moduli: `canvasrefresh`, `zoomrefresh`, `notebook`, `safe`, `canvaslifecycle`.

- La toolbar e l'orologio dipingono direttamente e aggiornano la loro regione;
  non è più necessario il vecchio intervento che evitava il repaint del notebook.
- Le dirty region sono accorpate e ritagliate al contenuto.
- Il feedback veloce è separato dalla riconciliazione grigio/colore a riposo.
- La riconciliazione si rinvia se sono attivi penna, gomma, trasformazioni,
  drag o pan; non deve rallentare un contatto in corso.
- Il pan viene accorpato anche per la copia dei pixel, non soltanto per il refresh.
- La pulizia dopo il pan è una singola operazione a riposo.
- I callback sono identità stabili, annullabili in stop/suspend.
- `Safe.later` usa un ritardo positivo: le catene non devono trattenere per sempre
  il ciclo di KOReader prima che possa tornare a leggere input.

Il watchdog disabilita il JIT nelle chiamate controllate: è intenzionale,
perché i loop compilati non vengono interrotti dal count hook. I percorsi
critici di disegno sono protetti senza quel watchdog. Rimuovere protezioni
non costituisce un miglioramento accettabile della fluidità.

Non sono stati abbassati i default di refresh: più richieste al pannello
non equivalgono a più frame visualizzati. `refreshpolicy`, `zoomrefresh`,
`zoompan`, `safe` e `suspend` passano, ma non misurano ghosting reale.

### 4.4 Gomma, selezioni, geometria e storia

Moduli: `stroke`, `document`, `erasercanvas`, `lasso`, `selectioncanvas`,
`shape`, `shapecanvas`, `shapesnap`, `snapcanvas`.

Il remoto usa percorsi continui della gomma e aggrega i campioni per intervallo,
anziché attraversare la pagina a ogni singolo evento. La regione da mostrare
subito è distinta da quella più grande necessaria per undo. Taglia/incolla
conservano copie indipendenti; l'ordine dei tratti è rilevante per il blending.
Le cancellazioni multiple e il redo compattano già la lista in un passaggio.
Le preview di geometria hanno snapshot e aggiornamenti cadenzati.

Le operazioni di storia sono limitate a 200, ma ogni operazione può trattenere
liste, frammenti o copie di molti punti. Il limite sul numero di operazioni
non è un limite assoluto sui byte. Non va ridotto senza una decisione sul
numero di undo che il prodotto deve offrire.

Rimane un possibile costo nella gomma: le rimozioni per path e lo splitting
in batch possono ancora spostare array tramite `table.remove/table.insert`.
Una cancellazione ampia può quindi costare più del passaggio geometrico.
Una futura compattazione deve conservare gli indici dei record di undo,
identità della lista live, frammenti e ordine. Non basta copiare il fix già
presente in `removeStrokes`: sono percorsi diversi.

### 4.5 Zoom e bitmap

Moduli: `zoom`, `zoomcache`, `zoomcanvas`, `zoomrefresh`, `viewcanvas`,
`canvasrender`, `liveink`.

Lo zoom conserva una pagina ingrandita e copia il viewport per il pan.
Ripara regioni per gomma/undo anche fuori dal viewport corrente: senza questa
riparazione un pan successivo farebbe riapparire tratti cancellati.
Le chiavi comprendono pagina/revisione e carta; la coda di nuovo inchiostro
viene applicata prima di usare la cache. Sono coperti cambio carta,
revisioni, undo/redo, cancellazioni offscreen e liberazione delle risorse.

A 1× la cache di pagine ha un massimo di due entry e un budget di 12 MiB per
quelle entry. **Quel budget non è il budget totale del plugin.** Ci sono anche
sfondo, bitmap PDF, snapshot delle preview, cache dello zoom e testo.

Ordini di grandezza su 1860×2480, senza stride, allocator e altri oggetti:

- BB8 pieno: circa 4,40 MiB; due pagine più sfondo: circa 13,20 MiB.
- Bitmap 2× sull'intera pagina BB8: circa 17,60 MiB; l'area reale di contenuto
  può essere inferiore perché esclude la toolbar.
- La stessa bitmap RGB32: circa 70,40 MiB.
- Preview live/geometria possono aggiungere uno snapshot del framebuffer.

La cache zoom non ha lo stesso limite da 12 MiB delle pagine a 1×.
Un limite complessivo o tile cache sarebbe utile su dispositivi con poca RAM,
ma cambierebbe hit/miss e latenza del pan. Serve una misura di RSS e delle
allocazioni native sul modello di Kindle prima di sostituire l'algoritmo.

### 4.6 Testo

Moduli: `textobject`, `textcache`, `textpreview`, `textdialog`, `notebooktext`,
`textsizepicker`, `notebooksettings`.

La cache del layout confronta separatamente testo, font, dimensione, scala,
stile, colore e larghezza; non ricostruisce ogni volta una chiave contenente
l'intera stringa. Decorazioni, caret e sfondo sono compositati separatamente.
La cache è limitata a 32 entry e 8 milioni di pixel; il testo corrente può
superare da solo il limite, per non liberare un widget durante il paint.
Il drag usa temporaneamente una rappresentazione opaca e ripristina lo stile.

Il testo trasparente inverte la mask, fa il blit e la reinverte. Una mask
inversa conservata potrebbe risparmiare lavoro, ma raddoppierebbe parte della
memoria e richiede test con antialiasing/font reali. Non è stato sostituito
questo percorso sulla base dei soli stub.

### 4.7 Salvataggio e caricamento

Moduli: `document`, `library`, API KOReader `Persist` letta come riferimento.

Il remoto riusa le tabelle serializzate delle pagine non modificate;
`_touchPage` invalida quelle modificate. Questo risparmia costruzione di tabelle,
ma il codec e il filesystem devono ancora attraversare/scrivere il documento
completo. L'autosave attende una pausa e si rinvia durante interazioni attive.
Al cambio pagina il salvataggio non precede più il paint richiesto.

Il load validato costruisce le nuove pagine prima di sostituire lo stato
aperto. Rifiuta liste/coordinate/width/colori non validi e normalizza indice
pagina/origine non finiti. La compatibilità con RGB è stata provata anche
con il vero bitser, oltre agli stub. Nei test di metadata lo store viene
copiato, per non far passare il round trip grazie a riferimenti condivisi.

Limiti residui:

- Non è un validatore completo di tutti i metadata opzionali: testo, font,
  sfondi PDF e dimensioni richiedono altri test contro documenti malformati.
- Atomic rename protegge dal file principale parzialmente sostituito, ma
  non dimostra da solo persistenza dopo perdita di alimentazione.
- Nel `Persist:save` di KOReader esaminato, il percorso bitser non verifica
  il risultato di `file:write` e `file:close`. Notebook dipende da quel risultato;
  lo stub e il probe bitser non dimostrano la gestione di disco pieno nel
  vero Persist. Non è stato modificato il progetto terzo. Un eventuale writer
  proprio deve preservare codec e durabilità e richiede test dedicati.
- L'indice della pagina attuale cambia anche senza modificare l'inchiostro:
  eliminare il save in chiusura solo perché `dirty` è falso può perdere
  la posizione di riapertura. Non è stato introdotto quel presunto risparmio.

### 4.8 Galleria, miniature e libreria

Moduli: `gallery`, `thumbnail`, `pagepanel`, `library`, `papersample`,
`newnotebook`, widget/menu/template picker.

La galleria usa miniature persistenti e generazione differita; il lookup cached
usa stat anziché aprire e rasterizzare ogni quaderno durante il layout.
Generare una miniatura deve comunque caricare il quaderno intero. La griglia
pagine rasterizza le pagine visibili a scala ridotta, senza bitmap persistenti
proprie. Con pagine dense può diventare un costo CPU significativo.

La cache miniature decide la freschezza dall'mtime, non dal contenuto o dalle
dimensioni richieste. Questo può lasciare una miniatura vecchia per due save
nello stesso tick del filesystem o dopo cambi di layout. È un caso da coprire
con test specifici; usare l'hash completo a ogni card renderebbe più lenta
l'apertura della galleria. Un'invalidazione esplicita in save o un sidecar
può essere preferibile, ma coinvolge più percorsi (rename/move/import).

Le protezioni locali sui symlink evitano cicli e cancellazioni oltre la directory
richiesta; le copie puliscono l'output parziale su errore. Sono controlli di
correttezza con qualche stat aggiuntivo, non accelerazioni della scrittura.
Non forniscono una transazione tra più file né eliminano le race del filesystem.

### 4.9 Export, sharing e PDF

Moduli: `export`, `exportprogress`, `galleryexport`, `share`, `xopp`, `svg`,
`pdfbackground`.

Il PDF principale è già diviso in render / pack / compress-write, con progress
e annullamento. `packPage` usa copie di riga native sul buffer BB8 non ruotato,
leggendo solo la larghezza visibile; altri buffer usano il percorso generico.
RLE concatena gruppi di literal invece di creare una stringa per ogni pixel.

Tuttavia una fase completa può essere ancora lunga: non esiste un limite in
millisecondi all'interno del render o della compressione di una pagina.
Nella condivisione si usa `Export.toPDF`, wrapper sincrono che esegue tutte le
fasi senza yield. `Safe.later` tra notebook non basta a rendere responsivo
un singolo quaderno lungo. Questo è il principale candidato ancora aperto
per ridurre blocchi percepiti durante sharing; il nuovo CRC32 migliora XOPP
ma non rende asincrono l'intero writer.

Il cache sharing legge tutto il `.scribe` per ottenere la chiave anche in caso
di hit; la galleria carica prima tutto il documento. Le letture possono essere
ridondanti, ma saltarle richiede conservare il controllo degli allegati XOPP.
Il checksum attuale è a 31 bit: non è collision-proof. Inoltre non incorpora
contenuto dei PDF esterni o versione dell'exporter. Un cambio del PDF sottostante
o dell'algoritmo può riusare un risultato non più attuale. I nuovi test
proteggono errori dichiarati e modifiche normali, non provano assenza di collisioni.

`pdfbackground` mantiene un raster corrente, riusabile nei repaint regionali.
Sfogliando miniature di diversi PDF il cache viene sostituito e MuPDF può
riaprire più volte documenti. Conservare più raster senza budget aggraverebbe
la pressione sulla memoria. `inspect/size` andrebbero inoltre provati con
errori dopo open, perché la chiusura delle risorse non è protetta in tutti
quei percorsi come lo è in `draw`.

XOPP conserva tratti editabili, ma il writer usa colori nero/grigio e non
riproduce tutti gli stili del testo o i riempimenti delle forme. SVG ha un
percorso diverso e omette esplicitamente carta/PDF. Questi sono limiti di
fedeltà dei formati, non regressioni introdotte dall'ottimizzazione CRC.
Il bundle XOPP + PDF non è una transazione unica: se l'allegato fallisce dopo
il rename primario, non è garantito il ripristino di un vecchio bundle.
I test I/O aggiunti non vengono presentati come prova di atomicità del bundle.

## 5. Interventi successivi ordinati per beneficio e rischio

| Priorità | Candidato | Stato dell'evidenza | Test necessari prima di applicarlo |
|---|---|---|---|
| Alta | PDF sharing tramite job incrementale | Percorso sincrono presente in `galleryexport` | Yield tra fasi, callback una volta, annullamento, cache/allegati, failure e chiusura della galleria |
| Alta | Budget complessivo bitmap/zoom | Allocazione cresce quadraticamente con zoom; budget globale assente | Pixel e pan equivalenti, RSS reale, eviction, transizioni colore e memoria insufficiente |
| Alta | Durabilità/fallimenti del vero Persist | Risultati write/close non controllati nel riferimento | Disco pieno, partial write, close/fsync/rename falliti, precedente file intatto e dirty mantenuto |
| Media | Compattazione della gomma in batch | Splice ripetuti ancora presenti; beneficio da misurare | Oracle su rimozioni/frammenti, batch multipli, undo/redo, identità e ordine, pixel regionali |
| Media | Invalidation miniature robusta | Chiave soltanto mtime | Due save stesso tick, cambio dimensioni, rename/move/import e costo layout senza hash completo |
| Media | Cache export dipendente da allegati/versione | Chiave notebook soltanto | PDF sostituito, upgrade exporter, vecchi cache, collisioni e cleanup |
| Media | Validator dei metadata opzionali | Copertura parziale, no schema completo | Fuzz mirato su text/font/PDF/size, file precedenti e stato aperto preservato |
| Media | Cache delle tile del page panel | Raster ripetuto delle pagine visibili | Revisione/carta/dimensioni/tema, eviction e confronto pixel con font/PDF veri |
| Bassa | Mask testo pronta per compositing | Due inversioni presenti, beneficio non profilato | Antialiasing, colore, stile, invalidation, memoria e pixel native |
| Bassa | Lookup CRC o writer streaming ulteriori | CRC ora migliorato; XML completo ancora in memoria | XOPP identico, input molto grandi, RSS e cleanup su errore |

Questi sono candidati, non ottimizzazioni già validate da applicare tutte
insieme. Alcuni richiedono un diverso compromesso memoria/latency o una nuova
transazione: sarebbe scorretto dichiararli privi di regressioni senza quelle prove.

## 6. Verifica effettuata

`make verify`: **41 suite configurate passate**, lint dei **67 moduli Lua**
senza warning/errori e cataloghi controllati con `msgfmt --check`.

Copertura aggiunta o adattata:

- `spec/lasso.lua`: 18 test, bounds una volta e confronto API su loop irregolari.
- `spec/performance.lua`: numero di copie, pixel, carta dopo hit di altra pagina,
  revisioni, undo/redo, batch, eviction e free.
- `spec/gallery.lua`: 72 test, compresi omonimi e compagni XOPP in staging.
- `spec/persistence.lua`: 31 test, stato preservato, indici/origini, RGB e metadata.
- `spec/storage.lua`: 10 test, symlink/cicli e errori di copia/chiusura.
- `spec/sharecache.lua`: 7 test, chiavi, chunk successivi e fault injection.
- `spec/interchange.lua`: gzip multi-blocco, Unicode, CRC indipendente e limite
  sul lavoro di checksum, oltre alla fedeltà già testata dei metadata.
- `spec/xoppstorage.lua`: 5 test, successo e fallimenti primario/sorgente/allegato.

Prove aggiuntive fuori dalla suite ordinaria:

1. Confronto deterministico del lazo contro la vera sorgente baseline.
2. XOPP completo byte-identico alla baseline, oltre al decoder gzip indipendente.
3. `check-persistence-codec`: codec bitser KOReader reale, file temporanei veri,
   save/load atomico del Document, RGB, Unicode, PDF, pagine e undo/redo.
   L'adapter del test non sostituisce una prova di fsync del vero Persist.
4. `check-page-cache`: blitbuffer nativi, grigio/RGB, backend Lua/C, confronto
   pixel prima/dopo, mutazioni, template, selezioni e ripristino regionale.
5. `check-raster` e `check-color-render` del remoto, eseguiti sul runtime
   già disponibile; clipping/rotazioni/stride/RGB passati.
6. `make check-package`: zip valido, plugin e traduzioni presenti, suite escluse.
7. `git diff --check`: nessun errore di whitespace; nessun conflitto Git rimasto.

I test ordinari usano stub per molte API UI. Questo accelera e isola il bench,
ma non misura il pannello e non verifica ogni font, driver o percorso MuPDF.
Le prove native riducono il rischio relativo ai pixel; non sostituiscono la
verifica fisica della fluidità, del ghosting o dei picchi di RAM sul Kindle.

## 7. Misura sul Kindle che renderebbe il prossimo passo affidabile

Non è stato fatto deploy. Per una successiva prova hardware servono notebook
riproducibili piccoli e densi, carta puntinata/PDF, zoom, marker/matita, lazi,
gomma, drag, undo e sharing lungo.

Misurare separatamente:

- tempo del callback input e latenza da campione a richiesta refresh;
- repaint CPU e numero/area delle richieste fast/UI/full;
- p50/p95/p99, non solo tempo medio;
- memoria nativa/RSS e pause GC nei cambi di tool/pagina/zoom;
- tempo di autosave e numero di byte realmente scritti;
- intervallo massimo senza input durante export e sharing;
- correttezza di riapertura, undo/redo e cleanup dopo suspend/resume.

Le costanti del tuning vanno confrontate sullo stesso dispositivo e contenuto.
Il fatto che il desktop calcoli prima un bitmap non permette di stabilire
quanto prima il pannello e-ink finirà la waveform. Gli interventi applicati
riducono lavoro dimostrabilmente ridondante; il massimo prestazionale sul
Kindle rimane una proprietà da profilare sull'hardware, non una garanzia
ricavabile dalla sola lettura del codice.
