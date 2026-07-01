; ModuleID = 'LLVMDialectModule'
source_filename = "LLVMDialectModule"

declare double @yon_rt_map_empty()

declare double @yon_rt_map_put(double, double, double)

declare double @yon_rt_map_get(double, double)

declare double @yon_rt_map_contains(double, double)

declare double @yon_rt_map_size(double)

declare double @yon_rt_set_empty()

declare double @yon_rt_set_add(double, double)

declare double @yon_rt_set_contains(double, double)

declare double @yon_rt_set_size(double)

declare double @yon_rt_vec_empty()

declare double @yon_rt_vec_size(double)

declare double @yon_rt_vec_get(double, double)

declare double @yon_rt_vec_push(double, double)

declare double @yon_rt_vec_set(double, double, double)

declare double @yon_rt_list_empty(double)

declare double @yon_rt_list_cons(double, double)

declare double @yon_rt_list_head(double)

declare double @yon_rt_list_tail(double)

declare double @yon_rt_list_length(double)

declare double @yon_rt_hashset_empty()

declare double @yon_rt_hashset_add(double, double)

declare double @yon_rt_hashset_contains(double, double)

declare double @yon_rt_hashset_size(double)

declare double @yon_rt_hashset_to_list(double)

declare double @yon_rt_xset_empty()

declare double @yon_rt_xset_add(double, double)

declare double @yon_rt_xset_contains(double, double)

declare double @yon_rt_xset_size(double)

declare double @yon_rt_xset_union(double, double)

declare double @yon_rt_xset_intersect(double, double)

declare double @yon_rt_xset_to_list(double)

declare double @yon_rt_xrelset_empty()

declare double @yon_rt_xrelset_add_ref(double, double)

declare double @yon_rt_xrelset_add(double, double)

declare double @yon_rt_xrelset_contains(double, double)

declare double @yon_rt_xrelset_size(double)

declare double @yon_rt_xrelset_union(double, double)

declare double @yon_rt_xrelset_intersect(double, double)

declare double @yon_rt_xrelmap_empty()

declare double @yon_rt_xrelmap_add_ref(double, double)

declare double @yon_rt_xrelmap_insert(double, double, double)

declare double @yon_rt_xrelmap_get(double, double)

declare double @yon_rt_xrelmap_contains(double, double)

declare double @yon_rt_xrelmap_size(double)

declare double @yon_rt_xsimplex_empty()

declare double @yon_rt_xsimplex_pair(double, double)

declare double @yon_rt_xsimplex_triangle(double, double, double)

declare double @yon_rt_xsimplex_triangle_fine(double, double, double)

declare double @yon_rt_xsimplex_omega(double, double, double)

declare double @yon_rt_xsimplex_add(double, double, double)

declare double @yon_rt_xsimplex_count(double, double)

declare double @yon_rt_xsimplex_dominant(double)

declare double @yon_rt_xsimplex_size(double)

declare double @yon_rt_xtower_class(double, double)

declare double @yon_rt_xtower_same_branch(double, double, double)

declare double @yon_rt_xtower_width(double)

declare double @yon_rt_xtower_depth()

declare double @yon_rt_map_to_list(double)

declare double @yon_rt_set_to_list(double)

declare double @yon_rt_merkle_leaf(double)

declare double @yon_rt_merkle_node2(double, double, double)

declare double @yon_rt_merkle_node2_commutative(double, double, double)

declare double @yon_rt_merkle_label(double)

declare double @yon_rt_merkle_child(double, double)

declare double @yon_rt_merkle_equal(double, double)

declare double @yon_rt_merkle_to_list(double)

declare double @yon_rt_merkle_node3(double, double, double, double)

declare double @yon_rt_merkle_node4(double, double, double, double, double)

declare double @yon_rt_leech_sign_canonical(double, double)

declare double @yon_rt_leech_syndrome(double)

declare double @yon_rt_leech_orbit_id(double)

declare double @yon_rt_leech_same_orbit(double, double)

declare double @yon_rt_leech_m24_orbit(double)

declare double @yon_rt_leech_gcode_weight(double)

declare double @yon_rt_leech_cocode_weight(double)

declare double @yon_rt_leech_xi_apply(double)

declare double @yon_rt_leech_co0_step(double)

declare double @yon_rt_leech_co0_canonical_exact(double)

declare double @yon_rt_leech_co0_equivalent(double, double)

declare double @yon_rt_leech_transport(double, double)

declare double @yon_rt_leech_transport_apply(double, double)

declare double @yon_rt_leech_co0_canonical(double)

declare double @yon_rt_leech_co0_orbit_size(double, double)

declare double @yon_rt_leech_embed_bits(double, double)

declare double @yon_rt_leech_point(double)

declare double @yon_rt_leech_pair_subtype(double, double)

declare double @yon_rt_cap_grant(double)

declare double @yon_rt_cap_check(double)

declare double @yon_rt_cap_revoke(double)

declare double @yon_rt_move_register_version(double, double)

declare double @yon_rt_move_current_version(double)

declare double @yon_rt_math_sqrt(double)

declare double @yon_rt_math_abs(double)

declare double @yon_rt_math_floor(double)

declare double @yon_rt_math_ceil(double)

declare double @yon_rt_math_round(double)

declare double @yon_rt_math_min(double, double)

declare double @yon_rt_math_max(double, double)

declare double @yon_rt_math_pow(double, double)

declare double @yon_rt_math_log(double)

declare double @yon_rt_math_exp(double)

declare double @yon_rt_math_sin(double)

declare double @yon_rt_math_cos(double)

