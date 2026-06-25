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

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails = 0 then exit 0 else exit 1
