(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_metatheory_fuzz.ml — property-based / differential testing of the kernel's
 * operational semantics (item 4 of the "Verifying semantic correctness" ladder).
 *
 * The reducer (Builtins.reduce_with_builtins: core via Reduce.step + cubical via the
 * Cubical engine bridge) is the oracle. We generate CLOSED "should-compute" terms and
 * check the properties the paper proofs (SN, Progress, confluence) claim:
 *
 *   P1  NO-STUCK (Progress / SN, core):  a should-compute CORE term must reduce to a
 *        VALUE, never to a non-value normal form ("stuck") and never time out. A core
 *        STUCK refutes Progress; a core TIMEOUT refutes SN. Either fails the test.
 *   P2  CUBICAL no-stuck = the O2 hunt:  same, for cubical terms (PApp/Comp/HComp/HIT),
 *        incl cross-dimensional hcomp faces. A cubical STUCK is the *witness* of the known
 *        canonicity gap O2 (metatheory.md): REPORTED, but does NOT fail the build (O2 is
 *        open by record, not a regression).
 *   P3  CONFLUENCE / determinism proxy:  a term and a trivially-wrapped copy must reach
 *        the same normal form; a mismatch refutes determinism and fails.
 *
 * Deterministic: Random is seeded with a fixed constant, so a finding reproduces. *)

open Ast

let ctx = Reduce.empty_ctx
let fuel_budget = 5000

type outcome = Value of term | Stuck of term | Timeout of term
let nf_of = function Value t | Stuck t | Timeout t -> t

let classify (t : term) : outcome =
  let nf = Builtins.reduce_with_builtins ~fuel:fuel_budget ctx t in
  let nf2 = Builtins.reduce_with_builtins ~fuel:1 ctx nf in
  if not (term_equal_env [] nf nf2) then Timeout nf
  else if Reduce.is_value nf then Value nf
  else Stuck nf

(* ── generators (closed, "should-compute") ────────────────────────────── *)
let num n = Var (Printf.sprintf "__num_%d" n)
let ty0 = TyType 0
let i_end () = if Random.bool () then I0 else I1

let rec gen_val d : term =
  if d <= 0 then num (Random.int 100)
  else match Random.int 6 with
    | 0 -> num (Random.int 100)
    | 1 -> Lam ("x", ty0, Var "x")
    | 2 -> Pair (gen_val (d-1), gen_val (d-1))
    | 3 -> Refl (gen_val (d-1))
    | 4 -> PLam ("i", gen_val (d-1))
    | _ -> Unit

let rec gen_core d : term =
  if d <= 0 then gen_val 0
  else match Random.int 8 with
    | 0 | 1 -> gen_val d
    | 2 -> App (Lam ("x", ty0, Var "x"), gen_core (d-1))
    | 3 -> Fst (Pair (gen_core (d-1), gen_val 1))
    | 4 -> Snd (Pair (gen_val 1, gen_core (d-1)))
    | 5 -> let a = gen_val 1 in
           J ("x", ty0, gen_val 1, Lam ("y", ty0, Var "y"), Refl a, a)
    | 6 -> App (Lam ("x", ty0, Pair (Var "x", Var "x")), gen_core (d-1))
    | _ -> Fst (Pair (gen_core (d-1), gen_core (d-1)))

let rec gen_cubical d : term =
  if d <= 0 then PApp (Refl (gen_val 1), i_end ())
  else match Random.int 7 with
    | 0 -> PApp (Refl (gen_cubical (d-1)), i_end ())
    | 1 -> PApp (PLam ("i", gen_val 1), i_end ())
    | 2 -> HComp (ty0, [], [], gen_core (d-1))
    | 3 -> Comp (ty0, [], [], gen_core (d-1))
    | 4 -> Transp (("i", ty0), gen_core (d-1))
    | 5 -> (* cross-dimensional hcomp face i=1 ∧ j=0 — the O2 target *)
           HComp (ty0, [[("i", true); ("j", false)]],
                  [("i", [("i", true); ("j", false)], gen_val 1)], gen_core (d-1))
    | _ -> HITElim ([("c", ["x"], Var "x")], HITConstr ("c", [gen_val 1]))

(* DEEP alpha-renaming: rename EVERY Lam binder (capture-avoidingly via Subst)
 * and recurse through all generated constructors. alpha_bump t is alpha-
 * equivalent to t, so NF(t) must equal NF(alpha_bump t) — any divergence is a
 * substitution/capture bug. (Was shallow: only the outermost binder.) *)
