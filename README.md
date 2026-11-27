# FitClaude

App per iPad che trasforma il tapis roulant in una passeggiata tra le calli e i canali di Venezia,
con Claude come compagno di allenamento a voce.

- **Scena 3D in soggettiva** sulla TV: calli strette, fondamenta lungo i canali, ponti ad arco
  (la camera sale e scende), campi con pozzo e campanile, gondole, pali da ormeggio, panni stesi
  e i "nizioleti" con i nomi delle calli.
- **Claude a voce** negli AirPods, in italiano: commenta l'allenamento, risponde alle domande,
  può cambiare velocità e pendenza (con conferma) e appendere insegne lungo il percorso.
- **Il fanale di Claude**: una luce che cammina davanti a te nella scena e cambia colore
  (verde = ti ascolta, arancione = pensa, blu = parla).
- **Gesti** con la fotocamera frontale dell'iPad.
- **Tapis**: simulatore per provare subito, oppure il Toorx via Bluetooth (FTMS) con il modulo
  TRX APP GATE 3.0.

## Installazione (sul Mac)

1. Installa **Xcode** dall'App Store (versione 16 o successiva).
2. Installa **XcodeGen**, che genera il progetto Xcode da `project.yml`:
   ```
   brew install xcodegen
   ```
   (se non hai Homebrew: https://brew.sh)
3. Scarica il codice e genera il progetto:
   ```
   git clone https://github.com/effepitt/fitclaude.git
   cd fitclaude
   xcodegen
   open FitClaude.xcodeproj
   ```
4. In Xcode seleziona il target **FitClaude** → **Signing & Capabilities** → **Team**: scegli il
   tuo Apple ID. Con un account gratuito l'app va reinstallata ogni 7 giorni; con l'Apple Developer
   Program (99 €/anno) no.
5. Collega l'iPad al Mac con il cavo. Sull'iPad attiva **Impostazioni → Privacy e sicurezza →
   Modalità sviluppatore** (serve un riavvio).
6. In Xcode scegli l'iPad come destinazione e premi **Run** (▶).
7. Al primo avvio l'iPad chiede i permessi per microfono, riconoscimento vocale, fotocamera e
   Bluetooth: concedili tutti.

## Primo avvio

1. **Impostazioni** (ingranaggio in basso a destra) → incolla la **chiave API** di Claude
   (da https://console.anthropic.com). Resta salvata nel Portachiavi dell'iPad.
2. Scegli il modello. Opus 5.5 è il più capace; Haiku 5.5 risponde più in fretta e costa meno.
3. Lascia la sorgente su **Simulatore** finché non hai il modulo Bluetooth: con i pulsanti
   Avvia, Velocità + e − puoi provare scena, voce e gesti.

## Collegare la TV

- **Cavo USB-C → HDMI** (consigliato): nessun ritardo.
- **AirPlay**: Centro di Controllo → Duplica schermo → la tua TV.

In entrambi i casi l'app mostra sulla TV la scena a schermo intero con i dati, mentre sull'iPad
restano comandi e conversazione.

**Importante:** disattiva **Stage Manager** (Impostazioni → Multitasking e gesti). Con Stage
Manager attivo l'iPad usa la TV come secondo desktop e la scena dedicata non compare.

## Posizione dell'iPad

In **orizzontale** sul supporto della console, con il **campo largo** della fotocamera
(l'app lo attiva da sola, disattivando Center Stage). Un piccolo spessore dietro il bordo
superiore inclina l'iPad in avanti e toglie il soffitto dall'inquadratura. Fissalo con un
elastico o un velcro: in orizzontale sporge dal supporto.

Nelle Impostazioni, sezione Gesti, c'è l'anteprima della fotocamera per sistemarlo.

## Voce

- **Parla** (pulsante verde) oppure **mano alzata**: Claude ti ascolta; la frase finisce dopo
  un secondo di silenzio.
- **Ascolto continuo** (Impostazioni): Claude ti riascolta da solo dopo ogni risposta.
- Comandi immediati, senza attendere Claude:
  - "**stop**", "**basta**", "**fermati**", "**rallenta**" → rallenta subito al passo (3 km/h);
  - "**sì**" / "**no**" → conferma o annulla un aumento in attesa;
  - "**sinistra**" / "**destra**" a un bivio → canali o calli.

## Gesti

Sempre con una mano sola, tenuti circa mezzo secondo:

| Gesto | Effetto |
|---|---|
| Mano alzata accanto alla spalla | Claude ti ascolta |
| Pollice su | Conferma l'aumento di velocità/pendenza |
| Pollice giù | Annulla, oppure interrompe Claude mentre parla |
| Palmo aperto verso l'iPad, all'altezza del petto | Rallenta al passo e azzera la pendenza |
| Braccio aperto a destra | +0,5 km/h (da confermare), oppure "calli" a un bivio |
| Braccio aperto a sinistra | −0,5 km/h, oppure "canali" a un bivio |

Sopra la velocità impostata (default 9 km/h) i gesti si fermano, tranne il palmo: usa la voce.
Se destra e sinistra risultano invertite, attiva "Inverti destra e sinistra" nelle Impostazioni.

## Sicurezza

- Velocità e pendenza non superano mai i massimi delle Impostazioni (default 12 km/h e 10%).
- Le diminuzioni sono immediate; ogni aumento chiesto da Claude o dai gesti va confermato ed è
  limitato a +2 km/h e +3% per volta.
- Se dici di avere dolore o malessere, Claude rallenta e ti suggerisce di fermarti.
- **La chiave magnetica del tapis resta lo stop d'emergenza.** Tienila sempre agganciata.

## Tapis Bluetooth (dopo aver installato il TRX APP GATE 3.0)

1. Impostazioni → Tapis roulant → **Tapis Bluetooth**.
2. Se il tapis annuncia il profilo FTMS, l'app si collega da sola; altrimenti tocca il suo nome
   nell'elenco.
3. Apri **Registro Bluetooth**: elenca servizi e caratteristiche trovati e dice se il tapis
   accetta comandi. Condividilo con Claude (pulsante in alto a destra): se il Toorx usa un
   protocollo diverso da FTMS, da lì si adatta il codice.

Chiudi Kinomap, iConsole+ e Zwift prima di collegarti: il tapis accetta un solo collegamento.

## Struttura del codice

| Cartella | Contenuto |
|---|---|
| `App/` | Avvio dell'app e scena per lo schermo esterno (TV) |
| `Model/` | `AppModel` che collega tutto, impostazioni |
| `Treadmill/` | Simulatore, Bluetooth FTMS, regole di sicurezza |
| `Voice/` | Riconoscimento vocale e sintesi in italiano |
| `Claude/` | Messages API, conversazione e strumenti |
| `Scene/` | Venezia in SceneKit, texture e nizioleti generati via codice |
| `Gestures/` | Fotocamera frontale + Vision |
| `Views/` | Schermate iPad e TV |

## Stato

Prima versione (0.1). Il codice è stato scritto senza poterlo compilare: alla prima
compilazione in Xcode potrebbero comparire piccoli errori. Copia il messaggio di errore e
mandalo a Claude, che lo correggerà.
