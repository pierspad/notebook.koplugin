# Revisione del checkout attuale: confini, benchmark e costi nascosti

Il ramo `dev`, HEAD `5eb8c5c`, è stato verificato con fetch e pull fast-forward:
nessun aggiornamento entrante. La baseline è il checkout locale completo alla
partenza, comprese le modifiche già presenti di pagina/marker/suspend. Non è il
solo tag v1.5.0. Backup recuperabile in `/tmp/notebook-review-20261001/`:
`preexisting.patch`, `untracked.tar.gz`, `lua/`. I repository fratelli sono riferimenti.

Questa revisione integra, senza attribuirsi le modifiche precedenti,
[la prima analisi](2026-10-01-maintenance-benchmark-updates.md),
[le ottimizzazioni PDF/load](2026-10-01-optimization-followup.md) e
[il follow-up marker/pagine](2026-10-01-stable-followup.md).
I risultati storici riguardano altre fixture/versioni: non vanno fusi in un'unica
percentuale di miglioramento. Le nuove misure hanno prefisso `2026-10-01-maintenance-`.

## Modifiche di questa revisione

### Documento e replay della storia

`documenthistory.lua` possiede tre operazioni esplicite: `revert`, `reapply`,
`bounds`. Supporta add, erase, move, list e pages. Document resta proprietario
unico di stack, limite 200, batch, dirty, revisioni e pagina corrente; il replay
non salva, non programma callback, non accede al canvas e non disegna.

Il confine è intenzionalmente piccolo: non è una seconda classe Document né un
mixin che nasconde ulteriore stato. Le liste trasferite dalla storia alle pagine
sono copiate; i tratti e gli oggetti pagina conservano l'identità prevista.
Bounds espliciti prevalgono sulla ricostruzione dai tratti; una translation
include anche l'area precedente. Il loader privato isola il modulo anche quando
un altro plugin ha già caricato un modulo omonimo. La suite loader verifica
questa collisione. Le suite esistenti coprono batch, selezioni, ordine, pagine,
cache, persistenza e repaint dello zoom attraverso Document di produzione.

### Gomma per oggetti: eliminare gli spostamenti ripetuti

`eraseAlongPath` camminava al contrario e chiamava `table.remove` per ogni hit.
Questo evita gli errori di indice ma sposta ogni volta la coda superstite: con
tratti alternati colpiti/non colpiti, gli spostamenti sono quadratici.

Ora una scansione compatta i superstiti in ordine nella stessa lista. Gli hit
conservano gli indici originali e vengono invertiti una volta per mantenere il
contratto descending della cronologia. Shapes selezionate tramite il parametro
`shapes` restano nella pagina. Bounds, batch, revisioni e dirty mantengono le API.
Non viene modificato il criterio geometrico di hit né la gomma per area.

La regressione di produzione verifica 240 oggetti, 160 hit alternati, bounds,
identità della lista, ordine dei superstiti, indici, undo/redo e indipendenza
della storia da un'aggiunta successiva. Eseguita contro il Document della
baseline, fallisce con 160 shift; contro il codice corrente passa senza shift.
La fixture prestazionale usa 4.000 oggetti di tre punti ciascuno, metà lontani:
miss, contatto limitato e cancellazione di metà pagina. Include preparazione
della lista, hit test, cancellazione e undo/redo; non misura solo il compattatore.

### Harness: misurare e comparare senza falsi successi

`benchmark.py` resta il runner locale/SSH; `bench-suite.lua` usa il runtime
nativo. Il nuovo `benchmark_report.py` separa le regole di confronto dal
trasporto e dalla stampa. Dieci test Python sono eseguiti da `make verify`.

- CPU, wall, heap, retained, RSS e GC conservano ora i nove campioni grezzi,
  oltre a min/mediana/p95/max. Ordinare una copia conserva l'ordine temporale.
- Ogni scenario riporta warm-up e iterazioni. CPU/wall sono per operazione;
  heap/RSS/GC sono per batch di iterazioni, e non vanno divisi automaticamente.
