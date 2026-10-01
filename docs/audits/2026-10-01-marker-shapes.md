# Audit: figure, superficie dell’evidenziatore e cancellazione

Data: 1 ottobre 2026. Base: `dev`, commit `7410d78`, versione
`v1.5.0-dev.3`. `git fetch` e `git pull --ff-only` eseguiti: nessun commit
in ingresso, checkout inizialmente pulito. Modifiche locali, senza commit,
push o installazione sul dispositivo. Questo rapporto integra l’audit
`2026-10-01-performance.md`: approfondisce il percorso di disegno e modifica,
non ripete la precedente revisione di storage, galleria e condivisione.

## Problemi riprodotti prima delle correzioni

| Problema | Percorso | Evidenza riproducibile |
| --- | --- | --- |
| Cancellazione a blocchi | `Stroke:splitAlongPath` | Un marker largo 40 px, centro a y=80, non veniva toccato da una gomma r=6 a y=65, pur essendoci superficie colorata sotto la gomma. Test fallito: `nib edge missed`. |
| Anteprima grigia poco leggibile | `ShapeCanvas:_paintShape` | Una figura colore 160 veniva rasterizzata in grigio e inviata a `refreshFast`. Test fallito: `gray figure sent to binary waveform`. |
| Riempimento pesante durante il movimento | creazione/trasformazione figure | Ogni anteprima rasterizzava il riempimento definitivo, coprendo lo sfondo durante il trascinamento. |
| Perdita di metadati | resize/rotazione | Il resize costruiva sempre una figura con `Shape.create`, quindi una figura riconosciuta da un marker poteva diventare penna. `Shape.transform` ometteva `tint`. |
| Lavoro su eventi identici | anteprime figure | Eventi con le stesse coordinate ricreavano e ridisegnavano la stessa geometria. |

La causa della cancellazione non era soltanto il rasterizzatore. Il modello
eliminava punti centrali e ricostruiva i tratti dai punti rimasti. Ogni punto
portava con sé una grande impronta quadrata, e togliere un punto eliminava anche
i segmenti adiacenti. Una gomma piccola non poteva scavare una parte della
larghezza del marker. Cambiare solo la forma della punta avrebbe nascosto
parte del sintomo senza correggere questa semantica.

Non è stata misurata la latenza fisica del pannello e-ink. I test dimostrano il
contenuto del framebuffer e le chiamate di refresh; i benchmark misurano CPU e
blitbuffer reali sul desktop. La valutazione della fluidità sul Kindle richiede
una prova sul dispositivo.

## Nuovo percorso dell’evidenziatore

### Superficie continua

Il tratto è il movimento continuo di una punta a scalpello, con pressione
interpolata linearmente tra campioni. Restano estremità da marker; spariscono
le grandi scalettature dovute alle impronte distanziate lungo le diagonali.

`highlightink.drawSegment` non interpola più una serie di stampate. Per ogni
riga visibile risolve le due disequazioni dei lati verticali della punta e
ottiene l’intervallo di posizioni del centro che copre quella riga. Valuta poi
i lati orizzontali agli estremi dell’intervallo e colora uno span. Il lavoro
geometrico cresce con l’altezza visibile, quello di blending con i pixel nuovi.

L’impronta iniziale condivisa può essere esclusa quando è già stata disegnata:
si elaborano solo le strisce nuove. La stessa ottimizzazione vale per variazioni
di pressione, svolte e inversioni. Il clipping resta limitato al viewport.

Il blending mantiene il minimo per canale RGB, oppure il minimo di grigio.
Ripassare con lo stesso marker non accumula oscuramento. L’anteprima live
rimane il reticolo nero ancorato ai pixel, poi sostituito dal colore definitivo.
La scelta del colore ora è unica per segmenti, punti isolati e aree cancellate:
un marker con tinta implicita non cambia tinta quando viene frammentato.

### Cancellazione geometrica

`markerarea` costruisce l’inviluppo convesso delle due impronte quadrate agli
estremi di un segmento. Per pressione lineare è il medesimo sweep del renderer.
La gomma è una capsula per ogni segmento del percorso, approssimata da un
inviluppo di cerchi circoscritti a 24 lati. Viene sottratta alla superficie del
marker, anziché ai suoi soli punti centrali.

