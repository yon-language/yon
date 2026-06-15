(* naturality_symcheck.ml — symbolic check of a naturality square.
 *
 * A natural transformation eta between two functors F and G must satisfy a
 * coherence condition (the naturality square): for the chosen component this
 * amounts to
 *
 *     eta(F(x))  =  G(eta(x))
 *
 * This file builds both sides symbolically as AST terms, normalizes them, and
 * checks whether they are equal. There are three layers of strength, applied
 * in order:
 *
 *   1. Reduction normalization: inline trivial function bodies, do constant
 *      folding, and simplify x+0 and x*1.
 *   2. Commutative canonicalization (canonicalize below): sort the operands of
 *      + and *, so 2*x and x*2 become the same term.
 *   3. Ring solver (ring_equal below): decide equality in the free commutative
 *      ring over the opaque leaves. This is what closes distributivity, e.g.
 *      x*(a+b) versus x*a + x*b, and collecting like terms, e.g. (x+1)^2
 *      versus x^2 + 2x + 1. On the polynomial fragment it is a decision
 *      procedure, so a positive answer is a real proof and a negative answer
 *      is genuine (not a failure to normalize).
 *
 * The result is "Proven" when the two sides are equal, "Inconclusive" when
 * they leave the fragments above (opaque reduction-clauses, recursion,
 * branches the normalizer cannot align). Inconclusive is NOT "Disproven":
 * disproving the square needs a concrete counterexample, which is the job of
 * the runtime checks F2a/F2b, or an escalation to an SMT solver or Coq. This
 * file only decides positive symbolic equality. *)

module S = Surface_ast

type sym_result =
  | Proven           (* LHS == RHS after normalization *)
  | Inconclusive of string  (* not decided, with a reason *)

(* Alpha-equivalence: structural comparison up to variable renaming. For the
 * naturality check the free variables are the function parameters (usually
 * "input" or "x").
 *
 * For now this is a purely syntactic comparison (no alpha-renaming), which is
 * enough for the common case where parameters have standardized names. *)
let rec expr_equal (a : S.expr) (b : S.expr) : bool =
  match a, b with
  | S.ELit (la, _), S.ELit (lb, _) -> literal_equal la lb
  | S.EVar (na, _), S.EVar (nb, _) -> na = nb
  | S.EField (ea, fa, _), S.EField (eb, fb, _) ->
      fa = fb && expr_equal ea eb
  | S.ECall (fa, asa, _), S.ECall (fb, asb, _) ->
      fa = fb
      && List.length asa = List.length asb
      && List.for_all2 expr_equal asa asb
  | S.EBinop (opa, la, ra, _), S.EBinop (opb, lb, rb, _) ->
      opa = opb && expr_equal la lb && expr_equal ra rb
  | S.EApp (ha, asa, _), S.EApp (hb, asb, _) ->
      expr_equal ha hb
      && List.length asa = List.length asb
      && List.for_all2 expr_equal asa asb
  | S.EParen (ea, _), eb -> expr_equal ea eb
  | ea, S.EParen (eb, _) -> expr_equal ea eb
  | _ -> false  (* altre forme: pessimistico *)

and literal_equal (a : S.literal) (b : S.literal) : bool =
  match a, b with
  | S.LitNumber x, S.LitNumber y -> Float.equal x y
  | S.LitString x, S.LitString y -> x = y
  | _ -> a = b

let rec subst_var (var_name : string) (replacement : S.expr) (e : S.expr) : S.expr =
  let r = subst_var var_name replacement in
  match e with
  | S.EVar (n, _) when n = var_name -> replacement
  | S.EVar _ | S.ELit _ -> e
  | S.EField (obj, fld, loc) -> S.EField (r obj, fld, loc)
  | S.ECall (n, args, loc) -> S.ECall (n, List.map r args, loc)
  | S.EBinop (op, l, ri, loc) -> S.EBinop (op, r l, r ri, loc)
  | S.EParen (inner, loc) -> S.EParen (r inner, loc)
  | _ -> e  (* altre forme: pass-through *)

let try_inline_fun (fun_idx : (string * S.fun_decl) list)
                   (name : string) (args : S.expr list) : S.expr option =
  match List.assoc_opt name fun_idx with
  | None -> None
  | Some fd ->
      (match fd.S.fn_params, fd.S.fn_body with
       | [{S.param_name = p; _}], [S.SReturn (body_expr, _)] ->
           (match args with
            | [arg] ->
                Some (subst_var p arg body_expr)
            | _ -> None)
       | _ -> None)

