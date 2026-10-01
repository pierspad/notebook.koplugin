# Gomma per area, ordine delle figure e costi di aggiornamento

## Base del confronto

Analisi del plugin Notebook, ramo `dev`, 1 ottobre 2026. Fetch e pull fast-forward
eseguiti: nessun commit remoto entrante. Il checkout conteneva già modifiche
locali su marker, geometria, rendering, persistenza, import/export e lasso.
Queste modifiche sono state preservate e costituiscono la base **prima** delle
misure qui riportate. Non sono risultati di un confronto con il solo HEAD.

Backup recuperabile della base locale:
`/tmp/notebook-before-optimization-20261001.tar.gz`.
Sono stati modificati soltanto i sorgenti e gli strumenti di Notebook; KOReader
è stato usato come runtime di riferimento. Nessun commit o deploy.

## Percorso della gomma e origine della latenza

1. `erasercanvas:_eraseAlong` filtra i salti/palmo, apre un batch di undo e
   raccoglie i punti del digitizer. Non interpola artificialmente decine di
   singoli eventi. La cancellazione usa tutta la polilinea raccolta.
2. `_applyErasePath` invoca il modello una volta per intervallo di display.
   La cadenza predefinita è 70 ms (`tuning.erase_repaint_ms`): questo introduce
   un'attesa percepibile anche se il calcolo è veloce. La prima posizione viene
   applicata subito e non consuma l'intervallo del primo movimento effettivo.
3. La gomma per oggetti esegue hit test e rimuove gli oggetti colpiti. La gomma
   per area deve invece produrre geometria sopravvissuta e bounds aggiornati:
   è intrinsecamente più costosa.
4. Per la penna, `stroke:splitAlongPath` usa bounds e indice a blocchi di 24
   punti, copia le sequenze non coinvolte e misura quelle potenzialmente colpite.
5. Per il marker, `markerarea.erase` sottrae capsule con approssimazione
   circoscritta a 24 lati dalle impronte geometriche dei segmenti. Non può usare
   il solo centro della penna: un taglio sul bordo deve rimuovere solo quel bordo.
6. Il modello restituisce due bounds distinti: area da ridisegnare ora e area
   da ripristinare nell'undo. Usare l'area dell'intero tratto per ogni update
   sarebbe molto più costoso. Questa distinzione era già nella base locale.
7. `_queueEraseRepaint` aggrega l'area sporca. A 1x, `canvasrender` ripristina
   la carta/cache di sfondo e ridisegna gli oggetti sovrapposti al clip. A zoom
   maggiore, `zoomcache` ripara la zona del bitmap e poi la copia sul viewport.
8. Il refresh UI e il pannello e-ink aggiungono costi diversi da quelli CPU.
   Il rilascio della penna scarica il lavoro pendente e chiude un unico undo.

### Sprechi eliminati

**Poligoni costruiti per segmenti distanti.** Prima, un marker ondulato da 1001
punti costruiva hull e contenitori per quasi ogni segmento, anche quando solo
pochi erano vicini alla gomma. Ora un test scalare sui bounds del segmento e
sul massimo raggio effettivo esclude i segmenti lontani prima dell'allocazione.
Le sequenze non toccate mantengono la rappresentazione originale compatta.
Il filtro include anche il margine della capsula circoscritta: non restringe
accidentalmente il taglio ai bordi. La sottrazione esatta resta invariata.

**Capsule identiche ricostruite per ogni evidenziatore.** Tutti i marker di
un'applicazione del modello condividono un contesto temporaneo con i cutter.
La costruzione è pigra, dopo la prima collisione coi bounds del marker.
Il contesto dura una sola chiamata del documento: nessuna invalidazione fra
path diversi, nessuna cache persistente, nessun aumento del formato su disco.
I cutter restano immutabili durante la sottrazione.

**Scorrimenti ripetuti della lista.** Prima ogni rimozione e ogni inserimento
di un frammento spostava la coda della lista con `table.remove/insert`. Una
cancellazione che coinvolge H tratti e F frammenti su N oggetti poteva fare
lavoro dell'ordine di `(H+F)*N`. Nel batch ora si costruisce la nuova lista con
un passaggio stabile `O(N+F)`. Se non ci sono hit non si ricostruisce la lista.
L'ordine dei frammenti e degli altri oggetti è preservato. Gli snapshot di
history rimangono copie separate, anche per i successivi erase per oggetti.
Tradeoff: un nuovo array di riferimenti per ogni batch che cambia la pagina,
in cambio dell'eliminazione degli scorrimenti quadratici.