- Oltre agli hit si confrontano contatori di tratti, punti, contorni, pagine,
  query, pagine selezionate e bytes RLE quando presenti. Draw/blit counts sono
  osservazioni prestazionali, perciò una loro riduzione non significa output diverso.
- `result_equivalent=true` significa **contatori controllati uguali**, non
  equivalenza geometrica/pixels/file. `null` significa esito non controllato.
  I confronti nativi e i test funzionali restano necessari in entrambi i casi.
- Un contatore differente fa fallire un guardrail anche se il tempo migliora:
  l'harness precedente saltava questi casi nel controllo regressioni.
- Casi assenti dalla baseline o dal corrente sono elencati; con soglie attive
  fanno fallire il confronto. Per baseline che supportano gli estesi, usare
  `--baseline-extended --extended`. La copertura parziale resta leggibile senza soglie.
- Il runner verifica il fingerprint prima/dopo: modifiche concorrenti ai sorgenti
  o alla fixture rendono la prova invalida. Parsing e diagnostica sono condivisi
  fra esecuzione locale e SSH.
- Baseline CPU zero dà ratio `null`, non 1. NaN, infinito e tempi negativi
  confrontati sono respinti; nomi duplicati e filtri vuoti non passano.
- Limiti negativi/non finiti, baseline+compare insieme e soglie senza baseline
  sono respinti prima di eseguire i benchmark.
- `--fail-wall-regression` aggiunge una soglia sul tempo trascorso;
  `--fail-retained-kib` aggiunge un limite assoluto alla crescita della heap Lua
  dopo GC. Non sono soglie sulla RAM nativa o sulla batteria.

Nuovi scenari: gomma oggetti miss/sparse/dense, history diretta/protetta/watched
attraverso `Safe.widget`, SVG completo/selezionato, XOPP selezionato e duplicazione
pagina con undo/redo. Il callback history cancella/ripristina 200 di 400 tratti,
per evitare che un callback banale misuri soltanto il wrapper.

## Confini e priorità di manutenzione

| Area | Proprietario attuale | Confine utile / motivazione | Contratti e rischi |
|---|---|---|---|
| Formato e I/O | documentstorage | Già separato, non aggiungere UI o scheduling | Validazione completa prima della sostituzione, cache serialized per pagina, rename |
| Edit e revisioni | document | Mantenere un unico proprietario; estrarre geometria solo con esiti espliciti | Un edit invalida cache e redo; liste history mai vive |
| Replay | documenthistory | Estratto in questa revisione, API a tre funzioni | Identità, ordine, bounds e copie shallow |
| Stroke | stroke | Punti/trasformazioni sono centrali; indice e split condividono invarianti | Ogni mutazione invalida chunks e widget testo; formato marker multipart |
| Marker | markerarea/markerclip/markerhit | Le separazioni preesistenti sono coerenti: costruzione, sottrazione, contatto | Poligoni separati, pressione, bounds, tagli ripetuti |
| Raster | renderer, penink, highlightink, geometryink, polygonink, raster | Conservare dispatch e primitive specializzate | Clip, stride, rotazioni, BB8/RGB, pressione e riuso proxy/JIT |
| Canvas | canvas e mixin | Prima esplicitare i gruppi di stato, poi eventuali controller | I mixin operano sullo stesso self: più file senza ownership non riducono responsabilità |
| Lifetime | canvaslifecycle, stylusbridge | Unico owner di input/timer/buffer; evitare seconda cache globale | Close/fault/suspend/overlay idempotenti, nessun callback su framebuffer coperto |
| E-ink | canvasrefresh, zoomrefresh | Separato da calcolo pixels; conservare coalescing e ultimo endpoint | CPU più veloce non autorizza frequenze refresh più alte |
| Zoom | zoomcache, zoomcanvas | Cache/riparazione separata dal gesto | Revisioni, ink differita, erase fuori viewport, pan finale |
| Selection | selectioncanvas/lasso/lassomenu | Comandi modello e geometria separabili prima dei dialoghi | Coordinate trasformate, clipboard indipendente, una sola history per gesto |
| Notebook UI | notebook, notebooktoolbar, notebooksettings, notebooktext | Orchestrazione resti in notebook; unificare finishInteraction dove verificabile | Save fallito non chiude; overlay/clock/suspend hanno stato proprio |
| Griglia | pagegrid, pagetile, pagepanel, exportpagesdialog | Già separata layout/miniatura/policy; evitare raster cache senza invalidazione | Selezione su tutte le pagine, widget liberati, paginazione e mapping PDF |
| Galleria | gallery/galleryheader/gallerycard | Prossima separazione sensata: worker thumbnail e comandi storage | Queue cancellabile, dedup, folder generation, no callback di schermata chiusa |
| Libreria | library | Separare indice/sort da operazioni filesystem quando si modifica quel flusso | Symlink, PDF compagni, collisioni nomi e errori parziali |
| Miniature | thumbnail | Invalidazione esplicita e job più piccoli prima di altri moduli | Carica tutto il notebook; cache mtime non include dimensioni e contenuto |
| Export | export/svg/xopp, galleryexport/exportprogress | Writer separati da progress/nomi; un piano di output utile per bulk | Temporanei, annullamento, selezione immutable, companion XOPP |
| Share | share | Il content hash rende un hit O(bytes); non sostituirlo con solo mtime | Stesso tick filesystem, collisioni cache e cleanup, disponibilità LocalSend |
| Update | updatepolicy/updatetransport/updateinstaller/updater | Confini già coerenti, non inglobarli nella galleria | Trasporto, verifica archivio, rollback, riavvio, due rename non power-loss atomic |
| Supporto UI | widgets/actionmenu/pickers/dialogs | Componenti piccoli: una separazione ulteriore aumenta navigazione | Callback protette, sizing, i18n e font cache |
| Tuning | tuning/tuningdock/settings | Policy, UI e preferenze diverse; non usare benchmark per cambiare a caso i default | Parametri di feeling richiedono penna/pannello reali |

