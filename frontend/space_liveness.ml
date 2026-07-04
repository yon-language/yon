(* space_liveness.ml  -  per-function Space arc-set, the base of the reclaim
   analysis (automatic last-use reclaim, and the `drop X` check that appeals to
   the same criterion).

   The static Space graph (space_graph.ml) answers WHICH arcs exist. This module
   answers, per function, WHICH Spaces that function can communicate with, so a
   later downstream-reachability pass can place the reclaim at each Space's
   last-use (and verify a `drop X` against the same point).

   PRECISION on the arc site. For TOPOLOGY, an import edge is attributed to the
   `import ... from X` declaration. For LIVENESS it is not the declaration that
   communicates, it is the USE of the imported symbol (a dispatch call, or the
   symbol handed to `awaits`). So an import arc of a function is: the function
   uses a name that was imported from X. This is conservative and sound: treating
   any use of an X-imported symbol as communication never drops X too early. Wire
   arcs stay the EWireTo(X) sites, exactly as the graph collects them.

   The `names_used` walk is exhaustive on expr / stmt (no wildcard): a new
   constructor fails the build rather than silently missing a use. Same net as
   the graph's wire walk. *)

module S = Surface_ast

(* symbol name -> the Space it was imported from (import mod::name from Space) *)
let import_map (prog : S.program) : (string, string) Hashtbl.t =
  let h = Hashtbl.create 16 in
  List.iter (function
      | S.TopImportFrom (_m, name, sp, _loc) -> Hashtbl.replace h name sp
      | _ -> ())
    prog;
  h

(* Every name USED as a variable or a call head in an expression, with its
   location. A superset that serves two readers: imported-symbol uses (import
   arcs) and callees (the call graph). *)
let rec names_expr (e : S.expr) : (string * S.location) list =
  match e with
  | S.EVar (n, l) -> [ (n, l) ]
  | S.ECall (f, args, l) -> (f, l) :: List.concat_map names_expr args
  | S.ELit _ | S.EWireTo _ -> []
  | S.EField (a, _, _) | S.EParen (a, _) | S.ENot (a, _)
  | S.ERefl (a, _) | S.EFst (a, _) | S.ESnd (a, _)
  | S.EPathApp (a, _, _) | S.EPathAbs (_, a, _) | S.EIn (a, _, _)
  | S.ELam (_, a, _) | S.EMoveLam (_, a, _, _, _)
  | S.EReductionLam (_, a, _, _) | S.EMorphLam (_, a, _, _, _)
  | S.EFunctorLam (_, a, _, _, _, _) | S.EViewLam (_, a, _, _) -> names_expr a
  | S.EApp (h, args, _) -> names_expr h @ List.concat_map names_expr args
  | S.EHITConstr (_, args, _) -> List.concat_map names_expr args
  | S.EBinop (_, a, b, _) | S.EPair (a, b, _) | S.EComposeWith (a, b, _) ->
      names_expr a @ names_expr b
  | S.EIfThenElse (a, b, c, _) | S.EJ (a, b, c, _) | S.EElMatch (a, b, c, _) ->
      names_expr a @ names_expr b @ names_expr c
  | S.EPullbackVal (_, _, a, b, _) -> names_expr a @ names_expr b
  | S.EQuote (S.TyTermExpr t, a, _) -> names_expr t @ names_expr a
  | S.EHITElim (e0, branches, x, _) ->
      names_expr e0
      @ List.concat_map (fun (_, _, be) -> names_expr be) branches
      @ names_expr x
  | S.EProduce (body, _) -> List.concat_map names_stmt body
  | S.ESpawn (eo, body, _) ->
      (match eo with Some e0 -> names_expr e0 | None -> [])
      @ List.concat_map names_stmt body
  | S.ENew (p, fas, l) | S.ENewIn (p, _, fas, l) ->
      (* `new P { ... }` creates a P instance in P's Space: the place name P is an
         arc toward that Space (resolved via the place->space map, merged into
         imap). The tp_at_space rewrite makes this explicit later; here P names it. *)
      (p, l) :: List.concat_map (fun fa -> names_expr fa.S.fa_value) fas
  | S.EAll (_, c, _) -> names_cond c
  | S.EPullback _ | S.EPushout _ -> []

and names_stmt (s : S.stmt) : (string * S.location) list =
  match s with
  | S.SLet (_, e, _) | S.SAssignHolds (_, e, _) | S.SAssignBecomes (_, e, _)
  | S.SReturn (e, _) | S.SEmit (e, _) | S.SPromote (e, _) -> names_expr e
  | S.SCall (f, args, l) -> (f, l) :: List.concat_map names_expr args
  | S.SNew (p, fas, l) | S.SNewIn (p, _, fas, l) ->
      (p, l) :: List.concat_map (fun fa -> names_expr fa.S.fa_value) fas
  | S.SWhen (c, body, elifs, oth, _) ->
      names_cond c
      @ List.concat_map names_stmt body
      @ List.concat_map (fun (c2, b2) -> names_cond c2 @ List.concat_map names_stmt b2) elifs
      @ (match oth with Some b -> List.concat_map names_stmt b | None -> [])
  | S.SForEvery (_, _, e, body, _) | S.SInSequence (_, e, body, _)
  | S.SIter (e, body, _) | S.SWhile (e, body, _) ->
      names_expr e @ List.concat_map names_stmt body
  | S.SRepeat (_, body, oth, _) ->
      List.concat_map names_stmt body
      @ (match oth with Some b -> List.concat_map names_stmt b | None -> [])
  | S.SForever (body, _) | S.SProduce (body, _) -> List.concat_map names_stmt body
  | S.SScope (_, body, e, _) -> List.concat_map names_stmt body @ names_expr e
  | S.SForces (_, c, body, _) -> names_cond c @ List.concat_map names_stmt body
  | S.SDrop (_, _) -> []                          (* drop names a Space, not a value use *)

and names_cond (c : S.condition) : (string * S.location) list =
  match c with
  | S.CondExpr e | S.CondIs (e, _) | S.CondIsNot (e, _) -> names_expr e
  | S.CondAnd (a, b) | S.CondOr (a, b) -> names_cond a @ names_cond b

let names_used_in_fun (fd : S.fun_decl) : (string * S.location) list =
  List.concat_map names_stmt fd.S.fn_body

(* `apply_move(a) in S` and `f(a) in S` (f a morph) are mangled by the parser into
   the call NAME: `__apply_move_in_<S>` and `__morph_in_<S>__<f>` (parser.mly). The
   target Space travels in the name, so a use of such a call is an arc toward S,
   the same as a wire or an imported-symbol use. Returns the target Space, if any. *)
let space_of_mangled_call (name : string) : string option =
  let has_prefix p =
    String.length name > String.length p && String.sub name 0 (String.length p) = p in
  if has_prefix "__apply_move_in_" then
    Some (String.sub name 16 (String.length name - 16))
  else if has_prefix "__morph_in_" then
    (* `__morph_in_<S>__<f>`: S runs to the first "__" separator (Space names may
       contain single underscores, so split on the double underscore). *)
    let rest = String.sub name 11 (String.length name - 11) in
    let n = String.length rest in
    let rec find i =
      if i + 1 >= n then None
      else if rest.[i] = '_' && rest.[i + 1] = '_' then Some i
      else find (i + 1) in
    (match find 0 with Some i -> Some (String.sub rest 0 i) | None -> None)
  else None

(* `w.awaits(producer)` subscribes to a producer in the wire's Space. The Space is
   not in the surface syntax (it rides the wire handle's type), so tycheck records
   it in the global `awaits_site_table`, keyed by the awaits call's (line, col).
   A site whose location hits that table is an arc toward the recorded Space. *)
let awaits_arc_of (l : S.location) : string option =
  match Hashtbl.find_opt S.awaits_site_table (l.S.start_line, l.S.start_col) with
  | Some (sp, _, _, _) -> Some sp
  | None -> None

(* A variable bound to a SECTION of a routed place holds a live reference into
   that place's Space arena: a section handle is NOT a copy, a later field read
   dereferences the arena. So every USE of such a variable is an arc toward the
   Space, or the reclaim would madvise pages a later read still needs (real on
   Linux, where MADV_DONTNEED zero-fills; masked on Darwin, which reclaims
   lazily). Collected flow-insensitively over the whole body (a binding anywhere
   maps the name everywhere): conservative, never frees early. Binders, closed
   under aliasing by fixpoint: `be x holds new P { }`, `be x holds f( )` where f
   returns a place, `be x holds y` where y is already bound. The result merges
   into the name->Space map (imap), so uses resolve through the same lookup as
   imported symbols. *)
let section_bindings ~(imap : (string, string) Hashtbl.t)
    ~(ftab : (string, S.fun_decl) Hashtbl.t) (body : S.stmt list)
    : (string * string) list =
  let rec binds_stmts ss = List.concat_map binds_stmt ss
  and binds_stmt s =
    match s with
    | S.SLet (x, e, _) -> [ (x, e) ]
    | S.SAssignHolds (S.LVar x, e, _) -> [ (x, e) ]
    | S.SAssignHolds (S.LField _, _, _) | S.SAssignBecomes _ | S.SReturn _
    | S.SCall _ | S.SNew _ | S.SNewIn _ | S.SEmit _ | S.SPromote _
    | S.SDrop _ -> []
    | S.SWhile (_, b, _) | S.SIter (_, b, _) | S.SForEvery (_, _, _, b, _)
    | S.SInSequence (_, _, b, _) | S.SForever (b, _) | S.SProduce (b, _)
    | S.SForces (_, _, b, _) | S.SScope (_, b, _, _) -> binds_stmts b
    | S.SRepeat (_, b, oth, _) ->
        binds_stmts b @ (match oth with Some o -> binds_stmts o | None -> [])
    | S.SWhen (_, b, elifs, oth, _) ->
        binds_stmts b
        @ List.concat_map (fun (_, bb) -> binds_stmts bb) elifs
        @ (match oth with Some o -> binds_stmts o | None -> [])
  in
  let pairs = binds_stmts body in
  let tbl : (string, string) Hashtbl.t = Hashtbl.create 8 in
  let rec space_of_rhs e =
    match e with
    | S.ENew (p, _, _) | S.ENewIn (p, _, _, _) -> Hashtbl.find_opt imap p
    | S.ECall (f, _, _) ->
        (match Hashtbl.find_opt ftab f with
         | Some fd ->
             (match fd.S.fn_return with
              | Some (S.TyUser p) -> Hashtbl.find_opt imap p
              | _ -> None)
         | None -> None)
    | S.EVar (y, _) -> Hashtbl.find_opt tbl y
    | S.EParen (e0, _) -> space_of_rhs e0
    | _ -> None
  in
  let changed = ref true in
  while !changed do
    changed := false;
    List.iter (fun (x, e) ->
        if not (Hashtbl.mem tbl x) then
          match space_of_rhs e with
          | Some sp -> Hashtbl.replace tbl x sp; changed := true
          | None -> ())
      pairs
  done;
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl []

(* imap extended with the section-handle bindings of [body] (and extra seeds,
   e.g. place-typed parameters). Copies on write; the caller's map is shared. *)
let imap_with_handles ~imap ~ftab ?(seeds = []) (body : S.stmt list)
    : (string, string) Hashtbl.t =
  match seeds @ section_bindings ~imap ~ftab body with
  | [] -> imap
  | bs ->
      let m = Hashtbl.copy imap in
      List.iter (fun (x, sp) -> Hashtbl.replace m x sp) bs;
      m

(* The Spaces a function communicates with DIRECTLY (its own body): wire arcs
   (EWireTo, via the graph), import arcs (uses of a symbol imported from a Space),
   mangled cross-space calls (`apply_move`/morph `in S`), and section-handle uses
   (including place-typed parameters: the caller's handle dereferenced here). *)
let direct_arcs ~(imap : (string, string) Hashtbl.t)
    ~(ftab : (string, S.fun_decl) Hashtbl.t) (fd : S.fun_decl) : string list =
  let param_seeds =
    List.filter_map
      (fun pr -> match pr.S.param_ty with
         | S.TyUser p ->
             (match Hashtbl.find_opt imap p with
              | Some sp -> Some (pr.S.param_name, sp) | None -> None)
         | _ -> None)
      fd.S.fn_params
  in
  let imap = imap_with_handles ~imap ~ftab ~seeds:param_seeds fd.S.fn_body in
  let used = names_used_in_fun fd in
  let wire = List.map fst (Space_graph.wires_fun fd) in
  let imported = List.filter_map (fun (n, _l) -> Hashtbl.find_opt imap n) used in
  let mangled = List.filter_map (fun (n, _l) -> space_of_mangled_call n) used in
  let awaits = List.filter_map (fun (_n, l) -> awaits_arc_of l) used in
  List.sort_uniq compare (wire @ imported @ mangled @ awaits)

(* name -> its declaration, over every top-level function (the merged program
   already carries the arrows lifted from place bodies as top-level TopFun). *)
let func_table (prog : S.program) : (string, S.fun_decl) Hashtbl.t =
  let h = Hashtbl.create 32 in
  List.iter (function S.TopFun fd -> Hashtbl.replace h fd.S.fn_name fd | _ -> ()) prog;
  h

let callees ~(ftab : (string, S.fun_decl) Hashtbl.t) (fd : S.fun_decl) : string list =
  List.sort_uniq compare
    (List.filter_map
       (fun (n, _l) -> if Hashtbl.mem ftab n then Some n else None)
       (names_used_in_fun fd))

(* The Spaces a function can communicate with directly OR through any function it
   (transitively) calls. Fixed-point closure over the call graph, recursion-safe
   via a visited set. *)
let transitive_arcs ~(place_space : (string, string) Hashtbl.t)
    (prog : S.program) : (string, string list) Hashtbl.t =
  let imap = import_map prog in
  (* place-creation arcs: `new P` reaches P's Space; merge into the name->Space
     map so direct_arcs resolves a place name the same way as an imported one. *)
  Hashtbl.iter (fun p s -> Hashtbl.replace imap p s) place_space;
  let ftab = func_table prog in
  let memo = Hashtbl.create 32 in
  let rec arcs_of (name : string) (visiting : string list) : string list =
    match Hashtbl.find_opt memo name with
    | Some r -> r
    | None ->
        if List.mem name visiting then []            (* cycle guard: recursion *)
        else match Hashtbl.find_opt ftab name with
          | None -> []
          | Some fd ->
              let here = direct_arcs ~imap ~ftab fd in
              let through =
                List.concat_map (fun c -> arcs_of c (name :: visiting)) (callees ~ftab fd)
              in
              let r = List.sort_uniq compare (here @ through) in
              (* memoize only when not inside an active cycle for this name *)
              if not (List.mem name visiting) then Hashtbl.replace memo name r;
              r
  in
  let out = Hashtbl.create 32 in
  Hashtbl.iter (fun name _ -> Hashtbl.replace out name (arcs_of name [])) ftab;
  out

(* ---- level 3: downstream-of-a-point (the shared predicate) ---- *)

let stmt_loc (s : S.stmt) : S.location =
  match s with
  | S.SLet (_, _, l) | S.SAssignHolds (_, _, l) | S.SAssignBecomes (_, _, l)
  | S.SReturn (_, l) | S.SCall (_, _, l) | S.SNew (_, _, l) | S.SNewIn (_, _, _, l)
  | S.SWhen (_, _, _, _, l) | S.SForEvery (_, _, _, _, l) | S.SInSequence (_, _, _, l)
  | S.SRepeat (_, _, _, l) | S.SForever (_, l) | S.SScope (_, _, _, l)
  | S.SProduce (_, l) | S.SEmit (_, l) | S.SPromote (_, l) | S.SForces (_, _, _, l)
  | S.SIter (_, _, l) | S.SWhile (_, _, l) | S.SDrop (_, l) -> l

let same_loc (a : S.location) (b : S.location) : bool =
  a.S.start_line = b.S.start_line && a.S.start_col = b.S.start_col

let union a b = List.sort_uniq compare (a @ b)

(* All Spaces a REGION of statements communicates with, each paired with a
   representative site that reaches it: a wire arc (the `wire to space X` site),
   an import arc (the imported-symbol USE site), or a transitive call arc (the
   call site). "Does X live here" AND, when it does, where. *)
let region_arc_sites ~imap ~ftab ~tarcs (stmts : S.stmt list) : (string * S.location) list =
  let named = List.concat_map names_stmt stmts in
  let wires = List.concat_map Space_graph.wires_stmt stmts in
  let import_arcs =
    List.filter_map
      (fun (n, l) -> match Hashtbl.find_opt imap n with Some sp -> Some (sp, l) | None -> None)
      named in
  let call_arcs =
    List.concat_map
      (fun (n, l) ->
         if Hashtbl.mem ftab n then
           (match Hashtbl.find_opt tarcs n with
            | Some a -> List.map (fun sp -> (sp, l)) a | None -> [])
         else [])
      named in
  let mangled_arcs =
    List.filter_map
      (fun (n, l) -> match space_of_mangled_call n with Some sp -> Some (sp, l) | None -> None)
      named in
  let awaits_arcs =
    List.filter_map
      (fun (_n, l) -> match awaits_arc_of l with Some sp -> Some (sp, l) | None -> None)
      named in
  wires @ import_arcs @ call_arcs @ mangled_arcs @ awaits_arcs

let region_arc_sites_expr ~imap ~ftab ~tarcs (e : S.expr) : (string * S.location) list =
  let named = names_expr e in
  let wires = Space_graph.wires_expr e in
  let import_arcs =
    List.filter_map
      (fun (n, l) -> match Hashtbl.find_opt imap n with Some sp -> Some (sp, l) | None -> None)
      named in
  let call_arcs =
    List.concat_map
      (fun (n, l) ->
         if Hashtbl.mem ftab n then
           (match Hashtbl.find_opt tarcs n with
            | Some a -> List.map (fun sp -> (sp, l)) a | None -> [])
         else [])
      named in
  let mangled_arcs =
    List.filter_map
      (fun (n, l) -> match space_of_mangled_call n with Some sp -> Some (sp, l) | None -> None)
      named in
  let awaits_arcs =
    List.filter_map
      (fun (_n, l) -> match awaits_arc_of l with Some sp -> Some (sp, l) | None -> None)
      named in
  wires @ import_arcs @ call_arcs @ mangled_arcs @ awaits_arcs

(* The Spaces reachable in the control-flow AT OR AFTER `target` within `body`,
   each with a representative downstream site. [downstream_arcs] below is the
   name-set projection of this, and is the predicate the pin gate guards.
   Sequential: what comes after target in its block, and after each enclosing
   construct. Loop rule (Option A): if a loop encloses target, the WHOLE loop
   body is downstream (the back-edge re-runs it), so a Space touched anywhere in
   an enclosing loop is live at target. Nesting is handled by construction: every
   enclosing loop contributes its whole body. Conservative and sound: never
   downstream-empty too early. *)
let downstream_arc_sites ~imap ~ftab ~tarcs (body : S.stmt list) (target : S.location)
    : (string * S.location) list =
  (* section-handle liveness: uses of a handle-bound variable dereference its
     Space's arena, so those variables resolve like imported symbols. *)
  let imap = imap_with_handles ~imap ~ftab body in
  let ras = region_arc_sites ~imap ~ftab ~tarcs in
  let raes = region_arc_sites_expr ~imap ~ftab ~tarcs in
  let rec ds_block (stmts : S.stmt list) : bool * (string * S.location) list =
    match stmts with
    | [] -> (false, [])
    | s :: rest ->
        if same_loc (stmt_loc s) target then (true, ras rest)
        else
          let (found, arcs) = ds_stmt s in
          if found then (true, arcs @ ras rest) else ds_block rest
  and ds_stmt (s : S.stmt) : bool * (string * S.location) list =
    match s with
    (* loops: the whole body is downstream of any interior point (back-edge) *)
    | S.SWhile (_, b, _) | S.SIter (_, b, _)
    | S.SForEvery (_, _, _, b, _) | S.SInSequence (_, _, b, _) | S.SForever (b, _) ->
        if fst (ds_block b) then (true, ras b) else (false, [])
    | S.SRepeat (_, b, oth, _) ->
        if fst (ds_block b) then
          (true, ras b @ (match oth with Some o -> ras o | None -> []))
        else (match oth with Some o -> ds_block o | None -> (false, []))
    (* non-loop compounds: sequential within the branch holding the target *)
    | S.SWhen (_, b, elifs, oth, _) ->
        let branches = b :: List.map snd elifs
                       @ (match oth with Some o -> [ o ] | None -> []) in
        let rec pick = function
          | [] -> (false, [])
          | br :: bs -> let (f, a) = ds_block br in if f then (true, a) else pick bs
        in pick branches
    | S.SScope (_, b, e, _) ->
        let (f, a) = ds_block b in if f then (true, a @ raes e) else (false, [])
    | S.SForces (_, _, b, _) -> ds_block b
    | S.SProduce (b, _) -> ds_block b
    (* leaf statements hold no nested statement block that can host the target *)
    | S.SLet _ | S.SAssignHolds _ | S.SAssignBecomes _ | S.SReturn _
    | S.SCall _ | S.SNew _ | S.SNewIn _ | S.SEmit _ | S.SPromote _
    | S.SDrop _ -> (false, [])
  in
  snd (ds_block body)

(* The pinned predicate: the NAME-SET of the downstream arcs.
   X in (downstream_arcs body loc)  <=>  a live arc toward X is reachable from loc.
   This is exactly the name projection of downstream_arc_sites, so the gate that
   pins this also guards the site-carrying core. *)
let downstream_arcs ~imap ~ftab ~tarcs (body : S.stmt list) (target : S.location) : string list =
  List.sort_uniq compare
    (List.map fst (downstream_arc_sites ~imap ~ftab ~tarcs body target))

(* ---- level 4: the `drop X` construct check ---- *)

(* Every `drop X` in a statement tree, with its site. Recurses into every
   nested block, exactly like the arc collectors, so a drop under a loop or a
   branch is found. *)
let rec drops_in_stmts (stmts : S.stmt list) : (string * S.location) list =
  List.concat_map (fun s -> match s with
    | S.SDrop (x, l) -> [ (x, l) ]
    | S.SWhile (_, b, _) | S.SIter (_, b, _)
    | S.SForEvery (_, _, _, b, _) | S.SInSequence (_, _, b, _)
    | S.SForever (b, _) | S.SProduce (b, _) | S.SForces (_, _, b, _)
    | S.SScope (_, b, _, _) -> drops_in_stmts b
    | S.SRepeat (_, b, oth, _) ->
        drops_in_stmts b @ (match oth with Some o -> drops_in_stmts o | None -> [])
    | S.SWhen (_, b, elifs, oth, _) ->
        drops_in_stmts b
        @ List.concat_map (fun (_, bb) -> drops_in_stmts bb) elifs
        @ (match oth with Some o -> drops_in_stmts o | None -> [])
    | S.SLet _ | S.SAssignHolds _ | S.SAssignBecomes _ | S.SReturn _
    | S.SCall _ | S.SNew _ | S.SNewIn _ | S.SEmit _ | S.SPromote _ -> []) stmts

(* Why a `drop X` is illegal. Two faults, checked in this order:
   - Unknown_space: X is not a declared Space. A typo (drop Acount for Account)
     has no arc toward the misspelling, so the reachability check alone would
     wave it through; the domain must be validated first, with its own message.
   - Still_live: X exists but a live arc toward it is still reachable downstream
     of the drop. The carried location is that arc (the wire / imported-symbol
     use / call that keeps X alive). *)
type drop_fault =
  | Unknown_space
  | Still_live of S.location

type drop_error = {
  de_space : string;
  de_drop  : S.location;   (* the `drop X` site *)
  de_fault : drop_fault;
}

(* Whole-program check of every `drop X`. Two obligations, in order:
   (1) EXISTENCE: X must be a declared Space (`declared` is the manifest census,
       the source of truth -- it includes isolated declared Spaces that appear in
       no arc, which are still droppable). Validate the domain before reasoning
       about the value.
   (2) SAFETY: X must have no arc reachable at or after the drop
       (downstream_arc_sites is empty of X) -- the SAME criterion the automatic
       reclaim uses, so a drop can never fire earlier than reclaim would.
   Import/transitive arcs are whole-program, so this runs on the merged program. *)
let check_drops ~(declared : string list)
    ~(place_space : (string, string) Hashtbl.t) (prog : S.program) : drop_error list =
  let imap = import_map prog in
  Hashtbl.iter (fun p s -> Hashtbl.replace imap p s) place_space;   (* place-creation arcs *)
  let ftab = func_table prog in
  let tarcs = transitive_arcs ~place_space prog in
  let funs = List.filter_map (function S.TopFun fd -> Some fd | _ -> None) prog in
  List.concat_map
    (fun (fd : S.fun_decl) ->
       List.filter_map
         (fun (x, loc) ->
            if not (List.mem x declared) then
              Some { de_space = x; de_drop = loc; de_fault = Unknown_space }
            else
              let sites = downstream_arc_sites ~imap ~ftab ~tarcs fd.S.fn_body loc in
              (match List.assoc_opt x sites with
               | Some arc_loc ->
                   Some { de_space = x; de_drop = loc; de_fault = Still_live arc_loc }
               | None -> None))
         (drops_in_stmts fd.S.fn_body))
    funs

(* ---- level 5: the automatic reclaim at last-use (the mechanism) ---- *)

(* The DUAL of check_drops: instead of verifying a user-chosen drop point, FIND
   each Space's last use and insert the reclaim there. It runs on the entry's
   `main`, where all execution lives, so main's downstream arc-set (WITH transitive
   arcs) is the whole-program remaining use of a Space: the first top-level
   position where X leaves downstream_arcs is its GLOBAL last use, and an auto
   reclaim there is sound -- no read of X can follow (a read after would be an arc,
   and the arc set is complete). Spaces live through the end are left to process
   exit; Spaces already dropped explicitly are skipped (the user's drop covers
   them). It only inserts SDrop nodes, reusing the drop emission verbatim. *)
let auto_reclaim_main_body ~imap ~ftab ~tarcs (declared : string list)
    (body : S.stmt list) : S.stmt list =
  match body with
  | [] -> []
  | _ ->
      let n = List.length body in
      (* after_i = the Spaces reachable STRICTLY AFTER statement i (downstream_arcs
         at s_i does not include s_i's own arcs). So X leaves the live set right
         after its last use. *)
      let after =
        List.map (fun s -> downstream_arcs ~imap ~ftab ~tarcs body (stmt_loc s)) body in
      let all_touched =
        List.sort_uniq compare
          (List.map fst (region_arc_sites ~imap ~ftab ~tarcs body)) in
      let explicit = List.map fst (drops_in_stmts body) in
      let candidates =
        List.filter
          (fun x -> List.mem x declared && not (List.mem x explicit)) all_touched in
      (* first i where x is no longer live after s_i = x's last use is at s_i, so
         reclaim right after s_i (before s_{i+1}). i = n-1 means x is used in the
         last statement (live to the end): no reclaim, process exit frees it. *)
      let last_use x =
        let rec find i = function
          | [] -> n - 1
          | a :: rest -> if List.mem x a then find (i + 1) rest else i
        in find 0 after in
      let inserts =
        List.filter_map (fun x ->
          let i = last_use x in if i < n - 1 then Some (i + 1, x) else None)
          candidates in
      let drops_before j =
        List.filter_map (fun (k, x) -> if k = j then Some (S.SDrop (x, S.dummy_loc)) else None)
          inserts in
      List.concat (List.mapi (fun i s -> drops_before i @ [ s ]) body)

(* Insert the automatic reclaims into the entry's main. Whole-program (transitive
   arcs cross files), so it runs on the merged program, and only on `main` -- the
   single root under which all execution happens. *)
let auto_reclaim_program ~(declared : string list)
    ~(place_space : (string, string) Hashtbl.t) (prog : S.program) : S.program =
  let imap = import_map prog in
  Hashtbl.iter (fun p s -> Hashtbl.replace imap p s) place_space;
  let ftab = func_table prog in
  let tarcs = transitive_arcs ~place_space prog in
  List.map (function
    | S.TopFun fd when fd.S.fn_name = "main" ->
        S.TopFun { fd with S.fn_body =
          auto_reclaim_main_body ~imap ~ftab ~tarcs declared fd.S.fn_body }
    | td -> td) prog
