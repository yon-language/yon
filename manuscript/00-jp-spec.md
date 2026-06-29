# Spec — "Jurassic Park in Yon" (governing brief)

> This is the **governing specification** for the JP reframing of the Yon book.
> It supersedes the organizing principle of `book-plan.md` for the JP structure
> (the 7 Iterations spine). The deliverable it asks for is
> `manuscript/01-jp-structure.md` (structure only, then stop for review).
>
> The author's prompt is reproduced **verbatim** below. A dated **Verification
> log** is appended at the bottom: it records corrections established *from the
> code* (per the spec's own "verify, never from memory" contract) — file-name
> fixes and surface-vocabulary drift. The verbatim prompt is NOT edited; read the
> verification log alongside it.

---

## Author's prompt (verbatim)

# Task: structure "Jurassic Park in Yon" — a pedagogical book in Docusaurus

You are working inside the repository of the Yon programming language. You must
**structure** (not yet fully write) a book that teaches Yon through Michael
Crichton's novel *Jurassic Park*, integrated into the project's existing
Docusaurus site. The JP epub is supplied alongside this prompt; read it.

## Working contract (non-negotiable)

1. **Verify every claim from the code, never from memory.** Before writing that a
   Yon construct "works", "does X", or "exists", confirm it with `grep`, source
   reading, or a test. The sources of truth in the repo are:
   - `regression/COVERAGE.md` — the 5-layer test coverage matrix, gaps marked `[ ]`.
     The official map of what is verified.
   - `audit_language.md` — the feature-by-feature audit with
     resolved/partial/declared/debt verdicts and supporting `file:line` anchors.
   - `manuscript/00-blueprint.md` — the book blueprint (voice, register, the three
     planes, the recurring example). The JP book IS this book: Jurassic Park
     becomes the recurring example in place of Account/Ledger.
   - the `git log` — feature history: what was added and what was removed.
   - the oracles (`frontend/test_*.ml`), the examples
     (`regression/keyword_coverage/*.yon`, `examples/*.yon`) and their exit-code
     baseline.

2. **Mandatory honesty marking.** Every construct presented in the book carries
   one of three verdicts, with its source:
   - **✓ verified** — a test/oracle/compilation exercises it (name which).
   - **declared** — true by design but not covered by a test; say so openly.
   - **debt** — known and open, with the pointer.
   A claim without a source does NOT enter the book. This rule protects the
   project's reputation: the model reader is hostile and competent.

3. **Exact vocabulary.** Use only the names that actually exist in Yon. In
   particular: there is NO `section` keyword — it is only the internal name of the
   MLIR type `!topos.section<"P">`. At the surface, an inhabitant of a place is
   built with `new P { ... }` and a name is bound with `be x holds e`. Verify
   every keyword against `frontend/lexer.mll` before using it in an example.

4. **Language:** the book's prose is in **English** (technical register, warm in
   the connective tissue, lean, no hype — see the voice specimen in
   `00-blueprint.md` and render it in English). Yon code and its comments are
   already in English.

5. **No invented code.** Every `.yon` snippet in the book must compile. If a
   construct is needed for the narrative but is a debt (does not compile yet), it
   is told as a declared debt, NOT faked as working.

## The load-bearing structure (from the novel)

*Jurassic Park* is built on **seven Iterations** (its Parts). Each opens with the
Mandelbrot fractal redrawn one step further and an epigraph from Ian Malcolm. Laid
end to end, the seven epigraphs trace a collapse curve. Verify the exact texts in
the supplied epub; in summary:
1. few clues to the underlying structure
2. sudden changes appear
3. details emerge more clearly
4. underlying instabilities begin
5. flaws become severe
6. recovery may prove impossible
7. the mathematics demands the courage to face its implications

**The 7 Iterations become the 7 parts of the book.** At each Iteration the
"fractal" being redrawn is Yon itself revealed one plane deeper, following the
conceptual dependency graph (silicon at the bottom to Yoneda at the top): native
ground → lattice/silicon → ontology (place/world) → identity and homotopy
(Id/path/Glue/HIT) → behaviour and space (arrows/geom/Space) → sheaf/wire → the
idea (Yoneda). Map the 7 epigraphs onto the 7 concept groupings so the epigraph
resonates with the content.