Prima della sottrazione si verifica l’intersezione reale: l’overlap di due box
non basta a creare frammenti o una voce undo. La differenza tra poligoni
convessi viene scomposta in parti con tagli di semipiano. Poligoni degeneri,
con area numericamente nulla, vengono scartati. Una gomma ferma è un contatto
circolare; un movimento rapido mantiene tutta la capsula, senza buchi tra
campioni; un percorso con più segmenti applica tutte le capsule in ordine.

La capsula circoscritta evita residui dentro il cerchio della gomma, con un
sovrataglio massimo `r*(sec(pi/24)-1)`, circa 0,345 px per r=40 in coordinate
di pagina. A zoom 2 il medesimo errore geometrico raddoppia in pixel schermo.
Non si tratta di una sottrazione circolare matematicamente esatta.

I bounds della ridipintura coprono il percorso della gomma, l’approssimazione
e un margine di raster. I bounds di undo restano quelli degli oggetti originali.
`Document` continua a gestire batching, revisioni, ordine dei tratti e history.

### Controllo della frammentazione

Una prima implementazione corretta geometricamente creava un oggetto Stroke
per ogni poligono superstite. Il benchmark su una curva di 1001 punti e 12 tagli
ha prodotto 7735 oggetti: un costo inaccettabile per liste, undo e salvataggio.
Questo risultato è stato usato per rivedere l’implementazione prima della
consegna, non è il comportamento finale.

Ora le parti convesse contigue sono raccolte nello stesso Stroke: i vertici
restano nell’array piatto `pts`; il campo opzionale `marker_parts` registra gli
indici finali delle parti indipendenti. Non esistono segmenti tra la fine di una
parte e l’inizio della successiva. I tratti centrali non toccati restano normali
Stroke compatti; segmenti collineari con pressione uguale vengono trattati
come un unico sweep senza alterare la loro superficie.

`marker_parts` è conservato da serializzazione/deserializzazione, copiato
indipendentemente da `clone`, passato ai descrittori scalati e validato durante
il caricamento. Sono accettati soltanto marker filled, indici interi finiti,
parti di almeno tre vertici, ordine strettamente crescente e copertura esatta
dell’intero array di punti. Un caricamento invalido non sostituisce il documento
aperto. Il codec `.scribe` esistente resta in uso; non è un formato raster e
non vengono salvati snapshot dello schermo.

I quaderni precedenti continuano a caricarsi. L’aspetto delle diagonali di
marker precedenti segue la nuova superficie continua. I nuovi marker cancellati
usano metadati che le versioni precedenti non sanno renderizzare correttamente:
il mantenimento del numero di formato non implica fedeltà visiva facendo
successivamente downgrade del plugin.

## Figure: anteprima e risultato definitivo

Durante creazione, resize e rotazione si mostra un contorno nero senza
riempimento. Il descrittore di preview eredita la geometria, ma forza penna
fineliner e nero: modificare una figura nata da un marker non reintroduce una
preview grigia. Il modello definitivo conserva tool, stile, tinta, colore e fill.

Al rilascio si ripristina lo sfondo nell’area interessata, si disegna una volta
il risultato definitivo e si usa la modalità UI per grigi, marker e matita.
Per la creazione non si ripercorre tutta la pagina dal modello. Rimangono la
cadenza massima di 50 ms e un solo callback differito con l’ultimo endpoint.
Campioni identici non ricreano geometria o snapshot.

La rotazione/resize conserva l’ultimo endpoint anche se il rilascio precede
il callback. Timer e buffer del gesto vengono rilasciati; i test esercitano il
rilascio con endpoint ancora accodato. La ridipintura definitiva dopo un resize
mantiene il percorso che ristabilisce l’ordine rispetto agli altri tratti;
non è stata eliminata per risparmiare tempo sacrificando la sovrapposizione.

Il costo residuo è il ripristino dello snapshot e l’aggiornamento di una regione
che può essere grande. Non si attribuisce al contorno nero la capacità di
eliminare i limiti di refresh di un pannello fisico. Le figure riconosciute al
termine di un hold mantengono la ridipintura UI locale già prevista da
`snapcanvas`: la verifica nativa conferma che freccia e cache zoom coincidono
con il rendering autorevole.

## Responsabilità e integrazioni controllate

