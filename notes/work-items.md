# Yon — Work Items (open gaps → actionable units)

---

## ⏸ SESSION STATE — resume here: topos-per-space MILESTONE (swarm, UNCOMMITTED, needs build)

**Status: swarm edits LANDED on disk, NOT yet compiled. Build + fix + gate WITH Antonio.
Revert is the safety net (`git checkout -- frontend examples regression` if it goes sideways).**

What the swarm did (3 agents, disjoint file ownership; edits verified present on disk):
- **G (grammar)** `lexer.mll` + `parser.mly`: `morphism` keyword (MORPHISM_KW) for topos
  morphisms; `morphism_decl` production; `topos_morphisms_opt` uses it; `on morphism`
  in morph_item now uses MORPHISM_KW; **topos_decl drops `objects{}` / `at` / `in`** →
  produces `tp_objects=[]`, `tp_at_space=None`, `tp_world=None`. AST record shape UNCHANGED.
- **M (manifest/driver)** `package_layout.ml` + `manifest.ml` + `yoner_emit_mlir.ml`:
  `Manifest.assign_topos_structure` fills tp_objects/at_space/world from the filesystem
  (place-files of the topos's space); `check_one_topos_per_space` (mandatory, only for
  real named spaces — loose single files exempt); driver builds per-file space maps and
  wires both before `assign_place_worlds`. Exit 3 on layout violation.
- **C (corpus)** migrated 5 topos PROJECTS (c_prop_abstract, c_topos_at_space,
  kw_topos_block, sheaf_quotient_prop_ok, sheaf_quotient_prop_reject): inline places →
  own files, `objects{}`/`at`/`in` dropped, `operation`→`morphism`.
- **Me**: rewrote the gate-wired W6 negative `neg_morph_functoriality.yon` to the new
  grammar (top-level places + topoi with only `morphisms{}`; single-file ⇒ no one-per-
  space enforcement; W6 check uses tp_morphisms not tp_objects, so it still fires).

COMPILE/FIX checklist (expected, compiler-driven):
1. `cd frontend && dune build` — fix OCaml warnings-as-errors in the new agent code
   (unused vars/values likely) + any Menhir shift/reduce conflict (G expects none).
   `OBJECTS_KW` unused-token = warning only (menhir not --strict), harmless.
2. `bash swarm/hooks/gate.sh` — the 5 migrated projects must compile under the new
   manifest flow; the W6 negative must reject (exit 3).
M-agent flags to watch at gate: assign_topos_structure runs AFTER Module_prefix.mangle
(assumes bare local names survive); `places_of_space` order; per-space topos count
summed across files.
Still FLAGGED (low priority, untracked): 2 single-file `_pending_construct_tests`
(c_topos_at_space / c_prop_abstract) only minimally migrated — can't express FS-objects.

---

## ⏸ SESSION STATE (historical) — dropping the `with R { }` construct

