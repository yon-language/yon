(* test_type_frontier.ml — the I6 invariant of the Fase 1 carrier path.
 *
 * type_root (a type's structural identity) and of_core_ty (a type's runtime
 * layout) are two partial functors over the same types. This oracle pins how
 * their partiality frontiers relate, the sharpened I6:
 *
 *   (1) root => carrier. A type with a content-addressed root always has a
 *       runtime carrier. No phantom identity: the Step-2 wiring can never mint
 *       an `ind_<root>` place that the emit is then unable to lower.
 *
 *   (2) The carrier's NoCarrier frontier is exactly the universe, and there the
 *       root is likewise None. That single type (TyUniverse -> Ast.TyType) is
 *       the only one both functors decline: the shared frontier point.
 *
 *   (3) The duality (a feature, not a gap). Everywhere else the root is None (a
 *       type variable, a handle, a dependent Pi/Sigma) the carrier is still
 *       defined (a uniform or opaque layout). The layout forgets identity (every
 *       instance is one f64 slot); the root remembers it. The reverse implication
 *       (carrier => root) fails on exactly this set, by design.
 *
 * The roadmap wrote the frontier as an iff. It is not: at the carrier-value
 * level `number` and a type variable are the same Scalar f64, so a carrier
 * cannot witness identity. The honest theorem is (1)+(2)+(3), and that is what
 * this test pins, so the two frontiers cannot silently drift apart. *)

open Surface_ast
module TR = Type_root
module TE = Tyenv

let num = TyPrim "number"
let v n args = { v_name = n; v_args = args }

(* one named inductive, so the real Step-2 path (root -> ind_ place) is exercised *)
let env = TE.add_named_sum TE.empty "List" [v "Nil" []; v "Cons" [num; TyUser "List"]]

(* does the runtime carrier exist? of_core_ty declines only universes/codes *)
let carrier_defined_core (c : Ast.ty) : bool =
  try ignore (Carrier.of_core_ty c); true with Carrier.NoCarrier _ -> false
let carrier_defined (t : ty) : bool = carrier_defined_core (Desugar.desugar_ty t)
let has_root (t : ty) : bool = TR.type_root env t <> None

let fails = ref 0
let check desc cond =
  if cond then Printf.printf "  ok   %s\n" desc
  else (incr fails; Printf.printf "  FAIL %s\n" desc)

(* a spanning set that straddles both sides of both frontiers *)
let anon = TySum [v "A" [num]; v "B" []]
let cases = [
  "number",           num;
  "List number",      TyList num;
  "number -> number", TyArrow (num, num);
  "TySum [A|B]",       anon;
  "TyUniverse 0",      TyUniverse 0;                 (* the shared frontier point *)
  "TyVar a",           TyVar "a";                    (* duality: carrier, no root *)
  "TyMetaVar 3",       TyMetaVar 3;                  (* duality *)
  "TyPi x.num.num",    TyPi ("x", num, num);         (* duality: dependent -> Arrow *)
  "TySigma x.num.num", TySigma ("x", num, num);      (* duality: dependent -> Struct *)
]

let () =
  Printf.printf "=== type frontier (I6: root => carrier) ===\n";

  (* (1) root => carrier, over the whole spanning set. No exceptions allowed. *)
  List.iter (fun (lbl, t) ->
    let r = has_root t and c = carrier_defined t in
    check (Printf.sprintf "root=>carrier: %-18s (root=%b carrier=%b)" lbl r c)
      ((not r) || c)) cases;

  (* (2) the universe is the unique shared-undefined point *)
  check "universe: no carrier" (not (carrier_defined (TyUniverse 0)));
  check "universe: no root"    (not (has_root (TyUniverse 0)));
  let carrierless = List.filter (fun (_, t) -> not (carrier_defined t)) cases in
  check "universe is the only carrier-less type in the set"
    (List.map fst carrierless = ["TyUniverse 0"]);

  (* (3) the duality: off the universe, root None yet carrier defined *)
  List.iter (fun (lbl, t) ->
    check (Printf.sprintf "duality: %-16s carries but has no identity" lbl)
      ((not (has_root t)) && carrier_defined t))
    [ "TyVar a", TyVar "a"; "TyMetaVar 3", TyMetaVar 3;
      "TyPi", TyPi ("x", num, num); "TySigma", TySigma ("x", num, num) ];

  (* the Step-2 wiring itself: a named inductive's root yields the ind_ place,
     and that place carries (a Section). root => carrier, on the real path. *)
  (match TR.type_root env (TyUser "List") with
   | Some r ->
       check "inductive: ind_<root> has a carrier (Section)"
         (carrier_defined_core (Ast.TyPlace (Printf.sprintf "ind_%016Lx" r)))
   | None -> incr fails; Printf.printf "  FAIL List without a root\n");

  if !fails = 0 then (Printf.printf "PASS type frontier: I6 holds\n"; exit 0)
  else (Printf.printf "FAIL type frontier: %d failed\n" !fails; exit 1)
