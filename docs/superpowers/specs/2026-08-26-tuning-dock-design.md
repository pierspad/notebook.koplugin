# Tuning dock — design

Un pannello di taratura in-place, aperto solo dentro un taccuino chiamato
`_tuning_`, che espone come manopole le costanti oggi sepolte in cima ai moduli.

## Perché

Le costanti che governano la sensazione della penna — ogni quanto si aggiorna il
pannello mentre si scrive, ogni quanto si ridipinge mentre la gomma passa, quanto
si aspetta prima di far scattare una forma — sono state scelte a occhio e non
sono mai state confrontate con un'alternativa sul dispositivo vero. L'emulatore
non può dire nulla al riguardo: non ha né pannello E-Ink né digitizer.

Due sintomi noti aspettano questa misura: la gomma "part of a stroke" che arranca,
e lo spostamento di una selezione col lazo che resta molto indietro rispetto alla
punta. Entrambi possono essere un valore sbagliato oppure un algoritmo che
ridipinge troppo, e oggi non c'è modo di distinguerli senza ricompilare e
ridistribuire per ogni tentativo. Questo pannello è lo strumento che rende la
domanda rispondibile in pochi secondi invece che in minuti.

L'obiettivo è **trovare i valori giusti e congelarli nel sorgente**, non rendere
il plugin configurabile: nessuna di queste manopole è mai visibile a chi apre un
taccuino normale.

## Il cancello

`Notebook.title == "_tuning_"`, dove il titolo è già quello che `main.lua` passa
all'apertura. Nessun file sentinella, nessun gesto, nessun SSH: si crea il
taccuino dalla galleria e si scrive quel nome.

Un taccuino con qualunque altro nome esegue esattamente il codice di oggi. Non
c'è un ramo nuovo in nessun percorso caldo — l'unica differenza è un rettangolo
`content` più corto, che è già un parametro.

## Il dock

Una fascia in fondo allo schermo, alta circa un terzo, con la tela sopra.

Non è un dialogo. Un dialogo modale è inutile qui: mentre è aperto non si può
scrivere, e il ciclo "cambio un valore, chiudo, provo, riapro" costa più
attenzione del fenomeno che si sta cercando di sentire. Con il dock aperto si
cambia un valore e si traccia subito un tratto un centimetro più su: la differenza
la si sente nella stessa mano, non nella memoria di trenta secondi prima.

Tecnicamente è il meccanismo che già esiste. `Canvas.content` è un `Geom`
arbitrario passato dall'esterno, oggi usato per riservare la banda della toolbar
in alto; `Canvas:init` rifiuta i punti la cui impronta non ci sta dentro, e
`Document:setContentOrigin` porta dietro le coordinate. Riservare una fascia in
basso è la stessa cosa, sullo stesso codice, già collaudata contro il caso della
toolbar.

**Conseguenza accettata:** l'inchiostro è salvato in coordinate schermo, quindi le
pagine scritte con il dock aperto hanno una geometria diversa da quelle normali,
e un export PDF del taccuino di prova avrebbe margini strani. Per un taccuino usa
e getta non importa, ed è un motivo in più perché il cancello sia un taccuino
dedicato: nessun taccuino vero cambia mai geometria.

### Intestazione

Una riga fissa, sempre visibile:

> `Test notebook — rename it if you are not tuning`

Nell'intestazione del dock e non come tratti disegnati nella pagina. Dei tratti
sarebbero cancellabili con la gomma, finirebbero nel PDF, e andrebbero ricreati a
ogni pagina nuova; una riga del dock non si può perdere per sbaglio e compare
esattamente nella condizione che deve segnalare.

Accanto, i comandi globali: `Reset tab`, `Reset all`, `Dump`.

### Steppers, non slider

Ogni parametro è una riga: `[−]  nome   valore  [+]`.

Uno slider trascinabile è la scelta sbagliata per questo lavoro in particolare.
Trascinare su e-ink genera una raffica di refresh parziali, cioè esattamente il
fenomeno che si sta misurando: lo strumento inquinerebbe la misura. E darebbe
"circa 47" quando poi il numero va trascritto esatto nel sorgente. Un tap è un
passo, un refresh, un valore preciso.

Tap lungo su `−`/`+` ripete, per i parametri con range ampio.

Ogni riga si ridisegna da sola quando cambia: un refresh parziale del rettangolo
della riga, non del dock.

