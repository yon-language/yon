(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* hit_env.ml — environment of Higher Inductive Type signatures.
 *
 * HITs are inductive types with two kinds of constructors:
 *
 *   - Point constructors: ordinary constructors producing elements.
 *     Example: in S¹, the point `base : S¹`.
 *
 *   - Path constructors: producing equalities between elements.
 *     Example: in S¹, the path `loop : base = base`.
 *
 * The type checker needs to know, for each HIT, what its constructors
 * are so that:
 *
 *   1. Calls to a constructor are well-typed (correct arity, parameter
 *      types match).
 *
 *   2. Pattern matches against a HIT are exhaustive (all point and
 *      path constructors covered).
 *
 *   3. Composition operations at a HIT can dispatch on its
 *      constructors (cubical.ml's reduce_comp).
 *
 * We expose:
 *
 *   - The hit_signature type (extending what's in cubical.ml).
 *   - The registry: the places of the prelude and of the program whose laws are cells
 *     (prelude/hit/), and Pushout and Quotient, which wait for term parameters on places.
 *   - Lookup and registration functions.
 *)

open Surface_ast

(* ─── HIT signature representation ─────────────────────────────────── *)

(* A point constructor: a name + the types of its arguments. *)
type point_constructor = {
  pc_name : string;
  pc_params : (string * ty) list;        (* named parameters with types *)
  pc_result : ty;                         (* the HIT type being constructed *)
}

(* A path constructor: a name + parameters + endpoints (left and right).
 * Endpoints are expressions over the parameters, evaluated to terms
 * of the HIT type. *)
type path_constructor = {
  hpc_name : string;
  hpc_params : (string * ty) list;
  hpc_left : expr;                        (* left endpoint *)
  hpc_right : expr;                       (* right endpoint *)
}

(* The full HIT signature. *)
type hit_signature = {
  hit_name : string;
  hit_type_params : string list;          (* type parameters, e.g. A in Suspension A *)
  hit_points : point_constructor list;
  hit_paths : path_constructor list;
}

(* ─── HIT environment ──────────────────────────────────────────────── *)

(* A registry of HIT signatures, keyed by name. *)
type hit_env = (string * hit_signature) list

let empty_env : hit_env = []

let register (env : hit_env) (sig_ : hit_signature) : hit_env =
  (sig_.hit_name, sig_) :: env

let lookup (env : hit_env) (name : string) : hit_signature option =
  List.assoc_opt name env

(* ─── Built-in HITs ────────────────────────────────────────────────── *)

(* Pushout: the standard pushout HIT. *)
let pushout_signature : hit_signature = {
  hit_name = "Pushout";
  hit_type_params = ["A"; "B"; "C"];     (* C ←f A ->g B *)
  hit_points = [
    { pc_name = "inl";
      pc_params = [("c", TyUser "C")];
      pc_result = TyUser "Pushout"; };
    { pc_name = "inr";
      pc_params = [("b", TyUser "B")];
      pc_result = TyUser "Pushout"; };
  ];
  hit_paths = [
    { hpc_name = "glue";
      hpc_params = [("a", TyUser "A")];
      hpc_left = ECall ("inl", [ECall ("f", [EVar ("a", dummy_loc)], dummy_loc)], dummy_loc);
      hpc_right = ECall ("inr", [ECall ("g", [EVar ("a", dummy_loc)], dummy_loc)], dummy_loc); };
  ];
}

(* Quotient A R: the quotient of A by an equivalence relation R.
 *   point constructor: inj : A -> A/R
 *   path constructor: quot : forall(a, b: A). R a b -> inj(a) = inj(b)
 *)
let quotient_signature : hit_signature = {
  hit_name = "Quotient";
  hit_type_params = ["A"; "R"];
  hit_points = [
    { pc_name = "inj";
      pc_params = [("a", TyUser "A")];
      pc_result = TyUser "Quotient"; };
  ];
  hit_paths = [
    { hpc_name = "quot";
      hpc_params = [("a", TyUser "A"); ("b", TyUser "A");
                    ("r", TyUser "R")];
      hpc_left = ECall ("inj", [EVar ("a", dummy_loc)], dummy_loc);
      hpc_right = ECall ("inj", [EVar ("b", dummy_loc)], dummy_loc); };
  ];
}

(* ─── Built-in environment ─────────────────────────────────────────── *)

let builtin_env : hit_env = [
  ("Pushout", pushout_signature);
  ("Quotient", quotient_signature);
]

(* ─── Constructor lookup ──────────────────────────────────────────── *)

(* Find a constructor by name across all registered HITs. Returns
 * the HIT it belongs to plus the constructor type (point or path). *)

type constructor_kind =
  | KPoint of point_constructor
  | KPath of path_constructor

(* The HITs the kernel knows: the built-in ones, and the places whose laws are cells. *)
let registry : hit_env ref = ref builtin_env

(* A statement read as a cell: its premise, if any, and its two ends. *)
let cell_ends (body : expr) : (expr option * expr * expr) option =
  let rec strip = function EParen (e, _) -> strip e | e -> e in
  let ends e = match strip e with
    | EBinop (OpEq, l, r, _) -> Some (l, r)
    | _ -> None in
  match strip body with
  | ECall ("__heyt_imp", [p; c], _) ->
      Option.map (fun (l, r) -> (Some p, l, r)) (ends c)
  | e -> Option.map (fun (l, r) -> (None, l, r)) (ends e)

(* Inside its place, the name of a nullary arm is that arm, whichever other coproduct lists it. *)
let qualify_arms ?(house_fun = fun (_ : string) -> false)
    (pd : place_decl) (bound : string list) (e : expr) : expr =
  let nullary = List.filter_map (fun (v : variant) ->
      if v.v_args = [] && not (List.mem v.v_name bound) then Some v.v_name else None) pd.pd_arms in
  let rec q (e : expr) : expr =
    match e with
    | EVar (x, l) when List.mem x nullary -> EField (EVar (pd.pd_name, l), x, l)
    | EParen (a, l) -> EParen (q a, l)
    | ERefl (a, l) -> ERefl (q a, l)
    | EBinop (o, a, b, l) -> EBinop (o, q a, q b, l)
    | ECall (n, a, l) when not (List.mem n bound) && house_fun n ->
        let qualified = pd.pd_name ^ "__" ^ n in
        (match Hashtbl.find_opt arrow_sites (l.file, l.start_line, l.start_col, n) with
         | Some k -> Hashtbl.replace arrow_sites (l.file, l.start_line, l.start_col, qualified) k
         | None -> ());
        ECall (qualified, List.map q a, l)
    | ECall (n, a, l) -> ECall (n, List.map q a, l)
    | e -> e in
  q e

(* A place with arms and laws is a computad: the arms are its 0-cells, a law a cell. *)
let signature_of_place ?house_fun (pd : place_decl) : hit_signature option =
  let cells = List.filter_map (function
      | FoLaw (name, Some st) when not st.ls_given ->
          (match cell_ends st.ls_body with
           | Some (premise, left, right) ->
               let own = qualify_arms ?house_fun pd (List.map (fun (_, x, _) -> x) st.ls_quants) in
               let left = own left and right = own right in
               let premise = Option.map own premise in
               let quantified = List.map (fun (_, x, t) -> (x, t)) st.ls_quants in
               let witness = match premise with
                 | Some p ->
                     (match cell_ends p with
                      | Some (_, a, b) ->
                          [("__premise", TyId (TyMetaVar (-424242), TyTermExpr a, TyTermExpr b))]
                      | None -> [("__premise", TyPrim "proposition")])
                 | None -> [] in
               Some { hpc_name = name; hpc_params = quantified @ witness;
                      hpc_left = left; hpc_right = right }
           | None -> None)
      | _ -> None) pd.pd_members in
  if pd.pd_arms = [] || cells = [] then None
  else Some {
    hit_name = pd.pd_name;
    hit_type_params = pd.pd_type_params;
    hit_points = List.map (fun (v : variant) ->
        { pc_name = v.v_name;
          pc_params = List.mapi (fun i t -> (Printf.sprintf "arg%d" i, t)) v.v_args;
          pc_result = TyUser pd.pd_name }) pd.pd_arms;
    hit_paths = cells }

let register_places (p : program) : unit =
  registry := List.fold_left (fun env d ->
      match d with
      | TopPlace pd ->
          let house_fun n =
            List.exists (function
                | TopFun fd -> fd.fn_home = Some pd.pd_name
                               && (fd.fn_name = n || fd.fn_name = pd.pd_name ^ "__" ^ n)
                | _ -> false) p in
          (match signature_of_place ~house_fun pd with
           | Some sig_ -> (pd.pd_name, sig_) :: List.remove_assoc pd.pd_name env
           | None -> env)
      | _ -> env) builtin_env p

(* A cell of a place, by name. *)
let cell_of_place (name : string) : (hit_signature * path_constructor) option =
  List.find_map (fun (_, sig_) ->
      if List.mem_assoc sig_.hit_name builtin_env then None
      else Option.map (fun c -> (sig_, c))
          (List.find_opt (fun c -> c.hpc_name = name) sig_.hit_paths)) !registry

let find_constructor (env : hit_env) (cname : string)
    : (hit_signature * constructor_kind) option =
  let rec search = function
    | [] -> None
    | (_, sig_) :: rest ->
        match List.find_opt (fun pc -> pc.pc_name = cname) sig_.hit_points with
        | Some pc -> Some (sig_, KPoint pc)
        | None ->
            match List.find_opt (fun hpc -> hpc.hpc_name = cname) sig_.hit_paths with
            | Some hpc -> Some (sig_, KPath hpc)
            | None -> search rest
  in
  search env

(* Get the parameter types for a constructor (point or path). *)
let constructor_params (k : constructor_kind) : (string * ty) list =
  match k with
  | KPoint pc -> pc.pc_params
  | KPath hpc -> hpc.hpc_params

(* Get the result type for a constructor. For point constructors, the
 * result is the HIT itself. For path constructors, it's a Path type. *)
let constructor_result (k : constructor_kind) : ty =
  match k with
  | KPoint pc -> pc.pc_result
  | KPath _ -> TyUser "Path"

(* ─── Coverage check ───────────────────────────────────────────────── *)

(* Given a HIT and a set of handled constructor names, return the
 * list of missing constructors. Used by pattern-match exhaustiveness
 * checking. *)
let missing_constructors (sig_ : hit_signature) (handled : string list)
    : string list =
  let all_points = List.map (fun pc -> pc.pc_name) sig_.hit_points in
  let all_paths = List.map (fun hpc -> hpc.hpc_name) sig_.hit_paths in
  let all = all_points @ all_paths in
  List.filter (fun n -> not (List.mem n handled)) all