**Scanline su poligoni invisibili.** Un frammento multipart può essere vicino
al clip in Y ma lontano in X. `highlightink.polygon` prima percorreva comunque
ogni bordo per ogni riga. Ora calcola anche l'estensione X e interrompe prima
quando il contorno non può produrre pixel nel clip. Il confronto conserva la
tolleranza subpixel inclusiva `1e-8`. Nessun cambiamento al blending o ai colori.

## Controllo diretto dell'ordine

Il pulsante testuale “Ordine” e il dialogo successivo sono sostituiti da un
controllo a due pulsanti adiacenti: freccia su + T, freccia giù + T. Altezza
identica agli altri pulsanti, spazio di tocco completo e icone SVG native.
Il bordo inferiore sottolinea il lato attivo. Se la figura è in una posizione
intermedia nella lista, inizialmente nessun lato è indicato come assoluto.

Il tap applica immediatamente il paint order, ridisegna la figura e ricrea la
selezione con lo stato aggiornato. Restano undo/redo, autosave differito e
invalidazione della cache zoom. Un comando già soddisfatto non aggiunge history.
La pressione prolungata spiega “Sopra il testo” / “Sotto il testo”, tradotti.
I due messaggi del dialogo rimosso sono eliminati da POT e tutti i cataloghi.

La semantica resta quella preesistente: porta l'oggetto all'inizio/fine della
lista di disegno, quindi rispetto anche a penna e altri oggetti. Non viene
introdotto un nuovo campo persistente di layering relativo al solo testo.

## Misure ripetibili

`tools/bench-eraser.lua`: produzione con stub delle dipendenze KOReader,
mediana di 7 campioni dopo 2 warmup, GC fra campioni, 12 tagli per sequenza.
Confronta esattamente tutte le tabelle serializzate di geometria e stile,
ordine dei frammenti e undo/redo. Misura CPU per applicazione del modello,
escludendo fixture, controllo degli output, commit e undo/redo.

| Scenario | Prima, ms | Dopo, ms | Rapporto |
|---|---:|---:|---:|
| 12 marker rettilinei, 1001 punti ciascuno | 1,213 | 1,151 | 1,05x |
| 12 marker ondulati, 1001 punti ciascuno | 23,566 | 9,356 | 2,52x |
| 2000 tratti di penna, cancellazioni dense | 7,433 | 3,097 | 2,40x |

Il caso rettilineo è sostanzialmente invariato: il piccolo scarto non va
interpretato come un miglioramento robusto.

Con JIT disattivato, stesso harness:

| Scenario | Prima, ms | Dopo, ms | Rapporto |
|---|---:|---:|---:|
| Marker rettilinei | 4,014 | 3,728 | 1,08x |
| Marker ondulati | 58,715 | 27,504 | 2,13x |
| Penna, cancellazioni dense | 30,584 | 6,945 | 4,40x |

`tools/bench-marker-repaint.lua`: framebuffer nativo BB8 1860x2480, marker
ondulato da 1001 punti dopo 12 tagli, clip 45x55, 100 repaint per campione,
mediana di 5 dopo 2 warmup. Confronto pixel per pixel dell'intero buffer:
**7,235 → 3,897 ms/update (1,86x)**, pixel identici. Ripristino del clip e
ridisegno sono inclusi; refresh del pannello escluso.

Il precedente benchmark nativo `bench-marker-area.lua`, un singolo marker,
mostra **2,844 → 1,444 ms/taglio** per il caso ondulato. Il rendering completo
della pagina resta circa **15,4–15,7 ms**. Non si dichiara un miglioramento del
rendering completo: il guadagno nuovo riguarda il ridisegno locale.

Esecuzione dalla radice del plugin, usando una copia dei sorgenti prima:

