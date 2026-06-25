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

## Layer 1 — Yon surface (every construct)   [biggest remaining gap]

DONE — single-file construct micro-tests (regression/keyword_coverage/c_*.yon,
functional): scope-anon, repeat-otherwise, lambda-block, arrow/map/El/PathP/
heyt-int/morph-handle types, generics `fun id<A>`, import-alias, quote, el_match.
DONE — negatives (regression/yon_tests/negative/neg_*.yon): return-mismatch,
return-tail, dup-param, empty-body, arity, unbound-var, path-app-nonpath,
quote-carrier-mismatch.
DROPPED (was UNCOVERED) — `init Name as Space`: vestigial, superseded by the
filesystem project model; removed from the language.

REMAINING:
- [ ] project-context constructs as MINI-PROJECTS (need yon.toml world/place):
      `place P over X` (slice), `cell n from src to tgt` (HIT path ctor),
      abstract `prop p(..): proposition`, `topos T at Space`,
      `morph M { on morphism src via tgt }`  ← HIGH (functor-on-arrows, the
      categorical core, entirely untested).
- [ ] handle-type STRATIFICATION negatives (plain lambda where a move/reduction/
      morph handle TYPE is required → must reject) — need declared places → projects.
- [ ] `neg_pathp_endpoint` — BLOCKED by a real gap: Dispatcher.type_equal is
      endpoint-blind for TyPathP (see to-fix); today the mismatch is accepted.

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
- [ ] prop_eval — the Ω evaluator (test_heyting covers the algebra, not the
      evaluator that applies it). A single test_prop_eval.ml known-answer.
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

DONE — 4 node types × 3 examples (arena_basic, spawn_parallel_collect, net_stream):
ll-emits (valid IR), has-entry (@main/@__yon_dispatch), no-undefined-runtime-refs
(nm-checked: every @yon_rt_*/@Spawn__*/@__yon_dispatch referenced is provided),
f64-abi (value-facade calls are double; void-control calls excluded).

REMAINING (real semantic value, not cosmetic):
- [ ] child_exit → unreachable: a `call ... @Spawn__child_exit`/`yon_rt_spawn_child_exit`
      must be followed by `unreachable` (it _exit()s). Protects a nasty concurrency bug.
- [ ] object-symbol-split: after llc -filetype=obj, `nm` the .o — `main` defined,
      undefined ⊆ RTSET+libc. The link-time invariant, before the slow link.
- [ ] broaden from 3 example programs to ~10 touching more runtime families.
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
1. Layer 1 mini-projects, starting with `morph on morphism` (HIGH — untested core).
2. Layer 2 prop_eval oracle.
3. Layer 4 child_exit→unreachable, then object-symbol-split, then broaden examples.
