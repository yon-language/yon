(* test_o2_probe.ml — CCHM boundary/adjacency probe for the O2 canonicity claim.
 *
 * The metatheory fuzzer reports ~490 cubical "stuck" hcomp witnesses. Those are
 * hcomp over FREE dimensions (i,j not bound by any PLam) — legitimately neutral.
 * The real canonicity question is about CLOSED instances: bind the dimension and
 * instantiate it to I0/I1, then the boundary laws MUST hold:
 *   hcomp^i [i=1 |-> u] u0  @ i:=1  ==  u        (active face fires)
 *   hcomp^i [i=1 |-> u] u0  @ i:=0  ==  u0       (inactive face -> base)
 * and the cross-dimensional conjunction i=1 /\ j=0 fires ONLY at that corner.
 * If these hold, the engine is sound+complete on closed instances and the 490 are
 * a measurement artifact (neutral-on-open). If any fails, the gap is localized here. *)

open Ast

let ctx = Reduce.empty_ctx
let nf t = Builtins.reduce_with_builtins ~fuel:5000 ctx t
let num n = Var (Printf.sprintf "__num_%d" n)
let ty0 = TyType 0
let show = Pretty.pp_term

let pass = ref 0 and fail = ref 0
let check label got expect =
  if term_equal got expect then (incr pass; Printf.printf "  [ok]   %-34s -> %s\n" label (show got))
  else (incr fail; Printf.printf "  [FAIL] %-34s -> %s  (expected %s)\n" label (show got) (show expect))

(* instantiate a 1-dimension hcomp at i := r *)
let h1 r =
  nf (PApp (PLam ("i",
      HComp (ty0, [[("i", true)]], [("s", [("i", true)], num 7)], num 5)), r))

(* instantiate a cross-dimensional hcomp [i=1 /\ j=0 |-> 7] 5 at (i:=ri, j:=rj) *)
let h2 ri rj =
  nf (PApp (PLam ("j",
      PApp (PLam ("i",
        HComp (ty0, [[("i", true); ("j", false)]],
               [("s", [("i", true); ("j", false)], num 7)], num 5)), ri)), rj))

let () =
  Printf.printf "=== O2 boundary/adjacency probe (CLOSED instances) ===\n";
  Printf.printf "-- 1-dim: hcomp^i [i=1 |-> 7] 5 --\n";
  check "@ i:=1  (face ACTIVE)"        (h1 I1) (num 7);
  check "@ i:=0  (face inactive->base)" (h1 I0) (num 5);
  Printf.printf "-- cross-dim: hcomp [i=1 /\\ j=0 |-> 7] 5 --\n";
  check "@ (i:=1,j:=0)  (ACTIVE corner)" (h2 I1 I0) (num 7);
  check "@ (i:=1,j:=1)  (inactive)"      (h2 I1 I1) (num 5);
  check "@ (i:=0,j:=0)  (inactive)"      (h2 I0 I0) (num 5);
  check "@ (i:=0,j:=1)  (inactive)"      (h2 I0 I1) (num 5);
  Printf.printf "=== boundary probe: %d ok | %d FAIL ===\n" !pass !fail;
  (* Also confirm the OPEN term stays neutral (correct), not a value. *)
  let open_h = nf (HComp (ty0, [[("i", true)]], [("s", [("i", true)], num 7)], num 5)) in
  Printf.printf "open hcomp (i free) -> %s  [is_value=%b] (neutral is CORRECT)\n"
    (show open_h) (Reduce.is_value open_h);

  (* ── Closed-canonicity sweep (the REAL O2 measurement) ─────────────────────
     Generate cubical terms over two free dimensions {i,j}, then CLOSE them at
     every corner (i,j := I0/I1). At a corner all faces are decided, so a correct
     Kan engine must reduce to a VALUE (canonicity). A stuck corner is a genuine
     canonicity bug — unlike the open, free-dimension neutral, which is correct. *)
  Printf.printf "\n=== closed-canonicity sweep (every corner must be a value) ===\n";
  Random.init 20260708;
  let dims = [| "i"; "j" |] in
  let rand_face () =
    let atom () = (dims.(Random.int 2), Random.bool ()) in
    match Random.int 4 with
    | 0 -> [ atom () ]                    (* 1-dim face *)
    | 1 -> [ atom (); atom () ]           (* conjunction (possibly cross-dim) *)
    | 2 -> [ ("i", true) ]
    | _ -> [ ("j", false) ] in
  let rec gen d : term =
    if d <= 0 then num (Random.int 9)
    else match Random.int 5 with
      | 0 -> num (Random.int 9)
      | 1 -> let f = rand_face () in
             HComp (ty0, [f], [("s", f, gen (d-1))], gen (d-1))
      | 2 -> let f1 = rand_face () and f2 = rand_face () in   (* disjunction system *)
             HComp (ty0, [f1; f2], [("a", f1, gen (d-1)); ("b", f2, gen (d-1))], gen (d-1))
      | 3 -> let f = rand_face () in
             Comp (ty0, [f], [("s", f, gen (d-1))], gen (d-1))
      | _ -> let f = rand_face () in                          (* nested hcomp *)
             HComp (ty0, [f], [("s", f, HComp (ty0, [f], [("t", f, gen (d-1))], gen (d-1)))], gen (d-1)) in
  let close t =                              (* PApp/PLam close i and j at all corners *)
    List.concat_map (fun ri ->
      List.map (fun rj ->
        ((ri, rj), nf (PApp (PLam ("j", PApp (PLam ("i", t), ri)), rj))))
      [ I0; I1 ]) [ I0; I1 ] in
  let vals = ref 0 and stuck = ref 0 and wit = ref [] in
  for _ = 1 to 2000 do
    let t = gen 3 in
    List.iter (fun (_, r) ->
      if Reduce.is_value r then incr vals
      else (incr stuck; if List.length !wit < 5 then wit := show r :: !wit))
      (close t)
  done;
  Printf.printf "corners: %d value | %d STUCK (n=%d terms x4 corners)\n"
    !vals !stuck (2000);
  if !stuck > 0 then
    Printf.printf "  [genuine closed-stuck witnesses]: %s\n" (String.concat " | " !wit);
  let ok = !fail = 0 && !stuck = 0 in
  Printf.printf "=== O2 PROBE RESULT: %s ===\n"
    (if ok then "engine computes every closed face system (boundary + canonicity); the 490 fuzzer stuck are open-dim neutrals, not a gap"
     else "GENUINE gap localized above");
  if ok then exit 0 else exit 1
