# Notebook: responsabilità, prestazioni, copertura e aggiornamento sul Kindle

Analisi del 1 ottobre 2026. Il ramo `dev`, HEAD `7410d78`, è stato verificato con
fetch e pull fast-forward: nessun commit remoto entrante. Il checkout conteneva
numerose modifiche locali su marker, gomma, ordine delle forme, persistenza,
import/export e traduzioni. Sono state preservate. La baseline dei confronti è
**quel checkout locale completo**, non il solo HEAD e non la release v1.4.0.

Backup iniziale recuperabile: `/tmp/notebook-task-backup/preexisting.patch`,
`preexisting-untracked.tar.gz` e `baseline-lua/`. Non sono stati effettuati
commit, pubblicazioni, deploy o riavvii del KOReader dell'utente. I repository
fratelli sono stati usati come riferimenti in sola lettura.

## 1. Risultati e loro limiti

Il problema principale non è il numero dei file: è quante responsabilità e quanti
stati devono essere tenuti contemporaneamente corretti da una funzione. Separare
un file senza chiarire la proprietà dello stato sposta il problema. Qui sono
state estratte responsabilità con confini verificabili, mantenendo le API dei
widget e del documento.

- `document.lua`: 879 → 725 righe. `documentstorage.lua` possiede codec,
  validazione dei dati, serializzazione e salvataggio atomico del file.
- `gallery.lua`: 1567 → 1065 righe, nonostante l'aggiunta del blocco durante
  l'aggiornamento e dell'export selettivo. `gallerycard.lua` possiede una scheda;
  `galleryheader.lua` layout adattivo, selezione visibile, ordinamento e Updates.
- `main.lua`: 275 → 222 righe. `pluginicons.lua` sincronizza le icone; il punto
  d'ingresso resta responsabile di dispatcher, istanze e apertura dei notebook.
- L'updater aggiunge quattro moduli distinti: regole pure, trasporto, installazione,
  interfaccia/pianificazione. Non inserisce rete o sostituzione dei file nel modello.
- L'export selettivo usa `pageselection.lua`, una vista delle pagine, e
  `exportpagesdialog.lua`, il dialogo. I writer PDF/SVG/XOPP ricevono la stessa API
  documento di prima. Non occorre introdurre tre implementazioni dei range.

Le righe comprendono commenti: non sono una misura di complessità algoritmica.
Il modello mantiene ancora storia, operazioni sulle pagine e cancellazione; la
galleria mantiene navigazione, selezione e operazioni sui file. La sezione 3
indica ulteriori divisioni sensate, senza fingere che questa revisione le abbia
già effettuate.

## 2. Percorsi critici e proprietà dello stato

### Digitizer → vettori → pixels → pannello

`stylusbridge` acquisisce la disponibilità del canale; `stylusinput` trasforma e
filtra gli eventi, controlla il widget modale e instrada il tool; `touchinput`
gestisce il dito e i gesti. `penpressure` normalizza la risposta. `stroke`
possiede i punti e le geometrie derivate; `document` registra l'operazione.
`renderer` sceglie il rasterizzatore; `canvasrender` ricostruisce la regione;
`canvasrefresh` decide quando chiedere una waveform. A zoom >1 si aggiungono
`zoomcanvas`, `zoomcache` e `zoomrefresh`.

Sono tre budget diversi: elaborazione degli eventi, calcolo dei pixels e latenza
fisica del display. Un renderer più rapido non giustifica abbassare a caso
`refresh_interval_ms` o `erase_repaint_ms`: si può creare più lavoro in coda di
quanto il pannello smaltisca. Una soglia sul tempo CPU da sola non verifica
l'ultimo campione al rilascio, il ghosting, il palmo o la risposta dei popover.

### Modello → storia → dati persistiti

I pixels non sono la fonte della verità. `Document` mantiene pagine e tratti;
revisioni invalidano bitmap e `_serialized`. Un batch raggruppa un gesto in una
singola operazione; le liste della storia sono copie di riferimenti, non la lista
viva della pagina. Condividere la lista viva sarebbe una regressione di undo,
anche se facesse migliorare allocazioni e benchmark.

`DocumentStorage:save` riusa la serializzazione dei tratti delle pagine pulite,
ma il codec codifica e scrive ancora **l'intero documento**. Non è un salvataggio
incrementale su disco. L'autosave del canvas è già subordinato a `dirty` e al
termine delle interazioni: il caso `save/unchanged` misura l'API esplicita, non
una scrittura che avvenga necessariamente ogni 2,5 secondi a notebook immobile.
Il close esplicito salva anche lo stato della pagina corrente. Una scorciatoia
«se non dirty non salvare» cambierebbe queste garanzie: non è stata introdotta.

### Galleria → miniature → apertura

`Library.list` visita e ordina gli elementi; non carica ogni notebook. Il layout
chiede `Thumbnail.cached`, basato su stat; i miss entrano nella coda della
galleria. `Safe.later` lascia passare l'input fra job. Tuttavia una singola
`Thumbnail.get` carica l'intero notebook per scegliere una pagina e disegnarla:
il fatto che i job siano separati non rende interrompibile quel singolo job.

Il punto migliore per ottimizzare è ridurre il lavoro di un miss e invalidare
bene i risultati. La cache disk deve restare coerente con timestamp, dimensioni
della miniatura, rotazione e contenuto. Il codice attuale usa soprattutto mtime:
le modifiche nello stesso secondo e il cambio di dimensione meritano prove
specifiche; sono rischi da verificare, non bug qui dimostrati.

