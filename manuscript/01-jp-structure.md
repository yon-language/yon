# Jurassic Park in Yon — structure (for review)

> Deliverable of `00-jp-spec.md` §"What to deliver NOW". This is the **backbone**,
> not the chapters. Built from: `jp-novel-map.md` (the novel, read in full),
> `construct-inventory.md` (✓/declared/debt, code-anchored), `swarm/AUDIT_CONSTRUCT_ORDER.md`
> (the D0–D16 ladder + tiers), and the corrected filesystem ontology
> (**dir = space, file = place, world = `yon.toml`**). Every construct named here
> carries the verdict the book will print. **Stop point: approve this spine before
> any chapter is written.**

## The opening (before Iteration 1, before Malcolm)

The author's line, first person, standing alone:

> *"I tried to engineer a Jurassic Park that works. I hope I did a better job than Hammond."*

Hammond's certainty was the flaw; this line carries the humility he lacked —
Malcolm's posture, not Hammond's. It invites the hostile reader to find the crack.
It is true on two planes: the new builder addressing the reader, and the author
speaking about the language (an attempt to engineer the substrate on which such a
park would hold). Paired with the Prologue ("The Bite of the Raptor": a cover-up,
a whispered "raptor") and answered by Malcolm's first epigraph — *"I tried"* /
*"few clues to the underlying structure"*.

## The honest boundary (stated up front, kept all book)

Yon closes the **ontological** gap — identity confusion, cross-world leaks, descent
that breaks a quotient, carrier-less inhabitants. It does NOT close the **human**
gap — Nedry's sabotage, the storm, the staff cuts. The novel's *cause* is structural
(a control system that can detect a shortfall but never a surplus of identities);
its *occasions* are human. The book marks every chapter: **real ontological hook**
(Yon catches it) or **narrative framing** (it does not). Never force "Yon would have
saved this" where there is none.

---

## The seven Iterations → seven Parts → Yon concept planes

The fractal is redrawn one plane deeper each Iteration, ascending the dependency
graph **silicon (bottom) → Yoneda (top)**. Content-addressing is planted as silicon
in Iteration 2 and revealed as Yoneda in Iteration 7 — the top meeting the bottom is
the book's closing move. Verdict key: ✓ verified · ~ declared · ✗ debt.

| Iter | Malcolm epigraph (verbatim) | Resonance | Yon plane |
|------|------------------------------|-----------|-----------|
| 1 | *"At the earliest drawings of the fractal curve, few clues to the underlying mathematical structure will be seen."* | the substrate is all present but unreadable (the dismissed genetic marker) | **Native ground**: machine + the mechanics to read it |
| 2 | *"With subsequent drawings of the fractal curve, sudden changes may appear."* | the clones are real — identical genomes are *the same thing* | **Lattice & silicon**: identity-as-content, geometry-as-distance |
| 3 | *"Details emerge more clearly as the fractal curve is re-drawn."* | the recount: "you only tracked the expected number" — content vs location | **Ontology**: place / world / space, the arrows |
| 4 | *"Inevitably, underlying instabilities begin to appear."* | equality stops being yes/no; a loop the runtime can't see ↔ breeding the count can't see | **Identity & homotopy**: Id / path / Glue / HIT |
| 5 | *"Flaws in the system will now become severe."* | "all female" was a certainty; the truth was *unknown* — denying it caused the breach | **Logic of the undecided & the error** |
| 6 | *"System recovery may prove impossible."* | you cannot glue broken local parts into a coherent whole — descent fails | **Sheaf, descent, morphisms, wire** |
| 7 | *"Increasingly, the mathematics will demand the courage to face its implications."* | the nest count done right + the migration; the most concrete *was* the most abstract | **The idea (Yoneda) & the reveal** |

---

## Reasoned table of contents

Each chapter: **JP scene · Yon concept(s) · verdict (source) · the `.yon` program (one
line) · hook**. The fractal player opens every Iteration (7 frames). D-rungs in
brackets tie each chapter to `AUDIT_CONSTRUCT_ORDER.md`.

### Iteration 1 — Native ground · *"few clues to the underlying structure"*
JP: the bite no one can read; the genetic-engineering marker dismissed as
contamination; a child's drawing says *dinosaur*.

