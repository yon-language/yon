(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* yon_lsp.ml — Language Server Protocol implementation for Yon.
 *
 * Runs on the client (stdin/stdout, JSON-RPC), nothing to host. Reuses the
 * existing frontend: parser, lexer, type checker. An LSP is a protocol wrapper
 * around parse + check; no new language logic here.
 *
 * Initial capabilities: real-time diagnostics (parse and type errors
 * inline in the editor) on didOpen / didChange. *)

(* ─── Diagnostics: the core, testable without the protocol ──────────── *)

type diag = {
  d_line : int;     (* 0-based, as LSP requires *)
  d_col : int;      (* 0-based *)
  d_end_line : int;
  d_end_col : int;
  d_severity : int; (* 1 = Error *)
  d_msg : string;
  d_code : string option;  (* the stable diagnostic code, e.g. "E3001" *)
}

(* Parse the source. On a parse/lex error, produce a single diagnostic with
 * the lexbuf position. On success, return the AST for type checking. *)
let parse_source (source : string)
    : (Surface_ast.program, diag) result =
  let lexbuf = Lexing.from_string source in
  try Ok (Parser.program Lexer.token lexbuf)
  with
  | Parser.Error ->
      let p = lexbuf.Lexing.lex_curr_p in
      let line = p.Lexing.pos_lnum - 1 in            (* LSP 0-based *)
      let col = p.Lexing.pos_cnum - p.Lexing.pos_bol in
      Error { d_line = line; d_col = col;
              d_end_line = line; d_end_col = col + 1;
              d_severity = 1;
              d_msg = "Syntax error";
              d_code = Some (Error_codes.id Error_codes.Parse_syntax) }
  | Lexer.Lexer_error msg ->
      let p = lexbuf.Lexing.lex_curr_p in
      let line = p.Lexing.pos_lnum - 1 in
      let col = p.Lexing.pos_cnum - p.Lexing.pos_bol in
      Error { d_line = line; d_col = col;
              d_end_line = line; d_end_col = col + 1;
              d_severity = 1;
              d_msg = Printf.sprintf "Errore lessicale: %s" msg;
              d_code = Some (Error_codes.id Error_codes.Lex_bad_token) }

(* Convert a frontend type_error into an LSP diagnostic. The frontend
 * locations are 1-based (start_line/start_col); LSP is 0-based. *)
let type_error_to_diag (e : Tycheck.type_error) : diag =
  let l = e.Tycheck.err_loc in
  let line0 = max 0 (l.Surface_ast.start_line - 1) in
  let col0 = max 0 l.Surface_ast.start_col in
  let eline0 = max 0 (l.Surface_ast.end_line - 1) in
  let ecol0 = max 0 l.Surface_ast.end_col in
  (* if the location is dummy (0,0,0,0) or degenerate, highlight at least 1 char *)
  let eline0, ecol0 =
    if eline0 = line0 && ecol0 <= col0 then (line0, col0 + 1)
    else (eline0, ecol0)
  in
  { d_line = line0; d_col = col0;
    d_end_line = eline0; d_end_col = ecol0;
    d_severity = 1;
    d_msg = e.Tycheck.err_msg;
    d_code = Some (Error_codes.id Error_codes.Type_check) }

(* Source -> list of diagnostics. Empty = valid program.
 * Parse error: one diagnostic, then we stop (we cannot type check).
 * Type errors: all the ones collected by check_program (multi-error). *)
let diagnostics_of_source (source : string) : diag list =
  match parse_source source with
  | Error d -> [d]
  | Ok prog ->
      let result = Tycheck.check_program prog in
      List.map type_error_to_diag result.Tycheck.cr_errors

(* "file:///abs/path" -> "/abs/path". Minimal: the common editor case. *)
let path_of_uri (uri : string) : string =
  if String.length uri >= 7 && String.sub uri 0 7 = "file://" then
    let rest = String.sub uri 7 (String.length uri - 7) in
    if String.length rest > 0 && rest.[0] = '/' then rest else "/" ^ rest
  else uri