Le estrazioni proposte ma non implementate sono priorità contestuali, non nuovi
strati obbligatori. In particolare non ho riscritto canvas/gallery/library in
controller generici: è un intervento molto più rischioso della riduzione verificata
qui, e i test attuali dipendono da parecchi campi pubblici/impliciti.

## Copertura: cosa misura e cosa resta fuori

| Feature / costo | Benchmark disponibile | Garanzia complementare / limite |
|---|---|---|
| Persistenza | save pulito/edit, load completo | storage/persistence: errori e invalidazione; flash da misurare separatamente |
| Penna/marker | raster completo/clip/thumbnail | bench pen/marker e native pixel checks; suite non misura digitizer-to-panel |
| Gomma area | penna/marker, 48/120/300 px e 12 tagli | eraser/markerarea + 80 confronti geometrici/pixels; contorni crescenti restano costosi |
| Gomma oggetti | miss/sparse/dense e bordi marker | Nuova regressione compaction; hit test non è prova della latenza di un gesto completo |
| Lasso | selezione 200 vertici | lassoedit/interaction/bench-drag coprono modifiche; tempo completo drag+repaint non nel runner unificato |
| Undo/redo | bulk, 200 batch, duplicazione pagina | run/pages/bulkdelete/zoomhistory: identità, cache e ordine |
| Watchdog | Safe.widget watched/protected/direct | safe verifica timeout/fault e ripristino; un singolo callback non rappresenta tutti i widget |
| Cache pagina | cold/warm, draw/blit counters | performance: pixels, eviction e free; alternanza pagina/edit può usare una fixture workflow dedicata |
| Zoom | cold 2x e pan warm | zoompan/zoomrefresh/liveink: coalescing/endpoints; mancano scala 4x e RGB nel runner unificato |
| Testo/forme | 40 testi multilingue e 40 forme filled | textlayout, shape, tools, native renderer; mancano typing e cache churn come tempi separati |
| Carta | blank/lined/grid/dots | templateclip/bench-template: clipping a scale frazionarie |
| PDF background | cold/warm e alternanza dimensioni/pagine | pdfcache/native: sostituzione e budget; MuPDF/zoom grandi non sono memoria Lua |
| PDF export | 4 pagine e 2 selezionate, RLE denso/carta | export_polish: cancel/destinazione; 930×1240, non full-res Scribe |
| SVG | completo e selezionato | svg: atomicità e struttura; foglio e sfondi PDF omessi per contratto |
| XOPP | completo e selezionato | interchange/xoppstorage: gzip/coordinate e file compagno; companion PDF non nella fixture cronometrata |
| Share cache | hash completo del notebook | sharecache; trasferimento LocalSend/rete non misurato |
| Gallery | thumbnail disk cold/warm, list 1001 | gallery: queue e annullamento; non galleria reale con cartelle/link/export misti |
| Selezione pagine | UI apertura/toggle 100 pagine | pageselection e check-updates-ui: range/checkbox/layout; toggle ricostruisce miniature visibili |
| Suspend/overlay/close | Test funzionali e native framebuffer | Nessun tempo o consumo idle del lifecycle nel runner |
| Updater | check-updater nativo separato | Nessun benchmark di latenza rete o installazione: dipende da servizio/storage |