### Tab

Cinque, che sono i cinque comportamenti che si tarano separatamente perché si
provano con gesti diversi.

| Tab | Cosa si prova |
| --- | --- |
| **Ink** | Scrivere. Fluidità e ritardo della punta. |
| **Eraser** | Cancellare, in entrambe le modalità. |
| **Lasso** | Selezionare e trascinare. |
| **Shapes** | Tenere fermo a fine tratto. |
| **Input** | Palmo appoggiato, salti del digitizer. |

Il tab attivo si ricorda tra un'apertura e l'altra: si passano sessioni intere
dentro lo stesso.

## Parametri

Default = valore di oggi. Il passo è scelto perché un singolo tap dia una
differenza percepibile senza saltare l'ottimo.

### Ink

| Parametro | Oggi | Range | Passo | Da `canvas.lua` |
| --- | --- | --- | --- | --- |
| `refresh_interval_ms` | 20 | 8–120 | 4 | `REFRESH_INTERVAL_MS` |
| `idle_flush_ms` | 35 | 10–200 | 5 | `IDLE_FLUSH_MS` |
| `reconcile_delay_ms` | 2000 | 200–5000 | 100 | `RECONCILE_DELAY_MS` |
| `jitter_floor_sq` | 4 | 0–64 | 1 | `JITTER_FLOOR_SQ` |
| `live_highlight_tint` | 100 | 0–255 | 10 | `LIVE_HIGHLIGHT_TINT` |

### Eraser

| Parametro | Oggi | Range | Passo | Da |
| --- | --- | --- | --- | --- |
| `eraser_radius` | 12 | 4–80 | 2 | `canvas.lua` `ERASER_RADIUS` |
| `erase_repaint_ms` | 70 | 16–400 | 10 | `canvas.lua` `ERASE_REPAINT_MS` |
| `eraser_mode` | `stroke` | — | toggle | campo del canvas, ripetuto qui per comodità |

### Lasso

| Parametro | Oggi | Range | Passo | Da |
| --- | --- | --- | --- | --- |
| `drag_repaint_ms` | 60 | 16–400 | 10 | `canvas.lua` `DRAG_REPAINT_MS` |
| `lasso_sample_spacing` | 12 | 2–48 | 2 | `lasso.lua` `SAMPLE_SPACING` |
| `frame_margin` | 10 | 0–40 | 2 | `canvas.lua` `FRAME_MARGIN` |

### Shapes

| Parametro | Oggi | Range | Passo | Da |
| --- | --- | --- | --- | --- |
| `hold_travel_sq` | 64 | 4–400 | 4 | `canvas.lua` `HOLD_TRAVEL_SQ` |
| `hold_delay_ms` | 350 | 100–1500 | 50 | letterale `0.35` in `_onPenMove` |
| `rect_angle_tolerance` | 18 | 2–45 | 1 | `shape.lua` `RECT_ANGLE_TOLERANCE` |

`hold_delay_ms` oggi è un `0.35` scritto in mezzo a `_onPenMove`, senza nome e
senza commento: promuoverlo è metà del guadagno di questo lavoro anche a
prescindere dal pannello.

### Input

| Parametro | Oggi | Range | Passo | Da `canvas.lua` |
| --- | --- | --- | --- | --- |
| `palm_grace_ms` | 600 | 0–2000 | 50 | `PALM_GRACE_MS` |
| `max_pen_speed` | 6 | 1–30 | 1 | `MAX_PEN_SPEED` |
| `jump_base` | 48 | 8–300 | 8 | `JUMP_BASE` |
| `max_jump_gap_ms` | 120 | 20–500 | 20 | `MAX_JUMP_GAP_MS` |
| `outlier_limit` | 8 | 1–40 | 1 | `OUTLIER_LIMIT` |

## `tuning.lua`

Un modulo con una tabella di campi, i default sopra, e load/save su
`G_reader_settings` sotto il prefisso `notebook_tuning_`.

I moduli che oggi hanno le costanti locali fanno `local T = require("tuning")` e
leggono `T.refresh_interval_ms` al posto della costante. In `_onPenMove` è una
lookup di hash per campione, contro una blit e una ioctl: irrilevante.

I `local X = 20` in testa a `canvas.lua`, `lasso.lua` e `shape.lua` spariscono, e
i loro commenti — che sono la parte di valore, perché spiegano *perché* quel
numero — si spostano su `tuning.lua`. Il modulo diventa il posto unico dove sta
scritto cosa fa ogni manopola, ed è anche il testo che il dock mostra.