(* A canonical project Diagnostic (Error_codes.t) -> an LSP diagnostic. The range
 * is 1-based surface coordinates; LSP is 0-based. *)
let diag_of_diagnostic (d : Error_codes.t) : diag =
  let l = d.Error_codes.range in
  let line0 = max 0 (l.Surface_ast.start_line - 1) in
  let col0 = max 0 l.Surface_ast.start_col in
  let eline0 = max 0 (l.Surface_ast.end_line - 1) in
  let ecol0 = max 0 l.Surface_ast.end_col in
  let eline0, ecol0 =
    if eline0 = line0 && ecol0 <= col0 then (line0, col0 + 1) else (eline0, ecol0) in
  { d_line = line0; d_col = col0; d_end_line = eline0; d_end_col = ecol0;
    d_severity = (match Error_codes.severity d.Error_codes.code with
                  | Error_codes.Error -> 1 | Error_codes.Warning -> 2);
    d_msg = d.Error_codes.message;
    d_code = Some (Error_codes.id d.Error_codes.code) }

(* Diagnostics for an open document: the single-file parse + type errors, PLUS
 * the whole-program semantic diagnostics (drop, ...) when the file lives inside a
 * package. The open buffer's unsaved text is substituted into the project load,
 * so the editor sees exactly what the compiler would. The semantic pass runs on
 * the merged program (whole-program is required for the drop analysis); its
 * results are attributed to THIS document by matching each diagnostic's site
 * against the drop sites parsed from this file (locations carry no file of their
 * own yet). *)
(* Lint warnings (Wxxx) for the open buffer: purely syntactic, so they run on this
 * document alone, in project mode or not. Rendered as Warning diagnostics. *)
let lint_diags (source : string) : diag list =
  match parse_source source with
  | Error _ -> []
  | Ok prog -> List.map diag_of_diagnostic (Linter.lint_program prog)

let diagnostics_of_document (path : string) (source : string) : diag list =
  match Project.root_of_file path with
  | None ->
      (* not in a package: single-file parse + type errors + lint *)
      diagnostics_of_source source @ lint_diags source
  | Some root ->
      (match parse_source source with
       | Error d -> [d]                     (* parse error: cannot type-check *)
       | Ok _ ->
           let loaded = Project.load ~root ~overrides:[ (path, source) ] () in
           (* Type errors AND whole-program semantic diagnostics (drop E3001/E3002,
              wire boundary E3010), both computed over the WHOLE package -- so a
              cross-file reference (a place/type/function in a sibling file) resolves
              instead of tripping a false "unknown ..." -- then attributed to THIS
              document by the exact file each diagnostic's location carries (Project
              stamps the parsing file onto every location). Project-wide diagnostics
              with no file (layout, entrypoint, orphan space -- dummy location) do
              not attach to the cursor and are left to the compiler's CLI. Lint
              warnings are appended from the open buffer. *)
           let mine (d : Error_codes.t) = d.Error_codes.range.Surface_ast.file = path in
           (* Lint the WHOLE package too: dead-function is a whole-program rule (a
              function unused in this buffer may be reached from a sibling file), so
              linting the merged program and attributing by file avoids that false
              positive. *)
           (Project.typecheck_diags loaded |> List.filter mine |> List.map diag_of_diagnostic)
           @ (Project.check_all loaded |> List.filter mine |> List.map diag_of_diagnostic)
           @ (Linter.lint_program loaded.Project.merged
              |> List.filter mine |> List.map diag_of_diagnostic))

(* ─── Pretty-print of a surface type (for hover and symbols) ────────── *)

