(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* law_check.ml — the verification of declared laws, one pass.
 *
 * A natural transformation eta : F => G claims, for every morphism N the two
 * functors share and every object it binds, the square
 *     eta(F(N)(x)) = G(N)(eta(x))
 * The verdict is a value of Omega:
 *   - proven: the two sides are the same term after normalization, or the
 *     SMT solver finds no input where they differ;
 *   - refuted: the solver exhibits an input where they differ;
 *   - unknown: neither — the square leaves the fragment the normalizer and
 *     the solver model, or the solver is not available.
 * A refuted law rejects the program; an unknown law is not certified and
 * rejects it too, unless the transformation is declared an axiom (`is given`).
 *
 * The solver models the values the program computes with, never an
 * idealization: Number is an IEEE double, Int64 a 64-bit two's-complement
 * integer, and two values are the same iff they have the same bits (the
 * identity the runtime uses). *)

module S = Surface_ast

type verdict =
  | Proven of string        (* by what *)
  | Refuted of string       (* a counterexample *)
  | Unknown of string       (* why it is not decided *)

type square = {
  sq_nat : S.nat_transform_decl;
  sq_morphism : string;
  sq_object : string;
  sq_verdict : verdict;
}

(* The functions a square is made of: the program's own functions, and the
   wrappers F__N / eta__obj the morphs and the transformation stand for. *)
let square_index (p : S.program) =
  let fun_decl_index : (string * S.fun_decl) list =
    List.filter_map (function S.TopFun fd -> Some (fd.S.fn_name, fd) | _ -> None) p in
  let reduction_index : (string * S.reduction_decl) list =
    List.filter_map (function S.TopReduction rd -> Some (rd.S.rd_name, rd) | _ -> None) p in
  let synth_wrapper_decl (morph_name : string) (n_src : string) (m_tgt : string) : S.fun_decl option =
    match List.assoc_opt m_tgt fun_decl_index with
    | Some target_fd ->
        let param = match target_fd.S.fn_params with
          | p :: _ -> p
          | [] -> {S.param_name = "x"; param_ty = S.TyPrim "number"}
        in
        let body : S.stmt list = [
          S.SReturn (
            S.ECall (m_tgt,
              [S.EVar (param.S.param_name, S.dummy_loc)],
              S.dummy_loc),
            S.dummy_loc)
        ] in
        Some {
          S.fn_name = morph_name ^ "__" ^ n_src;
          fn_type_params = [];
          fn_params = [param];
          fn_return = target_fd.S.fn_return;
          fn_on_error = None; fn_visits = []; fn_internal = false; fn_given = false; fn_home = None;
          fn_body = body;
          fn_loc = S.dummy_loc;
        }
    | None ->
        (* The target may be a reduction. We inline the clause with a
         * matching name if it has the form
         *   on N(p) { return e } *)
        (match List.assoc_opt m_tgt reduction_index with
         | Some rd ->
             let clause = List.find_opt (function
               | S.RcOn (cname, _, _, _) -> cname = n_src
               | _ -> false
             ) rd.S.rd_clauses in
             (match clause with
              | Some (S.RcOn (_, params, body_stmts, _)) ->
                  (match params, body_stmts with
                   | [param], [S.SReturn (body_expr, _)] ->
                       (* Direct inline: the wrapper body is the clause
                        * body. *)
                       Some {
                         S.fn_name = morph_name ^ "__" ^ n_src;
                         fn_type_params = [];
                         fn_params = [param];
                         fn_return = Some (S.TyPrim "number");
                         fn_on_error = None; fn_visits = []; fn_internal = false; fn_given = false; fn_home = None;
                         fn_body = [S.SReturn (body_expr, S.dummy_loc)];
                         fn_loc = S.dummy_loc;
                       }
                   | _ -> None)
              | _ -> None)
         | None -> None)
  in
  let all_morphs = List.filter_map (function
    | S.TopMorph mp -> Some mp | _ -> None) p in
  let all_nats = List.filter_map (function
    | S.TopNatTransform nt -> Some nt | _ -> None) p in
  (* For each morph, synthesize the virtual wrappers and add to fun_idx *)
  let wrapper_decls = List.concat_map (fun (mp : S.morph_decl) ->
    List.filter_map (fun (n_src, m_tgt) ->
      synth_wrapper_decl mp.S.mp_name n_src m_tgt
    ) mp.S.mp_on_morphism_map
  ) all_morphs in
  let nat_wrapper_decls = List.concat_map (fun (nt : S.nat_transform_decl) ->
    List.filter_map (fun (obj, tgt) ->
      synth_wrapper_decl nt.S.nt_name obj tgt
    ) nt.S.nt_via_bindings
  ) all_nats in
  let extended_idx =
    fun_decl_index
    @ List.map (fun (fd : S.fun_decl) -> (fd.S.fn_name, fd)) wrapper_decls
    @ List.map (fun (fd : S.fun_decl) -> (fd.S.fn_name, fd)) nat_wrapper_decls
  in
    (all_morphs, all_nats, extended_idx)

