# Stable release, gomma spessa e selezione visuale delle pagine

## Stato delle versioni e riproducibilità

La baseline è la release ufficiale **v1.5.0**, pubblicata il 1 ottobre 2026:
https://github.com/pierspad/notebook.koplugin/releases/tag/v1.5.0
La workflow di release 36868702347 è riuscita; tag/release sono stabili, non prerelease.
Il pacchetto ufficiale misura 292398 byte; SHA-256:
`0487de2bca5ef87d474e77f84cea398a9ed79883f9dd1bf79bfe7c7fed4ebada`.

Le modifiche successive sono locali, con metadata **v1.6.0-dev.1**. Non sono state
pubblicate e non è stata sostituita l'estensione attiva sul Kindle. Il downloader
è già nel repository della release stabile, in `utils/download-release.sh`.
Le modifiche preesistenti del README sono preservate.

Prima delle modifiche è stata copiata `lua/` in `/tmp/notebook-next-baseline/lua`.
I report contengono hash dei sorgenti e delle fixture, runtime, architettura,
profilo JIT realmente attivo, frequenze CPU e nove campioni per caso.
Sul Kindle la frequenza registrata era 2000000 kHz in tutti i campioni riportati.
Le misure sono CPU/offscreen: escludono il tempo fisico del pannello e-ink.

## Responsabilità dei componenti

- `pagetile.lua`: carta, miniature, numero/checkbox e gesti del singolo riquadro.
- `pagegrid.lua`: dimensionamento fullscreen, paginazione, swipe e rilascio dei widget.
- `pagepanel.lua`: navigazione e azioni che modificano le pagine. Scende da 467 a 221 righe.
- `exportpagesdialog.lua`: selezione delle pagine, sincronizzazione della barra,
  tastiera/range e conferma. Non contiene azioni di modifica del documento.
- `pageselection.lua`: parser, formattazione compatta e vista di esportazione;
  indipendente dalla UI e dalle modifiche ai notebook.
- `markerhit.lua`: contatto geometrico della gomma con l'impronta visibile del marker.
- `markerclip.lua`: sottrazione convessa e bounds dei poligoni immutabili.
- `markerarea.lua`: costruzione delle impronte, conservazione delle sequenze non
  toccate e creazione dei frammenti. Non gestisce più il clipping delle half-plane.

Il loader privato include tutti i nuovi moduli. I test della UI che reinstallano
lo schermo azzerano anche i moduli estratti: evita che una fixture riusi il Device
catturato dalla fixture precedente.

## Gomma: correttezza e ottimizzazione

La gomma per oggetti cercava la linea centrale di un evidenziatore non ancora
frammentato, usando solo il raggio della gomma. Un marker largo 100 px a y=80
veniva ignorato da una gomma a y=120, benché quell'area fosse dipinta.
Il test falliva prima della correzione. Ora il contatto segue i quadrati del pennino
con la pressione effettiva e il loro hull, anche lungo percorsi sparsi. I frammenti
separati mantengono i loro vuoti; non si collegano contorni indipendenti.
I contatti sui quadrati degli estremi si risolvono senza allocare un hull.
Le sequenze lontane sono escluse usando l'indice a blocchi già esistente.

Nella gomma per area, la sottrazione prima calcolava l'intersezione e poi tornava
sugli stessi lati due volte per separare interno ed esterno. Ora un solo passaggio
produce entrambe le metà. Se l'intersezione finale ha area nulla, viene conservato
il poligono originale: un semplice overlap dei bounds non produce modifiche o undo.
I bounds dei poligoni immutabili sono calcolati una volta per la durata del lavoro
geometrico; non costituiscono una cache persistente nei notebook o nel formato su disco.
I blocchi lontani della linea originale vengono copiati insieme, senza valutare
il pennino di ogni campione. La geometria di clipping e i pixel restano equivalenti.

### Benchmark Kindle: 1001 punti ondulati, 12 tagli e undo/redo

| JIT | Larghezza marker | Prima, ms/batch | Dopo, ms/batch | Riduzione CPU |
| --- | ---: | ---: | ---: | ---: |
| on | 48 | 122.566 | 72.212 | 41.1% |
| on | 120 | 514.024 | 326.162 | 36.5% |
| on | 300 | 2569.547 | 1546.817 | 39.8% |
| off | 48 | 369.517 | 182.830 | 50.5% |
| off | 120 | 1672.973 | 786.714 | 53.0% |
| off | 300 | 7530.189 | 3670.242 | 51.3% |

I valori riguardano l'intero batch di 12 tagli con history, non un singolo evento.
Con JIT, il caso largo 300 px resta a circa 129 ms/taglio come media del batch;
senza JIT circa 306 ms/taglio. Sono ancora costi visibili: i marker molto larghi,
curvi e già frammentati restano una priorità. Il prossimo intervento dovrebbe
ridurre il lavoro sui contorni ripetuti, verificando anche memoria e persistenza.
Non ho cambiato il formato vettoriale né introdotto un modulo C/C++.

Il test dei bordi corregge il risultato e quindi non è un confronto a lavoro
semanticamente equivalente: la baseline perdeva contatti. Sul Kindle 60 query
ora costano circa 0.60–0.86 ms con JIT e 2.21–3.41 ms senza JIT. Il report mostra
anche gli hit. Il comparatore segnala risultati differenti e non li presenta come
semplici regressioni CPU. La correttezza resta verificata dalle suite dedicate.

