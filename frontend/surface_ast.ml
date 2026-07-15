(* surface_ast.ml — abstract syntax tree of surface Yon v0.3.
 *
 * This is the AST produced by the parser. It is distinct from the
 * Yon Core AST (in ast.ml) which is the target of desugaring.
 *
 * The structure follows the BNF grammar of yon-language-spec-v0-3.md §5
 * closely. Each grammar nonterminal has a corresponding type here.
 *)

(* Source location for error reporting and diagnostics. *)

type dim =
  | DI0
  | DI1
  | DIVar of string

type location = {
  start_line : int;
  start_col : int;
  end_line : int;
  end_col : int;
  file : string;      (* originating file (from Lexing.pos_fname); "" if unknown *)
}

let dummy_loc = { start_line = 0; start_col = 0; end_line = 0; end_col = 0; file = "" }

(* Compile-time membership table (same pattern as stage_forces): the
   tycheck registers here every for-every whose collection types as a
   STREAM, keyed by source position; the desugar consults it to choose
   the drain lowering over the list walk. *)
let stream_foreach_table : (int * int, unit) Hashtbl.t = Hashtbl.create 16

(* Same mechanism for the stream METHOD calls (s.fold / s.for_every):
   sites whose receiver types as a stream take the drain lowering. *)
let stream_method_table : (int * int, unit) Hashtbl.t = Hashtbl.create 16

(* Wire subscription sites, registered by the tycheck for the desugar:
   awaits sites carry (space, producer selector, channel id); stream
   field sites just the membership. *)
let awaits_site_table : (int * int, string * int * int * int) Hashtbl.t = Hashtbl.create 16
let substream_site_table : (int * int, int) Hashtbl.t = Hashtbl.create 16

(* ─── Type expressions ─────────────────────────────────────────────── *)