(* Constant folding + elementary algebra simplifications.
 * Rule:
 *   c1 OP c2 -> eval (se entrambi LitNumber)
 *   e + 0 -> e
 *   0 + e -> e
 *   e - 0 -> e
 *   e * 1 -> e
 *   1 * e -> e
 *   e * 0 -> 0
 *   0 * e -> 0
 * Iterated to a fixed point (max 100 iters for safety). *)
let rec normalize_step (e : S.expr) : S.expr =
  match e with
  | S.EBinop (op, l, r, loc) ->
      let l' = normalize_step l in
      let r' = normalize_step r in
      (match l', r' with
       | S.ELit (S.LitNumber a, _), S.ELit (S.LitNumber b, _) ->
           let v = (match op with
             | S.OpAdd -> a +. b
             | S.OpSub -> a -. b
             | S.OpMul -> a *. b
             | S.OpDiv when b <> 0.0 -> a /. b
             | _ -> Float.nan) in
           if Float.is_nan v then S.EBinop (op, l', r', loc)
           else S.ELit (S.LitNumber v, loc)
       | _, S.ELit (S.LitNumber 0.0, _) when op = S.OpAdd -> l'
       | S.ELit (S.LitNumber 0.0, _), _ when op = S.OpAdd -> r'
       | _, S.ELit (S.LitNumber 0.0, _) when op = S.OpSub -> l'
       | _, S.ELit (S.LitNumber 1.0, _) when op = S.OpMul -> l'
       | S.ELit (S.LitNumber 1.0, _), _ when op = S.OpMul -> r'
       | _, S.ELit (S.LitNumber 0.0, _) when op = S.OpMul ->
           S.ELit (S.LitNumber 0.0, loc)
       | S.ELit (S.LitNumber 0.0, _), _ when op = S.OpMul ->
           S.ELit (S.LitNumber 0.0, loc)
       | _ -> S.EBinop (op, l', r', loc))
  | S.EParen (inner, _) -> normalize_step inner
  | S.ECall (n, args, loc) -> S.ECall (n, List.map normalize_step args, loc)
  | S.EField (obj, fld, loc) -> S.EField (normalize_step obj, fld, loc)
  | _ -> e

(* A total order on expressions, used for commutative canonicalization. The
 * order is arbitrary but consistent: literal < var < field < call < binop;
 * within the same family, lexicographic on the data. *)
let rec compare_expr (a : S.expr) (b : S.expr) : int =
  let tag e = match e with
    | S.ELit _ -> 0
    | S.EVar _ -> 1
    | S.EField _ -> 2
    | S.ECall _ -> 3
    | S.EBinop _ -> 4
    | S.EParen _ -> 5
    | _ -> 99
  in
  let ta = tag a and tb = tag b in
  if ta <> tb then compare ta tb
  else
    match a, b with
    | S.ELit (la, _), S.ELit (lb, _) -> compare la lb
    | S.EVar (na, _), S.EVar (nb, _) -> compare na nb
    | S.EField (ea, fa, _), S.EField (eb, fb, _) ->
        let c = compare fa fb in
        if c <> 0 then c else compare_expr ea eb
    | S.ECall (na, asa, _), S.ECall (nb, asb, _) ->
        let c = compare na nb in
        if c <> 0 then c
        else compare_lists asa asb
    | S.EBinop (opa, la, ra, _), S.EBinop (opb, lb, rb, _) ->
        let c = compare opa opb in
        if c <> 0 then c
        else let c2 = compare_expr la lb in
             if c2 <> 0 then c2 else compare_expr ra rb
    | S.EParen (ea, _), S.EParen (eb, _) -> compare_expr ea eb
    | _ -> 0  (* same tag but uncovered form: arbitrary *)

and compare_lists xs ys =
  match xs, ys with
  | [], [] -> 0
  | [], _ -> -1
  | _, [] -> 1
  | x :: xs', y :: ys' ->
      let c = compare_expr x y in
      if c <> 0 then c else compare_lists xs' ys'

