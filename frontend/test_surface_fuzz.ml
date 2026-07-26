(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* test_surface_fuzz.ml — a surface-level fuzzer for the Yon frontend.
 *
 * The metatheory fuzzer (test_metatheory_fuzz.ml) hammers the Core IR. This one
 * hammers the REAL frontend the user hits: it generates Yon SOURCE programs
 * (grammar-guided + corpus mutation + token salad) and runs the actual pipeline
 *   lex -> parse -> tycheck -> infer_place_worlds -> desugar -> type_erase -> emit
 * exactly as `yoner_emit_mlir` does, then asserts the ROBUSTNESS invariant:
 *
 *   the frontend TERMINATES and either ACCEPTS (emits MLIR) or REJECTS CLEANLY
 *   (a parse/lex error, a tycheck diagnostic, or an intended compile-time
 *   rejection). It NEVER CRASHES. In particular, once tycheck has ACCEPTED a
 *   program, desugar+erase+emit must not raise: an accepted program that fails
 *   to lower is a real bug (the `=`-inside-produce Fatal was exactly this class).
 *
 * Clean rejects: Parser.Error / lex Failure / cr_errors<>[] / the intended
 * Type_erase.Higher_order_type_param rejection. Anything else that escapes
 * (Stack_overflow, Not_found, Invalid_argument, Assert_failure, Match_failure,
 * or any exception after tycheck accepted) is a CRASH = a bug we print + fail on.
 *
 * Run:  dune build ./test_surface_fuzz.exe && ./_build/default/test_surface_fuzz.exe [seed] [cases]
 * Exit 0 iff zero crashes.
 *)

(* ---- parse (same front door as eval_runner / yoner_emit_mlir) ---- *)
let parse_string (source : string) : (Surface_ast.program, string) result =
  let lexbuf = Lexing.from_string source in
  try Ok (Parser.program Lexer.token lexbuf)
  with
  | Parser.Error -> Error "parse"
  | Failure _ -> Error "lex"
  | Lexer.Lexer_error _ -> Error "lex"   (* now caught by the drivers too (fixed) *)

type verdict =
  | Reject of string          (* clean: syntax / type / intended reject *)
  | Accept                    (* lowered all the way to MLIR text *)
  | Bug of string * string    (* (stage, exception) -> a crash *)

