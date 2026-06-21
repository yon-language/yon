(* sct.ml — Size-Change Termination gate for delta-rule certification.
 *
 * Lee, Jones, Ben-Amram, "The Size-Change Principle for Program
 * Termination", POPL 2001.
 *
 * A user function may be unfolded as a delta-rule inside the definitional
 * equality judgment ONLY if its recursion is certified terminating here.
 *   certified     => unfolding reaches a normal form in finitely many
 *                    steps, so no fuel/cap is needed and the judgment stays
 *                    decidable;
 *   not certified => the function is left opaque (never unfolded): the
 *                    judgment may be incomplete but is never unsound and
 *                    never diverges.
 *
 * Well-founded order: SUBTERM only. A constructor application
 * (HITConstr / Pair / StreamCons) is strictly greater than each of its
 * components; the binders of a HITElim branch and the results of Fst/Snd
 * are strict subterms of the scrutinee. This order is genuinely
 * well-founded (constructors bottom out).
 *
 * Numeric "descent" (n-1 < n) is NOT used: `number` is float/signed, so
 * `<` is not well-founded and a numeric edge would make the certificate
 * unsound. Such recursions yield no subterm edge and are simply not
 * certified — conservative, never wrong. No heuristics, no fuel, no magic
 * numbers anywhere in this module: the closure below is computed to a
 * fixpoint, which exists because the set of labelled graphs over a finite
 * parameter set is finite.
 *)

module A = Ast
module SMap = Map.Make (String)

(* Size relation against the well-founded (subterm) order.
 * Strict (↓): strictly smaller.  NonStrict (↓=): smaller-or-equal.
 * Absence of an edge means "no relation guaranteed". *)
type rel = Strict | NonStrict

(* Strict is absorbing: it wins both when composing along a path and when
 * merging two parallel contributions between the same pair of params. *)
let rel_join (a : rel) (b : rel) : rel =
  match a, b with
  | NonStrict, NonStrict -> NonStrict
  | _ -> Strict

(* A function definition as seen by the gate. *)
type fundef = {
  name   : string;
  params : string list;   (* ordered parameter names *)
  body   : A.term;        (* desugared body *)
}

(* A size-change graph for a single call edge src -> dst.
 * An edge (i, j, r) means: argument in position j of the call descends
 * from the caller's parameter i with relation r. *)
type scg = {
  src   : string;
  dst   : string;
  edges : (int * int * rel) list;   (* kept sorted & deduped, see mk_scg *)
}

(* Smart constructor: dedup (i,j) keeping the strongest relation, then sort
 * so structural equality is a canonical equality on graphs. *)
let mk_scg (src : string) (dst : string) (edges : (int * int * rel) list) : scg =
  let tbl = Hashtbl.create 16 in
  List.iter
    (fun (i, j, r) ->
       match Hashtbl.find_opt tbl (i, j) with
       | Some r' -> Hashtbl.replace tbl (i, j) (rel_join r r')
       | None    -> Hashtbl.replace tbl (i, j) r)
    edges;
  let edges =
    Hashtbl.fold (fun (i, j) r acc -> (i, j, r) :: acc) tbl []
    |> List.sort compare
  in
  { src; dst; edges }

