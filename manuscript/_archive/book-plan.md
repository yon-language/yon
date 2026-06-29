# Yon — Book Plan (blueprint) · DA APPROVARE

> Fase 1 di book-wright. Questo è il progetto del libro: una volta giusto,
> tutto il resto scorre. Ancorato a `LANGUAGE_AUDIT.md` (verità di terra) e a
> `DOCS_DIFF.md`. Niente prosa di capitolo finché non approvi questo.

## Decisione aperta (confermami)

**Lingua del libro.** I doc esistenti sono in inglese; un libro di linguaggio
ha più portata in inglese. Conversazione in italiano. → Proposta: **libro in
inglese**, noi due ne parliamo in italiano. Se preferisci l'italiano, si fa in
italiano. *(Il blueprint qui sotto è in italiano per la revisione; lo specimen
di voce è dato in entrambe.)*

## Promessa

Dopo questo libro il lettore sa **modellare un dominio come un topos** e farsi
garantire dal compilatore proprietà che altrove sono speranze a runtime:
invarianti di quoziente (privacy/compliance), cambi di rappresentazione senza
rotture (univalenza), leggi algebriche certificate, coordinamento fra processi
come morfismo geometrico, logica del "non so" senza terzo escluso. Sa anche
*riconoscere* quando un linguaggio mainstream sta solo sperando, e perché.

## Lettore-modello

Ingegnere del software competente (Java/Go/Python/C++/SQL), **senza**
background in teoria dei tipi o dei fasci. Sa cos'è un'interfaccia, una
transazione, un test. Vuole capire perché varrebbe la pena cambiare modo di
pensare. Non gli si chiede di sapere cos'è un funtore: glielo si fa *vedere*
nel parco. Il manager pragmatico è un secondo lettore servito dai riquadri
"Jurassic" (i 4 tempi), che può leggere saltando la prosa tecnica.

## Voce e registro

Narrativa pedagogica alla *Code* di Petzold / *SICP*: il *perché* prima del
*cosa*, motivazione sentita, un esempio che cresce, rigore senza aridità.
Caldo nel tessuto connettivo, preciso e onesto nelle affermazioni: ciò che è
dimostrato si dichiara dimostrato (col test accanto), ciò che è ristretto si
dichiara ristretto. I riquadri Jurassic hanno una **seconda voce**: asciutta,
ironica, profonda — l'ingegnere navigato che parla al management senza
fronzoli.

**Specimen — voce del libro (IT):**
> Centomila dinosauri si muovono nel parco, e ognuno è due cose insieme: un
> animale con un battito e una posizione, e una riga di dati che qualcuno, da
> qualche parte, vuole interrogare. Il problema non è memorizzarli. È che il
> biologo, la sicurezza e l'ufficio legale guardano lo *stesso* animale e
> devono vederne *cose diverse* — e nessuno dei tre deve poter vedere ciò che
> non gli spetta. In Java questa è una promessa scritta nei commenti. In Yon
> è una cosa che il compilatore si rifiuta di tradire.

**Specimen — voce del libro (EN):**
> A hundred thousand dinosaurs move through the park, and each is two things at
> once: an animal with a heartbeat and a position, and a row of data someone
> wants to query. Storing them isn't the hard part. The hard part is that the
> biologist, security, and legal look at the *same* animal and must see
> *different* things — and none of the three may see what isn't theirs. In Java
> that's a promise written in a comment. In Yon it's something the compiler
> refuses to betray.

**Specimen — voce riquadro Jurassic (4 tempi), asciutta/ironica:**
> *Il feticcio accademico.* Un fascio è un dato che vive bene sui ricoprimenti.
> *Il disastro enterprise.* In Java il "dato coerente fra viste" è un commento e
> tre code review. *La soluzione coi dinosauri.* La vista del legale è una
> proiezione sul quoziente per coorte; un'operazione che leakerebbe l'individuo
> non compila. *Il ritorno.* Il data-leak per cui pagheresti la multa GDPR
> diventa un errore di compilazione: costo zero a runtime, impossibile a valle.

## Esempio ricorrente — il parco (cresce di capitolo in capitolo)

**InGen Sim**: simulazione real-time di 100.000+ dinosauri. Il filo unico:

- mondi/place: un dinosauro è un `place`; i dipartimenti (Scienza, Sicurezza,
  Legale) sono mondi/viste sullo stesso animale.
- quoziente/fascio: la vista Legale è una proiezione sul quoziente per coorte
  (GDPR); operazioni che leakano l'individuo **non compilano**.
- univalenza: si cambia la codifica del DNA (rappresentazione) senza toccare il
  codice che la usa — `transport` lungo l'equivalenza.
- algebra certificata: aggregati biometrici sul branco (somma/max) con leggi
  verificate; un claim di commutatività falso è respinto.
- heap content-addressed: due genomi identici deduplicati, uguaglianza O(1).
- Heyting: un sensore che non vede un dinosauro dà **unknown**, non `false`.
- cross-space/geomorph: i dipartimenti sono `space` distinti coordinati da un
  morfismo geometrico; gli stream dei sensori.
- modello d'errore: il *containment breach* è un errore come sotto-oggetto.
- capability/effetti: chi può leggere i biometrici vs la posizione.

## Arco di scoperta → Indice ragionato

