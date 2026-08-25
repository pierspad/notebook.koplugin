# Notebook — taccuini a mano libera per KOReader

Note di progetto: perché il plugin è fatto così. Per installarlo e usarlo, il
[README](../README.md).

## Stato

In uso sul Kindle Scribe: disegno, evidenziatore, gomma, undo/redo, pagine
multiple, salvataggio, galleria, export PDF.

Quello che si vede solo sul dispositivo — e che l'emulatore non può mostrare,
perché non ha né pannello E-Ink né digitizer — è stato anche la fonte dei bug
peggiori: il palmo appoggiato che arriva nello slot della penna, la latenza
reale delle forme d'onda, e schermate che stanno comode a 540 px e sbordano a
1860. Da qui gli strumenti in fondo a questo file: renderizzare alla geometria
vera, e far girare il vero ciclo di eventi, invece di fidarsi dell'emulatore.

## Dove sono le cose

```
lua/            il plugin -- è questa cartella che viene impacchettata come
                notebook.koplugin e installata sul dispositivo
lua/spec/       il banco di prova, che non viene impacchettato
tools/          deploy sul dispositivo e riavvio di KOReader
docs/           questo file
Makefile        test, lint, pacchetto, deploy
```

Il nome della cartella **è** il nome del plugin: KOReader ricava l'identità di
un plugin da come si chiama la directory (`pluginloader.lua`), e sovrascrive con
quello il campo `name` dichiarato in `main.lua`. Per questo il pacchetto si
chiama `notebook.koplugin` e non altrimenti, e per questo rinominare la cartella
è un cambio che si porta dietro impostazioni, cartella dei dati e tab di Simple
UI — vedi `lua/spec/migration.lua`, che è dove quella compatibilità è fissata.

Serve anche l'emulatore di KOReader, ma **solo** per il render headless in fondo
a questo file; i test non ne hanno bisogno. Se ce l'hai, sta fuori da questo
repo: non è nostro codice, ed è fatto di symlink verso i propri artefatti di
build.

## Installazione

```bash
make deploy TARGET=/percorso/kindle/montato
```

oppure via SSH:

```bash
make deploy TARGET=root@192.168.1.42 FLAGS=--restart
```

Lo script esegue i test prima di copiare e si rifiuta di installare se
falliscono. Prova la porta 2222 (server SSH di KOReader) e poi la 22
(USBNetwork), con un connect TCP da tre secondi ciascuna: un dispositivo
addormentato o un indirizzo sbagliato danno un errore subito invece di restare
appesi.

Se KOReader si pianta, **non serve riavviare il Kindle**:

```bash
tools/restart.sh root@192.168.1.42          # rilancia KOReader
tools/restart.sh root@192.168.1.42 --log    # e prima mostra il log degli errori
```

Il server SSH di KOReader è dropbear, un processo a sé: continua a rispondere
anche mentre il ciclo Lua è bloccato. Vale la pena tenerlo acceso proprio per
questo — da un dispositivo già piantato non lo si può più avviare.

Scrive **una sola cartella**: `koreader/plugins/notebook.koplugin`. Non tocca
libri, impostazioni o KOReader stesso. Per disinstallare basta cancellarla.

Nel dispositivo: `Menu → Strumenti (chiave inglese) → pagina 2 → More tools → Notebook`.

## Come è fatto

### Niente patch, niente reverse engineering

KOReader espone già un'API per la penna (`Input:registerStylusCallback`, in
`frontend/device/input.lua`), aggiunta a monte. Fornisce eventi già elaborati
con il tipo di strumento — punta, gommino, evidenziatore — e permette di
"dominare" l'evento perché non diventi anche uno swipe. Il digitizer Wacom viene
già aperto all'avvio dal codice Kindle. Il plugin è quindi puramente additivo.

### Modello dati

Vettoriale, unica fonte di verità. I tratti sono liste di punti in array piatti
(stride 3: x, y, pressione). La bitmap è solo cache di rendering, mai salvata.

La cronologia è un **log di operazioni**, non uno stack di stati: `add` per un
tratto, `erase` per una rimozione multipla. Un futuro strumento di selezione
(sposta, ridimensiona) si aggancia allo stesso sistema senza rifarlo.

