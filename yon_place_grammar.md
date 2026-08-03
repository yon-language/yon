# Yon — la grammatica del `place` nella forma-frecce

**Stato:** progetto deciso, esecuzione in corso.
**Base di verifica:** commit `a6f4e0a` (origin) + stadi 0-2 locali.
**Convenzione di stato** su ogni forma:

- **✓ vivo** — si scrive già oggi, verificato sul corpus
- **◐ stadio N** — deciso, non ancora scrivibile; lo stadio che lo accende
- **○ aperto** — decisione ancora da prendere (fork)

---

## 1. Il principio

Un `place` è un oggetto: un presheaf `Site → Type`. La sua identità è il suo
profilo di osservazione (Yoneda), non il suo layout — il layout è il **carrier**,
un funtore derivato, e non si dichiara.

Da qui la forma: **un place si dichiara elencando le sue frecce, con la
direzione marcata.**

| direzione | cosa fa | forma |
|---|---|---|
| **in entrata** | genera (colimite, algebra iniziale) | `this > A :U B` |
| **in uscita** | osserva (limite, proiezione) | `nome tipo` |
| **in uscita mediata** | opera con effetti | `operation f(...): T` |
| **canonica** | slice, mono, errore | `over`, `subcontains`, `on error` |

Record e coprodotto **non sono due nature**: sono lo stesso costrutto con
l'insieme dei generatori rispettivamente vuoto o pieno. Un place senza `this >`
è un record; con `this >` è un'unione; con entrambi è un sum-of-products.

**Dentro il place** ciò che l'oggetto espone di sé — ed entra nella sua Merkle
root, quindi nella sua identità. **Fuori dal place** le frecce *fra* place
(`fun`, `move`, `view`, `morph`, `functor`, `geomorph`): aggiungerne una non
deve cambiare *chi è* l'oggetto, altrimenti ogni sezione esistente cambierebbe
tipo.

---

## 2. Dichiarazione di place — forma completa

```ebnf
place_decl ::=
    "place" IDENT modifier* "{" member* "}"

modifier ::=
    "over" IDENT                    (* categoria slice C/X *)
  | "subcontains" IDENT             (* mono: sottooggetto *)
  | "on" "error" IDENT              (* morfismo d'errore *)
  | "with" "effects"                (* ◐ ritirato allo stadio 5 se fork 3 = inline *)

member ::=
    arm_clause                      (* frecce in entrata *)
  | field                           (* frecce in uscita *)
  | cell                            (* osservazione mutabile *)
  | operation                       (* freccia mediata *)
  | law                             (* obbligo algebrico *)
  | clause_member                   (* ◐ stadio 4: over/subcontains/on error nel corpo *)

arm_clause ::= "this" ">" arm ( ":U" arm )*
arm        ::= IDENT [ "(" type ( "," type )* ")" ]
             | IDENT ":" term "=" term          (* ○ fork 2: costruttore di cammino *)

field     ::= IDENT type                        (* NB: spazio, NON due punti *)
cell      ::= "cell" IDENT type
operation ::= "operation" IDENT "(" param ( "," param )* ")" ":" type
param     ::= IDENT ":" type
law       ::= "law" IDENT

clause_member ::= "over" IDENT | "subcontains" IDENT | "on" "error" IDENT
```

**Attenzione alla asimmetria reale del linguaggio:** i **campi** si scrivono
`nome tipo` (spazio), i **parametri** si scrivono `nome: tipo` (due punti).
È così nel corpus vivo; la grammatica lo rispecchia invece di uniformare.

---

## 3. Le forme, una per una

### 3.1 Record — solo osservazioni ✓ vivo

```
place Slice over Base { weight number }
place SyntaxError subcontains Error { message number line number }
```

Un place senza generatori. Ogni campo è una freccia in uscita `this → T`.

### 3.2 Unione — solo generatori ✓ vivo

```
place Bool  { this > tt :U ff }
place Bit   { this > one :U zero }
place Color { this > Red :U Green :U Blue(number) :U Gray(number) }
place CtorReg { this > CrNil :U CrCons(number, number, CtorReg) }
```

`this >` apre la clausola, `:U` unisce. L'unione è **disgiunta**: in un topos i
coprodotti sono unioni disgiunte e le iniezioni sono mono (estensività), quindi
ogni braccio è un sottooggetto dell'unione e l'analisi per casi è ben definita.

Un braccio può riferirsi al place stesso (`CrCons(..., CtorReg)`): è così che si
dichiarano i dati ricorsivi.

### 3.3 Bracci-place ◐ stadio 1 (fatto, invisibile)

```
place Opened { initial number }
place Closed { moment number }

place Account { this > Opened :U Closed }
```

Un braccio che **nomina un place dichiarato** *è* quel place: l'iniezione
braccio→unione è registrata sulla macchina di `subcontains`, non su un
meccanismo nuovo. Da cui il polimorfismo: un `Opened` è usabile dove è atteso un
`Account`, per subsunzione lungo il mono.

Un braccio la cui testa non risolve a un place resta un costruttore con payload
posizionale, come oggi.