### Costi nascosti e limiti delle misure

Il benchmark aggiunge pennini da 48/120/300 px, contatti ai bordi e 12 tagli ripetuti.
Registra anche oggetti, contorni e punti risultanti nei nuovi casi di taglio.
Il numero di oggetti da solo nasconde i contorni contenuti in un marker multipart.
CPU, wall time, heap prima del GC, memoria trattenuta, RSS e costo GC sono riportati.
Il delta heap a fine campione non è il picco RSS né il totale delle allocazioni:
l'auto-GC può intervenire durante il campione. Alcuni casi larghi hanno delta heap
superiori pur risultando più veloci; non va dedotta una riduzione universale della RAM.

Un primo confronto desktop eseguito insieme a verifiche native mostrava rumore e
un caso largo peggiorato. È stato sostituito da un confronto isolato per `marker-cuts`;
le misure autorevoli per il dispositivo sono quelle del Kindle. I test funzionali
non vengono usati come prova di velocità, e le verifiche native sullo stesso host
non vengono eseguite insieme al suo benchmark.

## Esportazione visuale

`Esporta → Scegli pagine` apre la griglia fullscreen delle miniature, con caselle.
La selezione copre l'intero notebook, anche oltre la schermata visibile; swipe e
frecce cambiano la schermata della griglia. Tutti/Nessuno agiscono su tutte le pagine.
Toccando la barra dei numeri si apre l'input con tastiera; confermandolo vengono
sincronizzate caselle e barra. Toccando una miniatura si aggiorna il range compatto.
La selezione iniziale comprende tutte le pagine. Nessuna selezione blocca Continua.

Il parser supporta numeri, intervalli inclusivi, virgole e punti e virgola, spazi,
duplicati e estremi aperti. Su otto pagine `-3;5-` equivale a `1-3,5-8`.
L'estremo sinistro omesso vale 1; quello destro vale il totale. Range rovesciati,
fuori bounds, token vuoti e separatori finali sono respinti. Un range invalido non
modifica la selezione precedente. Selezionare/esportare non modifica le pagine o undo.
Il parser e la vista conservano il mapping della pagina sorgente dei PDF.

## Toolbar che ricompare dopo inattività

Il timer dell'orologio scriveva direttamente nel framebuffer, senza conoscere
l'overlay fullscreen. Il problema dipendeva dal cambio di minuto, quindi poteva
apparire dopo pochi secondi. La regressione ora apre il pannello di produzione,
invoca il timer e verifica che i pixel non cambino.

Notebook possiede esplicitamente il pannello aperto e lo rilascia sul CloseWidget.
Il canvas sospende i propri callback di disegno e l'input stylus durante l'overlay;
l'orologio conserva la propria cadenza. Alla chiusura si ridisegna il notebook,
si elimina il debito di refresh del vecchio framebuffer e si riprogramma l'autosave
se necessario. Il pannello viene chiuso anche quando si chiude il notebook.
Il comportamento di suspend/screensaver continua ad avere test separati.

## Aggiornamento: cosa è stato provato davvero

Il test nativo scarica dal GitHub ufficiale la 1.4.0 e la latest stabile 1.5.0 usando
il transport di produzione. Verifica metadati, dimensione, SHA-256 e archivio;
installa la 1.4.0 in una directory temporanea, la sostituisce con la 1.5.0, verifica
metadata della nuova copia e del backup e assenza di un file divenuto obsoleto.
È riuscito sia in locale sia sul Kindle. Le fixture verificano anche archivio
ostile, Lua invalido, versione sbagliata, checksum sbagliato e rollback su rename fallito.

`utils/download-release.sh 1.5.0` è stato provato sia in locale sia sul Kindle:
ha scaricato e verificato lo ZIP ufficiale. Sul dispositivo l'output del test era
in `/tmp` e viene eliminato a fine prova. Lo script normale salva in Downloads.

Non è stata sostituita la copia attiva né riavviato KOReader per un aggiornamento
interattivo. Il test completo dell'utente dalla 1.5.0 alla prossima stabile sarà
possibile quando verrà pubblicata una nuova release ufficiale. Le `-dev` sono escluse.
Il rollback gestisce gli errori normali; due rename separati non garantiscono
atomicità rispetto a una perdita di alimentazione tra i rename.

## Verifiche e comandi

- `make verify`: lint senza warning e 46 suite riuscite.
- `make check-package`: ZIP `v1.6.0-dev.1` valido.
- Runtime nativo locale e Kindle: 672 confronti renderer, 29 preview/PDF e 80
  tagli geometrici ripetuti con pixel equivalenti alla baseline.
- Runtime nativo locale e Kindle: pannello pagine inattivo e screensaver non
  alterati dai callback; ink e ownership input corretti a 1x e 2x.
- UI nativa locale e Kindle: checkbox, parser, barra con tastiera e controlli;
  layout verificato a 600×800 e 1860×2480.

```sh
make verify
make check-package
python3 tools/check-native.py --baseline /path/to/baseline/lua
python3 tools/check-updater.py --network --ui
python3 tools/benchmark.py --baseline /path/to/baseline/lua --filter marker-cuts
python3 tools/benchmark.py --baseline /path/to/baseline/lua --filter marker-edge
# Gli stessi wrapper accettano --ssh root@INDIRIZZO e --port.
```

I report grezzi sono in `results/2026-10-01-stable-followup-*`.
