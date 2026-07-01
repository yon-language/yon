# to-fix — limiti reali trovati PER ESECUZIONE (v1.1)

> Regola: ogni voce qui è stata trovata **compilando ed eseguendo** un programma
> a risposta nota, non leggendo i sorgenti degli oracle. Una funzionalità che
> all'esecuzione produce un **marker**, uno **stuck**, un **valore errato** o un
> **reject** dove dovrebbe ridurre → finisce qui, con il programma che lo mostra.
>
> Colonne: costrutto · programma · osservato (com'è uscito) · atteso · gravità.

| costrutto | programma | osservato | atteso | gravità |
|---|---|---|---|---|
| **build progetto (`yonc <dir>`)** | tutti gli `examples/*/` (≈29) | era `COMPILE_FAIL: missing 'backend' in [runtime]` | binario eseguibile | **RISOLTO** — scelta di Antonio: `[runtime] backend="memory"` esplicito aggiunto ai 29 yon.toml. Ora costruiscono ed eseguono: tutti corretti (0 auto-verificanti + sentinel di design: handle_lambdas 44, kw_merge_move 22, kw_topos_block 42…) |
| **`decide(unknown)` → SIGABRT** | `examples/decidable_unknown.yon` | `Abort trap: 6` → exit 134 | abort **intenzionale** (asserzione di decidibilità) | **DESIGN, non bug** — l'abort è voluto e correttamente in baseline. Aperto: SIGABRT crudo vs **reject a compile-time** (il type system sa che `unknown` non è decidibile) o **errore tipato** (modello error-place). Decisione di Antonio |
| **copertura runtime dei progetti** | `examples/*/` + `regression/yon_tests/*` | la pytest li **emette** soltanto (`yoner_emit_mlir`), non li costruisce+esegue con `yonc` | gate runtime in suite | **MEDIA** — la verifica-all'esecuzione fatta oggi NON è catturata dalla suite: un domani una regressione runtime passerebbe in silenzio. Aggiungere un gate che `yonc <dir>` + run + confronta l'exit atteso |

## Coda lunga builtin (audit d'esecuzione, batch 1)
| costrutto | programma | osservato | atteso | gravità |
|---|---|---|---|---|
| **`Seq.range` crash** | `swarm/builtin_probe/seq_range.yon` | era `Fatal error: unknown function '__stream_from_list'` | no crash | **RISOLTO** — aggiunto caso emit identità per `__stream_from_list` standalone (lo stream È l'handle della lista). Ora compila+esegue, pytest 321 |
| **`Seq.range` tipo = `number`** | `for every x in Seq.range(5)` | `TYPE ERROR pulito: for-every requires list/stream, got number` | iterabile come stream | **MEDIA (no crash)** — `Seq.range` è registrato `→ f64`, quindi non for-every-iterabile. Decisione API: tiparlo `stream of number` o consumarlo solo via `Seq.fold` |
| **`XRelSet`/`XRelMap`/`XSimplex` build-fail** | `swarm/builtin_probe2/*` | era BUILD_FAIL: il MLIR chiamava `@yon_rt_xrel*`/`@yon_rt_xsimplex_*` **non dichiarate** | binario | **RISOLTO** — aggiunte 19 `func.func private` in `emit_mlir.ml` (le def erano già in `yon_rt.c`). Ora costruiscono ed eseguono; pytest **321**. Regressione silenziosa (0 copertura) chiusa |
| **`XRelSet`/`XRelMap`: `add_ref` (frame custom) non esposto** | `swarm/builtin_probe2/xrelset_class.yon` | `size(add 1536, add 1280)=2` | distinte sotto Curtis (corretto) | **RISOLTO/chiarito** — CORREZIONE: `XRelSet` classifica **già** per classe col frame **Curtis di default** (`canon`=`YON_CURTIS_CANON_IDX`, non identità); la size-2 è corretta (1536/1280 = classi Curtis diverse), NON un buco. `add_ref` serve solo a **personalizzare** il frame — ora esposto (`stdlib_runtime.ml` + emit). La verifica esatta delle classi Curtis è matematica specialistica → todo-1.2 |
| **`to_stream` mancante su `XRelSet`/`XRelMap`** | — | non registrato | iterabilità come XSet/HashSet | **MEDIA** — incoerenza API: non puoi scorrere XRel* |
| **nessun `remove`/`difference`/`pop`** | — | assenti su tutte le collezioni | API completa | **BASSA/MEDIA** — `remove` (Map/Set/Vec), `difference` (Set), `pop` (Vec) |
| **`XSet.add` — ignore silenzioso** | `swarm/builtin_probe/xset_has.yon` | `add(empty,7)` no-op → `contains=false` (exit 9) | — | **BASSA (non bug)** — `XSet` accetta solo punti **type-2 Leech**; `7` non lo è → `yon_rt_xset_add` lo ignora *silenziosamente* (corretto, ma nessun segnale). La mia sonda era fuori dominio. Migliorabile: errore/segnale invece di ignore muto |

## Full audit adversariale (batch 1) — robustezza del compilatore
| caso | osservato | atteso | gravità |
|---|---|---|---|
| **stringa vuota `""`** | `String.length("")` → `Fatal: variable '__str_' not in scope` | 0 | **RISOLTO** — `decode_string`/emit usavano `len > 6`; `__str_` (vuoto) è len 6 → scartato. Fix `>= 6` (builtins.ml + emit_mlir ×3) |
| **corpo funzione vuoto** | `fun main(): number { }` → `Fatal: [emit_mlir infer] term form cannot be analyzed` | rifiuto pulito "manca return" | **ALTA (crash)** — eccezione OCaml invece di errore diagnostico |
| **parametro duplicato** | `fun f(a, a)` → FE_ok ma **BUILD_FAIL** | rifiuto pulito "param duplicato" | **MEDIA** — check mancante nel frontend |
| **funzione senza return** | `fun main(): number { be x holds 5 }` → **ACCETTATA**+build | rifiuto "manca return" | **MEDIA** — manca l'analisi del return-path |
| **runtime safety** | `5/0`, `List.head(empty)`, `Vec.get(empty,99)` → costruiscono | comportamento definito (errore/sentinella, non UB) | **DA VERIFICARE a runtime** |

Comportamento CORRETTO (rifiuto pulito): arità sbagliate, type mismatch, `for-every` su number, moduli interni (`Map`/`Log`/`Spawn`), unknown fn/var/mod, nomi riservati come ident, `if` senza else, place vuoto senza contesto.

## Note (non-bug, da chiarire)
- **`Map` e `Log` non sono moduli di superficie**: solo `HashMap`/`HashSet`/`XSet` sono registrati in `stdlib_runtime.ml`. I `Map__*`/`Log__*` sono livello-emit (interni). La mappa pubblica è `HashMap`. Le sonde `map_get`/`log_write` erano su moduli non pubblici → non bug. **Per il libro**: documentare `HashMap`, non `Map`.
- **`sym` (inverso di cammino) → v1.2** (deciso da Antonio): `~` è bitwise, non negazione d'intervallo (`(p @ (~ I0))` → parse error). Confermato in `todo-1.2.md` B3.
- ✓ verificati all'esecuzione (batch 1): `HashMap`, `HashSet`, `Vec`, `VoyagerList` → set/add → get/contains corretti (exit 0).
- `examples/false_coherence.yon` → `COMPILE_FAIL` (frontend). È un **negative mal posizionato** in `examples/`: il reject è corretto, ma il file dovrebbe stare in `regression/yon_tests/negative/`. Sistemazione, non bug.

## Verificati ALL'ESECUZIONE (non solo emit) — registro positivo
- cubical/HIT/Glue di superficie: `comp`, `hcomp` (faccia singola), `transport(ua(id))`, `transport(ua(succ))`→riduce al valore, `hit_elim` (S¹→42), `ind_path`/J, somme. Tutti exit atteso. Il "marker `__equiv_fwd`" **riduce** fino al numero: nessuno stuck sulle superfici testate.
- corpus sciolto examples: arena/collections/math/string/vec/while/iter/produce-emit/heyting/patterns/spawn/stream/wire… COMPILE=ok + run senza crash (correttezza per-file da incrociare con `baseline_exitcodes.txt`).

## stdlib type-safety lasca agli argomenti — load-bearing, NON un fix da una riga
| caso | osservato | atteso | gravità |
|---|---|---|---|
| **`Math.sqrt("text")` accettato** | `check_args` (tycheck.ml ~1894) ha un ramo "accept all — proper polymorphism": al posto di parametro CONCRETO non confronta il tipo dell'argomento | rifiuto `text` vs `number` | **BASSA — by design, deferita** |

**Cosa ho provato e perché l'ho ritirato (niente verde finto).** Ho stretto `check_args`: ai parametri concreti, `Dispatcher.type_equal pty aty` o errore. `f_stdlib_badarg` veniva rifiutato pulito — ma il gate ha mostrato **8 esempi del corpus rotti** (`stdlib_extended`, `syslog_demo`, `system_io`, `v1_control_flow`, +4). Non sono 8 bug: è il **modello a handle-f64**. In Yon una stringa, una lista, un place sono *tutti* `f64` a runtime; il typing agli argomenti stdlib è volutamente lasco perché il boundary è dinamico. L'accept-all è **load-bearing** e, di fatto, intenzionale.

**Conclusione.** La `Math.sqrt("text")` è una *conseguenza del design* (typing lasco sul boundary f64), non un buco chiudibile senza:
1. un audit completo delle firme stdlib in `stdlib_runtime.ml` (separare i parametri davvero `number` da quelli `tunk`/handle), **e**
2. un raffinamento di `Dispatcher.type_equal` per i casi handle↔number legittimi.

Lavoro grande, valore modesto (intercetta solo letterali palesemente errati) → **deferito a v1.2**, ledger `todo-1.2`. Revert applicato: `tycheck.ml` == commit 321-verde (diff vuoto vs HEAD).

## tycheck: il tipo del RETURN IMPLICITO (tail) non e' verificato (silent-accept, DEFERITO)
Riformulazione precisa dopo lettura di desugar. NON e' "manca return su ogni path": Yon ha il **return implicito** — `desugar_stmt_or_return` (desugar.ml:1205) usa l'ultimo statement del corpo come valore di ritorno (`SReturn e -> desugar_expr e`, `other -> desugar_stmt other`). Quindi `fun f() -> number { let x holds 5 }` ritorna implicitamente 5: CORRETTO, non va rifiutato.

**Il buco vero.** `check_stmts_accum` (tycheck.ml:2315) passa `expected_return` a ogni statement ma SOLO l'arm `SReturn` (2089-2090) lo verifica. Il valore del **tail implicito** (ultimo statement non-`SReturn`) NON viene confrontato con `expected_ret`. Cosi' `fun h() -> Account { let y holds 3 }` type-checka: il tail produce 3 (number), ma il tipo dichiarato e' Account (un place) -> mismatch number/place non rilevato -> miscompila/build-fail a valle.

**Fix corretto (mirror di desugar, NON "richiedi return esplicito").** Aggiungere `check_implicit_tail_return env ctx (last_stmt) expected_ret`, chiamato in `check_fun_decl`/`_accum` quando `fn_return = Some rt` e l'ultimo stmt non e' `SReturn`. Deve inferire il tipo del valore che `desugar_stmt <tail>` produce — costrutto per costrutto, rispecchiando ESATTAMENTE desugar.ml (SLet standalone, SCall, SNew, SWhen, loop, ...) — e confrontarlo con rt. Dove desugar produce Unit (loop/effetto senza valore) e rt e' un tipo concreto -> rifiuto.

**Prerequisito.** Tracciare `desugar_stmt` per OGNI costruttore di stmt (cosa lowera come valore quando e' tail), poi scrivere il check che gli corrisponde 1:1. **Rischio corpus: ALTO** (classe degli 8-esempi). Va misurato su pytest 321 in loop iterativo. Decisione: farlo come task focalizzato con tracing completo di desugar_stmt + gate iterativo, NON a colpo singolo non misurato.

## INVENTARIO AUDIT — cosa resta da battere (stato a wave 6 + cubical/universi)
### Già auditati e chiusi
Frontend: tycheck, desugar, emit_mlir, builtins, reduce, subst, ast, sheaf, heyting, hit_env, cubical, cubical_bindings, carrier, catt_r_yon (parziale: preso il bug universi), naturality_symcheck, stdlib_runtime.
Runtime: yon_rt, yon_rt_hsh, yon_arena, xleech2_coord, xleech2_heap.

### DA AUDITARE — alto valore (soundness / memory-safety)
Frontend (cuore tipi/inferenza, ancora intatto):
- `dispatcher.ml` — dispatch di `type_equal`, centrale per ogni uguaglianza di tipi. Mai auditato a fondo.
- `hm_infer.ml` — inferenza HM (qui viveva il polyclash).
- `ty_subst.ml` — unificazione. **FLAG CHIUSO nel codice (verificato 2026-07-01):** l'occurs-check c'è (`unify` fa `if occur_check n t then raise (Unify_failure (UOccurCheck ...))`), quindi niente sostituzione ciclica → `apply_subst` termina; il silent-pass `TyVar _, _ -> empty_subst` è stato rimosso (ora `raise (Unify_failure (UMismatch ...))`). Resta solo `TyPrim "unknown"` che unifica con tutto: escape-hatch graduale deliberato, non un buco. Il modulo resta comunque da auditare a fondo per il resto.
- `core_check.ml` — core-checker del kernel.
- `type_erase.ml` — erasure (correttezza a runtime).
- `prop_eval.ml` — valutazione Ω (visto solo in parte dall'agente heyting).

Runtime (Leech/memoria non battuti):
- `xleech2_mphf.c` — minimal perfect hash, indicizzazione.
- `xleech2_handler_stack.c` — stack degli handler.
- `yon_curtis_canon.c` — canonicalizzazione Curtis.
- `yon_mmap.c` — wrapper mmap.

### Secondari / bassa priorità
`move_engine`, `sct`, `site`, `inline_seq`, `method_sugar`, `module_prefix`, `package_layout`, `manifest`, `place_visibility` (già false alarm), `leech_theta`; tooling non-soundness (`yon_lsp`, `yon_doc`, `yon_lint`, `yonfmt`, `pretty`, `diagnostics`). `test_*`/`*_demo`/`run_example`: harness, skip. `locally_nameless.ml`: SOSPESO, non in build.

### Prossimo cluster consigliato
Cuore tipi: `dispatcher` + `hm_infer` + `ty_subst` + `core_check`. È lì che vive la correttezza del sistema di tipi. (Il buco storico di `ty_subst` è chiuso — vedi sopra; resta debito di copertura, non un bug aperto.)

## DA FARE (prossimo batch project-mode)
### place collision tra world — chiave per nome nudo (HIGH soundness)
`manifest.ml:assign_place_worlds` riceve `world_of_place : string -> string option` costruito dal driver (`yoner_emit_mlir.ml` ~328) keyando una `Hashtbl` per **nome nudo** del place. Due `place Foo` in space/world diversi collidono → last-write-wins → entrambi i `TopPlace Foo` legati allo stesso world → uno controllato contro la sheaf SBAGLIATA. Fix: identità del place = (space, place) — il filesystem È la dichiarazione — oppure rifiutare nomi-place duplicati cross-world a collection time (come l'unicità dell'entry, gia' controllata). File: driver `yoner_emit_mlir.ml` + eventuale helper in manifest.

### return-implicito-tail in tycheck (vedi sezione dedicata sopra)
Il tipo del valore di return implicito (ultimo stmt non-SReturn) non e' confrontato con expected_ret. Regression-prone, mirror di desugar_stmt, gate iterativo.

## FATTI in questo batch
- manifest world_decl_of: carry-through di tutte le costruzioni (no piu' collasso → quotient non piu' droppato).
- manifest parse_file: Sys_error → Manifest_error (yon.toml directory/illeggibile → errore pulito).
- package_layout walk: Sys.readdir/is_directory guardati (dir illeggibile/symlink rotto → skip+warning, no crash).

## yon_xcoord_to_int24: disaccordo semantico con yon_xcoord_type (Leech, non memory-safety)
Trovato dal test C `test_unit_coord_decode` (sweep su 2^21/277 probe). `yon_xcoord_to_int24` documenta "ritorna -1 se v non è un type-2 short decodificabile", ma il decoder `gen_xi_leech_to_short` è più permissivo del classificatore `yon_xcoord_type` (gen_leech2_subtype): per alcuni `v` con `type(v)!=2`, `to_int24` decodifica (ritorna 0). **Non è un OOB** — le guard-lane oltre la 24 restano intatte e ogni decode resta in {-4..4} (memory-safety OK). Nel path raggiungibile `to_int24` è chiamato solo su short già validati type-2 (la validazione type-2 avviene a monte), quindi il disaccordo è **latente**. Da chiarire: o `to_int24` deve rifiutare i non-type-2 per rispettare il suo contratto doc, o il doc va corretto. Priorità BASSA (matematica Leech specialistica). Il test conta i disaccordi (`semantic-disagree=N`) ma non fallisce su questo.

## dispatcher: type_equal cieco agli endpoint per TyPathP (stessa classe del TyId, non chiuso)
Trovato costruendo i negativi Yon. `Dispatcher.type_equal` intercetta `TyId/TyId` PRIMA del dispatch e ne confronta gli endpoint (fix fatto in precedenza, dispatcher.ml:360-367), ma `TyPathP` NON ha l'intercettazione equivalente: passa per `lift_to_cubical` (dispatcher.ml:145-159) che riscrive gli endpoint a placeholder `__endpoint_x/__endpoint_y` → due `PathP(i,A,x,y)` che differiscono SOLO negli endpoint vengono giudicati uguali → un programma cubicale mal-tipato sui PathP potrebbe essere accettato. Reachable solo via uso PathP di superficie (nicchia, avanzato). Fix: aggiungere un arm `TyPathP/TyPathP` in type_equal che confronta carrier + endpoint (come il TyId), prima del dispatch. Priorità BASSA. (Per questo il negativo `neg_pathp_endpoint` è stato saltato: oggi verrebbe accettato → negativo rotto.)

## Spawn__child_exit / yon_rt_spawn_child_exit non marcati noreturn (robustezza, basso)
Trovato costruendo il nodo LLVM child_exit. `yon_rt_spawn_child_exit` fa `_exit(0)` (yon_rt.c:2344) ma NON è dichiarato `noreturn`, e emit_mlir non emette `unreachable` dopo la chiamata. Conseguenza: l'ottimizzatore e il lettore dell'IR non sanno che il controllo non torna; il continuation del parent appare raggiungibile dopo il fork-child. Non è un bug attivo (a runtime _exit termina davvero), ma è una forma IR meno sicura e ottimizzabile. Fix: marcare `Spawn__child_exit`/`yon_rt_spawn_child_exit` `noreturn` (attributo) ed emettere `unreachable` dopo la call nel ramo child. Priorità BASSA. (Il test child_exit oggi asserisce l'invariante più debole "il risultato non viene consumato"; si stringe da solo quando il fix landa.)

## topos T at Space: place interni senza world — RISOLTO
Era: `topos T at Space` non assegnava il world ai place inline dell'objects-block (restavano __INFER), mentre `in W` sì. Causa: il ramo TopTopos di `Manifest.assign_place_worlds` (e desugar:2203) gestiva solo `td.tp_world` (in W), non `td.tp_at_space`. FIX: aggiunto il fallback `at Space -> world_of_space wm sp` in assign_place_worlds (param opzionale `~world_of_space`, passato dal driver yoner_emit_mlir dove `wm` e' disponibile). Allineato al modello toml+filesystem (space dal filesystem, world dallo [world.X] spaces del toml). Test: examples/c_topos_at_space compila. Gate 746 verde.

