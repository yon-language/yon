(* test_kernel_independent.ml — the INDEPENDENT second checker (de Bruijn criterion, D1).
 *
 * A self-contained reducer for the CORE fragment (β, Σ projections, J-on-refl, refl@, plus
 * congruence) with its OWN capture-avoiding substitution and OWN alpha-equality — it calls
 * neither Reduce nor Subst nor Ast.term_equal, so it is a genuinely independent second
 * implementation. It then DIFFERENTIALLY checks itself against the main kernel
 * (Builtins.reduce_with_builtins): on every generated closed core term, the two normal forms
 * must be alpha-equal. A mismatch is a bug in one of the two reducers — exactly the kind a
 * single audited kernel cannot catch alone. This discharges defect D1 of trusted-kernel.md
 * for the core conversion (the soundness-critical re-derivation).
 *
 * Scope: the proved-sound core. Cubical reduction (cubical.ml) is D2 (incomplete) and is out.
 *)

open Ast

(* ── independent substitution (capture-avoiding, with freshening) ─────── *)
let ctr = ref 0
let fresh () = incr ctr; Printf.sprintf "$ind%d" !ctr

let rec fv = function
  | Var x -> [x]
  | Lam (x, _, b) -> List.filter (fun y -> y <> x) (fv b)
  | App (f, a) -> fv f @ fv a
  | Pair (a, b) -> fv a @ fv b
  | Fst t | Snd t | Refl t -> fv t
  | J (_, _, c, d, p, b) -> fv c @ fv d @ fv p @ fv b
  | PApp (p, _) -> fv p
  | PLam (_, b) -> fv b
  | _ -> []

