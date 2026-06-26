# Yon test-coverage matrix & backlog

Single source of truth for the unified pytest harness across the 5 layers
(Yon · OCaml · MLIR · LLVM · C). Goal: complete unit + functional + integration
coverage, every construct / module / op / pass / function.

Harness entry: `python3 -m pytest regression`  (gate: `bash swarm/hooks/gate.sh`
— rebuilds frontend `dune build` + runtime `make -C runtime`, then pytest,
count-tolerant; then the adversarial ratchet).

## Pyramid (measurable via markers — conftest.py)

Kinds: `unit` | `functional` | `integration`.  Layers: `yon|ocaml|mlir|llvm|c`.
Slice with `pytest -m`, e.g. `pytest -m "c and unit"`, `pytest -m functional`.

    for k in unit functional integration; do
      n=$(python3 -m pytest regression -m "$k" --co -q 2>/dev/null | grep -c '::')
      echo "$k: $n"; done

Suite ~707 nodes. unit is the dominant base (per-assertion oracle nodes via
test_oracle_checks.py), functional in the middle, integration the tip.

  unit        — one module fn / one MLIR pass / one C fn, known-answer.
  functional  — a language feature emits / type-checks / is rejected (frontend).
  integration — full chain to a running binary; projects; cross-process wires.

---

## Layer 1 — Yon surface (every construct)

COVERAGE MODEL: test_yon_coverage.py enforces that EVERY lexer keyword is
exercised by compiling code (examples/ + keyword_coverage/ + yon_tests/ +
cross_space/) or a kernel oracle. HARDENED this pass: the exercised-token scan
now STRIPS comments first — previously a keyword appearing only in a comment
counted as covered (phantom coverage). The comment-stripped audit found 6
phantoms: `forever`, `and`, `or`, `true`, `false` (live constructs, exercised by
NO code) and `objects` (dead). Resolution:
  - `forever` -> keyword_coverage/c_forever.yon (forever_stmt, real code).
  - `and`/`or`/`true`/`false` -> keyword_coverage/c_bool_logic.yon (real code;
    all four VERIFIED to lower, exit 0).
  - `objects` (OBJECTS_KW) -> DROPPED: orphan token (no grammar production left
    after the topos-per-space milestone removed inline `objects { }`); removed
    from lexer.mll + parser.mly %token.

DONE — single-file construct micro-tests (regression/keyword_coverage/c_*.yon,
functional): scope-anon, repeat-otherwise, lambda-block, arrow/map/El/PathP/
heyt-int/morph-handle types, generics `fun id<A>`, import-alias, quote, el_match,
bool-logic (true/false/and/or), forever.
DONE — negatives (regression/yon_tests/negative/neg_*.yon): return-mismatch,
return-tail, dup-param, empty-body, arity, unbound-var, path-app-nonpath,
quote-carrier-mismatch.
DROPPED (was UNCOVERED) — `init Name as Space`: vestigial, superseded by the
filesystem project model; removed from the language.

