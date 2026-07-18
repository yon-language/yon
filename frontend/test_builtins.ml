(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_builtins.ml — oracle for the builtin value layer (builtins.ml).
 *
 * Two soundness properties are pinned:
 *
 *  (1) KNOWN-ANSWER arithmetic/comparison via try_eval_binop, including the
 *      "stay stuck" fixes: __div/__mod by zero -> None, and a non-finite
 *      result (overflow to Inf) -> None instead of a poison value.
 *
 *  (2) ROUND-TRIP: decode_number (encode_number d) = Some d for representative
 *      doubles — this is exactly the %g-lossiness fix (encode∘decode = id);
 *      and decode_string (encode_string "") = Some "" (the empty-string fix,
 *      "__str_" has length 6 so the >= 6 guard matters).
 *)

open Ast

let pass = ref 0
let fails = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fails; Printf.printf "  [FAIL] %s\n" name)

let enc = Builtins.encode_number
let dec = Builtins.decode_number

(* a binop result, decoded as a number; None if stuck or non-numeric *)
let binop_num op a b =
  match Builtins.try_eval_binop op a b with
  | Some t -> Builtins.decode_number t
  | None -> None

(* a binop result, decoded as a bool *)
let binop_bool op a b =
  match Builtins.try_eval_binop op a b with
  | Some t -> Builtins.decode_bool t
  | None -> None

