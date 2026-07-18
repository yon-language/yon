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
 *   - A built-in registry of stdlib HITs: S¹, S², Suspension, Pushout,
 *     PropTrunc, SetTrunc.
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

(* S¹: the circle, with one point and one loop.
 *
 *   data S¹ where
 *     base : S¹
 *     loop : base = base
 *)
let s1_signature : hit_signature = {
  hit_name = "S1";
  hit_type_params = [];
  hit_points = [
    { pc_name = "base";
      pc_params = [];
      pc_result = TyUser "S1"; };
  ];
  hit_paths = [
    { hpc_name = "loop";
      hpc_params = [];
      hpc_left = EVar ("base", dummy_loc);
      hpc_right = EVar ("base", dummy_loc); };
  ];
}

(* S²: the 2-sphere, with one point and one 2-path.
 *
 *   data S² where
 *     base : S²
 *     surf : Square (refl base) (refl base) (refl base) (refl base)
 *
 * For the prototype, we model surf as a single path; a full
 * implementation would use a square (2-dimensional path constructor).
 *)
let s2_signature : hit_signature = {
  hit_name = "S2";
  hit_type_params = [];
  hit_points = [
    { pc_name = "base";
      pc_params = [];
      pc_result = TyUser "S2"; };
  ];
  hit_paths = [
    { hpc_name = "surf";
      hpc_params = [];
      hpc_left = EVar ("base", dummy_loc);
      hpc_right = EVar ("base", dummy_loc); };
  ];
}

(* Suspension A: two points (north, south) and a path for every a in A
 * connecting them.
 *
 *   data Suspension (A : Type) where
 *     north : Suspension A
 *     south : Suspension A
 *     merid : A -> north = south
 *)
let suspension_signature : hit_signature = {
  hit_name = "Suspension";
  hit_type_params = ["A"];
  hit_points = [
    { pc_name = "north";
      pc_params = [];
      pc_result = TyUser "Suspension"; };
    { pc_name = "south";
      pc_params = [];
      pc_result = TyUser "Suspension"; };
  ];
  hit_paths = [
    { hpc_name = "merid";
      hpc_params = [("a", TyUser "A")];
      hpc_left = EVar ("north", dummy_loc);
      hpc_right = EVar ("south", dummy_loc); };
  ];
}

(* PropTrunc A: the propositional truncation, with inclusion and a
 * path-constructor identifying any two elements.
 *
 *   data || A || where
 *     incl : A -> || A ||
 *     squash : (x y : || A ||) -> x = y
 *)
let prop_trunc_signature : hit_signature = {
  hit_name = "PropTrunc";
  hit_type_params = ["A"];
  hit_points = [
    { pc_name = "incl";
      pc_params = [("a", TyUser "A")];
      pc_result = TyUser "PropTrunc"; };
  ];
  hit_paths = [
    { hpc_name = "squash";
      hpc_params = [("x", TyUser "PropTrunc"); ("y", TyUser "PropTrunc")];
      hpc_left = EVar ("x", dummy_loc);
      hpc_right = EVar ("y", dummy_loc); };
  ];
}

(* SetTrunc A: the set truncation, with inclusion and a 2-path
 * identifying any two parallel paths.
 *)
let set_trunc_signature : hit_signature = {
  hit_name = "SetTrunc";
  hit_type_params = ["A"];
  hit_points = [
    { pc_name = "incl";
      pc_params = [("a", TyUser "A")];
      pc_result = TyUser "SetTrunc"; };
  ];
  hit_paths = [
    { hpc_name = "set_id";
      hpc_params = [("x", TyUser "SetTrunc"); ("y", TyUser "SetTrunc");
                    ("p", TyUser "Path"); ("q", TyUser "Path")];
      hpc_left = EVar ("p", dummy_loc);
      hpc_right = EVar ("q", dummy_loc); };
  ];
}

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
  ("S1", s1_signature);
  ("S2", s2_signature);
  ("Suspension", suspension_signature);
  ("PropTrunc", prop_trunc_signature);
  ("SetTrunc", set_trunc_signature);
  ("Pushout", pushout_signature);
  ("Quotient", quotient_signature);
]

(* ─── Constructor lookup ──────────────────────────────────────────── *)

(* Find a constructor by name across all registered HITs. Returns
 * the HIT it belongs to plus the constructor type (point or path). *)

type constructor_kind =
  | KPoint of point_constructor
  | KPath of path_constructor

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
