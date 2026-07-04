(* error_codes.ml — the single registry of stable diagnostic codes, and the
 * canonical Diagnostic value every producer emits and every consumer reads.
 *
 * A code is defined by its relationships (Yoneda): its stable id, its severity,
 * its historical CLI prefix, its title. Nothing else identifies it. The `code`
 * variant is EXHAUSTIVE: a new diagnostic kind fails the build until it is given
 * an id here, so the catalog can never silently omit a class -- the same
 * anti-fake-green net the rest of the frontend relies on, turned on the catalog.
 *
 * Codes are STABLE UNDER MESSAGE REWORDING. A tool grabs `E3001`, not the string
 * "DROP ERROR:"; rename the prose and the tool keeps working. That stability is
 * the whole reason the catalog exists.
 *
 * Ranges:
 *   E1xxx  syntax   (lexer, parser)
 *   E2xxx  type     (Tycheck)
 *   E3xxx  Space semantics (drop / reclaim / wire boundary -- the diagnostics no
 *                    other language can give, from the communication graph)
 *   E4xxx  project / layout (topos-per-space, entrypoint, file layout, manifest)
 *   W xxx  lint warnings (well-typed but suspicious; never reject)
 *)

module S = Surface_ast

type severity = Error | Warning

type code =
  (* E1xxx syntax *)
  | Parse_syntax
  | Lex_bad_token
  (* E2xxx type *)
  | Type_check
  (* E3xxx Space semantics *)
  | Drop_still_live
  | Drop_unknown_space
  | Wire_boundary
  (* E4xxx project / layout *)
  | Topos_layout
  | Entrypoint
  | File_layout
  | Manifest
  (* Wxxx lint warnings (well-typed but suspicious; never reject) *)
  | Lint_dead_function
  | Lint_unused_binding
  | Lint_unused_param
  | Lint_unused_import

let id : code -> string = function
  | Parse_syntax        -> "E1001"
  | Lex_bad_token       -> "E1002"
  | Type_check          -> "E2001"
  | Drop_still_live     -> "E3001"
  | Drop_unknown_space  -> "E3002"
  | Wire_boundary       -> "E3010"
  | Topos_layout        -> "E4001"
  | Entrypoint          -> "E4002"
  | File_layout         -> "E4003"
  | Manifest            -> "E4004"
  | Lint_dead_function  -> "W1001"
  | Lint_unused_binding -> "W1002"
  | Lint_unused_param   -> "W1003"
  | Lint_unused_import  -> "W3001"

let severity : code -> severity = function
  | Parse_syntax | Lex_bad_token | Type_check
  | Drop_still_live | Drop_unknown_space | Wire_boundary
  | Topos_layout | Entrypoint | File_layout | Manifest -> Error
  | Lint_dead_function | Lint_unused_binding | Lint_unused_param
  | Lint_unused_import -> Warning

(* The prefix each class historically printed on the CLI. Preserved additively so
 * text-matching consumers keep working while the stable code is what tools grab. *)
let cli_prefix : code -> string = function
  | Parse_syntax | Lex_bad_token -> "PARSE ERROR"
  | Type_check                   -> "TYPE ERROR"
  | Drop_still_live | Drop_unknown_space -> "DROP ERROR"
  | Wire_boundary                -> "WORLD BOUNDARY ERROR"
  | Topos_layout                 -> "TOPOS LAYOUT ERROR"
  | Entrypoint                   -> "ENTRYPOINT ERROR"
  | File_layout                  -> "FILE ERROR"
  | Manifest                     -> "MANIFEST ERROR"
  | Lint_dead_function | Lint_unused_binding | Lint_unused_param
  | Lint_unused_import           -> "LINT"

let title : code -> string = function
  | Parse_syntax        -> "syntax error"
  | Lex_bad_token       -> "lexical error"
  | Type_check          -> "type error"
  | Drop_still_live     -> "cannot drop a Space still used downstream"
  | Drop_unknown_space  -> "drop of an unknown Space"
  | Wire_boundary       -> "wire crosses a world boundary"
  | Topos_layout        -> "topos layout violation"
  | Entrypoint          -> "entrypoint violation"
  | File_layout         -> "file layout violation"
  | Manifest            -> "manifest error"
  | Lint_dead_function  -> "unreachable function"
  | Lint_unused_binding -> "unused binding"
  | Lint_unused_param   -> "unused parameter"
  | Lint_unused_import  -> "unused import (dead Space dependency)"

(* The canonical Diagnostic. The message is the specific text WITHOUT the prefix
 * or code (those come from the code). The range is 1-based surface coordinates
 * (dummy_loc when a class has no precise site, e.g. a project-wide manifest
 * error); consumers that need a range fall back to the file head. *)
type t = {
  code    : code;
  range   : S.location;
  message : string;
}

let make ?(range = S.dummy_loc) (code : code) (message : string) : t =
  { code; range; message }

(* Canonical one-line CLI rendering: "<PREFIX> [<id>]: <message>". The historical
 * prefix stays, the stable code is added in brackets. *)
let to_cli (d : t) : string =
  Printf.sprintf "%s [%s]: %s" (cli_prefix d.code) (id d.code) d.message

(* Every code, for enumeration (docs, tooling, the catalog gate). Keep in sync
 * with the variant above; the gate (regression/test_error_codes.py) proves the
 * assigned ids are all distinct -- the one hazard hand-numbering invites. *)
let all : code list =
  [ Parse_syntax; Lex_bad_token; Type_check;
    Drop_still_live; Drop_unknown_space; Wire_boundary;
    Topos_layout; Entrypoint; File_layout; Manifest;
    Lint_dead_function; Lint_unused_binding; Lint_unused_param; Lint_unused_import ]