DONE — project-context constructs POSITIVES, gate-wired example projects
(test_projects.py globs examples/**/yon.toml, asserts compile-accept):
`place P over X` (examples/c_place_over), `cell .. from .. to ..`
(examples/c_cell), abstract `prop p(..): proposition` (examples/c_prop_abstract),
topos decl in a space `Topos.yon` (examples/c_prop_abstract, kw_topos_block, +
every project). NB `topos T at Space` was DROPPED with the topos-per-space
milestone (residence is filesystem-inferred); the construct is the plain topos
decl, covered everywhere.
DONE — handle-type STRATIFICATION negative: a plain arrow where a
`morph from S1 to S2` handle is required is rejected (exit 3); wired
`yon_tests/negative/neg_handle_plain_fn.yon` (the handle opacity is confined to
the topos identifiers, not the argument's arrow-vs-handle distinction).
DONE — morph on-morphism FUNCTORIALITY hardened (W6): `yon_tests/negative/
neg_morph_functoriality.yon` rejects an `on morphism .. via wrong_sig` whose
signature is not F(dom) -> F(cod). (Earlier STUB note now resolved.)

REMAINING — construct-specific semantic checks that are STUBS (accept-all on the
structural/categorical content; VERIFIED this pass: each accepted in project
context, exit 0). NOT wireable as negatives until hardened — wiring would be a
false-green. Red→green oracles staged in `_pending_construct_tests/` (collected
by nothing), each a minimal mutation of its passing example, verified ACCEPTED
today; hardening must be Mac-gated against the example corpus (false-reject risk,
per the PathP/morph saga):
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
- [ ] morph via-signature (v1.2) — `on morphism deposit via wrong_sig` with
      incompatible wrong_sig still accepted by `check_via_bindings` when the
      source topos is out of scope. Oracle: `neg_morph_via_signature.yon`.
- [x] PathP type-equality — RESOLVED, and the original note was INVERTED.
      The real gap: Dispatcher.type_equal had NO TyPathP arm, so two PathP fell
      to base_equal; classify_ty routes TyPathP to FragCATT, whose decidable
      (catt_r_yon.ml `ty_structural_eq`) ALSO has no PathP case → returns false
      for ANY two PathP. So the actual bug was a FALSE-REJECT on all path types
      (identical PathP rejected too), NOT the false-accept the old note claimed.
      Verified empirically: neg_pathp_endpoint was rejected WITH and WITHOUT the
      change (it never discriminated). Fix: explicit endpoint-aware TyPathP arm
      (carrier up-to interval-var name + both endpoints, mirroring the TyId arm
      + TyPi rename), so PathP equality is correct BOTH ways.
      Red→green oracle is POSITIVE: `keyword_coverage/c_pathp_refl.yon`
      (identical PathP → exit 0; falsely rejected pre-fix). Companion negative
      `neg_pathp_endpoint.yon` pins the other direction (different endpoint →
      exit 3). NB latent: ty_structural_eq's TyId case also drops endpoints and
      PathP has no case at all — both now bypassed by the explicit type_equal
      arms, but worth a follow-up if anything calls ty_structural_eq directly.

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
leech_theta, sct. Each oracle's internal [PASS]/[FAIL] is one pytest node
(test_oracle_checks.py).

REMAINING:
- [x] prop_eval — DONE: test_prop_eval.ml is wired in frontend/dune (built and
      run; its [PASS]/[FAIL] lines become test_oracle_checks.py nodes). The Ω
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
(rewrites/lowering). Found + fixed a real bug: AlgebraVerifier missing Func/Arith
dependent dialects (crashed standalone).

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

DONE — 6 examples (arena_basic, spawn_parallel_collect, net_stream,
string_literals, collections_ext, merkle_noncommutative) ×: ll-emits (valid IR),
has-entry (@main/@__yon_dispatch), no-undefined-runtime-refs (nm-checked),
f64-abi (value-facade calls are double; void-control calls excluded). PLUS
test_ll_object_symbol_split (nm the .o: `main` defined, undefined ⊆ RTSET+libc —
link invariant before the slow link) and test_ll_child_exit_unreachable
(TOLERANT form, see below).

REMAINING:
- [ ] child_exit NORETURN — the test exists but asserts only the WEAK
      "safe-by-deadness" invariant, by design, because the lowering does NOT mark
      the facade noreturn. The real fix: in emit_mlir.ml (~L5715) emit
      `Spawn__child_exit` declaration with a noreturn passthrough so mlir-translate
      emits the LLVM `@Spawn__child_exit` declaration with the `noreturn` attribute;
      then strengthen the node to assert the declaration carries `noreturn`.
      Red→green on the Mac (pre: no noreturn; post: present). CAUTION: must confirm
      mlir-opt/topos-opt accept the attribute and func→llvm forwards it — if the
      func verifier rejects it, ALL examples' lowering breaks, so gate carefully.
      NB: literal `unreachable` after the call is an LLVM SimplifyCFG opt, NOT
      emitted by mlir-translate, so assert the noreturn ATTRIBUTE, not `unreachable`.
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
arena, spawn, conway, quantizer, mphf. Building these CAUGHT that the runtime .o
were STALE (audit fixes not in the linked objects) → gate now `make -C runtime`.

REMAINING (low priority — integration-covered): deque/pq/vec, merkle, xset/xrel,
crypto/bits/time/random, rpc, fold/checkpoint families of yon_rt.c.

---

## Next, by return-on-effort
0. [DONE] Soundness: PathP endpoint-blind type_equal closed (neg_pathp_endpoint,
   red→green). This came BEFORE coverage — an active false type-equality beats
   covering a healthy feature.
1. `morph on morphism` — FINDING: the functor-on-arrows check is a STUB
   (accept-all on functoriality; see Layer 1). HIGHEST remaining value, same
   class as PathP. Needs a Mac-gated red→green (can't harden blind: ~10 morph
   examples + undeclared-topoi risk).
2. [DONE] Layer 2 prop_eval oracle (wired in dune).
3. child_exit NORETURN fix (emit a noreturn passthrough on Spawn__child_exit,
   strengthen the node to assert the attribute). object-symbol-split DONE.
   Broaden examples 6→~10 is low value.