**Status: COMPLETE, COMMITTED & PUSHED (origin/main @ `91e3ecf`). `with` construct
+ orphan handler cluster + dead-test cleanup fully dropped. Nothing pending here.**
- `6e0cfaa` — OCaml `with`-drop (Fase 1 grammar + Fase 2 SWith/With), -219 lines.
- Part C — handler cluster (MLIR op+pass, runtime, link scripts, test node, rm'd files).
- Both gate-GREEN (754 after Part C removed the reduction-inlining node).
NEXT: `git push` (sends `6e0cfaa` + Part C + the earlier `0835649` PathP fix).
COSMETIC DEBT — DONE (uncommitted, needs `dune build` to confirm no missed ref):
the 6 dead `with`-parsing kernel tests in `main.ml` cleaned — 5 removed
(test_hello_world, test_tycheck_with_handler, test_yoneda_typeclass_dispatch,
test_effect_inference_transitive, test_nested_with_stack) + their runner entries;
test_parse_reduction kept (stripped only its Test 10 `with`-block, Test 10a stays).
LEFT (truly cosmetic, intentional): comment-only `with_handler` mentions in the
MLIR pass docs (LowerToposToLLVM.cpp / LowerToposToStandard.cpp/.h) + a couple of
orphan doc-comments in main.ml. NB lost coverage: effect-inference + yoneda
place-reduction dispatch had main.ml smoke tests only through `with` — re-add
`with`-free versions if wanted.

MORPH (Alto-2 / W6) — demonstrating negative WRITTEN (not gate-wired):
`regression/_pending_construct_tests/neg_morph_via_signature.yon` (accepted today
= the red; sound hardening logged in `todo-1.2.md` §C). The functor-on-arrows
check stays a documented v1.2 item (can't harden the core blind).

DONE (uncommitted working tree, frontend compiles clean):
- **Fase 1 — grammar** (`parser.mly`): removed the `with_stmt` rule + its `stmt`
  reference. `with R {}` / `with R of P {}` no longer parse.
- **Fase 2 Part A — `SWith` surface node removed**: constructor out of
  `surface_ast.ml` + every arm (`method_sugar`, `tycheck` ×3, `yon_lsp`,
  `desugar` ×7, `module_prefix` ×3). `hm_infer` comment tidied.
- **Fase 2 Part B — `With` core node removed**: out of `ast.ml` + all ~18 arms
  (`reduce`, `subst`, `builtins`, `inline_seq`, `sct`, `type_erase`, `pretty`,
  `emit_mlir` ×6, `desugar` ×3) + 3 kernel-test fns in `main.ml`
  (`test_with_handle`, `test_nested_handlers`, `test_reduce_with_propagation`)
  and their runner entries.
- `cd frontend && dune build` = clean (no output).

LEFT INTENTIONALLY (not bugs):
- `locally_nameless.ml` still has 3 `With` arms — module is EXCLUDED from the
  build (`modules \ locally_nameless`), harmless.
- Dead-but-valid refs: `reduce.world_tag_setter`, `active_handlers`,
  `main.ml:5020` registration. Unused ≠ error here (verified in Part A).
- Test 88 `test_reduce_ctx_with_place` KEPT — uses `Reduce.with_current_place`/
  `pop_current_place`, NOT the `With` constructor.

RESUME STEPS, in order:
1. `bash swarm/hooks/gate.sh` — full pytest gate (expected GREEN: no corpus
   example uses `with R {}`).
2. If green, commit the OCaml `with` drop (Fase 1 + 2): the ~15 frontend files.
3. **PART C — orphan handler cluster: EDITS DONE (uncommitted).** All build/link/
   gate-relevant references removed. REMAINING to finish: `rm` the now-orphan
   files, rebuild (cmake+make+dune), gate.
   - EDITED (references removed): `mlir/TopOps.td` (WithHandlerOp def),
     `LowerToposToStandard.cpp` (LowerWithHandlerOp struct + illegal-op entry +
     patterns.add), `mlir/CMakeLists.txt` + `mlir/topos-opt.cpp` (drop
     ReductionInlining pass: source, include, register), `test_mlir_passes.py`
     (reduction-inlining node), `runtime/yon_rt.c` (facade + include),
     `runtime/yon_rt.h` (include), `runtime/Makefile` (OBJS),
     `runtime/yon_test_conway_chains.c` (build comment), `toolchain/yonc` +
     `regression/run_regression.sh` (link lists), RTSET in
     `test_runtime_units.py` / `test_llvm_ir.py` / `test_yon_selfhost.py` /
     `test_yon_pipeline.py`, `frontend/hm_infer.ml` (SWith comment tidy).
   - TO `rm` (orphan, no longer referenced — run on Mac):
     `mlir/passes/ReductionInlining.cpp` + `.h`,
     `runtime/xleech2_handler_stack.c` + `.h`,
     `regression/mlir_units/reduction_inlining_in.mlir` + `reduction_inlining_keep.mlir`
   - REBUILD/GATE: `cmake --build mlir/build --target topos-opt` &&
     `make -C runtime` && `cd frontend && dune build && cd ..` &&
     `bash swarm/hooks/gate.sh`.
   - **KEPT**: `xleech2_heap` / `xleech2_coord` / `xleech2_mphf` — Leech runtime,
     LIVE. Only `xleech2_handler_stack` removed.
   - COSMETIC DEBT (non-breaking, optional tidy): comment-only `with_handler`
     mentions in `LowerToposToLLVM.cpp` / `LowerToposToStandard.cpp/.h`; and 6
     dead `with`-parsing kernel tests in `main.ml` (Test 28 `test_tycheck_with_handler`
     @836 + the source-string tests around lines 267, 675, 3202, 3387, 4817) —
     they parse-fail now but don't run in the gate.
4. (Optional) negative test that `with R {}` is rejected — need the parse-error
   exit code first (it's a parse error, not exit 3).

ALSO OUTSTANDING (independent of the with-drop):
- Confirm commit `0835649` (PathP fix) is **pushed**.
- Uncommitted docs: this `work-items.md` + `COVERAGE.md` findings.
- The W-items below (W1–W11). Highest value: **W6 morph stub**, **W1 sheaf**.

---

HEAD `0835649`. One unit per open gap. Each carries a **Core-safety** field
(how it must NOT break Yoneda / CATT / HoTT / cubical) as a first-class
constraint, plus a red→green so the close is provable, not declared.

Invariant for every unit: the change must be SOUND first. The PathP episode is
the template — a blind tightening can introduce the *opposite* bug
(false-reject). So every unit that touches the typechecker/lowering ships with
(a) a positive that must still pass and (b) a negative that flips red→green, and
is gated on the Mac against the FULL corpus before commit.

Priority key: P0 soundness-flavored · P1 surface-construct realized · P2 coverage.

---

## W1 — Sheafification for overlapping coverings  [MLIR · P0 · project]

**Obiettivo (done =):** a `topology` with an OVERLAPPING covering emits the
runtime sheaf-compatibility check (sections agreeing on overlaps glue, uniquely);
a program whose sections DISagree on an overlap is rejected/!⊥ at run, not
silently accepted. Removes the "silent under-check" — the only soundness-flavored
gap of the five.

**Dove:** `mlir/passes/LowerToposToStandard.cpp:1308` ("the sheaf condition …
is not yet emitted by this pass"); `@covering` currently "informational metadata
(no operational effect)".

**Approccio:** in the FromSite/covering lowering, for a covering family with
pairwise overlaps, emit the gluing predicate: for each pair of covers (Uᵢ,Uⱼ)
emit the restriction-equality check on Uᵢ∩Uⱼ, and the existence/uniqueness of
the glued section. Stage it: first emit the *compatibility* check (sections
agree on overlaps) before the full descent (unique glue). Non-overlapping
coverings keep today's (correct) path.

**Core-safety (topos/Yoneda):** this is the Grothendieck-topology semantics —
must implement the ACTUAL sheaf condition (equalizer of the restriction maps),
not a stand-in. The sheaf is a presheaf F: Cᵒᵖ→Set satisfying the gluing
equalizer; the Yoneda embedding is faithful precisely because representables are
sheaves, so a fake check would corrupt the site. Do NOT weaken to "accept if
covers exist". Anchor against the existing sheaf oracles (test_sheaf) so the
non-overlapping descent is unchanged.

**Red→green:** positive — a project with a covering whose sections agree on the
overlap compiles+runs exit 0. Negative — same covering, sections disagree on the
overlap → rejected (today: silently accepted). The negative is RED now (this is
the demonstrable open debt), GREEN when emitted.

**Blast radius:** medium-high (touches the lowering all sheaf programs traverse).
Gate the full sheaf corpus (test_sheaf, the sheaf_quotient projects) every
iteration — must not regress the descent that already works.

---

## W2 — Multi-argument reduction lowering  [MLIR · P1 · medium]

**Obiettivo (done =):** a `reduction` clause with >1 argument lowers to a runtime
function instead of bailing; an n-ary reduction used in a program reaches the
binary.

**Dove:** `mlir/passes/LowerToposExtensions.cpp:184` ("Multi-argument reductions
are not yet …").

**Approccio:** generalize the single-arg lowering to fold the clause's parameter
list (curry or pass-as-tuple over the f64 facade); emit the per-clause runtime
fn `R__clause(args…)` the dispatcher already expects.

**Core-safety (CATT/δ-conversion):** reductions ARE the δ-conversion engine, and
termination is SCT-gated and fuel-free *by construction*. The n-ary lowering must
preserve the size-change ordering — the extra arguments enter the SCT graph, they
do not bypass it. Re-run the SCT oracle (test_sct) + the reduction examples
(reduction_fold) to confirm strong normalization still holds. No new
non-terminating rewrite path.

**Red→green:** positive — an n-ary reduction example compiles+runs exit 0 (today
the emit bails). Add it to baseline_exitcodes.txt as the red→green anchor.

**Blast radius:** medium (extension lowering). Gate reduction examples.

---

## W3 — Closure conversion for escaping probes  [MLIR · P1 · medium]

**Obiettivo (done =):** a probe (observation closure) that ESCAPES its defining
scope gets its captured environment converted to a heap closure instead of
"not yet supported".

**Dove:** `mlir/passes/LowerToposExtensions.cpp:553` ("closure conversion not yet
supported").

**Approccio:** standard closure conversion — lift the escaping probe to a
top-level fn taking an explicit environment record; allocate the env (arena, no
malloc — match the runtime's zero-malloc discipline) and thread it through the
facade.

**Core-safety:** probes are observation/effect closures, not type-theory terms —
no CATT/HoTT impact. The constraint is the effect/linearity discipline: a probe
that escapes must keep its capture read-discipline (no aliasing a moved section).
Verify against effect_propagation / handle_lambdas examples.

**Red→green:** positive — an escaping-probe example compiles+runs (today bails).

**Blast radius:** medium-low (one lowering branch, off the common path).

---

## W4 — `with`-handler dispatch: emit the op + real payload  [emit + MLIR · P1 · medium]

**STATUS (verified from code, 3 layers — NOT a single "not yet connected"):**
- Runtime `xleech2_handler_stack.c` — DONE & integrated, not orphan.
  `yon_handler_push(hash, fn_ptr)` / `pop` / `lookup` are complete (O(1) hash
  dispatch, per-thread LIFO stack), exposed via the facade `yon_rt.c:3028-3038`,
  certified by the handler-stack oracle. Solid foundation.
- MLIR op + lowering `LowerWithHandlerOp` (`LowerToposToStandard.cpp:1729`) —
  EXISTS but is an M4 STUB: it emits PAYLOAD-LESS `yon_handler_push()`/`pop()`
  (L1748-1755: `getFunctionType({}, {})` — no hash, no fn_ptr), so it installs a
  token, not a real handler. And it never fires, because…
- Frontend `C.With` (`emit_mlir.ml:4625`) — PASSTHROUGH: never emits
  `topos.with_handler`, so the lowering pattern is dead from the surface. The
  comment at :4628 ("XLeech2 runtime not yet connected") is about THIS scope —
  it is the effect-handler, NOT the wire (the wire is wired end-to-end, seal
  campaign). Fails LOUD today, not silent.

**Obiettivo (done =):** `with HANDLER of PLACE { body }` installs the real
handler: `C.With` emits `topos.with_handler` carrying the handler identity, and
`LowerWithHandlerOp` is upgraded from payload-less M4 to threading
(hash, fn_ptr) into the real `yon_handler_push`/`lookup` so inner handled ops
dispatch through the stack — instead of the body running raw and only failing
loud when an inner op needs the handler.

**Approccio (two middle layers; runtime untouched):**
  1. emit_mlir `C.With` → emit `topos.with_handler` with the handler's trampoline
     hash + the place identity (stop the passthrough).
  2. `LowerWithHandlerOp` → replace the empty `{}`→`{}` push/pop with the
     real signature: compute the trampoline hash, materialize the fn_ptr, pass
     both to `yon_handler_push(hash, fn_ptr)` and balance with `pop(hash)`.

**Core-safety:** algebraic effect handlers — the stack discipline is already
tested (handler-stack oracle), and the runtime is untouched, so no type-theory /
CATT / cubical impact. Risk is frame leak/imbalance (push without matching pop).
Gate the handler-stack oracle + handle_lambdas + any with-handler example.

**Red→green:** positive — a `with`-handler example whose body invokes a handled
op compiles+runs exit 0, dispatching through the installed handler (today: raw
body / loud fail). Negative — imbalanced handler still rejected.

**Blast radius:** medium (frontend emit + one MLIR pattern; runtime stable).

---

## W5 — `Move.merge` surface form  [surface · P1 · small]

**Obiettivo (done =):** the merge form is reachable from surface syntax, not just
from the engine; a program that writes the merge surface form lowers to the
existing `Move.merge` runtime.

**Dove:** `frontend/builtins.ml:540` ("Merge form not yet wired through surface").
Engine exists; this is surface plumbing.

**Approccio:** add the surface→builtin binding for the merge form (lexer/parser
already? verify) and route it to the existing Move.merge engine call. Smallest of
the five — the backend is done.

**Core-safety (Yoneda/morphisms):** `Move` is morphism composition / version
merge — the merge must remain the engine's (associative, version-monotone)
operation. Surface wiring must not invent new semantics; it binds the existing
one. Gate kw_merge_move + the move examples.

**Red→green:** positive — a merge-surface example compiles+runs exit 0 (today the
surface form is unreachable).

**Blast radius:** low (additive surface binding).

---

## W6 — `morph on morphism` functor-on-arrows check  [tycheck · P0 · careful]

**Obiettivo (done =):** an `on morphism n via m` with an INCOMPATIBLE `m` is
rejected (exit 3); today it is accepted (the check only verifies `m` exists).
Closes the accept-all on the categorical core — same class as PathP.

**Dove:** `frontend/tycheck.ml:2852` (`check_via_bindings`). Today: checks only
that `m_tgt` is a fun or reduction-with-clause `n_src`.

**Approccio (staged, sound-first):**
  1. **Existence of the source arrow:** verify `n_src` is a declared morphism of
     the SOURCE topos `mp.mp_source` — BUT degrade gracefully: if the source
     topos is not in scope (several examples reference UNDECLARED topoi, e.g.
     c_morph_on_morphism), SKIP the check rather than reject (no false-reject).
  2. **Functoriality of signatures:** derive the functor's object action F from
     `mp_on_object` (its param type X ↦ return type F(X)); require
     `m_tgt : F(dom n_src) → F(cod n_src)`. Compare via `Dispatcher.subtype`
     (the same relation hardened for PathP), NOT a bespoke equality.

**Core-safety (Yoneda/CATT — THE critical field):** the check must encode
functoriality F(f): F(X)→F(Y), nothing stronger. Over-constraining (e.g.
requiring dom=cod, i.e. only endomorphisms) would FALSE-REJECT legitimate
non-endo morphisms — the PathP bug inverted. The relation used is `subtype`
(already CATT/HoTT-correct), so universe/path conversion is untouched. The
graceful-skip in step 1 is mandatory: a morph over a topos not in scope must
remain accepted, exactly as today, or the ~10 morph/functor examples
(geom_morphism_*, functor_compose_*, nat_transform_functor) break.

**Red→green:** negative — a morph whose `via` target has an incompatible
signature, accepted today → rejected after. Positive — c_morph_on_morphism and
all existing morph examples STILL compile (the must-not-regress set).

**Blast radius:** HIGH (core typechecker, ~10 examples). MUST be built
iteratively on the Mac against the full morph/functor corpus. Do NOT commit until
every existing morph example is green AND the new negative flips.

---

## W7 — child_exit → noreturn  [emit + LLVM test · P1 · small]

**Obiettivo (done =):** `Spawn__child_exit` is declared `noreturn`, so the LLVM
declaration carries the attribute; strengthen `test_ll_child_exit_unreachable`
from the tolerant "safe-by-deadness" form to assert the attribute.

**Dove:** `frontend/emit_mlir.ml:5715` (facade decl); test in
`regression/test_llvm_ir.py`.

**Approccio:** emit the child-exit facade decl with a noreturn passthrough; THEN
dump the real `.ll` of spawn_parallel_collect and write the assertion against the
OBSERVED form (inline `noreturn` vs attribute group #N) — not guessed. Assert the
ATTRIBUTE, not literal `unreachable` (that's an LLVM SimplifyCFG opt, not emitted
by mlir-translate).

**Core-safety:** runtime/codegen only — no type-theory impact.

**Red→green:** pre — no `noreturn` on the decl (red). post — present (green).

**Blast radius:** medium — if mlir-opt/topos-opt reject the attribute, the
lowering of ALL examples breaks. Gate immediately; revert the two hunks if the
func verifier refuses it. This is why it ships as one isolated experiment.

---

## W8 — desugar oracle (Layer 2)  [OCaml unit · P2 · small]

**Obiettivo (done =):** a `test_desugar.ml` known-answer oracle pinning the
Surface→Core rules (let → App(Lam,v); inline-lambda lift), wired in frontend/dune;
its [PASS]/[FAIL] become test_oracle_checks nodes. Last missing Layer-2 unit.

**Dove:** new `frontend/test_desugar.ml`; `frontend/dune` names list.

**Approccio:** call `Desugar` on small known Surface terms, assert the Core AST
shape (structural equality on a handful of cases).

**Core-safety:** read-only oracle — observes, changes nothing. Cannot break the
core; it can only CATCH a desugar regression.

**Red→green:** N/A (additive oracle); it just runs green on correct desugar.

**Blast radius:** zero (new test executable, no production code touched).

---

## W9 — handle-type stratification negatives  [surface · P2 · small]

**Obiettivo (done =):** a plain lambda passed where a move/reduction/morph handle
TYPE is required is rejected (exit 3) — proving the stratification check bites.

**Dove:** new negative projects under `regression/yon_tests/negative/` (need
declared places → project form).

**Approccio:** write minimal projects that pass a bare `λ` into a handle-typed
slot. VERIFY-FIRST: confirm each is actually rejected for the RIGHT reason
(handle-type mismatch, not an incidental parse/scope error) — the PathP lesson.
If a check turns out to be a stub (accept-all), it becomes its own W-item, not a
false-green test.

**Core-safety:** handle types stratify the effect/morphism layer above the base
CATT types; the negatives only ASSERT existing rejection, they add no semantics.

**Red→green:** each negative must reject today for the right reason (verify via
the actual diagnostic, as with neg_pathp_endpoint).

**Blast radius:** zero on production (test-only) — but gated to confirm "bites".

---

## W10 — mini-project construct negatives  [surface · P2 · careful-each]

**Obiettivo (done =):** `place P over X`, `cell`, abstract `prop`, `topos T at
Space` each have a negative that proves their check bites (incorrect use →
exit 3). The c_* examples already cover the POSITIVE (compiles); these add the
"check bites" side.

**Dove:** new negatives under `regression/yon_tests/negative/` (project form).

**Approccio:** per construct, write the ill-formed use the check SHOULD reject
(e.g. `place Slice over Base` violating the over-relation; an abstract prop used
where a concrete is required). CRUCIAL — verify each one rejects TODAY for the
right reason. Given the morph finding, SUSPECT each may be a stub: any that
accepts-when-it-should-reject is promoted to a W-item (harden the check), not
shipped as a passing test.

**Core-safety:** `place over` is the slice/subobject relation, `cell` is a HIT
path constructor, `topos at Space` binds a topos to a Space — each negative must
target the construct's OWN well-formedness, not collide with the type core. No
hardening here unless a stub is found (then it gets a PathP-style careful unit).

**Red→green:** per construct, red only if a stub is found; otherwise the negative
just documents that the check bites.

**Blast radius:** zero on production unless a stub forces a hardening unit.

---

## W11 — broaden LLVM examples 6 → ~10  [LLVM test · P2 · trivial]

**Obiettivo (done =):** the `EXAMPLES` list in test_llvm_ir.py covers more runtime
families (math, list/seq, time/random, capability).

**Dove:** `regression/test_llvm_ir.py` `EXAMPLES` list (one-line edit).

**Approccio:** add a few example names that already build (e.g. math_ext,
route_history, capability_flow_demo, land_reach). The harness SKIPS any whose
pre-LLVM stage fails, so this is zero-risk; it only adds coverage where they lower.

**Core-safety:** test-only, no production code.

**Red→green:** N/A (additive coverage).

**Blast radius:** zero.

---

## Suggested order

1. **W6 morph** — the real soundness gap on the core (PathP class). Highest value,
   needs the careful Mac loop.
2. **W1 sheaf overlapping** — debt #1, the only other soundness-flavored gap; a
   project, not a line.
3. **W7 child_exit, W8 desugar, W9 handle-neg, W11 broaden** — the small,
   low/zero-risk units the normal write→gate loop closes quickly; W5 merge
   (small surface) alongside.
4. **W2 multi-arg reduction, W3 closure-conv, W4 with-handler** — the remaining
   backend wiring, medium each.
5. **W10** — per-construct negatives, each verified-first (may spawn hardening
   units).
