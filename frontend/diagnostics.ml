(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* diagnostics.ml — improved error formatting for parser and type checker.
 *
 * Two improvements:
 *
 *   1. Parser errors now include the actual token text and a snippet
 *      of source context spanning two lines (above and below the
 *      error position).
 *
 *   2. Type checker errors are formatted with file location, error
 *      kind tag, and optional suggestion strings.
 *
 * Both functions are pure: they accept a source string and an error
 * position/info, and produce a formatted message.
 *)

(* ─── Source-line extraction ───────────────────────────────────────── *)

(* Split a source string into a list of lines (preserving line numbers
 * 1-based). *)
let lines_of (src : string) : string array =
  String.split_on_char '\n' src |> Array.of_list

(* Get a line by 1-based line number; empty string if out of range. *)
let line_at (lines : string array) (n : int) : string =
  if n < 1 || n > Array.length lines then ""
  else lines.(n - 1)

(* Build a 2-line context: the offending line plus a caret pointer
 * indicating the column. Optionally include the line above and below
 * for readability. *)
let format_source_context
    (src : string)
    (line_num : int) (col : int) : string =
  let lines = lines_of src in
  let line = line_at lines line_num in
  let pad_col = String.make (max 0 col) ' ' in
  let caret = pad_col ^ "^" in
  let above =
    if line_num > 1 then Printf.sprintf "%4d | %s\n" (line_num - 1)
      (line_at lines (line_num - 1))
    else ""
  in
  let below =
    if line_num < Array.length lines then
      Printf.sprintf "%4d | %s\n" (line_num + 1)
        (line_at lines (line_num + 1))
    else ""
  in
  Printf.sprintf "%s%4d | %s\n     | %s\n%s"
    above line_num line caret below

(* ─── Parser error formatting ──────────────────────────────────────── *)

(* When the parser fails, we get:
 *   - The lexbuf's current position (line, col)
 *   - The last token that was returned by the lexer (we can re-lex
 *     just enough to find out, or we can capture the last token via
 *     a wrapper lexer in main.ml)
 *
 * For now we provide a function that accepts the position and an
 * optional last-token string, and formats a helpful message. *)

type parse_diagnostic = {
  pd_line : int;
  pd_col : int;
  pd_last_token : string option;
  pd_message : string;
}

(* ─── Type checker error formatting ────────────────────────────────── *)

(* Error kinds for type checking. Each kind has a short tag for
 * display and an optional suggestion that helps the user fix the
 * issue. *)

type ty_error_kind =
  | UnknownIdentifier of string
  | UnknownPlace of string
  | UnknownWorld of string
  | UnknownReduction of string
  | UnknownFunction of string
  | ArityMismatch of { name : string; expected : int; got : int }
  | TypeMismatch of { context : string; expected : string; got : string }
  | MissingEffect of { op : string; place : string }
  | InvalidFieldAccess of { ty : string; field : string }
  | UnhandledOperation of { reduction : string; op : string; place : string }
  | AmbiguousOperation of { name : string; places : string list }
  | Other of string

let kind_tag = function
  | UnknownIdentifier _ -> "[unknown-identifier]"
  | UnknownPlace _ -> "[unknown-place]"
  | UnknownWorld _ -> "[unknown-world]"
  | UnknownReduction _ -> "[unknown-reduction]"
  | UnknownFunction _ -> "[unknown-function]"
  | ArityMismatch _ -> "[arity-mismatch]"
  | TypeMismatch _ -> "[type-mismatch]"
  | MissingEffect _ -> "[missing-effect]"
  | InvalidFieldAccess _ -> "[invalid-field-access]"
  | UnhandledOperation _ -> "[unhandled-operation]"
  | AmbiguousOperation _ -> "[ambiguous-operation]"
  | Other _ -> "[error]"

let kind_message = function
  | UnknownIdentifier x ->
      Printf.sprintf "unknown identifier '%s'" x
  | UnknownPlace p ->
      Printf.sprintf "unknown place '%s'" p
  | UnknownWorld w ->
      Printf.sprintf "unknown world '%s'" w
  | UnknownReduction r ->
      Printf.sprintf "unknown reduction '%s'" r
  | UnknownFunction f ->
      Printf.sprintf "unknown function '%s'" f
  | ArityMismatch { name; expected; got } ->
      Printf.sprintf "%s: expected %d argument%s, got %d"
        name expected (if expected = 1 then "" else "s") got
  | TypeMismatch { context; expected; got } ->
      Printf.sprintf "%s: expected %s, got %s" context expected got
  | MissingEffect { op; place } ->
      Printf.sprintf "operation %s.%s requires the function to either:\n\
                      \    declare 'visits %s' in its signature, or\n\
                      \    be inside a 'with R of %s' block"
        place op place place
  | InvalidFieldAccess { ty; field } ->
      Printf.sprintf "cannot access field '%s' on a value of type %s\n\
                      \    field access requires a place type, not a primitive"
        field ty
  | UnhandledOperation { reduction; op; place } ->
      Printf.sprintf "reduction '%s' handles operation '%s' which is not declared in place '%s'"
        reduction op place
  | AmbiguousOperation { name; places } ->
      Printf.sprintf "operation '%s' is ambiguous: declared in %d places (%s)\n\
                      \    qualify the call with Place.%s instead"
        name (List.length places) (String.concat ", " places) name
  | Other msg -> msg

let format_ty_error
    (src : string)
    (line : int) (col : int)
    (kind : ty_error_kind) : string =
  let location = Printf.sprintf "%s at line %d, column %d"
                   (kind_tag kind) line col in
  let message = kind_message kind in
  let context = format_source_context src line (max 0 (col - 1)) in
  Printf.sprintf "%s\n  %s\n\n%s" location message context

(* ─── Suggestion engine ────────────────────────────────────────────── *)

(* Simple Levenshtein-distance suggestion: given an unknown identifier
 * and a list of known names, find the closest match. *)

let levenshtein (a : string) (b : string) : int =
  let la = String.length a in
  let lb = String.length b in
  if la = 0 then lb
  else if lb = 0 then la
  else
    let d = Array.make_matrix (la + 1) (lb + 1) 0 in
    for i = 0 to la do d.(i).(0) <- i done;
    for j = 0 to lb do d.(0).(j) <- j done;
    for i = 1 to la do
      for j = 1 to lb do
        let cost = if a.[i-1] = b.[j-1] then 0 else 1 in
        d.(i).(j) <- min (min (d.(i-1).(j) + 1) (d.(i).(j-1) + 1))
                         (d.(i-1).(j-1) + cost)
      done
    done;
    d.(la).(lb)

let suggest_closest (target : string) (candidates : string list)
    (threshold : int) : string option =
  let scored =
    List.map (fun c -> (c, levenshtein target c)) candidates in
  let sorted = List.sort (fun (_, a) (_, b) -> compare a b) scored in
  match sorted with
  | (best, dist) :: _ when dist <= threshold -> Some best
  | _ -> None

(* Format an error with a suggestion appended if a similar name exists. *)