Quindi **il benchmark non copre tutte le feature end-to-end**. I controlli di
correttezza coprono più comportamento del runner prestazionale. Per proteggere
un'ottimizzazione servono workload comparabile e prova dell'output: nessuno dei
due può sostituire l'altro.

## Costi nascosti da sorvegliare

1. **Somma delle cache native.** Page cache ha budget 12 MiB, text 8M pixels,
   PDF 12 MiB con eccezione raster singolo, background una copia, zoom una pagina
   ingrandita. A BB8 1860×2480 una pagina è ~4,4 MiB; il solo zoom 2x sull'area
   1860×2440 vale ~17,3 MiB. RGB moltiplica ulteriormente. Ogni budget locale
   può essere rispettato mentre la somma è troppo alta. Delta heap/RSS finale
   non misura picco né lifetime di tutte le allocazioni FFI.
2. **Salvataggio e flash.** Riutilizzare serialized evita lavoro sui tratti puliti,
   ma bitser riscrive l'intero file. Misurare bytes, wall, CPU e numero di save per
   gesto; save/unchanged è API esplicita, non autosave perpetuo. Rename atomico
   non certifica durability su power loss senza flush/fsync del filesystem.
3. **Singolo job lungo.** Safe.later cede input fra miniature, non dentro
   Document.load/render/writePNG. Una queue asincrona può ancora congelare la UI
   per centinaia di ms per job. Analogamente ogni phase PDF può restare lunga.
4. **Stato caldo e JIT.** La cache calda e l'ordine dei casi cambiano trace,
   collector e CPU governor. La misura isolata e quella integrata devono entrambe
   essere conservate; callback con watchdog non equivalgono a chiamate dirette.
5. **Memoria contro CPU.** Ridurre allocazioni provvisorie può trattenere più
   bitmap/poligoni nella storia. Osservare retained, eviction/free e frequenza GC,
   senza sommare il GC esplicito del fixture a ogni interazione reale.
6. **Granularità geometrica.** Pochi oggetti possono contenere molti contorni e
   punti: contare soltanto strokes sottostima marker frammentati. I nuovi contatori
   rendono osservabile questo costo, ma non certificano equivalenza pixels.
7. **Invalidazione.** Timestamp nello stesso secondo, dimensioni thumbnail,
   rotazione/color mode, template, sostituzione background e edit durante export
   devono essere testati. Una cache più rapida con pixels vecchi è una regressione.
8. **Il pannello.** CPU e wall offscreen non misurano waveform, ghosting, coda
   input, campione finale, palmo, batteria né feeling. Le prove di uso con penna
   restano necessarie prima di cambiare refresh/tuning.

## Risultati e verifiche di questa revisione

Sul Kindle, in confronto isolato della gomma oggetti:

| Caso | JIT | Prima CPU mediana ms | Dopo ms | Riduzione |
|---|---|---:|---:|---:|
| `eraser/object-miss` | on | 10.828 | 8.481 | 21.7% |
| `eraser/object-sparse` | on | 14.919 | 10.778 | 27.8% |
| `eraser/object-dense` | on | 51.539 | 25.196 | 51.1% |
| `eraser/object-miss` | off | 29.511 | 28.292 | 4.1% |
| `eraser/object-sparse` | off | 35.731 | 30.395 | 14.9% |
| `eraser/object-dense` | off | 161.981 | 54.516 | 66.3% |

Fonte: [object Kindle](results/2026-10-01-maintenance-object-kindle.json).
I contatori dei risultati sono uguali per tutti i casi. Nel denso si cancellano
2.000 di 4.000 oggetti. La memoria retained resta dello stesso ordine:
il guadagno non viene presentato come riduzione universale della RAM.

Il nuovo Document ha 644 righe contro le 725 della baseline; il replay è un modulo
separato di 107 righe. Il numero totale di righe cresce leggermente per rendere
esplicito il contratto: il risultato cercato è ridurre la responsabilità del modello,
non minimizzare la dimensione dei sorgenti.

Il [confronto desktop completo](results/2026-10-01-maintenance-full-desktop.json)
contiene 54 scenari per ciascun profilo JIT, stessa copertura baseline/corrente,
nessun contatore di esito discordante. Il primo confronto JIT on ha segnalato
render dirty +30,6%, cache cold +27,4%, thumbnail render +37,9% e apertura
griglia +30,9%. Nella [ripetizione](results/2026-10-01-maintenance-full-desktop-repeat.json)
gli stessi rapporti sono 1,079/1,047/0,994/1,036; non sono rallentamenti ripetibili
nella medesima misura. Restano candidati nel repeat: area pen +23,5% e miss oggetti
+21,1%, entrambi sotto mezzo ms sul desktop; nella prova isolata Kindle il miss
migliora. Le soglie non sono state dichiarate superate per tutta l'app.

Il [confronto Kindle completo](results/2026-10-01-maintenance-full-kindle.json)
ha la stessa copertura e nessun contatore discordante. Il denso oggetti passa
59,440→29,017 ms (−51,2%), mentre il miss completo passa 9,814→11,177 ms (+13,9%):
il guadagno del denso non viene esteso ai miss. Si segnalano anche lasso +22,9%,
area pen +32,1%, history bulk +23,6%, PDF completo +33,9% e selezionato +27,2%.
La frequenza registrata è 2 GHz in entrambe le copie, ma ciò non rende identici
trace JIT, cache, GC o pressione di sistema. Il renderer/codec PDF non è cambiato.

La [prova mirata area pen](results/2026-10-01-maintenance-area-pen-kindle.json)
misura ratio 0,999 con JIT on e off (4,811 ms / 7,230 ms corrente): il segnale
+32,1% dell'intera sequenza non è riprodotto dal percorso isolato. I report
completi rimangono disponibili; un test locale non annulla un possibile costo
quando si combinano molte feature. Il workflow misto va rivalutato sulle
fixture reali prima di dichiarare assenza generale di regressioni.

Il [PDF isolato sul Kindle](results/2026-10-01-maintenance-pdf-kindle.json)
passa invece 568,662→545,460 ms sul completo e 278,909→267,971 ms sulla selezione,
ratio 0,959/0,961. Non viene interpretato come ottimizzazione PDF di questa
revisione: il writer è invariato. Il contrasto con il workflow completo rende
visibile quanto ordine/stato delle trace incidano sui numeri. Non si sostiene
che il +33,9% del completo sia risolto semplicemente perché l'isolato è veloce.

La [prova flash Kindle](results/2026-10-01-maintenance-flash-kindle.json)
usa una directory temporanea sotto `/mnt/us`, non `/tmp`, con fixture isolata.

