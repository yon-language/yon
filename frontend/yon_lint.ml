(* yon_lint.ml — the `yon_lint` CLI over the shared Linter library.
 *
 * The rules live in linter.ml (also used by the language server), so the CLI and
 * the editor cannot disagree. This file is only argument handling and I/O.
 *
 *   yon_lint <file>          : print warnings, exit 0 (lint is advisory)
 *   yon_lint --strict <file> : exit 1 if any warning is emitted
 *)

let read_file (file : string) : string =
  let ic = open_in file in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic; s

let parse (source : string) : Surface_ast.program option =
  let lexbuf = Lexing.from_string source in
  try Some (Parser.program Lexer.token lexbuf) with _ -> None

let () =
  let strict, file =
    match Array.to_list Sys.argv with
    | [_; "--strict"; f] -> (true, Some f)
    | [_; f] -> (false, Some f)
    | _ -> (false, None)
  in
  match file with
  | None -> prerr_endline "uso: yon_lint [--strict] <file.yon>"; exit 64
  | Some path ->
      (match parse (read_file path) with
       | None ->
           Printf.eprintf "%s: parse error (run the compiler for details)\n" path;
           exit 65
       | Some prog ->
           let ws =
             List.sort
               (fun (a : Error_codes.t) b ->
                  compare a.Error_codes.range.Surface_ast.start_line
                          b.Error_codes.range.Surface_ast.start_line)
               (Linter.lint_program prog) in
           List.iter (fun (w : Error_codes.t) ->
             Printf.printf "%s:%d: [%s] %s\n"
               path w.Error_codes.range.Surface_ast.start_line
               (Error_codes.id w.Error_codes.code) w.Error_codes.message)
             ws;
           if ws = [] then Printf.printf "%s: no lint warnings\n" path;
           if strict && ws <> [] then exit 1 else exit 0)