### Condivisione ed export

La condivisione non ha soltanto un costo di rendering: `Share.cachedExport`
legge e calcola un hash dell'intero `.scribe` anche per determinare un hit. Una
cache utile può quindi avere un costo di ingresso importante. Gli XOPP con
sfondo PDF hanno un file compagno: tempi e correttezza devono includere entrambi.
Il job PDF divide il lavoro in rendering, preparazione e RLE; cancellare deve
rimuovere soltanto il temporaneo, preservando la destinazione preesistente.

## 3. Divisioni successive raccomandate

| Componente | Responsabilità rimaste | Divisione proposta | Contratto da mantenere |
|---|---|---|---|
| `document.lua` | Edit, history, pagine, eraser, metadati | Prima estrarre replay/bounds della storia; poi applicazione geometrica dell'eraser | Identità dei tratti, ordine, batch unico, revisioni e dirty |
| `gallery.lua` | Navigazione, coda thumbnail, dialoghi CRUD, selezione, bulk action | Worker thumbnail cancellabile; controller delle operazioni sui file | Folder/page stabili, holder del launcher, nessun job per schermata chiusa |
| `library.lua` | Root/migrazione, indicizzazione, copie, rename/move/delete ricorsivi | `libraryindex` e operazioni storage iniettate | Nomi, file compagni, fallimenti I/O, niente traversal di symlink |
| `canvas.lua` | Stato condiviso e coordinamento di numerosi mixin | Piccoli oggetti di stato per contatto, selezione, refresh e cache | Un solo proprietario di ogni timer/buffer; niente doppio consumo degli eventi |
| `stroke.lua` | Punti, bounds, indice, clone/transform, hit test, split, serializzazione | Separare calcoli derivati e split quando il profiling ne giustifica l'interfaccia | Cache invalidate per ogni mutazione; formato persistito compatibile |
| `pagepanel.lua` | Layout, miniature e manipolazione delle pagine | Scheda pagina e queue delle miniature condivisa soltanto se i contratti coincidono | Duplicazione indipendente, template e sfondo PDF corretti |
| `galleryexport.lua` | Prepare share, nomi, copie, writer, job/progress | Piano di output separato dall'esecuzione, con risultati strutturati | Collisioni case-insensitive, companion XOPP, fallimenti parziali |
| `notebook.lua` | Orchestrazione, history UI, close/suspend e repaint | Comandi del documento con esiti tipizzati invece di ulteriori callback ad hoc | Save fallito lascia aperto il notebook; input e timer sempre restituiti |

Non conviene creare un'interfaccia generica tra tutte le classi solo per ridurre
le righe. I mixin del canvas dipendono da campi impliciti di `self`: dividere ogni
metodo in un altro file aumenterebbe il numero di posti da consultare. Prima
vanno documentati e ridotti i campi condivisi. La cache dovrebbe esporre
invalidazione/release; la geometria dovrebbe restituire bounds e frammenti;
soltanto il controller dovrebbe decidere refresh e scheduling.

## 4. L'harness precedente non copriva tutte le feature

Il Makefile chiamava «test bench» le suite di correttezza; non era una misura
completa delle prestazioni. Sono strumenti necessari ma diversi.

| Strumento precedente | Misurava | Limite rilevante |
|---|---|---|
| `bench-notebook` | Cambio pagina, save, history | Un solo tempo medio; save pulito esplicito; file/settings temporanei con nomi fissi |
| `bench-pen`, `bench-marker` | Pennelli e tratti | CPU offscreen; nessuna coda del digitizer/pannello; fixtures ristrette |
| `bench-render` | Clip di penna/marker | Controllava solo 1860 righe di un buffer alto 2480 e stampava errori senza fallire: corretto in questa revisione |
| `bench-marker-area` | Geometria dopo tagli, render | Media; numero limitato di marker; non tutta la vita delle cache |
| `bench-eraser` | Eraser prima/dopo, undo/redo | Stub e moduli di baseline parziali: il risultato riguarda il modello, non i pixels o il dispositivo |
| `bench-marker-repaint` | Dirty repaint del marker | Caso specifico; importante per l'equivalenza, insufficiente per classificare tutta l'app |
| `bench-template` | Carta intera, viewport e clip | Buona verifica pixels; non include cache/background PDF o concorrenza con input |
| `bench-drag` | Campioni aggregati, endpoint e undo | Impostazioni/path fissi; non latenza fisica; non memoria di snapshot |
| `bench-dashes` | Contorno selezione | Caso locale; utile, ma non la selezione completa |
| `benchmark-export` | RLE di carta e rumore | Encoder, non export completo né layout, compressione e I/O insieme |
| `bench-performance-audit` | Lasso/XOPP rispetto a `38fcfd5` | Baseline hardcoded, I/O XOPP sostituito in memoria: non rappresenta la versione remota corrente o una scrittura reale |

Le suite `performance`, `zoomhistory`, `liveink`, `raster`, `templateclip`,
`refreshpolicy`, `suspend`, `storage`, `persistence`, `sharecache`, `xoppstorage`
controllano garanzie importanti: pixels, chiamate ridondanti, eviction/free,
atomicità logica, symlink e I/O fallito. Non danno da sole p95 di latenza, RSS,
consumo batteria o latenza del pannello.