Regola dura su ogni **capitolo-feature**: (a) la lacuna (perché serve), (b)
l'approccio Yon, (c) **il disastro nel/i linguaggio/i mainstream più adatto**
(Java/Go/Python/C++/SQL/Rust a seconda del concetto), (d) un **test runnabile**
che finisce in `regression/` (pytest). Niente capitolo senza test verde.
Riquadro **Jurassic (4 tempi)** dove il concetto è chapter-worthy.

**Parte 0 — Perché un topos (il gancio).**
- 1. Il parco impossibile in Java. *(motiva tutto; disastro: Java/Python)*
- 2. Mondi, place, spazi: il vocabolario. *(worlds/places/space)*

**Parte I — Le basi del linguaggio (tessuto).**
- 3. Valori e binding (`be…holds`), niente durate-pezzotto. *(disastro: —)*
- 4. Controllo di flusso (when/for/iter/while). 
- 5. Funzioni, effetti, `visits`. *(disastro effetti: Java/Go)*
- 6. Liste, mappe, somme, comprehension `{x:A where P}` (→ Σ).

**Parte II — Il cuore categoriale (i colpi grossi).**
- 7. Le frecce: move/view/reduction/operation; dispatch Yoneda `recv.f`.
- 8. **Quozienti e fasci**: la vista che non può tradire. *(disastro: Java/Python runtime-hope)* ★
- 9. **Sotto-oggetti ed errori**: `subcontains`, error model. *(Go errors/Rust Result)*
- 10. **Algebra certificata**: leggi verificate, claim falsi respinti. *(Java/Scala)* ★

**Parte III — Identità, cammini, univalenza.**
- 11. Uguaglianza come cammino: `Id`/`refl`/`ind_path`. *(disastro: equals/hashCode)*
- 12. `transport` e **univalenza che computa**: cambiare rappresentazione gratis. *(nessun equivalente statico)* ★
- 13. Kan (`comp`/`hcomp`) — facce single-atom; limite onesto dichiarato. ◑
- 14. HIT (`hit`/`hit_elim`) — il cerchio; limite dichiarato. ◑

**Parte IV — Logica del non-deciso.**
- 15. **Heyting tri-valore**: `present/absent/unknown`, niente terzo escluso. *(disastro: SQL NULL a 3 valori)* ★
- 16. Interi con maschera Unknown (`heyt_int`) — ◑ verifica MLIR prima del capitolo.

**Parte V — Più processi.**
- 17. **Spazi che parlano**: `wire`, `move/unifies`, geomorph. *(disastro: Go/Erlang coord. manuale)* ★
- 18. Concorrenza: spawn/promote/parallel.
- 19. Capability e confini. *(disastro: Java SecurityManager/Go)*

**Parte VI — Strumenti e progetto.**
- 20. Heap content-addressed: dedup, uguaglianza O(1). *(disastro: C++/Java deep-equals)*
- 21. **Il filesystem È la dichiarazione**: l'albero di cartelle come ontologia
  (dir=world, file=space, place eredita il world, `world.yon`, `yon.toml`).
  *(disastro: in Java/Go la struttura del dominio è convenzione + boilerplate;
  qui la struttura del progetto È il modello, verificata fino al codegen)* ★
  — visual: file-tree interattivo del parco (cartella `Park/`, quoziente,
  file=space) accanto alla forma esplicita equivalente.
- 22. Pacchetti, import, tooling.

**Reference & appendici.**
- R. Reference delle keyword (rigenerata dall'inventario, depurata dai pezzotti).
- G. Glossario.
- F. Lavoro futuro (comp/hcomp facce composte, libreria unità, ecc.).
- **D. Benchmark — SOLO QUI, ri-misurati** quando v1.1 è ferma, metodo
  dichiarato, sorgenti nel repo. Niente numeri prima.

★ = capitolo con riquadro Jurassic completo nei 4 tempi.

## Convenzioni

- Notazione: `place`, `world`, `space`, `move`, `view`, `reduction`,
  `operation` in monospace; concetti categoriali (funtore, fascio, quoziente)
  in tondo, definiti una volta nel glossario (append-only).
- Codice Yon in blocchi ```yon; il "disastro" mainstream in blocco col suo tag
  (```java, ```sql, ```go…), sempre etichettato con il linguaggio e *perché
  quel* linguaggio.
- Naming esempi: prefisso `park_` per i sorgenti del parco; ogni test del libro
  vive in `regression/book/<capitolo>/` ed è incluso nel pytest.
- Ogni claim "il compilatore lo garantisce" ha accanto il file di test che lo
  prova (link relativo).

## Apparato pedagogico

- Box: **Idea chiave**, **Tranello comune**, **Approfondimento** (saltabile),
  **Jurassic** (i 4 tempi, per il management).
- Checkpoint di comprensione a fine capitolo.
- Apparato visuale (book-wright + skill visualize): diagrammi Mermaid per
  categorie/funtori/quozienti; SVG per il flusso pull/push del geomorph;
  componenti React interattivi (Docusaurus) dove l'interazione insegna (es.
  slider sul branco che mostra l'aggregato certificato; toggle vista
  Scienza/Sicurezza/Legale sullo stesso dinosauro).

## Regole di processo (book-wright)

- `manuscript/state.md` è la spina: si legge prima di ogni capitolo, si
  aggiorna dopo (glossario append-only, termini introdotti, fili aperti, voce).
- Si scrive un capitolo alla volta; ci si ferma solo ai bivi veri.
- Output: capitoli Markdown → assemblaggio Docusaurus (frazionato per parte).
- **Gate del libro**: un capitolo-feature non è "fatto" finché il suo test non
  è verde nel pytest. I benchmark sono l'ultima cosa.
