(* yonfmt.ml — the `yonfmt` CLI over the shared Formatter library.
 *
 * The formatting logic lives in formatter.ml (also used by the language server's
 * textDocument/formatting), so the CLI and the editor cannot disagree. This file
 * is only argument handling and file I/O.
 *
 *   yonfmt <file>         : print the formatted output to stdout (if safe)
 *   yonfmt --write <file> : rewrite the file in place (if safe)
 *   yonfmt --check <file> : exit 0 if already formatted, 1 if it would change
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
  | [_; file] ->
      (match Formatter.safe_format (read_file file) with
       | Some out -> print_string out
       | None -> prerr_endline "not formattable (fail-safe: no output)"; exit 2)
  | _ ->
      prerr_endline "uso: yonfmt [--write|--check] <file.yon>"; exit 64
