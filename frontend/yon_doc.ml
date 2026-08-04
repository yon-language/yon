(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* yon_doc.ml — documentation generator for Yon.
 *
 * Produces a Markdown API reference from a source file's AST: every world,
 * place (with its fields and operations), geomorph (with pull/push signatures),
 * and function (signature + declared effects `visits`). Structural only — Yon's
 * lexer discards comments, so there are no doc-comments to extract; like godoc
 * or rustdoc on an undocumented module, the value is the structured surface of
 * the program made browsable.
 *
 * Usage: yon_doc <file.yon>           -> Markdown on stdout
 *        yon_doc <file.yon> -o doc.md -> write to file
 *)

module S = Surface_ast

(* Minimal type printer (kept local to avoid cross-executable deps). *)
(* The doc shows the SURFACE, so a primitive prints as its declared face:
   the prelude place (Number, Text, Boolean, Unit), not the kernel code the
   parser canonicalized it to. Writing the code would show a form the surface
   rejects (E1001). The face is looked up in fusion_of_prim, so a new fused
   place is picked up without touching this table. *)
let rec fmt_ty (t : S.ty) : string =
  match t with
  | S.TyPrim n ->
      (match Hashtbl.find_opt S.fusion_of_prim n with
       | Some face -> face
       | None ->
           (match n with
            | "number" -> "Number" | "text" -> "Text"
            | "boolean" -> "Boolean" | "unit" -> "Unit"
            | _ -> n))
  | S.TyPrimIn (n, opts) -> n ^ " in " ^ String.concat ", " opts
  | S.TyList t -> "list of " ^ fmt_ty t
  | S.TyMap (k, v) -> "map of " ^ fmt_ty k ^ " to " ^ fmt_ty v
  | S.TyUser n -> n
  | S.TyArrow (a, b) -> fmt_ty a ^ " -> " ^ fmt_ty b
  | _ -> "<type>"

let fmt_ret = function Some t -> ": " ^ fmt_ty t | None -> ""

let fmt_params (ps : S.param list) : string =
  String.concat ", "
    (List.map (fun (p : S.param) -> p.S.param_name ^ ": " ^ fmt_ty p.S.param_ty) ps)

let buf = Buffer.create 4096
let line s = Buffer.add_string buf s; Buffer.add_char buf '\n'

(* ─── per-declaration documentation ──────────────────────────────────── *)

let doc_world (w : S.world_decl) =
  line (Printf.sprintf "### world `%s`" w.S.wd_name);
  (match w.S.wd_product_of with
   | [] -> () | ps -> line (Printf.sprintf "- product of: %s" (String.concat ", " ps)));
  (match w.S.wd_coproduct_of with
   | [] -> () | ps -> line (Printf.sprintf "- coproduct of: %s" (String.concat ", " ps)));
  (match w.S.wd_subset_of with
   | Some s -> line (Printf.sprintf "- subset of: %s" s) | None -> ());
  line ""

let doc_place (p : S.place_decl) =
  line (Printf.sprintf "### place `%s` in `%s`" p.S.pd_name p.S.pd_world);
  (match p.S.pd_subcontains with
   | Some b -> line (Printf.sprintf "- sub-object of (`this <`): `%s`" b) | None -> ());
  (match p.S.pd_over with
   | Some x -> line (Printf.sprintf "- fibered over: `%s`" x) | None -> ());
  let fields = List.filter_map (function S.FoField f -> Some f | _ -> None) p.S.pd_members in
  let ops = List.filter_map (function S.FoOp o -> Some o | _ -> None) p.S.pd_members in
  if fields <> [] then begin
    line ""; line "Fields:";
    List.iter (fun (f : S.field_decl) ->
      line (Printf.sprintf "- `%s`: %s" f.S.fd_name (fmt_ty f.S.fd_ty))) fields
  end;
  if ops <> [] then begin
    line ""; line "Operations:";
    List.iter (fun (o : S.operation_decl) ->
      line (Printf.sprintf "- `%s(%s)%s`" o.S.op_name
              (fmt_params o.S.op_params) (fmt_ret o.S.op_return))) ops
  end;
  line ""