(* Types in Yon surface — covers first-order schema types plus
 * universe hierarchy and dependent constructors for HoTT.
 *
 * Universe levels are Russell-predicative: Type_n : Type_{n+1}.
 * No Type : Type (which would yield Girard's paradox).
 *
 * Cumulativity: Type_n <: Type_{n+1}, so any term of type Type_n
 * can be used where Type_{n+1} is expected.
 *
 * The Pi (dependent function), Sigma (dependent pair), and Id (path
 * equality) constructors expose HoTT-level dependent types in the
 * surface syntax. A non-dependent arrow A -> B is sugar for
 * Pi(_:A). B (TyPi with unused binder).
 *)
type ty =
  | TyPrim of string                                  (* text, number, boolean, money, etc. *)
  | TyPrimIn of string * string list                  (* "money in EUR, USD" *)
  | TySum of variant list                             (* "EUR | USD | JPY" *)
  | TySumIn of variant list * string list             (* "(...) in W" *)
  | TyList of ty                                      (* "list of T" *)
  | TyMap of ty * ty                                  (* "map of K to V" *)
  | TyStream of ty                                    (* "stream of T" *)
  | TyWire of string                                  (* the handle of "wire to Space"; carries the Space name *)
  | TySubscription of string * ty                     (* the handle of w.awaits(f); carries the Space name and the stream element type *)
  | TyUser of string                                  (* user-defined place name *)
  | TyApp of string * ty list                         (* type application: Box<number>, HashMap<text, number> *)
  | TyVar of string                                   (* type variable (generic binder) *)
  | TyMetaVar of int                                  (* HM fresh tyvar alpha_N *)
  | TyUniverse of int                                 (* Type_n : universe of level n *)
  | TyPi of string * ty * ty                          (* Pi(x:A). B(x) — dependent function *)
  | TySigma of string * ty * ty                       (* Sigma(x:A). B(x) — dependent pair *)
  | TyId of ty * ty_term * ty_term                    (* Id_A(a, b) — identity / path type *)
  | TyPathP of (string * ty) * ty_term * ty_term      (* PathP (<i> A) x y : dependent path; i binds in A, endpoints are terms *)
  | TyEl of ty_term                                   (* El(c): c is the CaTT code-index (derived El) *)
  (* The Heyt-int type, parametric in the number of trits. Each "trit" is
   * {Present, Absent, Unknown}. Surface syntax: heyt_int<N> with N trits.
   * MLIR lowering: tuple<i64, i64> = (value, mask). Intuitionistic bit-by-bit
   * operations: &?, |?, ^?, ~? *)
  | TyHeytInt of int                                  (* heyt_int<N>: N trit *)
  (* A first-class function type, for higher-order functions. Surface syntax
     "T -> U", curried for several arguments (T -> U -> V is
     TyArrow (T, TyArrow (U, V))). Lowered to an LLVM function pointer. *)
  | TyArrow of ty * ty
  (* A first-class move handle, a cross-world map. Surface syntax
     "move from W1 to W2". Lets a move be passed as a parameter:
     fun apply_m(m: move from EU to Reporting, x: Trade) { ... }.
     None is a wildcard (for HM inference). *)
  | TyMoveHandle of string option * string option
  (* A first-class reduction handle, the algebra that interprets the
     operations of a place P. Surface syntax "reduction of P". Lets a reduction
     be passed in: fun run(r: reduction of Output, ...) { with r { ... } }.
     None is a wildcard. *)
  | TyReductionHandle of string option
  (* A first-class morph handle, cross-space transport realized by a natural
     transformation. Surface syntax "morph from S1 to S2". Lets a morph be
     passed as a parameter. None is a wildcard. *)
  | TyMorphHandle of string option * string option
  (* A first-class view handle, the representable functor Hom(-, P). Surface
     syntax "view of P". Lets a view be passed as a parameter. *)
  | TyViewHandle of string option

(* A "ty_term" is a placeholder for an expression appearing inside a
 * type (e.g., the endpoints of Id_A(a,b)). At surface level, we keep
 * this as the expression AST (which we'll define below); we forward-
 * reference it here via abstraction over expr. *)
and ty_term = TyTermExpr of expr                     (* a Surface term-tree appearing inside a type (Tarski code) *)

and variant = {
  v_name : string;
  v_args : ty list;
}

(* Stream back-pressure modifiers (buffer/drop) were removed entirely in v1.1:
   the surface syntax was parsed but never consumed, so a stream type is now
   just `stream of T` (TyStream of ty). *)

(* ─── Expressions ──────────────────────────────────────────────────── *)

and literal =
  | LitNumber of float
  | LitString of string
  | LitBool of bool
  | LitDuration of float * string                     (* "100 ms", "5 s" *)
  | LitCurrency of float * string                     (* "10.50 EUR" *)
  | LitHeytPresent                                    (* present as value *)
  | LitHeytAbsent                                     (* absent as value *)
  | LitHeytUnknown                                    (* unknown as value *)

and binop =
  | OpAdd | OpSub | OpMul | OpDiv | OpMod
  | OpLt | OpGt | OpLeq | OpGeq | OpEq | OpNeq
  | OpAnd | OpOr

and expr =
  | ELit of literal * location
  | EVar of string * location
  | EField of expr * string * location                (* "obj.field" *)
  | ECall of string * expr list * location            (* "f(a, b, c)" *)
  | EApp of expr * expr list * location               (* general application: head is an expr (a name, a lambda, ...) applied to args *)
  | EHITElim of expr * (string * string list * expr) list * expr * location
  | EPathApp of expr * dim * location
  | EPathAbs of string * expr * location              (* plam i => e : path abstraction <i> e *)
  | EHITConstr of string * expr list * location       (* hit(base), hit(loop), hit(merid, a): HIT constructor *)
  | EWireTo of string * location                      (* "wire to Space": open the transport toward a Space *)
  | EProduce of stmt list * location                  (* "produce { ... }" as an expression: the value is the stream id *)
  | ESpawn of expr option * stmt list * location      (* "spawn { ... }" / "spawn in N parallel { ... }": value is the collection stream; None = single replica, Some e = e replicas *)
  | ENew of string * field_assignment list * location (* "new Place { field1 e1, ... }" *)
  | ENewIn of string * string * field_assignment list * location  (* retired: `new P in Space` removed (a place's space is its filesystem directory); constructor kept for exhaustive matches, no longer produced *)
  | EBinop of binop * expr * expr * location
  | EParen of expr * location
  | EAll of string * condition * location             (* retired: the `all P where cond` surface form was removed in v1.1; constructor kept for exhaustive matches *)
  | EIn of expr * string * location                   (* "e in Context" *)
  (* HoTT-level term constructors *)
  | ERefl of expr * location                          (* refl(t) *)
  | EPair of expr * expr * location                   (* pair(a, b) *)
  | EFst of expr * location                           (* fst(p) *)
  | ESnd of expr * location                           (* snd(p) *)
  | EJ of expr * expr * expr * location               (* ind_path(C, d, p) *)
  | EQuote of ty_term * expr * location               (* quote(c, a) : El(c), a : carrier(c) — B intro *)
  | EElMatch of expr * expr * expr * location         (* el_match(target, ret, body): B eliminator, binds carrier *)
  (* pullback / pushout as an expression. Categorically: given f : A -> C and
   * g : B -> C, pullback(f, g) is the universal limit (A x_C B).
   * RETIRED at the surface: the no-arg `pullback(f,g)` / `pushout(f,g)`
   * expression forms were removed in v1.1 (they lowered to a 0.0 placeholder);
   * the parser no longer produces these constructors. The universal property
   * now lives in the `place P = pullback(f,g)` declaration, and the runtime
   * pullback in EPullbackVal (the 4-arg form). The constructors are kept only
   * so downstream pattern matches stay exhaustive. *)
  | EPullback of string * string * location            (* retired surface form, no longer produced *)
  | EPushout of string * string * location             (* retired surface form, no longer produced *)
  (* The runtime universal pullback. Syntax: pullback(f, g, a, b) builds the
   * pair (a, b) in A x B, checking the constraint f(a) == g(b) at runtime. If
   * it holds, return a valid handle (encoded as a tagged number); if not, a
   * runtime trap or NaN.
   *
   * Honest upfront: this is not the FULL universal property (no automatic
   * factor map). It is the pullback as construction + constraint +
   * projections. *)
  | EPullbackVal of string * string * expr * expr * location  (* "pullback(f, g, a, b)" *)
  (* Unary boolean/Heyting not. Type check: bool -> bool, Heyt -> Heyt.
   * Lowered to an MLIR xor with true for booleans. *)
  | ENot of expr * location
  (* if/then/else as an EXPRESSION.
   * Tycheck: T_cond=bool, T_then=T_else=T_result.
   * Lowered to scf.if with scf.yield of the value. *)
  | EIfThenElse of expr * expr * expr * location
  (* An inline lambda as an expression. Syntax `fun(x: T) => expr` or
     `fun(x) => expr` (with HM inference on x). The body is a single expression,
     no statements and no return. Lowered to a synthetic top-level function
     __lam_<N>. *)
  | ELam of (string * ty) list * expr * location
  (* An inline handle lambda: a categorically typed lambda producing a
     TyMoveHandle / TyReductionHandle / TyMorphHandle. The stratification is
     preserved: a plain `fun(x) => ...` is not accepted where a
     move/reduction/morph is required; only the three specific categorical
     lambdas are valid there.
     Syntax:
       move(s: P1) => expr from P1 to P2
       reduction(acc: T, x: U) => expr of P
       morph(s: P_src) => expr from S1 to S2
     Lowered by lifting to a function plus a synthetic decl
     __<kind>_inline_<N>. *)
  | EMoveLam of (string * ty) list * expr * string * string * location
  (* params, body_expr, from_place, to_place, loc *)
  | EReductionLam of (string * ty) list * expr * string * location
  (* params, body_expr, of_place, loc *)
  | EMorphLam of (string * ty) list * expr * string * string * location
  (* EFunctorLam, an anonymous first-class functor.
     `functor (params) => body from W to V (law identity)? (law composition)?`
     A map between worlds (categories). The functor laws (identity,
     composition) are declared and checkable by the compiler, like the
     algebraic laws. Fields: params, body, from_world, to_world, laws,
     location. *)
  | EFunctorLam of (string * ty) list * expr * string * string * string list * location
  (* params, body_expr, from_topos, to_topos, loc *)
  (* EViewLam, the fifth lambda form. `view(s: P) => expr of P` produces
     TyViewHandle (Some P), lifted to __view_inline_N. A single projection,
     unlike a top-level view which can show several fields. *)
  | EViewLam of (string * ty) list * expr * string * location
  (* params, body_expr, of_place, loc *)
  (* Handle composition. `compose h1 with h2` produces a composed handle. The
     direction reads left to right: "apply h1, then h2", which categorically is
     h2 o h1. Polymorphic over the five handle types:
   * - compose <fun> with <fun>          -> fun
   * - compose <move from P to Q> with <move from Q to R>   -> move from P to R
   * - compose <morph from S1 to S2> with <morph from S2 to S3>  -> morph from S1 to S3
   * - compose <view of P> with <fun>    -> view of P (post-compose con fun)
   * - compose <reduction of P> with <fun> -> reduction of P (post-compose) *)
  | EComposeWith of expr * expr * location
  (* h1, h2, loc — semantics: result(x) = h2(h1(x)) *)

and field_assignment = {
  fa_name : string;
  fa_value : expr;
  fa_loc : location;
}

and condition =
  | CondExpr of expr
  | CondIs of expr * pattern                          (* "e is pattern" *)
  | CondIsNot of expr * pattern                       (* "e is not pattern" *)
  | CondAnd of condition * condition
  | CondOr of condition * condition

and pattern =
  | PatVar of string                                  (* exact identifier match *)
  | PatLit of literal
  | PatType of ty                                     (* type match: "x is number" *)
  | PatPresent                                        (* the Heyting "is present" *)
  | PatAbsent                                         (* "is absent" *)
  | PatUnknown                                        (* "is unknown" *)

(* ─── Statements ───────────────────────────────────────────────────── *)

and stmt =
  | SLet of string * expr * location                  (* "let x holds e" *)
  | SAssignHolds of lvalue * expr * location          (* "x holds e" or "x.f holds e" *)
  | SAssignBecomes of lvalue * expr * location        (* "x = e" or "x.f = e" (the `becomes` surface token is retired; this node is internal-only) *)
  | SReturn of expr * location
  | SCall of string * expr list * location            (* function call as statement *)
  | SNew of string * field_assignment list * location (* "new P { ... }" *)
  | SNewIn of string * string * field_assignment list * location  (* retired: `new P in Space` removed (space = filesystem directory); constructor kept for exhaustive matches, no longer produced *)
  | SWhen of condition * stmt list *
             (condition * stmt list) list *           (* additional "when" branches *)
             stmt list option *                        (* optional "otherwise" *)
             location
  | SForEvery of for_kind * string * expr * stmt list * location
  | SInSequence of string * expr * stmt list * location
  | SRepeat of int * stmt list * stmt list option * location  (* "repeat at most N times { ... } (otherwise { ... })?" *)
  | SForever of stmt list * location
  | SScope of string option * stmt list * expr * location     (* "scope S? { ... return e }" *)
  | SProduce of stmt list * location                  (* "produce { ... }" *)
  | SEmit of expr * location
  | SPromote of expr * location
    (* "promote E" inside a spawn body: emits E onto the spawn's collection
     * stream. Like SEmit but valid only inside a spawn block; tycheck enforces
     * the scope and that all promotes in one block agree on the element type. *)
  | SForces of string * condition * stmt list * location
    (* Forcing semantics. "forces <stage> <cond> { body }" runs body only if
     * the stage `stage` forces (|-) the condition `cond` in the Kripke-Joyal
     * sense. The stage is the name bound to a place or to a current
     * observation situation. *)
  (* Explicit loops.
   * iter N do { body }: bounded, always terminates. Lowered to scf.for.
   * while cond do { body }: general. Lowered to scf.while. *)
  | SIter of expr * stmt list * location
  | SWhile of expr * stmt list * location
  | SDrop of string * location
    (* "drop X": reclaim Space X at this point. The checker proves no arc toward
     * X is reachable downstream (Space_liveness.downstream_arcs); an arc to X
     * after the drop is a compile error. X is a Space name, unambiguous from the
     * communication graph. *)

and lvalue =
  | LVar of string
  | LField of string * string                         (* "obj.field" *)

and for_kind =
  | ForParallel       (* "for every x in xs" *)
  | ForWhenHere       (* "for every x in xs when here" — stream consumption *)

(* Canonical NAME of a Tarski code term (for carrier lookup, pretty-printing,
 * El_<name> mangling). Simple codes are variables, exactly the old string;
 * applied codes (ECall / ERefl) get a readable synthesized name. *)
let rec ty_term_to_name (e : expr) : string =
  match e with
  | EVar (s, _) -> s
  | EParen (e, _) -> ty_term_to_name e
  | ERefl (t, _) -> "refl(" ^ ty_term_to_name t ^ ")"
  | ECall (f, args, _) ->
      f ^ "(" ^ String.concat "," (List.map ty_term_to_name args) ^ ")"
  | _ -> "_code"

(* ─── Declarations ─────────────────────────────────────────────────── *)

type param = {
  param_name : string;
  param_ty : ty;
}

type place_descriptor =
  | PdBy of string                                    (* "is by Identifier" *)
  | PdIdList of string list                           (* "is hello, world" *)
  | PdType of ty                                      (* "is text" *)

(* A simple place declaration inside a world: "Color is red, green, blue" *)
type world_place = {
  wp_name : string;
  wp_descriptor : place_descriptor;
  wp_loc : location;
}

type operation_decl = {
  op_name : string;
  op_params : param list;
  op_return : ty option;
  op_functorial : bool;  (* cross-world functorial: the operation is lifted
                            automatically along world morphisms (Yoneda lifting
                            at the world level) *)
  op_algebra : string option;  (* `uses algebra <Name>`: instantiates an
                            algebra from the certified catalog. The place's laws
                            are verified against the catalog. *)
  op_loc : location;
}

type field_decl = {
  fd_name : string;
  fd_ty : ty;
  fd_loc : location;
}

type field_or_op =
  | FoField of field_decl
  | FoOp of operation_decl
  | FoCell of cell_decl                               (* cell custom *)
  | FoLaw of string             (* `law <name>`: a declared algebraic law
                                   (commutative/associative/monotone), checked
                                   statically against the certified catalog. *)

(* An explicit cell declaration inside a place.
 *
 * By default 0-cells (fields) and 1-cells (operations) are implicit; an
 * explicit `cell` is needed for:
 *   - 1-cell path constructors (for HITs: loop, merid, glue)
 *   - 2-cells (homotopies between paths)
 *   - cells of dimension >= 3
 *
 * Syntax:
 *   cell <name> from <src> to <tgt>
 *
 * The declared cell has dimension dim(src) + 1 = dim(tgt) + 1.
 *)
and cell_decl = {
  cell_name : string;
  cell_src : expr;
  cell_tgt : expr;
  cell_loc : location;
}

type place_decl = {
  pd_name : string;
  pd_type_params : string list;     (* generic parameters: `place Box<T> { value T }` *)
  pd_world : string;
  pd_with_effects : bool;
  pd_members : field_or_op list;
  pd_over : string option;          (* slice category C/X: a place fibered over X *)
  pd_laws : string list;            (* algebraic laws declared on the place *)
  pd_subcontains : string option;       (* `place A subcontains B` declares the injection
                                       A -> B (A is a sub-object of B). A is usable
                                       wherever B is expected (subsumption).
                                       Checked: A must have all of B's fields. *)
  pd_is_error : bool;                (* `error E subcontains Base` is a place marked as an
                                       error. An error place is the target of the
                                       `on_error` error morphism. It reuses the whole
                                       place structure (fields, subcontains, subsumption). *)
  pd_on_error : string option;       (* `place P ... on_error E` declares the error
                                       morphism P -> E. On failure, place P is
                                       transformed into the error E. The effect is
                                       contained: the morphism does not leave the space. *)
  pd_loc : location;
}

type fun_decl = {
  fn_name : string;
  fn_type_params : string list;     (* generic type parameters: fun id<A, B>(...) *)
  fn_params : param list;
  fn_return : ty option;
  fn_visits : string list;          (* effect signature — Yoneda-native "constraint":
                                       visits Ord means the function requires the
                                       place Ord with its operations to be active *)
  fn_partial : bool;
  fn_internal : bool;               (* `internal fun`: not exported from its module *)
  fn_body : stmt list;
  fn_loc : location;
}

type mapping_kind =
  | MapsTo    (* "maps to F by fn" *)
  | ConvertsTo
  | AggregatesTo

type mapping_decl = {
  m_from : string;
  m_kind : mapping_kind;
  m_to : string;
  m_by : string;
  m_loc : location;
}

type merge_decl = {
  merge_shares : string list;
  merge_conflicts : (string * string) list;          (* (field, resolver) *)
  merge_loc : location;
}

type move_body =
  | MoveMapping of mapping_decl list                  (* Form A: from W1 to W2 *)
  | MoveMerge of merge_decl                           (* Form B: unifies W1, W2 *)

type move_decl = {
  mv_name : string;
  mv_from : string list;  (* for Form A: [from]; for Form B: [list of worlds] *)
  mv_to : string option;  (* for Form A: Some to; for Form B: None *)
  mv_body : move_body;
  mv_policy : string list;  (* lawful policy tags (e.g. ["GDPR"; "HIPAA"]). The
                               topos kernel checks that the move is compatible
                               with the target world's compliance requirements. *)
  mv_requires_caps : string list;  (* the required capability tokens. The type
                                      checker verifies at compile time that the
                                      caller declares the caps. *)
  mv_loc : location;
}

type view_item =
  | VShowSimple of string                             (* "show f" *)
  | VShowAs of string * expr                          (* "show f = e" *)
  | VShowLabel of string * string                     (* "show f as \"label\"" *)

type view_decl = {
  vw_name : string;
  vw_of : string;
  vw_items : view_item list;
  vw_loc : location;
}

type reduction_clause =
  | RcOn of string * param list * stmt list * location
  | RcLet of string * expr * location

(* The direction of a reduction.
 *   Forward  : applies P -> Q
 *   Backward : applies Q -> P (reverse handler)
 *   Bi       : both (univalence-ready) *)
type reduction_direction =
  | RdForward
  | RdBackward
  | RdBi

(* The runtime materialization policy of a reduction was removed. The
 * distributed semantics now live in the declared geometric morphism (see
 * geom_morphism_decl with gm_adjunction, gm_f_star_exact,
 * gm_f_lower_star_exact). The `reduction_policy` type and its four
 * constructors (direct/sharded/paxos/crdt) no longer exist; the model is
 * geom_morphism + space.with_fold. *)

(* Ordering of multi-shot effects.
 *   Sequential : apply the shots one after another in declaration order
 *   Parallel   : all in parallel, no dependency
 *   ByPriority : apply in priority order (lower = first) *)
type shot_ordering =
  | OrdSequential
  | OrdParallel
  | OrdByPriority

type reduction_decl = {
  rd_name : string;
  rd_of : string;
  rd_multi_shot : bool;
  rd_direction : reduction_direction;
  rd_lawful : bool;
  rd_shot_ordering : shot_ordering;
  rd_type_params : string list;
  rd_invertible : bool;                   (* forward o backward = id (univalence) *)
  rd_clauses : reduction_clause list;
  rd_fold_name : string option;           (* the canonical fold name, e.g. "sum_f64" *)
  rd_loc : location;
}

type world_decl = {
  wd_name : string;
  wd_places : world_place list;
  wd_product_of : string list;      (* categorical product *)
  wd_coproduct_of : string list;    (* categorical coproduct *)
  wd_coequalizer_of : (string * string * string) option;  (* coequalizer *)
  wd_quotient_of : (string * string) option;  (* quoziente (W, R) *)
  wd_subset_of : string option;     (* world hierarchy — EU_Region subset_of Region *)
  wd_loc : location;
}

(* Geometric morphism as a first-class construct. *)
type geom_morphism_decl = {
  gm_name : string;
  gm_source_site : string;          (* source site (Sh(C)) *)
  gm_target_site : string;          (* target site (Sh(D)) *)
  gm_pull : fun_decl option;        (* f^* inverse image *)
  gm_push : fun_decl option;        (* f_* direct image *)
  (* Explicitly declared categorical properties. The runtime derives the
   * cross-space coordination shape from these, replacing the old policy enum.
   *
   * adjunction = true means the caller declares that (pull, push) form an
   * adjoint pair f^* |- f_*. Formally checking the unit/counit is left to the
   * topos kernel and is not implemented here.
   *
   * f_star_exact = true means f^* preserves finite limits;
   * f_lower_star_exact = true means f_* preserves finite colimits. These guide
   * the dispatch:
   *   both exact          -> strong coordination (linearizable)
   *   only lax monoidal   -> eventual coordination (lax)
   *   neither/semilattice -> free_merge coordination (CRDT)
   *)
  gm_adjunction : bool;
  gm_f_star_exact : bool;
  gm_f_lower_star_exact : bool;
  gm_loc : location;
}

(* Helper sum used by the parser for geom_morphism_item productions. *)
type geom_morphism_item_kind =
  | GmItemPull of fun_decl
  | GmItemPush of fun_decl
  (* Categorical properties declared inside the geom_morphism block. They
     replace the old policy enum (direct/sharded/paxos/crdt) as the mechanism
     for declaring distributed semantics. *)
  | GmItemAdjunction
  | GmItemExactFStar
  | GmItemExactFLowerStar

(* A topos as a first-class declaration.
 *
 * A topos T groups together:
 *  - objects: the objects of the topos (the typed "states")
 *  - terminal (opt): name of the terminal object (synthesized default: 1_T)
 *  - morphisms: internal operations as a list of operation_decl
 *  - props: classified sub-objects (predicates on objects)
 *
 * Example syntax:
 *   topos Account where {
 *     objects { State { balance: number } }
 *     terminal Unit
 *     morphisms {
 *       operation deposit(x: number): number
 *       operation withdraw(x: number): number
 *     }
 *     prop is_overdrawn(s: State): Omega
 *   }
 *
 * For compatibility, topos_decl keeps a list of place_decl under sd_objects,
 * so the rest of the compiler (tycheck, emit) can keep seeing each object as a
 * place until the full lowering refactor is done. *)
type topos_decl = {
  tp_name : string;
  tp_world : string option;
  (* Explicit topos -> space binding. Syntax
   * `topos Account at EU_SPACE where { ... }`. When present, the space is the
   * concrete home where the topos instances live at runtime. Used by the emit
   * of __morph_in_<S>__<M>
   * to derive the array of heap_ids to pass to yon_rt_begin_cross_space_op,
   * without heuristics. *)
  tp_at_space : string option;
  tp_objects : place_decl list;            (* the objects of the topos *)
  tp_terminal : string option;             (* opz: nome terminal, default 1_<name> *)
  tp_morphisms : operation_decl list;      (* internal operations *)
  tp_props : prop_decl list;               (* proposizioni classified *)
  tp_loc : location;
}

and prop_decl = {
  pr_name : string;
  pr_params : (string * ty) list;
  pr_body_opt : expr option;               (* None = abstract, Some = with body *)
  pr_loc : location;
}

(* A morph as a first-class declaration.
 *
 * A morph in the category of topoi is precisely a functor: a map that takes
 * objects to objects and morphisms to morphisms, preserving composition and
 * identities. In Yon it is the top-level declaration of a map between topoi.
 *
 * Terminological note: future editions of the language may add other kinds of
 * morphisms (geometric_morphism is already separate; one could imagine
 * lex_morph, regular_morph, etale_morph). For now "morph" is the ordinary
 * case.
 *
 * The two aspects (objects, morphisms) are optional:
 *   - if mp_on_object is missing, identity on objects
 *   - if mp_on_morphism_map is [], identity on morphisms *)
type morph_decl = {
  mp_name : string;
  mp_source : string;                       (* source topos *)
  mp_target : string;                       (* target topos *)
  mp_on_object : fun_decl option;
  (* on_morphism_map is a correspondence of morphism names, not inline
   * functions. Syntax: `on_morphism deposit_eu via deposit_global`. Meaning:
   * the morphism `deposit_eu` of the source topos is mapped onto the morphism
   * `deposit_global` of the target. *)
  mp_on_morphism_map : (string * string) list;
  mp_loc : location;
}

(* A top-level functor as a first-class construct (not sugar over fun). It
 * carries source/target worlds explicitly, so the categorical identity (a map
 * between categories) is not lost and the functor registers in morph_decls as
 * a morph, because categorically it is a morph_decl (same structure: name,
 * source, target, action). This makes it referenceable from a nat_transform
 * `from F to G`. *)
type functor_decl = {
  ft_name : string;
  ft_from_world : string;
  ft_to_world : string;
  ft_params : (string * ty) list;
  ft_body : expr;
  ft_laws : string list;
  ft_loc : location;
}

(* Helper sum used by the parser for the morph_item productions. *)
type morph_item_kind =
  | MItemOnObject of fun_decl
  | MItemOnMorphism of string * string

(* A natural transformation as a first-class declaration.
 *
 * A nat_transform is a coherent family of morphisms that transforms one morph
 * into another morph (both with the same source and target). *)
type nat_transform_decl = {
  nt_name : string;
  nt_source_morph : string;
  nt_target_morph : string;
  (* nt_components has two variants:
   *   - an inline fun_decl (for an anonymous body, left as a future option)
   *   - a via_name (the name of an existing fun or reduction): the component
   *     eta_X is realized by a fun or a reduction clause of the same name.
   *
   * Syntax (the via variant, current):
   *   nat_transform Upgrade from LiftEU_v1 to LiftEU_v2 {
   *     for each State by upgrade_state
   *     for each USDState by upgrade_usd
   *   }
   *
   * We store the pairs (obj_name, via_target_name). The desugar synthesizes
   * wrappers analogous to on_morphism via M. *)
  nt_components : (string * fun_decl) list;       (* legacy inline (currently empty) *)
  nt_via_bindings : (string * string) list;       (* (obj_name, target_name) *)
  nt_loc : location;
}

type top_decl =
  | TopWorld of world_decl
  | TopSpace of space_decl                            (* cross-Space *)
  | TopPlace of place_decl
  | TopType of string * variant list * location
      (* a NAMED sum type: `inductive Tree = Leaf | Node(Tree, Tree)`. Gives the
         point-only HIT a name so a constructor argument can refer to the type
         it defines (genuine recursion), which an anonymous inline sum cannot. *)
  | TopFun of fun_decl
  | TopMove of move_decl
  | TopView of view_decl
  | TopReduction of reduction_decl
  | TopLet of string * expr * location
  | TopOperation of operation_decl                    (* top-level operation outside place *)
  | TopGeomMorphism of geom_morphism_decl
  | TopPullback of universal_decl                     (* P = pullback(f, g) *)
  | TopPushout of universal_decl                      (* P = pushout(f, g) *)
  | TopTopology of topology_decl                      (* Lawvere-Tierney topology *)
  | TopReductionCompose of reduction_compose_decl     (* R = R1 . R2 *)
  | TopTopos of topos_decl
  | TopMorph of morph_decl
  | TopNatTransform of nat_transform_decl
  | TopFunctor of functor_decl
  | TopImport of string * location                    (* import "path-or-dep" *)
  | TopImportSym of string * string * string option * location
      (* import mod::name [as alias]: module, name, optional local alias *)
  | TopImportFrom of string * string * string * location
      (* import mod::name from Space: module, name, Space — cross-package RPC *)

(* space declaration.
 *
 * There is NO surface `space ...` syntax: a space is a directory (filesystem-
 * derived; package_layout.space_decls builds one space_decl per directory).
 * The space is a logical runtime heap. sd_world optionally records the world
 * the space belongs to (from the toml), e.g. EU and US under Region.
 *
 * RETIRED model (kept for context, no longer in the record): a `sd_reduction`
 * field once bound the space to a reduction via the `backed by` keyword,
 * mapping a reduction policy to a cross-space transfer policy
 * (strong/idempotent/weak). Both the field and the `backed by` syntax are gone;
 * the current model is described just below. *)
(* space_decl pulito.
 *
 * Previously `sd_reduction` bound the space to a reduction via the `backed by`
 * keyword, and the compiler mapped the reduction policy
 * (RpDirect/RpSharded/RpEventualCRDT) to a runtime enum
 * (YON_POLICY_STRONG/EVENTUAL/CRDT_MERGE) used for the coordination-shape
 * dispatch.
 *
 * The space has no policy enum. Distributed properties are declared via the
 * geom_morphism that connects it to other spaces. For CRDT semilattices, the
 * only attribute the space itself has is the `fold` (the semilattice operation
 * internal to the topos). Example:
 *   space TALLY with fold "sum_f64"
 *)
and space_decl = {
  sd_name      : string;
  sd_world     : string option;
  sd_fold      : string option;(* the canonical fold name *)
  sd_loc       : location;
}

(* Explicit composition of reductions.
 *   reduction R = R1 . R2
 * R applies R2 first, then R1. *)
and reduction_compose_decl = {
  rcm_name : string;
  rcm_left : string;
  rcm_right : string;
  rcm_loc : location;
}

(* universal construction declaration. *)
and universal_decl = {
  uni_name : string;
  uni_f : string;
  uni_g : string;
  uni_loc : location;
}

(* A Lawvere-Tierney topology on a place.
 *
 * An LT topology on Omega is j: Omega -> Omega with three axioms:
 *   j(true) = true
 *   j(j(p)) = j(p)
 *   j(p and q) = j(p) and j(q)
 *
 * It determines a sub-topos (the sheaves for j) of the base topos.
 * In Yon, `topology j of P { ... }` registers j as an idempotent operation
 * that governs the "locality" of P. *)
and topology_decl = {
  tp_name : string;
  tp_of_place : string;
  tp_body : stmt list;
  tp_loc : location;
}

type program = top_decl list
