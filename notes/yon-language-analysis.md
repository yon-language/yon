# Yon — analisi del linguaggio (calibrata, 2026-07)

> Analisi onesta secondo il template a 15 sezioni. Regola: distinguo sempre
> **[REALE/TESTATO]** da **[PARZIALE]** e **[ASPIRAZIONALE]**. Nessun benchmark,
> adozione o feature inventata — dove non ho il dato, lo dico. È la versione che
> regge davanti a un revisore ostile, non il pitch.

---

## 1. Info generali

- **Nome**: Yon — a topos-oriented programming language.
- **Autore**: Antonio Mennillo (single author).
- **Licenza**: AGPLv3 (`LICENSE`).
- **Repo**: https://github.com/yon-language/yon
- **Versione**: v1.1 chiusa (kernel + tooling verificati); v1.2 in corso (completamento type-theory + hardening).
- **Estensione**: `.yon`.
- **Toolchain**: OCaml frontend → MLIR (dialetto "topos") → LLVM → eseguibile nativo; runtime in C.
- **Influenzato da**: Haskell/Agda/Coq (tipi, purezza), Rust (ownership/isolamento), Erlang (processi/isolamento), teoria delle categorie/topos.
- **Ha influenzato**: nessuno (progetto giovane, single-author).

---

## 2. Fondamenti teorici