```sh
luajit tools/bench-eraser.lua /percorso/base/lua
luajit tools/bench-eraser.lua /percorso/base/lua --jit-off
```

Dalla directory del runtime KOReader contenente `setupkoenv.lua` e `luajit`:

```sh
./luajit /plugin/tools/bench-marker-repaint.lua /plugin/lua /percorso/base/lua
SDL_VIDEODRIVER=dummy ./luajit /plugin/tools/check-shape-order.lua /plugin/lua
./luajit /plugin/tools/check-marker-area.lua /plugin/lua
./luajit /plugin/tools/check-highlight-buffer.lua /plugin/lua
```

Questi numeri sono misure su desktop. Non misurano digitizer, code degli eventi,
waveform, ghosting o temperatura del Kindle. I tempi fra harness diversi non
vanno sommati: usano fixture differenti.

## Verifiche di comportamento

- Suite completa `make verify`: lint Lua, 42 suite, cataloghi validati da msgfmt.
- `make check-package`: ZIP integro, moduli e icone distribuiti, test esclusi.
- Regressione dei controlli diretti riprodotta prima della modifica: invocare
  il comando front lasciava l'ordine invariato perché apriva il vecchio dialogo.
- Test di selezione conservata, no-op senza history, front/back, undo/redo a 1x/2x.
- Test del rilascio dopo preview della trasformazione già dipinta.
- Prova nativa del tap propagato nel widget tree, aree di tocco posizionate,
  icone, altezze uguali, indicatore attivo, copertura dei pixel e undo a 1x/2x.
- Oracle geometrico indipendente per tagli circolari/polilinee, bordi dei marker,
  poligoni multipart, punti sparsi, reversal e cancellazioni ripetute.
- Roundtrip persistente e confronti dei pixel con buffer nativi BB8/RGB32,
  quattro rotazioni, backend C/Lua; blending RGB16/24/32, inversioni e viewport.

## Altri percorsi controllati e costi residui

| Percorso | Evidenza nel codice / scelta |
|---|---|
| Penna live | Disegna incrementi e accumula dirty rect; il pen-up non riproduce l'intero tratto. Le suite liveink/interaction coprono questa proprietà. |
| Figure e rotazione | Snapshot del fondo per gesto, preview binaria a 50 ms, ultimo endpoint e rilascio verificati. Evita il replay del fondo ad ogni movimento. |
| Zoom | Riparazioni locali della bitmap, pending ink e revisioni; invalidazione per cambio ordine conservata. Test zoomhistory/zoomrefresh. |
| Cambio pagina | Cache di due pagine entro budget 12 MiB; invalidazione e rilascio memoria coperti da performance. |
| Salvataggio | Serializzazione riusata per pagine pulite; dirty revision e scrittura atomica preservate. Non aggiunto I/O al percorso del digitizer. |
| Lasso | Bounds preliminari e copie di clipboard separate dall'history già presenti; nessuna modifica speculativa. |
| Undo/redo | Snapshot distinti e ordine stabile; i benchmark ricontrollano i frammenti dopo redo. |
| Refresh | Cadenzato e cleanup differito già presenti. Abbassare indiscriminatamente 70 ms può saturare la coda e-ink. |
| Rappresentazione marker | Multipart evita migliaia di oggetti, ma contorni e frammenti possono comunque crescere con molti tagli. Nessuna semplificazione lossy introdotta. |
| Scansione della pagina | Il modello e il repaint attraversano ancora la lista dei tratti. Un indice spaziale di pagina potrebbe aiutare notebook estremi, ma richiede invalidazione rigorosa su tutte le trasformazioni/history/load. Non introdotto senza misure di necessità. |
| Gomma per oggetti | La rimozione usa ancora scorrimenti della lista; il lavoro qui è concentrato sulla gomma per area segnalata. Un harness dedicato permetterebbe di scegliere compattazione e preservare indici dell'undo. |

La latenza percepita residua ha quindi una componente certa di cadenza (70 ms
predefiniti), una componente misurata di geometria/raster e una componente
hardware non misurata. Le modifiche riducono le seconde senza alterare i
parametri del pannello. Il tuning della cadenza va confrontato sul dispositivo
con la stessa pagina, stessa velocità della mano e stessa impostazione di refresh.
