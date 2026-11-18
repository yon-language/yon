(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* yonrw — rewrite the nodes of one form in a Yon file and keep every other byte (rewriter.ml).
 *
 *   yonrw <rule> <file.yon>            print the rewritten text
 *   yonrw <rule> --write <file.yon>    rewrite the file in place
 *   yonrw <rule> --check <file.yon>    exit 1 if the file holds nodes of the form
 *   yonrw --rules                      the rules
 *
 * Exit 0: done or nothing to do; 1: --check found the form; 2: the rewrite was refused (the file
 * is left as it was, the reason on stderr); 64: usage. *)

let read_file f = let ic = open_in_bin f in let s = really_input_string ic (in_channel_length ic) in close_in ic; s

let rule_named n =
  match List.find_opt (fun (r : Rewriter.rule) -> r.Rewriter.name = n) Rewriter.rules with
  | Some r -> r
  | None -> prerr_endline ("yonrw: no rule " ^ n ^ " (yonrw --rules)"); exit 64

let () =
  match Array.to_list Sys.argv with
  | [_; "--rules"] -> List.iter (fun (r : Rewriter.rule) -> print_endline r.Rewriter.name) Rewriter.rules
  | [_; rule; mode; file] when mode = "--write" || mode = "--check" ->
      let r = rule_named rule in
      (match Rewriter.rewrite r (read_file file) with
       | Rewriter.Unchanged -> ()
       | Rewriter.Rewritten (text, n) ->
           if mode = "--check" then (Printf.printf "%s: %d nodes of %s\n" file n rule; exit 1)
           else begin
             let oc = open_out_bin file in output_string oc text; close_out oc;
             Printf.printf "%s: %d nodes rewritten\n" file n
           end
       | Rewriter.Refused why -> Printf.eprintf "%s: refused, left as it was: %s\n" file why; exit 2)
  | [_; rule; file] ->
      let r = rule_named rule in
      (match Rewriter.rewrite r (read_file file) with
       | Rewriter.Unchanged -> print_string (read_file file)
       | Rewriter.Rewritten (text, _) -> print_string text
       | Rewriter.Refused why -> Printf.eprintf "%s: refused: %s\n" file why; exit 2)
  | _ -> prerr_endline "usage: yonrw <rule> [--write|--check] <file.yon> | yonrw --rules"; exit 64