## The framing: "I tried to engineer a Jurassic Park that works"

The book opens — before the first Iteration, before Malcolm's first epigraph —
with the author's own line, first person, standing alone:

> "I tried to engineer a Jurassic Park that works. I hope I got it right."

This is the opposite of InGen's voice. Hammond never said "I hope I got it
right" — his certainty that the system was foolproof WAS the flaw. The author's
line carries the humility Hammond lacked, and it sets the whole register: the book
does not claim to have closed Crichton's gap, it invites the hostile reader to
look for the crack. Malcolm's posture, not Hammond's.

The line works on two planes at once. In the fiction, it is the new builder
addressing the reader. In reality, it is the author speaking about the language —
because that is literally what was done: an attempt to engineer the substrate on
which such a park would hold. The author's line and Malcolm's first epigraph
answer each other: "I tried" / "few clues to the underlying structure". Over seven
Iterations the structure is redrawn, until the reader can judge whether it held.

## The thematic bridge (why JP and Yon touch)

The engine of Jurassic Park is a **problem of identity and counting**: Hammond
counts the dinosaurs and trusts the number, but the system is already out of
control because the dinosaurs breed and the boundary between "the same" and
"another" breaks down. This is exactly the ontological problem Yon solves by
construction: a `place` is an object, an inhabitant's identity is its content
(content-addressing: two indistinguishable dinosaurs share the same slot by dedup),
and true individuality lives in the **Space cell** (location, not content). Hammond
conflates extension and location — the error Yon makes a type error.

This is the **"fourth wall"**: the point where the reader sees the Jurassic Park
disaster could not have happened in Yon — not by magic, but because Yon makes
compile-time-rejectable what was a silent assumption for InGen. Stay open to
discovery: forcing Crichton's chaos inside Yon's invariants is an experiment, not
an illustration — if an unexpected property emerges, annotate it honestly as such.

**The honest boundary (this is what makes the opening line true, not just nice).**
Yon closes the class of errors it actually catches: identity confusion, cross-world
leaks, descent that breaks a quotient, carrier-less inhabitants. It does NOT close
the errors no type system catches — Nedry's sabotage, the storm, the human decision
to cut staff. The book is stronger for saying this plainly: Yon closes the
**ontological** gap (the structural one, already in the data), not the **human**
one. For each chapter, mark whether the JP scene carries a real ontological hook Yon
catches, or is narrative framing only — never force a "Yon would have saved this"
where there is none.

## Fixed chapter formula

Every chapter follows this four-beat structure:
1. **The scene (JP)** — a moment from the novel, in prose. Paraphrase Crichton in
   your own words; do not paste novel paragraphs. Malcolm's one-line epigraphs may
   be quoted briefly (fair use); extended scenes are retold, not reproduced.
2. **The idea (the theory)** — the categorical/cubical concept the scene evokes, on
   three planes: philosophy / in the language / on the silicon.
3. **The code (Yon)** — the `.yon` program that models the scene. It compiles. With
   the real output and exit code.
4. **The verdict** — ✓ verified / declared / debt, with the source in the code.

The recurring example that grows through the book is the **park**: a dinosaur is
born as a `place`, the park is a `world`, the paddocks are `Space`s that communicate
over a `wire`, two identical specimens share one fossil by content-addressing yet
live in distinct Space cells.

## Recorded visualizations: Yon computes, React replays

Some chapters carry an interactive visualization. The rule is strict and it is the
whole point: **the React component does NOT compute — Yon does.** A `.yon` program
is compiled and run; its execution emits a trace of points (states, frames,
coordinates); that trace is captured as JSON in the repo; the React component reads
the JSON and replays it (animate, scrub, show). React is a witness, not an actor —
exactly like `CodeWindow` shows the real exit code rather than asserting it. A
visualization computed in JavaScript would be a lie about what Yon does; a
visualization replayed from a Yon-emitted trace is a proof rendered watchable, and
a hostile reader can regenerate the JSON from the `.yon → emit → run → trace.json`
pipeline.

