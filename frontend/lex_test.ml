(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
let src = {|reduction Counter of State with multi_shot {
  let count holds 0
  on increment() {
    count becomes count + 1
  }
}|}

let () =
  let lb = Lexing.from_string src in
  let rec aux () =
    let t = Lexer.token lb in
    let s = match t with
      | Parser.REDUCTION -> "REDUCTION"
      | Parser.IDENT s -> Printf.sprintf "IDENT(%s)" s
      | Parser.OF -> "OF"
      | Parser.WITH -> "WITH"
      | Parser.MULTI_SHOT -> "MULTI_SHOT"
      | Parser.LBRACE -> "LBRACE" | Parser.RBRACE -> "RBRACE"
      | Parser.LET -> "LET" | Parser.HOLDS -> "HOLDS"
      | Parser.NUM_LIT n -> Printf.sprintf "NUM(%g)" n
      | Parser.LPAREN -> "LPAREN" | Parser.RPAREN -> "RPAREN"
      | Parser.BECOMES -> "BECOMES"
      | Parser.PLUS -> "PLUS"
      | Parser.EOF -> "EOF"
      | _ -> "?"
    in
    Printf.printf "%s " s;
    if t <> Parser.EOF then aux ()
  in
  aux ();
  print_newline ()
