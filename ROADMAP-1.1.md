# Yon 1.1 — roadmap

Scope: completare il nucleo logico-geometrico (cubical + Yoneda), chiudere i
buchi tecnici dichiarati, e allineare claim e documentazione a ciò che compila
e gira. Non è una release di sola manutenzione.

Principio operativo (non negoziabile): ogni passo è additivo e verificato
contro la regressione prima del successivo; un cambio pulito alla volta; design
su carta prima del codice fondazionale; nessuna affermazione che il compilatore
o un test non abbia confermato. Branch dedicato `1.1-dev`.

---

## 1. HoTT (cubical) — nucleo chiuso a livello kernel

Stato: blocco chiuso end-to-end nel typechecker. Regressione 64/64; oracoli
dedicati tutti verdi (test_el, test_path, test_glue, test_quote, test_path_core,
test_motive, test_j_tarski, test_hit_elim, test_cubical_surface, test_hit_compute,
test_isequiv).

1. TyEl nel typechecker — fatto: decode 0/1-cella, uguaglianza via `decidable_equal`,
   conversione per-carrier in `Dispatcher.type_equal`, sintassi di superficie
   `El`/`quote`/`el_match` end-to-end.
2. Uguaglianza di cammini non banale — fatto: `Path`/`refl`/`transport`,
   `comp`/`hcomp`; due cammini uguali per riduzione ma non sintatticamente
   (test_path_core). `refl(t)` traccia `t` come endpoint reale, niente placeholder.
3. `Glue` e HIT — fatto: `Glue`/`hcomp` con estensionalità (test_glue); HIT di
   prima classe (costruttori + eliminatore + computazione da sorgente,
   circle_hit.yon); S¹≃S¹ via transport del punto sbloccato.
4. isEquiv — fatto: gate di soundness su `ua`/`Glue` (esigono un `Equiv`
   strutturato `equiv(f,g,η,ε)`, mai una funzione nuda) e coerenza piena
   (η : Π a. Id(g(f a), a), ε : Π b. Id(f(g b), b) verificate sui termini reali).
   `type_equal` su `TyId` confronta carrier ed endpoint (test_isequiv 10/10).
5. Endpoint scrivibili e conversione — fatto: grammatica `Id` con endpoint
   espressioni (`Id(A, g(f(a)), a)` da sorgente, zero conflitti nuovi nel parser);
   confronto degli endpoint fino a normalizzazione (g(f a) ≡ a se f,g inverse,
   rifiutato se non lo sono). Regressione: id_endpoint_coherence.yon.

### 1.6 Debito definizionale (δ-conversione) — DA CHIUDERE

Il confronto fino a conversione poggia oggi su due toppe da rimuovere alla radice:
- ref globale `surface_fun_idx` in `dispatcher.ml`, che porta i corpi delle
  funzioni a `type_equal` per side-effect (stato globale fuori dal contesto);
- inliner di superficie `Naturality_symcheck.normalize` con cap `50` (magic
  number), parallelo al normalizzatore del kernel, usato per gli endpoint.

Radice unica: l'uguaglianza definizionale non ha accesso alle δ-regole
(definizioni delle funzioni) attraverso il contesto. Decisione presa: le δ-regole
vivono in `Tyenv.env`. Piano:
- estendere `Tyenv.env` con i corpi delle funzioni (δ-regole), popolati una sola
  volta dal contesto, non per stato globale; eliminare `surface_fun_idx`;
- δ-conversione nel reducer del kernel (unfolding di `f args` quando `f` ha una
  definizione nel contesto), accanto a β; riscrivere `ty_term_equal` su
  `desugar_expr` + `term_equal_kernel` con il contesto δ; rimuovere `normalize`
  e il cap 50 da quel percorso;
- terminazione senza fuel né euristiche: solo le funzioni certificate dal SCT
  (Size-Change Termination) entrano come δ-regole nel giudizio di uguaglianza —
  la loro normalizzazione termina, il confronto resta decidibile; le non
  certificate non si espandono (sound: non si dichiara uguale ciò che non si è
  ridotto);
- verifiche d'arrivo: g(f a)≡a (inverse, accettato), g(x)=x+1 (rifiutato),
  funzione ricorsiva certificata SCT (normalizza), funzione non terminante (non
  ammessa come δ, niente loop).
- prerequisiti da confermare: `desugar_expr` ha una dipendenza dal ref
  `synth_funs` per il lambda-lifting (isolare la parte pura o renderlo chiamabile
  senza effetti dal punto di confronto); `r_yon_term_equiv` deve rispettare le
  δ-regole una volta che il contesto le porta, senza forzare divergenze su
  sotto-termini non necessari.

---

## 2. Yoneda / Sym (topos) — da certificare

Stato oggi: principio architetturale (content-addressing come identità degli
indiscernibili, dispatch auditato a mano come "Yoneda-coherent", documento di
coerenza "Yoneda-∞-ω"). Nessuna verifica meccanica nel linguaggio.

1. Formalizzare il lemma nel linguaggio
   - definire "rappresentabile" nel kernel
   - dimostrare `Handle A ≅ (A ⇒ Set)` nel linguaggio, non in metateoria
   - test: una `f : A → B` trasformata in trasformazione naturale tra rappresentabili
   - obiettivo: il linguaggio fornisce `yoneda_lemma : (∀ X. (A ⇒ X) → (B ⇒ X)) → (A ⇒ B)`
