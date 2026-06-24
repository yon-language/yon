# Yon test-coverage matrix & backlog

Single source of truth for the unified pytest harness across the 5 layers
(Yon · OCaml · MLIR · LLVM · C). Goal: complete unit + integration coverage,
every construct / module / op / pass / function. Built from a 4-agent audit
(2026-06-24). Tick items as their tests land and gate green.

Harness entry: `python3 -m pytest regression`. Markers (conftest.py):
`yon|ocaml|mlir|llvm|c` × `unit|integration`. Gate is count-tolerant.

---

## Layer 1 — Yon surface (every construct)

Source of truth: `frontend/{lexer.mll,parser.mly,surface_ast.ml}`. ~150 live
constructs. Existing: examples/ (39, baseline) + keyword_coverage/ (6) +
yon_tests/{prove,negative,runtime} (23) + cross_space + project fixtures.

### UNCOVERED — live constructs needing a test (28)
Statements: [ ] SScope anonymous · [ ] SRepeat `otherwise` tail.
Expressions: [ ] ELam block-body · [ ] EReductionLam · [ ] EMorphLam ·
[ ] EQuote (+neg) · [ ] EElMatch · [ ] pipe-forward `|>`.
Types: [ ] TyMap (`map of K to V`) · [ ] TyPathP (+neg) · [ ] TyEl ·
[ ] TyHeytInt type (`heyting<N>`) · [ ] TyArrow (`T -> U`) ·
[ ] TyMoveHandle param · [ ] TyReductionHandle param · [ ] TyMorphHandle param.
Declarations: [ ] `fun id<A>` generics · [ ] `reduction R<T> of P` generic ·
[ ] `place P over X` slice · [ ] cell_decl (`cell loop from base to base`) ·
[ ] `by fun(...)=>...` inline mapping · [ ] abstract `prop p(..): proposition` ·
[ ] `topos T at Space` · [ ] morph `on object: fun(..)=>e` inline ·
[ ] morph `on morphism src via tgt` (HIGH — functor-on-arrows, untested) ·
[ ] `import m::n as alias` · [ ] TopSpaceInit `init Name as Space` (+neg).
Stratification negatives: [ ] plain `fun(x)=>..` where move/reduction/morph
handle type required must be REJECTED (ties to handle-type gaps).

### DEAD / vestigial — do NOT write tests
SAssignHolds (no production) · EPullback/EPushout expr (v1.1 removed) ·
EAll (removed) · LitDuration/LitCurrency (DUR_LIT removed) ·
TopWorld/TopSpace from grammar (built by manifest/layout, test in project suite) ·
OrdParallel/OrdByPriority/nt_components (AST-only, parser hardwires defaults).

---

## Layer 2 — OCaml frontend (unit oracles)

Best-covered: cubical/kernel (test_path/glue/isequiv/hit_*/eta_sigma/quote/
motive/j_tarski/o6/yoneda*). Wired now: +ty_subst, kernel_alpha, leech_theta, sct.

### NO isolated oracle, soundness-critical — add one (known-answer)
[ ] tycheck (infer/check/check_program: well-typed→[]; ill-typed→1 tagged err;
cross-space leak reject; return-tail) · [ ] dispatcher (classify routing table;
directional subtype accept A<:B reject B<:A) · [ ] reduce (β-step, eta, is_value,
fuel-bounded divergence) · [ ] builtins (arith known-answer; encode∘decode=id) ·
[ ] subst (3 capture sub-cases) · [ ] desugar (let→App(Lam,v); inline-lambda lift)
· [ ] sheaf (factoring field accept / non-factoring reject) · [ ] hm_infer
(infer `fun f(x)=>x+1`:number→number; occur-check; recursion) ·
[ ] prop_eval+heyting (full Ω meet/join/neg/imp table; neg(unknown)=unknown).
Pipeline-sufficient (skip): pretty, emit_mlir, carrier, eval*, drivers,
parser_state, diagnostics, inline_seq, tooling, manifest/layout/module_prefix.

---

## Layer 3 — MLIR (24 passes, 7 types, ~90 ops) — only 4 passes exercised