### 3.4 Sum-of-products — generatori **e** osservazioni ◐ stadio 3

```
place Account {
  this > Opened :U Closed
  balance number
}
```

Oggi rifiutato (`failwith` arm+campi in `parser.mly`). Allo stadio 3 diventa
legale, e acquista il significato che il coprodotto impone: **una mappa fuori da
un coprodotto è una tupla di mappe**, quindi un campo dichiarato sull'unione è
un **obbligo su ogni braccio** — `Opened` e `Closed` devono entrambi esporre
`balance`, verificato con la stessa macchina di `subcontains` in direzione
opposta. I campi sull'unione sono l'interfaccia comune, quelli sui bracci il
loro proprio.

Il gate: `examples/union_field_obligation/`, oggi rosso pinnato, verde allo
stadio 3.

### 3.5 Effetti — operazioni e leggi ✓ vivo (forma attuale)

```
place Tally with effects {
  total number
  operation add(x: number): number
}
```

Un'operazione è una freccia **mediata**: non osserva soltanto, agisce. Le `law`
(`law associative`, `law commutative`, `law identity`, `law composition`) sono
obblighi algebrici verificati dal verificatore delle algebre, non commenti.

○ **fork 3 aperto**: le operazioni restano in un blocco marcato `with effects`,
oppure diventano righe della lista come le altre frecce (e `with effects`
sparisce, inferito dalla presenza di operazioni)?

### 3.6 Le tre clausole canoniche ✓ vive nell'header, ◐ stadio 4 nel corpo

```
place Slice over Base { weight number }                 -- slice C/X
place SyntaxError subcontains Error { message number }  -- mono
place QueryInsert on error QueryError { sql number }    -- morfismo d'errore
```

- **`over X`** — categoria slice: ogni abitante porta la freccia canonica
  `this → X`. L'appartenenza senza foreign key.
- **`subcontains B`** — monomorfismo `this ↪ B`: subsunzione, con verifica che
  `this` esponga tutte le osservazioni di `B`. L'ereditarietà ridotta alla sua
  parte sana: solo inclusione, nessun override.
- **`on error E`** — la freccia `this → E` verso un error place. Il fallimento
  non squarcia lo stack: è un morfismo dichiarato, il gestore è il copairing sul
  coprodotto `+E`.

Allo stadio 4 diventano ammesse anche come righe del corpo (header legale come
sinonimo deprecato, migrazione via `yon fmt`).

### 3.7 Error place ◐ stadio 4

```
error Overdraft subcontains BankError { attempted number available number }
```

Oggi `error_decl` è una produzione che duplica `place_decl` con
`pd_is_error = true`. Allo stadio 4 diventa zucchero per `place ... subcontains ...`
marcato: una produzione in meno.

### 3.8 Costruttore di cammino ○ fork 2

```
place Int {
  this > mk(nat, nat)
  this > shift(a: nat, b: nat) : mk(a, b) = mk(a+1, b+1)
}
```

Un generatore di **punti** mette elementi nel place; un generatore di **cammini**
mette **uguaglianze**: dichiara che due elementi sono lo stesso, come dato del
tipo. Conseguenza operativa: ogni funzione che esce dal place è **obbligata a
rispettarlo** — l'obbligo sul ramo-cammino è il **path-over**, e il checker
rifiuta un ramo che non lo soddisfa.

Ti dà: quozienti, multiset finiti, tipi con uguaglianza propria — dati che ogni
altro linguaggio simula con invarianti non verificati.

○ **Aperto**: si abilita adesso (e il path-over pinnato nel kernel è il
prerequisito), o la grammatica riserva il posto e il parser rifiuta con
"path constructor not yet enabled"?

---

## 4. Costruire e smontare

### 4.1 Costruzione — costruttori qualificati ◐ brief superficie S4

```
hit(Confirmed, 100)              →   Payment.Confirmed(100)
hit(Node, hit(Leaf, 10), x)      →   Tree.Node(Tree.Leaf(10), x)
hit(tt)                          →   Bool.tt
```

`Tipo.Costruttore(args)`. Il place fa da cognome, il braccio da nome: zero
collisioni possibili fra `Account.Opened` e `Ticket.Opened`. Nudo ammesso **solo**
nei pattern del `match` e in espressione **dentro** il place che lo dichiara.

`hit` scende nel kernel: la forma qualificata desugara allo stesso termine Core.

### 4.2 Eliminazione — `match` canonico ✓ vivo (forma nuova), ◐ S4 per il ritiro di `hit_elim`

```
fun mot(t: Tree): number { return 0 }                  -- sparisce
hit_elim(mot, [Leaf(v) => v, Node(l,r) => ...], t)     -- ritirato

match t { Leaf(v)   => v,
          Node(l,r) => total(l) + total(r) }
```

Il **motive** — «quando avrai finito di smontare, cosa ti resterà in mano?» —
oggi è il primo argomento di `hit_elim`, e nel corpus è spesso una funzione
finta che ritorna 0, scritta solo per riempire il buco della firma. Dalla Fase 2
(`57016d4`) il motive è **inferito dalla modalità-check**: quando il tipo atteso
varia con la variabile scrutinata, quel tipo *è* il motive.