let rec ty_str (t : Surface_ast.ty) : string =
  match t with
  | Surface_ast.TyPrim s -> s
  | Surface_ast.TyPrimIn (s, _) -> s
  | Surface_ast.TySum _ -> "sum"
  | Surface_ast.TySumIn _ -> "sum"
  | Surface_ast.TyList t -> "list of " ^ ty_str t
  | Surface_ast.TyMap (k, v) -> "map of " ^ ty_str k ^ " to " ^ ty_str v
  | Surface_ast.TyStream t -> "stream of " ^ ty_str t
  | Surface_ast.TyUser s -> s
  | Surface_ast.TyVar s -> s
  | Surface_ast.TyMetaVar n -> Printf.sprintf "?%d" n
  | Surface_ast.TyUniverse n -> Printf.sprintf "Type_%d" n
  | Surface_ast.TyPi (x, a, b) ->
      Printf.sprintf "Pi(%s:%s).%s" x (ty_str a) (ty_str b)
  | Surface_ast.TySigma (x, a, b) ->
      Printf.sprintf "Sigma(%s:%s).%s" x (ty_str a) (ty_str b)
  | Surface_ast.TyId _ -> "Id"
  | Surface_ast.TyHeytInt n -> Printf.sprintf "heyt_int<%d>" n
  | _ -> "_"

(* ─── Document symbols: outline di world/place/fun/move/reduction ───── *)

(* SymbolKind LSP: 5=Class, 12=Function, 13=Variable, 23=Struct, 8=Field *)
type symbol = {
  s_name : string;
  s_kind : int;
  s_detail : string;
  s_loc : Surface_ast.location;
}

let fun_signature (fn : Surface_ast.fun_decl) : string =
  let params =
    String.concat ", "
      (List.map (fun (p : Surface_ast.param) ->
         p.Surface_ast.param_name ^ ": " ^ ty_str p.Surface_ast.param_ty)
        fn.Surface_ast.fn_params)
  in
  let ret = match fn.Surface_ast.fn_return with
    | Some t -> ty_str t | None -> "unit" in
  Printf.sprintf "fun %s(%s): %s" fn.Surface_ast.fn_name params ret

let symbols_of_program (prog : Surface_ast.program) : symbol list =
  List.filter_map (fun (d : Surface_ast.top_decl) ->
    match d with
    | Surface_ast.TopWorld wd ->
        Some { s_name = wd.Surface_ast.wd_name; s_kind = 5;
               s_detail = "world"; s_loc = wd.Surface_ast.wd_loc }
    | Surface_ast.TopPlace pd ->
        Some { s_name = pd.Surface_ast.pd_name; s_kind = 23;
               s_detail = "place in " ^ pd.Surface_ast.pd_world;
               s_loc = pd.Surface_ast.pd_loc }
    | Surface_ast.TopFun fn ->
        let det = (if fn.Surface_ast.fn_internal then "internal " else "") ^ fun_signature fn in
        Some { s_name = fn.Surface_ast.fn_name; s_kind = 12;
               s_detail = det; s_loc = fn.Surface_ast.fn_loc }
    | Surface_ast.TopMove mv ->
        Some { s_name = mv.Surface_ast.mv_name; s_kind = 12;
               s_detail = "move"; s_loc = mv.Surface_ast.mv_loc }
    | Surface_ast.TopReduction rd ->
        Some { s_name = rd.Surface_ast.rd_name; s_kind = 12;
               s_detail = "reduction"; s_loc = rd.Surface_ast.rd_loc }
    | Surface_ast.TopView vd ->
        Some { s_name = vd.Surface_ast.vw_name; s_kind = 5;
               s_detail = "view"; s_loc = vd.Surface_ast.vw_loc }
    | Surface_ast.TopImport (s, loc) ->
        Some { s_name = s; s_kind = 2 (* Module *);
               s_detail = "import"; s_loc = loc }
    | Surface_ast.TopImportSym (m, n, alias, loc) ->
        let nm = match alias with Some a -> a | None -> n in
        Some { s_name = nm; s_kind = 2 (* Module *);
               s_detail = Printf.sprintf "import %s::%s" m n; s_loc = loc }
    | Surface_ast.TopImportFrom (m, n, sp, loc) ->
        Some { s_name = n; s_kind = 2 (* Module *);
               s_detail = Printf.sprintf "import %s::%s from Space %s" m n sp;
               s_loc = loc }
    | _ -> None
  ) prog

