# Dead code audit (2026-06-07)

Status: class A pruned (this commit), regression 126 green plus
cross-Space after the cut. One scan-scope correction recorded below.

Method: mechanical cross-reference, four scans. (1) OCaml toplevel
`let` definitions vs references in every module, qualified, via
`open`, and in test files; entry-point binaries excluded as
definition sites but included as reference sources. (2) C runtime
function definitions vs calls inside C, `@symbol` references in the
emitter, and MLIR pass sources; dynamically constructed names checked
by prefix. (3) TopOps.td operation mnemonics vs `topos.<op>` strings
in the emitter, the passes and the MLIR examples. (4) Known
session-level deads. No removal happens without an explicit decision:
this file is the worklist.

## Scan-scope correction (recorded)

`parser_state.lift_inline_lambda_to_fun` was a false positive: the
OCaml scan covered `*.ml` only, and the function is referenced from
the **parser.mly semantic actions** (alias at line 26). Lesson for the
method: `.mly`/`.mll` actions are reference sources. Every other class
A entry was re-checked against `.mly`/`.mll` and confirmed dead.

## Class A: PRUNED (this commit)

| Where | What | Why dead |
|---|---|---|
| frontend/builtins.ml:283 | the `"__is_not"` constant-folding branch | unreachable since `is not` desugars to `__heyt_not(__is ...)` (comment at desugar.ml:1006 documents the rerouting) |
| frontend/builtins.ml | `reset_place_fields` | never referenced |
| frontend/diagnostics.ml | `format_parse_error`, `format_with_suggestion` | superseded formatting helpers |
| frontend/eval.ml | `pp_result`, `pp_trace` | debug printers, never called |
| frontend/hm_infer.ml | `error_to_string` | never called |
| frontend/ty_subst.ml | `scheme_to_string` | never called |
| frontend/emit_mlir.ml | `collect_reduction_handler_sigs` | superseded by the current reduction lowering |
| frontend/move_engine.ml | `set_field`, `try_reduce_move` | kernel uses the dispatch at ~262 instead |
| runtime/yon_rt.c | `yon_rt_apply_move` | the move application is lowered emit-side (field ops), the runtime shim is unreached |

## Class B: intentional reserve (proposal: keep, with a comment marking the reserve)

| Where | What | Reserve for |
|---|---|---|
| frontend/catt_r_yon.ml | 23 functions (`family1_alpha_equiv`, `family2_beta_step`, `family4_place_iso`, whiskers, `pd_comp_2`, `universal_colimit_cell`, cell accessors, registry/persistence helpers) | the R_Yon reduction families and the CaTT cell kernel: the formalization research program |
| frontend/cubical.ml, cubical_bindings.ml, hit_env.ml, tyenv.ml interval helpers | `face_is_consistent`, `formula_holds`, `glue_type`, `hit_constructor_arity`, `mk_equiv_ty`, `empty_env`, `register`, `missing_constructors`, `add_interval`, `is_interval_var`, `add_vars` | the cubical/HIT frontier; S1 (hit_env) is load-bearing in the formalization sec. 13 counterexample |
| frontend/dispatcher.ml | the `*_equal` family + `summarize_classification`, `term_equal_kernel` | the dispatcher classification API |
| frontend/tycheck.ml | `is_comprehension`, `is_classifier_pullback`, `comprehension_ty`, `true_arrow_ty` | cited by the formalization sec. 5 as the deciding procedures of the classifier. Finding: they are not wired into any compilation path today (the wired piece is `comprehension_coerces_to`). Either wire them into the checker or keep them as the verification API the document points at; do NOT prune |
| frontend/heyting.ml | `h_leq`, `to_bool_strict` | lattice API completeness |
| runtime/yon_rt.c SCT families | `sat_*`, `sat2_*`, `co0_*`, `leech_*`, `orb_*`, `sparse_*`, `frontier_init`, `alpha_3sat_gen`, `dimacs_run_co0_wavefront`, `sort_children_*` | SCT paper instrumentation and reproducibility |
| runtime/yon_rt_hsh.c | the `yon_rt_alg_*` catalog family | certified-algebra runtime API surface |
| runtime/yon_rt.c streams/net/rpc2 | `yon_rt_stream_shm_*`, `yon_rt_net_*`, `yon_rt_stream_produce/size/lookup`, `yon_rpc2_session*`, `yon_rpc2_random64`, `yon_rt_rpc2_queue_epoch` | Idraulica v1 plumbing kept as v2 substrate: the live cross-Space traffic goes through rpc2 invoke; decide at Idraulica v2 implementation time |
| runtime handler stack | `yon_rt_handler_push/pop/lookup`, `yon_handler_stack_clear/depth` | effects machinery reserve |
| runtime/yon_rt.c multiverse | `find_migration`, `yon_rt_register_migration`, `yon_rt_migration_count`, `yon_rt_space_count`, `yon_rt_heap_occupancy`, `yon_rt_capture_args` | migration/introspection reserve |
| mlir TopOps.td (13 ops) | `absurd`, `adjoint_check`, `bang`, `coequalizer`, `cpl_element`, `fibration`, `indeterminate`, `kleisli`, `nat_trans`, `place_dependent`, `reindex`, `sharing_constraint`, `split_fibration` | dialect API surface for the P7 lowering roadmap; `nat_trans` note: the surface nat transform lowers differently today |

## Class C: to decide, one by one

| Where | What | Question |
|---|---|---|
| runtime/xleech2_heap.c | `cidx_ensure/grow/insert/lookup`, `chain_extend`, `index_remove`, `meta_free`, `yon_xheap_alloc`, `yon_xheap_lookup_content`, `yon_xheap_registry_count`, `yon_xheap_unlink_shm` | allocator internals unreached from any path: dead branches of xleech2 (removal/compaction/secondary index) or kept-by-design? Verify by hand before touching the allocator |
| runtime/yon_rt.c | `hashmap_grow` | same caution as above |
| frontend/place_visibility.ml | `empty_for` | trivially prunable, or API symmetry? |
| frontend/prop_eval.ml | `make_ctx` | same |
| frontend/reduce.ml | `family5_equivalent` | R_Yon family 5: reserve like catt families, or stale? |
| frontend/stdlib_runtime.ml | `get_current_world_tag`, `lattice_union_cells` | stdlib surface that never landed? |

Tally: 63 OCaml toplevels, 80 C functions, 13 dialect ops, 1
unreachable branch. Proposal A is regression-safe by construction
(nothing referenced anywhere); B gets a `(* reserve: ... *)` marker
instead of deletion; C waits for a decision each.