| Ch | JP scene | Yon concept(s) [D] | Verdict (source) | `.yon` | Hook |
|----|----------|--------------------|------------------|--------|------|
| 1.1 | The unreadable fragment | the machine: mmap sole primitive, two allocators, no GC, `exit()` [D-runtime #23]; `Carrier`=printer [#26]; single normalizer [#27] | ✓ (`test_unit_xheap_bounds.c`, `carrier.ml:143`, `reduce.ml:~548`) | a minimal program: bind, compute, `exit 0` | framing (substrate present, unread) |
| 1.2 | "Counted by computer every few minutes" | the mechanics to read code: `be x holds e`, `fun`, control flow, expressions [D0a–e] | ✓ (T3 corpus; `examples/*`) | `be x holds …`, a `fun main`, an `if/for` | framing |
| 1.3 | A drawing names what the data couldn't | output is stdout-only via `Output` [#26 note]; the honesty discipline: compile-time reject, exit 3, "no fake green" [#19] | ✓ (`run_example.ml:54`, the `negative/` corpus, `gate.sh`) | a program that prints; a sibling that is rejected (exit 3) | framing → seeds the book's contract |

### Iteration 2 — Lattice & silicon · *"sudden changes may appear"*
JP: the party arrives; living dinosaurs; cloned from amber-trapped DNA, gaps filled.

> **SYNCED 2026-06-29 to what shipped.** FNV content-addressing was pulled forward into **1.2
> "Counted by Computer"** (it teaches it in full: def, byte-compare, the slot, HashSet dedup gated,
> the clones-from-one-sequence). So 2.1 is no longer "content-addressing" (that would repeat 1.2);
> 2.1 now introduces the **Leech lattice** (the 2nd engine), and 2.3 is the **field guide** to all 11
> data structures, not the original "Classifying the animals" cladistics experiment (CUT — it tried to
> read biology off the lattice; the lattice reads the embedding, not the meaning — see `linear-map.md`).

| Ch | JP scene | Yon concept(s) [D] | Verdict (source) | `.yon` | Hook |
|----|----------|--------------------|------------------|--------|------|
| 2.1 | The clones are real (the arrival / first sight) | **the Leech lattice = the 2nd content-address engine** (a place, not a name): 196,560 type-2 points = the kissing number (theorem); MPHF = perfect 18-bit address, 0 collisions; 12 M24 classes; `Co₀`. `Leech.embed` places a value. [#21, D16] | ✓ (`test_leech_theta.ml:26,33`; `test_mphf.c`; `yon_rt.c:3077`) | `uc_lattice` → `196560 12 1 2`; address by place vs 1.2's address by name | framing → **plants the reveal** (name & place; pays off Iter 7) · player: **LEECH SHELLS** |
| 2.2 | The genome, retouched ("Version 4.4") | **Golay (24,12,8) / VoyagerList**: integrity is algebraic, recovery is decoding [#22, D16] | ✓ (`runtime/test_unit_voyagerlist.c:53-82`) | seal a codeword, corrupt 1–2 bits, recover | **real** (correction as structure; short leash — Yon doesn't "repair DNA") · player: **GENOME** |
| 2.3 | The Park's Memory (field guide) | **the 11 data structures on both engines** (FNV hash + Leech lattice): HashSet/HashMap/MerkleTree/List/Vec/VoyagerList/Arena/XSet/XRelSet·XRelMap/XSimplex/XTower; the FNV-vs-Leech division; the constructed clade reader [#21, #2, D16] | ✓ (all gated: `uc_*` + `13/14/15` contracts) | one JP use case per structure, each runnable+gated | **real** (which engine answers which question); honest boundary: geometry's meaning is earned · 11 players |

### Iteration 3 — Ontology · *"details emerge more clearly"*
JP: the tour; Malcolm forces a recount; the total climbs past 238; **"they're
breeding."** The fourth wall: Hammond counts locations believing he counts contents.

| Ch | JP scene | Yon concept(s) [D] | Verdict (source) | `.yon` | Hook |
|----|----------|--------------------|------------------|--------|------|
| 3.1 | The island laid out | **the filesystem is the declaration**: `[world.Park]` in `yon.toml`; a paddock = a directory (space); a dinosaur = `Rex.yon` (place) [D2] | ✓ (`package_layout.ml:29-48`; `test_world_site.ml` for world algebra `*,+,/∼,subset` [#12]) | a tiny park project tree that compiles | **real** (the tree IS the ontology) |
| 3.2 | "You only tracked the expected number" | **identity is extensional** (content-addressing as ontology) [#2]; **the arrows** `move/view/reduction/operation`, Yoneda dispatch `recv.f` [D3] | ✓ (#2; dispatch `parser.mly:24-42`, `test_dispatcher.ml`) | `new Dinosaur { same genome }` twice → one slot | **real** (the fourth wall, part 1) |
| 3.3 | One fossil, two positions | **the `Space` cell** = location, not content [#3]; concept vs instance: stratified universes [#11], strict products η_Σ [#10] | ✓ Space cell (write `x = e`→`Space__set`, read `Space__get`, runtime `g_space_cells`; `kw_list_here.yon` green); ✓ universes (`test_core_check.ml`), η_Σ (`test_eta_sigma.ml`) | two location cells, one content slot (the dedup'd genome) | **real** (the fourth wall, part 2 — BOTH halves green) · player: **PADDOCK MAP** |

### Iteration 4 — Identity & homotopy · *"underlying instabilities begin to appear"*
JP: sabotage and storm; fences fail; the rigid assumption (equality = identity) wobbles.

| Ch | JP scene | Yon concept(s) [D] | Verdict (source) | `.yon` | Hook |
|----|----------|--------------------|------------------|--------|------|
| 4.1 | Things stop being equal-or-not | **`Id` / `refl` / `PathP`**: equality has a geometry [#6, D9] | ✓ (`test_path.ml:28-106`; neg `neg_pathp_endpoint.yon` exit 3) | `refl`, a `PathP` with checked endpoints | framing |
| 4.2 | Govern by the diagonal case | **`J` / `ind_path`**, β on `refl` [#7, D9] | ✓ (`test_j_tarski.ml:18-42`); ✗ stuck on non-`refl` (Debt #4) | `J` reduces on `refl` | framing (+ mark the boundary) |
| 4.3 | Change the representation under a failing system | **`Glue` / `ua`** (univalence): isomorphism is identity [#8, D11] | ✓ kernel (`test_glue.ml`; `transport_ua_succ.yon`→11); ✗ surface E2E (Debt #2-3) | `transp (Glue …)` applies the fwd map | framing (honest: kernel computes, surface partial) |
| 4.4 | A loop no instrument sees | **HIT, S¹, `loop`** (via `cell from..to` + `hit_elim`) [#9, D12]; Kan `comp`/`hcomp`/`transp` (scoped) [D10] | ✓ (`test_hit_compute.ml`; `circle_hit.yon` exit 42); scoped (single-face, `todo-1.2`) | the circle: a non-trivial path no byte-compare sees | **real** (the loop ↔ the invisible breeding) |

### Iteration 5 — Logic of the undecided & the error · *"flaws will now become severe"*
JP: a juvenile **male** raptor bred in the wild — the "all female" certainty was
never true, only *assumed*. The flaw is now undeniable.

| Ch | JP scene | Yon concept(s) [D] | Verdict (source) | `.yon` | Hook |
|----|----------|--------------------|------------------|--------|------|
| 5.1 | "All female" was never proven | **Heyting Ω (Gödel G3)**: `present/absent/unknown`, `=>?` `!?`, no LEM [#5, D15] | ✓ (`test_prop_eval.ml:76-164`; `decidable_unknown.yon` exit 134) | a sensor returns `unknown`, not `false`; `neg(unknown)=unknown` | **real** (unknown ≠ false — the epistemics InGen lacked) |
| 5.2 | Evolution has a direction | **directional subtyping** `number <: heyt_int <: prop` [#16] | ✓ (`test_dispatcher.ml:60-64`: reverse = false) | forward promotes; reverse is rejected | framing |
| 5.3 | The breach is a place | **`place P on error E`**, monad `+E` [#17]; **closed arrows**, local capture = error [#18, D7]; effects/concurrency [D13] | ~ error-as-place **declared** (`error_morphism` accept); ✓ capture-reject (`closed_morphism_capture` exit 3) | an error place; a closed arrow that rejects a leak | **real** (containment as a typed destination) + framing (Nedry is human) |

### Iteration 6 — Sheaf, descent, morphisms, wire · *"system recovery may prove impossible"*
JP: power restoration backfires; the raptors besiege the lodge; recovery keeps failing.

| Ch | JP scene | Yon concept(s) [D] | Verdict (source) | `.yon` | Hook |
|----|----------|--------------------|------------------|--------|------|
| 6.1 | A whole is its coherent parts | **sheafification / descent reject**: glue that violates the equivalence → the whole does not exist [#13, D6] | ✓ VIEW path (4 negatives, `sheaf.ml:62,88`); ✗ OPERATIONS path (Stage 2, Debt #1) | `view` that leaks the individual → rejected (exit 3); the invariant one compiles | **real** (topos vs collection — the deepest hook) |
| 6.2 | Translating between worlds | **`geom_morphism`** pull/push f*⊣f∗ [#14, D5]; **`morph on morphism`** (functoriality) [#15] | ✓ geom (`test`/examples + `cross_space/`); ~/✗ via-signature stub (Debt, "highest remaining value") | a pull/push across two worlds; a functoriality reject | framing → structural (combination gap: geom lives in big examples) |
| 6.3 | Isolated, and one dies unseen | **`wire` / DTO over SHM**: crossing is explicit, by value [#25, D14]; **prefork** isolation [#24, D13] | ~ wire **declared** (runtime real; surface red on Mac, Debt #6); ✓ prefork C facade (`test_spawn_collect.c`) | a `wire` between two spaces; an EOF | **real** (ontological isolation) + env debt |

> **Load note (author, approved).** Iteration 6 carries four concepts (sheaf ·
> descent · morphisms · wire) — the heaviest Part. Do NOT rebalance pre-emptively,
> but watch it when drafting: if it overflows, `wire` (6.3) drops to the tail of
> Iteration 5 (it is more *system* than *topos*).

### Iteration 7 — The idea (Yoneda) & the reveal · *"the mathematics will demand the courage to face its implications"*
JP: Malcolm's deathbed lectures; Grant counts eggshell impressions in the raptor
nest; the raptors line up to **migrate**.

| Ch | JP scene | Yon concept(s) [D] | Verdict (source) | `.yon` | Hook |
|----|----------|--------------------|------------------|--------|------|
| 7.1 | "An object is what is observed of it" | **Yoneda** (representable): `Hom(P,Q) ≅ Nat(よP,よQ)`; place-as-presheaf [#1]; single normalizer as Yoneda-discipline [#27] | ✓ representable (`test_yoneda_typed.ml`, `test_yoneda_lemma.ml`); ~ place-as-presheaf declared (`ast.ml:8`) | the `recv.f` dispatch as the lemma in motion | **real** (the climax) · mark the boundary (representable, not general internalized Yoneda) |
| 7.2 | The reveal: top is bottom | **content-addressing WAS Yoneda** — the Iter-2 silicon re-read as the Iter-7 idea [#2 + Yoneda] | ✓ (re-runs #2 with the new eye) | the same dedup program from 2.1, now read as Yoneda | **real** (the whole-book payoff) |
| 7.3 | Count the eggshells; read the migration | **proofs evaporate**: `type_erase` (pay correctness at compile time, zero runtime) [#20]; the migration as Leech proximity [#21] | ✓ core (`type_erase.ml`, `test_type_erase.ml`); ✗ higher-order (Debt #11) | a final integrated park program: count by content, locate by Space, read distance on Λ₂₄ | **real** (the count done right) |

### The close (after Iteration 7)
The Epilogue ("None of us is going anywhere") + the honest boundary restated: Yon
closed the ontological gap, not the human one. *"I hope I got it right"* — now the
reader judges.

---

## Recorded visualizations (Yon computes, React replays)

Emission is **stdout-only** via the `Output` place (`emit_mlir.ml:438,2922`) — there
is no native structured trace. So each player needs a thin build-time harness
`.yon → emit → run → (stdout) → harness → trace.json`; React replays the JSON. The
**JSON capture is a tooling step / language debt**, told honestly; the *computation*
is real Yon. A hostile reader can regenerate every JSON.

| Player | Attaches to | What Yon computes & prints | Backing verdict |
|--------|-------------|----------------------------|-----------------|
| **Fractal** | opens all 7 Iterations (7 frames) | a Mandelbrot/escape iteration emitting points (numeric loop + `Output.print`) | ✓ arithmetic + I/O (D0); **needs a new `.yon`, Mac-gated** |
| **Paddock map** | Iteration 3.3 | dinosaurs as points: identical genomes = ONE content slot but TWO `Space` cells | ✓ content-addressing [#2]; ✓ Space cell [#3 — write `x=e`/`Space__set`, read `Space__get`, runtime-backed]. **BOTH halves green.** |
| **Genome** | Iteration 2.2 | a VoyagerList codeword: corrupt → recover, before/after bits | ✓ Golay [#22] |

---

## What the book can show working vs what it tells as open research

**Coverable today (green test exists):** #2 content-addressing · #4 NoCarrier · #5
Heyting Ω · #6 Id/PathP · #7 J · #8 ua (kernel) · #9 HIT · #10 η_Σ · #11 universes ·
#12 world algebra · #13 sheaf (VIEW) · #16 directional subtyping · #18 closed-arrow
capture · #19 exit-3 discipline · #20 type_erase (core) · #21 Leech 196,560 · #22
Golay · #23 mmap/arena · #24 prefork (C facade) · #26 Carrier printer · #27 single
normalizer · Yoneda (representable).

**Debts — told as open research, never faked:**
- #13 sheaf **OPERATIONS** path (Stage 2 — VIEW closed, operations not).
- #15 `morph on morphism` **via-signature** stub (COVERAGE "highest remaining value").
- #3 **Space cell** mutation (`=`) — no green run yet; gates the paddock-map player.
- #8 `ua`/Glue/transport **surface** end-to-end (kernel computes; surface partial).
- #20 **higher-order** `type_erase` (clean reject, not lowered).
- #24/#25 runtime **end-to-end on this Mac** (spawn/wire flaky — env, Debt #6).
- #1 place-as-presheaf, #17 error-as-place — accept-only / framing (no asserting test).
- **Co₀/Monster** link — real math, not code-exercised; mark the boundary.

**Combination gaps** (the book must show constructs *combined*; these exist only
inside big examples and lack an isolated micro-test): #14 geom_morphism, #17 error,
#25 wire, #9 HIT (single example), #3 Space cell, the full #12+#13+#1 "topos vs
collection" pairing. The recurring **park** is the natural vehicle to combine them.

---

## Docusaurus mapping (additive only)

- **Section**: a new sidebar in `website/sidebars.js`, "Jurassic Park in Yon",
  split into 7 categories (Iterations). Do not touch existing sidebars.
- **Docs tree**: `website/docs/jp/iteration-{1..7}/` each with `_category_.json`
  (label = the Iteration + its epigraph) and one `.mdx` per chapter
  (`sidebar_position`, `slug`).
- **Code blocks**: reuse `website/src/components/CodeWindow.js` for every `.yon`
  snippet with its real exit code. KaTeX for the mathematics, Mermaid for diagrams,
  the existing Prism Yon grammar for highlighting.
- **Players**: `website/src/components/{FractalPlayer,PaddockMap,GenomePlayer}.jsx`,
  each reading its JSON from `website/src/data/jp-traces/*.json`.
- **Trace pipeline**: the `.yon` sources live in `regression/book/jp/<chapter>/`,
  wired into pytest (the book gate); a small harness script emits the JSON into
  `website/src/data/jp-traces/`. Nothing is hand-authored JSON.

## The fixed chapter formula (every chapter)
1. **The scene (JP)** — retold in our words (no pasted Crichton; one-line Malcolm
   epigraphs only). 2. **The idea** — philosophy / in the language / on the silicon.
3. **The code (Yon)** — the `.yon` that models it; compiles; real output + exit code
   via `CodeWindow`. 4. **The verdict** — ✓ / declared / debt, with the source.

---

## Decisions for the author before drafting chapters

1. **The 7-Iteration ↔ concept mapping above** — approve, or rebalance any
   Iteration. (Heyting/errors sit in Iter 5, sheaf/wire in Iter 6 — by epigraph
   resonance, not by the spec's exact wording; confirm that's the right call.)
2. **Pedagogical tension, owned honestly**: the thematic ascent is silicon→Yoneda,
   but a reader needs the basic mechanics (D0–D1) early. The plan weaves them into
   Iterations 1–2 as connective tissue rather than giving them their own Part — OK?
3. **The Space cell (#3) — RESOLVED (closed by observation, 2026-06-26).** NOT a
   debt: a variable assigned with `=` is promoted to a Space cell (write `Space__set`,
   read `Space__get`, runtime `g_space_cells`/`yon_rt_space_set`/`_get`), green via
   `kw_list_here.yon` + the stream/fold lowerings (risolto + lowered). The paddock-map shows BOTH halves of the fourth wall green:
   one content slot (#2) + two location cells (#3). Kept distinct: `x.f = e` (place
   field) is a by-design reject (sections immutable, by design); `new…in` inline is
   a vestige (space = directory). Neither is used.
4. **Sample chapter**: the sandbox can't compile Yon (Mac-gated), so I can't
   guarantee a snippet compiles here. Want a Chapter 1.1 voice-and-format specimen
   with its `.yon` marked "pending Mac gate", or hold all code until you can gate it?
5. **The fractal player** needs a new `.yon` (numeric escape iteration + `Output.print`).
   Confirm I should author it (then you Mac-gate), or point me at an existing numeric
   example to base it on.
