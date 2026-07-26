(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_xtower_surface.ml — surface-exposure oracle for XTower.
 *
 * XTower is the nested stabilizer tower Co0 ⊃ N ⊃ M24 ⊃ id (widths 1/3/12/196560,
 * depth 4), exposed to the surface next to XSimplex. This oracle pins the three
 * properties of the EXPOSURE; the runtime VALUES (1/3/12/196560, 4, the partition)
 * are checked by the native run in regression/book/jp/08_xtower_surface, since they
 * are C-runtime constants this OCaml layer cannot evaluate.
 *
 *   (1) REGISTRY  — Stdlib_runtime.lookup_stdlib_signature resolves all four methods
 *                   with the right arities. This is the exact bug that bit
 *                   VoyagerList.seal: registered in emit but not in the tycheck
 *                   registry -> "unknown function or operation" at typecheck.
 *   (2) TYPECHECK — a program calling each of the four methods is ACCEPTED.
 *   (3) LOWER     — the emitted MLIR contains the matching yon_rt_xtower_* func.call.
 *
 * Grounded on: stdlib_runtime.ml:843 lookup_stdlib_signature; tycheck.ml:4194
 * check_program; the real pipeline in yoner_emit_mlir.ml (check_program -> desugar
 * with env -> Type_erase.erase -> set_views_list -> emit_program).
 *)

open Surface_ast

let pass = ref 0
let fails = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fails; Printf.printf "  [FAIL] %s\n" name)

let loc = dummy_loc
let enum (n : float) : expr = ELit (LitNumber n, loc)
let call name args = ECall (name, args, loc)

let mkmain ~body : fun_decl =
  { fn_name = "main"; fn_type_params = []; fn_params = [];
    fn_return = Some (TyPrim "number"); fn_on_error = None; fn_visits = []; fn_home = None;
    fn_internal = false; fn_body = body; fn_loc = loc }

(* true iff the single-function program is ACCEPTED by the type checker *)
let accepts (fn : fun_decl) : bool =
  (Tycheck.check_program [ TopFun fn ]).Tycheck.cr_errors = []

(* full pipeline to MLIR text, mirroring yoner_emit_mlir.ml; "" on any pipeline
 * exception so a hiccup reports as a clean [FAIL], not a crashed oracle. *)
let mlir_of (fn : fun_decl) : string =
  try
    let prog = [ TopFun fn ] in
    let cr = Tycheck.check_program prog in
    let dr = Desugar.desugar_program ~env:(Some cr.Tycheck.cr_env) prog in
    let dr = Type_erase.erase dr in
    Emit_mlir.set_views_list [];
    Emit_mlir.emit_program dr
  with _ -> ""

let contains (hay : string) (needle : string) : bool =
  let nl = String.length needle and hl = String.length hay in
  let rec go i = i + nl <= hl && (String.sub hay i nl = needle || go (i + 1)) in
  nl > 0 && go 0

let arity (qname : string) : int option =
  match Stdlib_runtime.lookup_stdlib_signature qname with
  | Some (args, _) -> Some (List.length args)
  | None -> None

let () =
  Printf.printf "=== XTower surface-exposure oracle ===\n\n";

  (* (1) registry: all four methods resolve with the right arity *)
  check "registry: XTower.class -> 2 args"       (arity "XTower__class" = Some 2);
  check "registry: XTower.same_branch -> 3 args" (arity "XTower__same_branch" = Some 3);
  check "registry: XTower.width -> 1 arg"        (arity "XTower__width" = Some 1);
  check "registry: XTower.depth -> 0 args"       (arity "XTower__depth" = Some 0);

  (* (2) typecheck: a program calling each method is accepted *)
  check "typecheck: return XTower.class(1536, 2)"
    (accepts (mkmain ~body:[ SReturn (call "XTower__class" [enum 1536.0; enum 2.0], loc) ]));
  check "typecheck: return XTower.same_branch(1536, 1280, 2)"
    (accepts (mkmain ~body:[ SReturn (call "XTower__same_branch" [enum 1536.0; enum 1280.0; enum 2.0], loc) ]));
  check "typecheck: return XTower.width(0)"
    (accepts (mkmain ~body:[ SReturn (call "XTower__width" [enum 0.0], loc) ]));
  check "typecheck: return XTower.depth()"
    (accepts (mkmain ~body:[ SReturn (call "XTower__depth" [], loc) ]));

  (* (3) lower: the emitted MLIR calls the matching runtime symbol *)
  check "lower: XTower.class -> @yon_rt_xtower_class"
    (contains (mlir_of (mkmain ~body:[ SReturn (call "XTower__class" [enum 1536.0; enum 2.0], loc) ]))
              "yon_rt_xtower_class");
  check "lower: XTower.same_branch -> @yon_rt_xtower_same_branch"
    (contains (mlir_of (mkmain ~body:[ SReturn (call "XTower__same_branch" [enum 1536.0; enum 1280.0; enum 2.0], loc) ]))
              "yon_rt_xtower_same_branch");
  check "lower: XTower.width -> @yon_rt_xtower_width"
    (contains (mlir_of (mkmain ~body:[ SReturn (call "XTower__width" [enum 0.0], loc) ]))
              "yon_rt_xtower_width");
  check "lower: XTower.depth -> @yon_rt_xtower_depth"
    (contains (mlir_of (mkmain ~body:[ SReturn (call "XTower__depth" [], loc) ]))
              "yon_rt_xtower_depth");

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails = 0 then exit 0 else exit 1