Three roles, on three planes (do not pick one — assign each to where it earns its
place):
- **The fractal — structural device.** The novel opens every Iteration with the
  Mandelbrot fractal redrawn one step further. A player that shows the fractal grow
  — computed in Yon, emitted as points, replayed in React — opens each of the 7
  Iterations. Seven frames, one per part: Crichton's device made interactive, the
  red thread binding the parts like Malcolm's epigraphs.
- **The paddock map — ontology.** Dinosaurs as points on the park map. Two
  indistinguishable T-Rex are ONE point in content-addressing (same fossil, same
  slot) but TWO points on the paddock map (two Space cells). The animation shows
  identity-vs-location in one glance, and shows why Hammond miscounts: he counts
  map-points believing he counts content-points.
- **The genome — silicon.** DNA sequences with frog fragments filling the gaps are
  a completion-and-correction problem; Yon has Golay/Voyager error correction on the
  lattice. Keep the analogy on a SHORT leash: Yon does not "repair DNA" — it shows
  how a code is corrected when correction is a mathematical structure, not a
  stopgap. InGen's gap-filling introduced the breeding bug; Golay recovers cleanly.

**Verify before promising.** Confirm from the code that a `.yon` program can emit a
structured trace (Yon prints via the `Output` place / `Console` reduction; turning
stdout lines into JSON is a small tooling step). If structured emission is a debt,
say so and use the format that exists — never invent JSON that pretends to come out
of Yon.

## Docusaurus integration

The site exists at `website/` (verified). Concretely:
- `website/src/components/CodeWindow.js` — the existing component for code blocks
  with output. Use it for `.yon` snippets with their exit codes.
- `website/sidebars.js` — the sidebar config. The book is a NEW section, split by
  Iteration (7 parts). Hook it in here.
- Study how the existing docs use KaTeX (the mathematics) and Mermaid (diagrams)
  and the Prism grammar for Yon; reuse them, don't reinvent.
- The recorded-visualization React components live as site components reading their
  JSON traces from the repo.
- Do NOT break the existing site. Additive work only.

## What to deliver NOW (the structure only, not the whole book)