(* ─── Hover: hit-test a position -> expr node -> description ─────────── *)

(* Is the position (line0, col0) inside a 1-based span? *)
let pos_in_loc (line0 : int) (col0 : int) (l : Surface_ast.location) : bool =
  let line = line0 + 1 and col = col0 in  (* loc is 1-based on line, 0-based on col *)
  let after_start =
    line > l.Surface_ast.start_line ||
    (line = l.Surface_ast.start_line && col >= l.Surface_ast.start_col) in
  let before_end =
    line < l.Surface_ast.end_line ||
    (line = l.Surface_ast.end_line && col <= l.Surface_ast.end_col) in
  after_start && before_end

(* The width of a span (to choose the innermost = narrowest node). *)
let loc_width (l : Surface_ast.location) : int =
  (l.Surface_ast.end_line - l.Surface_ast.start_line) * 10000
  + (l.Surface_ast.end_col - l.Surface_ast.start_col)

(* Find the innermost sub-node of the expr containing the position and return
 * its (description, loc). Best-effort over the most common constructs. *)
let rec hover_expr (line0 : int) (col0 : int) (e : Surface_ast.expr)
    : (string * Surface_ast.location) option =
  let here desc l =
    if pos_in_loc line0 col0 l then Some (desc, l) else None in
  (* try the children first (the innermost), then the node itself *)
  let pick children self =
    let from_children =
      List.fold_left (fun acc child ->
        match hover_expr line0 col0 child, acc with
        | Some (d, l), Some (_, la) -> if loc_width l < loc_width la then Some (d, l) else acc
        | Some r, None -> Some r
        | None, _ -> acc) None children in
    match from_children with Some r -> Some r | None -> self ()
  in
  match e with
  | Surface_ast.ELit (lit, l) ->
      let d = match lit with
        | Surface_ast.LitNumber _ -> "number (letterale)"
        | Surface_ast.LitString _ -> "text (letterale)"
        | _ -> "letterale" in
      here d l
  | Surface_ast.EVar (name, l) -> here (Printf.sprintf "`%s`" name) l
  | Surface_ast.ECall (name, args, l) ->
      pick args (fun () -> here (Printf.sprintf "call to `%s`" name) l)
  | Surface_ast.EBinop (_, a, b, l) ->
      pick [a; b] (fun () -> here "operazione binaria" l)
  | Surface_ast.EField (obj, fld, l) ->
      pick [obj] (fun () -> here (Printf.sprintf "field `.%s`" fld) l)
  | Surface_ast.EParen (inner, l) ->
      pick [inner] (fun () -> here "(...)" l)
  | Surface_ast.EIfThenElse (c, t, f, l) ->
      pick [c; t; f] (fun () -> here "if/then/else" l)
  | Surface_ast.ENot (a, l) -> pick [a] (fun () -> here "not" l)
  | _ -> None

(* Extract the statement-expressions from a fun body for the hit-test
 * (best-effort: searches all the expressions of the TopFun declarations). *)
