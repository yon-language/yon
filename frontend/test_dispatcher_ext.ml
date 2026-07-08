(* test_dispatcher_ext.ml — ORACLE (extension): adversarial coverage of the
 * federation equality/subtype dispatcher, disjoint from test_dispatcher.ml.
 *
 * test_dispatcher.ml already pins: primitives, TyHeytInt<N> equality,
 * text/String fusion, and the four subtype-promotion answers. This file ADDS,
 * with a bias toward NEGATIVE / endpoint-sensitive cases that would catch a
 * regression:
 *
 *   - TyId endpoint-sensitivity (dispatcher.ml:351) — two Id types that differ
 *     ONLY in an endpoint are NOT equal (the coherence-check soundness fix:
 *     `a = a` is not `a = b`).
 *   - TyPathP endpoint-sensitivity + carrier compared UP TO the bound interval
 *     name (dispatcher.ml:359-374).
 *   - TyPi codomain compared UP TO the bound variable (dispatcher.ml:375-379).
 *   - TyArrow / TyMoveHandle / TyReductionHandle structural + wildcard arms.
 *   - El(code) equality (dispatcher.ml:346) — string/structural, NOT delta.
 *   - subtype: the transitive number<:proposition arm, one-way direction,
 *     reflexive fall-through to type_equal.
 *   - Place fallback arm (dispatcher.ml:398-403) via transport pairs.
 *   - Behavioral known-answers: boolean/proposition canon, "unknown" wildcard,
 *     TyUser~TyPrim name fusion.
 *
 * Grounded on:
 *   dispatcher.ml:301 type_equal : env -> ctx -> ty -> ty -> bool
 *   dispatcher.ml:418 subtype   : env -> ctx -> sub:ty -> super:ty -> bool
 *   catt_r_yon.ml:436 ty_structural_eq (canon boolean/proposition; unknown)
 *   catt_r_yon.ml:1320 el_equal (El code decoded via ty_term_to_name)
 *   tyenv.ml:187 with_transport_pair, tyenv.ml:190 place_transportable
 *)

open Surface_ast

let pass = ref 0
let fails = ref 0
let check name cond =
  if cond then (incr pass; Printf.printf "  [PASS] %s\n" name)
  else (incr fails; Printf.printf "  [FAIL] %s\n" name)

let env = Tyenv.with_builtins Tyenv.empty
let ctx = Reduce.empty_ctx
let eq t1 t2 = Dispatcher.type_equal env ctx t1 t2
let sub_ ~sub:s ~super:p = Dispatcher.subtype env ctx ~sub:s ~super:p

let dl = dummy_loc
let v s = EVar (s, dl)
let tm e = TyTermExpr e
let num = TyPrim "number"
let txt = TyPrim "text"
let prop = TyPrim "proposition"