| Caso | Prima CPU ms | Dopo CPU ms | Prima wall ms | Dopo wall ms |
|---|---:|---:|---:|---:|
| `save/unchanged` | 95.200 | 110.781 | 185.361 | 207.675 |
| `save/one-page-edit` | 95.272 | 111.835 | 183.827 | 208.797 |

La copia corrente costa circa 208 ms wall ma ~111 ms CPU: osservare solo CPU
nasconde quasi 100 ms di attesa. Il save non è stato ottimizzato da questa
revisione; +16–17% CPU nel confronto flash è conservato, non attribuito con
certezza al replay. `/mnt/us` e `/tmp` sono destinazioni diverse, perciò quei
report non vanno passati a `--compare` fra loro; non dimostrano durability dopo
power loss o latenza di autosave durante un gesto reale. Lo storage e governor
possono variare anche quando il nome del dispositivo è lo stesso.

La prova callback Kindle, su history di 200 oggetti cancellati, misura circa
0,293 ms diretta, 0,343 ms watched e 0,319 ms protetta con JIT richiesto on;
con JIT off circa 0,955/1,267/1,003 ms. L'overhead è misurabile ma questa fixture
non dimostra un collo di bottiglia sufficiente per indebolire il watchdog.
Fonte: [callback Kindle](results/2026-10-01-maintenance-callbacks-kindle.json).

- `make verify`: 46 suite Lua e 10 test Python di confronto/fingerprint, lint su 83 file
  di produzione senza warning/errori e cataloghi gettext validi.
- `make check-package`: ZIP locale v1.6.0-dev.1 valido, modulo replay incluso.
- Runtime nativo desktop **e Kindle**: 672 confronti renderer, 29 preview/PDF,
  80 marker geometrici e controlli overlay/suspend con pixels equivalenti alla
  baseline; le prove native non giravano sullo stesso host dei suoi benchmark.
- Nuova regressione eraser: riprodotta sulla baseline prima del cambiamento.

SHA-256 dei sorgenti Lua correnti nelle prove: `1d29321cc8caaa155cfaf92c8322ac83431043aee8970f91b858fff4995f1326`.

Log: [native desktop](results/2026-10-01-maintenance-native-desktop.txt),
[native Kindle](results/2026-10-01-maintenance-native-kindle.txt).

## Metodo e comandi

Sorgenti temporanei via SSH, nessuna installazione nel plugin attivo, nessun
riavvio di KOReader, nessun notebook personale letto. Refresh del pannello
sostituito da no-op nell'harness. Le fixture /tmp sono distinte da quelle su
`/mnt/us`; host/runtime/storage/JIT/scala/samples/fixture devono coincidere nei
confronti. Il fingerprint include sorgenti plugin e script fixture, ma non tutte
le librerie native KOReader: un runtime aggiornato nella stessa directory deve
avere una baseline nuova. Nove samples danno p95=max; non è una stima affidabile
della coda e non sono nove processi indipendenti. Non si inferisce significatività
statistica da una singola mediana. Le soglie riportano candidati da indagare.

```sh
make verify
make check-package
make benchmark BENCH_ARGS='--extended --jit both --output build/benchmark.json'
python3 tools/benchmark.py --baseline /path/to/baseline/lua --baseline-extended --extended --jit both
python3 tools/benchmark.py --compare build/previous.json --extended --jit both --fail-regression .20 --fail-wall-regression .20 --fail-retained-kib 1024
python3 tools/benchmark.py --ssh root@KINDLE --port 22 --filter eraser/object --jit both
python3 tools/benchmark.py --ssh root@KINDLE --port 22 --remote-work-root /mnt/us --filter save/ --jit on
python3 tools/check-native.py --baseline /path/to/baseline/lua --ssh root@KINDLE --port 22
```

## Inventario statico corrente

Tutti i moduli Lua di produzione nella directory `lua/`. Il conteggio funzioni
considera solo dichiarazioni a inizio riga; non è un indicatore di complessità.
Le dipendenze sono require letterali privati, comprese quelle lazy, non scritture
self/callback. Per i confini comportamentali usare la matrice precedente.

