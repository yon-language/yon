# Yon test-coverage matrix & backlog

Single source of truth for the unified pytest harness across the 5 layers
(Yon · OCaml · MLIR · LLVM · C). Goal: complete unit + functional + integration
coverage, every construct / module / op / pass / function.

Harness entry: `python3 -m pytest regression`  (gate: `regression/gate.sh`
— rebuilds frontend `dune build` + runtime `make -C runtime`, then pytest,
count-tolerant; then the adversarial ratchet).

## Pyramid (measurable via markers — conftest.py)

Kinds: `unit` | `functional` | `integration`.  Layers: `yon|ocaml|mlir|llvm|c`.
Slice with `pytest -m`, e.g. `pytest -m "c and unit"`, `pytest -m functional`.

    for k in unit functional integration; do
      n=$(python3 -m pytest regression -m "$k" --co -q 2>/dev/null | grep -c '::')
      echo "$k: $n"; done

unit is the dominant base (one node per OCaml oracle via
test_oracle_checks.py, which fails on any internal [FAIL] line), functional in the middle, integration the tip.

  unit        — one module fn / one MLIR pass / one C fn, known-answer.
  functional  — a language feature emits / type-checks / is rejected (frontend).
  integration — full chain to a running binary; projects; cross-process wires.

---

## Layer 1 — Yon surface (every construct)

COVERAGE MODEL: test_yon_coverage.py enforces that EVERY lexer keyword is
exercised by compiling code (examples/ + keyword_coverage/ + yon_tests/ +
cross_space/) or a kernel oracle. The exercised-token scan strips comments
first: a keyword that appears only in a comment is not covered.
  - `forever` -> keyword_coverage/c_forever.yon (forever_stmt, real code).
  - `and`/`or`/`true`/`false` -> keyword_coverage/c_bool_logic.yon (real code).

DONE — single-file construct micro-tests (regression/keyword_coverage/c_*.yon,
functional): scope-anon, repeat-otherwise, lambda-block, arrow/map/El/PathP/
heyt-int/morph-handle types, generics `fun id<A>`, import-alias, quote, el_match,
bool-logic (true/false/and/or), forever.
DONE — negatives (regression/yon_tests/negative/neg_*.yon): return-mismatch,
return-tail, dup-param, empty-body, arity, unbound-var, path-app-nonpath,
quote-carrier-mismatch.
`init Name as Space` is not part of the language: the filesystem project model
takes its place.

