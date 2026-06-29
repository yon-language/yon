# Yon Book — state.md (living spine)

> Read this BEFORE writing any chapter. Update it immediately AFTER. This file
> prevents drift: terminology, voice, what's already introduced, open threads.
> Blueprint: `manuscript/book-plan.md`. Ground truth: `swarm/LANGUAGE_AUDIT.md`.

## Locked decisions (log)

- **Language of the book: English.** (Conversation with author: Italian.)
- **Single spine**: the dinosaur park (InGen Sim) is the recurring example
  across the whole book. Approved by author.
- **Scope: comprehensive** — foundations + categorical core + identity/
  univalence + logic + multi-process + tooling + reference. Benchmarks LAST.
- **Hard rule (book gate)**: a feature chapter is not done until (a) it has a
  runnable Yon test in `regression/book/<chapter>/` that is GREEN in pytest on
  the Mac, and (b) it shows the "disaster" in the most fitting mainstream
  language(s) — chosen per concept, NOT always Java.
- **Mainstream-disaster language per concept** (author's call): pick what hurts
  most. Heyting tri-value → SQL `NULL` (3-valued logic). Cross-space/geomorph →
  Go/Erlang. O(1) equality / content-addressing → C++/Java deep-equals.
  Effects/capabilities → Java/Go. Error model → Go errors/Rust Result.
  Sheaf-reject → Java/Python (runtime-hoped invariant). Univalence → none has a
  static equivalent (state that plainly).
- **Visuals**: interactive React components for Docusaurus (source in
  `manuscript/components/`), Mermaid/SVG diagrams inline; author explicitly
  wants live graphical examples that showcase Yon. Use the inline visualize
  tool to preview while drafting; keep the React source for the Docusaurus build.
- **Jurassic boxes** (4 beats: Academic Fetish / Enterprise Disaster / Dinosaur
  Solution / Business ROI) live INSIDE the ★ chapters, dry-ironic-deep voice.

## Voice specimen (LOCKED — match this register)

Book voice (EN):
> A hundred thousand dinosaurs move through the park, and each is two things at
> once: an animal with a heartbeat and a position, and a row of data someone
> wants to query. Storing them isn't the hard part. The hard part is that the
> biologist, security, and legal look at the *same* animal and must see
> *different* things — and none of the three may see what isn't theirs. In Java
> that's a promise written in a comment. In Yon it's something the compiler
> refuses to betray.

Jurassic-box voice (EN, dry/ironic/deep): short, four labeled beats, no fluff,
the seasoned engineer talking to management.

## Canonical terms / notation (APPEND-ONLY — never rename once defined)

Seeded (define in prose at first use; do not rename):
- **world** — a category (objects + structure-preserving maps).
- **place** — an object living in a world; a record-like entity.
- **space** — a runtime heap where instances of a place are allocated.
- **move / view / reduction / operation** — the four "arrows" (named maps).
- **quotient world** — `world Anon = User / rel`; a world modded by a relation.
- **sheaf condition / descent** — a map out of a quotient exists iff it is
  invariant under the relation; non-invariant ops are rejected at compile time.
- **subcontains** — sub-object injection `E ↪ Base` (`place E … subcontains Base`).
- **Id / path / refl / ind_path (J)** — identity type and its eliminator.
- **transport** — moving a value along a path of types.
- **univalence** — equivalences ARE paths; `ua(e)`; transport applies the fwd map.
- **Heyting tri-value** — `present / absent / unknown`; `&&? ||? =>? !?`; no LEM.
- **geomorph** — geometric morphism (pull ⊣ push) between sites/spaces.
- **Yoneda dispatch** — `recv.f(args) = f(recv, args)`.
- **filesystem-as-declaration** — the directory tree IS the declaration: a
  folder = a world, a `.yon` file = a space, a place inherits its folder's
  world; `world.yon` carries construction (`/ Rel`, `= A+B`, `subset of`);
  `yon.toml` is the manifest. The explicit `world W {…}`/`space S in W` inline
  form is the canonical target the tree desugars onto. REAL + tested
  (`package_layout.ml` + `yoner_emit_mlir.ml` + `test_site.py`/`project_min`).
  Taught in Part VI (its own chapter); examples/tests use the inline form.

## Verified surface syntax (anchors, real & compiling)

```yon
world User { Person is Account }      // world with a place membership
world Anon = User / cohort            // quotient world
place Tag in Anon { cohort number }   // place in a world, fields: name type
view PublicProfile of Profile { show cohort }   // a view (projection)
place SyntaxError in W subcontains Error { message number line number }
fun main(): number { return 0 }
```
Sheaf-reject anchor: a `view … { show leak = secret }` where `secret` is NOT
invariant under the quotient relation is REJECTED (negative test
`sheaf_quotient_view_reject.yon`). The OK version exposes only the invariant
field (`cohort`).

## Terms introduced & where

- **Ch 1**: world, place, view, quotient (`A / r`), sheaf/descent condition
  (informally, as "a view must factor through the quotient"), invariant field.
  All introduced *informally as motivation* — proper vocabulary is Ch 2, full
  sheaf proof is Ch 8. Do NOT re-introduce from scratch later; build on these.
- Mainstream-disaster language used in Ch 1: **Java** (the "rule in a comment"),
  with Python/Go/SQL named as no-better. Reserve other languages for other chs.

## Recurring example — current state

InGen Sim. **Ch 1 done (draft)**: established the park, a `Dinosaur` place, the
three departments (Science/Security/Legal) as the tension, and the cohort
quotient as the legal lens. Teased the compile-time reject (paid off Ch 8) and
"change the DNA encoding without breaking code" is NOT yet teased (save for
Ch 12). Park world used: `world Park { Dino is Species }`,
`world PublicPark = Park / cohort`, `place Dinosaur in PublicPark { cohort
number, individual_id number }`. Keep these names stable.

## Open threads / foreshadowing

- Ch 1 teases the compile-time reject → paid off in Ch 8 (quotients & sheaves).
- Ch 1 may tease "change the DNA encoding without breaking code" → Ch 12
  (univalence/transport).
- Benchmarks promised only in Appendix D (re-measured when v1.1 is frozen).

## Conventions

- Yon code in ```yon. Disaster code tagged by its language (```java/```sql/
  ```go/```cpp…), always labeled WHY that language.
- Example source files prefixed `park_`. Each chapter's runnable test lives in
  `regression/book/<NN>/` and is wired into pytest.
- Every "the compiler guarantees X" claim links the test file that proves it.

## Asset & component inventory

- **Ch 1** · `manuscript/components/ThreeLenses.jsx` — interactive: one dinosaur,
  three lenses (Science/Security/Legal); shows the Legal lens quotients identity
  away. Docusaurus import: `@site/src/components/ThreeLenses`.
- **Ch 1 tests** · `regression/book/01/park_ok.yon` (must pass, exit 0),
  `regression/book/01/park_leak_reject.yon` (must be REJECTED). Need wiring into
  pytest + Mac gate before Ch 1 counts as "done".

## CRITICAL learning (Ch 1 correction)

The PLACE-LEVEL sheaf gate (`tycheck.ml:2787`) rejects ANY place on a quotient
world `Q = base / rel` that carries a field not invariant under `rel`:
"place X is not a sheaf … field(s) … not invariant under rel". So a quotient
place may carry ONLY rel-invariant fields. The full/individual data must live
on a place in the BASE world; the quotient place carries only the relation
field; views must factor through rel (anchor: `sheaf_quotient_view_ok.yon`).
EXEMPTION: synthetic view-places skip the place gate (the view check handles
descent). → My first Ch 1 example was WRONG (put individual_id on the quotient
place). Corrected: base-world `Dinosaur` (full) + quotient `PublicDino` (cohort
only) + `view LegalLens { show bucket = bucket_of(cohort) }`. The hook is now
the stronger place-level guarantee: you cannot even build a public record that
carries identity.

## Pending Mac gate (no fake green)

Ch 1 REWRITTEN filesystem-first (2026-06-21, after B1/5336d3e made park_project
compile). The chapter now teaches the directory-tree form: `yon.toml` +
`herd/Dinosaur.yon` (@Park) + `public/PublicDino.yon` (@PublicPark). Tests:
- `regression/book/01/park_project/` — compiles (Codex B1: emit-dir exit 0).
- `regression/book/01/park_project_leak/` — individual_id on the public record;
  EXPECTED reject (place-level sheaf gate, same as inline park_leak_reject which
  is gated green). Needs a quick Mac gate to confirm the leak variant rejects.
- (inline park_ok.yon / park_leak_reject.yon kept as extra regression; green.)
Still to wire: a pytest entry asserting park_project builds and park_project_leak
is rejected. NOTE: "filesystem ONLY" is NOT yet effective — inline still compiles
(B3 pending). Chapter teaches filesystem as THE form; honest.