Il `match` è anche **dipendente**: i rami possono produrre prove, non solo
valori, e l'obbligo cambia ramo per ramo. È il meccanismo che porta l'univalenza
fra `Bool` e `Bit` fino al binario nativo.

○ La forma annotata `match t : Motivo { ... }` resta una porta per il caso in
cui l'inferenza non arrivi: da aprire solo se un caso reale la chiede.

---

## 5. Superficie umana ◐ brief superficie S1-S3

| oggi | domani | Core (invariato) |
|---|---|---|
| `pair(a, b)` | `(a, b)` | `Pair(a, b)` |
| `pair(a, pair(b, c))` | `(a, b, c)` | `Pair(a, Pair(b, c))` |
| `fst(p)` / `snd(p)` | `p.fst` / `p.snd` | `Fst(p)` / `Snd(p)` |
| — | `be (x, y) holds p` | binding di `Fst`/`Snd` |
| `refl(e)` | `clear(e)` | `Refl(e)` |
| `refl(a)` in check | `clear` | `Refl(<inferito>)` |

`clear` nudo vale in modalità check (il tipo atteso `Id(A, lhs, rhs)` dà il
testimone); `clear(e)` quando il testimone va detto.

**Muoiono dalla superficie**: `refl`, `plainly`, `stay`, `pair`, `fst`, `snd`,
`hit`, `hit_elim`. Restano vive come **forme kernel** — i costruttori Core
`Refl`, `Pair`, `Fst`, `Snd`, `HITConstr`, `HITElim` non si toccano.

**Non si toccano** (cantiere separato, decisione pendente): la famiglia journey
`back` / `span` / `through` / `carry..along`.

---

## 6. Fuori dal place — le frecce fra place ✓ vive

```
fun net_worth(a: Account): number { ... }        -- freccia qualunque
move ToArchive of Account from Live to Archive   -- fra mondi
view Snapshot of Account                         -- proiezione read-only
morph normalize of Account                       -- endo, stesso mondo
functor Pricing from Commerce to Finance         -- muove una CATEGORIA intera
reduction Ledger of Account                      -- gestore degli effetti
geomorph Sync from Branch to HQ                  -- pull/push, f* ⊣ f∗
```

Aggiungerne una non cambia l'identità del place. Con la Fase 1b (il file *è* un
place) queste vivono già naturalmente accanto al place senza esserne parte.

---

## 7. Esempio completo — la stella polare

```
place Opened { initial number }
place Closed { moment number }

place Account over Customer subcontains Asset on error Overdraft {
  this > Opened :U Closed        -- generatori: come si fabbrica (disgiunti)
  balance number                 -- osservazione sull'unione: obbligo su OGNI braccio
  owner Customer                 -- osservazione verso un altro place
  cell pending number            -- osservazione mutabile (solo via morfismi)
  operation deposit(x: number): number
  law composition
}

error Overdraft subcontains BankError { attempted number available number }

fun main(): number {
  be acc holds Account.Opened(100)
  be (a, b) holds (acc.balance, 0)
  return a - b - 100
}
```

Stato di questo esempio: **non compila oggi.** Serve lo stadio 3 (arm+campi),
lo stadio 4 (clausole, `error` come zucchero), S1/S4 della superficie
(tuple, costruttori qualificati).

---

## 8. Cosa resta aperto

| # | Fork / debito | Natura | Dove si decide |
|---|---|---|---|
| 1 | **fork 3**: operazioni inline o blocco `effects` | design | stadio 5 |
| 2 | **fork 2**: costruttore di cammino ora o posto riservato | design + kernel | stadio 6; prerequisito path-over pinnato |
| 3 | Guardia world-inference (place-con-bracci salta la riscrittura) | debito ontologico | rientra la biforcazione record/sum sotto altro nome — da sciogliere |
| 4 | `pd_subcontains` opzione → lista (multi-appartenenza) | rappresentazione | prima che il caso appaia nel corpus |
| 5 | Seconda passata di risoluzione (ordine di dichiarazione) | correttezza | primo gradino dello stadio 3 |
| 6 | Famiglia journey (`back`/`span`/`through`) | design | cantiere separato |
| 7 | `match t : Motivo` annotato | design | solo se un caso reale lo chiede |

## 9. Stadi

| stadio | cosa accende | stato |
|---|---|---|
| 0 | specimen gate rosso pinnato | ✓ fatto (locale) |
| 1 | bracci-place, iniezione = subcontains | ✓ fatto (locale), diff MLIR vuoto |
| 2 | morte di `TopType`, una sola forma AST | ✓ fatto (locale), diff MLIR vuoto |
| 3 | **arm + campi legali**, obbligo sui bracci, seconda passata | ◐ prossimo — primo stadio visibile |
| 4 | clausole nel corpo, `error` come zucchero | ◐ |
| S1-S6 | superficie umana (tuple, `clear`, qualificati, migrazione, ritiro) | ◐ brief pronto |
| 5-6 | fork 3, fork 2 | ○ |
