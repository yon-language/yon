# Il lessico, una keyword alla volta — il documento passo-passo

**Data:** 2026-07-25 · **Metodo:** una voce per volta, in chat. Ogni voce ha:
ELI5 → sillogismo aristotelico → esempio pratico → cosa fa OGGI il compilatore
(verificato sul codice vivo, non sull'audit) → le opzioni con le conseguenze →
raccomandazione → **decisione di Antonio** (che è l'unica che conta).

Regola del gioco: la domanda non è mai «teniamo la parola?» ma «**la cosa che la
parola dichiarerebbe, la vogliamo nel linguaggio?**». Se sì, si cabla (la parola
deve avere un consumatore semantico). Se no, si ritira (la parola muore con le
quattro cerchie: corpus, book, ledger, fixture). Accettata-e-ignorata non è
un'opzione: è la peggiore delle tre.

---

## 0. Correzioni allo stato del 23/7 (cose già chiuse da allora)

- ~~prima pietra~~, ~~`new` cade~~, ~~`hit`/`hit_elim` nel kernel~~,
  ~~`refl`/`plainly`/`stay` → `clear`~~ — **FATTI** (nel tree, non committati).
  In più: i prefissi viaggio si incatenano senza parentesi (`back clear 5`),
  la baseline acceptance è a 100 esempi (`kw_clear` incluso).
- La **domanda parcheggiata sulla root del place sintetico** è CHIUSA: la root è
  nominale via Merkle, e due bracci omonimi in unioni diverse dello stesso file
  vengono **rifiutati ad alta voce** in check_decl (niente collasso silenzioso,
  niente risoluzione ambigua). La testa d'identità nel payload fa il resto.
- L'audit del 23 va corretto su due voci (evidenza sotto): `multishot` non è
  inerte fino in fondo, `internal` ha un consumatore reale.

## 1. L'ordine della scala

Prima le **bugie** (indipendenti, chiudono un debito di fiducia), poi i **fork**
(scelte di registro), infine i gradini di sezione già decisi (`pair`/`fst`/`snd`,
destrutturazione, vocabolario negli errori).

1. `multishot` · 2. `lawful` · 3. `invertible` · 4. `unifies` ·
5. `forward`/`backward`/`bi` (rd_direction, include fork I) ·
6. `partial` · 7. `internal` · 8. `import` · 9. `span` (aggancia il fork B)
→ poi fork B (famiglia viaggio), E (cicli), C (plurali), D (converts/aggregates),
F (pullback/pushout), H (logiche), doppioni HoTT (`ind_path`/`induct`,
`comp`/`hcomp`).

---

## 2. Le schede

### 2.1 `multishot` — l'handler richiamabile più volte

- **ELI5.** Quando un'operazione sospende e una `reduction` la gestisce, la
  continuazione («il resto del lavoro») di norma si riprende UNA volta sola
  (one-shot). Multi-shot = il gestore può riprenderla più volte: rieseguire il
  seguito con risposte diverse (retry, backtracking, ricerca non-deterministica).
- **Sillogismo.** *Un multishot è a un handler ciò che un pozzo è a una
  borraccia: attingibile ancora e ancora.*
- **Esempio pratico.** `reduction Retry of Fetch with multishot { ... }`: la
  fetch fallisce, il gestore riprende la continuazione fino a 3 volte. Senza
  multi-shot, la seconda ripresa sarebbe un errore (continuazione consumata).
- **Oggi (verificato 25/7).** NON è inerte come diceva l'audit: `with multishot`
  → `rd_multi_shot` → `C.r_multi_shot` → attributo MLIR `multi_shot = unit`, e
  `mlir/TopOps.cpp` lo USA nel verifier (coerenza con `shot_ordering`; un
  ordering multiplo senza multi_shot è contraddizione rifiutata). Quel `{ () }`
  nell'audit era il `%inline` di menhir, presenza=true — un misreading. **Il
  buco vero, verificato:** sotto il verifier NIENTE consuma `multi_shot` —
  nessun pattern di lowering, e il runtime non ha continuazioni riprendibili
  (le reduction sono fold su stream, non handler a continuazione delimitata).
  È metadata coerentemente verificato ma senza significato operativo: la
  «ripresa multipla» appartiene a un modello di handler che Yon non ha.
- **Opzioni.** (a) CABLA: scrivere i due test comportamentali; se il runtime non
  distingue, implementare la copia di continuazione (lavoro vero). (b) RITIRA:
  muore la parola E l'attributo MLIR e il pezzo di verifier — la semantica degli
  handler resta one-shot per legge. (c) VERIFICA-POI-DECIDI (raccomandata):
  prima i due test, poi la scelta è informata.
- **Decisione di Antonio (25/7): TIENI ENTRAMBI — fold E multishot in superficie.**
  Il multi-shot diventa un PROGETTO DI DESIGN vero (le «timeline»): aprire N
  timeline alla ricerca di un effetto specifico (un edge case, una condizione),
  con sintassi da regolamentare in modo svizzero. Motivi per cui in Yon costa
  meno che altrove: (1) l'heap content-addressed è immutabile con condivisione
  strutturale — fotografare una timeline = copiare handle, non byte; (2) lo
  stato davvero mutabile è confinato (space cells + effetti al bordo); (3) il
  runtime HA già il checkpoint stop-the-world (P8 #88: freeze/snapshot/resume).
  **Interim svizzero (eseguibile subito):** finché il motore non esiste,
  `with multishot` non deve più essere accettato-e-ignorato — errore di
  compilazione ONESTO con codice stabile («dichiarato, ma il motore timeline
  non è ancora cablato»), stessa dottrina dei comandi roadmap del CLI che
  escono 2 onestamente. La parola resta nel lessico e smette di mentire oggi.

### 2.2 `lawful` — la reduction che promette di rispettare le leggi

- **ELI5.** Un flag su una reduction che dichiara «questo handler rispetta le
  law del place». Oggi lo scrivi e nessuno controlla niente.
- **Sillogismo.** *Un lawful non verificato è a una promessa ciò che una firma
  senza contratto è a un accordo: la parola c'è, il vincolo no.*
- **Esempio pratico.** `lawful reduction Sum of Add { ... }` dovrebbe
  significare: il compilatore VERIFICA che il fold del gestore rispetti
  l'associatività dichiarata come `law` sul place.
- **Oggi.** `rd_lawful : bool` esiste in surface_ast; consumatori: SOLO il
  formatter (lo ristampa) e main.ml (test auto-avveranti). Zero semantica.
  Bugia piena.
- **Opzioni.** (a) CABLA: agganciare al meccanismo delle `law` (che è verificato
  davvero) — un lawful senza law nel place bersaglio = errore; con law = obbligo
  di verifica sul fold del gestore. (b) RITIRA: le `law` sul place restano (loro
  funzionano); muore solo l'aggettivo sulla reduction.
- **Decisione di Antonio:** ☐

### 2.3 `invertible` — la reduction che promette l'inverso

- **ELI5.** Dichiarare che il gestore è invertibile (forward∘backward = id).
  Odore di univalenza: se davvero le due direzioni si annullano, quella coppia È
  un'equivalenza, cioè un cammino.
- **Sillogismo.** *Un invertible non verificato è a un'equivalenza ciò che
  «andata e ritorno» detto a voce è a un biglietto: finché nessuno lo controlla,
  non porta da nessuna parte.*
- **Esempio pratico.** `invertible reduction Cd of Encode { ... }`: encode poi
  decode = identità. Cablato sul serio, diventerebbe materiale per `equiv` (le
  due coerenze eta/eps che già sappiamo verificare per eliminazione dipendente).
- **Oggi.** `rd_invertible : bool`; consumatori: formatter + main.ml. Bugia
  piena. Nota: il commento nel sorgente dice già «forward o backward = id
  (univalence)» — l'intenzione era seria.
- **Opzioni.** (a) CABLA verso `equiv`: invertible = obbligo delle due coerenze,
  scaricato con la macchina di Fase 2 (quella di eta/eps è GIÀ in piedi). La più
  bella delle cablature possibili. (b) RITIRA: chi vuole un'equivalenza scrive
  `equiv(f, g, eta, eps)` a mano, come oggi.
- **Decisione di Antonio:** ☐

### 2.4 `unifies` — il verbo di relazione senza relazione

- **ELI5.** Un verbo dichiarativo fra morfismi («X unifies Y») senza alcun
  significato implementato.
- **Sillogismo.** *Un unifies oggi è a due morfismi ciò che un «sono in
  contatto» è a due sconosciuti: non dice né come né perché.*
- **Oggi.** Zero consumatori in desugar/tycheck/emit/reduce (i grep trovano solo
  la parola inglese "unifies" nei commenti). Bugia piena.
- **Opzioni.** (a) CABLA: servirebbe prima UNA semantica candidata (pushout dei
  morfismi? colimite?) — oggi non c'è nemmeno la domanda precisa. (b) RITIRA
  (raccomandata): quando la semantica esisterà, la parola si ridichiara con un
  brief vero.
- **Decisione di Antonio:** ☐

### 2.5 `forward` / `backward` / `bi` — la direzione dichiarata e ignorata

- **ELI5.** La direzione di una reduction. Parsata, stampata dal formatter,
  ignorata da tutto il resto. `bi` in particolare (fork I): cosa marcherebbe?
- **Sillogismo.** *Una direzione non consumata è a un morfismo ciò che la
  freccia disegnata sull'asfalto è a una strada chiusa: indica, ma non porta.*
- **Oggi.** `rd_direction` con `RdForward|RdBackward|RdBi`; consumatori:
  formatter + main.ml. Bugia piena.
- **Legame.** Se 2.3 si cabla verso equiv, `bi` ha un candidato naturale (la
  coppia f⊣g dichiarata insieme); se 2.3 si ritira, anche la direzione perde il
  suo unico aggancio plausibile.
- **Decisione di Antonio:** ☐

### 2.6 `partial` — la funzione che ammette di non rispondere sempre

- **ELI5.** Marca una fun come parziale (può non terminare / non essere definita
  ovunque). Il tipo `fs_partial` esiste, l'uso nel corpus è un solo file di
  copertura.
- **Sillogismo.** *Una partial è a una funzione ciò che «salvo imprevisti» è a
  una promessa: onesta sul proprio limite.*
- **Oggi.** Campo presente nelle firme; da verificare al momento della decisione
  se il checker lo consuma (es. escluderla dai delta di uguaglianza
  definizionale — dove la totalità CONTA, perché i delta certificati via SCT
  presuppongono terminazione).
- **Opzioni.** (a) CABLA: `partial` = mai delta-rule, mai unfolding nel
  giudizio di uguaglianza (aggancio giusto e a portata: la certificazione SCT
  c'è già). (b) RITIRA: SCT già decide da solo chi è certificabile — la parola
  sarebbe ridondante rispetto a un'analisi che funziona.
- **Decisione di Antonio:** ☐

### 2.7 `internal` — il confine di modulo che c'è

- **ELI5.** `internal fun` = non esportata fuori dallo Space.
- **Sillogismo.** *Un internal è a uno Space ciò che la cucina è a un
  ristorante: indispensabile dentro, invisibile ai clienti.*
- **Oggi.** NON è bugia: `internal_funs` esiste in desugar con semantica
  «not exported cross-Space». Il problema è l'altro: **zero uso reale nel
  corpus** (un solo micro-esempio). Manca il caso vero, non il consumatore.
- **Opzioni.** (a) TIENI + un esempio vero cross-space che mostri il rifiuto
  dell'accesso esterno (e un gate negativo). (b) RITIRA solo se si decide che
  il confine di Space basta da sé (tutto ciò che non è wire è già invisibile —
  domanda: `internal` aggiunge qualcosa al modello, o duplica il muro?).
- **Decisione di Antonio:** ☐

### 2.8 `import` — la porta del modulo

- **ELI5.** Porta simboli/Space dentro il file. Risolto FISICAMENTE pre-parse
  (il file viene incluso), quindi un consumatore c'è.
- **Sillogismo.** *Un import è a un modulo ciò che una porta è a una stanza: fa
  entrare ciò che serve.*
- **Oggi.** 3 file di copertura, uso organico scarso; il grosso del cross-Space
  passa da `yon_modules`/toml. Domanda vera: nel modello «Space = filesystem +
  toml», il confine di modulo DENTRO lo Space serve, o è un residuo?
- **Decisione di Antonio:** ☐

### 2.9 `span` — l'univalenza in abito da viaggio

- **ELI5.** `span e` = `ua(e)`: da un'equivalenza, il cammino fra tipi.
- **Sillogismo.** *Uno span è a due tipi ciò che un ponte è a due rive: se c'è,
  si passa.*
- **Oggi.** Vivo in grammatica, un solo esercitatore, zero uso organico (il
  corpus scrive `ua(...)` o `carry ... along ...`). La sorte è legata al fork B:
  se il registro viaggio vince, `span` va fatto PARLARE nel corpus; se vince il
  registro tecnico, muore con la famiglia.
- **Decisione di Antonio:** ☐ (si decide DENTRO il fork B)

---

## 3. I fork (dopo le bugie)

Schede da scrivere una alla volta quando ci arriviamo, con lo stesso formato:
**B** famiglia viaggio (`back`/`span`/`through`/`carry along` — quale registro
vince; nota: `clear` è già entrato E si incatena senza parentesi, quindi il
registro metonimico ha già una vittoria in casa) · **E** cicli
(`repeat`/`times`/`iter`/`most` → una superficie) · **C** plurali
(`morphism/s`, `map/s`) · **D** `converts`/`aggregates` · **F**
`pullback`/`pushout` (l'ultima `place X = …`) · **H** logiche
(classica vs Heyting: quale famiglia è canonica) · doppioni HoTT
(`ind_path`/`induct`, `comp`/`hcomp` — demozione a kernel come `refl`?).

## 4. Ledger delle decisioni

| voce | decisione | data | eseguita |
|---|---|---|---|
| `multishot` | TIENI (fold + multishot); cabla come progetto «timeline»; per brief: lasciata ESATTAMENTE com'è finché il cantiere non apre | 2026-07-25 | intatta ✓ |
| `lawful` | RITIRA (brief sfoltimento) — l'obbligo discenderà dall'algebra | 2026-07-25 | ✓ |
| `invertible` | RITIRA — si riaggiunge quando l'univalenza sarà in superficie | 2026-07-25 | ✓ |
| `forward`/`backward`/`bi` | RITIRA (campo rd_direction+tipo morti); chiude il fork I | 2026-07-25 | ✓ |
| `partial` | RITIRA — torna con la stdlib se serve | 2026-07-25 | ✓ |
| `unifies` | STOP: il censimento del brief era errato — è la testata del merge move (MoveMerge, exit 22). Serve un brief a parte se il move deve restare a sorgente singola | 2026-07-25 | non toccata |

## 4-ante. LA PIETRA delle frecce (Antonio, 2026-07-26 — invalicabile)

**Le dieci specie di freccia** — `fun`, `operation`, `morph`, `view`, `move`,
`functor`, `geomorph`, `nat transform`, `reduction`, `compose` — obbediscono a
due leggi:

1. **`on error E` è dicibile su tutte**, nell'ordine uniforme
   `<testata> on error E : <codominio>` (il `:` dopo E disambigua ovunque;
   il codominio diventa obbligatorio con la clausola). Il tipo è sempre il
   coprodotto `T + E`; l'eliminatore è il match col testimone (`E as e =>`).
   NOTA APERTA `compose`: è un'ESPRESSIONE — se f: A→B+E1 e g: B→C+E2, la
   composizione vive nel Kleisli di (+E) e la propagazione va DISEGNATA
   (brief a sé), non improvvisata nella grammatica.
2. **Tutte e dieci si dichiarano DENTRO le graffe di un place.** Nessuna
   freccia top-level: il sollevamento (`push_decl`) esiste già, la regola è
   disciplina di superficie + un check E4xxx. Migrazione: 1097 dichiarazioni
   in 301 file + i programmi Yon0 del differenziale diventano place-bodied
   (lo stage-1 impara il corpo del place) — miglio a sé, brief prima di ogni
   riga.

### Il naming qualificato — LA CASA DÀ IL NOME (Antonio, 2026-07-26)

Regola unica: **nome qualificato = casa + nome**, e la casa viene o dal
CONTENITORE (`fun` dentro `place Number` → `Number.abs`) o dalla CLAUSOLA
(`view Snapshot of Account` → `Account.Snapshot`; idem of/from per
morph/reduction/move/functor/geomorph/nat). Niente due meccanismi.

- `fun` è l'UNICA freccia senza sorgente sintattica (niente of/from) — per
  questo è lei a volere il contenitore: il place in cui è scritta è la sua
  casa dichiarata.
- Le forme con of/from sono legittime top-level PER COSTRUZIONE: la clausola
  è la casa; chiedere il place attorno = dichiarare la casa due volte. I
  file-modulo puro-freccia (w/Snapshot.yon) sono la forma GIUSTA — fuori
  dalle classi di migrazione.
- Nudo ammesso dentro il place che dichiara (stessa regola dei punti nudi).
- Math/String smettono di essere namespace magici di emit e diventano le
  facce di Number/Text (i loro 28+ nomi diventano Number.abs, Text.concat…).
- OGGI push_decl solleva col nome NUDO: il preludio popolato inquinerebbe i
  nomi globali → **la classe 7 (enforcement) NON si fa prima del naming
  qualificato**. Enforcement mirato: solo `fun` (e forme senza sorgente).
- Caso limite scritto per dopo: `main` = 1 → Number, casa Entry, ma resta
  nome speciale non qualificato (è il punto d'ingresso).
- Domanda aperta collegata: fun vs operation ora che abitano lo stesso posto
  — la distinzione resta effetti-sì/no.

## 4bis. Regola architetturale (dal cantiere preludio, terza occorrenza)

**Nessuna tabella keyed per nome senza il sito.** Tre morsi della stessa
famiglia in tre cantieri: la testa d'identità (byte uguali fondevano place
diversi), la root del braccio sintetico (omonimi cross-unione), i punti fusi
(il `tt` del Bool utente dirottato sul letterale del preludio). Ogni volta che
qualcosa è indicizzato per nome nudo, due cose distinte collassano. **Il quarto
caso è TROVATO (review di Antonio, cantiere errore): `sum_ctor_registry` è
globale nome→(tag,tys) con replace — bracci omonimi in somme diverse si
sovrascrivono.** Per le somme d'errore il builder condiviso stabilizza le
posizioni; una somma utente che riordina un nome condiviso romperebbe. Fix:
chiave (type_tag della somma, braccio). Debito aperto, pre-esistente.

### Lezioni di strumento (incidenti, stessa famiglia)

- **Sweep testuali**: mai `\s` multiriga nei pattern contestuali; audit
  file-level per normalizzazione come gate standard.
- **Fix-loop automatici**: tetto di iterazioni + guard che verifica
  L'EFFETTO, non la posizione (l'incidente parser.mly: inseriva prima di
  `fn_visits`, controllava dopo — lo strumento non verificava di aver fatto
  la cosa che credeva).

### I due cammini verso Constant (regola f)

1. **fusione ⇒ Constant** (`is <prim>`): il primitivo esiste in ogni world.
2. **preludio ⇒ Constant per posizione**: `prelude/` è fuori da ogni space
   ⇒ nessun world ⇒ Constant — la regola esistente applicata al caso
   «nessuno space», non una regola nuova. VINCOLO di sicurezza: prelude/
   viaggia col compilatore e NON è scrivibile dall'utente (niente fallback
   sulla cwd del progetto, solo $YON_PRELUDE ed exe-relative).

## 5. Riservati (da NON toccare, invariati)

Costruttore di cammino (grammatica sì, semantica dopo il path-over kernel);
`.->` faccia esplicita della mediatrice (`1 .-> P` riservata agli stadi);
`topology` dichiarata-non-cablata (la sheafification è il debito #1).
La superficie cubicale end-to-end (`ua`/`Glue`/`transport`/`Path`) resta il
debito #2: progettazione, non pulizia.
Il **motore timeline** (multi-shot: N timeline alla ricerca di un effetto,
snapshot a costo-handle sull'heap content-addressed, seme = checkpoint P8 #88)
è il debito #3 — brief da scrivere con Antonio prima di ogni riga.