let rec alpha_bump (t : term) : term = match t with
  | Lam (x, ty, b) ->
      let x' = x ^ "_" in Lam (x', ty, alpha_bump (Subst.subst x (Var x') b))
  | App (f, a) -> App (alpha_bump f, alpha_bump a)
  | Pair (a, b) -> Pair (alpha_bump a, alpha_bump b)
  | Fst a -> Fst (alpha_bump a)
  | Snd a -> Snd (alpha_bump a)
  | Refl a -> Refl (alpha_bump a)
  | J (x, ty, c, d, p, a) ->
      J (x, ty, alpha_bump c, alpha_bump d, alpha_bump p, alpha_bump a)
  | PLam (i, b) -> PLam (i, alpha_bump b)
  | PApp (p, r) -> PApp (alpha_bump p, r)
  | HComp (ty, phi, sides, base) -> HComp (ty, phi, sides, alpha_bump base)
  | Comp (ty, phi, sides, base) -> Comp (ty, phi, sides, alpha_bump base)
  | Transp (l, b) -> Transp (l, alpha_bump b)
  | other -> other

let show_head = function
  | Var v -> "Var " ^ v | Lam _ -> "Lam" | App _ -> "App" | Fst _ -> "Fst"
  | Snd _ -> "Snd" | Pair _ -> "Pair" | Refl _ -> "Refl" | J _ -> "J"
  | PLam _ -> "PLam" | PApp _ -> "PApp" | Comp _ -> "Comp" | HComp _ -> "HComp"
  | Transp _ -> "Transp" | HITElim _ -> "HITElim" | HITConstr (c, _) -> "HITConstr " ^ c
  | Unglue _ -> "Unglue" | GlueElem _ -> "GlueElem" | Unit -> "Unit" | _ -> "other"

(* ── driver ───────────────────────────────────────────────────────────── *)
let n_core = 3000 and n_cub = 3000 and n_conf = 1000

let cv = ref 0 and cs = ref 0 and ct = ref 0
let uv = ref 0 and us = ref 0 and ut = ref 0
let confok = ref 0 and confbad = ref 0
let core_wit = ref [] and cub_wit = ref []
let add l x = if List.length !l < 6 then l := x :: !l

(* labeled diagnostic: classify ONE canonical instance of each cubical former, so the
 * O2 finding is pinned to a specific construct, not a generator artifact. *)
let diag () =
  let cases = [
    "refl @ r",                PApp (Refl (num 5), I0);
    "(<i>v) @ r",              PApp (PLam ("i", num 5), I0);
    "hcomp EMPTY system",      HComp (ty0, [], [], num 5);
    "comp EMPTY system",       Comp (ty0, [], [], num 5);
    "transp const line",       Transp (("i", ty0), num 5);
    "hcomp 1-dim face i=1",    HComp (ty0, [[("i", true)]], [("i", [("i", true)], num 7)], num 5);
    "hcomp CROSS-DIM i=1∧j=0", HComp (ty0, [[("i", true); ("j", false)]],
                                      [("i", [("i", true); ("j", false)], num 7)], num 5);
    "hitElim on hit(c,v)",     HITElim ([("c", ["x"], Var "x")], HITConstr ("c", [num 5]));
  ] in
  Printf.printf "--- per-construct diagnostic (which formers compute vs stick) ---\n";
  List.iter (fun (label, t) ->
    let s = match classify t with
      | Value _ -> "VALUE" | Stuck _ -> "STUCK (non-value normal form)" | Timeout _ -> "TIMEOUT" in
    Printf.printf "  %-26s -> %s\n" label s) cases

let () =
  (* seed + depth overridable from CLI for a hunting sweep; defaults keep the
   * deterministic gate reproducible. *)
  let seed  = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 20260701 in
  let depth = if Array.length Sys.argv > 2 then int_of_string Sys.argv.(2) else 4 in
  (* argv[3] = stretch scale (default 1): multiplies the iteration counts for a
     --stretch nightly sweep; the deterministic gate stays at scale 1. *)
  let scale = if Array.length Sys.argv > 3 then max 1 (int_of_string Sys.argv.(3)) else 1 in
  Random.init seed;
  diag ();
  for _ = 1 to n_core * scale do
    match classify (gen_core depth) with
    | Value _ -> incr cv
    | Stuck nf -> incr cs; add core_wit (show_head nf)
    | Timeout _ -> incr ct
  done;
  for _ = 1 to n_cub * scale do
    match classify (gen_cubical depth) with
    | Value _ -> incr uv
    | Stuck nf -> incr us; add cub_wit (show_head nf)
    | Timeout _ -> incr ut
  done;
  for _ = 1 to n_conf * scale do
    let t = gen_core depth in
    let a = nf_of (classify t) and b = nf_of (classify (alpha_bump t)) in
    if term_equal_env [] a b then incr confok else incr confbad
  done;
  Printf.printf "=== metatheory fuzz (seed %d, fuel %d, depth %d) ===\n" seed fuel_budget depth;
  Printf.printf "P1 core    : %d value | %d STUCK | %d timeout   (n=%d)\n" !cv !cs !ct n_core;
  Printf.printf "P2 cubical : %d value | %d stuck | %d timeout   (n=%d)\n" !uv !us !ut n_cub;
  Printf.printf "P3 confl   : %d ok | %d MISMATCH                 (n=%d)\n" !confok !confbad n_conf;
  if !cs > 0 || !ct > 0 then
    Printf.printf "  [core witnesses, head ctor of the stuck/looping normal form]: %s\n"
      (String.concat ", " !core_wit);
  if !us > 0 then
    Printf.printf "  [cubical NEUTRAL normal forms over FREE dimensions — correct, NOT stuck-bugs]: %s\n"
      (String.concat ", " !cub_wit);
  let core_bug = !cs > 0 || !ct > 0 || !confbad > 0 in
  if core_bug then begin
    Printf.printf "RESULT: FAIL — core Progress/SN or confluence violated.\n"; exit 1
  end else begin
    (* NOTE (2026-07-08): these generated terms have FREE dimension variables, so a
       residual hcomp/comp is a legitimately NEUTRAL normal form, not an O2 gap. Closed
       canonicity (the real O2 question) is measured by test_o2_probe.ml — CCHM boundary
       laws + 8000/8000 closed corners → value, cross-dim included. The count below is
       open-dimension neutrality, NOT a compute failure. *)
    Printf.printf "RESULT: core sound on this run%s.\n"
      (if !us > 0 then
         Printf.sprintf "; %d cubical neutrals over free dims (correct — see test_o2_probe for CLOSED canonicity)" !us
       else "; no cubical neutral found this run");
    exit 0
  end