| Modulo | Righe | Funzioni dichiarate | Dipendenze private |
|---|---:|---:|---|
| `_meta.lua` | 13 | 0 |  |
| `actionmenu.lua` | 411 | 19 | `safe` |
| `canvas.lua` | 602 | 9 | `canvaslifecycle`, `canvasrefresh`, `canvasrender`, `erasercanvas`, `i18n`, `lasso`, `liveink`, `renderer`, `safe`, `selectioncanvas`, `shapecanvas`, `shapesnap`, `snapcanvas`, `stroke`, `tuning`, `viewcanvas`, `zoomcache`, `zoomcanvas`, `zoomrefresh` |
| `canvaslifecycle.lua` | 116 | 7 | `pdfbackground`, `safe`, `stylusbridge`, `textcache` |
| `canvasrefresh.lua` | 135 | 7 | `rect`, `tuning` |
| `canvasrender.lua` | 140 | 3 | `pdfbackground`, `rect`, `renderer`, `template` |
| `document.lua` | 644 | 33 | `documenthistory`, `documentstorage`, `rect`, `template` |
| `documenthistory.lua` | 107 | 3 |  |
| `documentstorage.lua` | 169 | 2 | `stroke`, `template` |
| `erasercanvas.lua` | 168 | 7 | `rect`, `safe`, `tuning` |
| `export.lua` | 312 | 4 | `pdfbackground`, `renderer`, `template` |
| `exportpagesdialog.lua` | 111 | 11 | `i18n`, `pagegrid`, `pageselection`, `safe`, `widgets` |
| `exportprogress.lua` | 64 | 4 | `i18n`, `safe` |
| `gallery.lua` | 1065 | 41 | `actionmenu`, `document`, `exportpagesdialog`, `gallerycard`, `galleryexport`, `galleryheader`, `i18n`, `library`, `newnotebook`, `pdfbackground`, `safe`, `share`, `thumbnail`, `updater` |
| `gallerycard.lua` | 186 | 5 | `i18n` |
| `galleryexport.lua` | 307 | 2 | `document`, `export`, `exportprogress`, `i18n`, `library`, `pageselection`, `safe`, `share`, `svg`, `xopp` |
| `galleryheader.lua` | 375 | 5 | `_meta`, `actionmenu`, `i18n`, `library`, `updater`, `widgets` |
| `geometryink.lua` | 92 | 1 | `polygonink`, `raster` |
| `highlightink.lua` | 125 | 3 |  |
| `i18n.lua` | 163 | 0 |  |
| `lasso.lua` | 173 | 6 | `markerarea`, `rect`, `tuning` |
| `lassomenu.lua` | 264 | 7 | `i18n`, `safe` |
| `launcherbar.lua` | 218 | 4 | `safe` |
| `library.lua` | 627 | 25 |  |
| `liveink.lua` | 49 | 5 | `rect` |
| `loader.lua` | 27 | 0 |  |
| `main.lua` | 222 | 6 | `document`, `gallery`, `i18n`, `launcherbar`, `library`, `newnotebook`, `notebook`, `pagepanel`, `papersample`, `pluginicons`, `rect`, `safe`, `share`, `template`, `templatepicker`, `updater`, `widgets` |
| `markerarea.lua` | 194 | 3 | `markerclip`, `renderer`, `stroke` |
| `markerclip.lua` | 64 | 0 |  |
| `markerhit.lua` | 90 | 1 | `markerarea`, `renderer` |
| `newnotebook.lua` | 246 | 11 | `i18n`, `papersample`, `safe`, `template`, `widgets` |
| `notebook.lua` | 493 | 26 | `canvas`, `i18n`, `notebooksettings`, `notebooktoolbar`, `pagepanel`, `safe`, `tuning`, `tuningdock` |
| `notebooksettings.lua` | 222 | 7 | `actionmenu`, `i18n`, `notebooktext`, `settings`, `textsizepicker` |
| `notebooktext.lua` | 225 | 2 | `i18n`, `rect`, `textdialog`, `textobject`, `textpreview` |
| `notebooktoolbar.lua` | 322 | 8 | `canvas` |
| `pagegrid.lua` | 150 | 6 | `pagetile` |
| `pagepanel.lua` | 221 | 7 | `actionmenu`, `i18n`, `pagegrid`, `safe`, `templatepicker`, `widgets` |
| `pageselection.lua` | 62 | 3 |  |
| `pagetile.lua` | 121 | 4 | `pdfbackground`, `renderer`, `template` |
| `papersample.lua` | 187 | 3 | `template` |
| `pdfbackground.lua` | 100 | 5 |  |
| `penink.lua` | 75 | 1 | `raster` |
| `penpressure.lua` | 18 | 1 |  |
| `pluginicons.lua` | 62 | 0 |  |
| `polygonink.lua` | 58 | 1 | `penink`, `raster` |
| `pressure.lua` | 45 | 1 |  |
| `raster.lua` | 26 | 1 |  |
| `rect.lua` | 48 | 2 |  |
| `renderer.lua` | 372 | 5 | `geometryink`, `highlightink`, `markerarea`, `penink`, `raster`, `textobject` |
| `safe.lua` | 365 | 8 | `i18n` |
| `selectioncanvas.lua` | 348 | 11 | `i18n`, `lasso`, `lassomenu`, `rect`, `renderer`, `tuning` |
| `settings.lua` | 352 | 16 | `i18n`, `safe`, `widgets` |
| `shape.lua` | 262 | 3 | `stroke` |
| `shapecanvas.lua` | 252 | 12 | `rect`, `shape`, `textobject` |
| `shapesnap.lua` | 53 | 5 | `safe`, `shape`, `tuning` |
| `share.lua` | 196 | 5 | `library` |
| `snapcanvas.lua` | 64 | 1 | `rect`, `renderer` |
| `stroke.lua` | 611 | 17 | `markerarea`, `markerhit`, `textcache` |
| `stylusbridge.lua` | 100 | 2 | `pressure`, `safe` |
| `stylusinput.lua` | 233 | 1 | `penpressure` |
| `svg.lua` | 147 | 1 | `markerarea`, `renderer` |
| `template.lua` | 246 | 4 | `i18n`, `raster` |
| `templatepicker.lua` | 147 | 7 | `papersample`, `safe`, `widgets` |
| `textcache.lua` | 44 | 3 |  |
| `textdialog.lua` | 86 | 2 |  |
| `textobject.lua` | 147 | 6 | `rect`, `stroke`, `textcache` |
| `textpreview.lua` | 28 | 3 | `rect`, `renderer` |
| `textsizepicker.lua` | 81 | 5 | `i18n`, `textobject` |
| `thumbnail.lua` | 152 | 5 | `document`, `library`, `pdfbackground`, `renderer`, `template` |
| `touchinput.lua` | 332 | 12 | `penpressure`, `tuning` |
| `tuning.lua` | 272 | 5 |  |
| `tuningdock.lua` | 449 | 17 | `i18n`, `safe`, `tuning` |
| `updateinstaller.lua` | 106 | 3 | `updatepolicy` |
| `updatepolicy.lua` | 53 | 4 |  |
| `updater.lua` | 160 | 4 | `_meta`, `actionmenu`, `i18n`, `updateinstaller`, `updatepolicy`, `updatetransport` |
| `updatetransport.lua` | 66 | 3 |  |
| `viewcanvas.lua` | 62 | 5 | `raster`, `rect`, `renderer` |
| `widgets.lua` | 104 | 2 |  |
| `xopp.lua` | 177 | 2 | `markerarea`, `pdfbackground` |
| `zoom.lua` | 17 | 3 |  |
| `zoomcache.lua` | 159 | 7 | `pdfbackground`, `raster`, `rect`, `renderer`, `template` |
| `zoomcanvas.lua` | 210 | 3 | `penpressure`, `rect`, `renderer`, `stroke`, `tuning`, `zoom` |
| `zoomrefresh.lua` | 157 | 9 | `rect`, `tuning`, `zoom` |