1. Read the JP epub **in full** (the 7 Iterations, prologue, epilogue, the
   introduction, Malcolm's epigraphs). Exhaustive reading, not sampling.
2. Study the repo in this order: `manuscript/00-blueprint.md` (voice, three planes),
   `regression/COVERAGE.md` (what is verified), `frontend/lexer.mll` (the real
   ~110 keywords), `audit_language.md` (verdicts and anchors), the `website/` site.
3. Produce `manuscript/01-jp-structure.md` containing:
   - the map of 7 Iterations → 7 parts → Yon concept groupings, with each
     Iteration's Malcolm epigraph and why it resonates;
   - the reasoned table of contents chapter by chapter (chapter title = JP scene +
     Yon concept), giving for each chapter: the scene, the concept(s), the concept's
     status in the code (✓/declared/debt with source), one line on the `.yon`
     program that will model it, and whether the scene carries a real ontological
     hook or is narrative framing only;
   - which recorded visualizations attach to which chapters (fractal / paddock map /
     genome), and confirmation that the emission they need exists in the code;
   - the list of Yon constructs that are coverable and those that are NOT (debts),
     so it is clear in advance what the book can show working and what it tells as
     open research;
   - the mapping onto the Docusaurus site (file locations, sidebar wiring).
4. **Stop there and propose the structure for review.** Do not write the chapters
   until the backbone is approved. Optionally include ONE sample chapter (the
   first) as a voice-and-format specimen, clearly marked as a draft — but only if
   its every `.yon` snippet compiles and carries its verdict.

## How to begin

Read in the order given above (blueprint → coverage → lexer → audit → site → epub
in full), THEN write `01-jp-structure.md`. Before proposing, announce what you
found — especially any gap between what the book wants to show and what the code
can currently back. The opening line is the standard: "I tried to engineer a
Jurassic Park that works. I hope I got it right" — the structure you propose should
let the author earn it.

### Author's addenda (from the kickoff message)

- Every single Yon construct must be covered in the book — **and combined with the
  others** inside the story, not just in isolation.
- An "inspiration list" of constructs will be supplied separately (incoming).
- We still need to **decide a mechanism to record the values Yon emits** (the trace
  problem for the recorded visualizations). Open joint problem.

---

## Verification log — book-wright (2026-06-26)

Grounded against the code per contract rule #1. The verbatim prompt above is left
untouched; these are the corrections to apply when executing.

### Source-of-truth file references (corrections)

| Cited in spec | Reality | Action |
|---|---|---|
| `manuscript/00-blueprint.md` | **does not exist** | blueprint is `manuscript/book-plan.md`; living spine is `manuscript/state.md` |
| `audit_language.md` | ✓ exists (repo root) | use as-is |
| `regression/COVERAGE.md` | ✓ exists | use as-is |
| `DOCS_DIFF.md` | lives at `swarm/DOCS_DIFF.md` | adjust path |
| (additional ground truth) | `swarm/LANGUAGE_AUDIT.md` exists | cross-check against `audit_language.md` |

**Authoritative inventory & ordering (use these — do not re-derive a list by hand):**
- `swarm/AUDIT_INVENTORY.md` — Gate 0 *perimeter* taken from the code: every lexer
  keyword (~130), token, top-level (21), expression (38), type (24), builtin module
  (~36). No verdicts, just what exists.
- `swarm/AUDIT_CONSTRUCT_ORDER.md` — the **D0–D16 pedagogical ladder** with tiers
  (T3 runtime-verified / T2 emit-or-reject / T1 parse-only) AND an existing
  *Jurassic-superpowers → construct* mapping. Already reconciled with the filesystem
  correction (D2: dir=space/file=place/world-in-toml) and place-as-object (D3). This
  is the construct-ordering backbone for the book; build the structure on its rungs.
- `manuscript/construct-inventory.md` — the book-facing ✓/declared/debt distillation
  (this project), cross-referenced from the three files above + oracles + runtime
  tests, with `file:line` anchors.

### Surface vocabulary (verified against `frontend/lexer.mll`)

Confirmed TRUE in the spec:
- **No `section` keyword** — 0 matches. It is the MLIR type name only. ✓
- `new P { ... }` builds an inhabitant — `NEW` token, `lexer.mll:173`. ✓
- `be x holds e` is the binding form — `LET`/`HOLDS`, `lexer.mll:121,186`. ✓
- `place` / `space` / `wire` / `morphism` are real keywords. ✓
- The four arrows `move` / `view` / `reduction` / `operation` are real. ✓

**The filesystem ontology (code-verified — corrects two earlier mistakes).**
The mapping from the project tree to (world, space, place) is — per the *live code*
in `package_layout.ml`, NOT its stale header comment (lines 5-21), and confirmed by
the example trees and commit `9ccb859` ("file-naming: 1 place/file,
filename=placename"):

- **file = place.** A `.yon` file's basename IS the place it declares (`place_of`,
  `package_layout.ml:45-48`). `Rex.yon` declares place `Rex` — one place per file.
  The **body uses the `place` keyword**: a real compiling example is
  `place Counter with effects { count number  operation tick(n: number): number }`
  (`examples/reduction_fold/w/Counter.yon`). (An earlier draft of this note said
  "no `place` keyword" — that was wrong; filename = place name is the constraint,
  the keyword stays in the body. Verify the exact field/`new` syntax from examples
  before any snippet.)
- **directory = space.** The first path segment under the root is the space
  (`space_of`, `package_layout.ml:29-43`). `paddocks/Rex.yon` → space `paddocks`.
  A file directly under the root belongs to no space — the entrypoint area
  (e.g. `Entry.yon`).
- **world = the `yon.toml` manifest (TOML-ONLY).** Worlds are `[world.Name]` tables
  with `objects=[…]` and `spaces=[…]`; the membership `sd_world` is left `None` in
  the tree and supplied by the manifest (`package_layout.ml:78-82`). A world is
  NOT a directory and NOT an inline keyword. (Confirmed: `examples/verify_algebra`
  has `[world.Alg] spaces=["alg"]` + a directory `alg/`.)
- **`Topos.yon`** is the conventional topos-declaration file inside a space dir;
  inline keyword `topos Name where { … }` (`topos_decl`, `parser.mly:314`; v1.1
  topos-per-space drops `objects{}`/`at`/`in`). **`Entry.yon`** is the root
  entrypoint.

> **Two traps recorded so the book doesn't fall in them.**
> 1. `package_layout.ml`'s header comment (lines 5-7) says "dir = world, file =
>    space". That is the OLD model. The *code* (`space_of`/`place_of`) says **dir =
>    space, file = place**. Trust the code, not the comment.
> 2. There is no inline `world W { }` keyword and no inline `place` keyword: `world`
>    lives only in `yon.toml`; the inline declaration keyword is `topos`.

**JP payoff:** the spec's "the park is a world, the paddocks are spaces, a dinosaur
is a place" is then *literally* the project tree — `[world.Park]` in `yon.toml`; a
paddock = a directory (space); a dinosaur = `Rex.yon` (place); the paddock's topos =
`paddocks/Topos.yon`. The directory tree IS the park's ontology (its own chapter:
"the filesystem is the declaration").