Run as pytest subprocess: `topos-opt --<flag> in.mlir` → assert exit + stdout
regex (FileCheck-style). Checkers: accept + reject fixture each. Lowering:
output-IR-shape regex. Fixtures dir: `regression/mlir_units/`.

### Checkers — NONE tested
[ ] --algebra-verifier (accept ok.mlir → `@<P>_instantiate`; reject non-monotone/
non-catalog) · [ ] --ccc-equations-check (E0451/2/3/6/7) · [ ] --topos-type-
preservation (E0101) · [ ] --topos-progress (E0102) · [ ] --topos-hm-inference
(E0104) · [ ] --topos-giraud-check (E0501) · [ ] --topos-simpson6 (E0502) ·
[ ] --topos-localisation-decomp (E0504) · [ ] --topos-internal-lang (E0505) ·
[ ] --topos-alpha-rename (E0539) · [ ] --topos-accessibility (smoke, warn-only) ·
[ ] --topos-type-equiv-sanity (smoke; reject not expressible).

### Rewrite/lowering — NONE tested
[ ] --heyting-short-circuit · [ ] --coherence-elimination · [ ] --reduction-
inlining · [ ] --move-composition · [ ] --topos-cps-conversion · [ ] --place-
fusion · [ ] --structural-value-numbering · [ ] --world-specialization ·
[ ] --lower-topos-extensions · [ ] --lower-topos-to-standard · [ ] --lower-topos-
to-llvm. (Detailed input/CHECK sketches per pass: see audit report.)
Dead notes: E0103 not expressible from textual IR; many declarative ops
(fibration/reindex/kleisli/coequalizer/kripke_joyal) are verify-only, no pass.

---

## Layer 4 — LLVM lowering — black-box only (exit code)

Add pytest nodes inspecting emitted `.ll`/object (no execution):
[ ] no undefined runtime refs (every `@yon_rt_*`/`@Spawn__*`/`@__yon_dispatch`
referenced is in RTSET via `nm`) · [ ] entry `@main` + per-program
`@__yon_dispatch` defined · [ ] f64-uniform calling convention to runtime ·
[ ] `Spawn__child_exit` followed by `unreachable` · [ ] object symbol split
(`main` defined; undefined ⊆ RTSET+libc) · [ ] LLVM verifier clean surfaced.

---

## Layer 5 — C runtime — modules integration-covered; key paths lack unit tests

Wired now: mphf, arena, spawn, conway, quantizer (test_runtime_units.py +
test_runtime_mphf). Attacker-influenceable paths WITHOUT a direct unit test
(build like existing; exit 0 = pass), priority order:
[ ] A. yon_rt_field_load / flatten — OOB boundary (audited): in-bounds, exact
end, offset+size overflow→-1, uint32-wrap probe, null slot, flatten cap ·
[ ] B. xleech2 yon_xcoord_to_int24 — decode fuzz: 0→-1, bit-25→-1, j==24 guard
(ASan), random sweep, NaN/Inf into quantize · [ ] C. xleech2_heap put_v/
strip_alloc/arena_alloc — dedup idempotence, NULL+nbytes, TAG_FREE, slot
exhaustion, arena exhaustion/wrap, get OOB idx · [ ] D. yon_rt_hsh step/backward/
contains — empty/step/contains, out-of-range level, malformed weights handle ·
[ ] E. yon_rt_voyagerlist — Golay seal/open round-trip, corrupt 1-3 bits recover,
4 detect, corrupt_at OOB · [ ] F. yon_rt_string — substring/char_at/find bounds,
concat, parse_number edge cases.

---

## Execution phases
1. Layer 1 Yon surface micro-tests (every statement) — additive .yon, gate batches.
2. Layer 3 MLIR pass units — additive .mlir + pytest, no build risk (20 passes).
3. Layer 5 C unit tests A–F — additive .c + pytest (memory-safety).
4. Layer 2 OCaml oracles — new test_*.ml + dune (compile risk), soundness-critical.
5. Layer 4 LLVM IR assertions — additive pytest nodes.
