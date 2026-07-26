(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
/* parser.mly — Menhir grammar for Yon v0.3 surface syntax.
 *
 * Follows the BNF specification of yon-language-spec-v0-3.md §5.
 * LL(1) with small lookahead. Menhir handles the lookahead automatically.
 *
 * DESIGN NOTE — new syntax in TYPE position must be keyword-first.
 *   `expr` and `type_expr` overlap (both admit `Foo`, `Foo(...)`, ...). Any
 *   production that puts an `expr` at the START of a type (e.g. an infix
 *   `X same as Y` with X an expression) makes expr-lists and type_expr-lists
 *   indistinguishable in every comma context -> a fatal reduce/reduce conflict,
 *   and Menhir refuses to generate the parser. A leading keyword + delimiters
 *   (`Id(A,x,y)`, `Same(x,y)`, `El(c)`) lets the parser commit immediately and
 *   avoids the clash. This is a property of the grammar, not of one feature:
 *   design future type-level sugar keyword-first. */

%{
  open Surface_ast
  
  let mk_loc start_pos end_pos =
    { start_line = start_pos.Lexing.pos_lnum;
      start_col = start_pos.Lexing.pos_cnum - start_pos.Lexing.pos_bol;
      end_line = end_pos.Lexing.pos_lnum;
      end_col = end_pos.Lexing.pos_cnum - end_pos.Lexing.pos_bol;
      file = start_pos.Lexing.pos_fname; }

  (* Split a qualified name "a::b::c" into (module="a::b", name="c").
   * The name is the last segment; the module is everything before it. *)
  let split_qident (q : string) : string * string =
    let sep = "::" in
    match List.rev (Str.split_delim (Str.regexp_string sep) q) with
    | last :: rest -> (String.concat sep (List.rev rest), last)
    | [] -> ("", q)

  (* `recv.f(args)` dispatch on the case of the receiver head, the ML-like
   * convention shared by the corpus. An UPPERCASE head is a MODULE / namespace
   * (String, List, Wire, Space, ...): the call is the qualified function
   * `Module__f(args)`, the receiver is a prefix of the name, not a value. A
   * lowercase head is a VALUE — a place section, a stream/wire handle: the
   * receiver enters as the FIRST ARGUMENT, recv.f(args) = f(recv, args). That
   * second branch is the Yoneda reading (f composed with recv), and it is the
   * single representation, identical in statement and expression position — no
   * name mangling for values, no string-splitting downstream. *)
  let dot_is_module (obj : string) : bool =
    String.length obj > 0 && obj.[0] >= 'A' && obj.[0] <= 'Z'

  let dot_call_expr obj fld args loc =
    if dot_is_module obj then ECall (obj ^ "__" ^ fld, args, loc)
    else ECall (fld, EVar (obj, loc) :: args, loc)

  let dot_call_stmt obj fld args loc =
    if dot_is_module obj then SCall (obj ^ "__" ^ fld, args, loc)
    else SCall (fld, EVar (obj, loc) :: args, loc)

  (* support `by fun(...)` inline lambda in move
   * conversion/mapping. Lifting via Parser_state module (esposto). *)
  let lift_inline_lambda_to_fun = Parser_state.lift_inline_lambda_to_fun

  (* Infer the canonical fold name from the reduction name. Convention: a name
   * containing "Sum" -> "sum_f64", "Max" -> "max_f64", "Min" -> "min_f64".
   * Otherwise None. *)
  (* infer_fold_name was removed. It was a heuristic that, for reductions with
   * a crdt/sharded policy, inferred the fold name from the substring
   * "sum"/"max"/"min" in the name. That is categorically impure: the fold is a
   * property of the topos (space), not of the reduction. It is now declared
   * explicitly: space TALLY with fold "sum_f64". *)

  (* Builder for the geomorph declaration. Extracts the declared
   * categorical flags and rebuilds the AST declaration. *)
  let build_geom_morphism (name : string) (src_site : string)
                          (dst_site : string)
                          (items : geom_morphism_item_kind list)
                          (loc : location) : geom_morphism_decl =
    let pull = List.find_map
      (function GmItemPull p -> Some p | _ -> None) items in
    let push = List.find_map
      (function GmItemPush p -> Some p | _ -> None) items in
    let has_adj = List.exists
      (function GmItemAdjunction -> true | _ -> false) items in
    let f_star_ex = List.exists
      (function GmItemExactFStar -> true | _ -> false) items in
    let f_lower_ex = List.exists
      (function GmItemExactFLowerStar -> true | _ -> false) items in
    { gm_name = name; gm_on_error = None;
      gm_source_site = src_site;
      gm_target_site = dst_site;
      gm_pull = pull;
      gm_push = push;
      gm_adjunction = has_adj;
      gm_f_star_exact = f_star_ex;
      gm_f_lower_star_exact = f_lower_ex;
      gm_loc = loc }

  (* Whitelist of the canonical folds the runtime supports. Called on an
     explicit `fold "name"`; raises if the name is unknown. Only the runtime
     truly knows the supported folds, but the parser front-runs the diagnostic
     with a clear error instead of letting malformed MLIR through. *)
  let validate_fold_name (name : string) (loc_start : Lexing.position) : string =
    let known = [
      "sum_f64"; "max_f64"; "min_f64";
      "sum_i64"; "max_i64"; "min_i64";
      "sum_vec_f64"; "max_vec_f64"; "or_bitset"
    ] in
    if List.mem name known then name
    else
      failwith (Printf.sprintf
        "[parser P8 #86] line %d: fold name '%s' not recognized. Canonical folds: %s"
        loc_start.Lexing.pos_lnum
        name
        (String.concat ", " known))
%}

/* ─── Tokens ────────────────────────────────────────────────────────── */

/* Literals */
%token <float> NUM_LIT
%token <string> STR_LIT
%token <bool> BOOL_LIT
/* DUR_LIT (duration literals 100ms/5s) removed in v1.1 — see lexer.mll. */

/* Identifiers */
%token <string> IDENT
%token <string> QIDENT

/* Top-level keywords */
%token PLACE FUN MOVE VIEW REDUCTION OPERATION LET
%token SPACE
/* The BACKED token was removed (it was `space backed by reduction`). */
%token CELL
%token GEOM_MORPHISM PULL PUSH
%token PULLBACK PUSHOUT
%token TOPOLOGY
%token FUNCTORIAL
%token FUNCTOR
%token IMPORT
%token INTERNAL
%token LAW
%token USES
%token ALGEBRA
%token ERROR_KW
%token ON_ERROR
/* The tokens BACKED_BY/POL_DIRECT/POL_SHARDED/POL_PAXOS/POL_CRDT were removed:
 * they were distributed-policy keywords, replaced by geom_morphism +
 * space.with_fold. */
%token FOLD  /* explicit fold name, e.g. fold "sum_f64" */

/* First-class topos constructs. */
/* MORPHISM_KW (singular): keyword for a single morphism declaration inside a
 * topos `morphisms { }` block, and for the `on morphism N via M` clause. */
%token TOPOS_KW MORPHISM_KW TERMINAL_KW PROP_KW
%token MORPH_KW VIA_KW
%token NAT
%token ADJUNCTION_KW EXACT_KW
(* OVER is already declared below in the WHEN/SEQUENCE token group *)

/* Type-related */
%token OF IN TO STREAM IS NOT BY FROM WITH UNIFIES REQUIRES
%token WIRE
%token SPAWN PROMOTE PARALLEL
%token COMPOSE
%token HCOMP
%token COMP
%token SHARE RESOLVES

/* Stream back-pressure modifiers (BUFFER/DROP) removed in v1.1 — were inert. */

/* Control flow */
%token WHEN OTHERWISE FOR EVERY EACH HERE SEQUENCE OVER REPEAT AT MOST TIMES
%token FORCES
%token FOREVER SCOPE RETURN PRODUCE EMIT DOTARROW DROP
/* Expression-level if/then/else + iter/while */
%token IF_KW THEN_KW ELSE_KW
%token ITER_KW DO_KW WHILE_KW

/* Statement keywords */
%token HOLDS

/* Boolean operators */
/* ALL removed in v1.1 (EAll "all P where c" dropped — condition was inert). */
%token AND OR WHERE
/* The symbols &&/|| as aliases for and/or. */
%token AMPAMP PIPEPIPE
/* ! as an alias for unary `not`.
 * `=>` as implies (Heyting on Heyt args, classical elsewhere). */
%token BANG FATARROW
%token ARROW       /* tipo funzione T -> U */
/* Classic bitwise ops on number (cast f64->i64). */
%token AMP CARET TILDE
/* intuitionistic logic symbols with a `?` tag.
 * Lowering: dispatch su algebra Heyt (h_and/h_or/h_not/h_imp). */
%token AMPAMPQ PIPEPIPEQ BANGQ FATARROWQ
/* Intuitionistic bitwise ops with the `?` tag. They lower to topos.heyt_int_*
 * ops on !topos.heyt_int<64> carrying a (value, mask) pair (see emit_mlir). */
%token AMPQ PIPEQ CARETQ TILDEQ

/* View keywords */
%token SHOW AS

/* Mapping kinds */
%token MAPS CONVERTS AGGREGATES

/* Multi-shot */
%token MULTI_SHOT

/* Function effect signature */
%token VISITS

/* Heyting tri-value */
%token PRESENT ABSENT UNKNOWN

/* HoTT / dependent types */
/* place-as-object block form: `this` heads the coproduct clause,
   `:U` unions arms, `:=` binds a record field. */
%token THIS COLON_U COLONEQ
%token TYPE_KW PI SIGMA ID REFL PAIR FST SND IND_PATH
%token EL QUOTE EL_MATCH
%token HIT_ELIM LBRACKET RBRACKET
%token ATSIGN I0 I1 PLAM PATHP HIT_KW
/* Metonymic surface sugar (journey metaphor): desugar to the cubical primitives. */
%token BACK CARRY ALONG THROUGH
%token PLUSPLUS          /* p ++ q = concat */
%token LRARROW           /* f <=> g = equivalence */
%token MATCH_KW          /* match x { ctor => .. } = hit_elim with synthesized motive */
%token SAME CLEAR        /* `Same(X, Y)` = Id(A,X,Y) (A inferred); `clear` = the surface refl */
%token INDUCT            /* `induct(d, p)` = ind_path(0, d, p): J with the operational placeholder motive */
/* heyt_int<N> type keyword. */
%token HEYT_INT_KW
%token <int> TYPE_LEVEL

/* Operators and punctuation */
%token PLUS MINUS STAR SLASH PERCENT
%token LT GT LEQ GEQ EQ EQEQ NEQ
%token PIPE DOT COMMA COLON
%token PIPEGT                          (* pipe forward `|>` *)
%token LPAREN RPAREN LBRACE RBRACE

%token EOF

/* ─── Precedence and associativity ─────────────────────────────────── */
/* These declarations help Menhir resolve shift/reduce conflicts
   in expressions. Lower entries bind tighter. */

/* Precedence for the `all X where C` form: the condition is greedy,
 * consuming as many AND/OR/comparison operators as possible. We give
 * the implicit "end of where-condition" the lowest precedence so that
 * any operator shift wins over reduction. */
%nonassoc LOWEST
%left PIPEGT             (* pipe forward, left-assoc, prio bassa *)
%right FATARROW FATARROWQ
%left OR PIPEPIPE PIPEPIPEQ
%left AND AMPAMP AMPAMPQ
%left LT GT LEQ GEQ EQEQ NEQ
%nonassoc LRARROW        /* f <=> g = equivalence, non-associative */
%left PIPE
%left PIPEQ
%left CARET CARETQ
%left AMP AMPQ
%left PLUS MINUS
%left PLUSPLUS           /* p ++ q = concat, left-assoc */
%left STAR SLASH PERCENT
%nonassoc UMINUS
%nonassoc UNOT
%nonassoc UTILDE
%left THROUGH             /* p through f = ap(f, p), binds tight */
%left ATSIGN              /* path application p @ i, binds tight */
%nonassoc PREFIX_APP      /* metonymic prefixes (stay/back/span/carry) bind TIGHTER
                             than @, so `back X @ I0` is always `(back X) @ I0` and
                             never `back (X @ I0)` — deterministic, not menhir-arbitrary */

/* Precedence for IS pattern test. */
%nonassoc IS

/* Precedence for dangling-when. */
%nonassoc NO_ELIF
%nonassoc WHEN


/* ─── Start symbol ──────────────────────────────────────────────────── */

%start <Surface_ast.program> program

%%

/* ─── Program ───────────────────────────────────────────────────────── */

program:
  | decls = list(top_decl) EOF        { decls }

top_decl:
  | fnd = functor_decl                { fnd }
  | IMPORT s = STR_LIT                 { TopImport (s, mk_loc $startpos $endpos) }
  | IMPORT q = QIDENT                  { let (m,n) = split_qident q in
                                         TopImportSym (m, n, None, mk_loc $startpos $endpos) }
  | IMPORT q = QIDENT AS a = IDENT     { let (m,n) = split_qident q in
                                         TopImportSym (m, n, Some a, mk_loc $startpos $endpos) }
  | IMPORT q = QIDENT FROM sp = IDENT  { let (m,n) = split_qident q in
                                         TopImportFrom (m, n, sp, mk_loc $startpos $endpos) }
  | t = place_decl                    { t }
  | fd = fun_decl                     { TopFun fd }
  | md = move_decl                    { TopMove md }
  | vd = view_decl                    { TopView vd }
  | rd = reduction_decl               { TopReduction rd }
  | od = standalone_op                { TopOperation od }
  | gm = geom_morphism_decl           { TopGeomMorphism gm }
  | pb = pullback_decl                { TopPullback pb }
  | po = pushout_decl                 { TopPushout po }
  | tp = topology_decl                { TopTopology tp }
  | ld = top_let                      { ld }

  | td = topos_decl                   { TopTopos td }
  | mp = morph_decl                   { TopMorph mp }
  | nt = nat_transform_decl           { TopNatTransform nt }

(* topos as a first-class declaration.
 *
 * Syntax:
 *   topos Account where {
 *     objects { ... place_decl ... }
 *     terminal Unit                       (* optional *)
 *     morphisms { ... operations ... }    (* optional *)
 *     prop is_overdrawn(s: State): proposition = s.balance < 0
 *     prop is_positive(s: State): proposition = s.balance > 0
 *   }
 *
 * The props are subobject classifiers: given one or more objects of the topos,
 * a `prop` is a function into the classifier Omega (the proposition type). It
 * desugars internally to a fun_decl with return type proposition, but
 * syntactically it signals the categorical intent (a sub-object versus an
 * arbitrary function). *)
(* v1.1 topos-per-space: a topos no longer declares `objects { }`, nor `at
 * Space`, nor `in World` in the surface. The objects are inferred from the
 * filesystem (one source file per object) by a separate agent; the at/in
 * bindings are likewise inferred. The parser therefore produces a well-formed
 * topos_decl with empty objects and no at/in: tp_objects = [], tp_at_space =
 * None, tp_world = None. The `morphisms`, `terminal` and `props` blocks stay. *)
topos_decl:
  | TOPOS_KW name = IDENT
    WHERE LBRACE
      term_opt = topos_terminal_opt
      morph_opt = topos_morphisms_opt
      props = list(topos_prop_decl)
    RBRACE
    { { tp_name = name;
        tp_world = None;            (* inferred from the filesystem *)
        tp_at_space = None;         (* inferred from the filesystem *)
        tp_objects = [];            (* inferred from the filesystem *)
        tp_terminal = term_opt;
        tp_morphisms = morph_opt;
        tp_props = props;
        tp_loc = mk_loc $startpos $endpos } }

(* v1.1 topos-per-space: `topos_at_opt` (the `at <SPACE>` annotation) was
 * removed — the residence space is now inferred from the filesystem, so the
 * topos surface no longer carries it. *)

(* prop declaration as a subobject classifier.
 *   prop NAME(p1: T1, ..., pn: Tn): proposition = EXPR
 *
 * The return type is always `proposition`, but it is explicit in the syntax
 * for readability. EXPR is evaluated in the tri-value Heyting algebra
 * (HPresent/HAbsent/HUnknown) via prop_eval. *)
topos_prop_decl:
  | PROP_KW name = IDENT
    LPAREN params = param_list RPAREN
    COLON _ret = type_expr
    EQ body = expr
    { { pr_name = name;
        pr_params = List.map (fun p -> (p.param_name, p.param_ty)) params;
        pr_body_opt = Some body;
        pr_loc = mk_loc $startpos $endpos } }
  (* Abstract variant: signature only, no body. *)
  | PROP_KW name = IDENT
    LPAREN params = param_list RPAREN
    COLON _ret = type_expr
    { { pr_name = name;
        pr_params = List.map (fun p -> (p.param_name, p.param_ty)) params;
        pr_body_opt = None;
        pr_loc = mk_loc $startpos $endpos } }

(* v1.1 topos-per-space: `topos_world_opt` (the `in <World>` annotation) was
 * removed — the world is now inferred from the filesystem. The IN token stays
 * declared and is still used elsewhere (`place P in W`, `new P in Space`). *)

topos_terminal_opt:
  |                            { None }
  | TERMINAL_KW t = IDENT      { Some t }

(* v1.1: the `morphisms { }` block now declares its members with the singular
 * `morphism` keyword (morphism_decl), not the place-level `operation`. The
 * result is still a list of operation_decl, so the rest of the compiler is
 * unchanged. *)
topos_morphisms_opt:
  |                                                 { [] }
  | ops = nonempty_list(morphism_decl)              { ops }

(* morph_decl.
 *
 * Syntax:
 *   morph LiftEU from Account to AccountEU {
 *     on object(s: State): EUState = ...
 *     on morphism deposit via deposit_eu
 *     on morphism withdraw via withdraw_eu
 *   }
 *
 * A morph is a morphism in the category of topoi (that is, a functor). Future
 * editions may add other kinds of morphisms (the geometric morphism,
 * geomorph, is already separate; one could imagine lex_morph,
 * regular_morph, etale_morph).
 *
 * The two aspects (on object and on morphism) are both optional and
 * orthogonal. They may appear in any order in the body. *)
morph_decl:
  | MORPH_KW name = IDENT FROM src = IDENT TO tgt = IDENT
    LBRACE items = list(morph_item) RBRACE
    { let on_obj = List.find_map
        (function MItemOnObject fd -> Some fd | _ -> None) items in
      let mm = List.filter_map
        (function MItemOnMorphism (a, b) -> Some (a, b) | _ -> None) items in
      { mp_name = name; mp_on_error = None;
        mp_source = src;
        mp_target = tgt;
        mp_on_object = on_obj;
        mp_on_morphism_map = mm;
        mp_loc = mk_loc $startpos $endpos } }

morph_item:
  (* `on object` / `on morphism` are two-word contextual phrases, not
   * reserved keywords: the parser reads two identifiers and validates
   * the strings, the same scheme used by the reduction `on` clause.
   * This keeps `on`, `object` and `morphism` free as user names. *)
  | tag = IDENT kind = IDENT
    LPAREN params = param_list RPAREN
    ret = option(return_type_decl)
    LBRACE body = list(stmt) RBRACE
    { if tag <> "on" || kind <> "object" then
        failwith ("expected 'on object' clause in morph body, got '"
                  ^ tag ^ " " ^ kind ^ "'");
      (* on object uses an inline syntax without a redundant `fun` keyword. We
       * synthesize a fun_decl with a name derived from the morph context; the
       * real name is patched by the desugar (mp_name + "__on_object"). *)
      let fd = { fn_name = "__on_object";
                 fn_type_params = [];
                 fn_params = params;
                 fn_return = ret;
                 fn_on_error = None; fn_visits = []; fn_internal = false;
                 fn_body = body;
                 fn_loc = mk_loc $startpos $endpos } in
      MItemOnObject fd }
  (* An inline lambda as the body. Syntax:
   * `on object: fun(s: State): USDState => expr`. Equivalent to the block
   * { return expr }. *)
  | tag = IDENT kind = IDENT COLON FUN
    LPAREN params = param_list RPAREN
    ret = option(return_type_decl)
    FATARROW body_expr = expr
    { if tag <> "on" || kind <> "object" then
        failwith ("expected 'on object' clause in morph body, got '"
                  ^ tag ^ " " ^ kind ^ "'");
      let loc = mk_loc $startpos $endpos in
      let fd = { fn_name = "__on_object";
                 fn_type_params = [];
                 fn_params = params;
                 fn_return = ret;
                 fn_on_error = None; fn_visits = []; fn_internal = false;
                 fn_body = [SReturn (body_expr, loc)];
                 fn_loc = loc } in
      MItemOnObject fd }
  (* v1.1: `morphism` is now a keyword (MORPHISM_KW), so the `on morphism N via
   * M` clause consumes the keyword directly instead of reading it as an IDENT
   * with a string check. `on` stays a plain IDENT (it is NOT a keyword). *)
  | tag = IDENT MORPHISM_KW src_op = IDENT VIA_KW tgt_op = IDENT
    { if tag <> "on" then
        failwith ("expected 'on morphism' clause in morph body, got '"
                  ^ tag ^ " morphism'");
      MItemOnMorphism (src_op, tgt_op) }

(* natural transformation.
 *
 * Syntax:
 *   nat transform Upgrade from LiftEU_v1 to LiftEU_v2 {
 *     for each State by upgrade_state
 *     for each USDState by upgrade_usd
 *   }
 *
 * Each binding `for each X by Y` declares that the component eta_X of the
 * naturality is realized by the fun (or reduction clause of the same name) Y.
 * Y must exist in scope (validated by the type checker). *)
(* `nat transform t from F to G { for each X by fnX }` — `nat transform`
 * is a two-word contextual phrase, not a reserved keyword pair: `nat`
 * and `transform` stay free as user identifiers. *)
nat_transform_decl:
  | NAT kind = IDENT name = IDENT FROM src = IDENT TO tgt = IDENT
    LBRACE bindings = list(nat_transform_binding) RBRACE
    { if kind <> "transform" then
        failwith ("expected 'nat transform' declaration, got 'nat " ^ kind ^ "'");
      { nt_name = name; nt_on_error = None;
        nt_source_morph = src;
        nt_target_morph = tgt;
        nt_components = [];
        nt_via_bindings = bindings;
        nt_loc = mk_loc $startpos $endpos } }

nat_transform_binding:
  | FOR EACH obj = IDENT BY tgt = IDENT
    { (obj, tgt) }

(* Lawvere-Tierney topology
 *
 *   topology j of P {
 *     ...   // body that defines j: Omega -> Omega
 *   }
 *)
topology_decl:
  | TOPOLOGY name = IDENT OF of_place = IDENT
    LBRACE body = list(stmt) RBRACE
    { { tp_name = name; tp_of_place = of_place;
        tp_body = body;
        tp_loc = mk_loc $startpos $endpos } }

(* pullback / pushout of a place via the universal property.
 *
 *   place P = pullback(f, g)
 *   place P = pushout(f, g)
 *
 * f and g are names of already-declared moves or functions. P is the name
 * of the resulting place. *)
pullback_decl:
  | PLACE name = IDENT EQ PULLBACK LPAREN f = IDENT COMMA g = IDENT RPAREN
    { { uni_name = name; uni_f = f; uni_g = g;
        uni_loc = mk_loc $startpos $endpos } }

pushout_decl:
  | PLACE name = IDENT EQ PUSHOUT LPAREN f = IDENT COMMA g = IDENT RPAREN
    { { uni_name = name; uni_f = f; uni_g = g;
        uni_loc = mk_loc $startpos $endpos } }

(* Geometric morphism as a first-class construct.
 *
 *   geomorph F from SiteA to SiteB {
 *     pull(x: TypeFromB): TypeInA { ... }
 *     push(x: TypeFromA): TypeInB { ... }
 *   }
 *)
geom_morphism_decl:
  | GEOM_MORPHISM name = IDENT
    FROM src_site = IDENT TO dst_site = IDENT
    LBRACE items = list(geom_morphism_item) RBRACE
    { build_geom_morphism name src_site dst_site items
        (mk_loc $startpos $endpos) }

geom_morphism_item:
  | PULL LPAREN params = param_list RPAREN
    ret = option(return_type_decl)
    LBRACE body = list(stmt) RBRACE
    { GmItemPull { fn_name = "pull";
                   fn_type_params = [];
                   fn_params = params;
                   fn_return = ret;
                   fn_on_error = None; fn_visits = []; fn_internal = false;
                   fn_body = body;
                   fn_loc = mk_loc $startpos $endpos } }
  | PUSH LPAREN params = param_list RPAREN
    ret = option(return_type_decl)
    LBRACE body = list(stmt) RBRACE
    { GmItemPush { fn_name = "push";
                   fn_type_params = [];
                   fn_params = params;
                   fn_return = ret;
                   fn_on_error = None; fn_visits = []; fn_internal = false;
                   fn_body = body;
                   fn_loc = mk_loc $startpos $endpos } }
  (* Categorical clauses declaring properties of the geometric morphism. The
     runtime reads them to derive the coordination shape. *)
  | ADJUNCTION_KW                                  { GmItemAdjunction }
  | EXACT_KW PULL                                   { GmItemExactFStar }
  | EXACT_KW PUSH                                   { GmItemExactFLowerStar }

top_let:
  | LET name = IDENT HOLDS e = expr
    { TopLet (name, e, mk_loc $startpos $endpos) }

/* ─── Place declaration ─────────────────────────────────────────────── */

%inline place_kw:
  | PLACE     { false }
  | ERROR_KW  { true }   /* `error E { ... }` = sugar: a place marked is_error */

(* `place Number<64>` (numeric width, precedent heyting<64>) and
   `place Box<T>` (IDENT generics) share the `<`: ONE nonterminal keeps the
   grammar LR(1)-clean (two consecutive nullable `<`-starting nonterminals
   would conflict). Returns (width, tparams). *)
place_params:
  | (* empty *)                                        { (None, []) }
  | LT n = NUM_LIT GT                                  { (Some (int_of_float n), []) }
  | LT ids = separated_nonempty_list(COMMA, IDENT) GT  { (None, ids) }

(* `place Number is number { }` — the fusion clause: the place is the declared
   face of that PRIMITIVE CODE (is <prim>, not is <carrier>: carrier names are
   ambiguous — f64 realizes four codes — while the prim name keys prim_carrier,
   the one source of truth). A primitive is the place whose carrier is
   axiomatic instead of derived: the leaf of the carrier functor's recursion. *)
is_fusion_clause:
  | IS c = IDENT  { c }

place_decl:
  | is_err = place_kw name = IDENT
    wp = place_params
    fusion = option(is_fusion_clause)
    over = option(over_clause)
    oerr = option(on_error_clause)
    LBRACE mv = place_member_list RBRACE
    { let (members, variants, clauses) = mv in
      (* ONE production: a place, with or without arms; `error` is the same
         production marked. The canonical clauses may be written in the header
         (deprecated synonym) or as body lines (stage 4); the two merge here
         and a duplicate is rejected. *)
      let merge what header body =
        match header, body with
        | Some _, Some _ ->
            failwith ("place '" ^ name ^ "': " ^ what
                      ^ " declared both in the header and in the body")
        | Some x, None | None, Some x -> Some x
        | None, None -> None in
      let fold_clause what sel =
        List.fold_left (fun acc c ->
          match sel c with
          | None -> acc
          | Some x ->
              (match acc with
               | Some _ -> failwith ("place '" ^ name ^ "': " ^ what
                                     ^ " declared twice in the body")
               | None -> Some x)) None clauses in
      let b_over = fold_clause "over" (function PcOver x -> Some x | _ -> None) in
      let b_sub  = fold_clause "subcontains" (function PcSubcontains x -> Some x | _ -> None) in
      let b_oerr = fold_clause "on error" (function PcOnError x -> Some x | _ -> None) in
      let over = merge "over" over b_over in
      let ext  = b_sub in   (* the mono is a body clause only: this < B *)
      let oerr = merge "on error" oerr b_oerr in
      if is_err && (over <> None || oerr <> None) then
        failwith ("error '" ^ name ^ "': an error place takes only "
                  ^ "subcontains (no over / on error)");
      if is_err && variants <> [] then
        failwith ("error '" ^ name ^ "': an error place declares fields, "
                  ^ "not `this >` arms");
      let (width, tparams) = wp in
      (* collision fence at the SOURCE: the prelude owns its four names. *)
      (if List.mem name ["Number"; "Text"; "Boolean"; "Unit"]
          && fusion = None then
         failwith (Printf.sprintf
           "place %s collides with the prelude place of the same name: the             prelude owns it (rename yours)" name));
      TopPlace { pd_name = name;
                 pd_type_params = tparams;
                 pd_fusion = fusion;
                 pd_width = width;
                 pd_arms = variants;
                 pd_world = "__INFER";
                 pd_members = members;
                 pd_over = over;
                 pd_laws = List.filter_map
                   (function FoLaw l -> Some l | _ -> None) members;
                 pd_subcontains = ext;
                 pd_is_error = is_err;
                 pd_on_error = oerr;
                 pd_loc = mk_loc $startpos $endpos } }
(* Slice category: a place over X. The inhabitants of the place carry a
 * canonical reference to an instance of X. *)
over_clause:
  | OVER base = IDENT  { base }

(* place P ... on error E — an error morphism P -> E. `on` is read as a
 * plain identifier and validated contextually, the same scheme used by
 * the morph body clauses: `on` stays free as a user name. *)
on_error_clause:
  | ON_ERROR e = IDENT  { e }

field_or_cell:
  | f = field_decl                          { FoField f }
  | c = cell_decl                           { FoCell c }

(* The body of a place: it groups its data members (fields, cells) and its
   behaviour (the arrows). Data members stay in pd_members; each arrow is
   emitted as a synthetic top-level declaration via Parser_state, so the rest
   of the front-end sees it as an ordinary top-level arrow while the source
   keeps it inside the place. *)
place_member_list:
  | items = list(place_member)
    { let members =
        List.filter_map (function PbiMember fc -> Some fc | _ -> None) items in
      let variants =
        List.concat_map (function PbiVariants vs -> vs | _ -> []) items in
      let clauses =
        List.filter_map (function PbiClause c -> Some c | _ -> None) items in
      (members, variants, clauses) }

(* `this > A :U B :U ...` — the coproduct clause. It names the arms this place
   is the sum of; each arm is a variant (an existing place, optionally with a
   payload). Reuses the `variant` grammar shared with `inductive`. *)
variant_clause:
  | THIS GT vs = separated_nonempty_list(COLON_U, arm)   { vs }

place_member:
  | fc = field_or_cell                    { PbiMember fc }
  | vs = variant_clause                   { PbiVariants vs }
  /* stage 5 (fork 3 = inline): an operation is a mediated arrow, listed with
     the other arrows; a law is an algebraic obligation on the list. The
     `with effects` block dies — effectfulness is a theorem of the list. */
  | od = operation_decl                   { PbiMember (FoOp od) }
  | LAW l = IDENT                         { PbiMember (FoLaw l) }
  /* stage 4: the canonical clauses as body lines. `on` stays a bare IDENT
     (the header's contextual-keyword tactic), validated in the action. */
  | OVER base = IDENT                     { PbiClause (PcOver base) }
  /* the mono as containment arrow: `this < B` = this ⊂ B, a sub-object of B
     (mirror of the coproduct's `this > arms` = this ⊃ arms). Absorbs the
     retired `subcontains` word; the AST clause is unchanged (pure respelling). */
  | THIS LT base = IDENT                  { PbiClause (PcSubcontains base) }
  | ON_ERROR e = IDENT
    { PbiClause (PcOnError e) }
  | fd = fun_decl                         { Parser_state.push_decl (TopFun fd); PbiArrow }
  | md = move_decl                        { Parser_state.push_decl (TopMove md); PbiArrow }
  | fct = functor_decl                    { Parser_state.push_decl fct; PbiArrow }
  | gm = geom_morphism_decl               { Parser_state.push_decl (TopGeomMorphism gm); PbiArrow }
  | vd = view_decl                        { Parser_state.push_decl (TopView vd); PbiArrow }
  | rd = reduction_decl                   { Parser_state.push_decl (TopReduction rd); PbiArrow }
  | mp = morph_decl                       { Parser_state.push_decl (TopMorph mp); PbiArrow }
  | nt = nat_transform_decl               { Parser_state.push_decl (TopNatTransform nt); PbiArrow }


field_decl:
  | name = IDENT t = type_expr
    { { fd_name = name; fd_ty = t;
        fd_loc = mk_loc $startpos $endpos } }
  (* `side := number` — the explicit "has a field" binder. Same field, the
     `:=` just makes the product component read as a definition and removes any
     ambiguity with a bare arm name. *)
  | name = IDENT COLONEQ t = type_expr
    { { fd_name = name; fd_ty = t;
        fd_loc = mk_loc $startpos $endpos } }

(* A custom cell inside a place.
 *   cell <name> from <src> to <tgt>
 *
 * src and tgt are expressions denoting lower-dimensional cells. *)
cell_decl:
  | CELL name = IDENT FROM src = expr TO tgt = expr
    { { cell_name = name; cell_src = src; cell_tgt = tgt;
        cell_loc = mk_loc $startpos $endpos } }

operation_decl:
  (* `) on error E : T` — Antonio's third way: the clause sits BEFORE the
     return type, and the `:` after E disambiguates (no place member can
     start with `:`). Return type MANDATORY with the clause. *)
  | OPERATION name = IDENT LPAREN params = param_list RPAREN
    oerr = option(on_error_clause)
    ret = option(return_type_decl)
    alg = option(uses_algebra_clause)
    { (if oerr <> None && ret = None then
         failwith (Printf.sprintf
           "operation %s: `on error` requires an explicit return type \
            (`) on error E : T`)" name));
      { op_name = name; op_params = params; op_return = ret;
        op_on_error = oerr;
        op_functorial = false;
        op_algebra = alg;
        op_loc = mk_loc $startpos $endpos } }
  | FUNCTORIAL OPERATION name = IDENT LPAREN params = param_list RPAREN
    ret = option(return_type_decl)
    (* A cross-world functorial operation. The operation is lifted
     * automatically along world morphisms via the Yoneda lifting. *)
    { { op_name = name; op_params = params; op_return = ret; op_on_error = None;
        op_functorial = true;
        op_algebra = None;
        op_loc = mk_loc $startpos $endpos } }

(* v1.1: a topos's morphism declaration. Mirrors operation_decl but uses the
 * `morphism` keyword (MORPHISM_KW) instead of `operation`, and produces the
 * SAME operation_decl record (op_functorial = false, op_algebra = None). This
 * keeps `operation` for place members and `morphism` for topos morphisms,
 * while the downstream compiler keeps seeing operation_decl. *)
morphism_decl:
  | MORPHISM_KW name = IDENT LPAREN params = param_list RPAREN
    ret = option(return_type_decl)
    { { op_name = name; op_params = params; op_return = ret; op_on_error = None;
        op_functorial = false;
        op_algebra = None;
        op_loc = mk_loc $startpos $endpos } }
  (* `functorial morphism` — cross-world functorial morphism, lifted along
     world morphisms via Yoneda. Mirrors `functorial operation`. *)
  | FUNCTORIAL MORPHISM_KW name = IDENT LPAREN params = param_list RPAREN
    ret = option(return_type_decl)
    { { op_name = name; op_params = params; op_return = ret; op_on_error = None;
        op_functorial = true;
        op_algebra = None;
        op_loc = mk_loc $startpos $endpos } }

(* operation uses algebra <Name> — instantiates a catalog algebra *)
uses_algebra_clause:
  | USES ALGEBRA name = IDENT  { name }

(* A top-level functor as a named declaration.
 * `functor F(params) from W to V (law ...)* { body }` is sugar for a function
 * F that returns the corresponding functor-lambda. This reuses all the
 * (syntactic and semantic) law checking already done on EFunctorLam. *)
functor_decl:
  | FUNCTOR name = IDENT LPAREN params = separated_list(COMMA, lambda_param) RPAREN
    FROM from_w = IDENT TO to_w = IDENT
    laws = list(functor_law)
    LBRACE RETURN body = expr RBRACE
    { TopFunctor {
        ft_name = name; ft_on_error = None;
        ft_from_world = from_w;
        ft_to_world = to_w;
        ft_params = List.map (fun (n, t) -> (n, t)) params;
        ft_body = body;
        ft_laws = laws;
        ft_loc = mk_loc $startpos $endpos;
      } }

(* The functor laws declared on a functor-lambda. *)
functor_law:
  | LAW name = IDENT  { name }

standalone_op:
  | o = operation_decl                    { o }

return_type_decl:
  | COLON t = type_expr                   { t }

param_list:
  | items = separated_list(COMMA, param)  { items }

param:
  | name = IDENT COLON t = type_expr
    { { param_name = name; param_ty = t } }
  (* A parameter without an annotation becomes the marker TyUser "_", which
   * the infer_fun_signatures pre-pass resolves from the call sites. *)
  | name = IDENT
    { { param_name = name; param_ty = TyUser "_" } }

(* A lambda_param is a (string * ty) pair, not a record. Used only in the
   ELam constructor. *)
lambda_param:
  | name = IDENT COLON t = type_expr
    { (name, t) }
  | name = IDENT
    { (name, TyPrim "unknown") }

/* ─── Type expressions ──────────────────────────────────────────────── */

/* type_atom + arrow chain.
 * Syntax: T -> U -> V parses as T -> (U -> V) (right-associative). */
type_expr:
  | a = type_atom ARROW b = type_expr
    { TyArrow (a, b) }
  | a = type_atom
    { a }

type_atom:
  | TYPE_KW
    { TyUniverse 0 }
  | n = TYPE_LEVEL
    { TyUniverse n }
  | PI LPAREN x = IDENT COLON a = type_expr RPAREN DOT b = type_expr
    { TyPi (x, a, b) }
  | SIGMA LPAREN x = IDENT COLON a = type_expr RPAREN DOT b = type_expr
    { TySigma (x, a, b) }
  | ID LPAREN a = type_expr COMMA x = expr COMMA y = expr RPAREN
    { TyId (a, TyTermExpr x, TyTermExpr y) }
  (* `Same(X, Y)` = Id(A, X, Y), A inferred from the endpoints. Keyword-first
     (see header design note): the leading SAME + parens commit the parser, so
     no expr/type_expr clash. The carrier is a sentinel metavar resolved by
     Tycheck.elaborate_id_sugar. Pure sugar: same kernel Id, same rejection on
     a false equation. *)
  | SAME LPAREN x = expr COMMA y = expr RPAREN
    { TyId (TyMetaVar (-424242), TyTermExpr x, TyTermExpr y) }
  | PATHP LPAREN i = IDENT COMMA a = type_expr COMMA x = IDENT COMMA y = IDENT RPAREN
    { TyPathP ((i, a), TyTermExpr (EVar (x, mk_loc $startpos $endpos)), TyTermExpr (EVar (y, mk_loc $startpos $endpos))) }
  | EL LPAREN c = expr RPAREN
    { TyEl (TyTermExpr c) }   (* A1: c may be an APPLIED code El(Fam(x)), not just a bare name *)
  (* Type application at use: `Box<number>`, `HashMap<text, number>`. For now the
     arguments are accepted (readable annotations) and the type resolves to its
     base — the checker is monomorphic and the runtime carrier is uniform f64, so
     Box<number> and Box<text> share one layout. Precise per-instantiation
     element typing (a TyApp node + monomorphisation) is the next increment. *)
  | name = IDENT LT args = separated_nonempty_list(COMMA, type_atom) GT
    { (* The container types ARE generics: List<T>, Map<K,V>, Stream<T>
         canonicalize to their dedicated nodes (the retired spellings were
         `list of T`, `map of K to V`, `stream of T`). Wrong arity is an
         honest parse-time failure, not a silent TyApp. *)
      match name, args with
      | "List", [t] -> TyList t
      | "Map", [k; v] -> TyMap (k, v)
      | "Stream", [t] -> TyStream t
      | ("List" | "Map" | "Stream"), _ ->
          failwith (Printf.sprintf
            "%s expects %s type argument(s): List<T> | Map<K, V> | Stream<T>"
            name (if name = "Map" then "2" else "1"))
      | _ -> TyApp (name, args) }
  | name = IDENT
    { (* prelude fusion, canonicalized AT THE SOURCE: the capitalized face
         and its primitive code are one object; parsing them to one node
         means no comparator downstream can ever tell them apart (the same
         move as the String/text normalization in desugar, one layer up). *)
      match name with
      | "Number" -> TyPrim "number"
      | "Text" -> TyPrim "text"
      | "Boolean" -> TyPrim "boolean"
      | "Unit" -> TyPrim "unit"
      | ("number" | "text" | "boolean" | "unit") when
          not (let f = $startpos.Lexing.pos_fname in
               (* the prelude and the kernel corpus may speak the codes *)
               let has sub =
                 let ls = String.length sub and lf = String.length f in
                 let rec go i = i + ls <= lf
                   && (String.sub f i ls = sub || go (i + 1)) in
                 go 0 in
               has "prelude/") ->
          failwith (Printf.sprintf
            "type `%s` is the kernel code: write `%s` (the prelude place)"
            name (String.capitalize_ascii name))
      | _ -> TyUser name }
  | name = IDENT IN ids = ident_list
    { TyPrimIn (name, ids) }
  | first = IDENT PIPE rest = separated_nonempty_list(PIPE, variant)
    { TySum ({v_name = first; v_args = []} :: rest) }
  | name = IDENT LPAREN args = separated_list(COMMA, type_expr) RPAREN
    PIPE rest = separated_nonempty_list(PIPE, variant)
    { TySum ({v_name = name; v_args = args} :: rest) }
  | HEYT_INT_KW LT n = NUM_LIT GT
    { TyHeytInt (int_of_float n) }
  (* The move handle type "move from W1 to W2". Lets a move be passed as a
   * parameter. *)
  | MOVE FROM w1 = IDENT TO w2 = IDENT
    { TyMoveHandle (Some w1, Some w2) }
  (* tipo reduction handle
   * "reduction of P". Allows passing a reduction as a parameter. *)
  | REDUCTION OF p = IDENT
    { TyReductionHandle (Some p) }
  (* tipo morph handle
   * "morph from S1 to S2" (cross-Space natural transformation). *)
  | MORPH_KW FROM s1 = IDENT TO s2 = IDENT
    { TyMorphHandle (Some s1, Some s2) }
  (* The view handle type "view of P" (a representable functor). *)
  | VIEW OF p = IDENT
    { TyViewHandle (Some p) }
  | LPAREN t = type_expr RPAREN
    { t }
  (* Comprehension { x : A where P }: the subobject of A carved out by the
     mere-proposition fibre P (which may mention x). Desugars to the dependent
     pair Sigma(x:A). P, whose first projection is a mono exactly when P is a
     mere proposition. We use the WHERE keyword as separator rather than PIPE,
     because PIPE is already the sum-type separator (A | B | C) and reusing it
     here creates a genuine parse ambiguity. The fibre is written as a type
     (proposition-as-type, HoTT reading), keeping types and terms separated. *)
  | LBRACE x = IDENT COLON a = type_expr WHERE p = type_expr RBRACE
    { TySigma (x, a, p) }

hit_branch:
  | ctor = IDENT FATARROW v = expr { (ctor, PatVars [], v) }
  (* `Place as w =>` — classify-and-bind: `as` in the same trade it has in
     field patterns (bind to a name), applied to the whole section. *)
  | ctor = IDENT AS w = IDENT FATARROW v = expr { (ctor, PatWitness w, v) }
  (* the literals as patterns on the fused Boolean: `match b { true => ..,
     false => .. }` — they NAME the kernel arms tt/ff. *)
  | b = BOOL_LIT FATARROW v = expr { ((if b then "tt" else "ff"), PatVars [], v) }
  | ctor = IDENT LPAREN vars = separated_list(COMMA, IDENT) RPAREN FATARROW v = expr
    { (ctor, PatVars vars, v) }
  /* the co-mediatrice: field names bind projections BY NAME — the mirror of
     `.-> Cons { head 5 tail rest }`. `head` binds as itself, `head as h`
     renames. Unmentioned fields are discarded. */
  | ctor = IDENT LBRACE fs = list(pat_field) RBRACE FATARROW v = expr
    { (ctor, PatFields fs, v) }

pat_field:
  | f = IDENT              { (f, f) }
  | f = IDENT AS b = IDENT { (f, b) }


variant:
  | name = IDENT
    { { v_name = name; v_args = [] } }
  | name = IDENT LPAREN args = separated_list(COMMA, type_expr) RPAREN
    { { v_name = name; v_args = args } }

/* An arm of a `this >` clause. Same shape as a type-position variant, PLUS
   the fork-2 RESERVED SLOT: a path constructor puts an EQUALITY into the
   place, as data (`this > shift(nat, nat) : mk(a, b) = mk(a+1, b+1)`).
   The slot lives ONLY here (not in type-position sums, where the `:` tail
   would be ambiguous); enabling it requires the pinned path-over obligation
   in the kernel (the branch checked against PathP (i. P(loop@i)), Fase 2).
   Until then: a clean reject. */
arm:
  | v = variant  { v }
  | name = IDENT LPAREN separated_list(COMMA, type_expr) RPAREN
    COLON expr EQ expr
    { failwith ("path constructor '" ^ name ^ "' not yet enabled: a path "
                ^ "arm needs the pinned path-over obligation in the kernel") }
  | name = IDENT COLON expr EQ expr
    { failwith ("path constructor '" ^ name ^ "' not yet enabled: a path "
                ^ "arm needs the pinned path-over obligation in the kernel") }

(* A named sum type is a coproduct place: `place Tree { this > Leaf :U Node(Tree, Tree) }`
   (see place_decl, whose pd_arms carry the `this >` clause). The
   `variant` grammar above is shared with that clause; a constructor argument that
   names the type being defined (Tree) is a plain type_expr (TyUser "Tree"), so
   recursion is expressible. There is no separate `inductive`/`place X = ...` form. *)

(* stream_modifier / stream_mod_list removed in v1.1 (BUFFER/DROP were inert). *)

ident_list:
  | items = separated_nonempty_list(COMMA, IDENT)  { items }

/* ─── Function declaration ──────────────────────────────────────────── */

fun_decl:
  | internal = boption(INTERNAL) FUN name = IDENT
    tparams = type_params_opt
    LPAREN params = param_list RPAREN
    oerr = option(on_error_clause)
    ret = option(return_type_decl)
    visits = visits_clause
    LBRACE body = list(stmt) RBRACE
    { (* UNIFORM order across the arrow family: `) on error E : T` — after E
         comes `:`, which no other construct can start, so the clause is
         unambiguous in every host (the operation lesson). The return type is
         MANDATORY with `on error`: an arrow that can fail declares what it
         returns when it succeeds. *)
      (if oerr <> None && ret = None then
         failwith (Printf.sprintf
           "fun %s: `on error` requires an explicit return type \
            (`) on error E : T`)" name));
      { fn_name = name; fn_type_params = tparams; fn_params = params;
        fn_return = ret; fn_on_error = oerr;
        fn_visits = visits; fn_internal = internal;
        fn_body = body; fn_loc = mk_loc $startpos $endpos } }

/* Optional type parameters: <A>, <A, B>, or empty. */
type_params_opt:
  | (* empty *)                                   { [] }
  | LT names = separated_nonempty_list(COMMA, IDENT) GT
                                                  { names }

visits_clause:
  | (* empty *)                           { [] }
  | VISITS ids = ident_list               { ids }

/* ─── Move declaration ─────────────────────────────────────────────── */

move_decl:
  | MOVE name = IDENT FROM src = IDENT TO dst = IDENT
    caps = optional_requires
    LBRACE body = list(mapping_decl) RBRACE
    { { mv_name = name; mv_from = [src]; mv_to = Some dst; mv_on_error = None;
        mv_body = MoveMapping body;
        mv_policy = [];
        mv_requires_caps = caps;
        mv_loc = mk_loc $startpos $endpos } }
  | MOVE name = IDENT UNIFIES srcs = ident_list
    caps = optional_requires
    LBRACE body = merge_body RBRACE
    { { mv_name = name; mv_from = srcs; mv_to = None; mv_on_error = None;
        mv_body = MoveMerge body;
        mv_policy = [];
        mv_requires_caps = caps;
        mv_loc = mk_loc $startpos $endpos } }

(* optional `requires CAP1, CAP2` clause. *)
optional_requires:
  | /* empty */         { [] }
  | REQUIRES cs = separated_nonempty_list(COMMA, IDENT)  { cs }

mapping_decl:
  | src = IDENT MAPS TO dst = IDENT BY fn = IDENT
    { { m_from = src; m_kind = MapsTo; m_to = dst; m_by = fn;
        m_loc = mk_loc $startpos $endpos } }
  | src = IDENT CONVERTS TO dst = IDENT BY fn = IDENT
    { { m_from = src; m_kind = ConvertsTo; m_to = dst; m_by = fn;
        m_loc = mk_loc $startpos $endpos } }
  | src = IDENT AGGREGATES TO dst = IDENT BY fn = IDENT
    { { m_from = src; m_kind = AggregatesTo; m_to = dst; m_by = fn;
        m_loc = mk_loc $startpos $endpos } }
  (* An inline lambda in the BY clause. Lifted parser-side: the lambda becomes
   * a synthetic top-level function __by_inline_p_N, and that name is used as
   * m_by. *)
  | src = IDENT MAPS TO dst = IDENT BY FUN LPAREN
    params = separated_list(COMMA, lambda_param) RPAREN FATARROW body = expr
    { let loc = mk_loc $startpos $endpos in
      let name = lift_inline_lambda_to_fun params body loc in
      { m_from = src; m_kind = MapsTo; m_to = dst; m_by = name; m_loc = loc } }
  | src = IDENT CONVERTS TO dst = IDENT BY FUN LPAREN
    params = separated_list(COMMA, lambda_param) RPAREN FATARROW body = expr
    { let loc = mk_loc $startpos $endpos in
      let name = lift_inline_lambda_to_fun params body loc in
      { m_from = src; m_kind = ConvertsTo; m_to = dst; m_by = name; m_loc = loc } }
  | src = IDENT AGGREGATES TO dst = IDENT BY FUN LPAREN
    params = separated_list(COMMA, lambda_param) RPAREN FATARROW body = expr
    { let loc = mk_loc $startpos $endpos in
      let name = lift_inline_lambda_to_fun params body loc in
      { m_from = src; m_kind = AggregatesTo; m_to = dst; m_by = name; m_loc = loc } }

merge_body:
  | shares = option(share_clause)
    conflicts = list(conflict_clause)
    { { merge_shares = (match shares with Some s -> s | None -> []);
        merge_conflicts = conflicts;
        merge_loc = mk_loc $startpos $endpos } }

share_clause:
  | SHARE ids = ident_list                { ids }

(* `conflict on F resolves to fn` — `conflict on` is a two-word
 * contextual phrase, not a reserved keyword: both words stay free as
 * user identifiers. *)
conflict_clause:
  | tag = IDENT prep = IDENT field = IDENT RESOLVES TO fn = IDENT
    { if tag <> "conflict" || prep <> "on" then
        failwith ("expected 'conflict on' clause, got '"
                  ^ tag ^ " " ^ prep ^ "'");
      (field, fn) }

/* ─── View declaration ─────────────────────────────────────────────── */

view_decl:
  | VIEW name = IDENT OF p = IDENT
    LBRACE items = list(view_item) RBRACE
    { { vw_name = name; vw_of = p; vw_items = items; vw_on_error = None;
        vw_loc = mk_loc $startpos $endpos } }

view_item:
  | SHOW name = IDENT                            { VShowSimple name }
  | SHOW name = IDENT EQ e = expr                { VShowAs (name, e) }
  | SHOW name = IDENT AS lbl = STR_LIT           { VShowLabel (name, lbl) }

/* ─── Reduction declaration ────────────────────────────────────────── */

reduction_decl:
  | REDUCTION name = IDENT
    tp = loption(reduction_type_params)
    OF target = IDENT
    multi = boption(WITH_MULTI_SHOT)
    explicit_fold = fold_decl_opt
    LBRACE clauses = list(reduction_clause) RBRACE
    { (* No more distributed policy. The fold, if present, is explicit. The
       * cross-space semantics live in geom_morphism, not in the reduction. *)
      { rd_name = name; rd_of = target; rd_multi_shot = multi; rd_on_error = None;
        rd_clauses = clauses;
        rd_shot_ordering = OrdSequential;
        rd_type_params = tp;
        rd_fold_name = explicit_fold;
        rd_loc = mk_loc $startpos $endpos } }

(* The explicit keyword `fold "sum_f64"` declares the canonical fold. When
   present it takes precedence over the naming convention. *)
fold_decl_opt:
  |                          { None }
  | FOLD name = STR_LIT      { Some (validate_fold_name name $startpos(name)) }

(* reduction_policy_opt was removed: the keywords backed_by
 * direct|sharded|paxos|crdt no longer exist.
 * The distributed semantics lives entirely in geom_morphism. *)

(* The optional list of type parameters in angle brackets.
 *   reduction R<T1, T2> of P { ... } *)
reduction_type_params:
  | LT tps = separated_nonempty_list(COMMA, IDENT) GT  { tps }

%inline WITH_MULTI_SHOT:
  | WITH MULTI_SHOT { () }

reduction_clause:
  | rc = on_clause                        { rc }
  | LET name = IDENT HOLDS e = expr
    { RcLet (name, e, mk_loc $startpos $endpos) }

on_clause:
  | tag = IDENT name = IDENT LPAREN params = param_list RPAREN
    LBRACE body = list(stmt) RBRACE
    { if tag <> "on" then
        failwith ("expected 'on' keyword in reduction clause, got '" ^ tag ^ "'");
      RcOn (name, params, body, mk_loc $startpos $endpos) }

/* ─── Statements ───────────────────────────────────────────────────── */

stmt:
  | s = let_stmt                          { s }
  | s = assign_stmt                       { s }
  | s = return_stmt                       { s }
  | s = call_or_new_stmt                  { s }
  | s = when_stmt                         { s }
  | s = for_stmt                          { s }
  | s = in_seq_stmt                       { s }
  | s = repeat_stmt                       { s }
  | s = forever_stmt                      { s }
  | s = scope_stmt                        { s }
  | s = produce_stmt                      { s }
  | s = emit_stmt                         { s }
  | s = promote_stmt                      { s }
  | DROP sp = IDENT                       { SDrop (sp, mk_loc $startpos $endpos) }
  | s = iter_stmt                         { s }
  | s = while_stmt                        { s }
  | s = forces_stmt                       { s }

iter_stmt:
  | ITER_KW n = expr DO_KW LBRACE body = list(stmt) RBRACE
    { (* iter N do { body } — a bounded loop, always terminates.
       * Lowered to scf.for with upper bound N. *)
      SIter (n, body, mk_loc $startpos $endpos) }

while_stmt:
  | WHILE_KW c = expr DO_KW LBRACE body = list(stmt) RBRACE
    { (* while cond do { body } may not terminate.
       * Lowered to scf.while + scf.condition + scf.yield. *)
      SWhile (c, body, mk_loc $startpos $endpos) }

let_stmt:
  | LET name = IDENT HOLDS e = expr
    { SLet (name, e, mk_loc $startpos $endpos) }

assign_stmt:
  | lv = lvalue EQ e = expr
    { (* Reassignment (model A). `be x holds e` declares a mutable local once;
         `x = e` reassigns it (a same-scope re-`holds` is a compile error, the
         declare-once rule). The cell is promoted lazily: the first `=` on a
         name makes its `be` allocate a Space cell, reads go through it, `x = e`
         updates it. Snapshot semantics, no aliasing. *)
      SAssignBecomes (lv, e, mk_loc $startpos $endpos) }

lvalue:
  | x = IDENT                             { LVar x }
  | x = IDENT DOT f = IDENT               { LField (x, f) }

return_stmt:
  | RETURN e = expr                       { SReturn (e, mk_loc $startpos $endpos) }

call_or_new_stmt:
  | obj = IDENT DOT fld = IDENT LPAREN args = expr_list RPAREN
    { dot_call_stmt obj fld args (mk_loc $startpos $endpos) }
  | obj = IDENT DOT FOLD LPAREN args = expr_list RPAREN
    { dot_call_stmt obj "fold" args (mk_loc $startpos $endpos) }
  | obj = IDENT DOT PUSH LPAREN args = expr_list RPAREN
    { dot_call_stmt obj "push" args (mk_loc $startpos $endpos) }
  | name = IDENT LPAREN args = expr_list RPAREN
    { SCall (name, args, mk_loc $startpos $endpos) }
  | name = QIDENT LPAREN args = expr_list RPAREN
    { SCall (name, args, mk_loc $startpos $endpos) }   (* mod::fun(args) *)
  /* the mediatrice, statement position: same node, arrow-form surface. */
  | DOTARROW name = IDENT LBRACE fas = field_assign_list RBRACE
    { SNew (name, fas, mk_loc $startpos $endpos) }

forces_stmt:
  | FORCES stage = IDENT c = condition LBRACE body = list(stmt) RBRACE
    { SForces (stage, c, body, mk_loc $startpos $endpos) }

when_stmt:
  | WHEN c = condition LBRACE body = list(stmt) RBRACE
    rest = when_chain
    { let (elifs, other) = rest in
      SWhen (c, body, elifs, other, mk_loc $startpos $endpos) }

/* when_chain represents the optional sequence of WHEN-elifs and optional
 * OTHERWISE. We use explicit precedence to favor extending the chain
 * (longest match) rather than terminating it. */
when_chain:
  | /* empty */
    %prec NO_ELIF
    { ([], None) }
  | WHEN c = condition LBRACE body = list(stmt) RBRACE rest = when_chain
    { let (elifs, other) = rest in
      ((c, body) :: elifs, other) }
  | OTHERWISE LBRACE body = list(stmt) RBRACE
    { ([], Some body) }

for_stmt:
  | FOR EVERY x = IDENT IN e = expr WHEN HERE LBRACE body = list(stmt) RBRACE
    { SForEvery (ForWhenHere, x, e, body, mk_loc $startpos $endpos) }
  | FOR EVERY x = IDENT IN e = expr LBRACE body = list(stmt) RBRACE
    { SForEvery (ForParallel, x, e, body, mk_loc $startpos $endpos) }

in_seq_stmt:
  | IN SEQUENCE OVER x = IDENT IN e = expr LBRACE body = list(stmt) RBRACE
    { SInSequence (x, e, body, mk_loc $startpos $endpos) }

repeat_stmt:
  | REPEAT AT MOST n = NUM_LIT TIMES LBRACE body = list(stmt) RBRACE
    other = repeat_tail
    { SRepeat (int_of_float n, body, other, mk_loc $startpos $endpos) }

repeat_tail:
  | /* empty */
    { None }
  | OTHERWISE LBRACE body = list(stmt) RBRACE
    { Some body }

forever_stmt:
  | FOREVER LBRACE body = list(stmt) RBRACE
    { SForever (body, mk_loc $startpos $endpos) }

scope_stmt:
  | SCOPE name = IDENT LBRACE body = list(stmt) RBRACE
    { (* An always-true scope predicate is top in Omega, not a classical
         boolean. *)
      SScope (Some name, body,
              ELit (LitHeytPresent, dummy_loc),
              mk_loc $startpos $endpos) }
  | SCOPE LBRACE body = list(stmt) RBRACE
    { SScope (None, body,
              ELit (LitHeytPresent, dummy_loc),
              mk_loc $startpos $endpos) }

produce_stmt:
  | PRODUCE LBRACE body = list(stmt) RBRACE
    { SProduce (body, mk_loc $startpos $endpos) }

emit_stmt:
  | EMIT e = expr
    { SEmit (e, mk_loc $startpos $endpos) }

promote_stmt:
  | PROMOTE e = expr
    { SPromote (e, mk_loc $startpos $endpos) }

/* ─── Expressions ──────────────────────────────────────────────────── */

expr:
  | e1 = expr PLUS e2 = expr
    { EBinop (OpAdd, e1, e2, mk_loc $startpos $endpos) }
  (* Metonymic infix sugar: p ++ q = concat(p,q); f <=> g = equivalence with
     refl coherences (valid when f,g are definitional inverses); p through f =
     ap(f,p). Pure desugar to the cubical primitives. *)
  | e1 = expr PLUSPLUS e2 = expr
    { ECall ("concat", [e1; e2], mk_loc $startpos $endpos) }
  | f = expr LRARROW g = expr
    { let l = mk_loc $startpos $endpos in
      let refl_lam v = ELam ([(v, TyPrim "unknown")], ERefl (EVar (v, l), l), l) in
      ECall ("equiv", [f; g; refl_lam "a"; refl_lam "b"], l) }
  | p = expr THROUGH f = expr
    { ECall ("ap", [f; p], mk_loc $startpos $endpos) }
  | e1 = expr MINUS e2 = expr
    { EBinop (OpSub, e1, e2, mk_loc $startpos $endpos) }
  | e1 = expr STAR e2 = expr
    { EBinop (OpMul, e1, e2, mk_loc $startpos $endpos) }
  | e1 = expr SLASH e2 = expr
    { EBinop (OpDiv, e1, e2, mk_loc $startpos $endpos) }
  | e1 = expr PERCENT e2 = expr
    { EBinop (OpMod, e1, e2, mk_loc $startpos $endpos) }
  | e1 = expr LT e2 = expr
    { EBinop (OpLt, e1, e2, mk_loc $startpos $endpos) }
  | e1 = expr GT e2 = expr
    { EBinop (OpGt, e1, e2, mk_loc $startpos $endpos) }
  | e1 = expr LEQ e2 = expr
    { EBinop (OpLeq, e1, e2, mk_loc $startpos $endpos) }
  | e1 = expr GEQ e2 = expr
    { EBinop (OpGeq, e1, e2, mk_loc $startpos $endpos) }
  | e1 = expr EQEQ e2 = expr
    { EBinop (OpEq, e1, e2, mk_loc $startpos $endpos) }
  | e1 = expr NEQ e2 = expr
    { EBinop (OpNeq, e1, e2, mk_loc $startpos $endpos) }
  | e1 = expr AND e2 = expr
    { EBinop (OpAnd, e1, e2, mk_loc $startpos $endpos) }
  | e1 = expr AMPAMP e2 = expr
    { EBinop (OpAnd, e1, e2, mk_loc $startpos $endpos) }
  | e1 = expr OR e2 = expr
    { EBinop (OpOr, e1, e2, mk_loc $startpos $endpos) }
  | e1 = expr PIPEPIPE e2 = expr
    { EBinop (OpOr, e1, e2, mk_loc $startpos $endpos) }
  | e1 = expr FATARROW e2 = expr
    { (* implies `a => b`. Syntactic transformation: (not a) or b. *)
      let loc = mk_loc $startpos $endpos in
      EBinop (OpOr, ENot (e1, loc), e2, loc) }
  (* Pipe forward `a |> f(args)`. A post-parse syntactic transformation: pass
   * the LHS as the first argument of the RHS (which must be an ECall). *)
  | a = expr PIPEGT b = expr
    { match b with
      | ECall (name, args, _) ->
          ECall (name, a :: args, mk_loc $startpos $endpos)
      | EVar (name, _) ->
          ECall (name, [a], mk_loc $startpos $endpos)
      | _ -> failwith "[parser] pipe RHS must be a function call or a name"
    }
  | NOT e = expr %prec UNOT
    { ENot (e, mk_loc $startpos $endpos) }
  | BANG e = expr %prec UNOT
    { ENot (e, mk_loc $startpos $endpos) }
  | e1 = expr AMP e2 = expr
    { (* bitwise AND su number. *)
      ECall ("__band", [e1; e2], mk_loc $startpos $endpos) }
  | e1 = expr CARET e2 = expr
    { (* bitwise XOR su number. *)
      ECall ("__bxor", [e1; e2], mk_loc $startpos $endpos) }
  | e1 = expr PIPE e2 = expr
    { (* Classic bitwise OR on a number. The collision with TySum variants
       * (`A | B`) is only in type expressions, where value expressions do not
       * apply. *)
      ECall ("__bor", [e1; e2], mk_loc $startpos $endpos) }
  | TILDE e = expr %prec UTILDE
    { (* Unary bitwise NOT on a number. *)
      ECall ("__bnot", [e], mk_loc $startpos $endpos) }
  | e1 = expr AMPAMPQ e2 = expr
    { (* AND intuizionista (Heyting).
       * Lowering: __heyt_and(a, b) -> topos.heyt_and MLIR op. *)
      ECall ("__heyt_and", [e1; e2], mk_loc $startpos $endpos) }
  | e1 = expr PIPEPIPEQ e2 = expr
    { ECall ("__heyt_or", [e1; e2], mk_loc $startpos $endpos) }
  | e1 = expr FATARROWQ e2 = expr
    { ECall ("__heyt_imp", [e1; e2], mk_loc $startpos $endpos) }
  | BANGQ e = expr %prec UNOT
    { ECall ("__heyt_not", [e], mk_loc $startpos $endpos) }
  | e1 = expr AMPQ e2 = expr
    { (* Intuitionistic bitwise AND. Bit-by-bit semantics with Unknown-mask
       * propagation. *)
      ECall ("__heyt_int_and", [e1; e2], mk_loc $startpos $endpos) }
  | e1 = expr PIPEQ e2 = expr
    { ECall ("__heyt_int_or", [e1; e2], mk_loc $startpos $endpos) }
  | e1 = expr CARETQ e2 = expr
    { ECall ("__heyt_int_xor", [e1; e2], mk_loc $startpos $endpos) }
  | TILDEQ e = expr %prec UTILDE
    { ECall ("__heyt_int_not", [e], mk_loc $startpos $endpos) }
  (* The constructor heyt_int(value, mask). Lowers to an ECall of a
   * synthesized builtin. *)
  | HEYT_INT_KW LPAREN v = expr COMMA m = expr RPAREN
    { ECall ("__heyt_int_make", [v; m], mk_loc $startpos $endpos) }
  | HEYT_INT_KW LPAREN v = expr RPAREN
    { (* heyt_int(value): no mask means mask 0 (no Unknown bits) *)
      let loc = mk_loc $startpos $endpos in
      ECall ("__heyt_int_make", [v; ELit (LitNumber 0.0, loc)], loc) }
  | MINUS e = expr %prec UMINUS
    { EBinop (OpSub, ELit (LitNumber 0.0, dummy_loc), e, mk_loc $startpos $endpos) }
  | e = chained_expr                            { e }

(* method chaining.
 * `e.method(args)` itera su expr_atom, costruendo ECall(method, e :: args).
 * Tipico use: Seq.from_list(l).map(f).filter(p).fold(0, g). *)
chained_expr:
  | e = expr_atom                               { e }
  | recv = chained_expr DOT meth = IDENT LPAREN args = expr_list RPAREN
    { ECall (meth, recv :: args, mk_loc $startpos $endpos) }
  | recv = chained_expr DOT FOLD LPAREN args = expr_list RPAREN
    { ECall ("fold", recv :: args, mk_loc $startpos $endpos) }

expr_atom:
  | l = literal                                                       
    { ELit (l, mk_loc $startpos $endpos) }
  (* Inline lambda. Syntax: `fun(x: T, y: U) => expr` or `fun(x) => expr`.
   * Unannotated types receive TyPrim "unknown", to be resolved via HM. *)
  | FUN LPAREN params = separated_list(COMMA, lambda_param) RPAREN FATARROW
    LBRACE body = list(stmt) RBRACE
    { (* block-bodied inline lambda: lifted to a synthetic function,
         the expression's value is its name *)
      let loc = mk_loc $startpos $endpos in
      EVar (Parser_state.lift_inline_block_lambda_to_fun params body loc, loc) }
  | FUN LPAREN params = separated_list(COMMA, lambda_param) RPAREN FATARROW body = expr
    { ELam (params, body, mk_loc $startpos $endpos) }
  (* handle lambdas inline.
   * Categorical stratification preserved: the lambda has a dedicated tag
   * (move/reduction/morph), produces TyMoveHandle/etc.
   * Syntax:
   *   move(s: P1) => expr from P1 to P2
   *   reduction(acc, x) => expr of P
   *   morph(s: P_src) => expr from S1 to S2 *)
  | MOVE LPAREN params = separated_list(COMMA, lambda_param) RPAREN
    FATARROW body = expr FROM from_p = IDENT TO to_p = IDENT
    { EMoveLam (params, body, from_p, to_p, mk_loc $startpos $endpos) }
  | REDUCTION LPAREN params = separated_list(COMMA, lambda_param) RPAREN
    FATARROW body = expr OF of_p = IDENT
    { EReductionLam (params, body, of_p, mk_loc $startpos $endpos) }
  | MORPH_KW LPAREN params = separated_list(COMMA, lambda_param) RPAREN
    FATARROW body = expr FROM from_s = IDENT TO to_s = IDENT
    { EMorphLam (params, body, from_s, to_s, mk_loc $startpos $endpos) }
  | FUNCTOR LPAREN params = separated_list(COMMA, lambda_param) RPAREN
    FATARROW body = expr FROM from_w = IDENT TO to_w = IDENT
    laws = list(functor_law)
    { (* An anonymous first-class functor. Maps from world from_w to world
       * to_w. The declared functor laws (identity, composition) are checkable
       * by the compiler. *)
      EFunctorLam (params, body, from_w, to_w, laws, mk_loc $startpos $endpos) }
  (* EViewLam, an inline view lambda:
   *   view(s: P) => expr of P
   * Produces TyViewHandle (Some P). A single projection, unlike a top-level
   * view which can show several fields. *)
  | VIEW LPAREN params = separated_list(COMMA, lambda_param) RPAREN
    FATARROW body = expr OF of_p = IDENT
    { EViewLam (params, body, of_p, mk_loc $startpos $endpos) }
  (* Handle composition.
   * Syntax: `compose <h1> with <h2>` produces a composed handle.
   * Semantics: result(x) = h2(h1(x)). *)
  | COMPOSE h1 = expr_atom WITH h2 = expr_atom
    { EComposeWith (h1, h2, mk_loc $startpos $endpos) }
  | HCOMP ty_name = IDENT LBRACKET
      sides = separated_list(COMMA, hcomp_side) RBRACKET base = hcomp_base
    {
      let loc = mk_loc $startpos $endpos in
      let encoded_sides = List.map (fun (face_var, at_one, binder, body) ->
        let tag = if at_one then "__hcomp_side_i1" else "__hcomp_side_i0" in
        ECall (tag,
          [EVar (face_var, loc); EPathAbs (binder, body, loc)], loc)) sides in
      ECall ("__hcomp_surface",
        [EVar (ty_name, loc); ECall ("__hcomp_system", encoded_sides, loc); base],
        loc)
    }
  | COMP LPAREN line = expr RPAREN LBRACKET
      sides = separated_list(COMMA, hcomp_side) RBRACKET base = hcomp_base
    {
      let loc = mk_loc $startpos $endpos in
      let encoded_sides = List.map (fun (face_var, at_one, binder, body) ->
        let tag = if at_one then "__hcomp_side_i1" else "__hcomp_side_i0" in
        ECall (tag,
          [EVar (face_var, loc); EPathAbs (binder, body, loc)], loc)) sides in
      ECall ("__comp_surface",
        [line; ECall ("__hcomp_system", encoded_sides, loc); base], loc)
    }
  | PRESENT
    { ELit (LitHeytPresent, mk_loc $startpos $endpos) }
  | ABSENT
    { ELit (LitHeytAbsent, mk_loc $startpos $endpos) }
  | UNKNOWN
    { ELit (LitHeytUnknown, mk_loc $startpos $endpos) }
  | REFL LPAREN e = expr RPAREN
    { ERefl (e, mk_loc $startpos $endpos) }
  (* `clear` — THE surface spelling of reflexivity (refl stays the KERNEL
     form). Two shapes, one keyword:
       clear e   = refl(e)                       (was: stay e / refl(e))
       clear     = refl(inferred endpoint)       (was: plainly)
     The bare form's endpoint is filled by Tycheck.elaborate_id_sugar from
     the enclosing function's return-type Id; here it is a sentinel var.
     NOTE: after CLEAR, a token that can start an atom SHIFTS (greedy, same
     as every prefix metonym) — the bare form fires only when nothing
     parseable follows. This is the ONE state added to the s/r ledger
     (11 -> 12 states; the arbitrated resolutions are all this shift). *)
  | CLEAR e = expr_atom %prec PREFIX_APP
    { ERefl (e, mk_loc $startpos $endpos) }
  | CLEAR
    { ERefl (EVar ("__plainly__", mk_loc $startpos $endpos), mk_loc $startpos $endpos) }
  (* ─── Metonymic surface sugar (journey metaphor) ─────────────────────
     Prefix forms binding an atom; pure desugar to the cubical primitives.
       back p          = inv(p)
       span e          = ua(e)
       carry x along e = transport(ua(e), x)   (e a bridge / equivalence) *)
  | BACK e = expr_atom %prec PREFIX_APP
    { ECall ("inv", [e], mk_loc $startpos $endpos) }
  | CARRY x = expr_atom ALONG e = expr_atom %prec PREFIX_APP
    { let l = mk_loc $startpos $endpos in
      ECall ("transport", [ECall ("ua", [e], l); x], l) }
  | PAIR LPAREN a = expr COMMA b = expr RPAREN
    { EPair (a, b, mk_loc $startpos $endpos) }
  | FST LPAREN e = expr RPAREN
    { EFst (e, mk_loc $startpos $endpos) }
  | SND LPAREN e = expr RPAREN
    { ESnd (e, mk_loc $startpos $endpos) }
  (* `induct(d, p)` = path induction with the operational placeholder motive
     (`match` omits the HIT motive the same way). Desugars to ind_path(0, d, p);
     the raw `ind_path(C, d, p)` below stays available in the lower stratum. *)
  | INDUCT LPAREN d = expr COMMA p = expr RPAREN
    { let l = mk_loc $startpos $endpos in EJ (ELit (LitNumber 0.0, l), d, p, l) }
  | IND_PATH LPAREN c = expr COMMA d = expr COMMA p = expr RPAREN
    { EJ (c, d, p, mk_loc $startpos $endpos) }
  | QUOTE LPAREN c = IDENT COMMA a = expr RPAREN
    { EQuote (TyTermExpr (EVar (c, mk_loc $startpos $endpos)), a, mk_loc $startpos $endpos) }
  | EL_MATCH LPAREN t = expr COMMA r = expr COMMA b = expr RPAREN
    { EElMatch (t, r, b, mk_loc $startpos $endpos) }
  | HIT_ELIM LPAREN c = expr COMMA LBRACKET branches = separated_list(COMMA, hit_branch) RBRACKET COMMA x = expr RPAREN
    { EHITElim (c, branches, x, mk_loc $startpos $endpos) }
  (* Metonymic: `match x { ctor => .., loop => plam i => .. }` = hit_elim with a
     SYNTHESIZED motive (non-dependent). The sentinel motive __match tells the
     type checker to infer the result type from the branches. *)
  | MATCH_KW x = expr_atom LBRACE branches = separated_list(COMMA, hit_branch) RBRACE
    { let l = mk_loc $startpos $endpos in
      EHITElim (EVar ("__match", l), branches, x, l) }
  | e = expr_atom ATSIGN I0
    { EPathApp (e, DI0, mk_loc $startpos $endpos) }
  | e = expr_atom ATSIGN I1
    { EPathApp (e, DI1, mk_loc $startpos $endpos) }
  | e = expr_atom ATSIGN id = IDENT
    { EPathApp (e, DIVar id, mk_loc $startpos $endpos) }
  | PLAM i = IDENT FATARROW body = expr
    { EPathAbs (i, body, mk_loc $startpos $endpos) }
  | HIT_KW LPAREN ctor = IDENT RPAREN
    { EHITConstr (ctor, [], mk_loc $startpos $endpos) }
  | HIT_KW LPAREN ctor = IDENT COMMA args = separated_nonempty_list(COMMA, expr) RPAREN
    { EHITConstr (ctor, args, mk_loc $startpos $endpos) }
  | PULLBACK LPAREN f = IDENT COMMA g = IDENT COMMA a = expr COMMA b = expr RPAREN
    { (* Runtime pullback. pullback(f, g, a, b) builds the compatible pair
       * (a, b) with the constraint f(a) == g(b) checked at runtime. The no-arg
       * pullback(f,g)/pushout(f,g) EXPRESSION forms were removed in v1.1 — they
       * lowered to a 0.0 placeholder. The universal property lives in the
       * `place P = pullback(f,g)` declaration (still supported). *)
      EPullbackVal (f, g, a, b, mk_loc $startpos $endpos) }
  | obj = IDENT DOT fld = IDENT LPAREN args = expr_list RPAREN
    { dot_call_expr obj fld args (mk_loc $startpos $endpos) }
  (* FOLD and FILTER are keyword tokens (space-decl `with fold "..."`), so they
   * do not match IDENT in method-name position: explicit rules for
   * Class.fold/filter(args). PUSH is a keyword too (geometric-morphism
   * f_lower_star), so Vec.push(...) needs the same treatment. `map` is a
   * plain IDENT since the map keyword retired with `map of K to V`. *)
  | obj = IDENT DOT FOLD LPAREN args = expr_list RPAREN
    { dot_call_expr obj "fold" args (mk_loc $startpos $endpos) }
  | obj = IDENT DOT PUSH LPAREN args = expr_list RPAREN
    { dot_call_expr obj "push" args (mk_loc $startpos $endpos) }

  | name = IDENT LPAREN args = expr_list RPAREN IN space = IDENT
    { (* syntax `f(args) in S`.
       *
       * Cases:
       *  - f = "apply_move": desugars to __apply_move_in_<S>.
       *  - f = a declared morph name: desugars to
       *      __apply_morph_in_<S>(<MorphName>, args)
       *    so the runtime dispatch can apply the morph inside the target
       *    space (triggering cross-space coordination via geom_morphism when
       *    one is declared between the topoi involved).
       *  - otherwise: a regular function call in a space context, desugared as
       *    __call_in_<S>(name, args). The simple dispatch is equivalent to the
       *    local call, but the space context stays visible to the lowering. *)
      if name = "apply_move" then
        ECall ("__apply_move_in_" ^ space, args, mk_loc $startpos $endpos)
      else
        (* For morphs and other functions in a space: the desugar/tycheck
         * decides whether name is a morph (apply morph) or not. The mangling
         * __morph_in_<S>__<name> serves as a unique tag. *)
        ECall ("__morph_in_" ^ space ^ "__" ^ name, args,
               mk_loc $startpos $endpos) }
  | name = IDENT LPAREN args = expr_list RPAREN
    { ECall (name, args, mk_loc $startpos $endpos) }
  | name = QIDENT LPAREN args = expr_list RPAREN
    { ECall (name, args, mk_loc $startpos $endpos) }   (* mod::fun(args) *)
  | x = IDENT DOT fs = separated_nonempty_list(DOT, IDENT)
    {
      (* Build a left-associative chain: x.f1.f2.f3 -> EField(EField(EField(x, f1), f2), f3) *)
      List.fold_left
        (fun acc f -> EField (acc, f, mk_loc $startpos $endpos))
        (EVar (x, dummy_loc))
        fs
    }
  | x = IDENT DOT STREAM
    { (* subscription.stream: STREAM is a keyword, so the generic field
         chain above cannot accept it; dedicated rule *)
      EField (EVar (x, dummy_loc), "stream", mk_loc $startpos $endpos)
    }
  | x = IDENT                                                          
    { EVar (x, mk_loc $startpos $endpos) }
  | x = QIDENT
    { EVar (x, mk_loc $startpos $endpos) }   (* qualified name mod::fun *)
  /* the mediatrice, expression position: `.-> Confirmed { amount 100 }` is
     the mediating arrow the universal property guarantees — written, not
     called. Same ENew node: identical lowering by construction. */
  | DOTARROW name = IDENT LBRACE fas = field_assign_list RBRACE
    { ENew (name, fas, mk_loc $startpos $endpos) }
  | WIRE TO SPACE sp = IDENT
    { EWireTo (sp, mk_loc $startpos $endpos) }
  | PRODUCE LBRACE body = list(stmt) RBRACE
    { EProduce (body, mk_loc $startpos $endpos) }
  | SPAWN LBRACE body = list(stmt) RBRACE
    { ESpawn (None, body, mk_loc $startpos $endpos) }
  | SPAWN IN n = expr PARALLEL LBRACE body = list(stmt) RBRACE
    { ESpawn (Some n, body, mk_loc $startpos $endpos) }
  | LPAREN e = expr RPAREN                                             
    { EParen (e, mk_loc $startpos $endpos) }
  | IF_KW c = expr THEN_KW a = expr ELSE_KW b = expr   %prec LOWEST
    { (* if/then/else as an expression. Lowered to scf.if with a yield of the
       * value. Low precedence: captures as much of the expression to the right
       * as possible. *)
      EIfThenElse (c, a, b, mk_loc $startpos $endpos) }
  (* EAll ("all P where c") removed in v1.1: condition was dropped at desugar,
     __all had no lowering, unused in the corpus. *)

hcomp_side:
  | face_var = IDENT EQ I0 FATARROW PLAM binder = IDENT FATARROW body = expr
    { (face_var, false, binder, body) }
  | face_var = IDENT EQ I1 FATARROW PLAM binder = IDENT FATARROW body = expr
    { (face_var, true, binder, body) }

hcomp_base:
  | l = literal { ELit (l, mk_loc $startpos $endpos) }
  | x = IDENT { EVar (x, mk_loc $startpos $endpos) }
  | LPAREN e = expr RPAREN { EParen (e, mk_loc $startpos $endpos) }

expr_list:
  | items = separated_list(COMMA, expr)       { items }

literal:
  | n = NUM_LIT                               { LitNumber n }
  | s = STR_LIT                               { LitString s }
  | b = BOOL_LIT                              { LitBool b }

/* Note: currency literals "100 EUR" with whitespace are not supported
 * in this version of the parser. A NUM_LIT followed by an IDENT would
 * unsafely match here regardless of whether the IDENT is a real
 * currency code. Currency literals are tracked as separate tokens
 * (NUM_LIT + IDENT) and combined at the semantic phase if desired. */

field_assign_list:
  | items = list(field_assign)                { items }

field_assign:
  | name = IDENT e = expr
    { { fa_name = name; fa_value = e; fa_loc = mk_loc $startpos $endpos } }

/* ─── Conditions ───────────────────────────────────────────────────── */

/* ─── Conditions ─────────────────────────────────────────────────────
 *
 * A condition is built on top of expr (which already handles AND/OR
 * via boolean operators) plus pattern-matching atoms `IS` / `IS NOT`.
 * We avoid adding AND/OR at the condition level to prevent ambiguity
 * with the expression-level boolean operators.
 *
 * Surface programs that want `cond1 AND cond2` use the boolean
 * expression form directly (since `IS` patterns produce booleans
 * conceptually).
 */

/* ─── Conditions ─────────────────────────────────────────────────────
 *
 * A condition is built on top of expr with optional pattern-matching
 * atoms `IS` / `IS NOT`, plus AND/OR for chaining. The AND/OR in
 * conditions reuse the boolean operator precedence levels declared
 * above; this is the same precedence used by expr-level booleans, so
 * `x is present and x > 0` parses as `(x is present) AND (x > 0)`.
 */

condition:
  | c = condition_atom                        { c }
  | c1 = condition AND c2 = condition         { CondAnd (c1, c2) }
  | c1 = condition OR c2 = condition          { CondOr (c1, c2) }

condition_atom:
  | e = expr IS p = pattern                   { CondIs (e, p) }
  | e = expr IS NOT p = pattern               { CondIsNot (e, p) }
  | e = expr                  %prec LOWEST    { CondExpr e }

pattern:
  | x = IDENT                                 { PatVar x }
  | l = literal                               { PatLit l }
  | PRESENT                                   { PatPresent }
  | ABSENT                                    { PatAbsent }
  | UNKNOWN                                   { PatUnknown }