| Componente | Responsabilità dopo la modifica |
| --- | --- |
| `markerarea` | geometria dello sweep, intersezione/sottrazione, contorni indipendenti |
| `highlightink` | scanline continue, clipping dei pixel, blending, preview binaria |
| `renderer` | scelta colore, routing fra tratti e aree, descrittori scalati |
| `stroke` | metadati, clone, bounds e hit test delle superfici senza ponti |
| `document` | validazione del file, batching, undo/redo, revisioni e ordine |
| `shapecanvas` | stato del gesto, coalescing, preview e finalizzazione |
| `lasso` | selezione dentro una superficie e sui suoi contorni reali |
| `svg` / `xopp` | esportazione delle parti indipendenti senza bordi larghi o collegamenti |
| `loader` | inclusione del nuovo modulo nella cache privata del plugin |

Il loader è una whitelist manuale: il primo benchmark nativo ha rilevato che
il nuovo modulo non era incluso. È stato aggiunto e il test del loader ora
inietta un modulo omonimo estraneo, poi esegue rendering e cancellazione con
il require privato. Il test puro del nuovo file, da solo, non avrebbe coperto
questa integrazione.

L’hit test dei filled marker controlla l’interno e gli spigoli di ciascuna
parte. Il lasso riconosce una selezione interamente dentro la superficie e non
campiona falsi collegamenti tra contorni. Clone, traslazione, caricamento,
scalatura e ridipintura parziale mantengono le separazioni.