let doc_geomorph (g : S.geom_morphism_decl) =
  line (Printf.sprintf "### geomorph `%s`: `%s` → `%s`"
          g.S.gm_name g.S.gm_source_site g.S.gm_target_site);
  (* a geometric morphism IS an adjoint pair by definition (Antonio):
     the line is unconditional now *)
  line "- adjunction: pull ⊣ push";
  if g.S.gm_f_star_exact then line "- pull (f*) preserves finite limits";
  if g.S.gm_f_lower_star_exact then line "- push (f_*) preserves finite colimits";
  (match g.S.gm_pull with
   | Some fd -> line (Printf.sprintf "- pull `(%s)%s`" (fmt_params fd.S.fn_params) (fmt_ret fd.S.fn_return))
   | None -> ());
  (match g.S.gm_push with
   | Some fd -> line (Printf.sprintf "- push `(%s)%s`" (fmt_params fd.S.fn_params) (fmt_ret fd.S.fn_return))
   | None -> ());
  line ""

let doc_fun (f : S.fun_decl) =
  let tps = match f.S.fn_type_params with [] -> "" | ps -> "<" ^ String.concat ", " ps ^ ">" in
  let vis = if f.S.fn_internal then " *(internal)*" else "" in
  let visits = match f.S.fn_visits with
    | [] -> "" | vs -> Printf.sprintf "  \n  *visits:* %s" (String.concat ", " vs) in
  line (Printf.sprintf "### `%s%s(%s)%s`%s"
          f.S.fn_name tps (fmt_params f.S.fn_params) (fmt_ret f.S.fn_return) (visits ^ vis));
  line ""

(* ─── driver ─────────────────────────────────────────────────────────── *)

let gen (title : string) (prog : S.program) : string =
  Buffer.clear buf;
  line (Printf.sprintf "# API Reference: %s" title);
  line "";
  let imports = List.filter_map (function
    | S.TopImport (s, _) -> Some (Printf.sprintf "- package `%s`" s)
    | S.TopImportSym (m, n, Some a, _) -> Some (Printf.sprintf "- `%s::%s` as `%s`" m n a)
    | S.TopImportSym (m, n, None, _) -> Some (Printf.sprintf "- `%s::%s`" m n)
    | S.TopImportFrom (m, n, sp, _) ->
        Some (Printf.sprintf "- `%s::%s` from Space `%s` (cross-Space)" m n sp)
    | _ -> None) prog in
  if imports <> [] then begin
    line "## Imports"; line "";
    List.iter line imports; line ""
  end;
  let worlds = List.filter_map (function S.TopWorld w -> Some w | _ -> None) prog in
  let places = List.filter_map (function S.TopPlace p -> Some p | _ -> None) prog in
  let geoms  = List.filter_map (function S.TopGeomMorphism g -> Some g | _ -> None) prog in
  let funs   = List.filter_map (function S.TopFun f -> Some f | _ -> None) prog in
  if worlds <> [] then begin line "## Worlds"; line ""; List.iter doc_world worlds end;
  if places <> [] then begin line "## Places"; line ""; List.iter doc_place places end;
  if geoms  <> [] then begin line "## Geometric morphisms"; line ""; List.iter doc_geomorph geoms end;
  if funs   <> [] then begin line "## Functions"; line ""; List.iter doc_fun funs end;
  Buffer.contents buf

let parse (source : string) : S.program option =
  let lexbuf = Lexing.from_string source in
  try Some (Parser.program Lexer.token lexbuf) with _ -> None

let () =
  let args = Array.to_list Sys.argv in
  let file, out =
    match args with
    | [_; f; "-o"; o] -> (Some f, Some o)
    | [_; f] -> (Some f, None)
    | _ -> (None, None)
  in
  match file with
  | None -> prerr_endline "uso: yon_doc <file.yon> [-o doc.md]"; exit 64
  | Some path ->
      let ic = open_in path in
      let n = in_channel_length ic in
      let src = really_input_string ic n in
      close_in ic;
      (match parse src with
       | None -> Printf.eprintf "%s: parse error\n" path; exit 65
       | Some prog ->
           let title = Filename.remove_extension (Filename.basename path) in
           let md = gen title prog in
           (match out with
            | Some o -> let oc = open_out o in output_string oc md; close_out oc;
                        Printf.printf "%s\n" o
            | None -> print_string md))
