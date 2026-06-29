# Yon v1.2 — roadmap (lavoro futuro)

> Orizzonte v1.2. **Non è stato v1.1.** Registrato dall'architettura di Antonio.
> Inquadramento auditor: la v1.1 è verificata (18 oracle kernel verdi); la v1.2
> è il completamento del **Lemma di Yoneda universale** + gli item differiti.
> Oggi il kernel fa check **per conversione** (normalizza termini); la v1.2 deve
> renderlo un motore capace di **quantificare ed estrarre le coerenze superiori**.

---

## A. Yoneda universale — dal "Testimone di Pienezza" al teorema completo

Oggi `witness_ty` fissa il bersaglio a `Hom(-, Q)`: il sistema calcola perché sa
come computano le funzioni concrete. Per il prefascio arbitrario servono tre
pilastri che la v1.1 non vede.

### A1. Internalizzare il prefascio F come famiglia di tipi
Esprimere un funtore contravariante interno:
1. **Azione sugli oggetti**: famiglia dipendente `F : Type_0 → Type_0`.
2. **Azione sulle frecce** (pull-back contravariante): per ogni `A, B` e
   `f : A → B`, un'operazione `F(f) : F(B) → F(A)`.
3. **Leggi di funtorialità** come regole di conversione del kernel:
   `F(id) ≡ id` e `F(g ∘ f) ≡ F(f) ∘ F(g)`.

Senza queste delta-regole in `Reduce`, inserendo `F` astratto il riduttore si
pianta: non sa srotolare `F(f)`.

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

## Open debts (from audit_language.md) — 1.2 candidates

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
