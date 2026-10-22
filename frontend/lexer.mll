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

      (* `be x := e` is the sole binding form (immutable). It maps to the
         LET token because the core IR still calls such bindings let-bindings;
         mutation goes through `=`, not rebinding. *)
      "be", LET;

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
      "plam", PLAM;              (* path abstraction <i> e *)
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
}

let digit = ['0'-'9']
let alpha = ['a'-'z' 'A'-'Z' '_']
let alnum = alpha | digit
let ident_start = ['a'-'z' '_']
let upper_start = ['A'-'Z']
let alnum_id = ['a'-'z' 'A'-'Z' '0'-'9' '_']
let ws = [' ' '\t' '\r']

rule token = parse
  | ws+              { token lexbuf }
  | '\n'             { Lexing.new_line lexbuf; token lexbuf }
  | "//" [^ '\n']*   { token lexbuf }   (* line comment *)
  | "/*"             { block_comment lexbuf; token lexbuf }
  
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
  | '<'              { LT }
  | '>'              { GT }
  | '='              { EQ }
  | '|'              { PIPE }
  | '.'              { DOT }
  | ','              { COMMA }
  (* `:U` is the union (coproduct) operator between place arms: `A :U B`.
     The `:` prefix keeps `U` usable as an ordinary identifier. Written with
     no space (`:U`); a type annotation keeps its space (`x: T`), so `: U...`
     stays COLON + identifier. `:=` binds a record field (`side := number`).
     Both come before `:` so max-munch picks the two-char forms. *)
  | ":U"             { COLON_U }
  | ":="             { COLONEQ }
  | ':'              { COLON }
  | '('              { LPAREN }
  | ')'              { RPAREN }
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
  | (alpha alnum_id*) as s   { ident_or_keyword s }
  
  | eof              { EOF }
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