(* Canonicalize commutative ops by ordering the operands *)
let rec canonicalize (e : S.expr) : S.expr =
  match e with
  | S.EBinop (op, l, r, loc) when op = S.OpAdd || op = S.OpMul ->
      (* Flatten the associative chain: collect all the left and right operands
       * that use the same operator *)
      let rec flatten acc e =
        match e with
        | S.EBinop (op', l', r', _) when op' = op ->
            flatten (flatten acc l') r'
        | _ -> canonicalize e :: acc
      in
      let operands = flatten [] (S.EBinop (op, l, r, loc)) in
      (* Ordina e ricostrui-left-associativo *)
      let sorted = List.sort compare_expr operands in
      (match sorted with
       | [] -> e  (* impossibile *)
       | [x] -> x
       | first :: rest ->
           List.fold_left
             (fun acc operand -> S.EBinop (op, acc, operand, loc))
             first rest)
  | S.EBinop (op, l, r, loc) ->
      S.EBinop (op, canonicalize l, canonicalize r, loc)
  | S.ECall (n, args, loc) -> S.ECall (n, List.map canonicalize args, loc)
  | S.EField (obj, fld, loc) -> S.EField (canonicalize obj, fld, loc)
  | S.EParen (inner, _) -> canonicalize inner
  | _ -> e

(* Inlining + folding up to a fixed point.
 * Strategy:
 *   1. normalize_step (folding)
 *   2. recursive inlining of the known wrappers
 *   3. repeat until the expr stops changing *)
let rec inline_calls (fun_idx : (string * S.fun_decl) list) (e : S.expr) : S.expr =
  match e with
  | S.ECall (n, args, loc) ->
      let args' = List.map (inline_calls fun_idx) args in
      (match try_inline_fun fun_idx n args' with
       | Some inlined -> inline_calls fun_idx inlined
       | None -> S.ECall (n, args', loc))
  | S.EBinop (op, l, r, loc) ->
      S.EBinop (op, inline_calls fun_idx l, inline_calls fun_idx r, loc)
  | S.EField (obj, fld, loc) -> S.EField (inline_calls fun_idx obj, fld, loc)
  | S.EParen (inner, _) -> inline_calls fun_idx inner
  | _ -> e

let normalize (fun_idx : (string * S.fun_decl) list) (e : S.expr) : S.expr =
  let rec loop e n =
    if n <= 0 then e
    else
      let e' = inline_calls fun_idx e in
      let e'' = normalize_step e' in
      let e''' = canonicalize e'' in
      if expr_equal e e''' then e'''
      else loop e''' (n - 1)
  in
  loop e 50

(* ─── Ring solver: decide equality in a free commutative ring ───────────
 *
 * canonicalize above handles commutativity of + and * (it sorts operands),
 * but it does NOT distribute: x*(a+b) and x*a + x*b stay distinct, so the
 * naturality check reports Inconclusive on them. This solver closes that gap
 * for the pure polynomial fragment.
 *
 * The idea is the standard normal form for polynomials. Treat every leaf the
 * normalizer cannot reduce (a variable, a field access, an opaque call) as an
 * indeterminate, an "atom". Then any expression built from atoms with +, -, *
 * and numeric constants is a multivariate polynomial, and two polynomials are
 * equal in the ring exactly when they have the same normal form:
 *
 *     polynomial = a finite sum of monomials
 *     monomial   = a rational coefficient times a product of atoms with
 *                  multiplicities, e.g. 3 * x^2 * y
 *
 * Addition adds coefficients of like monomials; multiplication distributes
 * (monomial times monomial multiplies coefficients and adds exponents). On
 * this fragment the procedure is complete and decidable: it always returns a
 * verdict, never a false Inconclusive. The honest boundary is the fragment
 * itself: as soon as a leaf is an atom the normalizer could not inline away,
 * it is treated as an opaque indeterminate. That is sound (an opaque leaf is
 * just a variable), but it means an equality that depends on the meaning of
 * that leaf will not be decided here. *)

(* A monomial: atoms (in their canonical printed form) mapped to their positive
   integer exponents. The empty map is the constant monomial 1. We key atoms by
   a canonical string so monomials compare and merge structurally. *)
module AtomMap = Map.Make (String)
type monomial = int AtomMap.t

(* A polynomial: monomials (keyed by a canonical string of the monomial) mapped
   to their rational coefficient, kept as a pair (num, den) in lowest terms.
   A monomial absent from the map has coefficient zero. *)
module MonoMap = Map.Make (String)

let rec gcd a b = if b = 0 then abs a else gcd b (a mod b)

(* A coefficient is an exact rational, so that division by an integer constant
   (OpDiv by a literal) stays exact and 1/3 + 1/3 + 1/3 normalizes to 1. *)
type coeff = { num : int; den : int }

let mk_coeff n d =
  if d = 0 then { num = n; den = 0 }  (* division by zero: left as a marker *)
  else
    let s = if d < 0 then -1 else 1 in
    let n = n * s and d = d * s in
    let g = gcd n d in
    let g = if g = 0 then 1 else g in
    { num = n / g; den = d / g }

let coeff_add a b =
  if a.den = 0 || b.den = 0 then { num = 0; den = 0 }
  else mk_coeff (a.num * b.den + b.num * a.den) (a.den * b.den)

let coeff_mul a b =
  if a.den = 0 || b.den = 0 then { num = 0; den = 0 }
  else mk_coeff (a.num * b.num) (a.den * b.den)

let coeff_is_zero a = a.num = 0 && a.den <> 0

(* Print a monomial (its atom->exponent map) to a canonical key. Atoms are
   already sorted by AtomMap, so the key is unique for the monomial. *)
let monomial_key (m : monomial) : string =
  AtomMap.bindings m
  |> List.filter (fun (_, e) -> e <> 0)
  |> List.map (fun (a, e) -> Printf.sprintf "%s^%d" a e)
  |> String.concat "*"

(* Multiply two monomials: add exponents atom by atom. *)
let monomial_mul (a : monomial) (b : monomial) : monomial =
  AtomMap.union (fun _ ea eb -> Some (ea + eb)) a b

type polynomial = (monomial * coeff) MonoMap.t

let poly_zero : polynomial = MonoMap.empty

(* Add one monomial with a coefficient into a polynomial, merging like terms
   and dropping the term if the coefficient becomes zero. *)
let poly_add_term (p : polynomial) (m : monomial) (c : coeff) : polynomial =
  if coeff_is_zero c then p
  else
    let k = monomial_key m in
    match MonoMap.find_opt k p with
    | None -> MonoMap.add k (m, c) p
    | Some (_, c0) ->
        let c' = coeff_add c0 c in
        if coeff_is_zero c' then MonoMap.remove k p
        else MonoMap.add k (m, c') p

let poly_add (a : polynomial) (b : polynomial) : polynomial =
  MonoMap.fold (fun _ (m, c) acc -> poly_add_term acc m c) b a

let poly_neg (a : polynomial) : polynomial =
  MonoMap.map (fun (m, c) -> (m, coeff_mul c (mk_coeff (-1) 1))) a

let poly_mul (a : polynomial) (b : polynomial) : polynomial =
  MonoMap.fold (fun _ (ma, ca) acc ->
    MonoMap.fold (fun _ (mb, cb) acc2 ->
      poly_add_term acc2 (monomial_mul ma mb) (coeff_mul ca cb)
    ) b acc
  ) a poly_zero

(* The constant polynomial c (the empty monomial with coefficient c). *)
let poly_const (c : coeff) : polynomial =
  poly_add_term poly_zero AtomMap.empty c

(* A single atom as a polynomial: the monomial atom^1 with coefficient 1. *)
let poly_atom (key : string) : polynomial =
  poly_add_term poly_zero (AtomMap.singleton key 1) (mk_coeff 1 1)

(* Try to read an expression as a polynomial over its opaque leaves. Returns
   None when the expression leaves the ring fragment in a way we will not model
   (for example OpMod, or a non-integer/non-constant division), so the caller
   falls back to the existing Inconclusive path rather than guessing. *)
let rec to_poly (e : S.expr) : polynomial option =
  match e with
  | S.ELit (S.LitNumber f, _) ->
      (* Accept integer-valued literals exactly; a genuinely fractional literal
         (2.5) is kept out of the integer-coefficient model. *)
      if Float.is_integer f then Some (poly_const (mk_coeff (int_of_float f) 1))
      else None
  | S.EParen (inner, _) -> to_poly inner
  | S.EBinop (S.OpAdd, l, r, _) ->
      (match to_poly l, to_poly r with
       | Some pl, Some pr -> Some (poly_add pl pr)
       | _ -> None)
  | S.EBinop (S.OpSub, l, r, _) ->
      (match to_poly l, to_poly r with
       | Some pl, Some pr -> Some (poly_add pl (poly_neg pr))
       | _ -> None)
  | S.EBinop (S.OpMul, l, r, _) ->
      (match to_poly l, to_poly r with
       | Some pl, Some pr -> Some (poly_mul pl pr)
       | _ -> None)
  | S.EBinop (S.OpDiv, l, r, _) ->
      (* Only division by a nonzero integer constant stays in the exact model;
         dividing by a polynomial leaves the ring. *)
      (match to_poly r with
       | Some pr when MonoMap.cardinal pr = 1 ->
           (match MonoMap.choose pr with
            | (_, (m, c)) when AtomMap.for_all (fun _ e -> e = 0) m
                               && not (coeff_is_zero c) ->
                (match to_poly l with
                 | Some pl ->
                     let inv = mk_coeff c.den c.num in
                     Some (poly_mul pl (poly_const inv))
                 | None -> None)
            | _ -> None)
       | _ -> None)
  | S.EBinop (S.OpMod, _, _, _) -> None
  | _ ->
      (* Any other leaf (variable, field access, opaque call) is an opaque
         indeterminate. We key it by its canonical printed form, so two
         syntactically identical leaves are the same atom. *)
      Some (poly_atom (expr_to_atom_key e))

(* Canonical string for an opaque leaf, reusing canonicalize so that two leaves
   equal up to operator commutativity hash to the same atom. *)
and expr_to_atom_key (e : S.expr) : string =
  let rec render x =
    match x with
    | S.EVar (n, _) -> "v:" ^ n
    | S.ELit (S.LitNumber f, _) -> "n:" ^ string_of_float f
    | S.ELit (S.LitString s, _) -> "s:" ^ s
    | S.ELit (S.LitBool b, _) -> "b:" ^ string_of_bool b
    | S.EField (o, f, _) -> "f:" ^ f ^ "(" ^ render o ^ ")"
    | S.ECall (n, args, _) ->
        "c:" ^ n ^ "(" ^ String.concat "," (List.map render args) ^ ")"
    | S.EParen (i, _) -> render i
    | S.EBinop (op, l, r, _) ->
        let ops = (match op with
          | S.OpAdd -> "+" | S.OpSub -> "-" | S.OpMul -> "*"
          | S.OpDiv -> "/" | S.OpMod -> "%" | _ -> "?") in
        "(" ^ render l ^ ops ^ render r ^ ")"
    | _ -> "?"
  in
  render (canonicalize e)

(* Two polynomials are equal iff they have the same monomials with the same
   coefficients. Since the maps are keyed canonically, structural equality of
   the coefficient maps is exactly ring equality. *)
let poly_equal (a : polynomial) (b : polynomial) : bool =
  let coeffs p =
    MonoMap.bindings p
    |> List.map (fun (k, (_, c)) -> (k, (c.num, c.den)))
    |> List.sort compare
  in
  coeffs a = coeffs b

(* Decide whether two expressions are equal as elements of the free commutative
   ring over their opaque leaves. Returns None when either side leaves the
   ring fragment. *)
let ring_equal (l : S.expr) (r : S.expr) : bool option =
  match to_poly l, to_poly r with
  | Some pl, Some pr -> Some (poly_equal pl pr)
  | _ -> None


let check (fun_idx : (string * S.fun_decl) list)
          (eta_name : string)
          (f_n_name : string)
          (g_n_name : string)
          (input_name : string) : sym_result =
  let loc = S.dummy_loc in
  let input_var = S.EVar (input_name, loc) in
  (* LHS = η(F__N(input)) *)
  let lhs = S.ECall (eta_name,
              [S.ECall (f_n_name, [input_var], loc)], loc) in
  (* RHS = G__N(η(input)) *)
  let rhs = S.ECall (g_n_name,
              [S.ECall (eta_name, [input_var], loc)], loc) in
  let lhs_norm = normalize fun_idx lhs in
  let rhs_norm = normalize fun_idx rhs in
  if expr_equal lhs_norm rhs_norm then Proven
  else
    (* Syntactic normal forms differ. Before giving up, try to decide the
       equality in the free commutative ring: this closes the cases where the
       two sides differ only by distributivity or by collecting like terms
       (x*(a+b) vs x*a + x*b, and similar). On the polynomial fragment this is
       a decision procedure, so a positive answer is a real proof. *)
    (match ring_equal lhs_norm rhs_norm with
     | Some true -> Proven
     | _ ->
         Inconclusive (
           "post-normalization LHS and RHS are syntactically distinct; "
           ^ "may still be semantically equal (commutativity, reduction-clauses, etc.)"))

(* Helper that returns the normalized LHS and RHS (before the syntactic
 * comparison), so a caller can pass them to an external SMT solver. *)
let build_normalized_lhs_rhs
    (fun_idx : (string * S.fun_decl) list)
    (eta_name : string)
    (f_n_name : string)
    (g_n_name : string)
    (input_name : string) : S.expr * S.expr =
  let loc = S.dummy_loc in
  let input_var = S.EVar (input_name, loc) in
  let lhs = S.ECall (eta_name,
              [S.ECall (f_n_name, [input_var], loc)], loc) in
  let rhs = S.ECall (g_n_name,
              [S.ECall (eta_name, [input_var], loc)], loc) in
  (normalize fun_idx lhs, normalize fun_idx rhs)
