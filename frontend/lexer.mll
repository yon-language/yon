(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* lexer.mll — tokenizer for the Yon surface syntax.
   Maps source text to the tokens consumed by parser.mly. Keywords live in a
   hash table (built once below); everything else is matched by the rules at
   the bottom. *)

{
  open Parser
  
  exception Lexer_error of string
  
  let keyword_table = Hashtbl.create 64
  
  let () =
    List.iter (fun (k, v) -> Hashtbl.add keyword_table k v) [
      (* Top-level declarations. A Yon program is a list of these.
         A `place` is an object living in a world; a `space` is a runtime
         heap where instances of a place are allocated and addressed. `world`
         is not a surface keyword: a world is given by the project's toml and
         filesystem. *)
      "import", IMPORT;
      "internal", INTERNAL;
      "place", PLACE;
      (* `this` heads the coproduct clause of a block place: `this > A :U B`
         names the arms (sub-objects) that this place is the sum of. *)
      "this", THIS;
      "space", SPACE;
      "nat", NAT;

      (* The handle keywords: values that name a map in the category.
         `move` and `view` map between objects; `reduction` folds a structure
         to a value; `operation` is a method exposed by a place that carries an
         effect. They are static structures of the topos, not runtime values:
         you cannot nest one inside another, only compose them. *)
      "fun", FUN;
      "move", MOVE;
      "view", VIEW;
      "reduction", REDUCTION;
      "operation", OPERATION;
      "cell", CELL;             (* higher-cell inside a place (CATT-style) *)

      (* A `geomorph` is a geometric morphism between two whole worlds
         (categories): inside it, `pull` is the inverse image f^* and `push`
         the direct image f_*; `exact push` declares f_* exact (f^* is left
         exact by definition). `over X` builds the slice category — objects
         equipped with a chosen map down to X. *)
      "geomorph", GEOM_MORPHISM;
      "pull", PULL;
      "push", PUSH;
      "over", OVER;

      (* A `functor` is a first-class map between two worlds that preserves the
         categorical structure: it sends objects to objects and maps to maps,
         respecting identity and composition. Its direction is its header,
         `from W to V`; its laws are `law identity` and `law composition`.
         Transport along a morphism of worlds is a functor. *)
      "functor", FUNCTOR;

      (* Algebra on a place: `operation f(...) uses algebra A` binds an
         operation to a named algebra from the certified catalog (Additive,
         TropicalMax, ...). `law` names an obligation: on a functor, `identity`
         or `composition`; on a place or a morph, an algebraic law of its
         operations (commutative, associative, ...). Declared is claimed;
         undeclared is not claimed. *)
      "law", LAW;
      "uses", USES;
      "algebra", ALGEBRA;
      "fold", FOLD;             (* names the fold function, e.g. fold "sum_f64" *)

      (* The explicit vocabulary of category theory, exposed directly in the
         surface language. A `topos` is a category rich enough to do logic
         inside it (it has a subobject classifier, `prop` below). Its objects
         are the places of its directory; each `morphism` line declares one of
         its maps; `morph` declares a single map between topoi; `on object`/`on morphism ... via ...`
         say how a functor acts on each. A `nat transform` (natural
         transformation) is a map *between two functors* F and G: for each
         object it gives a map F(X) -> G(X), coherently. *)
      "topos", TOPOS_KW;
      (* A topos has no `objects` word: its objects are filesystem-derived. *)
      (* `morphism`: one line per morphism of a topos, and the word of the
         `on morphism N via M` clause. *)
      "morphism", MORPHISM_KW;
      "prop", PROP_KW;
      "each", EACH;             (* `for each X by Y` inside a nat transform *)
      "morph", MORPH_KW;
      "via", VIA_KW;

      (* A geometric morphism between topoi is an adjoint pair of functors:
         pull (f^*, inverse image, the left adjoint) and push (f_*, direct
         image, the right adjoint). `exact push` declares f_* exact; f^* is
         left exact by definition, so `exact` is only said of push. *)
      "exact", EXACT_KW;

      (* Error model. An `error` with `this < Base` in its body (see
         examples/error_morphism/db/QueryError.yon) declares an error as a
         place that is a sub-object of Base (an injection E -> Base: every E
         is a Base, so E can be used wherever a Base is expected). `place P
         on error E` declares the error morphism P -> E: on failure, P is
         transformed into the error object E, which exposes different maps
         (e.g. .rollback instead of .commit). `on error` is a two-word
         contextual phrase, not a reserved keyword. *)
      "error", ERROR_KW;

      (* `mut c := e` declares a cell, the one mutable thing; a value is
         defined with no keyword, `x := e`. The cell is written with `<-`. *)
      "mut", MUT;

      (* Type-level and connective words. Most read as English in declarations:
         `e is pattern`, `move M from A to B`. *)
      "of", OF;
      "in", IN;
      "to", TO;
      "stream", STREAM;
  "wire", WIRE;
      "spawn", SPAWN;
      "promote", PROMOTE;
      "parallel", PARALLEL;
      "is", IS;
      (* `is given`: the body is axiomatic, realized by the compiler —
         like Java's `native`. tycheck checks that the wired implementation
         exists: a declaration with no realization is rejected rather than
         left as a silent promise. *)
      "given", GIVEN;
      "not", NOT;
      "by", BY;
      (* `place P carried by C`: the carrier of the place, the object of the
         machine its values are *)
      "carried", CARRIED;
      "from", FROM;
      "with", WITH;
      "compose", COMPOSE;
      "hcomp", HCOMP;
      "comp", COMP;
      "unifies", UNIFIES;
      "requires", REQUIRES;
      "share", SHARE;
      "resolves", RESOLVES;
      (* heyting<N>: an integer in Heyting (intuitionistic) arithmetic, used
         where the logic is not assumed two-valued. *)
      "heyting", HEYT_INT_KW;

      (* No stream back-pressure modifiers (buffer/drop): a stream type has no
         policy field, so a modifier would be parsed and never consumed. *)

      (* Control flow *)
      "when", WHEN;
      "forces", FORCES;
      "otherwise", OTHERWISE;
      "for", FOR;
      "every", EVERY;
      "here", HERE;
      "sequence", SEQUENCE;
      "repeat", REPEAT;
      "at", AT;
      "most", MOST;
      "times", TIMES;
      "forever", FOREVER;
      "scope", SCOPE;
      "return", RETURN;
      "produce", PRODUCE;
      "emit", EMIT;
      (* Expression-level if/then/else, sufficient with while for
       * Turing-completeness. Lowered to scf.if with a yield of the value. *)
      "if", IF_KW;
      "then", THEN_KW;
      "else", ELSE_KW;
      (* Bounded loop: iter N do { body } always terminates.
       * General while: while cond do { body } may not terminate. *)
      "iter", ITER_KW;
      "do", DO_KW;
      "drop", DROP;
      "while", WHILE_KW;
      
      (* Operators (word form) *)
      "and", AND;
      "or", OR;
      (* No `all` ("all P where c"): the condition would be dropped at
         desugar and the construct has no lowering. *)
      "where", WHERE;
      
      (* View keywords *)
      "show", SHOW;
      "as", AS;

      (* Id-proposition sugar (desugar to Id / refl; no new kernel semantics):
         `Same(X, Y)` in type position is Id(A, X, Y) with A inferred from the
         endpoints; bare `clear` in a body is reflexivity of the endpoint. Keyword-first
         by grammar necessity (see parser.mly design note). *)
      "Same", SAME;
      "clear", CLEAR;
      (* NOTE: no `first`/`second` keywords — they collide with pervasive
         identifiers (the Generics chapter's `fun first<A,B>`, many examples).
         The Sigma projections stay `fst`/`snd` at the surface. *)
      (* `induct(d, p)` = path induction (ind_path) with the operational
         placeholder motive, exactly as `match` omits the HIT motive. The raw
         `ind_path(C, d, p)` stays live in the lower stratum. *)
      "induct", INDUCT;
      
      (* Mapping clauses *)
      "maps", MAPS;
      "converts", CONVERTS;
      "aggregates", AGGREGATES;
      
      (* Multi-shot marker *)
      "multishot", MULTI_SHOT;
      
      (* Booleans *)
      "true", BOOL_LIT true;
      "false", BOOL_LIT false;
      
      (* Reduction clauses: "on" is NOT a global keyword — it's an
         identifier that the parser checks contextually inside reduction
         bodies. Keeping it as IDENT allows users to write "on" as a
         field value (e.g., Status is on, off, error). *)
      
      (* Visits / effect signatures *)
      "visits", VISITS;
      
      (* Heyting tri-value *)
      "present", PRESENT;
      "absent", ABSENT;
      "unknown", UNKNOWN;

      (* HoTT / dependent types *)
      "Type", TYPE_KW;
      "Pi", PI;
      "Sigma", SIGMA;
      "Id", ID;
      "refl", REFL;
      "pair", PAIR;
      "fst", FST;
      "snd", SND;
      "ind_path", IND_PATH;     (* J-eliminator at surface level *)
      "El", EL;
      "quote", QUOTE;
      "el_match", EL_MATCH;
      "hit_elim", HIT_ELIM;
      "match", MATCH_KW;         (* metonymic: match x { ctor => .. } = hit_elim, motive synthesized *)
      "hit", HIT_KW;             (* HIT constructor: hit(base), hit(merid, a) *)
      "I0", I0;                  (* interval endpoint 0 *)
      "I1", I1;                  (* interval endpoint 1 *)
      "walk", WALK;              (* path abstraction <i> e *)
      "plam", PLAM;              (* the old spelling: refused by the parser *)
      "PathP", PATHP;            (* dependent path type *)

      (* Metonymic surface sugar (journey metaphor) — pure NAMES that desugar to
         the cubical primitives: back=inv,
         carry..along=transport, through=ap. No new semantics. *)
      "back", BACK;
      "carry", CARRY;
      "along", ALONG;
      "through", THROUGH;

      (* No duration literals (100ms/5s/3min): `s`, `ms`, etc. are ordinary
         identifiers; `2s` lexes as NUM_LIT + IDENT. *)
    ]
  
  let ident_or_keyword s =
    try Hashtbl.find keyword_table s
    with Not_found -> IDENT s

  (* The statement of a law or a prop, in the symbols of mathematical logic:
     after a quantifier (`∀x : T`, `∃x : T`) comes its variable and its type. In
     a prop a parenthesis opens the statement; in a law a comma does, and the
     statement reaches the end of the line. Inside it a single `=` is equality
     (`==`). Everywhere else `=` keeps its meaning. *)
  type statement = Outside | Variable | Bound | Inside of int | Line of int
  let statement = ref Outside
  let reset_statement () = statement := Outside
}

let digit = ['0'-'9']
let alpha = ['a'-'z' 'A'-'Z' '_']
let alnum = alpha | digit
let ident_start = ['a'-'z' '_']
let upper_start = ['A'-'Z']
let alnum_id = ['a'-'z' 'A'-'Z' '0'-'9' '_']
let ws = [' ' '\t' '\r']

rule raw_token = parse
  | ws+              { raw_token lexbuf }
  | '\n'             { Lexing.new_line lexbuf;
                       (if !statement = Line 0 then statement := Outside);
                       raw_token lexbuf }
  | "//" [^ '\n']*   { raw_token lexbuf }   (* line comment *)
  | "/*"             { block_comment lexbuf; raw_token lexbuf }
  
  (* No duration literals (100ms / 5s / 3min) and no currency codes: a
     duration is just a number (milliseconds). `2s` lexes as NUM_LIT 2 +
     IDENT s — the general rule. *)

  (* Numbers *)
  | digit+ '.' digit+ as n  { NUM_LIT (float_of_string n) }
  | digit+ as n              { let p = Lexing.lexeme_start_p lexbuf in
                               Hashtbl.replace Surface_ast.exact_int_literals
                                 (p.Lexing.pos_fname, p.Lexing.pos_lnum,
                                  p.Lexing.pos_cnum - p.Lexing.pos_bol) n;
                               NUM_LIT (float_of_string n) }
  
  (* String literals *)
  | '"'              { string_lit (Buffer.create 32) lexbuf }
  
  (* Multi-character operators *)
  | "<="             { LEQ }
  (* `c <- e` writes the cell c. Max-munch: `<=>` and `<=` are tried first;
     `a < -1` is written with a space. *)
  | "<-"             { LARROW }
  | ">="             { GEQ }
  | "!="             { NEQ }
  | "=="             { EQEQ }
  
  (* Intuitionistic logical connectives, tagged with `?`. In Yon's default
     logic a proposition is not assumed to be either true or false (no excluded
     middle), so these are distinct tokens from the classical connectives.
   * The 3-char tokens MUST come before the 2-char ones for max-munch (ocamllex). *)
  | "&&?"            { AMPAMPQ }
  | "||?"            { PIPEPIPEQ }
  | "=>?"            { FATARROWQ }
  | "<=>"            { LRARROW }   (* metonymic: f <=> g = equivalence *)
  | "!?"             { BANGQ }
  (* Bitwise operators in the intuitionistic setting, tagged with `?`.
     These lower to topos.heyt_int_* ops on !topos.heyt_int<64> (value,mask). *)
  | "&?"             { AMPQ }
  | "|?"             { PIPEQ }
  | "^?"             { CARETQ }
  | "~?"             { TILDEQ }

  (* `&&` / `||` accepted as aliases for the word forms `and` / `or`.
   * The multi-char tokens MUST come before the single-char ones for max-munch. *)
  | "&&"             { AMPAMP }
  | "||"             { PIPEPIPE }
  | "|->" | "\xe2\x86\xa6"  { MAPSTO }   (* ↦ : application *)
  | ">->" | "\xe2\x86\xaa"  { INJ }      (* ↪ : injection into an arm *)
  | "|>"             { PIPEGT }   (* pipe-forward: x |> f means f(x) *)
  | "=>"             { FATARROW }
  | "on" [' ' '\t']+ "error"
      { ON_ERROR }   (* one token: kills the contextual-`on` ambiguity in every
                        host (place member, fun, operation); an identifier
                        `on` elsewhere is untouched *)
  | ".->"            { DOTARROW } (* the mediatrice: a section written as the
                                      arrow FROM THE POINT — `.-> P { ... }`
                                      reads `1 -> P`, the dot carrying the
                                      terminal. Longest-match beats DOT. *)
  | "->"             { ARROW }   (* function type T -> U *)
  (* Single-character punctuation *)
  | '@'              { ATSIGN }
  | '['              { LBRACKET }
  | ']'              { RBRACKET }
  | '!'              { BANG }
  | '&'              { AMP }
  | '^'              { CARET }
  | '~'              { TILDE }
  | "++"             { PLUSPLUS }  (* metonymic: p ++ q = concat *)
  | '+'              { PLUS }
  | '-'              { MINUS }
  | '*'              { STAR }
  | '/'              { SLASH }
  | '%'              { PERCENT }
  (* `f<A, B>(`, written with no space after the name: type arguments, of a
     declaration or of a call. Only the `<` is consumed; the names are read again. *)
  | '<' upper_start alnum_id* (',' ' '* upper_start alnum_id*)* '>' '('
    { let n = Lexing.lexeme_end lexbuf - Lexing.lexeme_start lexbuf - 1 in
      lexbuf.Lexing.lex_curr_pos <- lexbuf.Lexing.lex_curr_pos - n;
      lexbuf.Lexing.lex_curr_p <-
        { lexbuf.Lexing.lex_curr_p with
          Lexing.pos_cnum = lexbuf.Lexing.lex_curr_p.Lexing.pos_cnum - n };
      let at = lexbuf.Lexing.lex_start_pos in
      let after_a_name =
        at > 0
        && (match Bytes.get lexbuf.Lexing.lex_buffer (at - 1) with
            | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
            | _ -> false) in
      if after_a_name then LT_TYPE_ARGS else LT }
  | '<'              { LT }
  | '>'              { GT }
  | '='              { (match !statement with
                        | Inside _ | Line _ -> EQEQ
                        | _ -> EQ) }
  | '|'              { PIPE }
  | '.'              { DOT }
  | ','              { (if !statement = Bound then statement := Line 0); COMMA }
  (* `:U` is the union (coproduct) operator between place arms: `A :U B`.
     The `:` prefix keeps `U` usable as an ordinary identifier. Written with
     no space (`:U`); a type annotation keeps its space (`x: T`), so `: U...`
     stays COLON + identifier. `:=` binds a record field (`side := number`).
     Both come before `:` so max-munch picks the two-char forms. *)
  | ":U"             { COLON_U }
  | ":="             { COLONEQ }
  | ':'              { COLON }
  | '('              { (match !statement with
                        | Bound -> statement := Inside 1
                        | Inside k -> statement := Inside (k + 1)
                        | Line k -> statement := Line (k + 1)
                        | _ -> ());
                       LPAREN }
  | ')'              { (match !statement with
                        | Inside 1 -> statement := Outside
                        | Inside k -> statement := Inside (k - 1)
                        | Line k when k > 0 -> statement := Line (k - 1)
                        | _ -> ());
                       RPAREN }
  | '{'              { LBRACE }
  | '}'              { RBRACE }
  (* Square brackets (LBRACKET/RBRACKET, lexed above) carry the cubical face
   * systems of hcomp/comp and the branch list of hit_elim (see parser.mly). *)
  
  (* Universe level token: Type_n for n=0,1,2,... — must come BEFORE
     the generic identifier rule because "Type" alone is also a
     keyword. *)
  | "Type_" (digit+ as n)  { TYPE_LEVEL (int_of_string n) }
  
  (* Identifiers — keyword or user-defined name.
     A keyword is recognized by lookup in keyword_table. *)
  | (alpha alnum_id* "::" alpha alnum_id* ("::" alpha alnum_id*)*) as s
      { QIDENT s }   (* qualified name mod::fun (namespaces) *)
  | (alpha alnum_id*) as s   { (if !statement = Variable then statement := Bound);
                               ident_or_keyword s }

  (* The symbols of mathematical logic (Velleman, How to Prove It). Each of
     ≠ ∧ ∨ → ¬ is the Yon operator of the same meaning; a statement is a
     proposition, in Omega, so ∧ ∨ → ¬ are the Heyting connectives. ↔ is the
     conjunction of the two implications; ∀ ∃ open a statement. *)
  | "\xce\xa0"  { PI }      (* Π *)
  | "\xce\xa3"  { SIGMA }   (* Σ *)
  | "\xe2\x88\x80"  { statement := Variable; FORALL }   (* ∀ *)
  | "\xe2\x88\x83"  { statement := Variable; EXISTS }   (* ∃ *)
  | "\xe2\x89\xa0"  { NEQ }                             (* ≠ *)
  | "\xe2\x88\xa7"  { AMPAMPQ }                         (* ∧ *)
  | "\xe2\x88\xa8"  { PIPEPIPEQ }                       (* ∨ *)
  | "\xe2\x86\x92"  { FATARROWQ }                       (* → *)
  | "\xc2\xac"      { BANGQ }                           (* ¬ *)
  | "\xe2\x86\x94"  { IFFQ }                            (* ↔ *)
  | "\xe2\x88\x88"  { raise (Lexer_error "∈ is not a symbol of Yon: the type of a quantifier follows a colon, `∀x : T`") }

  | eof              { reset_statement (); EOF }
  | _ as c           { raise (Lexer_error (Printf.sprintf "unexpected character %c" c)) }

and block_comment = parse
  | "*/"             { () }
  | '\n'             { Lexing.new_line lexbuf; block_comment lexbuf }
  | eof              { raise (Lexer_error "unterminated comment") }
  | _                { block_comment lexbuf }

and string_lit buf = parse
  | '"'              { STR_LIT (Buffer.contents buf) }
  | '\\' '"'         { Buffer.add_char buf '"'; string_lit buf lexbuf }
  | '\\' '\\'        { Buffer.add_char buf '\\'; string_lit buf lexbuf }
  | '\\' 'n'         { Buffer.add_char buf '\n'; string_lit buf lexbuf }
  | '\\' 't'         { Buffer.add_char buf '\t'; string_lit buf lexbuf }
  | '\n'             { Lexing.new_line lexbuf;
                       Buffer.add_char buf '\n';
                       string_lit buf lexbuf }
  | eof              { raise (Lexer_error "unterminated string") }
  | _ as c           { Buffer.add_char buf c; string_lit buf lexbuf }

{
  (* Three things the parser cannot see, since it does not see lines and reads one token
     ahead; the lexer tells it with a token of their own.
     - The clause `this > arms` ends at the end of its line, unless the next line goes on
       with `:U` or the line itself ends with `:U` or `>`.
     - After `law name`, what follows on the line is the statement; a bare name is a law a
       place only declares.
     - After a colon, a `where` or the dot of a binder comes a type. A type with an `=` of
       its own, on its line, is a path, and its endpoints are expressions, not types. *)
  type pending_token = {
    t : Parser.token;
    start_p : Lexing.position;
    curr_p : Lexing.position;
  }

  let owner = ref None
  let in_clause = ref false
  let type_follows = ref false
  let binder : int option ref = ref None
  let type_body = ref false
  let previous = ref EOF
  let previous_previous = ref EOF
  let previous_line = ref 0
  let held : pending_token list ref = ref []
  let lexed_to = ref Lexing.dummy_pos

  let lex_one (lexbuf : Lexing.lexbuf) : pending_token =
    if !lexed_to != Lexing.dummy_pos then lexbuf.Lexing.lex_curr_p <- !lexed_to;
    let t = raw_token lexbuf in
    lexed_to := lexbuf.Lexing.lex_curr_p;
    { t; start_p = lexbuf.Lexing.lex_start_p; curr_p = lexbuf.Lexing.lex_curr_p }

  let path_ahead (lexbuf : Lexing.lexbuf) (line : int) : bool =
    let at i =
      match List.nth_opt !held i with
      | Some p -> p
      | None -> let p = lex_one lexbuf in held := !held @ [p]; p in
    (* [opening] is true while the scan is inside the parentheses that open the type,
       [met] once an `=` stands directly in them: closed and followed by ∧, those
       parentheses are the first path of a conjunction *)
    let rec scan i depth opening met =
      let p = at i in
      if p.start_p.Lexing.pos_lnum > line then false
      else match p.t with
        | PI | SIGMA when i = 0 -> false
        | EQ when depth = 0 -> true
        | EQ when opening && depth = 1 -> scan (i + 1) depth opening true
        | LPAREN -> scan (i + 1) (depth + 1) (i = 0 || opening) met
        | RPAREN when opening && depth = 1 && met -> (at (i + 1)).t = AMPAMPQ
        | RPAREN -> depth > 0 && scan (i + 1) (depth - 1) (opening && depth > 1) met
        | EOF -> false
        | LBRACE | RBRACE | COMMA | COLONEQ | WHERE | FORALL | EXISTS when depth = 0 -> false
        | _ -> scan (i + 1) depth opening met in
    scan 0 0 false false

  let token (lexbuf : Lexing.lexbuf) : Parser.token =
    (match !owner with
     | Some l when l == lexbuf -> ()
     | _ ->
         owner := Some lexbuf;
         in_clause := false; type_follows := false; binder := None; type_body := false;
         previous := EOF; previous_previous := EOF;
         held := []; lexed_to := Lexing.dummy_pos);
    let virtual_token v =
      previous_previous := !previous;
      previous := v;
      v in
    if !type_follows
       && (type_follows := false; path_ahead lexbuf !previous_line) then
      virtual_token PATH_TYPE
    else begin
      let p =
        match !held with
        | p :: rest -> held := rest; p
        | [] -> lex_one lexbuf in
      lexbuf.Lexing.lex_start_p <- p.start_p;
      lexbuf.Lexing.lex_curr_p <- p.curr_p;
      let tok = p.t in
      let line = p.start_p.Lexing.pos_lnum in
      let put_back () = held := p :: !held in
      let finish t =
        (match t with
         | COLON | WHERE -> type_follows := true
         (* the body of a fun whose result is a type: what it returns may be a path *)
         | LBRACE when !previous = TYPE_KW && !previous_previous = COLON -> type_body := true
         | RETURN when !type_body -> type_body := false; type_follows := true
         | RBRACE -> type_body := false
         (* the comma after the binder of a dependent type: what follows is its body *)
         | PI | SIGMA -> binder := Some 0
         | LPAREN | LT when !binder <> None -> binder := Option.map succ !binder
         | RPAREN | GT when !binder <> None -> binder := Option.map pred !binder
         | COMMA when !binder = Some 0 -> binder := None; type_follows := true
         | _ -> ());
        previous_previous := !previous;
        previous := t; previous_line := line; t in
      if (match tok, !previous with IDENT _, LAW -> true | _ -> false) then begin
        statement := Line 0;
        finish tok
      end else
      if !previous_previous = LAW
         && line = !previous_line
         && (match tok with
             | IDENT _ | NUM_LIT _ | STR_LIT _ | BOOL_LIT _ | LPAREN | CLEAR -> true
             | _ -> false) then begin
        put_back ();
        previous_previous := EOF;
        previous := LAW_STATEMENT;
        LAW_STATEMENT
      end else
      if not !in_clause then begin
        if tok = GT && !previous = THIS then in_clause := true;
        finish tok
      end else
        match tok with
        | COLON_U -> finish tok
        | _ when !previous = COLON_U || (!previous = GT && !previous_previous = THIS && line > !previous_line) -> finish tok
        | _ when line > !previous_line ->
            in_clause := false;
            put_back ();
            previous := ARMS_END;
            ARMS_END
        | IDENT _ | BOOL_LIT _ | LT | GT | COMMA | LPAREN | RPAREN | ARROW | IN | COLON | EQ ->
            finish tok
        | _ ->
            in_clause := false;
            put_back ();
            previous := ARMS_END;
            ARMS_END
    end
}