## 5. Nuovo runner riproducibile

`tools/benchmark.py` orchestra `tools/bench-suite.lua`. Usa sorgenti tramite il
loader privato e il vero runtime KOReader/blitbuffer. Le fixture e i settings
sono isolati in una directory temporanea nuova per processo. Il pannello non
riceve refresh, neppure da stop/flush del canvas. Gli input aperti dal runtime
vengono chiusi al termine. Non viene effettuato un deploy.

Il JSON registra versione/architettura LuaJIT, JIT on/off, scala dei dati,
dimensioni/bpp, hash dei sorgenti e della fixture, mediane/minimi/p95 di CPU e
tempo trascorso, heap prima/dopo, heap trattenuto dopo GC, delta RSS, tempo della
raccolta completa esplicita, frequenza CPU quando disponibile e contatori del
caso. `--compare` rifiuta host/runtime/fixture/scala incompatibili.

Sono nove gruppi misurati dopo un warm-up. Il p95 empirico coincide qui con il
campione massimo: non è una stima robusta della coda di un'interazione umana.
Il delta heap non è il totale allocato e non è il picco. RSS finale-prima non
include un picco nato e liberato durante l'operazione. I bitmap FFI non sono
interamente rappresentati dal contatore GC Lua. Il tempo di GC esplicito visita
anche la fixture globale viva: non va aggiunto a ogni costo come se fosse il
GC causato soltanto da quella feature.

`--filter` permette controlli mirati. `--extended` aggiunge testo/forme, carta,
background PDF, export selettivo, share-cache key, history piena, miniature su
disco e listing di 1001 notebook. `--scale 1|2|4` porta la fixture da 400 a
1600 tratti per pagina. `--fail-regression 0.20` segnala candidati con aumento
CPU >20%; non certifica causalità e non dovrebbe essere una soglia assoluta
indifferente all'hardware di CI.

La modalità `--ssh` invia una copia isolata dei sorgenti e fa girare lo stesso
strumento sul Kindle. `--remote-work-root /mnt/us` consente di misurare i file
su flash reale in una cartella temporanea separata. Le misure eseguite qui hanno
usato `/tmp`: i tempi di save/load includono codec e I/O di quella destinazione,
**non certificano la latenza della flash USB**. L'ultima sonda SSH dopo le prove
non rispondeva; il confronto flash non è stato effettuato.

## 6. Misure sul Kindle Scribe

Confronto completo conservato in
`results/benchmark-kindle-final-2026-10-01.json`. JIT on, buffer BB8 1860×2480,
quattro pagine, 400 tratti misti da 48 punti per pagina. I casi eraser usano un
tratto ondulato da 1001 punti, dodici tagli, undo/redo. PDF a 930×1240: non è
un export alla piena risoluzione dello Scribe. Il governor letto era `ondemand`;
nel confronto finale le letture dopo i gruppi erano a 2 GHz. Non è stato cambiato
il governor né impostata una frequenza.

| Caso | Prima CPU mediana (ms) | Dopo (ms) | Interpretazione |
| `save/one-page-edit` | 79.413 | 82.738 | Scrive ancora l’intero notebook; priorità I/O/codec |
| `load/full-notebook` | 91.195 | 99.709 | ~100 ms; caricare tutto pesa sulle miniature |
| `repaint/production-64x64` | 2.434 | 2.157 | Percorso vero con filtro bounds, ~2 ms |
| `cache/page-warm` | 6.723 | 4.476 | Velocissimo rispetto al cold; risultato variabile fra run |
| `zoom/2x-cold` | 476.739 | 355.288 | Il miss è costoso; il bitmap da solo vale 17,31 MiB |
| `zoom/2x-pan-warm` | 5.350 | 4.536 | La copia evita la ricostruzione |
| `render/thumbnail-page` | 225.401 | 179.829 | Gain nel workflow; microbenchmark isolato JIT non lo conferma nella stessa misura |
| `eraser/area-highlighter` | 88.408 | 100.372 | 12 tagli + setup/history, non 100 ms per singolo evento |
| `export/pdf-4-pages` | 963.258 | 699.746 | ~27% meno CPU in questo confronto integrato |
| `export/rle-dense` | 71.880 | 79.077 | Variazione da controllare; codice RLE invariato |

Ulteriori casi, senza baseline equivalente nel vecchio harness:

| Caso | CPU mediana (ms) | Costo nascosto / significato |
|---|---:|---|
| `export/pdf-selected-2-pages` | 333.870 | ~52% meno CPU rispetto al completo; pagina corretta, senza mutare il modello |
| `render/text-and-filled-shapes` | 184.291 | 40 testi multilingue + 40 forme; attenzione alla cache/font |
| `background/pdf-cold` | 405.830 | Miss MuPDF: costo alto anche quando le annotazioni sono poche |
| `background/pdf-warm` | 7.192 | Cache essenziale; un cambio di dimensioni invalida |
| `share/cache-key-full-file` | 59.013 | ~59 ms per conoscere la chiave cache su file ~1,6 MB |
| `history/200-batches` | 11.706 | Snapshot: ~2965 KiB di heap delta nel caso |
| `thumbnail/disk-cold` | 342.627 | Load + raster + PNG; un job singolo blocca per ~344 ms wall |
| `thumbnail/disk-warm` | 0.028 | Stat, niente decode/render |
| `library/list-1001` | 69.175 | Filesystem + sort; non apertura di 1001 documenti |

