module {
  topos.world @__Default {
    topos.place @AddPlace in @__Default attributes {law_associative, law_commutative, law_monotone, with_effects} {
      topos.operation @add([f64, f64]) -> f64 attributes {algebra = "Additive", certified_associative = true, certified_commutative = true, certified_monotone = true} {
      }
    }
  }
  func.func private @yon_rt_map_empty() -> f64
  func.func private @yon_rt_map_put(f64, f64, f64) -> f64
  func.func private @yon_rt_map_get(f64, f64) -> f64
  func.func private @yon_rt_map_contains(f64, f64) -> f64
  func.func private @yon_rt_map_size(f64) -> f64
  func.func private @yon_rt_set_empty() -> f64
  func.func private @yon_rt_set_add(f64, f64) -> f64
  func.func private @yon_rt_set_contains(f64, f64) -> f64
  func.func private @yon_rt_set_size(f64) -> f64
  func.func private @yon_rt_list_empty(f64) -> f64
  func.func private @yon_rt_list_cons(f64, f64) -> f64
  func.func private @yon_rt_list_head(f64) -> f64
  func.func private @yon_rt_list_tail(f64) -> f64
  func.func private @yon_rt_list_length(f64) -> f64
  func.func private @yon_rt_hashset_empty() -> f64
  func.func private @yon_rt_hashset_add(f64, f64) -> f64
  func.func private @yon_rt_hashset_contains(f64, f64) -> f64
  func.func private @yon_rt_hashset_size(f64) -> f64
  func.func private @yon_rt_hashset_to_list(f64) -> f64
  func.func private @yon_rt_xset_empty() -> f64
  func.func private @yon_rt_xset_add(f64, f64) -> f64
  func.func private @yon_rt_xset_contains(f64, f64) -> f64
  func.func private @yon_rt_xset_size(f64) -> f64
  func.func private @yon_rt_xset_union(f64, f64) -> f64
  func.func private @yon_rt_xset_intersect(f64, f64) -> f64
  func.func private @yon_rt_xset_to_list(f64) -> f64
  func.func private @yon_rt_map_to_list(f64) -> f64
  func.func private @yon_rt_set_to_list(f64) -> f64
  func.func private @yon_rt_merkle_leaf(f64) -> f64
  func.func private @yon_rt_merkle_node2(f64, f64, f64) -> f64
  func.func private @yon_rt_merkle_node2_commutative(f64, f64, f64) -> f64
  func.func private @yon_rt_merkle_label(f64) -> f64
  func.func private @yon_rt_merkle_child(f64, f64) -> f64
  func.func private @yon_rt_merkle_equal(f64, f64) -> f64
  func.func private @yon_rt_merkle_to_list(f64) -> f64
  func.func private @yon_rt_merkle_node3(f64, f64, f64, f64) -> f64
  func.func private @yon_rt_merkle_node4(f64, f64, f64, f64, f64) -> f64
  func.func private @yon_rt_leech_sign_canonical(f64, f64) -> f64
  func.func private @yon_rt_leech_syndrome(f64) -> f64
  func.func private @yon_rt_leech_orbit_id(f64) -> f64
  func.func private @yon_rt_leech_same_orbit(f64, f64) -> f64
  func.func private @yon_rt_leech_m24_orbit(f64) -> f64
  func.func private @yon_rt_leech_gcode_weight(f64) -> f64
  func.func private @yon_rt_leech_cocode_weight(f64) -> f64
  func.func private @yon_rt_leech_xi_apply(f64) -> f64
  func.func private @yon_rt_leech_co0_step(f64) -> f64
  func.func private @yon_rt_leech_co0_canonical_exact(f64) -> f64
  func.func private @yon_rt_leech_co0_equivalent(f64, f64) -> f64
  func.func private @yon_rt_leech_co0_canonical(f64, f64) -> f64
  func.func private @yon_rt_leech_co0_orbit_size(f64, f64) -> f64
  func.func private @yon_rt_cap_grant(f64) -> f64
  func.func private @yon_rt_cap_check(f64) -> f64
  func.func private @yon_rt_cap_revoke(f64) -> f64
  func.func private @yon_rt_move_register_version(f64, f64) -> f64
  func.func private @yon_rt_move_current_version(f64) -> f64
  func.func private @yon_rt_math_sqrt(f64) -> f64
  func.func private @yon_rt_math_abs(f64) -> f64
  func.func private @yon_rt_math_floor(f64) -> f64
  func.func private @yon_rt_math_ceil(f64) -> f64
  func.func private @yon_rt_math_round(f64) -> f64
  func.func private @yon_rt_math_min(f64, f64) -> f64
  func.func private @yon_rt_math_max(f64, f64) -> f64
  func.func private @yon_rt_math_pow(f64, f64) -> f64
  func.func private @yon_rt_math_log(f64) -> f64
  func.func private @yon_rt_math_exp(f64) -> f64
  func.func private @yon_rt_math_sin(f64) -> f64
  func.func private @yon_rt_math_cos(f64) -> f64
  func.func private @yon_rt_math_pi() -> f64
  func.func private @yon_rt_math_e() -> f64
  func.func private @yon_rt_math_modulo(f64, f64) -> f64
  func.func private @yon_rt_math_gcd(f64, f64) -> f64
  func.func private @yon_rt_math_lcm(f64, f64) -> f64
  func.func private @yon_rt_magma_empty(f64) -> f64
  func.func private @yon_rt_magma_gen(f64, f64) -> f64
  func.func private @yon_rt_magma_is_commutative(f64) -> f64
  func.func private @yon_rt_magma_is_associative(f64) -> f64
  func.func private @yon_rt_magma_identity(f64) -> f64
  func.func private @yon_rt_magma_closure_size(f64) -> f64
  func.func private @yon_rt_magma_reachable(f64, f64) -> f64
  func.func private @yon_rt_magma_word_push(f64, f64) -> f64
  func.func private @yon_rt_magma_normal_form(f64) -> f64
  func.func private @yon_rt_magma_from_algebra(f64) -> f64
  func.func private @yon_rt_magma_subsetsum(f64, f64) -> f64
  func.func private @yon_rt_magma_subsetsum_mask(f64, f64) -> f64
  func.func private @yon_rt_magma_knap_item(f64, f64, f64) -> f64
  func.func private @yon_rt_magma_knapsack(f64, f64) -> f64
  func.func private @yon_rt_magma_knapsack_mask(f64, f64) -> f64
  func.func private @yon_rt_math_log2(f64) -> f64
  func.func private @yon_rt_math_log10(f64) -> f64
  func.func private @yon_rt_math_atan2(f64, f64) -> f64
  func.func private @yon_rt_math_sinh(f64) -> f64
  func.func private @yon_rt_math_cosh(f64) -> f64
  func.func private @yon_rt_math_tanh(f64) -> f64
  func.func private @yon_rt_hashset_union(f64, f64) -> f64
  func.func private @yon_rt_hashset_intersect(f64, f64) -> f64
  func.func private @yon_rt_list_reverse(f64) -> f64
  func.func private @yon_rt_bits_and(f64, f64) -> f64
  func.func private @yon_rt_bits_or(f64, f64) -> f64
  func.func private @yon_rt_bits_xor(f64, f64) -> f64
  func.func private @yon_rt_bits_not(f64) -> f64
  func.func private @yon_rt_bits_shl(f64, f64) -> f64
  func.func private @yon_rt_bits_shr(f64, f64) -> f64
  func.func private @yon_rt_bits_popcount(f64) -> f64
  func.func private @yon_rt_io_print_num(f64) -> f64
  func.func private @yon_rt_string_from_int(f64) -> f64
  func.func private @yon_rt_string_length(f64) -> f64
  func.func private @yon_rt_string_concat(f64, f64) -> f64
  func.func private @yon_rt_string_equal(f64, f64) -> f64
  func.func private @yon_rt_string_char_at(f64, f64) -> f64
  func.func private @yon_rt_string_print(f64) -> f64
  func.func private @yon_rt_string_parse_number(f64) -> f64
  func.func private @yon_rt_string_substring(f64, f64, f64) -> f64
  func.func private @yon_rt_string_find_char(f64, f64, f64) -> f64
  func.func private @yon_rt_string_from_char(f64) -> f64
  func.func private @yon_rt_file_read_text(f64) -> f64
  func.func private @yon_rt_file_exists(f64) -> f64
  func.func private @yon_rt_dimacs_uf20_load(f64) -> f64
  func.func private @yon_rt_dimacs_uf50_load(f64) -> f64
  func.func private @yon_rt_dimacs_n_vars() -> f64
  func.func private @yon_rt_dimacs_G() -> f64
  func.func private @yon_rt_dimacs_clause(f64) -> f64
  func.func private @yon_rt_seq_range(f64) -> f64
  func.func private @yon_rt_bits_fold(f64, f64, f64) -> f64
  func.func private @yon_rt_bits_or_64(f64, f64) -> f64
  func.func private @yon_rt_bits_and_64(f64, f64) -> f64
  func.func private @yon_rt_bits_xor_64(f64, f64) -> f64
  func.func private @yon_rt_time_now_ms() -> f64
  func.func private @yon_rt_time_now_ns() -> f64
  func.func private @yon_rt_random_seed(f64) -> f64
  func.func private @yon_rt_random_int() -> f64
  func.func private @yon_rt_random_range(f64, f64) -> f64
  func.func private @yon_rt_crypto_fnv1a(f64) -> f64
  func.func private @yon_rt_crypto_hash_int(f64) -> f64
  func.func private @yon_rt_sat_3sat_run(f64, f64, f64) -> f64
  func.func private @yon_rt_sat_3sat_filtered(f64, f64, f64, f64) -> f64
  func.func private @yon_rt_sat_dimacs_run(f64, f64) -> f64
  func.func private @yon_rt_sat_dimacs_uf20(f64, f64) -> f64
  func.func private @yon_rt_sat_dimacs_uf50(f64, f64) -> f64
  func.func private @yon_rt_sat_dimacs_o_at(f64) -> f64
  func.func private @yon_rt_sat_3sat_alpha(f64, f64, f64, f64) -> f64
  func.func private @yon_rt_sat_dimacs_uf20_orbital(f64, f64) -> f64
  func.func private @yon_rt_sat_dimacs_uf50_orbital(f64, f64) -> f64
  func.func private @yon_rt_sat_dimacs_uf20_leech(f64, f64) -> f64
  func.func private @yon_rt_sat_dimacs_uf50_leech(f64, f64) -> f64
  func.func private @yon_rt_sat_dimacs_leech_o_at(f64) -> f64
  func.func private @yon_rt_sat_dimacs_uf20_co0(f64, f64) -> f64
  func.func private @yon_rt_sat_dimacs_orbital_o_at(f64) -> f64
  func.func private @yon_rt_hashmap_orbital_set(f64, f64, f64) -> f64
  func.func private @yon_rt_hashmap_orbital_get(f64, f64) -> f64
  func.func private @yon_rt_hashset_orbital_add(f64, f64) -> f64
  func.func private @yon_rt_hashset_orbital_contains(f64, f64) -> f64
  func.func private @yon_rt_hashmap_orbital_set_with(f64, f64, f64, f64) -> f64
  func.func private @yon_rt_hashmap_orbital_get_with(f64, f64, f64) -> f64
  func.func private @yon_rt_hashset_orbital_add_with(f64, f64, f64) -> f64
  func.func private @yon_rt_hashset_add_canon_sn(f64, f64) -> f64
  func.func private @yon_rt_hashset_try_add(f64, f64) -> f64
  func.func private @yon_rt_hashset_try_add_canon_sn(f64, f64) -> f64
  func.func private @yon_rt_hashset_at_bucket(f64, f64) -> f64
  func.func private @yon_rt_hashset_dir_capacity(f64) -> f64
  func.func private @yon_rt_hashset_orbital_contains_with(f64, f64, f64) -> f64
  func.func private @yon_rt_xset_orbital_add(f64, f64, f64) -> f64
  func.func private @yon_rt_xset_orbital_contains(f64, f64, f64) -> f64
  func.func private @yon_rt_merkle_leaf_orbital(f64, f64) -> f64
  func.func private @yon_rt_hsh_empty(f64) -> f64
  func.func private @yon_rt_hsh_empty_mod(f64, f64) -> f64
  func.func private @yon_rt_hsh_step(f64, f64, f64) -> f64
  func.func private @yon_rt_hsh_contains(f64, f64, f64) -> f64
  func.func private @yon_rt_hsh_backward(f64, f64, f64) -> f64
  func.func private @yon_rt_hsh_shared_levels(f64) -> f64
  func.func private @yon_rt_hsh_levels(f64) -> f64
  func.func private @yon_rt_space_orbital_set(f64, f64, f64, f64) -> f64
  func.func private @yon_rt_space_orbital_get(f64, f64, f64) -> f64
  func.func private @yon_rt_voyagerlist_empty() -> f64
  func.func private @yon_rt_voyagerlist_append(f64, f64) -> f64
  func.func private @yon_rt_voyagerlist_get(f64, f64) -> f64
  func.func private @yon_rt_voyagerlist_size(f64) -> f64
  func.func private @yon_rt_voyagerlist_corrupt_at(f64, f64, f64) -> f64
  func.func private @yon_rt_voyagerlist_to_list(f64) -> f64
  func.func private @yon_rt_observe_alloc(f64) -> f64
  func.func private @yon_rt_observe(f64, f64, f64) -> f64
  func.func private @yon_rt_xheap_used() -> i32
  func.func private @yon_rt_spawn_self(f64) -> f64
  func.func private @yon_rt_spawn_index() -> f64
  func.func private @yon_rt_voyagerlist_seal(f64) -> f64
  func.func private @yon_rt_voyagerlist_open(f64) -> f64
  func.func private @yon_rt_voyagerlist_corrupt(f64, f64) -> f64
  func.func private @yon_rt_conway_gen_key(f64) -> f64
  func.func private @yon_rt_conway_seal_slot(f64, f64) -> f64
  func.func private @yon_rt_conway_unseal_slot(f64, f64) -> f64
  func.func private @yon_rt_conway_key_equal(f64, f64) -> f64
  func.func private @yon_rt_new(i32, !llvm.ptr, i32) -> i64
  func.func private @yon_rt_field_load(i64, i32, i32, !llvm.ptr) -> i32
  func.func private @yon_rt_fold_named(i32, i64, !llvm.ptr, i32, !llvm.ptr) -> i64
  llvm.mlir.global internal constant @yon_fold_str_sum_f64("sum_f64\00") {addr_space = 0 : i32}
  llvm.mlir.global internal constant @yon_fold_str_max_f64("max_f64\00") {addr_space = 0 : i32}
  llvm.mlir.global internal constant @yon_fold_str_min_f64("min_f64\00") {addr_space = 0 : i32}
  llvm.mlir.global internal constant @yon_fold_str_sum_i64("sum_i64\00") {addr_space = 0 : i32}
  llvm.mlir.global internal constant @yon_fold_str_max_i64("max_i64\00") {addr_space = 0 : i32}
  llvm.mlir.global internal constant @yon_fold_str_min_i64("min_i64\00") {addr_space = 0 : i32}
  llvm.mlir.global internal constant @yon_fold_str_sum_vec_f64("sum_vec_f64\00") {addr_space = 0 : i32}
  llvm.mlir.global internal constant @yon_fold_str_max_vec_f64("max_vec_f64\00") {addr_space = 0 : i32}
  llvm.mlir.global internal constant @yon_fold_str_or_bitset("or_bitset\00") {addr_space = 0 : i32}
  func.func @__new_AddPlace() -> !topos.section<"AddPlace"> {
    %c1_i32 = arith.constant 1 : i32
    %0 = llvm.alloca %c1_i32 x i8 : (i32) -> !llvm.ptr
    %c0_i32 = arith.constant 0 : i32
    %1 = call @yon_rt_new(%c0_i32, %0, %c1_i32) : (i32, !llvm.ptr, i32) -> i64
    %2 = topos.xcoord_to_section %1 : !topos.section<"AddPlace">
    return %2 : !topos.section<"AddPlace">
  }
  func.func private @AddPlace__add(i32, f64, f64) -> f64
  func.func @main() -> i32 {
    %cst = arith.constant 0.000000e+00 : f64
    %0 = arith.fptosi %cst : f64 to i32
    return %0 : i32
  }
  func.func @AddPlace_instantiate() -> f64 {
    %cst = arith.constant 0.000000e+00 : f64
    %0 = call @yon_rt_magma_from_algebra(%cst) : (f64) -> f64
    return %0 : f64
  }
}