let () =
  Printf.printf "=== Dispatcher equality / subtype oracle (ext) ===\n\n";

  (* ── TyId endpoint-sensitivity ──────────────────────────────────────── *)
  Printf.printf "-- TyId endpoints --\n";
  check "Id_num(a,b) == Id_num(a,b)  (identical -> equal)"
    (eq (TyId (num, tm (v "a"), tm (v "b")))
        (TyId (num, tm (v "a"), tm (v "b"))));
  check "Id_num(a,b) /= Id_num(a,c)  (right endpoint differs)"
    (not (eq (TyId (num, tm (v "a"), tm (v "b")))
             (TyId (num, tm (v "a"), tm (v "c")))));
  check "Id_num(a,b) /= Id_num(x,b)  (left endpoint differs)"
    (not (eq (TyId (num, tm (v "a"), tm (v "b")))
             (TyId (num, tm (v "x"), tm (v "b")))));
  (* THE coherence-check soundness case: refl-shaped a=a is not a=b. *)
  check "Id_num(a,a) /= Id_num(a,b)  (refl type is not an arbitrary path)"
    (not (eq (TyId (num, tm (v "a"), tm (v "a")))
             (TyId (num, tm (v "a"), tm (v "b")))));
  check "Id_num(a,b) /= Id_text(a,b) (carrier differs)"
    (not (eq (TyId (num, tm (v "a"), tm (v "b")))
             (TyId (txt, tm (v "a"), tm (v "b")))));
  (* symmetry holds on a mismatching pair (both directions false) *)
  check "TyId symmetry: eq(t1,t2) = eq(t2,t1) on a differing pair"
    ((eq (TyId (num, tm (v "a"), tm (v "b"))) (TyId (num, tm (v "a"), tm (v "c"))))
     = (eq (TyId (num, tm (v "a"), tm (v "c"))) (TyId (num, tm (v "a"), tm (v "b")))));

  (* ── TyPathP endpoint-sensitivity + interval-var alpha ──────────────── *)
  Printf.printf "-- TyPathP endpoints + interval alpha --\n";
  check "PathP<i>num x y == itself (identical)"
    (eq (TyPathP (("i", num), tm (v "x"), tm (v "y")))
        (TyPathP (("i", num), tm (v "x"), tm (v "y"))));
  check "PathP<i>num x y /= PathP<i>num x z (endpoint differs)"
    (not (eq (TyPathP (("i", num), tm (v "x"), tm (v "y")))
             (TyPathP (("i", num), tm (v "x"), tm (v "z")))));
  (* carrier mentions the interval var -> compared UP TO the bound name. *)
  let carrier_i i = TyId (num, tm (v i), tm (v "z")) in
  check "PathP<i>(Id(i,z)) x y == PathP<j>(Id(j,z)) x y (alpha on bound i)"
    (eq (TyPathP (("i", carrier_i "i"), tm (v "x"), tm (v "y")))
        (TyPathP (("j", carrier_i "j"), tm (v "x"), tm (v "y"))));
  check "PathP<i>(Id(i,z)) x y /= PathP<j>(Id(w,z)) x y (w is a genuine free var)"
    (not (eq (TyPathP (("i", carrier_i "i"), tm (v "x"), tm (v "y")))
             (TyPathP (("j", TyId (num, tm (v "w"), tm (v "z"))),
                       tm (v "x"), tm (v "y")))));
  check "PathP<i>num x y == PathP<j>num x y (bound name irrelevant when carrier is closed)"
    (eq (TyPathP (("i", num), tm (v "x"), tm (v "y")))
        (TyPathP (("j", num), tm (v "x"), tm (v "y"))));

  (* ── El(code) equality — string/structural, NOT delta ───────────────── *)
  Printf.printf "-- El(code) equality --\n";
  check "El(A) == El(A)"
    (eq (TyEl (tm (v "A"))) (TyEl (tm (v "A"))));
  check "El(A) /= El(B)"
    (not (eq (TyEl (tm (v "A"))) (TyEl (tm (v "B")))));
  check "El(id(x)) == El(id(x)) (same applied code)"
    (eq (TyEl (tm (ECall ("id", [v "x"], dl))))
        (TyEl (tm (ECall ("id", [v "x"], dl)))));
  (* El does NOT fold id(x) to x: equality is on the rendered code, no delta. *)
  check "El(id(x)) /= El(x)  (El is code-structural, not up-to-delta)"
    (not (eq (TyEl (tm (ECall ("id", [v "x"], dl)))) (TyEl (tm (v "x")))));

  (* ── subtype: promotions, direction, reflexivity ───────────────────── *)
  Printf.printf "-- subtype --\n";
  check "number <: proposition (transitive promotion arm)"
    (sub_ ~sub:num ~super:prop);
  check "proposition </: number (unsound reverse rejected)"
    (not (sub_ ~sub:prop ~super:num));
  check "number <: heyt_int<16> (promotion for any N)"
    (sub_ ~sub:num ~super:(TyHeytInt 16));
  check "heyt_int<8> <: heyt_int<8> (reflexive via type_equal)"
    (sub_ ~sub:(TyHeytInt 8) ~super:(TyHeytInt 8));
  check "heyt_int<8> </: heyt_int<16> (distinct N, no promotion)"
    (not (sub_ ~sub:(TyHeytInt 8) ~super:(TyHeytInt 16)));
  check "text <: text (reflexive fall-through to type_equal)"
    (sub_ ~sub:txt ~super:txt);
  check "proposition </: heyt_int<8> (no reverse promotion)"
    (not (sub_ ~sub:prop ~super:(TyHeytInt 8)));

  (* ── TyArrow / handle structural arms ───────────────────────────────── *)
  Printf.printf "-- arrow / handles --\n";
  check "num->text == num->text (structural)"
    (eq (TyArrow (num, txt)) (TyArrow (num, txt)));
  check "num->text /= num->num (codomain differs)"
    (not (eq (TyArrow (num, txt)) (TyArrow (num, num))));
  check "num->text /= text->text (domain differs)"
    (not (eq (TyArrow (num, txt)) (TyArrow (txt, txt))));
  check "TyArrow symmetry on differing pair"
    ((eq (TyArrow (num, txt)) (TyArrow (num, num)))
     = (eq (TyArrow (num, num)) (TyArrow (num, txt))));
  check "move(A,B) == move(_,B) (None is a world wildcard)"
    (eq (TyMoveHandle (Some "A", Some "B")) (TyMoveHandle (None, Some "B")));
  check "move(A,B) /= move(X,B) (concrete worlds differ)"
    (not (eq (TyMoveHandle (Some "A", Some "B")) (TyMoveHandle (Some "X", Some "B"))));
  check "reduction(P) == reduction(_) (None wildcard)"
    (eq (TyReductionHandle (Some "P")) (TyReductionHandle None));
  check "reduction(P) /= reduction(Q)"
    (not (eq (TyReductionHandle (Some "P")) (TyReductionHandle (Some "Q"))));

  (* ── TyPi codomain up-to-bound-variable ─────────────────────────────── *)
  Printf.printf "-- TyPi bound-variable alpha --\n";
  let pi_cod x = TyId (num, tm (v x), tm (v "z")) in
  check "Pi(x:num).Id(x,z) == Pi(y:num).Id(y,z) (alpha on bound var)"
    (eq (TyPi ("x", num, pi_cod "x")) (TyPi ("y", num, pi_cod "y")));
  check "Pi(x:num).Id(x,z) /= Pi(y:num).Id(w,z) (w free, not the binder)"
    (not (eq (TyPi ("x", num, pi_cod "x"))
             (TyPi ("y", num, TyId (num, tm (v "w"), tm (v "z"))))));
  check "Pi(x:num).num /= Pi(x:text).num (domain differs)"
    (not (eq (TyPi ("x", num, num)) (TyPi ("x", txt, num))));

  (* ── behavioral known-answers (pin real ty_structural_eq behavior) ──── *)
  Printf.printf "-- behavioral known-answers --\n";
  check "boolean == proposition (canonicalized to one sort)"
    (eq (TyPrim "boolean") prop);
  check "unknown == number (\"unknown\" is a polymorphic wildcard)"
    (eq (TyPrim "unknown") num);
  check "TyUser \"number\" == TyPrim number (name fusion)"
    (eq (TyUser "number") num);
  check "TyUser \"Foo\" /= TyUser \"Bar\" (distinct nominal places)"
    (not (eq (TyUser "Foo") (TyUser "Bar")));

  (* ── place fallback arm via transport pairs ─────────────────────────── *)
  Printf.printf "-- place fallback (transport pairs) --\n";
  check "P /= Q with no inclusion/transport registered"
    (not (eq (TyUser "P") (TyUser "Q")));
  let env2 = Tyenv.with_transport_pair env "P" "Q" in
  check "P == Q once a transport pair (P,Q) is registered (fallback arm)"
    (Dispatcher.type_equal env2 ctx (TyUser "P") (TyUser "Q"));
  check "transport is symmetric: Q == P too"
    (Dispatcher.type_equal env2 ctx (TyUser "Q") (TyUser "P"));

  Printf.printf "\n%d passed, %d failed\n" !pass !fails;
  if !fails = 0 then exit 0 else exit 1