### Non nascondere le misure contraddittorie

Nel primo run completo la cache calda sembrava passare da 3,406 a 6,741 ms
(+98%). Un follow-up mirato è passato invece a ratio 0,656; il run finale a
0,666. La cache non ridisegna tratti; il follow-up conta una copia per chiamata.
Non c'è evidenza sufficiente per attribuire il primo segnale a una regressione
del codice, ma non è corretto cancellarlo dai dati: entrambi i report sono
conservati.

Lo stesso vale per il gain della miniatura: nel primo workflow completo il ratio
era 0,430, nel finale 0,798, nel microbenchmark isolato con JIT on 0,984 e con JIT
off 0,909. Tracing, codice caldo precedente, GC e stato della macchina cambiano
il risultato. Il gain ripetibile a JIT off è più modesto. Le percentuali del primo
run non sono una promessa di «57% più veloce» per qualunque uso. Il renderer
rimuove lavoro realmente inutile e ha superato equivalenza pixels; la misura
end-to-end va ripetuta sulle fixture dell'utente.

Nel finale eraser marker +13,5%, RLE dense +10%, load +9,3% sono candidati da
osservare. Quei percorsi algoritmici non sono stati ottimizzati in questa
revisione; il caso marker nel run precedente era +2,1%. Non sono stati dichiarati
«nessuna regressione» o «tutto più veloce». Per decisioni su differenze di questo
ordine servono processi alternati A/B/B/A, più warm-up, distribuzioni per-sample,
frequenza/load e dataset identici. Restano da aggiungere picco RSS e tail-latency
dell'event loop, non ricavabili onestamente da questi delta.

## 7. Priorità con miglior rapporto beneficio/rischio

1. **Miss della miniatura e sfondi PDF.** Sul dispositivo sono ~343 e ~406 ms
   CPU. Prima migliorare riuso e invalidazione, poi eventuale lettura di una sola
   pagina. Controprova obbligatoria: cambi dimensione/rotazione, PDF modificato,
   template, stessa mtime, folder cambiata e schermata chiusa. Una cache più lunga
   potrebbe dare ottimi numeri e pixels vecchi.
2. **Rendering scalato / cold zoom.** È stato eliminato il viewport e il clipping
   per segmenti quando il tratto, con margine conservativo del pennello, è tutto
   nel buffer. I tratti al bordo restano sul percorso originale. Non cambia
   pressione, coordinate, grana, colore o formato. 576 confronti nativi
   grayscale/RGB, quattro rotazioni, quattro scale, tre offset e sei pennelli/
   forme hanno dato pixels identici. Il budget memory aggregato va misurato.
3. **Allocazioni del raster e history.** `penink` costruisce punti temporanei per
   segmento; il marker crea hull/parti. Prima profilare allocazioni, poi valutare
   coordinate scalari o strutture riusate. Non introdurre pooling condiviso con
   storia/cache: comprometterebbe immutabilità e undo. Il GC completo nella
   fixture è decine di ms; non è automaticamente tutto causato da un pennello.
4. **Autosave e caricamento dei notebook lunghi.** ~83/~100 ms per 4×400 tratti
   in `/tmp`; il fattore flash è ancora da misurare. Il cache `_serialized`
   evita di ricostruire pagine pulite ma non il codec/full write. Formato
   incrementale/journal richiede recupero dopo interruzione, migrazione, limite
   spazio e test di crash; non vale una modifica frettolosa del codec.
5. **Share-cache hit.** ~59 ms di hash completo: in un invio già cached può
   superare ampiamente il resto. Prima misurare l'intero prepare/share con
   file reali; valutare fingerprint forte memorizzato in fase di save. Usare solo
   mtime/size introdurrebbe collisioni su modifiche nello stesso secondo.
6. **Listing enorme.** ~69 ms per 1001 elementi: ottimizzare solo dopo aver
   separato stat, sort, layout e immagini. Un indice persistente costa
   invalidazione per modifiche USB/LocalSend e migrazioni; non deve diventare
   una seconda fonte della verità.
7. **Lasso/history semplici.** ~1,8/~0,28 ms: non sono la prima priorità in questa
   fixture. Dataset avversi con lasso contenente tutta la pagina e molte migliaia
   di punti possono cambiare l'ordine delle priorità.

## 8. Memoria: un singolo limite non è il limite dell'app

A BB8 1860×2480 un frame è 4.612.800 byte (4,40 MiB). Il page cache è limitato a
12 MiB e due entry, ma possono coesistere sfondo, due snapshot, live-ink,
background PDF, testo e zoom. Il solo zoom 2x sull'area 1860×2440 vale 18.153.600
byte (17,31 MiB). A RGB32 i bytes quadruplicano. `textcache` limita 32 entry e
8 milioni di pixels, non necessariamente 8 MiB su qualunque backend.

Per un benchmark di memoria utile occorrono: picco RSS campionato durante il job,
numero/bytes dei BB vivi, cache evictions, dimensione history, peak temporaneo del
codec e degli XML/RLE. Cicli ripetuti open → draw → undo → zoom → close devono
ritornare a un plateau; una sola `collectgarbage` non dimostra assenza di leak FFI.
Non è stato aumentato un limite cache per ottenere un tempo migliore.

## 9. Coverage: cosa è misurato e cosa manca ancora

