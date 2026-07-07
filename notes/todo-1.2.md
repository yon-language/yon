# Yon v1.2 — roadmap (lavoro futuro)

> Orizzonte v1.2. **Non è stato v1.1.** Registrato dall'architettura di Antonio.
> Inquadramento auditor: la v1.1 è verificata (18 oracle kernel verdi); la v1.2
> è il completamento del **Lemma di Yoneda universale** + gli item differiti.
> Oggi il kernel fa check **per conversione** (normalizza termini); la v1.2 deve
> renderlo un motore capace di **quantificare ed estrarre le coerenze superiori**.

---

## ★ MASTER BACKLOG 1.2 — LISTA UNICA (consolidata 2026-07-07)

Lista unica e prioritizzata di TUTTO l'aperto. Assorbe gli item ancora pendenti
da `to-fix.md` (che resta come registro storico "trovati-per-esecuzione", non più
come lista d'azione parallela). Ogni riga punta al dettaglio più sotto o nel file
indicato. Priorità: SOUNDNESS > completezza tipi > doc > hardening > copertura audit.

### P1 — SOUNDNESS (bug di correttezza, i più gravi)
> **NB 2026-07-07:** verifica empirica — i 4 P1 "tracciati" (universe equality, naturality
> false-Proven, return-tail, place-collision) sono **GIÀ FIXATI** (probe + gate lo confermano;
> ognuno ha check dedicato + messaggio). Il backlog era stale. L'unico bug live l'ha trovato il
> **surface fuzzer** (stdlib-arg type-code, sotto, fixato). Lezione: per la soundness reale,
> fuzzare > inseguire il backlog. Kernel: sound+confluente su ~266k casi (metatheory fuzzer).
- [x] **type-name come arg stdlib → false-accept + crash a emit** — FIXATO 2026-07-07.
  Trovato dal surface fuzzer (seed 30755): `List.empty(text)` (`text` = tipo usato come valore →
  `TyUniverse 0` via `tycheck.ml:799`) passava il check-arg lasco stdlib e crashava a emit.
  Fix: guard in `tycheck.ml` (path generico ECall, ~1148) che rifiuta arg di tipo `TyUniverse`,
  ESCLUSI i `Cubical_bindings.is_primitive` (idEquiv/ua/transport/… che consumano codici-tipo a
  compile-time). Verificato: m1 rifiuta pulito, `transport(ua(idEquiv(number)),5)` compila,
  418 oracle/pipeline + fuzzer sweep 25/25 verdi. Kernel soundness confermata a parte (metatheory
  fuzzer: core sound+confluente ~266k casi/38 seed).
- [x] **place collision cross-world — VERIFICATO FIXATO 2026-07-07** (opzione B:
  rifiuto rumoroso, non `(space,place)` ovunque). `yoner_emit_mlir.ml:481-495`: se un
  nome-place compare in due world diversi → messaggio pulito *"place 'X' is declared
  in two different worlds ('A' and 'B'); a place name must resolve to a single world —
  rename or move one"* + `exit 6`. Verificato empiricamente con un progetto a due
  world (`place Dup` in Alpha e Beta → rifiutato). Pin: `regression/test_place_collision.py`.
  (Il bullet era stale; la sezione "DA FARE" di to-fix.md è storica.)
- [x] **return-implicito-tail — VERIFICATO FIXATO 2026-07-07.** `check_implicit_tail_return`
  (`tycheck.ml:2368`, chiamato da check_fun_decl a 3409/3495): l'ultimo stmt (SLet/
  SAssignHolds/SCall) ha il tipo del suo valore confrontato via `subtype` col ritorno
  dichiarato → `fun h(): text { let y holds "..." }` con valore number è rifiutato
  (*"body ends with a value of type ... add an explicit return"*). Probe dedicato:
  `test_tycheck.ml:100` (verde).

### P2 — COMPLETEZZA TIPI / HoTT
- [x] **`El(Fam x)` / codominio calcolato — CHIUSO 2026-07-07** (=A1, caso calcolabile).
  Superficie sigillata → aperta (`parser.mly:812`: `El(espr)`, non solo IDENT). La
  regola di conversione **`El(c) ≡ El(nf_Δ c)`** riduce ogni codice El alla sua
  forma normale sotto i **delta certificati** (`el_normalize.ml`, stesso reducer
  `Builtins.reduce_with_builtins` della definitional equality; delta = leggi di
  funtorialità/computazione come conversione, NON un inliner di superficie), poi il
  funtore `carrier` puro decodifica la nf al carrier reale del place/prim
  (`carrier.ml:116`). Le type-family (codominio universo) sono droppate da emit
  (`type_erase.ml`: cittadini compile-time). Pinnato: `test_dependent_carrier.py`
  (12/12), fuzz 80/80 su costanti/identità/composte, corpus 76 + 202 gate verdi.
  **Confine onesto**: il caso genuinamente *value-dependent* (family stuck su una
  variabile runtime) NON è lowerato — non ha un unico layout runtime; fallisce
  pulito (nessun miscompile). Serve boxing/monomorfizzazione = feature separata.