let carrier_of_param (fd : S.fun_decl option) =
  match fd with
  | Some { S.fn_params = p :: _; _ } ->
      (match p.S.param_ty with
       | S.TyPrim "number" -> Some Naturality_smtcheck.F64
       | S.TyUser "Int64" | S.TyPrim "i64" -> Some Naturality_smtcheck.I64
       | _ -> None)
  | _ -> None

let z3_available () =
  Sys.command "command -v z3 >/dev/null 2>&1" = 0

let decide idx eta_name f_n_name g_n_name : verdict =
  match Naturality_symcheck.check idx eta_name f_n_name g_n_name "input" with
  | Naturality_symcheck.Proven -> Proven "the two sides normalize to the same term"
  | Naturality_symcheck.Inconclusive why ->
      (match carrier_of_param (List.assoc_opt f_n_name idx) with
       | None -> Unknown (why ^ "; the solver models Number and Int64 values only")
       | Some carrier ->
           if not (z3_available ()) then Unknown (why ^ "; z3 is not installed")
           else
             (match Naturality_symcheck.build_normalized_lhs_rhs
                      idx eta_name f_n_name g_n_name "input" with
              | exception Naturality_symcheck.Not_substitutable form ->
                  Unknown ("the square contains " ^ form ^ ", outside the modelled fragment")
              | (lhs, rhs) ->
                  (match Naturality_smtcheck.check ~carrier lhs rhs with
                   | Naturality_smtcheck.Smt_proven -> Proven "z3 finds no input where the sides differ"
                   | Naturality_smtcheck.Smt_disproven model -> Refuted model
                   | Naturality_smtcheck.Smt_unknown r | Naturality_smtcheck.Smt_unsupported r ->
                       Unknown r)))

(* The squares of every natural transformation of the program, decided. *)
let squares (p : S.program) : square list =
  let (all_morphs, all_nats, idx) = square_index p in
  List.concat_map (fun (nt : S.nat_transform_decl) ->
    let find n = List.find_opt (fun (mp : S.morph_decl) -> mp.S.mp_name = n) all_morphs in
    match find nt.S.nt_source_morph, find nt.S.nt_target_morph with
    | Some src, Some tgt ->
        let tgt_morphisms = List.map fst tgt.S.mp_on_morphism_map in
        let common = List.filter (fun n -> List.mem n tgt_morphisms)
                       (List.map fst src.S.mp_on_morphism_map) in
        List.concat_map (fun (obj, _) ->
          List.map (fun n ->
            { sq_nat = nt; sq_morphism = n; sq_object = obj;
              sq_verdict = decide idx (nt.S.nt_name ^ "__" ^ obj)
                             (src.S.mp_name ^ "__" ^ n) (tgt.S.mp_name ^ "__" ^ n) })
            common) nt.S.nt_via_bindings
    | _ -> []) all_nats

(* The squares last decided, for the driver to report the proven ones. *)
let last : square list ref = ref []

let check (p : S.program) : square list =
  let r = squares p in
  last := r;
  r
