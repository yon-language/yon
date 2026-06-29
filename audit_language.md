# Yon — Audit del linguaggio

**Data:** 2026-06-19 (riallineamento allo stato su disco, sessione swarm Claude+Codex)
**Commit di riferimento:** `6327636` (`parser: unify the value-receiver method-call form`), `main`, più working-tree non committato (loop swarm #A/#B/#1). Il commit `f3afc90` citato nelle note precedenti **non esiste nel repo** (`git cat-file -t f3afc90` → fatal).
**Scope:** audit di Yon *come linguaggio* — per ogni feature, lo stato reale di superficie e kernel, classificato come risolto / parziale / metadata dichiarato / futuro / debito, con `file:riga` e oracolo a sostegno.

> **RIALLINEAMENTO 2026-06-19 (sessione swarm) — questa nota ha precedenza sulle due note "terzo/quarto giro" sotto, che erano avanti rispetto all'albero.** Verifica dal codice su `main` (HEAD `6327636` + working-tree):
> - **Debito #1 (sheafification): PARZIALE, non chiuso.** Il reject di fascio per il quoziente è cablato in `tycheck.ml` `check_view_decl` (NON `check_place_decl`) e morde sulle **view** su `world Q = W / Rel`: una `show f = e` la cui espressione legge un campo più fine di `Rel` è respinta a compile time (exit 3). `sheaf.ml` espone `quotient_canon` (canon = `(.Rel)`, via `__field_Rel`) e `field_factors_through`; **non** esiste `place_violations`. File reali: `regression/yon_tests/negative/sheaf_quotient_view_reject.yon` (exit 3), `prove/sheaf_quotient_view_ok.yon` (exit 0), `negative/sheaf_quotient_view_impure_reject.yon` (exit 3, frontiera impura). I file `sheaf_quotient.yon`/`sheaf_quotient_ok.yon` citati prima **non esistono**. Le **operazioni** (Stadio 2) sono **ancora aperte**: un `op_sig` non ha corpo a `check_place_decl`, serve la risoluzione op→arrow implementante (giro di design separato). Frontiera nota e benigna: una show-expr impura cade in `desugar_expr_pure = None` → reject, ma è **shadowed** dalla disciplina degli effetti (la stessa expr è respinta anche su un world non-quoziente; misurato).
> - **Orfane `sheaf_covers`/`sheaf_gaps`/`all_forced_pieces`: ora effettivamente rimosse** da `catt_r_yon.ml` (loop swarm #1). La nota "terzo giro" le dava per rimosse quando non lo erano; ora il claim è vero.
> - **Debito #6 (runtime container-verificato): non riproducibile sul Mac attuale.** `./regression/run_regression.sh` qui è rosso: `spawn_parallel_collect` va in **timeout** (exit 124), e cross-space fallisce (`ledger rc=85`, `loop_remote rc=247`, `wire rc=248`, `subscriber does not compile`). Provato pre-esistente (identico con/senza le patch di sessione), quindi è debito runtime aperto su questa macchina (#5/#6), non una regressione. La pytest gira (`262 passed`, unico fail il timeout spawn).
> - **Ambiente test**: `pytest==9.1.1` nel `.venv` esistente, pinnato in `regression/requirements-dev.txt`; `.pytest_cache/` ignorato.
> - **Non ri-verificato in questa sessione**: i Debiti #2–#4 (cubical), #7–#14 e i dettagli di Batch 6/7 restano come scritti sotto, NON ricontrollati dal codice oggi. Trattarli come "da riconfermare", non come verificati.

> **Nota di aggiornamento (sessione 2026-06-18, quarto giro — riallineamento).** Verifica dei debiti *dal codice* prima di proseguire: l'audit era **stale** su tre voci. **#10** (`emit_ty` sotto `Carrier.t`) è **già chiuso** — `ty_to_mlir = Carrier.to_mlir ∘ Carrier.of_core_ty`, ed `emit_ty`/`core_ty_to_mlir_simple` ne sono alias (la vecchia divergenza schema/valore era su rami morti, behavior-preserving). **#9** (copertura): `geom_morphism` ha **6 esempi** (non 0); resta debole solo `topology` (1)/`reduction` (2) — declassato a minore. **#11**: il `failwith` stop-gap è ora un **reject pulito** (decreto 2026-06-17); resta non lowered solo la *feature* higher-order. Conteggio reale: **11 aperti, 3 chiusi (#1, #6, #10)**.

> **Nota di aggiornamento (sessione 2026-06-18, terzo giro).** Il **Debito #1 (sheafification) è CHIUSO.** Il reject di fascio per il generatore-quoziente è cablato nel `tycheck` (`check_place_decl`, canale `cr_errors`/exit 3) e verificato **end-to-end da sorgente**: un place su `world Q = W / Rel` con un campo non invariante sotto `Rel` è respinto a compile time (exit 3, `negative/sheaf_quotient.yon`), uno con i soli campi invarianti compila (exit 0, `prove/sheaf_quotient_ok.yon`). Coproduct e subset sono **vacui sui campi** (documentato in `sheaf.ml` e testato, nessun reject vacuo scritto: solo il quoziente vincola i campi). Le funzioni orfane e falsificate (`sheaf_covers`/`sheaf_gaps`/`all_forced_pieces`) sono **rimosse** da `catt_r_yon.ml`. La sezione Batch 4 e i debiti aggregati riflettono la chiusura.

## Metodo

Ogni claim è verificato dal codice (grep, oracolo del compilatore, test eseguiti), mai dalla memoria. Le prove sono di tre tipi: oracoli OCaml eseguiti (`test_*.exe`), emit del corpus (`yoner_emit_mlir.exe` sugli `examples/*.yon`), e ispezione del binario del dialect (`topos-opt`). Convenzione: «emit exit 0» significa che la pipeline frontend → MLIR completa senza errori; i due reject del corpus (`closed_morphism_capture`, e un secondo) sono intenzionali.

Legenda stati:

- **risolto** — implementato e verificato end-to-end al livello indicato.
- **parziale** — il nucleo c'è; un percorso specifico è dichiarato incompleto.
- **metadata dichiarato** — parsato e accettato, vive come metadata kernel, non genera codice (scelta esplicita).
- **futuro** — previsto dal design, non ancora presente.
- **debito** — scarto tra il claim e ciò che è effettivamente cablato.

---

## Batch 1 — Algebra dei tipi e uguaglianza

L'algebra `ty` ha 11 costruttori (`TyType`, `TyArrow`, `TyPi`, `TySigma`, `TyId`, `TyDirUniverse`, `TyEl`, `TyPlace`, `TyStream`, `TyGlue`, `TyPathP`). `TyBase` rimosso (unico residuo: un commento in `builtins.ml:656`). Contrazione η_Σ surjective-pairing `Pair(Fst t, Snd t) ⤳ t` (`reduce.ml:455`, size-decreasing). Uguaglianza **fuel-free**, δ-conversione SCT-gated (`dispatcher.ml:255`): terminazione per costruzione, non per cap.

| Voce | Stato | Prova |
|---|---|---|
| Algebra `ty` a 11 costruttori, `TyBase` rimosso | risolto | `ast.ml`; residuo solo in commento |
| η_Σ surjective pairing | risolto | `reduce.ml:455`; `test_eta_sigma` 7/7 |
| Uguaglianza fuel-free δ-SCT-gated | risolto | `dispatcher.ml:255`; commit `33561d9` |
| Oracoli di base | risolto | `test_o6` 4/4, `test_motive` 8/8, `test_path_core` 15/15, `test_isequiv` 11/11, `test_hit_elim` 4/4 |
| `World` reificato come termine del Core (sito `C(W)`) | risolto | `ast.ml:99` (`World of world_decl`), `ast.ml:161` (`world_decl`, `w_generators`); `World` chiuso/inerte come `Place` |
| `site_generator` + topologia `J` dal world | risolto | `ast.ml` (`GenCoproduct/Quotient/Coequalizer/Subset`; il prodotto NON è generatore); `site.ml:26` `get_J`, `:31` `is_trivial`, `:37` `same_topology` |
| `TopWorld` reifica il world di superficie nel sito | risolto | `desugar.ml:1464` `desugar_world_decl`, `:1922` `TopWorld` (non più no-op); `reduce.ml:36` `ctx.worlds`, `:84` `declare_world` |
| Oracolo del sito | risolto | `test_world_site` 32/32 (12 logica `J` + 7 desugar + 6 layout + 7 sheaf); `test_site.py` 28/28 |

**Crediti:** nucleo dei tipi e giudizio di uguaglianza solidi e terminanti per costruzione. Il world è ora un **oggetto di prima classe** del Core (il sito `C(W)`), non più metadata: la sua topologia `J` è letta dalle costruzioni con cui è dichiarato.
**Debiti:** nessuno aperto sull'algebra dei tipi.

---

## Batch 2 — HoTT / cubical

Superficie dedicata (`lexer.mll:223`, `parser.mly:1413`): `Id`, `refl`, `ind_path` (J), `El`, `quote`, `el_match`, `hit`, `plam` (`<i>e`), `p@i`, `PathP`. Call-form riconosciute via tabella dispatch (`cubical_bindings.ml:293`): `transport`, `glue`, `unglue`, `ua`, `equiv` — non keyword. Gate `isEquiv` reale: `ua` esige equivalenza strutturata (Σ con freccia in testa), rifiuta funzione nuda (`cubical_bindings.ml:169`). Il kernel cubical è completo e provato: **78 PASS**.

| Voce | Stato | Prova |
|---|---|---|
| Superficie `Id`/`refl`/`ind_path`/`El`/`quote`/`hit`/`plam`/`PathP` | risolto | `parser.mly:1413` |
| Gate `isEquiv` per `ua` | risolto | `cubical_bindings.ml:169`; `tycheck.ml:1547` |
| Kernel cubical (`TyPathP`/`Transp`/`TyGlue`, β di J) | risolto | `reduce.ml:438`; 78 PASS |
| Typing dipendente `ind_path` | risolto | `tycheck.ml:1150` |
| `glue`→`Glue` opaco, `unglue`→unknown (base non tracciata) | parziale | `cubical_bindings.ml:138,160` |
| `ind_path`/J neutro in endpoint `Id` type-level non normalizza finché non-`refl` | parziale | debito §16; `j_computes` vive in `runtime/` |
| `ua`/`Glue` end-to-end da superficie con mappe liftate | parziale (known boundary) | richiede δ-conv su quel percorso |

**Crediti:** kernel cubical completo; gate di equivalenza genuino.
**Debiti:** esposizione di superficie di `ua`/`Glue`/`transport`/`Path` ancora incompleta; `glue`/`unglue` con base non tracciata staticamente.

---

## Batch 3 — Logica interna (Ω di Heyting)

**Finding fondazionale e correzione applicata in questa sessione.** Il modulo `heyting.ml` dichiarava un'algebra di Heyting ma implementava **Kleene K3**: implicazione materiale `¬a ∨ b` (`½→½ = ½ ≠ ⊤`, violando `a→a = ⊤`) e negazione involutiva (`¬½ = ½`). La stessa logica errata era replicata nel dialect MLIR (`TopOps.td:787`: *«a -> b == NOT a OR b»*), con in più un'eliminazione della doppia negazione `NOT(NOT(x)) → x` (unsound in Heyting).

**Strada A (decisa da Antonio):** il frammento diventa la logica di **Gödel G3** — la catena a tre elementi *come* algebra di Heyting: `h_imp` come residuo (`½→½ = ⊤`, `½→⊥ = ⊥`), `h_not` regolare `φ→⊥` (`¬½ = ⊥`, non involutiva). Applicata su **entrambi i lati**:

| Lato | Intervento | Prova |
|---|---|---|
| Eval (`heyting.ml`) | `h_imp` residuo Gödel, `h_not` regolare, commenti | `test_heyting` **8/8** (aggiunzione su 27 triple, `a→a=⊤`, `¬=→⊥`, DNE fallisce, non-Kleene) |
| Nativo, fold costante (`HeytingShortCircuit.cpp`) | rimossa doppia negazione, `¬U=F`, tabella IMPLIES Gödel | `topos-opt`: `U=>?U → present`, `!?U → false` |
| Nativo, lowering dinamico (`LowerToposToStandard.cpp`) | `not`/`implies` ricablati a Gödel | white-box: `¬%arg` senza più la costante `U` |
| Dialect `.td` | commenti `heyt_not`/`heyt_implies` riallineati | — |

Operatori di superficie: famiglia classica (`=>` → `(not a) or b`, materiale *by design*) e famiglia intuizionista col `?` (`=>?`, `&&?`, `||?`, `!?`) che passa per `Heyting.*`. `h_and` (min) e `h_or` (max) erano già corretti e non sono stati toccati.

Build verde su frontend (dune) e dialect (make). Emit del corpus 65 ok / 2 reject = baseline; nessun esempio attiva la differenza Kleene/Heyting.

**Crediti:** il frammento Ω ora *è* Heyting genuino (Gödel G3), coerente con la decisione fondazionale (Ω dal classificatore dei sottooggetti, Ł₃ scartato); copertura test creata ex novo.
**Debiti:** la regressione **nativa** completa end-to-end (emit → topos-opt → llc → run su tutto il corpus) è da rifare sul Mac (richiede rebuild del runtime); sul corpus il rischio è nullo.

---

## Batch 4 — Effetti e geometria

Costruzioni dichiarabili: `world` (+ quotient), `place` (+ `objects {}` block, + error-as-place), `move`, `reduction` (handler di effetti algebrici), `geom_morphism` first-class (`pull`/`push`), `topology`, e i quattro kind di handle.

| Costruzione | Stato | Prova |
|---|---|---|
| `world` (+ quotient) | risolto, 28 esempi | `capability_flow_demo`, `kw_merge_move` exit 0 |
| `place` (+ `objects {}`) | risolto, 23 esempi | emit exit 0 |
| `move` (handle) | risolto, 4 esempi | `kw_merge_move` 456 righe, exit 0 |
| `reduction` (handler effetti) | risolto, 1 esempio | `Place__op → Reduction__op` (`emit_mlir:48`) |
| `handle` (move/reduction/morph/view) | risolto | `handle_lambdas` exit 0 |
| `geom_morphism` (first-class, `pull`/`push`) | risolto end-to-end, 0 esempi | desugar → cella diretta con witness reale (`Refl`→identità, `desugar.ml:1956`); emit → registrazione runtime (`yon_rt_register_geom_morphism`); test `main.ml:4320` |
| error-as-place (`place P on error E`) | presente | `error_decl → TopPlace`; `error_morphism.yon` |
| `x becomes e` (cella Space) | risolto + lowered | `Space__set` / `__space_update_here` (`desugar.ml:1186,1755`); `tycheck.ml:1862` |
| `x.f becomes e` (sezione place) | rigetto by-design | `failwith`: sezioni immutabili, mutare via celle Space (`desugar.ml:1757`) |
| disciplina closed-morphism | risolto (reject atteso) | `closed_morphism_capture` exit 3 |
| `topology` / `pullback` / `pushout` | **debito** (vedi sotto) | metadata dichiarato, sheafification non cablata |

### Sheafification — PARZIALE (reject di fascio per le VIEW su quoziente; operazioni aperte)

> Riallineato 2026-06-19: la nota "CHIUSA" qui sotto è superata. Stato reale: il
> reject è cablato per le **view** (`check_view_decl`), non per i place
> (`check_place_decl`); le **operazioni** sono lo Stadio 2, ancora aperto. La
> tabella sotto è corretta nei nomi reali (vedi nota di riallineamento in testa).

**Aggiornamento di sessione.** La sheafification descritta qui sotto come «aspirazionale a tre livelli» è stata **ri-fondata**. La vecchia condizione non era «giusta ma non cablata»: era **mal posta**.

- **Falsificazione (fase epistemica).** La pseudo-condizione `sheaf_covers`/`sheaf_gaps` (`catt_r_yon.ml:1379,1387`) confondeva i campi del prefascio (la fibra) con i pezzi del covering (la base del sito), riduceva il forcing a `List.mem`, e — soprattutto — ometteva l'**overlap**, che è la separazione, il cuore del fascio. Resta **orfana e ora superata**: va **rimossa**, non cablata (Debito #1 aggiornato).
- **Nuova base (su `main`).** Il sito è il `world`; gli oggetti sono gli abitanti/componenti, e la topologia `J` **emerge dalle costruzioni** (`coproduct` → cover disgiunto, `quotient` → le classi coprono, `subset` → inclusione densa; il `product` è un limite e **non** copre). Formulazione Yoneda: `P` è fascio ⟺ manda i colimiti-covering in limiti (`P(colim) ≅ lim`).
- **Motore del predicato (risolto, testato).** Per il generatore-quoziente `world Q = W / Rel`, `P` è fascio ⟺ ogni campo **fattorizza attraverso** `canon : W → Q` (proprietà universale del coequalizzatore): `field = s̄ ∘ canon`. `sheaf.ml:68` `field_factors_through` lo decide **costruendo** `s̄` (astrae `canon x` da `field x`; se `x` sparisce, fattorizza), non cacciando coppie divergenti. È la disciplina del content-addressing (un valore dipende solo dalla sua classe, mai dall'indirizzo) portata a compile time. Lato sound di Rice. `test_world_site` (7 casi sheaf): il controesempio `salary` vivo in ogni regime — `f(cohort u)`→fascio, `u` diretto→reject, costante→fascio, mista→reject, `Rel`=id→`Sh=PSh`, `Rel` totale→solo costanti.

| Voce | Stato | Prova |
|---|---|---|
| Vecchia pseudo-condizione `sheaf_covers`/`sheaf_gaps`/`all_forced_pieces` | **rimossa** | falsificata e orfana; eliminata da `catt_r_yon.ml` (`sheaf-closure`) |
| Sito = world, `J` dalle costruzioni | risolto | `site.ml:26`; `test_world_site` 12/12 logica `J` |
| Motore di fascio per il quoziente (fattorizzazione `canon`) | risolto | `sheaf.ml` `field_factors_through`; 7/7 casi sheaf |
| Aggancio di `canon` alla superficie (VIEW) | **risolto** | `Rel` = campo di `W`, `canon = λs. s.Rel` (`__field_Rel`); `sheaf.ml` `quotient_canon` (NON esiste `place_violations`) |
| Reject nel `tycheck` (compile time, exit 3) | **risolto (view)** | `tycheck.ml` `check_view_decl`; canale `cr_errors`/exit 3; usa `Desugar.desugar_expr_pure` (with_saved_state + is_pure_expr) |
| Verifica end-to-end da sorgente | **risolto (view)** | `negative/sheaf_quotient_view_reject.yon` → exit 3; `prove/sheaf_quotient_view_ok.yon` → exit 0; `negative/sheaf_quotient_view_impure_reject.yon` → exit 3 |
| Reject per le OPERAZIONI | **debito aperto (Stadio 2)** | `op_sig` senza corpo a `check_place_decl`; serve risoluzione op→arrow implementante |
| Generatori coproduct/subset | **vacui sui campi (documentato)** | `site.ml` `is_trivial`/`get_J`; solo `GenQuotient` vincola i campi |

Il vecchio quadro a tre livelli (statico orfano / lowering C++ del covering sovrapposto / trigger simulato) è **superato**: il ramo C++ (`LowerToposToStandard.cpp`, glue del covering) era fuori scope — un move si realizza via `xcoord`/Co₀, non per gluing — e il trigger-stringa del Test 170 non fa più parte del disegno. La sheafification è **chiusa**: motore + aggancio + reject end-to-end per il quoziente (l'unico generatore con contenuto sui campi), coproduct/subset documentati vacui, orfane rimosse. Il `canon` ha casa nel `world.yon` di una cartella-quoziente (Batch 8) quando il filesystem sarà cablato; il reject di oggi opera già sulla forma esplicita.

**Nota di design (Antonio):** `x holds …` è inizializzazione/dichiarazione, `x = …` è l'assegnazione di superficie, `becomes` deve restare **solo negli strati inferiori**. → **Fatto (2026-06-26):** `becomes` rimosso dalla superficie, `=` è il token (`lexer.mll:321`); il nodo AST resta `SAssignBecomes` (nome interno). Vedi Debt #8 (chiuso).

**Crediti:** nucleo effetti/geometria solido; `geom_morphism` end-to-end; `becomes` coerente con l'immutabilità delle sezioni.
**Debiti:** sheafification **chiusa** (vedi sopra); copertura esempi debole su `geom_morphism` (0), `reduction` (1), `topology` (1).

---

## Batch 5 — Concorrenza

Modello multi-processo prefork (PostgreSQL/Apache), isolamento per costruzione, nessun thread intra-processo.

| Costruzione | Stato | Prova |
|---|---|---|
| `spawn` / `promote` / collect | risolto (runtime), 1 esempio | facade `Spawn__open/role/index/promote/child_exit/join_stream` (`yon_rt.c:2421`); fork multi-processo, child `_exit`; `spawn_parallel_collect.yon` exit 0; `test_spawn_collect.c` |
| `wire` (DTO transport) | risolto (runtime), 1 esempio | `Wire__subscription_stream`(`_dto`) (`yon_rt.c:1666`); descrittori schema tipati (`emit_mlir:134`); `wire_eof.yon` exit 0 |
| modello IPC | risolto (runtime), deciso | `yon_rt.c:1765-1908`: una shared request-queue per Space (multi-producer) + private reply channels, mutex/condvar `PTHREAD_PROCESS_SHARED` (Linux + macOS M1), robust contro morte peer con lock tenuto |
| `space` (heap logico) | risolto single-process | `g_spaces[]`, `yon_rt_heap_for`, `L2_SEPARATE`; `Space__make` emesso |
| multi-process / remote node per Space | futuro | `parser.mly:550` |

**Crediti:** concorrenza solida e già decisa nel dettaglio (Idraulica v2 realizzata: request-queue condivisa + reply channel privati su mutex/condvar `PROCESS_SHARED` robusti).
**Debiti:** estensione multi-nodo/remoto futura; esecuzione end-to-end del runtime non container-verificata (richiede rebuild della catena Leech/Curtis/mmgroup).

---

## Batch 6 — Carrier → emit

Il rifattore foundational: `carrier : Place → Carrier.t` come funtore parziale, `type_erase` a monte, emit come printer di `Carrier.t`. `Carrier.t` è un'algebra astratta target-agnostica (`Scalar`/`Proposition`/`Section`/`Arrow`/`Struct`/`Opaque`, `carrier.ml:36`); il printer `to_mlir` (`carrier.ml:143`) è swappabile (MLIR oggi, WASM/C domani cambiando solo lui).

| Voce | Stato | Prova |
|---|---|---|
| Algebra `Carrier.t` astratta | risolto | `carrier.ml:36` |
| Funtore `of_core_ty : Place → Carrier.t` | risolto | `carrier.ml:70`; `NoCarrier` su 4 rami |
| Partialità = frontiera di erasure | risolto | `carrier.ml:113,128`; `type_erase` droppa a monte |
| `TySigma`-comprehension scarta la prova (zero-bit) | risolto | `carrier.ml:108` |
| `TyId` → witness cancellato (`refl x ≡ x`) | risolto | `carrier.ml:124` |
| Printer `to_mlir` swappabile | risolto | `carrier.ml:143` |
| `core_ty_to_mlir_simple` = thin wrapper sul carrier | risolto | `emit_mlir.ml:251`; Stage 1 behavior-preserving |
| Rigetto pulito della partialità a compile time | risolto | `emit_mlir.ml:253` |
| `type_erase` cancella type-argument universe-typed | risolto | `type_erase.ml:122` |
| `IdPlace` rimosso dall'AST | risolto | solo in commento `carrier.ml:119` |
| `emit_ty` (schema) non ancora printer del carrier | **debito** | `emit_mlir.ml:205`; coesiste col carrier (annidato vs appiattito) |
| `type_erase` higher-order | **debito** (stop-gap) | `type_erase.ml:84` `failwith` |
| `TyEl`-opaque `NoCarrier` | parziale | `carrier.ml:123`; legato al Batch 2 |
| `specialize_func`/`C.TyPlace` "morto" | non riscontrato | da ri-localizzare |

**Crediti:** rifattore realizzato — algebra astratta, funtore parziale con partialità confinata alla frontiera di erasure, printer swappabile, body lowering unificato e *behavior-preserving*. Carrier come funtore derivato, emit come mero printer.
**Debiti:** `emit_ty` (schema) non vive ancora sotto `Carrier.t` (unificazione parziale: arrow annidato schema vs appiattito body); `type_erase` higher-order è stop-gap con rigetto esplicito; `TyEl`-opaque è rete di sicurezza per il futuro Path/ua.

---

## Batch 7 — Runtime

Il livello dove il modello categoriale tocca il silicio. Verificato dal codice C e, per la prima volta, **eseguito nel container** (i `.o` mmgroup sono vendored e pre-compilati).

| Voce | Stato | Prova |
|---|---|---|
| Content-addressing FNV-1a 64-bit + dedup O(1), arena tile-based, mmap PRIVATE/SHM | risolto | `xleech2_heap.c:31-51` |
| MPHF bijettivo `xcoord↔idx` sui 196560 type-2 Leech vectors, senza tabelle proprie | risolto + **runtime verificato** | `xleech2_mphf.c`; `test_mphf`: 196560/196560 round-trip, 0 collisioni, full cover |
| Co₀ via mmgroup vendored (`gen_leech2_type`, mat24), mutex-serializzato | risolto | `xleech2_coord.c`; mmgroup linkato e funzionante |
| Curtis canon = LUT esatta precomputata (196560 entry), zero euristiche | risolto | `yon_curtis_canon.c` (generato da `tools_gen_canon.c`) |
| `XRel` = classe equivariante di type-2 vector, 26 ref a 2 bit in mantissa f64 | risolto | `yon_rt.c:4220-4238` |
| spawn multi-processo (fork) + IPC (request-queue + reply channel privati) | risolto + **runtime verificato** | `test_spawn_collect`: 3×10=30, no loss/dup/deadlock, queue cap 16<30 |
| `yon_rt_hsh.c` incluso da `yon_rt.c` (non TU autonomo) | osservazione | `yon_rt.c:7485` |
| Build platform-specific (`_GNU_SOURCE`/`_DARWIN_C_SOURCE`, `-include stdint`) | debito minore | portabilità |
| mmgroup `.o` pre-compilati (rebuild from-source non verificato) | debito minore | provenance |

**Crediti:** runtime research-grade reale e ora eseguito nel container — Leech lattice (196560 = kissing number), Co₀ via mmgroup, MPHF bijettivo a collisioni zero, content-addressing FNV, canonicalizzazione Curtis come tabella esatta. Niente euristiche né parametri liberi. Due prove runtime in questa sessione (MPHF + spawn).
**Debiti:** minori — portabilità del build e provenance dei `.o` mmgroup. Il debito #6 (esecuzione runtime non container-verificata) è **chiuso**.

---

## Batch 8 — Il filesystem come dichiarazione (nuovo)

Decisione di design di sessione: **un programma Yon è un albero di cartelle**, e il path porta l'ontologia che le keyword portavano. `cartella = world`, `file = space`, file sotto la radice = space nel world radice, e il file convenzionale `world.yon` porta solo ciò che il path non dice (abitanti, o la costruzione `= A + B` / `/ Rel` / `subset of`). Le keyword `world`/`space`/`in W` escono dalla superficie: restano come forma interna che il driver ricostruisce dal cammino e passa al desugar di oggi (surface sporco, kernel stretto). **Filesystem unica via** (deciso): la forma esplicita scritta a mano non è più valida; `main` vive in `src/main.yon`; i test si riscrivono come struttura (`test/...`).

| Voce | Stato | Prova |
|---|---|---|
| Deduzione `path → (world, space)` | risolto (primo mattone) | `package_layout.ml:33` `world_of`, `:45` `space_of`, `:59` `layout` |
| Ricostruzione della forma esplicita che il parser già accetta | risolto (primo mattone) | `package_layout.ml:89` `reconstruct`; `test_world_site` (6 casi layout): il testo ricostruito **parsa** |
| Integrazione nel driver (`walk_yon` deduce invece di concatenare piatto) | **debito (aperto)** | `yoner_emit_mlir.ml` cammina già `src/`, oggi concatena in uno scope piatto |
| Parser: eliminare le keyword `world`/`space`/`in` dalla superficie | **futuro** | la via unica le abolisce; il parser oggi le accetta ancora |
| Riscrittura del corpus (66 esempi + `yon_tests`) come struttura `src/` | **debito (aperto)** | conseguenza della via unica |
| `main` in `src/main.yon`, world radice implicito | deciso, non implementato | regola fissata |

**Crediti:** la struttura `src/` è quasi gratis — il `walk_yon` ricorsivo esiste già; il delta è dedurre `(world, space)` dal path invece che da keyword, e ogni file diventa un confine di namespace (lo space torna unità di isolamento, coerente col modello multi-processo). Primo mattone (deduzione + ricostruzione) fatto e testato.
**Debiti:** integrazione nel driver, eliminazione delle keyword dal parser, riscrittura del corpus, entrypoint — tutti aperti. È il filone più giovane; il punto di ricongiunzione con la sheafification è il `world.yon` di una cartella-quoziente, dove `world Q = W / Rel` darà finalmente un corpo a `canon`.

---

## Crediti aggregati

- Nucleo dei tipi e uguaglianza fuel-free SCT-gated: terminante per costruzione.
- Kernel cubical completo (78 PASS), gate `isEquiv` genuino.
- Logica interna ora Heyting genuino (Gödel G3) su eval e nativo, con copertura test.
- Effetti/geometria: `world`/`place`/`move`/`reduction`/`handle` end-to-end; `geom_morphism` con geometria reale (witness) e registrazione runtime.
- Concorrenza: modello multi-processo deciso e implementato a runtime (spawn fork, wire DTO, IPC request-queue + reply channel privati).
- Carrier → emit: funtore parziale realizzato, algebra astratta target-agnostica, printer swappabile, body lowering unificato e behavior-preserving.
- Runtime: research-grade reale e verificato nel container — Leech (196560), Co₀ via mmgroup, MPHF bijettivo a collisioni zero, content-addressing FNV, Curtis canon esatta; spawn multi-processo + IPC eseguiti.

## Debiti aggregati

| # | Debito | Batch | Tipo | Nota |
|---|---|---|---|---|
| 1 | Sheafification — **PARZIALE (2026-06-19)**: VIEW chiuse, OPERAZIONI aperte | 4 | parziale | reject di fascio per le view su quoziente in `check_view_decl` (exit 3), verificato da sorgente (3 test); orfane rimosse; Stadio 2 (operazioni) aperto — serve risoluzione op→arrow |
| 2 | `ua`/`Glue`/`transport`/`Path` non esposti end-to-end da superficie | 2 | feature | richiede δ-conv sul percorso |
| 3 | `glue`/`unglue` con base non tracciata staticamente | 2 | parziale | `Glue` opaco, `unglue` unknown |
| 4 | `ind_path`/J neutro non normalizza in endpoint type-level finché non-`refl` | 2 | parziale | `j_computes` in `runtime/` |
| 5 | Regressione nativa Heyting end-to-end da rifare sul Mac | 3 | verifica | rischio nullo sul corpus |
| 6 | Esecuzione runtime end-to-end — **APERTO sul Mac attuale (2026-06-19)** | 5 | verifica | `test_mphf`/`test_spawn_collect` ok in un container precedente, ma su questa macchina `run_regression.sh` è rosso: `spawn_parallel_collect` timeout (124), cross-space `rc=85/247/248` + `subscriber does not compile`. Provato pre-esistente. Riconfermare l'ambiente |
| 7 | Multi-nodo/remoto per Space | 5 | futuro | single-process oggi |
| 8 | ~~Token surface `becomes` da rivedere~~ **CHIUSO (2026-06-26)** | 4 | — | `becomes` non è più token surface: sostituito da `=` (`lexer.mll:321` EQ; 0 occorrenze `becomes`/`BECOMES` in lexer/parser). Il nodo AST `SAssignBecomes` resta come nome interno (lowering). La gerarchia voluta è atterrata: `holds`=init, `=`=assegnazione surface, `becomes`=solo strati inferiori |
| 9 | Copertura esempi debole su `topology` (1)/`reduction` (2) | 4 | minore | `geom_morphism` ora ha 6 esempi (risolto); resta poco) |
| 10 | ~~`emit_ty` (schema) non printer del carrier~~ **CHIUSO (quarto giro 2026-06-18)** | 6 | — | `ty_to_mlir = Carrier.to_mlir o Carrier.of_core_ty`; `emit_ty`/`core_ty_to_mlir_simple` alias; divergenza su rami morti |
| 11 | `type_erase` higher-order non lowered | 6 | feature | il `failwith` e ora un reject pulito (decreto 2026-06-17); resta la feature |
| 12 | `TyEl`-opaque `NoCarrier` unreached | 6 | futuro | live con Path/ua di superficie |
| 13 | Build runtime platform-specific + `yon_rt_hsh.c` non TU autonomo | 7 | minore | portabilità; provenance `.o` mmgroup |
| 14 | Filesystem-come-dichiarazione end-to-end (driver dedurre, parser senza keyword, corpus riscritto, `main`) | 8 | progetto | primo mattone fatto (`package_layout.ml`); resta l'integrazione |

**Conteggio (riallineato 2026-06-19, sessione swarm): 13 debiti aperti, 1 chiuso (#10).** Rettifica delle note precedenti dal codice: **#1 è PARZIALE** (view chiuse, operazioni aperte — Stadio 2), non chiuso; **#6 è APERTO sul Mac attuale** (spawn timeout + cross-space rossi, pre-esistenti), non chiuso; **#10 resta chiuso** (`emit_ty` sotto `Carrier`, in `main` — non ri-verificato oggi ma non contraddetto). Sostanziali: completare #1 (Stadio 2 operazioni), i cubical (#2–#4, serve δ-conv), il filesystem (#14); runtime (#5/#6/#13) e copertura (#9) minori/da-ambiente. Voci #2–#4, #7–#9, #11–#14 non ri-controllate in questa sessione: trattare come "da riconfermare".

## Prossimi batch

- **Sheafification:** ◐ parziale — VIEW chiuse (`check_view_decl`), OPERAZIONI aperte (Stadio 2: risoluzione op→arrow). Vedi Batch 4 e Debito #1.
- **Filesystem, integrazione (#14):** far dedurre al `walk_yon` `(world, space)` dal path invece di concatenare piatto; eliminare le keyword dalla superficie; riscrivere il corpus come struttura `src/`.
- **Batch 9 — Pipeline nativa:** emit → topos-opt → llc → ELF/ARM64, end-to-end.