(* ---- the oracle: run one source through the real pipeline ---- *)
let classify (src : string) : verdict =
  try
    match parse_string src with
    | Error _ -> Reject "syntax"
    | Ok prog ->
      (* From here, tycheck must return diagnostics as data, not raise; and if it
         ACCEPTS, every later stage must lower without raising. *)
      (match (try `Cr (Tycheck.check_program prog) with e -> `E e) with
       | `E e -> Bug ("tycheck", Printexc.to_string e)
       | `Cr cr ->
         if cr.Tycheck.cr_errors <> [] then Reject "type"
         else begin
           let prog =
             match Tycheck.infer_place_worlds prog with Ok p -> p | Error _ -> prog
           in
           match
             (try `Ds (Desugar.desugar_program ~env:(Some cr.Tycheck.cr_env) prog)
              with e -> `E e)
           with
           | `E e -> Bug ("desugar", Printexc.to_string e)
           | `Ds ds ->
             (match
                (try `Er (Type_erase.erase ds)
                 with Type_erase.Higher_order_type_param _ -> `Reject
                    | e -> `E e)
              with
              | `Reject -> Reject "type-erase"
              | `E e -> Bug ("type_erase", Printexc.to_string e)
              | `Er ds ->
                Emit_mlir.set_views_list
                  (List.filter_map (function
                     | Surface_ast.TopView vd ->
                       Some (vd.Surface_ast.vw_name, vd.Surface_ast.vw_of)
                     | _ -> None) prog);
                (match (try ignore (Emit_mlir.emit_program ds); `Ok
                        with Emit_mlir.Cubical_stuck _ -> `Reject
                           | e -> `E e) with
                 | `Ok -> Accept
                 | `Reject -> Reject "cubical-stuck"
                 | `E e -> Bug ("emit", Printexc.to_string e)))
         end)
  with
  | Stack_overflow -> Bug ("stackoverflow", "Stack_overflow")
  (* the real drivers' parse_string catches Parser.Error + Failure but NOT
     Lexer.Lexer_error, so an unexpected character Fatal-crashes the frontend
     instead of yielding a clean syntax diagnostic: model that as a crash. *)
  | Lexer.Lexer_error m -> Bug ("lexer-uncaught", "Lexer_error: " ^ m)

(* ---- generators ---- *)
let kw_pool =
  [| "be"; "holds"; "fun"; "return"; "if"; "then"; "else"; "while"; "do";
     "for"; "every"; "in"; "place"; "internal"; "view"; "move"; "reduction";
     "operation"; "number"; "text"; "true"; "false"; "and"; "or"; "not";
     "visits"; "import"; "topos"; "where";
     (* new surface: metonymic journey + cubical + HIT *)
     "clear"; "back"; "carry"; "along"; "through"; "match";
     "refl"; "transport"; "plam"; "hit"; "hit_elim"; "hcomp"; "comp"; "I0"; "I1" |]
let op_pool = [| "+"; "-"; "*"; "/"; "<"; ">"; "="; "=="; "("; ")"; "{"; "}"; ","; ":"; ";";
                 "++"; "<=>"; "@"; "=>" |]
let fn_pool =
  [| "List.cons"; "List.empty"; "List.head"; "List.tail"; "String.from_int";
     "String.equal"; "IO.print_num"; "Output.print"; "HashSet.add"; "HashSet.empty" |]
(* Simple functions defined by the generated prelude — used by the cubical /
   metonymic generators for `through f` and `f <=> g`. *)
let cubfn_pool = [| "succ"; "pred"; "dbl" |]

let var_name () = String.make 1 (Char.chr (Char.code 'a' + Random.int 6))
let num () = string_of_int (Random.int 1000)

let rec gen_expr d =
  if d <= 0 then (if Random.bool () then num () else var_name ())
  else match Random.int 9 with
    | 0 -> num ()
    | 1 -> var_name ()
    | 2 -> Printf.sprintf "(%s %s %s)" (gen_expr (d-1)) op_pool.(Random.int 8) (gen_expr (d-1))
    | 3 -> Printf.sprintf "%s(%s)" fn_pool.(Random.int (Array.length fn_pool)) (gen_expr (d-1))
    | 4 -> Printf.sprintf "List.cons(%s, %s)" (gen_expr (d-1)) (gen_expr (d-1))
    | 5 -> Printf.sprintf "(%s)" (gen_expr (d-1))
    | 6 -> Printf.sprintf "if %s then %s else %s" (gen_expr (d-1)) (gen_expr (d-1)) (gen_expr (d-1))
    | 7 -> gen_cubical (d-1)                              (* a path value (may type-error, not crash) *)
    | _ -> Printf.sprintf "(%s @ I0)" (gen_cubical (d-1)) (* a path applied -> a point (number) *)

(* Cubical / metonymic expression forms — the journey vocabulary, path algebra,
   univalence, and the HIT recursor. Some type-check, some don't; the fuzzer only
   demands they never CRASH the frontend. *)
and gen_cubical d =
  if d <= 0 then Printf.sprintf "clear %s" (num ())
  else match Random.int 8 with
    | 0 -> Printf.sprintf "clear %s" (num ())
    | 1 -> Printf.sprintf "back (%s)" (gen_cubical (d-1))
    | 2 -> Printf.sprintf "(%s ++ %s)" (gen_cubical (d-1)) (gen_cubical (d-1))
    | 3 -> Printf.sprintf "(%s through %s)" (gen_cubical (d-1)) cubfn_pool.(Random.int 3)
    | 4 -> Printf.sprintf "refl(%s)" (num ())
    | 5 -> Printf.sprintf "(%s @ I0)" (gen_cubical (d-1))
    | 6 -> Printf.sprintf "carry %s along (%s <=> %s)" (num ())
             cubfn_pool.(Random.int 3) cubfn_pool.(Random.int 3)
    | _ -> Printf.sprintf "match hit(base) { base => %s, loop => plam i => %s }"
             (num ()) (num ())

let rec gen_stmt d =
  match Random.int 7 with
  | 0 -> Printf.sprintf "be %s holds %s" (var_name ()) (gen_expr d)
  | 1 -> Printf.sprintf "%s = %s" (var_name ()) (gen_expr d)
  | 2 -> Printf.sprintf "if %s then { %s } else { %s }" (gen_expr d) (gen_stmt (d-1)) (gen_stmt (d-1))
  | 3 -> Printf.sprintf "while %s do { %s }" (gen_expr d) (gen_stmt (d-1))
  | 4 -> Printf.sprintf "for every %s in %s { %s }" (var_name ()) (gen_expr d) (gen_stmt (d-1))
  | 5 -> Printf.sprintf "be _ holds %s" (gen_expr d)
  | _ -> "return " ^ gen_expr d

(* Helper functions the cubical generators reference (succ/pred are inverse, so
   a fraction of the generated univalence terms even type-check). *)
let cub_prelude =
  "fun succ(n: Number): Number { return n + 1 }\n\
   fun pred(n: Number): Number { return n - 1 }\n\
   fun dbl(n: Number): Number { return n + n }\n"

let gen_grammar () =
  let n = 1 + Random.int 5 in
  let body = String.concat "\n  " (List.init n (fun _ -> gen_stmt 3)) in
  Printf.sprintf "%sfun main(): Number {\n  %s\n  return %s\n}"
    cub_prelude body (gen_expr 2)

(* corpus of real-ish seeds to mutate (near the valid manifold, where crashes hide) *)
let seeds = [|
  "fun main(): Number {\n  be x holds 0\n  return x\n}";
  "fun main(): Number {\n  be s holds 0\n  be i holds 0\n  while i < 5 do { s = s + i  i = i + 1 }\n  return s\n}";
  "fun deposit_net(amount: Number): Number { return amount - amount / 20 }\nfun main(): Number {\n  be d holds List.cons(100, List.cons(60, List.empty(0)))\n  be t holds 0\n  for every x in d { t = t + deposit_net(x) }\n  return t\n}";
  "fun main(): Number {\n  iter 4 do { be _ holds 0 }\n  return 8\n}";
  "internal fun k(x: Number): Number { return x * 1789 }\nfun main(): Number { return k(2) }";
  "fun main(): Number {\n  be g holds HashSet.add(HashSet.empty(0), 1445)\n  return HashSet.size(g)\n}";
  (* metonymic / cubical / generics seeds — near the new-syntax manifold *)
  "fun succ(n: Number): Number { return n + 1 }\nfun pred(n: Number): Number { return n - 1 }\nfun main(): Number {\n  be b holds succ <=> pred\n  return carry 10 along b\n}";
  "fun main(): Number {\n  be p holds back (clear 5)\n  return p @ I0\n}";
  "fun dbl(n: Number): Number { return n + n }\nfun main(): Number {\n  be s holds clear 7 ++ (clear 5 through dbl)\n  return s @ I0\n}";
  "fun main(): Number {\n  return match hit(base) { base => 42, loop => plam i => 42 }\n}";
  "fun identity<T>(x: T): T { return x }\nfun main(): Number { return identity(7) }";
  "fun unwrap(b: Box<number>): Number { return b.value }\nfun main(): Number { return 0 }";
|]

let rand_token () =
  match Random.int 4 with
  | 0 -> kw_pool.(Random.int (Array.length kw_pool))
  | 1 -> op_pool.(Random.int (Array.length op_pool))
  | 2 -> num ()
  | _ -> var_name ()

let tokenize s =
  let n = String.length s in
  let is_word c =
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9') || c = '_' || c = '.' in
  let toks = ref [] and i = ref 0 in
  while !i < n do
    let c = s.[!i] in
    if c = ' ' || c = '\n' || c = '\t' || c = '\r' then incr i
    else if is_word c then begin
      let j = ref !i in
      while !j < n && is_word s.[!j] do incr j done;
      toks := String.sub s !i (!j - !i) :: !toks; i := !j
    end else begin toks := String.make 1 c :: !toks; incr i end
  done;
  List.rev !toks

let mutate src =
  let lst = ref (tokenize src) in
  let m = 1 + Random.int 3 in
  for _ = 1 to m do
    let l = List.length !lst in
    if l > 0 then begin
      let k = Random.int l in
      lst := (match Random.int 6 with
        | 0 -> List.filteri (fun i _ -> i <> k) !lst                                  (* delete *)
        | 1 -> List.concat (List.mapi (fun i x -> if i = k then [x; x] else [x]) !lst) (* dup *)
        | 2 -> List.mapi (fun i x -> if i = k then rand_token () else x) !lst          (* replace *)
        | 3 -> List.filteri (fun i _ -> i < k) !lst                                    (* truncate *)
        | 4 -> List.concat (List.mapi (fun i x -> if i = k then [rand_token (); x] else [x]) !lst) (* insert *)
        | _ -> (match !lst with a :: b :: r when k = 0 -> b :: a :: r | _ -> !lst))    (* swap head *)
    end
  done;
  String.concat " " !lst

let gen_salad () =
  let n = 3 + Random.int 30 in
  String.concat " " (List.init n (fun _ -> rand_token ()))

let gen_one () =
  match Random.int 10 with
  | 0 | 1 | 2 | 3 -> gen_grammar ()                          (* 40% grammar-guided *)
  | 4 | 5 | 6 | 7 -> mutate seeds.(Random.int (Array.length seeds))  (* 40% corpus mutation *)
  | _ -> gen_salad ()                                        (* 20% token salad *)

let () =
  let seed  = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 20260701 in
  let cases = if Array.length Sys.argv > 2 then int_of_string Sys.argv.(2) else 4000 in
  Random.init seed;
  let acc = ref 0 and rej = ref 0 and bugs = ref [] in
  for _ = 1 to cases do
    let src = gen_one () in
    (match classify src with
     | Accept   -> incr acc
     | Reject _ -> incr rej
     | Bug (stage, exn) -> bugs := (stage, exn, src) :: !bugs)
  done;
  Printf.printf "surface-fuzz (seed %d, %d cases): accept=%d reject=%d BUGS=%d\n"
    seed cases !acc !rej (List.length !bugs);
  (match !bugs with
   | [] -> ()
   | bs ->
     Printf.printf "\n--- crashes (accepted-or-parseable input the frontend could not handle) ---\n";
     (* dedup by (stage, exn) so one bug class does not flood the report *)
     let seen = Hashtbl.create 16 in
     List.iter (fun (stage, exn, src) ->
       let key = stage ^ "|" ^ exn in
       if not (Hashtbl.mem seen key) then begin
         Hashtbl.add seen key ();
         Printf.printf "\n[%s] %s\n  SRC: %s\n" stage exn
           (String.concat " | " (String.split_on_char '\n' src))
       end) bs;
     Printf.printf "\n(%d total, %d distinct classes)\n"
       (List.length bs) (Hashtbl.length seen));
  exit (if !bugs = [] then 0 else 1)