- [x] **`core_check.ml` cablato — CHIUSO 2026-07-07** (well-formedness gate, non più
  test-only). Nuovo `core_wf.ml`: dopo desugar (prima di El_normalize) il checker
  dipendente ri-certifica ogni tipo dipendente del Core lowerato (disciplina "il
  kernel ri-verifica l'elaboratore", stile Lean/Coq). Gate **sicuro**: `core_check`
  ora distingue `Check_error` (in-frammento e mal-formato → REJECT) da `Unsupported`
  (fuori frammento: Place/Emit/stream/cubical/letterali → SKIP), quindi un programma
  ben-formato passa sempre (0 false-reject su corpus 76). Riconciliato l'universo dei
  codici: `sort_of`/`El` accetta codici tipati `TyType n` **o** `TyDirUniverse n` (la
  superficie desugara `Type_0`→`TyType`, l'oracolo usava `U_omega`). **Non vacuo**:
  rifiuta `El(g(y))` con `g:number→number` (El di un non-codice) che il tycheck di
  superficie **accettava** — backstop reale. Pin: `test_core_wf.py` (3/3), oracolo
  `test_core_check` 15/15, corpus/A1 verdi.
- [x] **core_check ESTESO — CHIUSO 2026-07-08** (delta-aware + letterali + checking termini).
  (1) **Delta-aware**: `rctx=empty` → record `cctx` threadato per la mutua ricorsione
  (`sort_of/infer/check/ty_conv/norm_ty`), con wrapper `?cc`-opzionali che preservano le
  firme pubbliche; la conversione ora srotola i delta **certificati SN-safe** (subset puro
  di `dr.functions` via `is_pure_body` + `Sct.certify`). (2) **Letterali**: `infer(Var "__num_N")
  → number`. (3) **Checking dei TERMINI (ADVISORY)**: `core_wf` verifica anche i **corpi** funzione
  contro il tipo dichiarato (`certify_term`: NF delta-aware + `check_strict`), ma il risultato è
  **advisory, mai fatale** — un corpo che non checka è loggato+skippato, NON rifiutato. Ragione
  (soundness): il `false` di `check` NON distingue "mal-tipato" da "checker incompleto", e il
  desugar sintetizza corpi (`__functor_inline_*`, `__arg_lam_inline_*`) che il frammento non
  copre → un reject li false-rejecterebbe (scoperto in regressione: 15 fallimenti → fixato).
  Il **gate hard sound** resta il pass di well-formedness dei TIPI (`sort_of`, reject non
  ambiguo: El-di-non-codice). `certify_term` è anche robusto alle eccezioni del reducer
  (`Failure`/`Stack_overflow` da builtin parziali tipo `decide(unknown)` → Skipped, non crash).
  Sul corpus: 22 corpi kernel-checkati, ~49 skippati, **0 rifiuti**. Pin: `test_core_check`
  **24/24** (+9), `test_core_wf_gate.py` 41. Promuovere a fatale solo quando il frammento sarà
  completo abbastanza da rendere un `false` un reject affidabile.
- [x] **tycheck rifiuta `El` di un non-codice — CHIUSO 2026-07-07.** `check_type_well_formed`
  (tycheck.ml, caso `TyEl`): per un codice applicato `f(args)`, se `f` ritorna un tipo-valore
  primitivo (via `Tyenv.lookup_fun`.`fs_return`) → errore di superficie con location
  (*"El(g(y)): the code computes a value of type number, not a type code"*). Prima il caso era
  vacuo (`el_decode(TmVar s)=Some(TyPrim s)` accettava tutto). Universo/generico/place deferiti
  al gate Core. A1 `El(Fam x)` invariato.
- [x] **Glue multi-faccia — CHIUSO 2026-07-07** (era DAVVERO rotto: 2 bug accoppiati).
  `reduce_hcomp`/CTGlue riusava la 1ª equivalenza `e₁` su OGNI faccia glue; e
  `subst_interval_in_ctype`/CTGlue de-sincronizzava `phi` (filter_map) e `partial` (map) →
  la faccia sopravvissuta prendeva la coppia sbagliata. Fix: zip `gphi`×`partial` (una coerenza
  per faccia con la SUA `eₖ`) + restrizione accoppiata phi/partial. Pin: `test_glue_boundary.ml`
  (20/20, era 8/20 rosso pre-fix). Confine: il dispatch-type della T-component resta prototipo
  `CTBase` (non osservabile sul termine); la parte A/univalenza è per-faccia corretta.
- [x] **Test equazioni di bordo del Glue — CHIUSO** (`test_glue_boundary.ml`): non più
  "computes/not stuck" ma le due equazioni CCHM — (F) restrizione su φₖ usa `eₖ`, (B) base/endpoint —
  su un Glue non-degenere a equivalenze distinte, 2 e 3 facce.
- [x] **`ap`/`concat`/`inv` witness inerti — CHIUSO 2026-07-07.** `builtins.ml` (`try_reduce_builtin`):
  le leggi groupoid ora COMPUTANO come riduzioni definizionali — `concat(refl,p)⟶p`, `concat(p,refl)⟶p`,
  `inv(refl)⟶refl`, `inv(inv(p))⟶p`, `ap(f,refl)⟶refl_{f a}`, `path_app(refl,i)⟶a` (recognizer `as_refl`
  per `Refl a` e `App(Var "refl",a)`). Niente più `__coh_witness`: le leggi che richiedono il recupero
  degli endpoint (`concat(inv p,p)`, `inv`/`ap` su path generico) restano **neutre oneste** (None),
  non witness fabbricati — la macchina interval/Kan (cubical.ml) possiede il resto. Pin:
  `test_builtins.ml` (38/38, +19), con guard "nessuna legge riduce a `__coh_witness`".

### P3 — DOC (togliere il bersaglio dell'audit esterno)
- [ ] **Scoping HoTT:** "tipi dipendenti del prim'ordine + core cubicale (univalenza-via-Glue)
  testato; elaborazione dipendente piena sulla roadmap". Togliere "proof assistant" finché
  SN non è pubblico + superficie cablata.
- [ ] **Esempi forti:** mostrare `id_endpoint_coherence.yon` (def-eq che riduce), non il Sigma non-dip.
- [ ] **Superficia SN/SCT:** sommario pubblico della metateoria.
- [ ] **Modello di memoria:** documentare content-addressed monotonico + `strip_trim` + `drop X`
  + death-watch. Chiude "no GC / never free" (ricorre in OGNI venue: HN, PCJ, LLVM Discourse).

### P4 — HARDENING
- [ ] **locally-nameless / de Bruijn** per il kernel (subst named è sound, ma più fragile).
- [ ] **Space death-watch automatica** (reclaim senza `drop` esplicito). [dettaglio: sezione dedicata]

### P5 — COPERTURA AUDIT (moduli mai battuti a fondo)
- [ ] Cuore tipi: `dispatcher` · `hm_infer` · `ty_subst` (debito copertura, buco storico chiuso)
  · `core_check` · `type_erase` · `prop_eval`.
- [ ] Runtime: `xleech2_mphf.c` · `xleech2_handler_stack.c` · `yon_curtis_canon.c` · `yon_mmap.c`.

### Caratteristiche di design (NON bug — documentare, non "fixare")
- stdlib typing lasco agli argomenti = conseguenza del boundary f64 (load-bearing, intenzionale). [to-fix.md]
- cumulatività universi direzionale = feature.
- linter: 4 regole (W1001-1003, W3001); `dead-function = "referenced nowhere"` FATTO;
  header stale allineato 2026-07-07. Nuove regole = feature da aggiungere se volute.

---

## A. Yoneda universale — dal "Testimone di Pienezza" al teorema completo

Oggi `witness_ty` fissa il bersaglio a `Hom(-, Q)`: il sistema calcola perché sa
come computano le funzioni concrete. Per il prefascio arbitrario servono tre
pilastri che la v1.1 non vede.

### A1. Internalizzare il prefascio F come famiglia di tipi
Esprimere un funtore contravariante interno:
1. **Azione sugli oggetti**: famiglia dipendente `F : Type_0 → Type_0`.
   → **CHIUSO 2026-07-07** (caso calcolabile). Superficie aperta a `El(espr)`;
   `El(F x)` computa via `El(c) ≡ El(nf_Δ c)` (delta certificati come conversione,
   `el_normalize.ml`); carrier decodifica la nf; type-family droppate da emit. Pin
   `test_dependent_carrier.py` (12/12) + fuzz 80/80 + corpus/gate verdi.
   → **value-dependent BOXING — CHIUSO 2026-07-08** (F, livello ABI): un `El` genuinamente
   value-dependent (codice stuck sotto Δ) ora lowera a un **carrier uniforme boxed** —
   fat pointer `!llvm.struct<(ptr,i64)>` (payload-ptr + tag i64), invece di fallire con
   `NoCarrier`. Sound (self-describing: il tag differisce il tipo a runtime, mai reinterpretato;
   memory-safe; uniforme → compile-once). Il caso A1 calcolabile è **byte-identico** (branch
   `Named` intatto; `test_dependent_carrier` 12/12). Pin: `test_boxed_el_carrier.py` (4/4).
   Confine onesto: fatta la **rappresentazione/ABI** (l'`El` value-dependent compila e
   round-trippa attraverso le chiamate); mancano intro/elim a livello di **valore**
   (alloc+tag / tag-check+load) — servono solo quando un costrutto di superficie costruisce/
   elimina un abitante stuck-El, che oggi non esiste, quindi non stubbato.
2. **Azione sulle frecce** (pull-back contravariante): per ogni `A, B` e
   `f : A → B`, un'operazione `F(f) : F(B) → F(A)`. → **rappresentazione kernel CHIUSA
   2026-07-07**: `F(f)` = `__psh_map F f` (riusa `App`/`Var`, nessun nuovo costruttore AST).
3. **Leggi di funtorialità** come regole di conversione del kernel:
   `F(id) ≡ id` e `F(g ∘ f) ≡ F(f) ∘ F(g)`. → **CHIUSO 2026-07-07** in `reduce.ml`
   (`try_functoriality`, guardato sulla forma `__psh_map`): `F(id) ⟶ id`,
   `F(g∘f) ⟶ F(f)∘F(g)` (contravariante). Argomento SN (misura `Σ|2° arg di __psh_map|`
   decresce) + WCR (LHS testa-disgiunti) ⇒ confluente (Newman). Fira anche con `F` astratto
   (legge solo lo slot morfismo) — conversione R_Yon, non inliner. Pin: `test_functoriality.ml`
   (12/12, due oracoli concordi); metatheory-fuzz byte-identico (non-interferenza provata).
   `__id`/`__compose` restano neutri canonici (le leggi di unità/associatività della
   composizione sono un concern separato, non aggiunte).
   → **SUPERFICIE CABLATA 2026-07-08** (E): `psh_map(F,f)` / `psh_compose(g,f)` / `psh_id`
   (nomi riservati sulle produzioni `ECall`/`EVar` esistenti — **zero nuova grammatica**,
   menhir 11→11); desugar ai marker `__psh_map`/`__compose`/`__id`; regola tycheck
   `psh_map(F,f) : F(B)→F(A)` (contravariante, oggetto = `El(F X)`), `psh_id:X→X`,
   `psh_compose` composizione. Tutte SOUND-FIRST (firano solo sulla forma presheaf, altrimenti
   `unknown` — nessun falso reject). Pin: `test_psh_surface.ml` (15/15), da superficie:
   `F(id)⟶id`, `F(g∘f)⟶F(f)∘F(g)`, contravarianza reale. A1.2/A1.3 ora chiuse kernel+superficie.

Il caso calcolabile (F concreto, `Fam(x)` che srotola via delta) è chiuso: il
riduttore ha le delta-regole certificate. Resta il caso di `F` **astratto**
(`F(f)` non srotolabile), che richiede 2+3 come delta-regole primitive.

### A2. Espandere Π con le congiunzioni cubiche (sistemi di facce complessi)
Yoneda: `Nat(よA, F) ≅ F(A)` è naturale **sia in A sia in F**. La naturalità è
un'uguaglianza tra trasformazioni → un **cammino di cammini** (omotopia
superiore). Non basta più la faccia singola del cubo (task #12, `i = I0 => …`):
servono le **congiunzioni di facce** (`i = I0 ∧ j = I1`). Spostare una
trasformazione naturale lungo un cambio di base funtoriale disegna un quadrato
(due lati = azione del prefascio, due lati = la trasformazione); chiuderlo
richiede che `hcomp` accetti **vincoli multidimensionali** per chiudere il cubo
omotopico.

### A3. Soluzione transitoria — Riflessione di Tarski (universi)
Via più rapida senza riscrivere la metateoria (stile Coq/Agda). Rendere `El(c)`
capace di **ispezionare la struttura del codice**: tipo primitivo
`Universe_Code` + pattern-matching sulla forma del tipo (Pi / Sigma / Id). Allora
una funzione interna costruisce esplicitamente l'iso di Yoneda per ogni tipo
induttivo → non più asserzione astratta, ma **algoritmo di traduzione dei tipi
certificato dal Core Checker**.

---

## B. Piano d'attacco v1.2 (i passi nel codice)
1. `frontend/parser.mly` — sintassi delle **congiunzioni cubiche** (`i=I0 ∧ j=I1`).
2. `reduce.ml` (core reduction) — **delta-regole** per i simboli di prefascio
   astratto e le loro composizioni (A1).
3. **Iso speculare**: non solo la proiezione `η ↦ η_P(id_P)`, ma la **freccia
   inversa** che da `x ∈ F(A)` genera la trasformazione naturale associata,
   dimostrando `f ∘ g ≡ id` e `g ∘ f ≡ id`.

---

## C. Altri item differiti (da sessione e CODEX_CONTRACTS)
- **B-fs-5 — place-as-object esclusivo**: togliere le frecce top-level dalla
  grammatica (3 mosse: `main` solo dentro `place Entry`; il driver legge le
  firme remote anche dalle frecce-dentro-place; rimozione/negativizzazione delle
  frecce top-level). Non prima che cross-space sia stabile.
- **CI job runtime cross-space**: oltre al nodo pytest capability-aware, un job
  separato che esegua `run.sh` dove SHM/fork sono disponibili.
- **Scope Kan/HIT/Glue**: Gate 2 dell'audit ne misura il confine esatto per il
  libro; estenderlo (facce composte multi-atom, collegato ad A2) è v1.2.
- **`morph on morphism` — check di funtorialità (oggi STUB)**: l'azione del
  funtore sulle frecce è accept-all. `tycheck.ml check_via_bindings` (~L2852)
  verifica solo che il bersaglio `via` esista come fun/reduction; NON verifica
  che la firma sia `F(dom N) → F(cod N)` (dove `F` = azione sugli oggetti,
  `mp_on_object`). È la versione pratica di A1 (azione sulle frecce) al livello
  superficie. **Negativo che dimostra il gap già scritto**:
  `regression/_pending_construct_tests/neg_morph_via_signature.yon` — accettato
  oggi (exit 0), deve essere rigettato (exit 3) dopo l'indurimento. Indurimento
  SOUND-FIRST (no falso-rigetto, come PathP al rovescio): (1) esistenza della
  freccia sorgente nel topos `mp.mp_source`, con skip grazioso se il topos non è
  in scope (vari esempi referenziano topoi non dichiarati); (2) funtorialità via
  `Dispatcher.subtype`, mai un'uguaglianza ad hoc, mai più forte di F(f):F(X)→F(Y).
  Must-not-regress: c_morph_on_morphism + geom_morphism_* + functor_compose_* +
  nat_transform_functor devono ancora compilare. Va fatto col build-loop sul Mac.

---

## Evidenza empirica (audit d'esecuzione, 2026-06-22) — gap CONFERMATI
I due gap qui sotto NON sono congetture: trovati compilando ed eseguendo sonde
(`swarm/frontier/`), sul Mac con la toolchain piena.
- **A2 — congiunzioni cubiche cross-dimensione**: CONFERMATO ASSENTE. `hcomp`
  accetta facce multiple sulla *stessa* dimensione (`[i=I0=>…, i=I1=>…]` compila),
  ma la congiunzione `i=I0 ∧ j=I1` non è scrivibile — `∧` non è un token del lexer.
- **B3 — inverso di cammino / round-trip dell'ua**: CONFERMATO ASSENTE.
  `sym(p)` → `TYPE ERROR: unknown function or operation: sym`. Senza l'inverso,
  l'iso completo di Yoneda (`f∘g ≡ id` E `g∘f ≡ id`) non è esprimibile.

**Ciò che invece FUNZIONA all'esecuzione (da non confondere coi gap)**: `comp`,
`hcomp` (faccia singola e 2-facce stessa-dim), `transport(ua(...))` forward incl.
equivalenza non banale (`succ/pred` → riduce al valore, NON resta marker),
`hit_elim` (ramo punto/base), `ind_path`/J. Verificati exit-code alla mano.

## Cumulatività degli universi (direzionale) — feature, non bug
Oggi Yon NON applica la cumulatività: `ty_structural_eq`/`ty_subst` confrontano gli universi con `n1 = n2` (uguaglianza pura), e `level_of_type` (già scritta in tycheck.ml:2382) è usata solo nei self-test di main.ml, non nella pipeline. Se si vuole la cumulatività vera — `Type_n <: Type_m` per `n ≤ m`, così che un tipo piccolo sia usabile dove se ne attende uno più grande — va aggiunta come check **direzionale** al sito di sottotipaggio (NON nell'uguaglianza simmetrica), riusando `level_of_type`. Attenzione: deve restare anti-Girard (mai `Type_m` dove serve `Type_n` con m>n).

## VoyagerList interleaver — modalità di storage, NON un metodo di lista
Oggi `VoyagerList` è una lista di codeword Golay (24,12,8) **indipendenti**: ogni
`append(d)` sigilla `d` nel suo codeword, ogni `get` corregge fino a 3 errori *di quel
codeword*. Protegge gli errori **sparsi** (fino a 3N su N elementi se distribuiti). L'interleaver
NON è un metodo in più sulla lista: è una **modalità diversa di mettere i dati** — spezzare un
dato grande e interlacciarne i bit *tra* i codeword, così un **burst contiguo** si spalma su più
codeword e ognuno ne vede ≤3 (la protezione vera della sonda Voyager). Quindi va aggiunto come
*strategia di sigillatura/layout* (interleaved vs per-elemento) + un `get` che ricompone il dato
grande dall'interlacciamento. Ha il suo viz e il suo gate, distinto dalla lista attuale.
(Caratterizzazione di Antonio, 2026-06-27; il libro lo tratta in v1.2, non spacciandolo per
estensione della lista che già c'è.)


<!-- ===== Appended 2026-06-30: frontier language concepts + Bug B + produce-= stop-gap ===== -->

# Frontier 2026 language concepts (and Bug B) — added 2026-06-30

**Principle.** Every item is a STAGED refactor: Stage 1 is behavior-preserving and
byte-identical (annotation only, defaults that change nothing), then the later stages add
the new behavior. Never big-bang. Ordered by affinity with the existing base.

**1.1 status.** Closed this cycle: the `return s.fold(...)` soundness bug (fold a stream in
return position read the handle as a list and returned 0; fixed in `desugar.ml` v1_lower_stmt,
gate `regression/yon_tests/runtime/stream_fold_return.yon`). Everything below is 1.2.

---

## Frontier 2026 language concepts (Yon already has half)

1. **QTT — Quantitative Type Theory.** Quantities `{0, 1, ω}` on every binder. Yon already
   has the `0` case (the erasure, `type_erase.ml`). Stage 1 = annotation + default `ω`,
   byte-identical. Stage 2 = linearity enforcement (quantity `1`). Stage 3 = unify the
   erasure under QTT. Reference: Idris 2 (Atkey 2018).

2. **Effects in types (approach "3").** The effect (`visits E`) enters the ARROW TYPE, it no
   longer stays a separate field of the signature. An operation's purity is DERIVED from its
   type, not hand-cabled in the `.td`: `emit` is impure because its type says `visits Stream`.
   Representation fork (how the effect row sits in `TyArrow`, surface syntax) is Antonio's
   decision when this is scheduled.
   - **NB (corrected):** the original framing said this "closes the SVN-emit bug as a
     consequence." That bug DOES NOT EXIST — verified 2026-06-29: the SVN does not collapse
     `emit`s (`produce { iter 5 { emit 7 } }` bound and folded sums to 35, all five arrive;
     `Stream__send` is a `func.call`, not in the `isKnownPureCall` whitelist nor
     `MemoryEffectFree`, so the SVN already skips it). The two real defects were the
     return-position fold (fixed in 1.1) and the 64-slot stream buffer (item B below). So this
     item stands on its OWN merit (principled purity from types), with no SVN-emit bug to close
     and no MLIR-local 1.1 fix outstanding.

3. **Composable / row-polymorphic effect handlers.** Generalize `reduction visits`: handlers
   that compose, polymorphic effect rows, a function declaring "uses at most these effects."
   Reference: Koka, Effekt.

4. **Capabilities.** No ambient access to IO/network/fs: a function does IO only if you pass it
   the explicit capability. The effect reified as a passable value. Grafts onto effects-as-place.
   Reference: Roc, Austral.

5. **Linear types / type-verified GC.** Quantity-`1` (from QTT) applied to region consumption:
   the type-checker guarantees a region is consumed exactly once → memory control verified at
   compile time, not only by construction. Categorically at home (symmetric monoidal category).
   This is the answer to "there is no memory control": it is 1.2, not missing from 1.1.

6. **Comptime / explicit staging.** Give a surface name to the compile-time evaluation the
   reducer already does: a `comptime` block executed during compilation, its result inlined.
   Reference: Zig.

7. **Structured concurrency.** The block `spawn` becomes lexically structured: a `spawn` block
   does not outlive its scope, the join is guaranteed by the type, no orphan tasks. Builds on
   the isolation-by-construction already present.

### Do NOT add
- **async/await.** A special case of the effect handlers we already have; it would be a
  downgrade. Roc itself uses managed effects, not async/await.

---

## In-process stream back-pressure (Bug B → approach iii)

Today the in-process stream (`yon_rt_stream_emit`, `runtime/yon_rt.c`) is a fixed 64-slot ring
(`YON_STREAM_MAX_SLOTS`) that SILENTLY DROPS past capacity. The cross-process SHM wire already
has real back-pressure (`yon_rt_stream_shm_produce_blocking`: block-poll until room). Decision:
**approach (iii)** — bring the wire's mechanism in-process, but with producer and consumer as
SEPARATE concurrent flows (the process model already present: spawn + SHM collection), so the
blocking back-pressure does not deadlock the single-flow `produce { } ; fold` pattern. Closes
the silent drop. Staged: Stage 1 leave the bounded ring but make the drop loud/an error;
later stages make `produce` a separate flow with blocking back-pressure.

Plus the **declared `unordered` / `parallel` stream mark** (Antonio's surface decision, to be
designed): an unordered stream may spread over N buffers for N processes and multiply bandwidth;
an ordered stream stays a single channel. Not automatic, not hidden — declared. The model
underneath (spawn + SHM collection) exists; only the mark that says when it is legal is missing.

**Distinct manifestation found 2026-07-01 — cross-process concurrent-drain read race.** Bug B
above is the in-process silent-drop. Separately, the cross-process SHM wire (`await_shm` drain in
a consumer process while a producer process is still writing) has a torn/stale read under
contention: the cross-space gate's scenario 3 (`regression/cross_space/`, producer streams 1..8,
consumer folds the sum = 36) intermittently returns `36 + k*64` (k=1,2,3), i.e. a single
`await_shm` returns a value one-or-more ring-lengths too high. The `64` is `YON_STREAM_MAX_SLOTS`,
so the race is in the ring's slot/generation read, not in the framing (the consumer loops exactly
8 times; it is a wrong VALUE, not an over-count). It is load-sensitive: ~80-100% correct in
isolation, surfaced only under the full parallel suite. **1.1 mitigation (shipped):** scenario 3
now uses a **readiness handshake** — the producer runs to completion (writes 1..8 + close, then
exits) before the consumer drains, so the gate is deterministic and still exercises the full
cross-process transport (8 < 64 sit in the file-backed segment, which persists past the producer's
exit). **1.2 action:** when the ring read is made race-free, restore scenario 3 to the *concurrent*
producer/consumer form (drop the sequencing) so it stands as the regression witness for this race.

**Related gap to close in the same rework: `=` inside a `produce` block.** A `produce`/`spawn`/
`scope` body is desugared via `desugar_stmt` (Core-term path), which bypasses the v1 cells pass
(`desugar.ml` ~1907/1997) that promotes `be x holds 0` to a Space cell and rewrites `x = e` to
`Space__set(x, e)`. So a mutable counter inside `produce { ... i = i + 1 ... }` desugars to
`__space_update_here`, which `emit_mlir` does not implement. The proper fix threads the cells
promotion into produce/spawn/scope bodies (so `=` there works like everywhere else); it overlaps
with making `produce` a separate concurrent flow, hence here. **Stop-gap shipped in 1.1**
(`tycheck.ml` `first_assign_loc`, checked at `EProduce` / `ESpawn`): `=` inside produce/spawn is now
rejected with a clean compile-time error (exit 3) instead of crashing emit_mlir — negative test
`regression/yon_tests/negative/neg_assign_in_produce.yon`. The full fix (make `=` actually work
there) is the 1.2 work above.

---

## Open debts — 1.2 candidates

- **Sheafification / topology not wired** (orphan + not-yet-emitted + simulated trigger). Debt
  #1, the one genuinely uncovered point. It is a project.
- **`ua` / Glue / transport / Path not exposed end-to-end from surface.** Requires δ-conv on the
  path. Elaborate `ua` → kernel `TyGlue` (loc-keyed table).
- **`glue` / `unglue` with statically-untracked base** (Glue opaque, unglue unknown).
- **`ind_path` / J neutral does not normalize in endpoint type-level until non-refl.**
- **Multi-node / remote for Space** (single-process today).
- **`emit_ty` (schema) not yet a printer of the carrier** — the carrier refactor to finish
  (nested-arrow schema vs flattened body).
- **`type_erase` higher-order not lowered** (today a stop-gap `failwith`).
- **`TyEl`-opaque NoCarrier** — safety net, live with surface Path/`ua`.
- **Weak example coverage on `geom_morphism` (0), `reduction` (1), `topology` (1).**
- **Runtime build platform-specific + mmgroup `.o` provenance** (portability).


## Space death-watch (1.2): dynamic state on top of the static graph (1.1)

**1.1 closed (2026-07-03): `drop X` end to end.** The explicit, compile-time
reclaim is done: analysis decides (`downstream_arcs`, the shared predicate),
the check verifies (existence from the manifest census, then reachability; exit-3
with the offending site), and the runtime honors (`yon_xheap_drop` = madvise the
Space heap's live arena, the whole-heap twin of `strip_trim`, at the drop point).
The runtime reads a decision already made; it does not make one. Double pin on the
`yon_xheap_drops()` counter, negative control seen failing. This 1.2 death-watch
is the AUTOMATIC counterpart (reclaim without an explicit `drop`), built on the
same graph and the same predicate; do NOT fold refcounts or runtime EOF into the
1.1 pass.

The 1.1 static Space communication graph (`frontend/space_graph.ml`, driver flag
`yonc <dir> --dump-space-graph`, gate `regression/test_space_graph.py`) is the
foundation this feature stands on. The split is the same one the whole language
keeps: the type is static, the value is dynamic; here the GRAPH is static, the
STATE of the graph is dynamic.

- **Static (done, 1.1):** which arcs can exist. The graph is a projection of the
  source: an arc `A -> B` is a declared `wire to space B` or `import ... from B`
  in code that lives in Space `A` (the entry root is node `""`). The in/out
  degree sums both families, so an isolated Space (in = out = 0) is reclaimable
  at end of work with NO runtime watch, deduced by the compiler. This is the
  perimeter inside which death can happen.
- **Dynamic (1.2, this item):** WHEN an arc closes (a wire reaches EOF), WHEN a
  Space is terminable now. The runtime observes closure: a live subscription
  count per channel, observable EOF, `kill(pid,0)`/`ESRCH` liveness, and a
  reclaim (madvise/unmap the Space heap) once every incoming arc of a Space has
  closed. The compiler guarantees "this Space communicates only with these"; the
  runtime observes when those arcs go quiet.

This separation is what makes the death-watch SOUND rather than heuristic: the
runtime never has to guess the topology, it reads it off the static graph and
only watches the closure of arcs the compiler already proved finite and named.
Depends on the 1.1 pass; do NOT fold refcounts or runtime EOF into that pass.

---

# Audit esterno (omega su r/programmingcirclejerk + thread HN 48436170, 2026-07-07)

Due critici competenti (omega; `lambdas`) hanno recensito repo + doc. La maggior
parte delle accuse PUNTUALI sono misread (smontate con file:line qui sotto), ma
alcuni gap veri COINCIDONO con item già in questo backlog, e ne escono di nuovi.
Categorie: **[CHECK]** verificare (può essere già ok) · **[FIX]** lavoro reale ·
**[DOC]** solo documentazione/scoping.

## Accuse smontate (misread — munizione per la replica, non lavoro)
- **"def-eq non riduce, solo nodi sintattici"** → FALSO. `false_coherence.yon`
  riduce `g(f(a))→a+1` e rifiuta (E2001); `id_endpoint_coherence.yon` compila.
  La superficie riduce gli endpoint `Id` via Dispatcher/`Reduce.ctx` (`tycheck.ml:727`).
- **"no intervalli/univalenza, non è HoTT"** → FALSO. `cubical.ml`: interval type
  reale; univalenza-via-Glue CALCOLA; `test_path_core`/`test_cubical_surface` verdi.
- **"booleani classici ⇒ LEM ⇒ contraddizione"** → FALSO (conflation Bool/Prop,
  design standard à la Lean). `test_excluded_middle_failure` (`main.ml:1782`)
  prova che LEM NON vale sui Prop.
- **"CTGlue: partials droppati, mai gluati"** → misread. L'equivalenza è applicata
  via `__equiv_fwd` (`cubical.ml:494`, test "Glue transport → forward map succ").
- **"cattura di variabile negli Scope"** → misread. `Scope.s` è etichetta di
  Space (`ast.ml:175`), non un binder; `free_vars` la ignora (`:331`). I binder
  veri (`Lam`) fanno alpha-renaming (`subst.ml:22-32`).
- **"never free = OOM = lying"** → FALSO. `drop X` (reclaim esplicito 1.1,
  `yon_xheap_drop` = madvise) + `strip_trim` (RAM fisica) + death-watch (1.2).

## Gap veri — GIÀ tracciati (i critici hanno confermato item noti)
- **[FIXED 2026-07-07] `El(Fam x)` / codominio calcolato** = A1 (caso calcolabile).
  Superficie aperta (`parser.mly:812`) + conversione `El(c) ≡ El(nf_Δ c)` via reducer
  del kernel coi delta certificati (`el_normalize.ml`) + carrier decodifica la nf
  (`carrier.ml`) + type-family droppate da emit (`type_erase.ml`). Pin:
  `test_dependent_carrier.py`. Resta debito separato: ua/Glue/transport/Path da
  superficie (P2), e il caso value-dependent (boxing) fuori A1.
- **[FIX] Glue multi-faccia incompleto** = A2/B3 "CONFERMATO ASSENTE".
  `reduce_hcomp` CTGlue usa solo la 1ª coppia partial (`cubical.ml:477`,
  `(t_ty, equiv) :: _`); le altre facce sono ignorate.

## Nuovi item da quest'audit
- **[CHECK] Test sulle equazioni di bordo del Glue.** Oggi i test dicono
  "computes / not stuck", NON "soddisfa le equazioni di bordo". Scrivere: comp/hcomp
  a un Glue non-degenere con equivalenza NON-identità → verificare (a) su φ coincide
  col partial element, (b) endpoint corretti. Chiude il "confine CCHM" (= Scope
  Kan/HIT/Glue, Gate 2) senza bisogno di un esperto esterno.
- **[FIX/CHECK] `core_check.ml` non cablato alla superficie.** Il checker dipendente
  che riduce (beta/eta/J, `ty_conv`) è test-only (`test_core_check`,
  `test_yoneda_typed`); la superficie usa `tycheck → ty_structural_eq` (strutturale,
  tranne la riduzione degli endpoint `Id` via Dispatcher). Decidere: cablare
  core_check nella pipeline, o documentare che la conversione di superficie è limitata.
- **[FIX] `ap`/`concat`/`inv` sono witness inerti** (`builtins.ml:567-579`,
  `__coh_witness`): nessuna algebra di cammino. Legato a B3 (inverso di cammino).
- **[FIX-opz] Locally-nameless / de Bruijn.** Il subst named + alpha-renaming
  on-the-fly è SOUND (Scope non è binder; i binder veri rinominano), ma i critici
  hanno ragione che de Bruijn/locally-nameless è più robusto e a prova di errore.
  Irrobustimento del kernel, non un bug.

## Doc — togliere il bersaglio (l'overclaim che si è fatto dunkare)
- **[DOC] Scoping HoTT.** I doc dicono "types from HoTT"; il frammento runnable di
  superficie è del PRIM'ORDINE (refl/pair/fst/snd + Id + comprehension) sopra un
  core cubicale testato. Riscrivere: "tipi dipendenti del prim'ordine + core
  cubicale (univalenza-via-Glue) verificato nei test; elaborazione dipendente piena
  sulla roadmap". Togliere "proof assistant" finché SN non è pubblico e la
  superficie non è cablata.
- **[DOC] Esempi forti.** Mostrare `id_endpoint_coherence.yon` (la def-eq riduce) e
  un Sigma DAVVERO dipendente, non il Sigma non-dipendente che legge come "non è
  dipendente".
- **[DOC] Superficia SN/SCT.** La metateoria è interna; metterne almeno un sommario
  pubblico — il lettore che vede solo il sito non può saperlo (lagnanza legittima).
- **[DOC] Modello di memoria.** Documentare: heap content-addressed monotonico (slot
  stabili per-vita-processo, by design) + reclaim fisico (`strip_trim`) + `drop X`
  esplicito + death-watch automatica (1.2). Chiude "no GC / never free".