declare double @yon_rt_math_pi()

declare double @yon_rt_math_e()

declare double @yon_rt_math_modulo(double, double)

declare double @yon_rt_math_gcd(double, double)

declare double @yon_rt_math_lcm(double, double)

declare double @yon_rt_magma_empty(double)

declare double @yon_rt_magma_gen(double, double)

declare double @yon_rt_magma_is_commutative(double)

declare double @yon_rt_magma_is_associative(double)

declare double @yon_rt_magma_identity(double)

declare double @yon_rt_magma_closure_size(double)

declare double @yon_rt_land_reach(double, double)

declare double @yon_rt_land_witness(double, double)

declare double @yon_rt_magma_word_push(double, double)

declare double @yon_rt_magma_normal_form(double)

declare double @yon_rt_magma_from_algebra(double)

declare double @yon_rt_math_log2(double)

declare double @yon_rt_math_log10(double)

declare double @yon_rt_math_atan2(double, double)

declare double @yon_rt_math_sinh(double)

declare double @yon_rt_math_cosh(double)

declare double @yon_rt_math_tanh(double)

declare double @yon_rt_hashset_union(double, double)

declare double @yon_rt_hashset_intersect(double, double)

declare double @yon_rt_list_reverse(double)

declare double @yon_rt_bits_and(double, double)

declare double @yon_rt_bits_or(double, double)

declare double @yon_rt_bits_xor(double, double)

declare double @yon_rt_bits_not(double)

declare double @yon_rt_bits_shl(double, double)

declare double @yon_rt_bits_shr(double, double)

declare double @yon_rt_bits_popcount(double)

declare double @yon_rt_io_print_num(double)

declare double @yon_rt_string_from_int(double)

declare double @yon_rt_string_length(double)

declare double @yon_rt_string_concat(double, double)

declare double @yon_rt_string_equal(double, double)

declare double @yon_rt_string_char_at(double, double)

declare double @yon_rt_string_print(double)

declare double @yon_rt_string_parse_number(double)

declare double @yon_rt_string_substring(double, double, double)

declare double @yon_rt_string_find_char(double, double, double)

declare double @yon_rt_string_from_char(double)

declare double @yon_rt_file_read_text(double)

declare double @yon_rt_file_write_text(double, double)

declare double @yon_rt_file_append_text(double, double)

declare double @yon_rt_env_get(double)

declare double @yon_rt_env_has(double)

declare double @yon_rt_args_count()

declare double @yon_rt_args_get(double)

declare double @yon_rt_file_exists(double)

declare double @yon_rt_seq_range(double)

declare double @yon_rt_bits_fold(double, double, double)

declare double @yon_rt_bits_or_64(double, double)

declare double @yon_rt_bits_and_64(double, double)

declare double @yon_rt_bits_xor_64(double, double)

declare double @yon_rt_time_now_ms()

declare double @yon_rt_time_now_ns()

declare double @yon_rt_random_seed(double)

declare double @yon_rt_random_int()

declare double @yon_rt_random_range(double, double)

declare double @yon_rt_crypto_fnv1a(double)

declare double @yon_rt_crypto_hash_int(double)

declare double @yon_rt_hashset_try_add(double, double)

declare double @yon_rt_hashset_at_bucket(double, double)

declare double @yon_rt_hashset_dir_capacity(double)

declare double @yon_rt_hsh_empty(double)

declare double @yon_rt_hsh_empty_mod(double, double)

declare double @yon_rt_hsh_step(double, double, double)

declare double @yon_rt_hsh_contains(double, double, double)

declare double @yon_rt_hsh_backward(double, double, double)

declare double @yon_rt_hsh_shared_levels(double)

declare double @yon_rt_hsh_levels(double)

declare double @yon_rt_voyagerlist_empty()

declare double @yon_rt_arena_empty()

declare double @yon_rt_arena_put(double, double, double)

declare double @yon_rt_arena_get(double, double)

declare double @yon_rt_arena_occupied(double, double)

declare double @yon_rt_arena_orbit(double, double)

declare double @yon_rt_arena_same_orbit(double, double, double)

declare double @yon_rt_arena_fuse(double, double, double, double)

declare double @yon_rt_arena_fusion_count(double, double)

declare double @yon_rt_voyagerlist_append(double, double)

declare double @yon_rt_voyagerlist_get(double, double)

declare double @yon_rt_voyagerlist_size(double)

declare double @yon_rt_voyagerlist_corrupt_at(double, double, double)

declare double @yon_rt_voyagerlist_to_list(double)

declare double @yon_rt_observe_alloc(double)

declare double @yon_rt_observe(double, double, double)

declare i32 @yon_rt_xheap_used()

declare double @yon_rt_spawn_self(double)

declare double @yon_rt_spawn_index()

declare double @yon_rt_voyagerlist_seal(double)

declare double @yon_rt_voyagerlist_open(double)

declare double @yon_rt_voyagerlist_corrupt(double, double)

declare double @yon_rt_conway_gen_key(double)

declare double @yon_rt_conway_seal_slot(double, double)

declare double @yon_rt_conway_unseal_slot(double, double)

declare double @yon_rt_conway_key_equal(double, double)

declare void @yon_rt_maybe_serve()

define i32 @main() {
  call void @yon_rt_maybe_serve()
  ret i32 0
}

define double @__yon_dispatch(double %0, double %1, double %2, double %3, double %4) {
  ret double -7.770000e+02
}

!llvm.module.flags = !{!0}

!0 = !{i32 2, !"Debug Info Version", i32 3}