let hover_at (prog : Surface_ast.program) (line0 : int) (col0 : int)
    : string option =
  (* collect all the top-level expressions of the function bodies *)
  let best = ref None in
  let consider e =
    match hover_expr line0 col0 e with
    | Some (d, l) ->
        (match !best with
         | Some (_, lb) -> if loc_width l < loc_width lb then best := Some (d, l)
         | None -> best := Some (d, l))
    | None -> () in
  let rec walk_stmt (s : Surface_ast.stmt) =
    let open Surface_ast in
    match s with
    | SLet (_, e, _) -> consider e
    | SAssignHolds (_, e, _) -> consider e
    | SAssignBecomes (_, e, _) -> consider e
    | SReturn (e, _) -> consider e
    | SEmit (e, _) -> consider e
    | SCall (_, args, _) -> List.iter consider args
    | SWhen (_, body, branches, otherwise, _) ->
        List.iter walk_stmt body;
        List.iter (fun (_, b) -> List.iter walk_stmt b) branches;
        (match otherwise with Some b -> List.iter walk_stmt b | None -> ())
    | SForEvery (_, _, e, body, _) -> consider e; List.iter walk_stmt body
    | SInSequence (_, e, body, _) -> consider e; List.iter walk_stmt body
    | SRepeat (_, body, otherwise, _) ->
        List.iter walk_stmt body;
        (match otherwise with Some b -> List.iter walk_stmt b | None -> ())
    | SForever (body, _) -> List.iter walk_stmt body
    | SScope (_, body, e, _) -> List.iter walk_stmt body; consider e
    | SProduce (body, _) -> List.iter walk_stmt body
    | SForces (_, _, body, _) -> List.iter walk_stmt body
    | SIter (e, body, _) -> consider e; List.iter walk_stmt body
    | SWhile (e, body, _) -> consider e; List.iter walk_stmt body
    | _ -> ()
  and walk_fun (fn : Surface_ast.fun_decl) =
    List.iter walk_stmt fn.Surface_ast.fn_body
  in
  List.iter (function
    | Surface_ast.TopFun fn -> walk_fun fn
    | _ -> ()) prog;
  match !best with Some (d, _) -> Some d | None -> None

(* ─── Completion: keywords + top-level names in scope ───────────────── *)

let keywords = [
  "be"; "place"; "fun"; "holds"; "return"; "operation"; "import"; "as"; "internal"; "from";
  "topos"; "subcontains"; "uses"; "algebra"; "law"; "verify"; "move"; "reduction"; "view";
  "with"; "effects"; "is"; "if"; "then"; "else"; "where";
  "commutative"; "associative"; "monotone"; "Additive"; "TropicalMax";
  "TropicalMin"; "Multiplicative"; "BooleanOr"; "BooleanAnd"; "Gcd";
]

let completions_of_program (prog : Surface_ast.program) : (string * int) list =
  (* CompletionItemKind: 14=Keyword, 3=Function, 7=Class, 6=Variable *)
  let kw = List.map (fun k -> (k, 14)) keywords in
  let names = List.filter_map (fun (d : Surface_ast.top_decl) ->
    match d with
    | Surface_ast.TopFun fn -> Some (fn.Surface_ast.fn_name, 3)
    | Surface_ast.TopPlace pd -> Some (pd.Surface_ast.pd_name, 7)
    | Surface_ast.TopWorld wd -> Some (wd.Surface_ast.wd_name, 7)
    | Surface_ast.TopImportSym (m, n, alias, _) ->
        (* the local usable name: the alias, or the qualified m::n *)
        Some ((match alias with Some a -> a | None -> m ^ "::" ^ n), 3)
    | Surface_ast.TopImportFrom (m, n, _, _) ->
        Some (m ^ "::" ^ n, 3)
    | _ -> None) prog in
  kw @ names

(* ─── minimal JSON (no external dependencies) ─────────────────────────── *)

