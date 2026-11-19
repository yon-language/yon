(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* yonfmt.ml — the `yonfmt` CLI over the shared Formatter library.
 *
 * The formatting logic lives in formatter.ml (also used by the language server's
 * textDocument/formatting), so the CLI and the editor cannot disagree. This file
 * is only argument handling and file I/O.
 *
 *   yonfmt <file>         : print the formatted output to stdout (if safe)
 *   yonfmt --write <file> : rewrite the file in place (if safe)
 *   yonfmt --check <file> : exit 0 if already formatted, 1 if it would change
 *   yonfmt --dump-ast <file> : the reading of the file, with its positions and its sites
 *)

let read_file (file : string) : string =
  let ic = open_in file in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic; s

let () =
  match Array.to_list Sys.argv with
  | [_; "--check"; file] ->
      (match Formatter.safe_format (read_file file) with
       | Some out when out = read_file file ->
           Printf.printf "already formatted: %s\n" file; exit 0
       | Some _ -> Printf.printf "needs formatting: %s\n" file; exit 1
       | None ->
           Printf.printf "not formattable (uncovered or invalid construct): %s\n" file;
           exit 2)
  | [_; "--write"; file] ->
      (match Formatter.safe_format (read_file file) with
       | Some out ->
           let oc = open_out file in output_string oc out; close_out oc;
           Printf.printf "formatted: %s\n" file
       | None -> Printf.printf "left unchanged (fail-safe): %s\n" file)
  | [_; "--dump-ast"; file] ->
      (* the reading as text: two builds of the parser that read a file the same way write
         the same text for it *)
      (match Formatter.parse_reading (read_file file) with
       | Some (prog, sites) -> print_string (Ast_compare.dump prog sites)
       | None ->
           (* the refusal, with where the reading stopped: a change of the grammar keeps it too *)
           Parser_state.reset (); Surface_ast.reset_parse_tables (); Lexer.reset_statement ();
           let lexbuf = Lexing.from_string (read_file file) in
           (try ignore (Parser.program Lexer.token lexbuf); print_endline "parsed on the second reading"
            with e ->
              let p = Lexing.lexeme_start_p lexbuf in
              Printf.printf "refused at %d:%d: %s\n" p.Lexing.pos_lnum (p.Lexing.pos_cnum - p.Lexing.pos_bol)
                (match e with
                 | Error_codes.Refused (c, m) -> Error_codes.id c ^ " " ^ m
                 | e -> Printexc.to_string e));
           exit 2)
  | [_; "--raw"; file] ->
      (* the raw output, before the round-trip fail-safe: it shows why the
         guard refuses, instead of leaving it to be guessed *)
      (match Formatter.parse (read_file file) with
       | None -> prerr_endline "parse failed"; exit 2
       | Some prog ->
           (match Formatter.format_program prog with
            | None -> prerr_endline "format_program: Exit (costrutto non coperto)"; exit 3
            | Some out -> print_string out))
  | [_; "--ast-diff"; file] ->
      (* where the program and its formatting differ, but for positions: the guard's reason *)
      (match Formatter.parse_reading (read_file file) with
       | None -> prerr_endline "parse failed"; exit 2
       | Some (prog, sites) ->
           (match Formatter.format_program prog with
            | None -> prerr_endline "format_program: Exit (an uncovered construct)"; exit 3
            | Some out ->
                (match Formatter.parse_reading out with
                 | None -> prerr_endline "the formatted text does not parse"; exit 4
                 | Some (prog2, sites2) ->
                     (match Ast_compare.first_difference prog prog2 with
                      | None when Ast_compare.sites_difference prog sites prog2 sites2 <> None ->
                          (match Ast_compare.sites_difference prog sites prog2 sites2 with
                           | Some what -> Printf.printf "differ in the sites (source first): %s\n" what
                           | None -> ())
                      | None ->
                          (match Formatter.format_program prog2 with
                           | Some out2 when out2 = out -> print_endline "the same program, and idempotent"
                           | Some out2 ->
                               let oc = open_out "/tmp/yonfmt_second.yon" in output_string oc out2; close_out oc;
                               let oc = open_out "/tmp/yonfmt_first.yon" in output_string oc out; close_out oc;
                               print_endline "the same program, not idempotent: /tmp/yonfmt_first.yon, /tmp/yonfmt_second.yon"
                           | None -> print_endline "the same program; the second formatting fails")
                      | Some (l1, l2, what) ->
                          Printf.printf "differ: source %d:%d, formatted %d:%d: %s\n"
                            l1.Surface_ast.start_line l1.Surface_ast.start_col
                            l2.Surface_ast.start_line l2.Surface_ast.start_col what))))
  | [_; file] ->
      (match Formatter.safe_format (read_file file) with
       | Some out -> print_string out
       | None -> prerr_endline "not formattable (fail-safe: no output)"; exit 2)
  | _ ->
      prerr_endline "uso: yonfmt [--write|--check] <file.yon>"; exit 64
