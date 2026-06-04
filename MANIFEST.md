# Snapshot turno 33 part 17 (2026-05-30) — Migrazione xheap Leech (SAT engines)

## Risultato chiave

4 wavefront SAT (naive, orbital S_n, leech G_24, co0) migrati da array C
statici/malloc all'allocatore xheap Leech (xleech2). **~1.5 GB di storage
statico/malloc eliminato.**

| Engine | UF20-01 |R| | Multi-run pulito |
|---|---|---|
| naive (sparse wavefront) | 196560 (saturazione xheap, dedup ok) | sì |
| **orbital S_n** | **1711** | **sì** (1711, 1733, 1667 verificati) |
| leech G_24 | 4096 (lossy syndrome) | sì |
| co0 | (variabile per istanza) | sì |

## Nuove API xheap (xleech2_heap.h)

- `yon_xheap_put_or_get(h, payload, n_bytes, tag, *was_new)` — content-addressed
  insert con flag "was new". Permette dual-structure (push raw a slot array
  se canon è nuovo).
- `yon_xheap_lookup_content(h, payload, n_bytes)` — lookup puro (no insert).
- `yon_xheap_reset(h)` — full reset O(N_INDEX): slots / content_index / arena_used.
- `yon_xheap_alloc(h, n_bytes, tag)` — allocazione anonima (no content_index).
  Pronto per part 18 (HashSet/HashMap/etc).
- `yon_xheap_slot_payload_mut(h, slot)` — payload mutabile.

## Migrazione SAT (yon_rt.c)

Eliminati:
- `orb_set[4M]` (32 MB) + `orbital_raw_frontier[10M]` (80 MB)
- `leech_set[1M]` (8 MB) + `leech_raw_frontier[2M]` (16 MB)
- `co0_set[1M]` (8 MB) + `co0_raw_frontier[2M]` (16 MB)
- `sparse_set` calloc(128M*8) = 1 GB + `frontier` malloc(50M*8) = 400 MB

Aggiunti:
- `g_sat_heap` (yon_xheap_t scratchpad SAT-dedicato)
- `orbital_raw_slots[YON_HEAP_N_SLOTS]`, `leech_raw_slots[]`,
  `co0_raw_slots[]`, `sparse_slots[]` (~786 KB ognuno, slot_id uint32)

## Test verificati

| Test | Risultato |
|---|---|
| test_yon_rt | 30/30 ✓ |
| test_lockedring | 14/14 ✓ |
| test_ty_subst | 24/24 ✓ |
| cross_validate_yonc | TOT 222 / MATCH 83 / MISMATCH 0 / COMPILE_FAIL 0 |
| SAT.uf20_orbital(1,1) | 1711 |
| SAT.uf20_orbital multi-run (1,2,3) | 1711, 1733, 1667 |
| sct_native_sat_wavefront.yon | raw=1717, canon=1717 |
| sct_native_9_algebras.yon | exit 83 (12+6+16+16+7+10+5+5+6) |

## Layout

```
turno_33_part17_2026-05-30/
├── runtime/    11 file:  yon_rt.{c,h}, yon_shm.h,
│                          xleech2_heap.{c,h}, xleech2_coord.{c,h},
│                          xleech2_mphf.{c,h}, xleech2_handler_stack.{c,h}
├── frontend/   37 file OCaml (lista completa qui sotto)
├── examples/   ~67 file .yon (sct_test*, cluster_a_*, sct_native_*, ecc.)
└── docs/        3 file md: SCT.md (con §34.6.7), yon-sct.md, goal.md
```

## Frontend OCaml — 37 file

Core IR / type-checking / emission:
- `ast.ml`, `surface_ast.ml` — AST surface + core IR
- `tyenv.ml`, `tycheck.ml`, `ty_subst.ml`, `subst.ml` — type-checker bidirezionale + substitution
- `hm_infer.ml` — Hindley-Milner inference
- `reduce.ml` — beta/delta reduction
- `desugar.ml` — surface → core IR lowering
- `emit_mlir.ml`, `yoner_emit_mlir.ml` — MLIR Topos dialect emission
- `eval.ml`, `eval_runner.ml` — interpreter (cross-validation)
- `prop_eval.ml` — propositional eval
- `pretty.ml` — pretty printer
- `diagnostics.ml` — error reporting

Parser:
- `lexer.mll`, `parser.mly`, `parser_state.ml`

Modules / runtime / dispatcher:
- `dispatcher.ml` — operator/method dispatch
- `stdlib_runtime.ml` — runtime symbol registry (DIMACS, HashSet, Math, Bits, Seq, File, ...)
- `builtins.ml` — primitive builtins
- `inline_seq.ml` — Seq/Stream inlining

Theory / math:
- `catt_r_yon.ml` — CaTT_r → Yon embedding
- `heyting.ml` — Heyting algebra
- `cubical.ml`, `cubical_bindings.ml` — cubical type theory
- `hit_env.ml` — higher inductive types env
- `place_visibility.ml`, `move_engine.ml` — Place/Move semantics
- `naturality_coqcheck.ml`, `naturality_smtcheck.ml`, `naturality_symcheck.ml` —
  triple-check naturality (Coq / SMT / symbolic)

Entry points / test:
- `main.ml`, `run_example.ml`, `test_ty_subst.ml`, `lex_test.ml`

## File modificati rispetto a part 16

- `runtime/xleech2_heap.{c,h}` — 5 nuove API (put_or_get, lookup_content, reset,
  alloc, slot_payload_mut)
- `runtime/yon_rt.c` — migrazione 4 SAT engines (orb_try_insert, leech_try_insert,
  co0_try_insert, sparse_insert, frontier_add) + try_add_canon_sn (part 16-bis)
- `docs/Structural_Collapse_Theorem.md` — §34.6.7 "Migration to xheap Leech allocator"

## Cosa NON è ancora migrato (deferred part 18)

`g_hashsets[256]`, `g_hashmaps[256]`, `g_xsets[]`, `g_streams[]`,
`g_voyagerlists[]`, `dimacs_clauses[1024]`, `co0_hash_table`/`co0_queue`
(BFS Co_0), `cap_registry`, `move_registry` — tutti su array C statici.
Migrazione meccanica via `yon_xheap_alloc` + `yon_xheap_slot_payload_mut`,
una struttura alla volta con test intermedi.

## Status teoremi SCT

18/20 PROVED + T21 + §34.6.5 RESOLVED orbital + §34.6.6 native Yon mapping
+ 9 algebre verificate + **§34.6.7 xheap migration (4 SAT engines)**.