(* Escape a string for JSON. *)
let json_escape (s : string) : string =
  let buf = Buffer.create (String.length s + 8) in
  String.iter (fun c ->
    match c with
    | '"'  -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | c when Char.code c < 0x20 ->
        Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
    | c -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

let diag_to_json (d : diag) : string =
  let code = match d.d_code with
    | Some c -> Printf.sprintf {|,"code":"%s"|} (json_escape c)
    | None -> "" in
  Printf.sprintf
    {|{"range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}},"severity":%d,"source":"yon"%s,"message":"%s"}|}
    d.d_line d.d_col d.d_end_line d.d_end_col d.d_severity code (json_escape d.d_msg)

(* ─── Minimal JSON-RPC parsing for the fields we need ───────────────── *)

(* Extract the string value of a top-level key (a simple greedy match).
 * Enough for "method", "uri", and "text". This is not a full JSON parser: LSP
 * editors send well-formed JSON and we only need a few fields. For "text" we
 * use an extraction that respects escapes. *)
let extract_string_field (json : string) (key : string) : string option =
  let pat = Printf.sprintf "\"%s\"" key in
  match Str.bounded_split (Str.regexp_string pat) json 2 with
  | [_; rest] ->
      (* rest starts after the key; skip spaces and ':' *)
      let i = ref 0 in
      let n = String.length rest in
      while !i < n && (rest.[!i] = ':' || rest.[!i] = ' ') do incr i done;
      if !i < n && rest.[!i] = '"' then begin
        incr i;
        let buf = Buffer.create 64 in
        let stop = ref false in
        while not !stop && !i < n do
          let c = rest.[!i] in
          if c = '\\' && !i + 1 < n then begin
            let nx = rest.[!i + 1] in
            (match nx with
             | 'n' -> Buffer.add_char buf '\n'
             | 'r' -> Buffer.add_char buf '\r'
             | 't' -> Buffer.add_char buf '\t'
             | '"' -> Buffer.add_char buf '"'
             | '\\' -> Buffer.add_char buf '\\'
             | '/' -> Buffer.add_char buf '/'
             | 'u' when !i + 5 < n ->
                 let hex = String.sub rest (!i + 2) 4 in
                 (try Buffer.add_char buf (Char.chr (int_of_string ("0x" ^ hex)))
                  with _ -> ());
                 i := !i + 4
             | c -> Buffer.add_char buf c);
            i := !i + 2
          end else if c = '"' then begin
            stop := true; incr i
          end else begin
            Buffer.add_char buf c; incr i
          end
        done;
        Some (Buffer.contents buf)
      end else None
  | _ -> None

(* ─── Server JSON-RPC su stdin/stdout ───────────────────────────────── *)

(* Read an LSP message: header "Content-Length: N\r\n\r\n" + N bytes of body. *)
let read_message (ic : in_channel) : string option =
  let rec read_headers content_length =
    let line = try input_line ic with End_of_file -> raise Exit in
    let line = if String.length line > 0 && line.[String.length line - 1] = '\r'
               then String.sub line 0 (String.length line - 1) else line in
    if line = "" then content_length
    else
      let cl =
        try Scanf.sscanf line "Content-Length: %d" (fun n -> Some n)
        with _ -> content_length
      in
      read_headers cl
  in
  try
    match read_headers None with
    | None -> None
    | Some n ->
        let body = really_input_string ic n in
        Some body
  with Exit | End_of_file -> None

let write_message (oc : out_channel) (body : string) : unit =
  Printf.fprintf oc "Content-Length: %d\r\n\r\n%s" (String.length body) body;
  flush oc

(* Response to the "initialize" request: declares the server capabilities.
 * textDocumentSync = 1 (Full): the client sends the entire text on every change.
 * Also announces hover, document symbols, completion, and document formatting. *)
let initialize_response (id : string) : string =
  Printf.sprintf
    {|{"jsonrpc":"2.0","id":%s,"result":{"capabilities":{"textDocumentSync":1,"hoverProvider":true,"documentSymbolProvider":true,"completionProvider":{"triggerCharacters":["."]},"documentFormattingProvider":true}}}|}
    id

(* JSON for the documentSymbol response. *)
let symbols_to_json (syms : symbol list) : string =
  let one (s : symbol) =
    let l = s.s_loc in
    let sl = max 0 (l.Surface_ast.start_line - 1) in
    let sc = max 0 l.Surface_ast.start_col in
    let el = max 0 (l.Surface_ast.end_line - 1) in
    let ec = max 0 l.Surface_ast.end_col in
    Printf.sprintf
      {|{"name":"%s","detail":"%s","kind":%d,"range":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}},"selectionRange":{"start":{"line":%d,"character":%d},"end":{"line":%d,"character":%d}}}|}
      (json_escape s.s_name) (json_escape s.s_detail) s.s_kind
      sl sc el ec sl sc el ec
  in
  "[" ^ String.concat "," (List.map one syms) ^ "]"

let completions_to_json (items : (string * int) list) : string =
  let one (label, kind) =
    Printf.sprintf {|{"label":"%s","kind":%d}|} (json_escape label) kind in
  "[" ^ String.concat "," (List.map one items) ^ "]"

let publish_diagnostics (uri : string) (diags : diag list) : string =
  let arr = String.concat "," (List.map diag_to_json diags) in
  Printf.sprintf
    {|{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"%s","diagnostics":[%s]}}|}
    (json_escape uri) arr

