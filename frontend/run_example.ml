(* run_example.ml — Driver to run a Yon source file end-to-end. *)

let () =
  if Array.length Sys.argv < 2 then begin
    Printf.eprintf "Usage: %s <file.yon>\n" Sys.argv.(0);
    exit 1
  end;
  let path = Sys.argv.(1) in
  let source =
    try
      let ic = open_in path in
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic;
      s
    with Sys_error msg ->
      Printf.eprintf "Cannot read %s: %s\n" path msg;
      exit 1
  in
  (* Register Heyting and stdlib hooks (same setup as main.ml). *)
  Builtins.heyting_hook := Heyting.try_reduce_heyt;
  Builtins.stdlib_hook := Stdlib_runtime.try_reduce_stdlib;
  Reduce.world_tag_setter := Stdlib_runtime.set_current_world_tag;
  Reduce.full_reduce_hook :=
    (fun ctx t -> Builtins.reduce_with_builtins ctx t);
  Printf.printf "═══════════════════════════════════════════════\n";
  Printf.printf " Running %s\n" path;
  Printf.printf "═══════════════════════════════════════════════\n\n";
  (* Phase 1: parse *)
  let lexbuf = Lexing.from_string source in
  Lexing.set_filename lexbuf path;
  let prog =
    try
      Parser.program Lexer.token lexbuf
    with
    | Parser.Error ->
        let pos = lexbuf.Lexing.lex_curr_p in
        Printf.eprintf "Parse error at line %d, column %d\n"
          pos.Lexing.pos_lnum (pos.Lexing.pos_cnum - pos.Lexing.pos_bol);
        exit 2
    | Failure msg ->
        Printf.eprintf "Lex/parse failure: %s\n" msg;
        exit 2
    | Lexer.Lexer_error msg ->
        Printf.eprintf "Lexer error: %s\n" msg;
        exit 2
  in
  Printf.printf "[Phase 1] Parsed %d top-level declarations\n"
    (List.length prog);
  (* Phase 2: type check *)
  let cr = Tycheck.check_program prog in
  Printf.printf "[Phase 2] Type checking: %d errors\n"
    (List.length cr.Tycheck.cr_errors);
  List.iter (fun e ->
    Printf.printf "  ERROR: %s\n" (Tycheck.error_to_string e))
    cr.Tycheck.cr_errors;
  if cr.Tycheck.cr_errors <> [] then exit 3;
  (* Phase 3: desugar *)
  let desugared = Desugar.desugar_program ~env:(Some cr.Tycheck.cr_env) prog in
  Printf.printf "[Phase 3] Desugared to Yon Core IR\n";
  (* Phase 4: reduce *)
  let ctx = Builtins.with_builtins desugared.Desugar.ctx in
  match desugared.Desugar.main with
  | None ->
      Printf.printf "[Phase 4] No `main` entry — looking for `fun main`...\n";
      (* Try to call main() directly. *)
      let call = Ast.App (Ast.Var "main", Ast.Unit) in
      let final = Builtins.reduce_with_builtins ctx call in
      Printf.printf "[Phase 4] Reduced to: %s\n" (Pretty.pp_compact final);
      (match Builtins.decode_number final with
       | Some n -> Printf.printf "Decoded as number: %g\n" n
       | None ->
           match Builtins.decode_string final with
           | Some s -> Printf.printf "Decoded as string: %s\n" s
           | None ->
               match Builtins.decode_bool final with
               | Some b -> Printf.printf "Decoded as bool: %b\n" b
               | None ->
                   match Heyting.decode_heyt final with
                   | Some h ->
                       Printf.printf "Decoded as proposition: %s\n"
                         (Heyting.heyt_to_string h)
                   | None -> Printf.printf "(non-decodable term)\n")
  | Some main_term ->
      let final = Builtins.reduce_with_builtins ctx main_term in
      Printf.printf "[Phase 4] Reduced to: %s\n" (Pretty.pp_compact final);
      (match Builtins.decode_number final with
       | Some n -> Printf.printf "Decoded as number: %g\n" n
       | None ->
           match Builtins.decode_string final with
           | Some s -> Printf.printf "Decoded as string: %s\n" s
           | None ->
               match Builtins.decode_bool final with
               | Some b -> Printf.printf "Decoded as bool: %b\n" b
               | None ->
                   match Heyting.decode_heyt final with
                   | Some h ->
                       Printf.printf "Decoded as proposition: %s\n"
                         (Heyting.heyt_to_string h)
                   | None -> Printf.printf "(non-decodable term)\n")