let () =
  Printf.printf "=== builtins (value layer) oracle ===\n\n";

  (* ── (1) known-answer arithmetic ──────────────────────────────────── *)
  check "__add 2 3 -> 5.0"
    (binop_num "__add" (enc 2.0) (enc 3.0) = Some 5.0);
  check "__sub 2 3 -> -1.0"
    (binop_num "__sub" (enc 2.0) (enc 3.0) = Some (-1.0));
  check "__mul 2 3 -> 6.0"
    (binop_num "__mul" (enc 2.0) (enc 3.0) = Some 6.0);

  (* comparison + equality *)
  check "__lt 2 3 -> bool true"
    (binop_bool "__lt" (enc 2.0) (enc 3.0) = Some true);
  check "__eq on equal strings -> true"
    (Builtins.try_eval_binop "__eq"
       (Builtins.encode_string "hi") (Builtins.encode_string "hi")
     |> (function Some t -> Builtins.decode_bool t | None -> None) = Some true);

  (* ── stuck cases (the fixes) ──────────────────────────────────────── *)
  check "__div by 0 -> None (stuck)"
    (Builtins.try_eval_binop "__div" (enc 1.0) (enc 0.0) = None);
  check "__mod by 0 -> None (stuck, no NaN leak)"
    (Builtins.try_eval_binop "__mod" (enc 1.0) (enc 0.0) = None);
  (* overflow to +inf must stay stuck, not encode a poison value.
   * 1e308 * 1e308 = +inf in IEEE double. *)
  check "__mul overflow to inf -> None (non-finite stuck)"
    (Builtins.try_eval_binop "__mul" (enc 1e308) (enc 1e308) = None);

  (* ── (2) round-trip: decode (encode d) = Some d ───────────────────── *)
  let roundtrips d =
    dec (enc d) = Some d
  in
  List.iter
    (fun d ->
       check (Printf.sprintf "round-trip number %.17g" d) (roundtrips d))
    [0.0; 1.0; -5.0; 1.0 /. 3.0; 0.1; 1e19; 123456.789];

  (* ── empty-string + non-empty-string round-trip ───────────────────── *)
  check "decode_string (encode_string \"\") = Some \"\""
    (Builtins.decode_string (Builtins.encode_string "") = Some "");
  check "string round-trip: decode (encode \"hello world\") = Some \"hello world\""
    (Builtins.decode_string (Builtins.encode_string "hello world")
     = Some "hello world");

  (* sanity: encode_number produces the tagged Var the kernel treats as a value *)
  check "encode_number 5.0 is a value-tagged Var"
    (match enc 5.0 with Var s -> Reduce.is_value (Var s) | _ -> false);

  (* ── (3) path / groupoid laws (builtins.ml: concat / inv / ap / path_app) ──
   *
   * These pin the P2 fix: the path operations COMPUTE the groupoid laws as
   * definitional reductions instead of returning the inert `__coh_witness`.
   * We drive them through try_reduce_builtin — the exact reducer arm — and
   * assert the reduced term is structurally the law's RHS (term_equal).
   *
   * refl appears in two shapes; every law is checked against both:
   *   canonical `Refl a`  and  builtin var-applied `App (Var "refl", a)`.
   *)
  let a = Var "a" and b = Var "b" in
  let p = Var "p" and f = Var "f" in
  let concat x y = App (App (Var "concat", x), y) in
  let inv x = App (Var "inv", x) in
  let ap g x = App (App (Var "ap", g), x) in
  let path_app pt i = App (App (Var "path_app", pt), i) in
  let reduces_to name t expected =
    match Builtins.try_reduce_builtin t with
    | Some got -> check name (term_equal got expected)
    | None -> check (name ^ " [reduced? NO]") false
  in
  let stays_neutral name t =
    check (name ^ " stays neutral (no witness)")
      (Builtins.try_reduce_builtin t = None)
  in
  (* the two refl shapes *)
  let refl_core = Refl a in
  let refl_var  = App (Var "refl", a) in

  (* concat left unit: concat(refl_a, p) = p *)
  reduces_to "concat(refl_a, p) = p          (left unit, Refl)" (concat refl_core p) p;
  reduces_to "concat(refl_a, p) = p          (left unit, refl-var)" (concat refl_var p) p;
  (* concat right unit: concat(p, refl_a) = p *)
  reduces_to "concat(p, refl_a) = p          (right unit, Refl)" (concat p refl_core) p;
  reduces_to "concat(p, refl_a) = p          (right unit, refl-var)" (concat p refl_var) p;
  (* concat(refl_a, refl_b): left unit fires first -> refl_b (canonical refl) *)
  reduces_to "concat(refl_a, refl_b) = refl_b (both refl)" (concat refl_core (Refl b)) (Refl b);
  (* concat of two general paths: no unit law -> neutral *)
  stays_neutral "concat(p, q)" (concat p (Var "q"));

  (* inv of refl: inv(refl_a) = refl_a *)
  reduces_to "inv(refl_a) = refl_a           (inverse of refl, Refl)" (inv refl_core) (Refl a);
  reduces_to "inv(refl_a) = refl_a           (inverse of refl, refl-var)" (inv refl_var) (Refl a);
  (* inv involution: inv(inv(p)) = p *)
  reduces_to "inv(inv(p)) = p                 (involution)" (inv (inv p)) p;
  (* inv of a general path: neutral *)
  stays_neutral "inv(p)" (inv p);
  (* concat(inv(p), p): endpoint not recoverable untyped -> neutral (documented) *)
  stays_neutral "concat(inv(p), p)" (concat (inv p) p);
  stays_neutral "concat(p, inv(p))" (concat p (inv p));

  (* ap functoriality on refl: ap(f, refl_a) = refl_{f a} *)
  reduces_to "ap(f, refl_a) = refl_{f a}     (functoriality, Refl)"
    (ap f refl_core) (Refl (App (f, a)));
  reduces_to "ap(f, refl_a) = refl_{f a}     (functoriality, refl-var)"
    (ap f refl_var) (Refl (App (f, a)));
  (* ap on a general path: neutral (no runtime path value to map) *)
  stays_neutral "ap(f, p)" (ap f p);

  (* path_app: refl is the constant path at a for EVERY endpoint *)
  reduces_to "path_app(refl_a, 0) = a        (const path, Refl)"
    (path_app refl_core (Var "__num_0")) a;
  reduces_to "path_app(refl_a, 1) = a        (const path, Refl)"
    (path_app refl_core (Var "__num_1")) a;
  reduces_to "path_app(refl_a, i) = a        (const path, refl-var, var endpoint)"
    (path_app refl_var (Var "i")) a;
  (* path_app on a general path: value varies with i -> neutral *)
  stays_neutral "path_app(p, i)" (path_app p (Var "i"));

  (* no result of any path law is the inert __coh_witness placeholder *)
  check "no path law reduces to __coh_witness"
    (List.for_all
       (fun t -> match Builtins.try_reduce_builtin t with
          | Some (Var "__coh_witness") -> false
          | _ -> true)
       [ concat refl_core p; concat p refl_core; inv refl_core; inv (inv p);
         ap f refl_core; path_app refl_core (Var "__num_0") ]);

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails = 0 then exit 0 else exit 1