- **Modello**: place = oggetto/prefascio (Site → Type); Space = processo (calcolo isolato); riduzione via kernel (R_Yon reducer + engine cubicale).
- **Sistema di tipi**: statico, forte. Dipendenti **del prim'ordine** in superficie [REALE]; nucleo cubicale (intervallo, Glue, hcomp/comp, transp, HIT) [PARZIALE — reale e testato sui casi chiusi, ma la prova di canonicità meccanizzata è aperta]; universi Russell `Type_n` + universo Tarski `U_omega` con `El(code)`.
- **Paradigmi**: funzionale (funzioni pure, effetti dichiarati via `visits`), categoriale (place/morfismi/nat-transform), concorrente (Space = processi isolati).
- **Logica**: **intuizionista** [REALE] — niente terzo escluso (l'`unknown` di Heyting non è decidibile; probato da `test_prop_eval`, Test 80).
- **Matematica sottostante**: teoria dei topos (place come prefascio su un sito), un frammento di HoTT/cubical (univalenza-via-Glue), Yoneda (il "testimone di pienezza").
- **Confine onesto**: Yon **non è un proof assistant**. I dipendenti di superficie sono prim'ordine; HoTT/cubical è reale ma parziale e non completamente esposto in superficie. La canonicità del frammento cubicale è un obbligo metateorico aperto (discharge via prova meccanizzata o citando la canonicità CCHM di Huber).

---

## 3. Sintassi di base

- **Entry point**: `fun main(): number { return 0 }`.
- **Commenti**: `/* ... */` (e `//`).
- **Blocchi**: `{ ... }`.
- **Binding locale**: `be x holds e` (dichiarazione, mutabile-una-volta); `x = e` (riassegnazione). *(modello "holds/=" A)*
- **Funzioni**: `fun add(x: number, y: number): number { return x + y }`; return implicito di coda (l'ultimo statement è il valore, verificato contro il tipo dichiarato da `check_implicit_tail_return`).
- **Effetti**: dichiarati nella firma — `fun do_emit(s: String): unit visits Output { return Output.print(s) }`. Il caller deve coprire gli effetti del callee (caller-covers-callee).
- **Primitivi**: `number` (f64), `money`, `text`/`String` (f64 handle), `boolean` (i1), `unit`, `proposition` (Ω di Heyting, tri-valore), `duration`, `heyt_int<N>`.
- **Compositi**: `Sigma(x: T). U`, `Pi(x: T). U`, `List`, `Map`, `Stream`, tuple/record via place, somme (`TySum`).
- **Dipendenti**: `El(code)` decodifica un codice a tipo; codominio calcolato `El(Fam(x))` [REALE, caso calcolabile].
- **Place / world / Space** [modello toml+filesystem, non blocchi surface]:
  - `place Order { amount number }` — un oggetto/prefascio.
  - Il **world** si dichiara nel `yon.toml` (`[world.X] spaces=[...]`), non in codice.
  - Lo **Space** è una directory del progetto (filesystem = dichiarazione).
  - `topos T where { ... }` — proprietà/prop del topos.
- **Cross-Space**: `wire to SpaceB` (IPC tipato su shm), `import f from SpaceB`.

Copertura sintattica: 154 programmi `.yon` nel corpus, tutti compilanti (gate `test_yon_pipeline`).

---

## 4. Capacità e feature — cosa è REALE

- **Content-addressing come identità** [REALE/TESTATO]: heap content-addressed sul reticolo di Leech Λ24; contenuti identici → stesso ref (dedup per costruzione). `test_unit_extensionality`: 300k contenuti distinti oltre il kissing number 196.560, tutti ref distinti, dedup stabile.
- **Isolamento per processo, zero data-race** [REALE/TESTATO]: Space = processo MMU-isolato, niente thread, niente memoria condivisa mutabile; comunicazione solo via wire tipati. Bug B (serializzazione shm) fixato con mutex PROCESS_SHARED; `test_unit_wire_race` prova la consegna esatta sotto contesa.
- **No-GC senza leak** [REALE/TESTATO]: nessun garbage collector (no tracing, no refcount per-oggetto). Reclaim via (a) uscita del processo Space (l'OS libera la heap), (b) `drop X` esplicito (madvise), (c) `strip_trim` (RAM fisica), (d) **death-watch** — region-reaping automatico quando gli archi entranti statici di uno Space si chiudono (`test_unit_deathwatch`). Non è un GC: conta archi nominati statici, reap a granularità di Space.
- **Effetti dichiarati** [REALE]: `visits` nella firma, caller-covers-callee, enforce a compile-time.
- **Uguaglianza = isomorfismo di Yoneda** [REALE/TESTATO]: l'uguaglianza è un *tipo/cammino*, non un booleano, e la sua decisione *è* l'iso di Yoneda — il reducer `R_Yon` (`catt_r_yon.ml`), condiviso da dispatcher/cubical/kernel. Test dedicati verdi: `test_yoneda_lemma` 11/0, `test_yoneda_typed` 5/0. **Questa macchina NON è la parte "parziale"** (correzione: la riga sotto marcava la *copertura* del kernel, non l'uguaglianza-Yoneda).
- **Verifica al kernel — copertura** [PARZIALE]: `core_wf` ri-certifica il Core lowerato — **hard sui tipi** (`sort_of`; es. reject di `El` di un non-codice), **advisory sui termini** (i corpi fuori dal frammento sono segnalati e saltati, mai errore fatale — `core_wf.ml:209-218`). Cioè: la *verifica whole-program dei termini* è parziale; la macchina dell'uguaglianza-Yoneda no.
- **Univalenza computazionale** [PARZIALE]: `transport(ua(e), x)` computa (`transport_ua_succ`); Glue multi-faccia + T-component per-faccia + transport-a-Glue CCHM implementati e testati al bordo; la coerenza ε piena resta prototipo.
- **Tooling** [REALE]: LSP, formatter (`yonfmt`, round-trip + idempotenza), linter (`yon_lint`, W-codes), doc (`yon_doc`), estensione VS Code, diagnostica a sorgente unica (driver + LSP → `Project.check_all`).

Cosa **NON** c'è: GPU, proof-assistant completo, HoTT pieno con canonicità provata, GC, macro/metaprogramming maturo, ecosistema di librerie.

---

## 5. Use case pratici (calibrati sulle leve reali)

| Dominio | Leva Yon reale | Maturità |
|---|---|---|
| **Storage / dedup** | content-addressing = identità; niente doppioni per costruzione | primitiva pronta; serve uno storage-engine sopra |
| **Database** | dedup automatico; struttura Merkle | primitiva pronta; serve un query/engine |
| **Sistemi distribuiti** | Space isolati, zero data-race, wire tipati | isolamento reale; serve orchestrazione |
| **Verifica / contratti** | dipendenti prim'ordine + `core_wf` + intuizionismo | parziale; ergonomia prove immatura |
| **DSL matematici / ricerca** | topos/Yoneda/cubical, equality-as-a-type | nicchia di ricerca |

*(Dettaglio in [`killer-applications.md`](killer-applications.md).)* Le "rivoluzioni" (Ethereum non-hackerabile, PostgreSQL a 1/100, Kubernetes senza deadlock) sono **traguardi aspirazionali**: il core dà la primitiva, il prodotto va costruito come libreria/runtime dedicato.

---

## 6. Punti di forza e debolezze

**Forza** [REALE]:
- Content-addressing come identità del linguaggio (dedup gratis, equality strutturale).
- Isolamento per processo → zero data-race per costruzione, non per disciplina.
- No-GC con reclaim automatico (death-watch) — la storia "no GC / never free" chiusa senza un collector.
- Modello categoriale coerente (place=prefascio, effetti dichiarati, world/Space da filesystem+toml).
- Nativo via LLVM/MLIR; tooling completo (LSP/fmt/lint/doc).
- Metateoria presa sul serio (SN via SCT, kernel re-check, fuzzing progressivo, gate a sorgente unica).

**Debolezze** (oneste):
- **Single-author, progetto giovane**: nessuna adozione, nessuna azienda, ecosistema ~inesistente.
- **Cubical/HoTT parziale**: canonicità un obbligo aperto; coerenza ε prototipo; non è un proof assistant.
- **Dipendenti di superficie prim'ordine**: meno espressivi di Agda/Coq/Lean.
- **Sintassi di nicchia**: curva ripida; niente esempi/tutorial estesi.
- **Non provato a scala**: nessun sistema reale grande costruito in Yon.
- **AGPLv3**: può limitare l'adozione commerciale.
- **Niente GPU, niente async maturo, macro/metaprogramming assenti.**

---

## 7. Confronto (calibrato)

| Feature | Yon | Rust | Haskell | Coq/Lean | Go |
|---|---|---|---|---|---|
| Paradigma | funzionale + topos | sistemi/ownership | funzionale puro | proof assistant | imperativo/CSP |
| Tipi | dipendenti prim'ordine + cubical parziale | statico, no dipendenti | statico HM+ext | dipendenti pieni | statico semplice |
| Concorrenza | Space=processi, no-race by construction | thread + ownership | STM/thread | — | goroutine+channel |
| Memoria | no-GC, content-addr, region-reaping | no-GC, borrow checker | GC | GC | GC |
| Verifica formale | parziale, integrata (core_wf) | no | no | sì (il core business) | no |
| Performance | nativo (LLVM) | nativo | GHC nativo | — | nativo |
| Ecosistema | ~nullo | ampio | medio | medio (matematica) | ampio |
| Maturità | v1.1, sperimentale | produzione | produzione | produzione | produzione |

Onestà: Yon **non compete** con Coq/Lean come proof assistant né con Rust/Go in ecosistema. Il suo spazio unico è **content-addressing + isolamento-per-processo + modello categoriale**, non "un Lean migliore".

---

## 8. Ecosystem e tooling

- **Compilatore**: `yonc` (dir o file → nativo).
- **Frontend**: OCaml (parser Menhir, ~38k righe); runtime C (~37k righe, escluso vendored mmgroup).
- **Test**: gate pytest (`test_yon_pipeline` 76 esempi end-to-end; ~40 oracoli OCaml; unit test runtime; metatheory fuzz); regressione completa ~1300+ nodi verdi.
- **LSP / formatter / linter / doc**: presenti (modulo condiviso CLI+LSP).
- **IDE**: estensione VS Code (LSP + linter + formatter).
- **Package/import**: `import from Space`, layout progetto = filesystem + `yon.toml`.
- **Stdlib**: minimale (Vec, Map, HashSet, Stream, List, XSet/XRel*, ecc.).

---

## 9. Prestazioni (solo dati REALI, con caveat)

> Benchmark misurati sull'M1 di Antonio (non nel sandbox); numeri build-invarianti separati dai timing. Non invento cifre.

- **Spawn Space**: scala ~linearmente, ~160 → ~958 M/s (dopo il fix del collect-slice 200ms→3ms). [misurato, M1]
- **Content-addressing / dedup**: identità O(1) per ref; 300k contenuti distinti gestiti senza falso-dedup (`test_unit_extensionality`). [testato]
- **Compilazione**: nativo via LLVM; tempi non profilati in modo pubblicabile.
- Altri numeri (equality su stringhe grandi, HTTP req/s, ecc.): **non disponibili** — non li invento.

---

## 10. Community e adozione (onesto)

- **Utenti**: sostanzialmente l'autore. Nessuna adozione esterna nota.
- **Aziende**: nessuna.
- **Progetti**: il compilatore/runtime stesso.
- **Presenza**: discussa criticamente su r/programmingcirclejerk e Hacker News (revisori competenti; molte accuse puntuali erano misread, alcuni gap veri coincidono con il backlog 1.2).
- Tendenza: interesse di nicchia nella type theory; niente crescita di massa.

---

## 11. Futuro e roadmap (dal backlog 1.2)

- Chiuso in 1.2: A1 (codominio calcolato `El(Fam x)`), core_check cablato, A1.2/A1.3 (funtorialità del prefascio, kernel+superficie), boxing value-dependent, Glue multi-faccia + transport-a-Glue CCHM, death-watch, copertura P5.
- Aperto: prova meccanizzata di canonicità (metateorema); coerenza ε cubicale piena (prototipo consistente); doc pubblici (scoping HoTT, memory-model, sommario SN/SCT); de Bruijn (descoped-post-1.2, irrobustimento non-bug).
- Direzione prodotto: trasformare una leva reale in libreria — **Storage/Database** è il candidato più pronto (content-addressing è già il cuore del runtime).

---

## 12. Esempi di codice (dal corpus reale)

**Hello / entry**
```yon
fun main(): number { return 0 }
```

**Effetti dichiarati** (`visits`)
```yon
fun do_emit(s: String): unit visits Output { return Output.print(s) }
fun caller(s: String): unit visits Output { return do_emit(s) }
fun main(): number { return 0 }
```

**Struttura dati mutabile su arena** (Vec, no malloc)
```yon
fun main(): number {
  be a holds Vec.push(Vec.push(Vec.push(Vec.empty(), 10), 20), 30)
  be b holds Vec.push(Vec.push(a, 40), 50)
  be c holds Vec.set(b, 0, 7)
  return Vec.size(c) + Vec.get(c, 0) + Vec.get(c, 4)   /* 5 + 7 + 50 */
}
```

**Tipo dipendente a codominio calcolato** (A1) — compila+gira
```yon
fun Fam(x: number): Type_0 { return number }
fun takes(p: Sigma(x: number). El(Fam(x))): number { return 0 }
fun main(): number { return 0 }
```
`El(Fam(x))` computa via la regola di conversione `El(c) ≡ El(nf_Δ c)` e decodifica al carrier reale di `number`.

*(Concorrenza cross-Space, gestione errori tipata, FFI: esistono nel modello — wire/import, Result/somme, extern C — ma per esempi eseguibili accurati si veda il corpus `examples/*.yon`, dato che la sintassi è di nicchia e va verificata dai sorgenti, non ricordata a memoria.)*

---

## 13. Risorse

- Repo: https://github.com/yon-language/yon (README, `docs/`, `examples/`).
- Libro/manuale: capitoli in `docs/book/` (topos-oriented programming, spaces, arrows, HoTT types, ecc.).
- Metateoria interna: `docs/metatheory-internal/` (trusted-kernel, CONFORMANCE, metatheory, SN).
- Playground/tutorial estesi/corsi: **non esistono ancora** — è un limite reale.

---

## 14. Avvertenze e limiti

- **Non è un proof assistant** — non usarlo come Coq/Lean.
- **Non usarlo per GUI, ML, GPU, web frontend** — fuori scope, niente librerie.
- **Sperimentale**: API e sintassi possono cambiare; un solo autore.
- **AGPLv3**: attenzione all'uso commerciale.
- **Cubical parziale**: la coerenza piena / canonicità provata non è garantita — i bordi osservabili sono esatti, la prova è aperta.

---

## 15. Giudizio finale

**A chi è adatto**: ricercatori di type theory / topos; chi vuole esplorare content-addressing come identità e isolamento-per-processo come modello di concorrenza; chi costruisce DSL/sistemi dove "dichiara la struttura e la struttura fa il lavoro" ha valore.

**A chi NON è adatto**: principianti; sviluppatori web/ML/GPU; chi ha bisogno di un ecosistema maturo o di un proof assistant completo oggi.

**Punteggi (calibrati, 1-10)**:
- Innovazione: **8** — content-addressing-as-identity + Space-isolation + modello topos sono genuinamente distintivi.
- Rigore/ingegneria interna: **8** — metateoria seria, kernel re-check, fuzzing, gate a sorgente unica, ~1300 test verdi.
- Sintassi/ergonomia: **5** — coerente ma di nicchia, ripida, poca guida.
- Performance: **7** — nativo LLVM, spawn scalabile, dedup O(1); pochi benchmark pubblicabili.
- Ecosistema: **2** — quasi inesistente.
- Documentazione: **4** — libro interno buono, ma niente tutorial/playground pubblici.
- Community: **1** — single-author, nessuna adozione.

**Verdetto**: Yon è un linguaggio **di ricerca genuinamente originale** — la sua tesi (place=prefascio, equality-as-a-type, content-addressing come identità, Space isolati senza data-race, no-GC con region-reaping) è coerente e in buona parte **reale e testata**, non solo pitch. Il valore vero non è "un proof assistant" (lo è solo parzialmente, e overclaimarlo è stato l'errore da correggere): è **il modello di esecuzione** — content-addressing + isolamento + no-GC — dove le primitive sono pronte e un prodotto (uno storage/DB engine) sarebbe la dimostrazione più diretta. I limiti sono di **maturità ed ecosistema**, non di visione: single-author, cubical parziale, nessuna adozione. Adatto oggi a nicchie di ricerca e a chi vuole costruire su primitive rare; non a produzione mainstream.
