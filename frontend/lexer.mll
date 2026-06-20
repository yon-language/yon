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
         A `world` is a category (a collection of objects and the structure-
         preserving maps between them); a `place` is an object living in a
         world; a `space` is a runtime heap where instances of a place are
         allocated and addressed. *)
      "import", IMPORT;
      "internal", INTERNAL;
      "world", WORLD;
      "place", PLACE;
      "space", SPACE;

      (* The four kinds of "handle": values that name a map in the category.
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

      (* Constructions that build new objects from old ones, named after their
         universal property. A `geomorph` is a map between two whole
         worlds (categories). `pullback`/`pushout` are the categorical limit/
         colimit: a pullback glues two maps over a shared target, a pushout
         over a shared source. `over X` builds the slice category — objects
         equipped with a chosen map down to X. `topology` equips a world with
         a notion of covering (a Grothendieck topology). `subset_of` makes one
         world a subcategory of another. *)
      "geomorph", GEOM_MORPHISM;
      "pull", PULL;
      "push", PUSH;
      "over", OVER;
      "pullback", PULLBACK;
      "pushout", PUSHOUT;
      "topology", TOPOLOGY;

      (* A `functor` is a first-class map between two worlds that preserves the
         categorical structure (it sends objects to objects and maps to maps,
         respecting identity and composition). `functorial` marks an operation
         that behaves this way. `forward`/`backward`/`bi` give a functor's
         direction. *)
      "functorial", FUNCTORIAL;
      "functor", FUNCTOR;
      "forward", FORWARD;
      "backward", BACKWARD;
      "bi", BI;

      (* Algebra on a place: `operation f(...) uses algebra A` binds an
         operation to a named algebra from the certified catalog (Additive,
         TropicalMax, ...). `law` declares an algebraic law the operation must
         satisfy (commutative, associative, ...); the compiler verifies the
         declared laws against the catalog and rejects a false claim.
         `verify P` then instantiates the verified place as a runnable handle. *)
      "lawful", LAWFUL;
      "law", LAW;
      "uses", USES;
      "algebra", ALGEBRA;
      "verify", VERIFY;
      "invertible", INVERTIBLE;
      "fold", FOLD;             (* names the fold function, e.g. fold "sum_f64" *)

      (* The explicit vocabulary of category theory, exposed directly in the
         surface language. A `topos` is a category rich enough to do logic
         inside it (it has a subobject classifier, `prop` below). `objects`/
         `morphisms` list its content; `terminal` is the one-point object;
         `morph` declares a single map; `on object`/`on morphism ... via ...`
         say how a functor acts on each. A `nat transform` (natural
         transformation) is a map *between two functors* F and G: for each
         object it gives a map F(X) -> G(X), coherently. *)
      "topos", TOPOS_KW;
      "objects", OBJECTS_KW;
      "morphisms", MORPHISMS_KW;
      "terminal", TERMINAL_KW;
      "prop", PROP_KW;
      "each", EACH;             (* `for each X by Y` inside a nat transform *)
      "morph", MORPH_KW;
      "via", VIA_KW;

      (* A geometric morphism between topoi is an adjoint pair of functors:
         pull (f^*, inverse image, the left adjoint) and push (f_*, direct
         image, the right adjoint). `adjunction` names the pairing, `exact`
         the requirement that the inverse image preserve finite limits. *)
      "adjunction", ADJUNCTION_KW;
      "exact", EXACT_KW;

      (* Error model. `error E subcontains Base { ... }` declares an error as a
         place that is a sub-object of Base (an injection E -> Base: every E
         is a Base, so E can be used wherever a Base is expected). `place P
         on error E` declares the error morphism P -> E: on failure, P is
         transformed into the error object E, which exposes different maps
         (e.g. .rollback instead of .commit). `on error` is a two-word
         contextual phrase, not a reserved keyword. *)
      "error", ERROR_KW;
      "subcontains", SUBCONTAINS;

      (* `be x holds e` is the sole binding form (immutable). It maps to the
         LET token because the core IR still calls such bindings let-bindings;
         mutation goes through `=`, not rebinding. *)
      "be", LET;
      "partial", PARTIAL;

      (* Type-level and connective words. Most read as English in declarations:
         `list of T`, `map of K to V`, `e is pattern`, `move M from A to B`. *)
      "of", OF;
      "in", IN;
      "to", TO;
      "list", LIST;
      "map", MAP;
      "stream", STREAM;
  "wire", WIRE;
      "spawn", SPAWN;
      "promote", PROMOTE;
      "parallel", PARALLEL;
      "is", IS;
      "not", NOT;
      "by", BY;
      "from", FROM;
      "init", INIT;
      "with", WITH;
      "compose", COMPOSE;
      "effects", EFFECTS;
      "unifies", UNIFIES;
      "requires", REQUIRES;
      "share", SHARE;
      "resolves", RESOLVES;
      (* heyting<N>: an integer in Heyting (intuitionistic) arithmetic, used
         where the logic is not assumed two-valued. *)
      "heyting", HEYT_INT_KW;

      (* Stream back-pressure policy: bound the buffer, or drop old/new items. *)
      "buffer", BUFFER;
      "drop", DROP;             (* `drop oldest` / `drop newest`: the
                                   policy word after `drop` is contextual *)

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
      "new", NEW;
      (* Expression-level if/then/else, sufficient with while for
       * Turing-completeness. Lowered to scf.if with a yield of the value. *)
      "if", IF_KW;
      "then", THEN_KW;
      "else", ELSE_KW;
      (* Bounded loop: iter N do { body } always terminates.
       * General while: while cond do { body } may not terminate. *)
      "iter", ITER_KW;
      "do", DO_KW;
      "while", WHILE_KW;
      
      (* Statement keywords *)
      "holds", HOLDS;
      
      (* Operators (word form) *)
      "and", AND;
      "or", OR;
      "all", ALL;
      "where", WHERE;
      
      (* View keywords *)
      "show", SHOW;
      "as", AS;
      
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
      "hit", HIT_KW;             (* HIT constructor: hit(base), hit(merid, a) *)
      "I0", I0;                  (* interval endpoint 0 *)
      "I1", I1;                  (* interval endpoint 1 *)
      "plam", PLAM;              (* path abstraction <i> e *)
      "PathP", PATHP;            (* dependent path type *)
      
      (* Note: duration units (ms, s, min, h, d, y) are NOT registered as
         keywords here because identifiers like "s" are too common as
         parameter names. Duration literals are recognized as a single
         token at the lex rule level via numeric prefix. *)
    ]
  
  let ident_or_keyword s =
    try Hashtbl.find keyword_table s
    with Not_found -> IDENT s
  
  (* Currency codes — recognized after a number literal followed immediately by uppercase letters.
     We handle them specially in the parser via the CURRENCY_CODE token. *)
  let is_currency_code s =
    String.length s = 3
    && (let all_upper = ref true in
        String.iter (fun c -> if c < 'A' || c > 'Z' then all_upper := false) s;
        !all_upper)
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
  
  (* Duration literals — must come BEFORE generic number to win the
     longest-match competition. No whitespace allowed between number
     and unit suffix; "100 ms" is two tokens (NUM_LIT + IDENT). *)
  | (digit+ ('.' digit+)?) "min" as s
                     { let n = float_of_string (String.sub s 0 (String.length s - 3)) in
                       DUR_LIT (n, "min") }
  | (digit+ ('.' digit+)?) "ms" as s
                     { let n = float_of_string (String.sub s 0 (String.length s - 2)) in
                       DUR_LIT (n, "ms") }
  | (digit+ ('.' digit+)?) ('s' | 'h' | 'd' | 'y') as s
                     { let n = float_of_string (String.sub s 0 (String.length s - 1)) in
                       let u = String.sub s (String.length s - 1) 1 in
                       DUR_LIT (n, u) }
  
  (* Currency literals are recognized at the parser level (NUM_LIT
     followed by 3-uppercase IDENT). The lexer just produces both
     tokens separately. *)
  
  (* Numbers *)
  | digit+ '.' digit+ as n  { NUM_LIT (float_of_string n) }
  | digit+ as n              { NUM_LIT (float_of_string n) }
  
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
  | "!?"             { BANGQ }
  (* Bitwise operators in the intuitionistic setting, tagged with `?`. *)
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
  | "->"             { ARROW }   (* function type T -> U *)
  (* Single-character punctuation *)
  | '@'              { ATSIGN }
  | '['              { LBRACKET }
  | ']'              { RBRACKET }
  | '!'              { BANG }
  | '&'              { AMP }
  | '^'              { CARET }
  | '~'              { TILDE }
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
  | ':'              { COLON }
  | '('              { LPAREN }
  | ')'              { RPAREN }
  | '{'              { LBRACE }
  | '}'              { RBRACE }
  (* Square brackets not currently used by the Yon v0.3 grammar;
   * they are reserved for future use (e.g., tensor indexing,
   * cubical face formulas in surface syntax). *)
  
  (* Universe level token: Type_n for n=0,1,2,... — must come BEFORE
     the generic identifier rule because "Type" alone is also a
     keyword. *)
  | "Type_" (digit+ as n)  { TYPE_LEVEL (int_of_string n) }
  
  (* Identifiers — keyword or user-defined name.
     Currency codes (3 uppercase) are also identifiers; we let the parser decide. *)
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