I valori vivono in `settings.reader.lua`, che `make deploy` non tocca: si tara, si
aggiorna il plugin, si ritrovano i propri valori. È la ragione per cui questo non
è un file usa e getta da cancellare a fine taratura.

### Interfaccia

```lua
T.refresh_interval_ms   -- lettura diretta, nei percorsi caldi
T.set(key, value)       -- clamp al range, salva, applica
T.reset(key)            -- torna al default
T.resetAll()
T.spec                  -- {key = {default, min, max, step, tab, doc}} per il dock
```

`T.spec` è una sola dichiarazione da cui il dock si costruisce da sé: aggiungere
una manopola in futuro è aggiungere una riga lì, non toccare la UI.

## Dump

`Dump` scrive i valori correnti — **solo quelli diversi dal default** — nel log di
KOReader, come Lua incollabile:

```
notebook tuning:
  refresh_interval_ms = 28,   -- default 20
  erase_repaint_ms    = 40,   -- default 70
```

È il ponte tra la taratura sul dispositivo e il sorgente. Senza, resta da
ricopiare a mano una quindicina di numeri letti dallo schermo, che è il punto in
cui una sessione di taratura si perde. Il log si legge già con
`tools/restart.sh --log`, quindi non serve nessun canale nuovo.

Conferma a schermo dopo la scrittura, perché il log non è visibile dal
dispositivo.

## Errori

Il dock passa da `Safe.widget`, come ogni altra schermata del plugin: un guasto
qui chiude il taccuino, non KOReader.

`T.set` fa clamp al range invece di fidarsi del chiamante, e il load ignora i
valori salvati che non sono numeri nel range o la cui chiave non è più in `spec`:
un `settings.reader.lua` rimasto da una versione precedente, con chiavi che non
esistono più, non deve poter impedire l'apertura di un taccuino.

## Test

Nel banco di prova esistente (`lua/spec/`), senza dispositivo:

- **`tuning.lua`** — default corretti; `set` clampa sopra e sotto; `reset`
  ripristina; il load scarta chiavi ignote, valori non numerici e fuori range;
  ogni chiave di `spec` ha default dentro il proprio range e un `tab` valido.
- **Equivalenza** — i default di `T` coincidono uno a uno con le costanti che
  sostituiscono. È il test che impedisce a questo lavoro di cambiare di soppiatto
  la sensazione della penna: a cancello chiuso il comportamento dev'essere quello
  di prima, e questo lo dimostra numero per numero.
- **Cancello** — `Notebook` costruito con `title = "_tuning_"` riserva la fascia e
  restringe `content`; con qualunque altro titolo `content` è identico a oggi.
- **Dump** — produce solo le chiavi cambiate, in forma Lua valida (`loadstring`
  del risultato ridà la stessa tabella).

Il dock stesso non si testa a unità: è geometria e tap, e il banco non ha un
pannello. Il render headless alla geometria vera, già usato per le altre
schermate, copre il fatto che a 1860 px non sbordi.

## Cosa questo lavoro non fa

Non aggiusta la gomma né il trascinamento del lazo. Li rende **misurabili**.

Quando si tara, però, vale la pena guardare due punti che nessuna costante può
salvare, perché sono la forma del codice e non un numero:

- `Canvas:_dragStep` ridipinge l'**unione** del rettangolo lasciato e di quello
  occupato (`Rect.grow` di vecchio e nuovo). Per un trascinamento in diagonale
  quell'unione è molto più grande della somma dei due, e cresce con la distanza
  percorsa nel passo. Se alzare `drag_repaint_ms` peggiora invece di migliorare,
  la causa è questa: passi più radi significano rettangoli più grandi.
- La gomma "part of a stroke" ri-rasterizza ogni tratto che tocca l'area. Se
  `erase_repaint_ms` non ha una zona buona, il problema è quanto lavoro fa una
  singola applicazione, non ogni quanto la si fa.

Entrambe sono spec separate, da scrivere quando i dati diranno quale delle due
strade è quella vera.

## Fuori portata

Restano da brainstormare a parte, dopo questa:

- Lag della gomma
- Lag dello spostamento con il lazo
- Tap lungo sulla penna → dimensioni e tipo di punta
- Frecce nel riconoscimento delle forme