SVG esporta superfici a scalpello, con blending darken, anziché sequenze di
dischi e opacità che accumulerebbe colore fra frammenti sovrapposti. Il supporto
di `mix-blend-mode` dipende dal visualizzatore SVG. XOPP esporta i contorni
indipendenti chiusi con fill, con bordo minimo, anziché ridisegnarli usando la
larghezza della punta originale. Il formato del fill è stato verificato nel
[SaveHandler ufficiale Xournal++](https://github.com/xournalpp/xournalpp/blob/master/src/core/control/xojfile/SaveHandler.cpp).
L’interchange XOPP conserva le precedenti approssimazioni di colori e pressione;
non è una verifica di equivalenza visiva in un’istanza di Xournal++.

## Test e misure

Verifica finale eseguita con `make verify`: 42 suite, lint Lua senza
warning, controllo dei cataloghi. `make check-package` verifica archivio,
file principali, cataloghi e assenza dei test nel pacchetto.

| Verifica nuova o ampliata | Cosa impedisce |
| --- | --- |
| 800 sweep con oracle di disequazioni indipendente | errori su diagonali, coordinate frazionarie, pressione, punti fermi, inversioni, clipping e preview |
| Sequenze incrementali vs rendering completo | perdita di strisce condivise sulle svolte e con pressione variabile |
| 80 tagli circolari randomizzati | cancellazione fuori dalla gomma, superficie rimasta dentro la gomma, pixel diversi dopo history/save/load |
| Save/load a scale 0,5 / 1 / 2 | perdita di geometria o metadati nel renderer scalato |
| Marker sparsi, tagli ripetuti e contatti sul bordo | dipendenza dai campioni centrali, frammentazione per punto e undo su zone vuote |
| Sweep diagonali e polilinee con inversioni, oracle di distanza indipendente | buchi tra campioni e sovrataglio lontano dal percorso |
| Contorni disgiunti | ponti inesistenti in rendering, hit test, lasso, esportazione e persistence |
| Otto indici di contorno malformati | accessi invalidi o sostituzione parziale del documento durante il load |
| Preview figure a 1x/2x e pen-up nel throttle | colore invisibile, fill temporaneo, endpoint perso, timer o buffer trattenuti |
| Resize/rotazione marker | perdita di tool o tinta |
| Loader con collisioni di nomi | dipendenza accidentale da moduli di un altro plugin |

Prove native, tutte eseguite sul runtime KOReader locale:

- `check-marker-area.lua`: tagli, clip e roundtrip nel codec bitser/zstd reale,
  BB8/RGB32, rotazioni 0–3 e backend C/Lua.
- `check-highlight-buffer.lua`: oracle indipendente sul viewport, rotazioni,
  inversioni e blending RGB16/24/32, canali scuri, ripassi idempotenti.
- `check-snap-render.lua`: sostituzione frecce e riparazione locale della cache
  zoom uguali al rendering autorevole.

Benchmark `bench-marker.lua`, stesso processo, confronto con
`git show 7410d78:lua/highlightink.lua`. Millisecondi CPU, buffer 1860×2480:

| Caso | Prima | Ora | Rapporto prima/ora |
| --- | ---: | ---: | ---: |
| Orizzontale lungo, colore | 0,502 | 0,512 | 0,98× |
| Diagonale lunga, colore | 1,033 | 1,174 | 0,88× |
| Diagonale lunga, preview | 0,126 | 0,111 | 1,14× |
| 300 campioni fitti, width 48, colore | 0,911 | 0,607 | 1,50× |
| 300 campioni fitti, width 48, preview | 0,518 | 0,355 | 1,46× |
| 300 campioni fitti, width 192, colore | 6,942 | 2,202 | 3,15× |
| 300 campioni fitti, width 480, colore | 35,815 | 6,253 | 5,73× |

Il nuovo percorso non è più veloce in ogni situazione: la diagonale lunga a
colore definitivo costa circa 14% in più in questa misura. Questo costo è
misurato e distinto dalla preview durante il contatto. Non si usa il massimo
speedup come promessa generale di fluidità.

Benchmark `bench-marker-area.lua`, 1001 punti, 12 tagli, media su 12 documenti:

| Geometria | ms/taglio | ms/render pagina | oggetti finali |
| --- | ---: | ---: | ---: |
| Retta | 0,190 | 0,675 | 1 |
| Curva ondulata | 2,727 | 15,879 | 25 |

Il raggruppamento ha ridotto la curva da 7735 a 25 oggetti rispetto al prototipo
intermedio. Restano molti vertici/contorni: è ridotto il costo degli oggetti,
non azzerata la complessità geometrica.

## Rischi residui e priorità per ulteriori interventi

1. **Prova sul dispositivo.** Misurare tempo campione→refresh, ritardo dopo
   pen-up, ghosting e riempimenti grandi. Hardware, waveform e carico dei quaderni
   non sono riprodotti dai benchmark desktop.
2. **Contorni dopo molte cancellazioni.** La rappresentazione è compatta negli
   oggetti, ma i vertici crescono. Un’unione geometrica esatta dei contorni o un
   indice per parte può ridurre rendering e sottrazioni; richiede oracle di
   superficie e test su sovrapposizioni, buchi e precisione, prima di adottarla.
3. **Gomma sulla penna.** Il percorso della penna continua a eliminare campioni
   centrali: un segmento molto sparso può non essere tagliato fra due punti.
   Non è stato generalizzato il nuovo modello dell’area a tutti gli stili della
   penna: pressione, grana e calligrafia richiedono geometrie proprie.
4. **Bounds delle anteprime figure.** Anche il solo contorno ripristina e
   aggiorna un box grande. Ripristinare strisce separate può aiutare rettangoli;
   aumentare il numero di refresh può invece peggiorare il pannello. Serve una
   misura hardware prima di cambiare questa politica.
5. **Memoria temporanea.** Snapshot di figure/live ink e cache di pagina hanno
   già lifecycle e limiti dedicati, ma un quaderno RGB grande può avere più
   buffer contemporanei. Non è stato introdotto un ulteriore buffer bitmap per
   la cancellazione. Il picco va misurato sul modello di dispositivo usato.
6. **Esportazioni.** Validazione XML/SVG e geometria dei contorni sono coperte;
   colore/blending fra visualizzatori esterni restano un limite dell’interchange.
   Aprire il file in Xournal++ e in due visualizzatori SVG completa la verifica.
7. **Dipendenze geometriche.** `markerarea` riusa la funzione pura
   `Renderer.radiusFor` con require lazy; estrarre in futuro una funzione comune
   del pennello è possibile, ma non sono state duplicate formule di pressione.
8. **Whitelist del loader.** Il test ampliato copre il nuovo modulo; resta utile
   una verifica automatica dell’inventario dei moduli di produzione per le
   prossime aggiunte, evitando una seconda fonte di verità manuale.

Non risultano modifiche a progetti fratelli. Il runtime KOReader è stato usato
come ambiente di verifica; il pacchetto prodotto contiene soltanto il plugin.
