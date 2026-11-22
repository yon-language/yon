(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
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
  | Form_gone
  | Head_refused
  (* E2xxx type *)
  | Type_check
  | Return_not_in_tail
  | Effect_unhandled
  | Arm_coproduct_unnamed
  | Arm_name_clash
  | Library_name_taken
  | Given_outside_prelude
  | Write_to_value
  | Heap_allocates
  | Proof_rule
  | Error_undeclared
  | Escape_missing
  | Escape_needless
  | Stream_read_twice
  | Name_rebound
  | Constraint_refuted
  | Law_outside_algebra
  | Algebra_carried
  | Writing_refused
  | Place_not_positive
  | Index_impure
  | Reduction_unfinished
  | Value_discarded
  | Abstract_holds_state
  | Name_reserved
  | Law_refuted
  | Law_uncertified
  (* E3xxx Space semantics *)
  | Union_arms_cross_space
  | Drop_still_live
  | Drop_unknown_space
  | Wire_boundary
  | Selector_collision
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
  | Form_gone           -> "E1003"
  | Head_refused        -> "E1004"
  | Type_check          -> "E2001"
  | Return_not_in_tail  -> "E2002"
  | Effect_unhandled    -> "E2003"
  | Arm_coproduct_unnamed -> "E2004"
  | Arm_name_clash      -> "E2005"
  | Library_name_taken  -> "E2006"
  | Given_outside_prelude -> "E2007"
  | Write_to_value      -> "E2008"
  | Heap_allocates      -> "E2009"
  | Proof_rule          -> "E2010"
  | Error_undeclared    -> "E2011"
  | Escape_missing      -> "E2012"
  | Escape_needless     -> "E2013"
  | Stream_read_twice   -> "E2014"
  | Name_rebound        -> "E2015"
  | Constraint_refuted  -> "E2016"
  | Law_outside_algebra -> "E2017"
  | Algebra_carried     -> "E2018"
  | Writing_refused     -> "E2019"
  | Place_not_positive  -> "E2020"
  | Index_impure        -> "E2021"
  | Reduction_unfinished -> "E2022"
  | Value_discarded     -> "E2023"
  | Abstract_holds_state -> "E2024"
  | Name_reserved       -> "E2025"
  | Law_refuted         -> "E2101"
  | Law_uncertified     -> "E2102"
  | Union_arms_cross_space -> "E3003"
  | Drop_still_live     -> "E3001"
  | Drop_unknown_space  -> "E3002"
  | Wire_boundary       -> "E3010"
  | Selector_collision  -> "E3011"
  | Topos_layout        -> "E4001"
  | Entrypoint          -> "E4002"
  | File_layout         -> "E4003"
  | Manifest            -> "E4004"
  | Lint_dead_function  -> "W1001"
  | Lint_unused_binding -> "W1002"
  | Lint_unused_param   -> "W1003"
  | Lint_unused_import  -> "W3001"

let severity : code -> severity = function
  | Parse_syntax | Lex_bad_token | Form_gone | Head_refused
  | Type_check | Return_not_in_tail | Effect_unhandled
  | Stream_read_twice
  | Name_rebound | Constraint_refuted | Law_outside_algebra | Algebra_carried
  | Writing_refused | Place_not_positive | Index_impure | Reduction_unfinished
  | Value_discarded | Abstract_holds_state | Name_reserved
  | Arm_coproduct_unnamed | Arm_name_clash | Library_name_taken
  | Given_outside_prelude | Write_to_value | Heap_allocates | Proof_rule
  | Error_undeclared
  | Escape_missing
  | Escape_needless
  | Law_refuted
  | Law_uncertified
  | Union_arms_cross_space
  | Drop_still_live | Drop_unknown_space | Wire_boundary | Selector_collision
  | Topos_layout | Entrypoint | File_layout | Manifest -> Error
  | Lint_dead_function | Lint_unused_binding | Lint_unused_param
  | Lint_unused_import -> Warning

(* The prefix each class historically printed on the CLI. Preserved additively so
 * text-matching consumers keep working while the stable code is what tools grab. *)
let cli_prefix : code -> string = function
  | Parse_syntax | Lex_bad_token | Form_gone | Head_refused -> "PARSE ERROR"
  | Stream_read_twice
  | Name_rebound | Constraint_refuted | Law_outside_algebra | Algebra_carried
  | Writing_refused | Place_not_positive | Index_impure | Reduction_unfinished
  | Value_discarded | Abstract_holds_state | Name_reserved -> "TYPE ERROR"
  | Type_check                   -> "TYPE ERROR"
  | Return_not_in_tail           -> "TYPE ERROR"
  | Effect_unhandled             -> "TYPE ERROR"
  | Arm_coproduct_unnamed | Arm_name_clash | Library_name_taken
  | Given_outside_prelude | Write_to_value | Heap_allocates | Proof_rule
  | Error_undeclared | Escape_missing | Escape_needless -> "TYPE ERROR"
  | Law_refuted | Law_uncertified -> "LAW ERROR"
  | Union_arms_cross_space -> "TYPE ERROR"
  | Drop_still_live | Drop_unknown_space -> "DROP ERROR"
  | Wire_boundary                -> "WORLD BOUNDARY ERROR"
  | Selector_collision           -> "WIRE ERROR"
  | Topos_layout                 -> "TOPOS LAYOUT ERROR"
  | Entrypoint                   -> "ENTRYPOINT ERROR"
  | File_layout                  -> "FILE ERROR"
  | Manifest                     -> "MANIFEST ERROR"
  | Lint_dead_function | Lint_unused_binding | Lint_unused_param
  | Lint_unused_import           -> "LINT"

let title : code -> string = function
  | Parse_syntax        -> "syntax error"
  | Lex_bad_token       -> "lexical error"
  | Form_gone           -> "a form of the language that is gone: the message writes the new one"
  | Head_refused        -> "a modifier or a clause that the declaration does not take (`is given` on a proof fun, a constraint fun, a law, a carrier; `internal constraint`; `proof constraint`)"
  | Stream_read_twice   -> "the same Stream is read a second time: a Stream is read once"
  | Name_rebound        -> "a name already bound in the fun is bound again (a block, an arm, a lambda, a fun of the house)"
  | Constraint_refuted  -> "a literal does not satisfy the constraint of the place it enters (a constraint fun, ExitCode, NonZero, the turns of iter)"
  | Law_outside_algebra -> "a law lives outside an algebra (in a model, in a place with arms, in any other place)"
  | Algebra_carried     -> "an algebra has a carrier: the layout belongs to a model"
  | Writing_refused     -> "a writing the checker refuses by its type: the message writes the right one (a name that is gone, a second way to write a fun, a fun without arguments read with (), an effect without (), a name without its place, `::` inside one Space, a prefix of `::` that is not the place of the fun)"
  | Place_not_positive  -> "a recursive place is not strictly positive"
  | Index_impure        -> "the index of a type reads a cell"
  | Reduction_unfinished -> "a reduction of the kernel does not reach its normal form within the bound"
  | Value_discarded     -> "a value computed or indicated and thrown away"
  | Abstract_holds_state -> "an abstract Space holds state (a wire end, an initialization that outlives a call): the state belongs to the concrete Space that imports it"
  | Name_reserved -> "a name of the program is one the compiler or the runtime makes: it begins with __ or yon_rt_, or it is the qualified name of a fun of a house"
  | Type_check          -> "type error"
  | Return_not_in_tail  -> "a return stands at the end of its body"
  | Effect_unhandled    -> "an operation is called that no reduction handles"
  | Arm_coproduct_unnamed -> "an arm of several coproducts used where no type names one"
  | Arm_name_clash      -> "an arm and an arrow of the same home share a name"
  | Library_name_taken  -> "a user place takes the name of a library place"
  | Given_outside_prelude -> "a runtime primitive declared outside the prelude"
  | Proof_rule -> "what a proof fun refuses: no termination certificate, is given, forever, while, a call of a fun the termination check does not certify, a call from code that runs"
  | Write_to_value      -> "a write to a name that is not a cell"
  | Error_undeclared    -> "an escape whose error has no way out: the signature does not declare it, or the code is a lambda, a producer or a spawn"
  | Escape_missing      -> "a value that may be an error is read where its success is wanted without escape"
  | Escape_needless     -> "an escape with nothing to do: the value cannot fail, or the fun returns the error as it is"
  | Heap_allocates      -> "the code of a heap allocates a value"
  | Law_refuted         -> "a declared law is refuted by a counterexample"
  | Law_uncertified     -> "a declared law is neither proven nor declared an axiom"
  | Union_arms_cross_space -> "the arms of a union must be places of one Space"
  | Drop_still_live     -> "cannot drop a Space still used downstream"
  | Drop_unknown_space  -> "drop of an unknown Space"
  | Wire_boundary       -> "wire crosses a world boundary"
  | Selector_collision  -> "two operations of a Space have one selector on the wire"
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

(* A refusal that carries its code. The parser raises it where it refuses a form
 * with the form to write (`Form_gone`) or a clause a declaration does not take
 * (`Head_refused`); every reader of the parser renders the code it carries. A
 * plain `Failure` of the parser stays a syntax error (E1001). *)
exception Refused of code * string

(* Canonical one-line CLI rendering: "<PREFIX> [<id>]: <message>". The historical
 * prefix stays, the stable code is added in brackets. *)
let to_cli (d : t) : string =
  Printf.sprintf "%s [%s]: %s" (cli_prefix d.code) (id d.code) d.message

(* Every code, for enumeration (docs, tooling, the catalog gate). Keep in sync
 * with the variant above; the gate (regression/test_error_codes.py) proves the
 * assigned ids are all distinct -- the one hazard hand-numbering invites. *)
let all : code list =
  [ Parse_syntax; Lex_bad_token; Form_gone; Head_refused;
    Type_check; Return_not_in_tail; Effect_unhandled;
    Arm_coproduct_unnamed; Arm_name_clash; Library_name_taken;
    Given_outside_prelude; Write_to_value; Heap_allocates; Proof_rule;
    Error_undeclared; Escape_missing; Escape_needless; Stream_read_twice;
    Name_rebound; Constraint_refuted; Law_outside_algebra; Algebra_carried;
    Writing_refused; Place_not_positive; Index_impure; Reduction_unfinished;
    Value_discarded; Abstract_holds_state; Name_reserved;
    Law_refuted;
    Law_uncertified;
    Union_arms_cross_space; Drop_still_live; Drop_unknown_space; Wire_boundary;
    Topos_layout; Entrypoint; File_layout; Manifest;
    Lint_dead_function; Lint_unused_binding; Lint_unused_param; Lint_unused_import ]