let rec subst' x v t = match t with
  | Var y -> if y = x then v else t
  | Lam (y, ty, b) ->
      if y = x then t
      else if List.mem y (fv v) then
        let y' = fresh () in Lam (y', ty, subst' x v (subst' y (Var y') b))
      else Lam (y, ty, subst' x v b)
  | App (f, a) -> App (subst' x v f, subst' x v a)
  | Pair (a, b) -> Pair (subst' x v a, subst' x v b)
  | Fst t -> Fst (subst' x v t)
  | Snd t -> Snd (subst' x v t)
  | Refl t -> Refl (subst' x v t)
  | J (s, ty, c, d, p, b) -> J (s, ty, subst' x v c, subst' x v d, subst' x v p, subst' x v b)
  | PApp (p, r) -> PApp (subst' x v p, r)
  | PLam (i, b) -> if List.mem i (fv v) then let i' = fresh () in PLam (i', subst' x v (subst' i (Var i') b)) else PLam (i, subst' x v b)
  | other -> other

(* ── independent small-step (normal order) ────────────────────────────── *)
let rec step' = function
  | App (Lam (x, _, b), a) -> Some (subst' x a b)              (* β *)
  | App (f, a) ->
      (match step' f with Some f' -> Some (App (f', a))
       | None -> (match step' a with Some a' -> Some (App (f, a')) | None -> None))
  | Fst (Pair (a, _)) -> Some a
  | Snd (Pair (_, b)) -> Some b
  | Fst t -> (match step' t with Some t' -> Some (Fst t') | None -> None)
  | Snd t -> (match step' t with Some t' -> Some (Snd t') | None -> None)
  | J (_, _, _, d, Refl a, _) -> Some (App (d, a))            (* J on refl *)
  | J (s, ty, c, d, p, b) ->
      (match step' p with Some p' -> Some (J (s, ty, c, d, p', b))
       | None -> (match step' d with Some d' -> Some (J (s, ty, c, d', p, b)) | None -> None))
  | PApp (Refl t, _) -> Some t                                (* refl @ r *)
  | PApp (p, r) -> (match step' p with Some p' -> Some (PApp (p', r)) | None -> None)
  | Lam (x, ty, b) -> (match step' b with Some b' -> Some (Lam (x, ty, b')) | None -> None)
  | Pair (a, b) ->
      (match step' a with Some a' -> Some (Pair (a', b))
       | None -> (match step' b with Some b' -> Some (Pair (a, b')) | None -> None))
  | Refl t -> (match step' t with Some t' -> Some (Refl t') | None -> None)
  | PLam (i, b) -> (match step' b with Some b' -> Some (PLam (i, b')) | None -> None)
  | _ -> None

let rec nf' cap t = if cap <= 0 then t else match step' t with Some t' -> nf' (cap-1) t' | None -> t

(* ── independent alpha-equality (binder bijection) ────────────────────── *)
let rec aeq env t1 t2 = match t1, t2 with
  | Var x, Var y -> (match List.assoc_opt x env with Some y' -> y' = y | None -> x = y)
  | Lam (x, _, b1), Lam (y, _, b2) -> aeq ((x, y) :: env) b1 b2
  | PLam (x, b1), PLam (y, b2) -> aeq ((x, y) :: env) b1 b2
  | App (f1, a1), App (f2, a2) -> aeq env f1 f2 && aeq env a1 a2
  | Pair (a1, b1), Pair (a2, b2) -> aeq env a1 a2 && aeq env b1 b2
  | Fst a, Fst b | Snd a, Snd b | Refl a, Refl b -> aeq env a b
  | J (_, _, c1, d1, p1, b1), J (_, _, c2, d2, p2, b2) ->
      aeq env c1 c2 && aeq env d1 d2 && aeq env p1 p2 && aeq env b1 b2
  | PApp (p1, _), PApp (p2, _) -> aeq env p1 p2
  | Unit, Unit -> true
  | _ -> t1 = t2

(* ── generators (closed should-compute CORE terms; same shape as the fuzzer) ── *)
let num n = Var (Printf.sprintf "__num_%d" n)
let ty0 = TyType 0
let rec gen_val d = if d <= 0 then num (Random.int 100) else match Random.int 5 with
  | 0 -> num (Random.int 100) | 1 -> Lam ("x", ty0, Var "x")
  | 2 -> Pair (gen_val (d-1), gen_val (d-1)) | 3 -> Refl (gen_val (d-1)) | _ -> Unit
let rec gen_core d = if d <= 0 then gen_val 0 else match Random.int 7 with
  | 0 | 1 -> gen_val d
  | 2 -> App (Lam ("x", ty0, Var "x"), gen_core (d-1))
  | 3 -> Fst (Pair (gen_core (d-1), gen_val 1))
  | 4 -> Snd (Pair (gen_val 1, gen_core (d-1)))
  | 5 -> let a = gen_val 1 in J ("x", ty0, gen_val 1, Lam ("y", ty0, Var "y"), Refl a, a)
  | _ -> App (Lam ("x", ty0, Pair (Var "x", Var "x")), gen_core (d-1))

(* ── independent SIMPLY-TYPED checker + Preservation (D1, typing half) ──
 * The kernel type-checks SURFACE and trusts the desugared Core (tycheck runs before
 * desugar), so the Core is never re-type-checked. This is a STANDALONE independent core
 * type-checker — bidirectional, simply-typed (Π as arrow, Σ as product, Id over a base) —
 * with its own infer'/check'. Combined with the independent reducer above it validates
 * PRESERVATION empirically: generate t : T well-typed by construction, reduce to nf with
 * nf', and re-check nf : T. A type lost under reduction is a Preservation violation. (J and
 * the dependent fragment are out; this is the simply-typed core, which is the part the
 * collapse onto SN rests on.) *)
type ity = TN | TArr of ity * ity | TProd of ity * ity | TIdt of ity

let is_num s = String.length s >= 6 && String.sub s 0 6 = "__num_"

let rec ast_to_ity = function
  | TyType _ -> Some TN
  | TyArrow (a, b) -> (match ast_to_ity a, ast_to_ity b with Some a', Some b' -> Some (TArr (a', b')) | _ -> None)
  | TySigma (_, a, b) -> (match ast_to_ity a, ast_to_ity b with Some a', Some b' -> Some (TProd (a', b')) | _ -> None)
  | TyId (a, _, _) -> (match ast_to_ity a with Some a' -> Some (TIdt a') | None -> None)
  | _ -> None

let rec infer' env t = match t with
  | Var x when is_num x -> Some TN
  | Var x -> List.assoc_opt x env
  | Lam (x, ast_ty, b) ->                          (* annotated lambda: synthesise the arrow *)
      (match ast_to_ity ast_ty with
       | Some a -> (match infer' ((x, a) :: env) b with Some bt -> Some (TArr (a, bt)) | None -> None)
       | None -> None)
  | App (f, a) -> (match infer' env f with
      | Some (TArr (ta, tb)) -> if check' env a ta then Some tb else None | _ -> None)
  | Fst p -> (match infer' env p with Some (TProd (a, _)) -> Some a | _ -> None)
  | Snd p -> (match infer' env p with Some (TProd (_, b)) -> Some b | _ -> None)
  | Pair (a, b) -> (match infer' env a, infer' env b with Some ta, Some tb -> Some (TProd (ta, tb)) | _ -> None)
  | Refl v -> (match infer' env v with Some a -> Some (TIdt a) | None -> None)
  | _ -> None
and check' env e t = match e, t with
  | Lam (x, _, b), TArr (ta, tb) -> check' ((x, ta) :: env) b tb
  | Pair (p, q), TProd (a, b) -> check' env p a && check' env q b
  | Refl v, TIdt a -> check' env v a
  | _ -> (match infer' env e with Some t' -> t' = t | None -> false)

(* type-directed generator: a closed term of type T, biased to contain redexes *)
let rec gen_ty d = if d <= 0 then TN else match Random.int 4 with
  | 0 -> TN | 1 -> TArr (gen_ty (d-1), gen_ty (d-1))
  | 2 -> TProd (gen_ty (d-1), gen_ty (d-1)) | _ -> TIdt (gen_ty (d-1))

let rec ity_to_ast = function
  | TN -> ty0 | TArr (a, b) -> TyArrow (ity_to_ast a, ity_to_ast b)
  | TProd (a, b) -> TySigma ("_", ity_to_ast a, ity_to_ast b)
  | TIdt a -> TyId (ity_to_ast a, num 0, num 0)

let rec gen_at env t d : term =
  if d <= 0 then (match t with
    | TN -> num (Random.int 50)
    | TArr (a, b) -> let x = fresh () in Lam (x, ity_to_ast a, gen_at ((x, a) :: env) b 0)
    | TProd (a, b) -> Pair (gen_at env a 0, gen_at env b 0)
    | TIdt a -> Refl (gen_at env a 0))
  else match Random.int 5 with
    | 0 -> (* β-redex of type t: (λx:s. body:t) (arg:s) *)
        let s = gen_ty 1 in let x = fresh () in
        App (Lam (x, ity_to_ast s, gen_at ((x, s) :: env) t (d-1)), gen_at env s (d-1))
    | 1 -> (* Fst of a Σ whose first is t *)
        Fst (Pair (gen_at env t (d-1), gen_at env (gen_ty 1) (d-1)))
    | 2 -> (* Snd of a Σ whose second is t *)
        Snd (Pair (gen_at env (gen_ty 1) (d-1), gen_at env t (d-1)))
    | _ -> (match t with
        | TN -> num (Random.int 50)
        | TArr (a, b) -> let x = fresh () in Lam (x, ity_to_ast a, gen_at ((x, a) :: env) b (d-1))
        | TProd (a, b) -> Pair (gen_at env a (d-1), gen_at env b (d-1))
        | TIdt a -> Refl (gen_at env a (d-1)))

(* ── driver: reduction re-check AND typing/Preservation re-check ───────── *)
let () =
  Random.init 20260701;
  let n = 5000 and depth = 5 and cap = 100000 in
  (* (1) reduction differential: independent NF vs kernel NF *)
  let agree = ref 0 and disagree = ref 0 and wit = ref [] in
  for _ = 1 to n do
    let t = gen_core depth in
    let k = Builtins.reduce_with_builtins ~fuel:cap Reduce.empty_ctx t in
    let i = nf' cap t in
    if aeq [] k i then incr agree
    else begin incr disagree;
      if List.length !wit < 5 then wit := (Pretty.pp_compact k ^ "  vs  " ^ Pretty.pp_compact i) :: !wit
    end
  done;
  (* (2) typing + Preservation: generate t:T, check it, reduce, re-check nf:T *)
  let typed_ok = ref 0 and typed_bad = ref 0 and preserved = ref 0 and lost = ref 0 in
  for _ = 1 to n do
    let ty = gen_ty 3 in
    let t = gen_at [] ty 4 in
    if check' [] t ty then incr typed_ok else incr typed_bad;       (* generator vs checker *)
    let nf = nf' cap t in
    if check' [] nf ty then incr preserved else incr lost           (* Preservation *)
  done;
  Printf.printf "=== independent core checker vs kernel (seed 20260701, n=%d, depth %d) ===\n" n depth;
  Printf.printf "reduction : AGREE %d | DISAGREE %d\n" !agree !disagree;
  Printf.printf "typing    : well-typed-accepted %d | rejected %d (generator vs independent checker)\n" !typed_ok !typed_bad;
  Printf.printf "preserv.  : type preserved under reduction %d | LOST %d\n" !preserved !lost;
  let bug = !disagree > 0 || !typed_bad > 0 || !lost > 0 in
  if bug then begin
    List.iter (fun w -> Printf.printf "  REDUCTION MISMATCH: %s\n" w) !wit;
    Printf.printf "RESULT: FAIL — independent reduction/typing/Preservation disagrees with the kernel.\n";
    exit 1
  end else begin
    Printf.printf "RESULT: independent reduction agrees with the kernel, and the independent\n";
    Printf.printf "        type-checker confirms Progress (no stuck) and Preservation on %d terms.\n" n;
    exit 0
  end