| Feature | Nuovo benchmark | Correttezza già verificata / aggiunta | Prossima misura utile |
|---|---|---|---|
| Penna, matita, marker | Rendering misto e scaled; marker area | `run`, `highlightink`, `liveink`, `renderfast`, native pixels | Live samples/lift-off, p95 callback e refresh/area |
| Gomma area | Penna/marker 1001 punti, 12 tagli | `eraser`, `markerarea`, `zoomhistory` | Oggetto intero, sweep denso, no-hit, crescita frammenti e pixels |
| Lasso | 200 vertici su pagina | `lasso`, `lassoedit`, `bulkdelete` | Drag/resize/copy-paste end-to-end, loop concavi/enclosing |
| Forme | 40 forme piene con testo; native equivalenza | `shape`, `shapesnap`, `interaction`, `geometryink` | Riconoscimento di tratti lunghi/rumorosi, snapping e preview |
| Testo | 40 testi multilingue warm | `textlayout`, `regressions` | Cold font, wrapping lungo, edit live e invalidazione/cache thrash |
| Carta | Blank/lined/grid/dots | `templateclip`, check nativi | Narrow/checklist, fraction/zoom/offscreen e cambio template |
| Zoom | Cold 2x, warm pan | `zoom`, `zoompan`, `zoomrefresh`, `zoomhistory` | Repair locale, RGB memory, pan bursts e ultima posizione |
| Pagina cache | Cold/warm; draw/blit counters | `performance`, `regressions` | LRU miss su 3+ pagine, resize/rotation e PDF alternati |
| Persistence | Unchanged, edit singola pagina, full load | `persistence`, `storage` | Flash vera, 50+ pagine, save fallito, corruzione, power-loss |
| Gallery | Disk thumbnail cold/warm, listing 1001 | `gallery`, `gallery_polish`, `suspend` | Layout+queue completo, folder change e input fra job |
| PDF background | MuPDF cold/warm | `tools`, `interchange`, check device | File pesanti, rotazioni, pagesize mista e PDF sostituito |
| Export PDF | Intero, subset, RLE | `export_polish`, `pageselection`, writer reale | Alta risoluzione, cancellazione e massimo slice non interrompibile |
| SVG/XOPP | XOPP completo; subset API condivisa | `svg`, `interchange`, `xoppstorage` | SVG, gzip/import, companion PDF e XML molto grande |
| Share | Hash cache key | `sharecache`, collisioni nomi, copy errors | Prepare hit/miss + invio LocalSend reale |
| Gestures/palmo/modal/suspend | Nessun replay temporizzato nativo nel runner | `palm`, `interaction`, `suspend`, `refreshpolicy` | Trace input anonimizzata, timer virtuale e endpoint invarianti |
| Updates | Probe reale HTTPS+ZIP e layout nativo | Policy, rollback, cleanup, scheduling, package validation | Captive portal, rate-limit, disco pieno e interruzione di alimentazione |
| UI/localizzazione | Probe nativo Updates/range | Cataloghi completi e layout emulator/Kindle | Font scale e lingue molto larghe/RTL |
| Pannello/batteria | Non misurati offscreen | Prova d'uso ancora necessaria | Waveform/queue timestamps, video o osservazione e sessione prolungata |

Non copre quindi «tutte le feature e tutti i costi». Ora rende visibili molte
aree prima assenti e mette per iscritto quelle ancora escluse. Una feature
corretta nei test può essere lenta; una feature veloce può perdere l'ultimo punto
o usare una bitmap sbagliata. Per ogni ottimizzazione occorrono entrambi i tipi
di prova.

## 10. Aggiornamenti ufficiali direttamente dal Kindle

Pulsante **Updates** a destra della versione nella galleria. Il menu contiene
**Check updates weekly**, selezionato per default con checkbox reale, e
**Check update**. Preferenza e timestamp sono in `G_reader_settings`. Il
controllo automatico è settimanale, non accende il Wi-Fi, non mostra messaggi
quando non c'è nulla di nuovo e ritenta gli errori al massimo ogni ora quando
online. Il controllo manuale usa `NetworkMgr:runWhenOnline`.