(* Composition G ; H : src(G) -> dst(H), defined when dst(G) = src(H). *)
let compose (g : scg) (h : scg) : scg option =
  if g.dst <> h.src then None
  else
    let edges =
      List.concat
        (List.map
           (fun (i, j, r1) ->
              List.fold_left
                (fun acc (j', k, r2) ->
                   if j = j' then (i, k, rel_join r1 r2) :: acc else acc)
                [] h.edges)
           g.edges)
    in
    Some (mk_scg g.src h.dst edges)

(* ─── Descent analysis ─────────────────────────────────────────────────
 * Track, for each in-scope variable, the parameter it descends from and
 * how. A parameter descends from itself, non-strictly. *)

type denv = (string * rel) SMap.t

(* Classify how an argument term descends from a parameter. Only a bare
 * variable, or a projection of something that descends, counts — Fst/Snd
 * extract a strict subterm. Anything computed (arithmetic, a constructor
 * application, an opaque call) descends from nothing. *)
let rec descent_of (de : denv) (t : A.term) : (string * rel) option =
  match t with
  | A.Var x -> SMap.find_opt x de
  | A.Fst t' | A.Snd t' ->
      (match descent_of de t' with
       | Some (p, _) -> Some (p, Strict)   (* a projection is strictly smaller *)
       | None        -> None)
  | _ -> None

(* The application spine: peel curried App, returning head and args L→R. *)
let spine (t : A.term) : A.term * A.term list =
  let rec go t acc =
    match t with
    | A.App (f, a) -> go f (a :: acc)
    | head         -> (head, acc)
  in
  go t []

(* Collect the size-change graphs for every recursive call site in one
 * function body. `known` is the set of user-function names (the call
 * targets that matter). *)
let collect (known : string list) (f : fundef) : scg list =
  let idx = Hashtbl.create 8 in
  List.iteri (fun i p -> Hashtbl.replace idx p i) f.params;
  let pidx name = Hashtbl.find_opt idx name in

  (* Build the SCG for a fully-applied call to a known function. *)
  let call_scg (de : denv) (g : string) (args : A.term list) : scg =
    let edges =
      List.concat
        (List.mapi
           (fun j arg ->
              match descent_of de arg with
              | Some (p, r) -> (match pidx p with Some i -> [ (i, j, r) ] | None -> [])
              | None        -> [])
           args)
    in
    mk_scg f.name g edges
  in

  let rec go (de : denv) (t : A.term) (acc : scg list) : scg list =
    match spine t with
    | A.Var g, (_ :: _ as args) when List.mem g known ->
        (* a recursive/known call: emit one graph, then recurse into args *)
        let acc = call_scg de g args :: acc in
        List.fold_left (fun acc a -> go de a acc) acc args
    | _ ->
        (* not a known-call spine: ordinary structural recursion *)
        (match t with
         | A.Var _ | A.Place _ | A.Reduction _ | A.World _ | A.Unit -> acc
         | A.Lam (v, _, b) -> go (SMap.remove v de) b acc
         | A.App (a, b) -> go de a (go de b acc)
         | A.Scope (_, b) | A.With (_, b) | A.Emit b | A.Refl b
         | A.Unglue b | A.Transp (_, b) -> go de b acc
         | A.PLam (v, b) -> go (SMap.remove v de) b acc
         | A.PApp (p, _) -> go de p acc
         | A.Fst a | A.Snd a -> go de a acc
         | A.Pair (a, b) | A.StreamCons (a, b) | A.GlueElem (_, a, b) ->
             go de a (go de b acc)
         | A.J (v, _, a, b, c, d) ->
             let de' = SMap.remove v de in
             go de' a (go de' b (go de' c (go de' d acc)))
         | A.Comp (_, _, sys, base) | A.HComp (_, _, sys, base) ->
             let acc =
               List.fold_left
                 (fun acc (v, _, tm) -> go (SMap.remove v de) tm acc)
                 acc sys
             in
             go de base acc
         | A.HITConstr (_, ts) ->
             List.fold_left (fun acc x -> go de x acc) acc ts
         | A.HITElim (branches, scrut) ->
             let sdesc = descent_of de scrut in
             let acc = go de scrut acc in
             List.fold_left
               (fun acc (_ctor, vars, bterm) ->
                  (* the leading Lam binders of a branch bind the
                   * constructor's components: strict subterms of the
                   * scrutinee, hence strict descendants of whatever the
                   * scrutinee descends from. *)
                  let de =
                    List.fold_left
                      (fun de v ->
                         match sdesc with
                         | Some (p, _) ->
                             SMap.add v (p, Strict) (SMap.remove v de)
                         | None -> SMap.remove v de)
                      de vars
                  in
                  let rec peel de bt =
                    match bt with
                    | A.Lam (v, _, body) ->
                        let de' =
                          match sdesc with
                          | Some (p, _) -> SMap.add v (p, Strict) (SMap.remove v de)
                          | None        -> SMap.remove v de
                        in
                        peel de' body
                    | other -> (de, other)
                  in
                  let de', inner = peel de bterm in
                  go de' inner acc)
               acc branches)
  in
  let de0 =
    List.fold_left (fun m p -> SMap.add p (p, NonStrict) m) SMap.empty f.params
  in
  go de0 f.body []

(* ─── Closure under composition ────────────────────────────────────────
 * Saturate the set of graphs. Finite: graphs are labelled relations over a
 * finite parameter set, so there are finitely many; the fixpoint is reached
 * without any step bound. *)

module GSet = Set.Make (struct
  type t = scg
  let compare a b = compare (a.src, a.dst, a.edges) (b.src, b.dst, b.edges)
end)

let closure (base : scg list) : scg list =
  let rec fix (cur : GSet.t) : GSet.t =
    let grown =
      GSet.fold
        (fun g acc ->
           GSet.fold
             (fun h acc ->
                match compose g h with Some gh -> GSet.add gh acc | None -> acc)
             cur acc)
        cur cur
    in
    if GSet.cardinal grown = GSet.cardinal cur then cur else fix grown
  in
  GSet.elements (fix (GSet.of_list base))

(* ─── The SCT criterion ─────────────────────────────────────────────────
 * A graph G : f -> f is idempotent when G ; G = G. The program is
 * size-change terminating iff every idempotent graph in the closure has a
 * strict self-loop x ->(↓) x. Per function: f is certified iff every
 * idempotent self-graph on f has a strict self-loop. No recursive cycle
 * through f => no such graph => f is certified vacuously. *)

let is_idempotent (g : scg) : bool =
  g.src = g.dst
  && (match compose g g with
      | Some gg -> gg.edges = g.edges   (* both canonical via mk_scg *)
      | None    -> false)

let has_strict_self_loop (g : scg) : bool =
  List.exists (fun (i, j, r) -> i = j && r = Strict) g.edges

(* Public entry point: the set of certified function names. *)
let certify (fns : fundef list) : string list =
  let known = List.map (fun fd -> fd.name) fns in
  let base = List.concat (List.map (collect known) fns) in
  let clo = closure base in
  List.fold_left
    (fun acc fd ->
       let idems =
         List.filter (fun g -> g.src = fd.name && is_idempotent g) clo
       in
       if List.for_all has_strict_self_loop idems then fd.name :: acc else acc)
    [] fns
  |> List.rev

(* Convenience predicate. *)
let certifies (fns : fundef list) (name : string) : bool =
  List.mem name (certify fns)