### Latenza

Mentre il tratto è in corso si **bypassa UIManager** e si dipinge direttamente
nel buffer dello schermo, chiedendo poi un refresh parziale del solo rettangolo
sporcato. Passare da UIManager significherebbe un ciclo di ridisegno dell'intero
stack di widget per ogni frammento di tratto.

È sicuro perché `paintTo` resta il renderer autorevole e ridisegna dal modello
vettoriale: qualsiasi ripittura ripristina l'immagine corretta, quindi il
percorso veloce non può lasciare lo schermo permanentemente sbagliato.

I refresh sono limitati a uno ogni ~24 ms invece di uno per evento: il digitizer
riporta punti molto più in fretta di quanto il pannello aggiorni, e una ioctl per
punto accumula un arretrato che si vede come inchiostro sempre più in ritardo
rispetto alla punta.

A fine tratto si ridisegna l'area in scala di grigi, perché A2 è a 1 bit e
lascia l'inchiostro duro e con ghosting.

### Evidenziatore

Scurisce **fino a** una tinta, mai oltre: la carta bianca ci arriva, e
l'inchiostro che è già più scuro resta com'è. Il minimo è idempotente, quindi non serve
alcuna maschera di copertura — le impronte lungo un tratto possono sovrapporsi
quanto vogliono, e una seconda passata sulle stesse parole non le annerisce.
(Prima moltiplicava, che non è idempotente: da lì la maschera, e da lì i tratti
che degeneravano in nero quando la maschera non bastava.)

Mentre il tratto è in corso però la tinta usata è **più scura** di quella finale.
L'idempotenza è giusta per il risultato e inutile mentre lavori: ripassare
sull'evidenziato non mostrava assolutamente nulla sotto la punta, quindi non si
vedeva dove stava passando il pennarello né dove doveva ancora andare. Al
sollevamento l'area viene ridisegnata dal modello alla tinta vera, così la banda
finale è piatta come tutte le altre.

### Non portarsi dietro il dispositivo

Un plugin gira dentro l'unico ciclo di eventi di KOReader, e ci sono due modi
per fermarlo del tutto. Entrambi lasciano un Kindle che non risponde a niente —
né tocco, né tasti, né ridisegno — e l'unica uscita è tenere premuto il tasto di
accensione. Per un taccuino è un esito inaccettabile qualunque sia il bug
dietro: il peggio che questo plugin deve poter fare è chiudersi da solo.

**Un errore lanciato dove il ciclo ci chiama.** Handler, `paintTo` e callback
schedulate sono invocate da UIManager, e la callback della penna da ancora più
in basso, dentro il polling dell'input. Niente di tutto ciò è protetto: un `nil`
indicizzato un livello sotto arriva fino in fondo e si porta via KOReader.

**Un'unità di lavoro che non restituisce il ciclo.** `handleInput` è

```lua
repeat
    _checkTasks()
    _repaint()
until not _task_queue_dirty
```

e l'input viene letto **dopo**. Una catena di task `nextTick` che si riarma da
sola, o un loop Lua che non finisce, significa che l'input non viene più letto.

`safe.lua` risponde a entrambi:

- `Safe.widget` mette un pcall sui tre punti da cui il ciclo entra in una
  schermata (`handleEvent`, `paintTo`, `init`) — e `handleEvent` copre anche i
  bottoni dentro l'albero, perché il container smista da lì.
- `Safe.later` è l'unico modo consentito di chiedere di essere richiamati:
  schedula un istante avanti, mai adesso, così il ciclo si chiude e l'input
  viene letto. Un test controlla che in tutto il plugin non resti un
  `UIManager:nextTick`.
- `Safe.watched` mette un tetto in istruzioni VM agli handler: un loop infinito
  diventa un traceback che lo nomina invece di un dispositivo morto.
- In caso di guasto: la callback della penna viene restituita per prima, le
  nostre schermate vengono chiuse, l'errore finisce in
  `koreader/notebook/notebook-error.log` e compare un avviso. KOReader continua.