`Space` / `Wire` capitalized are still not surface syntax — they are `space` /
`wire` (lowercase); capitalized forms are internal MLIR types, like `section`.
Space-cell mutation is `=` (`parser.mly:1080`); the `becomes` keyword was
**retired** (`SAssignBecomes` is a vestige AST name) — do not assert `becomes`.

**Method (author's standing rule).** Verify every keyword against the language's
*syntax files* at the moment a construct is used — never from memory or from a prose
comment. The syntax files are: `frontend/lexer.mll` (tokens) +
`frontend/parser.mly` (grammar) + `frontend/package_layout.ml` (filesystem
ontology). The archived `book-plan.md`/`state.md` predate v1.1 topos-per-space, so
their inline forms (`world W { }`) are stale; re-derive canonical terms from the
live syntax files before any `.yon` snippet.

### Trace emission — RESOLVED (2026-06-26): stdout-only

Verified against the code: Yon emits **only stdout**, via the builtin `Output`
place — a program prints by `visits Output` then `Output.print` (`Output__print`,
`emit_mlir.ml:438,2922-2925`; "Output buffer" `emit_mlir.ml:34`). There is **no
structured-trace / JSON emitter** in the frontend (no `to_json`/`trace.json`
primitive).

Consequence for the recorded visualizations (fractal / paddock / genome):
- They remain buildable AND honest. Yon **computes and prints** the points (states,
  frames, coordinates) to stdout; a thin build-time harness captures stdout into
  `trace.json`; the React component replays the JSON. "Yon computes, React replays"
  holds — React never computes.
- **Honesty marking:** the trace *format* is stdout lines (**declared**); the
  `stdout → trace.json` capture is a **tooling step / language debt**, not a Yon
  feature. Never present `trace.json` as something Yon emits natively. A hostile
  reader can regenerate it from `.yon → emit → run → (stdout) → harness → trace.json`.
- Note: Yon also has an evaluator (`frontend/eval.ml`, `eval_runner.ml`) — a `.yon`
  program can be *run* directly, still printing through `Output`. Confirm which path
  (compiled binary vs evaluator) is the practical source of the printed points when
  wiring the first player.

### Pre-existing book state — RESOLVED (fresh start, 2026-06-26)

Author's decision: **start from zero.** The earlier book is archived, not deleted,
under `manuscript/_archive/` (preserved for reference, not inherited):
- `_archive/book-plan.md` — the retired 22-chapter plan (dependency Parts 0–VI).
- `_archive/state.md` — old living spine (pre-topos-per-space, `world`-inline vocab).
- `_archive/01-the-impossible-park.md` — old Chapter 1 draft.
- `_archive/ThreeLenses.jsx` — old interactive component.

`manuscript/01-jp-structure.md` is to be built from this spec + the live code only,
with canonical terms re-derived from the syntax files. A new `state.md` is
initialized once the structure is approved. (Untracked, unwired site drafts
`website/docs/zz-draft-01-impossible-park.mdx` and `cubical.md` are leftovers from
the old draft; not in `sidebars.js`, harmless, left in place.)