2. Collegare content-addressing a Yoneda
   - prova (nel linguaggio o in metateoria) che `slot_id == slot_id ↔ content == content`
     è un caso concreto del lemma
   - test che sfrutta la proprietà per dedurre un'uguaglianza
3. Certificare il dispatch Yoneda-coherent
   - sostituire l'audit manuale con un checker: nessuna coercizione implicita tra
     tipi non equivalenti
   - test di regressione che fallisce se la coerenza è violata

---

## 3. Punti tecnici must-have (indipendenti da 1 e 2)

1. `yon_xcoord_to_int24` — oggi stub `return -1`. Implementare il decode
   coordinata-di-Leech → 24 interi (Seysen Thm 6.1 / `gen_leech2_short_vector`).
2. Benchmark `XSet` — misurare membership/union/intersection/popcount sulle
   word del bitmap (196.560 bit ≈ 3072 word a 64-bit), metodo dichiarato.
3. Modello carichi grandi — documentare il pattern (Space-per-richiesta + exit
   a fine) e testarlo con 2M entries su più Space.
4. Header `yon_rt.c` — rimuovere `thread_local` o renderlo macro vuota.
5. `xleech2_handler_stack` — allineare commenti e implementazione: il runtime è
   no-thread, l'header parla di "thread-local / each thread".
6. Cardinalità orbite Co₀ — ri-confermare nel sorgente i numeri
   (98280 / 8386560 / 8292375 sui 2²⁴ coset) prima di citarli.

Già chiuso: header di `yon_rt.c` riallineato (provato comment-only); spawn
end-to-end (sotto è solo consolidamento, non implementazione).

---

## 4. Documentazione — allineamento allo stato reale

1. Glossario minimo, un termine una definizione prima del primo uso
   (Handle, Space, xcoord, type-2, orbita, Lambda24, lattice point, world/place, site).
2. Esempio categoriale in prima pagina: objects/morphisms/compose/terminal/
   geom_morphism/topology — non l'enum che sembra OOP. Un morfismo è una
   funzione che preserva l'Handle.
3. `subset` → `subworld` in tutto il codice e nei doc.
4. Tre ruoli di Lambda24 separati: Golay (correzione errore), kissing number
   (set bitmap), Co₀ (canonicalizzazione orbite). Chiarire che l'addressing è
   `fnv1a` + `memcmp`, non la geometria.
5. Rimuovere le LLMism (frasi astratte, grandiosità, "notevolmente"); spezzare i
   muri di testo; passata umana, frasi più corte.
6. Backlog HN — ogni punto chiuso con un commit specifico, non solo claim-fix.
   Claim onesti: il frammento cubical e i limiti correnti (`TyEl`,
   propositions-as-booleans) descritti per ciò che fanno e non fanno; il
   content-addressing dal registro di `Syn(Yon) §9` (estensionalità verificata a
   payload via `memcmp`, `K` non iniettiva, collisioni di hash non rompono
   l'enunciato).

---

## 5. Suite di test e benchmark

1. Suite HoTT (≥20 test): conversione `TyEl`, uguaglianza di cammini, `comp`,
   `Glue`, HIT, `S¹ ≃ S¹`.
2. Suite Yoneda: verifica del lemma su tipi semplici, dedup come istanza.
3. Benchmark `XSet` integrato in `make bench`.
4. `gtest` (ed eventualmente `pytest`) per i test C del runtime.
5. Verifica finale: intera regressione (in-process + cross-Space) su oggetti
   freschi + i nuovi test HoTT/Yoneda, prima del rilascio.

---

## 6. Spawn — consolidamento

Funziona end-to-end (`spawn_parallel_collect.yon` compila; lowering e runtime
cablati). Resta:

1. Test approfonditi delle lambda in spawn: cosa accade a una chiusura che
   cattura un locale attraverso il fork + role-dispatch sulla coda
   `yon_rpc2_queue` (PROCESS_SHARED). Parallelismo effettivo verificato.
2. Esempio ufficiale: map-reduce / permutation test.
3. Documentazione del modello reale (no thread; processi su coda condivisa) nel
   linguaggio e nel runtime.

---

## 7. Ecosistema — libreria di test in Yon + `yon-pkg`

1. Libreria di test scritta in Yon stesso.
2. Distribuzione tramite `yon-pkg` (toolchain già presente in `toolchain/yonc`).

---

## Coordinamento

- Branch `1.1-dev`, commit incrementali, regressione verde prima di ogni avanzamento.
- Sequenza esecutiva consigliata (rischio crescente, per non toccare subito il
  type-checker e il Level 0/Level 2 già sigillati):
  blocco 3 e 4 (base solida e onesta) → blocco 6 → blocco 1 (`TyEl` e cammini) →
  blocco 2 (Yoneda) → blocco 5 e 7 → verifica finale.
- Pubblicazione: aggiornare il sito, `yon-pkg` con la libreria di test, post di
  rilascio che elenca i completamenti reali (cubical operativo, Yoneda
  certificato, spawn, method-call, `=`) e le verifiche aggiunte.