**Attenzione a LuaJIT**: un count hook non viene controllato dentro un trace
compilato, e un loop stretto è la prima cosa che LuaJIT compila — quindi
`debug.sethook` da solo *non* interrompe un loop infinito, e fallisce in
silenzio. Serve `jit.off()` per la durata della chiamata protetta. È il motivo
per cui il watchdog sta solo sugli handler: sulla penna e sul ridisegno il costo
di girare interpretati non sarebbe accettabile.

### Mandare un taccuino al telefono (LocalSend, opzionale)

Scribe non implementa LocalSend e non lo distribuisce. Esiste già un plugin che
lo fa per davvero — [localsend.koplugin](https://github.com/kaikozlov/localsend.koplugin),
backend in Go, invia **e riceve**, discovery multicast come le app del telefono,
HTTPS e PIN — e installarlo è affare di chi lo vuole: si scarica lo zip della
release per la propria architettura (`armv7` per il Kindle) e si scompatta in
`koreader/plugins/`.

Se c'è, tenendo premuto su un taccuino nella galleria compare **Invia**: il
taccuino viene reso in PDF nella cartella `cache` e passato al flusso di invio
di LocalSend, che si occupa di trovare il dispositivo e mandarcelo. Un PDF già
esportato parte così com'è, senza essere reso di nuovo.

Se non c'è, il pulsante non esiste e non cambia nient'altro. Il legame è
volutamente lasco: `share.lua` non fa `require` di niente — un require di un
plugin non installato è un errore fatale al caricamento — ma cerca l'istanza
del plugin registrata sulla UI, e se non la trova dice che non si può inviare.
Scribe resta autonomo, e chi vuole solo LocalSend per spostare i suoi libri se
lo installa senza sapere che Scribe esiste.

## Limiti noti

- **Nessuna pressione variabile.** Il digitizer riporta `ABS_PRESSURE`, ma
  KOReader lo consuma solo come segnale di contatto e non lo porta nei dati dello
  slot (vengono impostati solo `id`, `tool`, `x`, `y`). Il renderer è già pronto:
  serve una patch a monte per rendere disponibile il valore.
- **Nessuno strumento di selezione** ancora — il modello dati lo permette.
- **Solo taccuino bianco**: l'annotazione ancorata alle pagine di un documento
  non c'è. Le coordinate sono già tenute in spazio pagina proprio in vista di
  quello.

## Sviluppo

### Test della logica

```bash
make test
```

190 test sulla logica indipendente dal dispositivo, in un secondo e senza
emulatore. `make deploy` li esegue da solo e si rifiuta di installare se
falliscono; il gancio `pre-push` li esegue prima che qualcosa esca dalla
macchina.

| suite | cosa copre |
|---|---|
| `run` | geometria dei tratti, undo, rettangolo di refresh, evidenziatore, export |
| `pages` | pagine, sfondi, persistenza |
| `eraser` | gomma: cosa toglie, cosa ridisegna, cosa ricorda per l'undo |
| `palm` | penna contro mano appoggiata, e l'evidenziatore che si vede mentre passa |
| `i18n` | catalogo di traduzione allineato ai sorgenti |
| `gallery` | layout, ridisegno, memoria, selezione delle schermate |
| `safe` | un errore non esce dal ciclo, un loop infinito viene interrotto |
| `shape` | riconoscimento delle forme tenendo premuto, e lo snap agli assi |
| `lasso` | selezione, spostamento e trasformazioni di ciò che è stato preso |
| `migration` | un'installazione che viene da `scribe.koplugin`: dove sono i taccuini, come si chiamano le impostazioni, quale tab della barra è il nostro |

Gli stub del layer widget (`spec/uistubs.lua`) hanno la dimensione **e la
densità vere dello Scribe**. Non è un dettaglio: KOReader scala ogni padding,
bordo e font per la densità del pannello, e con gli stub che restituivano
i numeri non scalati i pannelli entravano comodamente in uno schermo da cui
nella realtà sbordavano.

Bug reali trovati così, dai log o dal render, che vale la pena ricordare:

- l'evidenziatore che anneriva a ogni sovrapposizione;
- la gomma che confrontava la distanza dai **punti** registrati anziché dai
  **segmenti**, quindi passava nei buchi tra vertici distanti — e più veloce
  scrivi, più i punti sono radi;
- la callback stylus che **dominava ogni evento della penna**, ovunque cadesse:
  i tocchi non arrivavano mai ai bottoni della barra, che quindi rispondevano al
  dito ma non alla penna;
- la barra che sbordava di 268 px alla risoluzione dello Scribe, spingendo il
  tasto Chiudi fuori dallo schermo;
- il ridisegno in scala di grigi eseguito a **ogni** sollevamento della penna:
  rirasterizzava l'intera pagina dal modello vettoriale proprio mentre la penna
  tornava giù, e peggiorava man mano che la pagina si riempiva;
- un `VerticalGroup` a cui veniva aggiunto un figlio **dopo** averlo misurato:
  si misura una volta sola e si ricorda dove va ognuno, quindi disegnando finiva
  fuori da quella lista e la schermata non compariva affatto. Lo stub adesso lo
  modella com'è, invece di ricalcolare le dimensioni a ogni richiesta — che è la
  versione comoda, e nascondeva esattamente questo errore.

### Render headless

Disegna i widget veri in un PNG, **alla risoluzione e alla densità dello
Scribe**, senza finestra e senza input. Prima si copia il plugin nell'albero
dell'emulatore:

```bash
cd ../koreader-src/koreader-emulator-*/koreader
rm -rf plugins/notebook.koplugin
cp -r ../../../notebook.koplugin/lua plugins/notebook.koplugin

export SDL_VIDEODRIVER=dummy
export EMULATE_READER_W=1860 EMULATE_READER_H=2480 EMULATE_READER_DPI=300

./luajit plugins/notebook.koplugin/spec/render.lua  /tmp/nb.png   # il taccuino
./luajit plugins/notebook.koplugin/spec/screens.lua /tmp          # tutte le schermate
./luajit plugins/notebook.koplugin/spec/exercise.lua              # i percorsi veri
rm -rf notebook/.thumbs && \
  ./luajit plugins/notebook.koplugin/spec/loop.lua                # il ciclo di eventi
```

`EMULATE_READER_DPI=300` non è opzionale: senza, l'emulatore scala per 160 dpi,
tutto viene proporzionalmente più piccolo dello schermo e un layout che sborda
sul dispositivo qui entra comodo. È il motivo per cui questi bug erano sfuggiti.

- **`render.lua`** disegna il taccuino e segnala se la barra sborda.
- **`screens.lua`** costruisce *ogni* schermata, stampa dove finisce ciascuna e
  torna un codice di errore se qualcosa esce dallo schermo o va sotto la
  tastiera. Con `LANGUAGE=it` davanti controlla la traduzione: le etichette
  italiane sono più lunghe, ed è proprio quello che spinge una riga oltre il
  bordo.
- **`loop.lua`** fa girare il vero ciclo di KOReader attorno a ogni schermata e
  conta quanti giri fa prima di tornare a leggere l'input. Prima era 8 per
  aprire la galleria — otto anteprime rasterizzate con il touch morto; ora è 1.
- **`exercise.lua`** guida la canvas come farebbe una mano — disegna, evidenzia,
  cancella in entrambi i modi, undo, redo, salva, ricarica, esporta — contro il
  framework vero, dove un argomento sbagliato a una chiamata del blitbuffer è un
  errore invece che un test che passa in silenzio.

Serve perché l'emulatore gira in una finestra piccola: un layout che ci sta a
540 px può sbordare a 1860, e i controlli che finiscono fuori diventano
intoccabili **senza alcun segno visibile**. È esattamente il bug che ha reso
inutilizzabile il tasto Chiudi, e questo strumento l'ha trovato in un colpo. Poi
è successo di nuovo, in due punti che i test non guardavano: la riga di bottoni
della galleria che usciva a destra, e il pannello del nuovo taccuino che finiva
sotto la tastiera portandosi via Annulla e Crea — una schermata da cui non si
poteva più uscire.

(Nota: pilotare la finestra dell'emulatore con input sintetico non funziona su
Wayland — SDL non riceve gli eventi. Da qui la scelta di renderizzare invece di
cliccare.)

Per l'emulatore interattivo: `cd ../koreader-src && ./kodev run`.
