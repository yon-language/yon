# Yon construct inventory — verdicts (code-sourced)

> Built by reading `regression/COVERAGE.md`, `audit_language.md`,
> `swarm/LANGUAGE_AUDIT.md`, the OCaml oracles (`frontend/test_*.ml`), the runtime
> tests (`runtime/test_*.c`), the examples and the syntax files. Every verdict has a
> `file:line` anchor. This is the honesty backbone for `01-jp-structure.md`:
> ✓ verified / declared / debt. The reader is hostile and competent.

## The 27 features

| # | Feature | Verdict | Evidence (anchor) | Note |
|---|---------|---------|-------------------|------|
| 1 | `place` as presheaf `Site→Type` | **declared** | `ast.ml:8,157-158`, `carrier.ml:3` | Design-level ontology; testable consequences are #12/#13 + Yoneda dispatch. No test asserts "place IS a presheaf". |
| 2 | content-addressing (FNV + byte-compare) | **✓ verified** | `runtime/test_unit_xheap_bounds.c:32-47` (dedup + memcmp), `test_runtime_units.py:54` PASS; impl `xleech2_heap.c:34-42,329,720` | Strongest silicon claim. |
| 3 | `Space` cell (location) | **✓ verified** | write `x = e` → `SAssignBecomes` → `Space__set`/`__space_update_here` (`desugar.ml:1761,1341`); **read `Space__get`** (becomes-promotion pass `desugar.ml:1835-1859`); runtime `g_space_cells`/`yon_rt_space_set`/`_get` (`yon_rt.c:6427,6443,6454`); green via `kw_list_here.yon` (exit 21) + all stream/fold lowerings. `audit_language.md:106` "risolto + lowered". | A var assigned with `=` is PROMOTED to a Space cell (every read → `Space__get`). Distinct from `x.f = e` (place field = by-design reject, sections immutable, `audit:107`) and `new…in` (vestige). `becomes` retired as surface token; `=` is the surface, `SAssignBecomes` the internal node. |
| 4 | carrier partial functor, `NoCarrier` | **✓ verified** | `carrier.ml:47,70,115,125,130`; `emit_mlir.ml:219`; oracle `test_type_erase.ml:24-70` | Clean reject at erasure frontier, not a crash. |
| 5 | Heyting Ω (Gödel G3), `=>?` `!?` | **✓ verified** | oracle `test_prop_eval.ml:76-164` (`neg(unknown)=unknown` :122); `heyting.ml:27-100`; `decidable_unknown.yon` exit 134 | Genuine Gödel G3, not Kleene K3 (fixed this session). |
| 6 | `Id`, `refl`, `PathP` | **✓ verified** | `test_path.ml:28-106`, `test_path_core.ml:31-38`; neg `neg_pathp_endpoint.yon` exit 3; `c_pathp_refl.yon` | Endpoint-blind bug closed this pass. |
| 7 | `J` / `ind_path`, β on refl | **✓ verified** | `test_j_tarski.ml:18-42`; β `reduce.ml:434-441`; `kw_paths.yon` exit 42 | Stuck on non-`refl` (declared boundary, Debt #4). |
| 8 | `Glue` / `ua` (univalence) | **✓ verified (kernel)** | `test_glue.ml:36-38`; `transport_ua_succ.yon` → **11 not 10**; isEquiv gate `cubical_bindings.ml:165-179` | Surface end-to-end is a partial boundary (Debt #2-3). `ua`/`glue` are dispatch entries, not keywords. |
| 9 | HIT (S¹, `base`, `loop`) | **✓ verified** | `test_hit_compute.ml:25-38`, `test_hit_elim.ml:36-46`; `examples/circle_hit.yon` exit 42; negs present | Combination gap: only one HIT example. |
| 10 | η_Σ (surjective pairing) | **✓ verified** | `test_eta_sigma.ml:18-52`; rule `reduce.ml:457-465` | Strict products (unique mediator). |
| 11 | stratified universes `Type_0≠Type_5` | **✓ verified** | `test_core_check.ml:130-138`; `tycheck.ml:2397-2422`; `kw_type0.yon` | The Girard barrier. |
| 12 | `world` (`*`,`+`,`/∼`,subset) | **✓ verified** | `test_world_site.ml:20-94` (7 cases); `site.ml:26,31` | Product intentionally NOT a site generator (it's a limit). |
| 13 | sheafification / descent reject | **✓ verified (VIEW) / debt (OPERATIONS)** | `sheaf.ml:62,88`; negs `sheaf_quotient_{view,view_impure,move,prop}_reject` exit 3 | VIEW path closed (4-door). OPERATIONS path = Stage-2 debt (`op_sig` bodyless). |
| 14 | `geom_morphism`, pull/push, f*⊣f∗ | **✓ verified** | `parser.mly:524-558`; desugar `desugar.ml:2142-2159`; 4 examples + 5 `cross_space/`; neg `geomorph_transport_no_leak` | Combination gap: lives in big cross-space examples. |
| 15 | `morph on morphism` (functoriality) | **declared / partial** | check `tycheck.ml:2830-2907`; neg `neg_morph_functoriality.yon` exit 3 | via-signature is a STUB when source topos out of scope (`_pending_construct_tests/`, COVERAGE L88-90, "highest remaining value"). |
| 16 | directional subtyping `number<:heyt_int<:prop` | **✓ verified** | `test_dispatcher.ml:60-64` (reverse = false); `dispatcher.ml:314-424` | One-way promotions. |
| 17 | `place P on error E`, monad `+E` | **declared** | `parser.mly:602,612`; `examples/error_morphism/` exit 0 | Accept-only; no dedicated negative on error-monad semantics. |
| 18 | closed arrows, capture = error | **✓ verified** | `tycheck.ml:408-428,1426-1514`; `closed_morphism_capture/` exit 3 | Isolation as a type law. |
| 19 | compile-time reject, exit 3, "no fake green" | **✓ verified** | `run_example.ml:54`; `gate.sh`; entire `negative/` corpus; comment-phantom audit | The honesty discipline, harness-enforced. |
| 20 | `type_erase` | **✓ verified (core)** | `type_erase.ml:1-125`; oracle `test_type_erase.ml:24-70` | Higher-order erasure = clean reject debt (`type_erase.ml:84`, Debt #11). |
| 21 | Leech, 196,560 type-2, X* on MPHF | **✓ verified** | theorem `test_leech_theta.ml:26,33` (theta + type2_count = 196560); runtime `test_mphf.c:49` (bijection, 0 collisions) | Two independent proofs. Co₀/Monster real math but NOT code-exercised. |
| 22 | Golay (24,12,8), VoyagerList | **✓ verified** | `runtime/test_unit_voyagerlist.c:53-82` (seal/open + corrupt-recover) | Decoding, not checksum. |
| 23 | mmap sole primitive, 2 allocators, no GC, `exit()` | **✓ verified** | `xleech2_heap.c:152-189,267-288,549`; `_exit` `yon_rt.c:2345`; `test_unit_xheap_bounds.c` | Deterministic memory. |
| 24 | multi-process prefork, no threads | **✓ verified (C facade)** | `yon_rt.c:2305,2345,2439-2453`; oracle `test_spawn_collect.c` (30, no loss/dup) | E2E `spawn_parallel_collect.yon` timeout-flaky on Mac (Debt #6). |
| 25 | `wire` / DTO over SHM | **declared** | `yon_rt.c:1677-1705`; `wire_eof.yon` exit 7 | Runtime real; no isolated DTO unit test; cross-space red on Mac (Debt #6). |
| 26 | `Carrier.t` target-agnostic, emit = printer | **✓ verified** | `carrier.ml:36,143-162`; `emit_mlir.ml:251` (Debt #10 closed) | Stdout-only emission (`Output__print`); no JSON emitter. |
| 27 | single kernel normalizer | **✓ verified** | `reduce.ml:~548`; consumed `dispatcher.ml:291-292` | Yoneda-as-design-discipline. |

## The three meditations

| Anchor | Verdict | Evidence | Note |
|--------|---------|----------|------|
| **Yoneda / presheaf** | **✓ verified (representable)** | `test_yoneda_typed.ml` (`Hom(P,Q)≅Nat(よP,よQ)`), `test_yoneda_lemma.ml`; dispatch `parser.mly:24-42` | Representable case only — NOT general internalized Yoneda. Honest narrower form. |
| **Content-addressing** | **✓ verified** | = #2 (`test_unit_xheap_bounds.c`, `xleech2_heap.c:34-42`) | "Yoneda made silicon." |
| **Leech lattice** | **✓ verified** | = #21 (`test_leech_theta.ml`, `test_mphf.c`) | Kissing number proven in-tree. Co₀/Monster NOT code-exercised — mark the boundary. |

## Coverable today (green test exists)
#2, **#3 (Space cell — `kw_list_here.yon` + stream lowerings)**, #4, #5, #6, #7, #8(kernel), #9, #10, #11, #12, #13(VIEW), #16, #18, #19, #20(core), #21, #22, #23, #24(C facade), #26, #27, Yoneda(representable).

## Debts (tell as open research)
- **#13 sheaf OPERATIONS path** (Stage 2): `op_sig` bodyless, op→arrow resolution unimplemented. Debt #1.
- **#15 via-signature**: accept-all stub when source topos out of scope. COVERAGE L88-90, "highest remaining value."
- **#8 ua/Glue/transport surface E2E**: kernel computes; surface partial (Debt #2-3).
- **#20 higher-order type_erase**: clean reject, not lowered.
- **#24/#25 runtime E2E on this Mac**: spawn/wire timeout/red (env-bound, Debt #6). C unit tests pass.
- **#1 place-as-presheaf, #17 error-as-place**: accept-only / framing, no asserting test.
- **Co₀/Monster link**: real math, not code-exercised.

## Combination gaps (only inside a big example, no isolated micro-test)
- **#14 geom_morphism** — only in 4 projects + 5 cross_space programs (green always entangled).
- **#17 error-as-place** — only `error_morphism` project.
- **#25 wire/DTO** — only `wire_eof` + cross_space.
- **#9 HIT** — kernel unit-tested but a single surface example.
- **#3 Space cell** — covered (`kw_list_here.yon` + stream/fold lowerings), but no JP-flavored isolated micro-test that names "location" explicitly; the park is the natural place to combine it with #2 (content) for the fourth wall.
- **#13 sheaf** — VIEW reject well-isolated, but the full "topos vs collection" pairing (with #12 + #1) is implicit, not one narrative example.

## Vocabulary correction
`becomes` surface keyword is **gone** — Space-cell mutation is `=` (`parser.mly:1080`);
`SAssignBecomes`/`BECOMES` survive only as internal names. Do not assert `becomes` in
the book.