La sorgente è `/repos/pierspad/notebook.koplugin/releases/latest`. Sono comunque
verificati `draft=false`, `prerelease=false`, tag `vMAJOR.MINOR.PATCH` senza
suffisso, nome/URL dell'asset esatti, dimensione e digest SHA-256. GitHub espone
questi campi nella [REST API delle release](https://docs.github.com/en/rest/releases/releases).
La release osservata e verificata era **v1.4.0**, ZIP da 260.468 byte. Il codice
locale resta v1.5.0-dev.3: non è stato trasformato in una release ufficiale.
Nessun pacchetto `-dev` viene proposto/installato dall'updater. Non viene fatto
un downgrade da v1.5.0-dev.3 a v1.4.0; v1.5.0 stabile supersede invece il suo dev.

Il trasferimento curl è asincrono rispetto alla UI, solo HTTPS anche nei redirect,
con verifica TLS, CA KOReader quando presente, timeout e limite bytes. JSON è
limitato a 1 MiB; ZIP a 8 MiB. File incompleti non vengono riusati. I residui più
vecchi di un giorno sono puliti senza seguire link o toccare file estranei.

Prima di installare: SHA/size, estrazione in staging separato sul filesystem del
plugin, max 512 entry e 32 MiB estratti, nessuna entry link/speciale, path senza
escape `..` o assoluti, niente duplicati, presenza main/meta/locale/icons,
compilabilità Lua e versione _meta uguale al tag. La metadata non viene eseguita.
Si sostituisce l'intera directory, così spariscono i moduli/cataloghi orfani.
La vecchia directory è mantenuta come backup; un errore nella seconda rename
ripristina la prima. I notebook sono fuori dalla directory del plugin.

**Limite concreto:** le due rename di directory non sono una singola operazione
atomica rispetto a perdita di alimentazione. Un crash esattamente fra le due
può lasciare il plugin nel backup `.notebook-update-backup`; in quel caso va
ripristinata la directory tramite SSH/USB. Il rollback gestisce gli errori I/O
ordinari, non certifica power-loss recovery. La verifica reale con ZIP hostile
ha provato rollback/error paths in una cartella temporanea. Non è stata simulata
un'interruzione di alimentazione del Kindle.

Dopo un update non si possono aprire notebook con i vecchi moduli in memoria:
la galleria si chiude e viene chiesto il riavvio. Solo la nuova versione caricata
ritira il backup del precedente pacchetto. L'installazione non viene avviata
automaticamente dal controllo settimanale: prima si vedono versione e note,
poi si sceglie Install.

## 11. Export di pagine selezionate

Dalla galleria, selezionare un notebook → Export → **Choose pages…**. Il dialogo
accetta ad esempio `1, 3-5`, valida i limiti, elimina duplicati e usa l'ordine
naturale del documento. La scelta del formato successiva usa la stessa vista
per PDF, SVG e Xournal++. L'output ha suffisso `-pages`, separato dall'export
completo.

La vista condivide i tratti senza modificarli. Template e metadati sono mappati
alla pagina originale; uno sfondo PDF senza numero esplicito riceve il numero
originale soltanto nella vista. Non cambia pagina corrente, dirty, history o
persistenza del notebook. Se il documento cambia fra scelta/export e gli indici
non esistono più, l'export fallisce senza creare una falsa selezione. Funziona
anche per notebook ottenuti annotando PDF. Non aggiunge un editor/extractor per
PDF arbitrari esterni alla libreria Notebook.

## 12. Verifiche effettuate

- `make verify`: lint Lua senza warning, tutte le 45 suite configurate e controllo
  gettext. Nuove suite `updater`, `renderfast`, `pageselection`; loader collision
  check esteso ai moduli estratti.
- `make check-package`: ZIP integro, entry principali e cataloghi, spec escluse.
- `tools/check-updater.py --network`: archiver/SHA reali, ZIP validi/hostili,
  rollback con errore iniettato, file orfani assenti, fetch della release stabile.
- Stessa verifica **sul Kindle via SSH**, compreso download e validazione v1.4.0
  senza installarla nel plugin attivo.
- `--ui` sul Kindle: pulsante a destra della versione, menu entro lo schermo,
  checkbox settimanale/toggle e dialogo range. PNG offscreen in `build/kindle-*`.
- 576 confronti pixels old/new del renderer nel runtime desktop reale:
  grayscale/RGB, quattro rotazioni, quattro scale, tre offset, sei pennelli/forme.
- Benchmark desktop JIT on/off, confronto completo Kindle e follow-up mirati.

La verifica offscreen non aggiorna il display e non testa una mano che scrive.
La prova d'uso resta utile per palmo, precisione percepita, ghosting, latenza penna
ed endpoint al rilascio. SSH permette però di arrivarci con CPU, cache, I/O,
geometria e integrità del pacchetto già controllati.

## 13. Comandi per ripetere e aggiungere guardrail

```sh
make verify
make check-package
make benchmark BENCH_ARGS='--jit both --extended --output build/benchmark.json'
python3 tools/benchmark.py --baseline /path/to/baseline-lua --jit both
python3 tools/benchmark.py --compare build/previous.json --fail-regression 0.20
python3 tools/benchmark.py --ssh root@KINDLE --port 22 --jit on --extended
python3 tools/benchmark.py --ssh root@KINDLE --remote-work-root /mnt/us --jit on --extended
python3 tools/benchmark.py --ssh root@KINDLE --filter cache/page --jit both
python3 tools/check-updater.py --ssh root@KINDLE --network --ui
```

Non eseguire confronti CPU durante le suite parallele di correttezza, un altro
benchmark o un trasferimento pesante. Conservare runtime, fixture, profilo JIT,
scaling e storage con i risultati. Una soglia superata è un motivo per indagare:
confrontare anche p95, allocazioni, pixels, bytes scritti, cache hit/miss e
scheduling, prima di chiamarla regressione del prodotto.

## 14. Inventario dei moduli

La tabella seguente include tutti i file Lua di produzione al momento della
revisione. Le dipendenze sono i nomi di moduli privati presenti nelle chiamate
`require` letterali, comprese quelle differite; è un indice statico, non un grafo
completo dei callback o delle scritture dei campi `self`.

| Modulo | Righe | Funzioni dichiarate | Dipendenze private | Responsabilità dichiarata nel sorgente |
|---|---:|---:|---|---|
| `_meta.lua` | 13 | 0 |  | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `actionmenu.lua` | 411 | 26 | `safe` | The menu of things you can do to a notebook: an icon and a label per row. |
| `canvas.lua` | 602 | 21 | `canvaslifecycle`, `canvasrefresh`, `canvasrender`, `erasercanvas`, `i18n`, `lasso`, `liveink`, `renderer`, `safe`, `selectioncanvas`, `shapecanvas`, `shapesnap`, `snapcanvas`, `stroke`, `tuning`, `viewcanvas`, `zoomcache`, `zoomcanvas`, `zoomrefresh` | The drawing surface: turns stylus events into ink on the panel. |
| `canvaslifecycle.lua` | 116 | 8 | `pdfbackground`, `safe`, `stylusbridge`, `textcache` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `canvasrefresh.lua` | 135 | 7 | `rect`, `tuning` | Shows a rectangle now, clipped to the drawing area. |
| `canvasrender.lua` | 140 | 3 | `pdfbackground`, `rect`, `renderer`, `template` | Lays the page's background down, under the ink. |
| `document.lua` | 725 | 40 | `documentstorage`, `rect`, `template` | The notebook document: pages of vector strokes, plus the undo history. |
| `documentstorage.lua` | 158 | 6 | `stroke`, `template` | Persistenza e validazione dei documenti |
| `erasercanvas.lua` | 168 | 7 | `rect`, `safe`, `tuning` | Rubs out along the path travelled since the last event, in one pass. |
| `export.lua` | 312 | 19 | `pdfbackground`, `renderer`, `template` | Exports a notebook document to PDF. |
| `exportpagesdialog.lua` | 30 | 3 | `i18n`, `pageselection` | Dialogo della selezione delle pagine |
| `exportprogress.lua` | 64 | 5 | `i18n`, `safe` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `gallery.lua` | 1065 | 75 | `actionmenu`, `document`, `exportpagesdialog`, `gallerycard`, `galleryexport`, `galleryheader`, `i18n`, `library`, `newnotebook`, `pdfbackground`, `safe`, `share`, `thumbnail`, `updater` | The notebook gallery: a grid of cards, the way a bookshelf is. |
| `gallerycard.lua` | 186 | 8 | `i18n` | Puts back the rounded corners a full-bleed picture painted over. |
| `galleryexport.lua` | 307 | 11 | `document`, `export`, `exportprogress`, `i18n`, `library`, `pageselection`, `safe`, `share`, `svg`, `xopp` | Hands what has been chosen to LocalSend. |
| `galleryheader.lua` | 375 | 22 | `_meta`, `actionmenu`, `i18n`, `library`, `updater`, `widgets` | What each listing order is called. |
| `geometryink.lua` | 92 | 3 | `polygonink`, `raster` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `highlightink.lua` | 125 | 4 |  | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `i18n.lua` | 163 | 11 |  | Translations for this plugin's own strings. |
| `lasso.lua` | 173 | 10 | `markerarea`, `rect`, `tuning` | Lasso selection and geometric containment helpers for strokes. |
| `lassomenu.lua` | 264 | 14 | `i18n`, `safe` | Floating interactive toolbar displayed directly above/below lasso-selected strokes. |
| `launcherbar.lua` | 218 | 17 | `safe` | Optional integration with the Simple UI launcher's navigation bar. |
| `library.lua` | 627 | 33 |  | Notebook storage: the files and folders on disk, and the operations on them. |
| `liveink.lua` | 49 | 5 | `rect` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `loader.lua` | 27 | 2 |  | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `main.lua` | 222 | 10 | `document`, `gallery`, `i18n`, `launcherbar`, `library`, `newnotebook`, `notebook`, `pagepanel`, `papersample`, `pluginicons`, `rect`, `safe`, `share`, `template`, `templatepicker`, `updater`, `widgets` | Notebook: handwriting notebooks for KOReader. |
| `markerarea.lua` | 239 | 14 | `renderer`, `stroke` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `newnotebook.lua` | 246 | 15 | `i18n`, `papersample`, `safe`, `template`, `widgets` | Creating a notebook: its name and its paper, in one screen. |
| `notebook.lua` | 471 | 38 | `canvas`, `i18n`, `notebooksettings`, `notebooktoolbar`, `pagepanel`, `safe`, `tuning`, `tuningdock` | The notebook screen: a toolbar plus the drawing canvas. |
| `notebooksettings.lua` | 222 | 30 | `actionmenu`, `i18n`, `notebooktext`, `settings`, `textsizepicker` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `notebooktext.lua` | 225 | 32 | `i18n`, `rect`, `textdialog`, `textobject`, `textpreview` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `notebooktoolbar.lua` | 322 | 26 | `canvas` | A tappable icon that can show itself as selected. |
| `pagepanel.lua` | 467 | 34 | `actionmenu`, `i18n`, `pdfbackground`, `renderer`, `safe`, `template`, `templatepicker`, `widgets` | The page overview: every page of the notebook at a glance. |
| `pageselection.lua` | 46 | 5 |  | Selezione delle pagine e vista per esportazione |
| `papersample.lua` | 187 | 5 | `template` | A square of paper, drawn as the paper it stands for. |
| `pdfbackground.lua` | 72 | 6 |  | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `penink.lua` | 75 | 2 | `raster` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `penpressure.lua` | 18 | 1 |  | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `pluginicons.lua` | 62 | 1 |  | Registrazione delle icone |
| `polygonink.lua` | 58 | 3 | `penink`, `raster` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `pressure.lua` | 45 | 3 |  | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `raster.lua` | 26 | 2 |  | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `rect.lua` | 48 | 2 |  | Growing a rectangle to cover another one. |
| `renderer.lua` | 372 | 17 | `geometryink`, `highlightink`, `markerarea`, `penink`, `raster`, `textobject` | Stroke rasterizer. |
| `safe.lua` | 365 | 27 | `i18n` | Keeping a fault in this plugin from taking the device down with it. |
| `selectioncanvas.lua` | 348 | 19 | `i18n`, `lasso`, `lassomenu`, `rect`, `renderer`, `tuning` | Applies the movement gathered since the last one, and shows it. |
| `settings.lua` | 352 | 24 | `i18n`, `safe`, `widgets` | The settings panel. |
| `shape.lua` | 262 | 9 | `stroke` | Geometric shape recognizer for handwriting strokes. |
| `shapecanvas.lua` | 252 | 13 | `rect`, `shape`, `textobject` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `shapesnap.lua` | 53 | 6 | `safe`, `shape`, `tuning` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `share.lua` | 196 | 10 | `library` | Handing a file to the LocalSend plugin, if it is installed. |
| `snapcanvas.lua` | 64 | 2 | `rect`, `renderer` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `stroke.lua` | 621 | 23 | `markerarea`, `textcache` | A single vector stroke: the atomic unit of a notebook page. |
| `stylusbridge.lua` | 100 | 5 | `pressure`, `safe` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `stylusinput.lua` | 233 | 2 | `penpressure` | Receives fully processed stylus slots, ahead of gesture detection. |
| `svg.lua` | 147 | 7 | `markerarea`, `renderer` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `template.lua` | 246 | 6 | `i18n`, `raster` | Page backgrounds: ruled lines, grids, dot grids. |
| `templatepicker.lua` | 147 | 9 | `papersample`, `safe`, `widgets` | The background chooser. |
| `textcache.lua` | 44 | 3 |  | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `textdialog.lua` | 86 | 3 |  | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `textobject.lua` | 147 | 11 | `rect`, `stroke`, `textcache` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `textpreview.lua` | 28 | 3 | `rect`, `renderer` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `textsizepicker.lua` | 81 | 9 | `i18n`, `textobject` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `thumbnail.lua` | 152 | 6 | `document`, `library`, `pdfbackground`, `renderer`, `template` | Thumbnails of a notebook's first page, cached on disk. |
| `touchinput.lua` | 332 | 13 | `penpressure`, `tuning` | Drawing with a finger, which is also the only way to draw in the emulator -- SDL synthesises finger touches, never stylus events, so without this path none of the drawing code could be exercised off-device. |
| `tuning.lua` | 272 | 7 |  | The numbers that decide how the pen feels. |
| `tuningdock.lua` | 449 | 27 | `i18n`, `safe`, `tuning` | The tuning dock. |
| `updateinstaller.lua` | 106 | 6 | `updatepolicy` | Validazione e sostituzione del pacchetto |
| `updatepolicy.lua` | 53 | 5 |  | Politica delle release stabili |
| `updater.lua` | 160 | 21 | `_meta`, `actionmenu`, `i18n`, `updateinstaller`, `updatepolicy`, `updatetransport` | Interfaccia e pianificazione degli aggiornamenti |
| `updatetransport.lua` | 66 | 5 |  | Trasferimenti HTTPS asincroni |
| `viewcanvas.lua` | 62 | 5 | `raster`, `rect`, `renderer` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `widgets.lua` | 104 | 4 |  | The small controls this plugin builds by hand, in one place. |
| `xopp.lua` | 177 | 11 | `markerarea`, `pdfbackground` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `zoom.lua` | 17 | 3 |  | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `zoomcache.lua` | 159 | 8 | `pdfbackground`, `raster`, `rect`, `renderer`, `template` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `zoomcanvas.lua` | 210 | 3 | `penpressure`, `rect`, `renderer`, `stroke`, `tuning`, `zoom` | Consultare API e chiamanti; modulo senza introduzione descrittiva |
| `zoomrefresh.lua` | 157 | 13 | `rect`, `tuning`, `zoom` | Consultare API e chiamanti; modulo senza introduzione descrittiva |

Il conteggio delle funzioni è lessicale e include anche funzioni anonime e occorrenze nei commenti; serve a orientare la lettura, non è una misura della complessità.

Un costo nascosto ulteriore è il watchdog di `safe.lua`: `Safe.watched` disabilita temporaneamente il JIT per rendere efficace il limite di istruzioni e poi ripristina lo stato. I benchmark diretti con JIT attivo non rappresentano quindi tutti i percorsi degli eventi reali. Occorre misurare anche i callback attraverso `Safe.widget`, distinguendo i gestori protetti dal watchdog e quelli con `watch=false`; `Safe.later` usa la protezione dagli errori senza quel watchdog.

Verifica finale: `make verify` (45 suite, 78 file Lua senza warning), `make check-package` e il controllo nativo `tools/bench-render.lua` completati con successo. Quest’ultimo verifica ora tutti i 2480 pixel verticali, con zero differenze nell’area e zero scritture fuori area per penna ed evidenziatore. I filtri dei benchmark estesi preparano esplicitamente il PDF e le cache necessari, anche quando i casi cold vengono esclusi.

## 15. Ottimizzazioni successive

La fase successiva, autorizzata dopo questa revisione, è descritta nel [rapporto delle ottimizzazioni](2026-10-01-optimization-followup.md). Include le modifiche accettate, i confronti via SSH e un tentativo sul renderer scartato per risultati prestazionali discordanti. Le misure e l’inventario sopra restano la fotografia della prima fase.