DONE — project-context constructs POSITIVES, gate-wired example projects
(test_projects.py globs examples/**/yon.toml, asserts compile-accept):
`place P over X` (examples/c_place_over), `cell .. from .. to ..`
(examples/c_cell), abstract `prop p(..): proposition` (examples/c_prop_abstract),
topos decl in a space `Topos.yon` (examples/c_prop_abstract, kw_topos_block, +
every project). There is no `topos T at Space`: residence is
filesystem-inferred; the construct is the plain topos decl, covered everywhere.
DONE — handle-type STRATIFICATION negative: a plain arrow where a
`morph from S1 to S2` handle is required is rejected (exit 3); wired
`yon_tests/negative/neg_handle_plain_fn.yon` (the handle opacity is confined to
the topos identifiers, not the argument's arrow-vs-handle distinction).
DONE — morph on-morphism FUNCTORIALITY: `yon_tests/negative/
morph_functoriality_reject/` (a project: spaces w, v) rejects an `on morphism .. via wrong_sig` whose
signature is not F(dom) -> F(cod).

REMAINING — construct-specific semantic checks that are STUBS (accept-all on the
structural/categorical content; each accepted in project
context, exit 0). NOT wireable as negatives until hardened — wiring would be a
false-green. Each needs a red→green oracle (a minimal mutation of its passing
example) before it can be wired; hardening must be gated against the example
corpus (false-reject risk):
- [ ] slice-base existence — `place P over Ghost` accepted; `pd_over` is read
      only by a hardcoded Some "Customer" branch (main.ml) + yon_doc, no general
      base-existence check. Oracle: `slice_over_undeclared_reject/`.
- [ ] cell-endpoint existence — `cell loop from ghost to ghost` accepted;
      desugar.ml drops FoCell as pure metadata (no endpoint resolution).
      Oracle: `cell_bad_endpoint_reject/`.
- [ ] abstract-prop signature typing — bodyless `prop p(s: Ghost): proposition`
      accepted; the bodyless form does not typecheck its param types (the
      body-bearing form, desugaring to a fun, would). Oracle:
      `prop_bad_param_reject/`.
- [ ] morph via-signature — `on morphism deposit via wrong_sig` with
      incompatible wrong_sig still accepted by `check_via_bindings` when the
      source topos is out of scope. Oracle: `neg_morph_via_signature.yon`.
- [x] PathP type-equality — Dispatcher.type_equal has an endpoint-aware
      TyPathP arm (carrier up to the interval-var name + both endpoints,
      mirroring the TyId arm), so PathP equality is correct both ways.
      Positive oracle `keyword_coverage/c_pathp_refl.yon` (identical PathP →
      exit 0); negative `neg_pathp_endpoint.yon` (different endpoint → exit 3).
      catt_r_yon.ml `ty_structural_eq` has no PathP case and its TyId case
      drops endpoints; anything calling it directly does not see endpoints.

DEAD / vestigial — do NOT test: SAssignHolds (no production), EPullback/EPushout
expr, EAll, LitDuration/LitCurrency, TopWorld/TopSpace from grammar (manifest/
layout), OrdParallel/OrdByPriority/nt_components (AST-only), `init as Space` (dropped).

---

## Layer 2 — OCaml frontend (unit oracles)

DONE — soundness-critical oracles (frontend/test_*.ml, each pinning an audit fix):
builtins (encode∘decode=id, div/mod-by-zero stuck), reduce (β/η/is_value),
subst (3 capture sub-cases incl. HITElim), tycheck (accept/reject: return-mismatch,
dup-param, empty-body, return-tail), dispatcher (directional subtype + type_equal),
sheaf (factor/non-factor), hm_infer (unify + occur-check). Plus the pre-existing
cubical/kernel oracles (path, glue, isequiv, hit_*, eta_sigma, motive, j_tarski,
o6, yoneda, core_check, el, type_erase, world_site) + ty_subst, kernel_alpha,
leech_theta, sct. Each oracle is one pytest node (test_oracle_checks.py); an internal [FAIL]
line fails it.

REMAINING:
- [x] prop_eval — DONE: test_prop_eval.ml is wired in frontend/dune (built and
      run as a test_oracle_checks.py node). The Ω
      evaluator known-answer oracle, distinct from test_heyting (the algebra).
- [ ] desugar — a Surface→Core oracle (let→App(Lam,v); inline-lambda lift).
Pipeline-sufficient (skip): pretty, emit_mlir, carrier, drivers, tooling,
manifest/layout/module_prefix.

---

## Layer 3 — MLIR (topos-opt per pass; regression/test_mlir_passes.py)

DONE — 18 passes covered (accept+reject for checkers, output-IR regex for rewrites):
algebra-verifier, ccc-equations-check, giraud-check, type-preservation, progress,
localisation-decomp, internal-lang  (checkers);  heyting-short-circuit,
lower-topos-to-standard, coherence-elimination, move-composition, place-fusion,
reduction-inlining, world-specialization, structural-vn, lower-topos-extensions
(rewrites/lowering).

REMAINING / SKIPPED (documented, mostly unreachable in isolation):
- [ ] cps-conversion, type-equiv-sanity (E0103 not expressible from textual IR),
      accessibility (warning-only) — possible smoke nodes, low value.
- SKIP (grounded): hm-inference (E0104 unreachable — pabs params always print),
      alpha-rename (E0539 pre-empted by builtin SymbolTable verifier),
      simpson6 (emits E0279 at op-verify, not E0502), giraud quotient-of (pass
      ignores quotient_of).
Note: lower-topos-to-llvm is an arith/scf→llvm lowering (not Topos-specific).

---

## Layer 4 — LLVM lowering (regression/test_llvm_ir.py)   [thin — to thicken]

DONE — 9 examples ×: has-entry (`define i32 @main()`, nothing else counts),
no-undefined-runtime-refs (nm-checked), runtime-abi (every facade declaration
checked operand by operand against its C prototype, every call site against the
declaration), object-symbol-split (nm the .o: `main` defined, undefined ⊆
RTSET + libc + named system symbols — no blanket `__` prefix), and
child_exit_noreturn (the call exists and its declaration is `noreturn`). A
missing tool or an unreadable object FAILS.

REMAINING:
- [x] child_exit NORETURN — test_ll_child_exit_noreturn asserts that the
      `Spawn__child_exit` declaration carries the `noreturn` attribute (not a
      literal `unreachable`: that is an LLVM SimplifyCFG product, which
      mlir-translate does not emit).
- [ ] broaden from 6 example programs to ~10 (low value; harness skips any example
      whose pre-LLVM stage fails, so adding names is safe but only helps if they lower).
- [x] object-symbol-split — DONE (test_ll_object_symbol_split).
LEAVE (refinements, not gaps): has-entry's `@main` OR `@__yon_dispatch`, and
f64-abi's auto-skip — tightening risks false-fail for little gain.

---

## Layer 5 — C runtime (regression/test_runtime_units.py + test_runtime_mphf)   [closed for high-value]

DONE — memory-safety + families: field_load (OOB incl. uint32-wrap), coord-decode
(reject/range; flagged a latent type-vs-decode semantic disagreement → to-fix),
xheap-bounds, hsh, string (substring/char_at/find/parse edge cases), voyagerlist
(Golay seal/open/correct/bounds), map (put/get/contains/rehash) + the wired
arena, spawn, conway, quantizer, mphf. The gate rebuilds the runtime objects
(`make -C runtime`) so the tests link the current sources.

REMAINING (low priority — integration-covered): deque/pq/vec, merkle, xset/xrel,
crypto/bits/time/random, rpc, fold/checkpoint families of yon_rt.c.

---

## Next, by return-on-effort
1. `morph on morphism` via-signature when the source topos is out of scope
   (Layer 1, REMAINING).
2. Broaden the LLVM examples 6→~10 (low value).