(* A whole-document formatting response: a single TextEdit replacing the entire
 * buffer with the formatted text, or [] when the formatter declines (fail-safe:
 * an uncovered construct or a non-idempotent result), leaving the buffer as is.
 * The shared Formatter is the same code the `yonfmt` CLI runs. *)
let formatting_edits (text : string) : string =
  match Formatter.safe_format text with
  | None -> "[]"
  | Some out ->
      (* end = the position just past the document's last character *)
      let el = ref 0 and ec = ref 0 in
      String.iter (fun c -> if c = '\n' then (incr el; ec := 0) else incr ec) text;
      Printf.sprintf
        {|[{"range":{"start":{"line":0,"character":0},"end":{"line":%d,"character":%d}},"newText":"%s"}]|}
        !el !ec (json_escape out)

(* Extract the id (which may be a number or a string) as raw text to reuse. *)
let extract_id (json : string) : string =
  (* find "id": and take the token up to a comma or brace *)
  try
    let idx = Str.search_forward (Str.regexp "\"id\"[ ]*:[ ]*") json 0 in
    let start = idx + (String.length (Str.matched_string json)) in
    let n = String.length json in
    let j = ref start in
    if !j < n && json.[!j] = '"' then begin
      incr j;
      let s = !j in
      while !j < n && json.[!j] <> '"' do incr j done;
      "\"" ^ String.sub json s (!j - s) ^ "\""
    end else begin
      let s = !j in
      while !j < n && json.[!j] <> ',' && json.[!j] <> '}' do incr j done;
      String.trim (String.sub json s (!j - s))
    end
  with Not_found -> "null"

let extract_method (json : string) : string =
  match extract_string_field json "method" with Some m -> m | None -> ""

(* Extract an integer field (e.g. "line", "character") from the JSON. *)
let extract_int_field (json : string) (key : string) : int option =
  try
    let re = Str.regexp (Printf.sprintf "\"%s\"[ ]*:[ ]*\\([0-9]+\\)" key) in
    let _ = Str.search_forward re json 0 in
    Some (int_of_string (Str.matched_group 1 json))
  with Not_found -> None

let run_server () : unit =
  let ic = stdin in
  let oc = stdout in
  set_binary_mode_in ic true;
  set_binary_mode_out oc true;
  (* document store: uri -> current text. Hover/symbol/completion operate on
   * this, because they arrive after didOpen on a uri, without the text in the
   * body. *)
  let docs : (string, string) Hashtbl.t = Hashtbl.create 16 in
  let respond id result_json =
    write_message oc
      (Printf.sprintf {|{"jsonrpc":"2.0","id":%s,"result":%s}|} id result_json) in
  let parse_doc uri =
    match Hashtbl.find_opt docs uri with
    | None -> None
    | Some text -> (match parse_source text with Ok p -> Some p | Error _ -> None) in
  let rec loop () =
    match read_message ic with
    | None -> ()
    | Some body ->
        let meth = extract_method body in
        (match meth with
         | "initialize" ->
             write_message oc (initialize_response (extract_id body))
         | "initialized" -> ()
         | "textDocument/didOpen" | "textDocument/didChange" ->
             (match extract_string_field body "uri",
                    extract_string_field body "text" with
              | Some uri, Some text ->
                  Hashtbl.replace docs uri text;
                  let diags = diagnostics_of_document (path_of_uri uri) text in
                  write_message oc (publish_diagnostics uri diags)
              | _ -> ())
         | "textDocument/hover" ->
             let id = extract_id body in
             (match extract_string_field body "uri",
                    extract_int_field body "line",
                    extract_int_field body "character" with
              | Some uri, Some line, Some col ->
                  (match parse_doc uri with
                   | Some prog ->
                       (match hover_at prog line col with
                        | Some desc ->
                            respond id (Printf.sprintf
                              {|{"contents":{"kind":"markdown","value":"%s"}}|}
                              (json_escape desc))
                        | None -> respond id "null")
                   | None -> respond id "null")
              | _ -> respond id "null")
         | "textDocument/documentSymbol" ->
             let id = extract_id body in
             (match extract_string_field body "uri" with
              | Some uri ->
                  (match parse_doc uri with
                   | Some prog -> respond id (symbols_to_json (symbols_of_program prog))
                   | None -> respond id "[]")
              | None -> respond id "[]")
         | "textDocument/completion" ->
             let id = extract_id body in
             (match extract_string_field body "uri" with
              | Some uri ->
                  let items = match parse_doc uri with
                    | Some prog -> completions_of_program prog
                    | None -> List.map (fun k -> (k, 14)) keywords in
                  respond id (completions_to_json items)
              | None -> respond id (completions_to_json
                         (List.map (fun k -> (k, 14)) keywords)))
         | "textDocument/formatting" ->
             let id = extract_id body in
             (match extract_string_field body "uri" with
              | Some uri ->
                  (match Hashtbl.find_opt docs uri with
                   | Some text -> respond id (formatting_edits text)
                   | None -> respond id "[]")
              | None -> respond id "[]")
         | "shutdown" ->
             respond (extract_id body) "null"
         | "exit" -> raise Exit
         | _ -> ());
        loop ()
  in
  (try loop () with Exit -> ())

(* ─── Entry point + test mode ───────────────────────────────────────── *)

let () =
  (* `yon_lsp --check <file>`: one-shot diagnostic mode (for tests and CI),
   * prints the diagnostics in a readable format and exits with code = #errors.
   * `yon_lsp`: LSP server mode (stdin/stdout). *)
  if Array.length Sys.argv >= 3 && Sys.argv.(1) = "--check" then begin
    let target = Sys.argv.(2) in
    let diags =
      if Sys.file_exists target && Sys.is_directory target then
        (* Whole-project mode: the canonical check_all, UNFILTERED. Used by the
           differential gate to compare the module's verdict against the driver. *)
        Project.check_all (Project.load ~root:target ())
        |> List.map diag_of_diagnostic
      else
        let ic = open_in target in
        let n = in_channel_length ic in
        let source = really_input_string ic n in
        close_in ic;
        diagnostics_of_document target source
    in
    List.iter (fun d ->
      Printf.printf "%d:%d-%d:%d [%s %s] %s\n"
        (d.d_line + 1) (d.d_col + 1) (d.d_end_line + 1) (d.d_end_col + 1)
        (match d.d_code with Some c -> c | None -> "-")
        (if d.d_severity = 1 then "error" else "warn") d.d_msg
    ) diags;
    if diags = [] then Printf.printf "OK: no errors\n";
    exit (min 255 (List.length diags))
  end else
    run_server ()
