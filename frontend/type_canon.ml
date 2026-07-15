(* type_canon.ml — EXPERIMENT (not the refactor).
 *
 * "A type IS the Merkle root of its canonical form", computed with the SAME
 * content-addressing as values. Produces evidence for a design decision (the
 * treatment of names in the canonical form) — it does NOT touch carrier/emit/
 * desugar. Excluded from the dune build; run standalone: `ocaml type_canon.ml`.
 *
 * Two fixed screws (implemented, not experimented):
 *   1. Constructor order is significant (order enters the stream as written).
 *   2. Recursion is a de Bruijn index (the self-reference serializes as an index,
 *      never as the type's name), so the recursive closure is name-independent.
 *
 * The screw under experiment: names, via `name_mode`.
 *
 * Anchors reused (not reinvented):
 *   - content_hash = FNV-1a 64-bit, byte-identical to runtime/xleech2_heap.c:37.
 *   - the canonical-form shape follows tyenv.ml:type_tag (length-prefixed frames).
 *)

(* ── FNV-1a 64-bit, identical to runtime/xleech2_heap.c ─────────────────────── *)
let fnv_offset = 0xcbf29ce484222325L
let fnv_prime  = 0x100000001b3L
let content_hash (b : bytes) : int64 =
  let h = ref fnv_offset in
  Bytes.iter (fun c ->
    h := Int64.mul (Int64.logxor !h (Int64.of_int (Char.code c))) fnv_prime) b;
  if Int64.equal !h 0L then 1L else !h

(* ── deterministic byte encoders (big-endian, length-prefixed) ─────────────── *)
let add_u8 buf n = Buffer.add_char buf (Char.chr (n land 0xff))
let add_u32 buf n =
  add_u8 buf (n lsr 24); add_u8 buf (n lsr 16); add_u8 buf (n lsr 8); add_u8 buf n
let add_u64 buf (n : int64) =
  for i = 7 downto 0 do
    add_u8 buf (Int64.to_int (Int64.logand (Int64.shift_right_logical n (i * 8)) 0xffL))
  done
let add_name buf s = add_u32 buf (String.length s); Buffer.add_string buf s

(* ── the type definition under study ───────────────────────────────────────── *)
type name_mode = Structural_pure | Nominal_type | Nominal_ctor

type field =
  | FPrim of string   (* a primitive field (e.g. "number"): a fixed, mode-independent root *)
  | FRec of int       (* de Bruijn self-reference: the type being defined, k binders up *)
  | FInd of tdef      (* a nested DIFFERENT inductive: its type_root in the same mode *)
and pctor = { pc_name : string; pc_fields : field list }
and hctor = { hc_name : string; hc_left : int; hc_right : int }  (* path ctor + endpoint point-ctor indices *)
and tdef  = { t_name : string; t_points : pctor list; t_paths : hctor list }

(* a primitive's root is fixed and mode-independent (a leaf of the Merkle tree) *)
let prim_root (s : string) : int64 = content_hash (Bytes.of_string ("\x50rim:" ^ s))

(* ── canonical byte stream + Merkle root, parametric on the name mode ───────── *)
let rec canonical_bytes (d : tdef) (mode : name_mode) : bytes =
  let buf = Buffer.create 128 in
  add_u8 buf 0x54;  (* format tag 'T' *)
  (* the TYPE name enters the root only under Nominal_type *)
  (match mode with
   | Nominal_type -> add_u8 buf 1; add_name buf d.t_name
   | Structural_pure | Nominal_ctor -> add_u8 buf 0);
  (* point constructors, IN WRITTEN ORDER (screw 1) *)
  add_u32 buf (List.length d.t_points);
  List.iter (fun pc ->
    (* the CONSTRUCTOR name enters only under Nominal_ctor *)
    (match mode with
     | Nominal_ctor -> add_u8 buf 1; add_name buf pc.pc_name
     | Structural_pure | Nominal_type -> add_u8 buf 0);
    add_u32 buf (List.length pc.pc_fields);
    List.iter (fun f -> field_bytes buf mode f) pc.pc_fields) d.t_points;
  (* path constructors, ALWAYS serialized (T3: empty for 0-truncated types) *)
  add_u32 buf (List.length d.t_paths);
  List.iter (fun hc ->
    (match mode with
     | Nominal_ctor -> add_u8 buf 1; add_name buf hc.hc_name
     | Structural_pure | Nominal_type -> add_u8 buf 0);
    add_u32 buf hc.hc_left;
    add_u32 buf hc.hc_right) d.t_paths;
  Buffer.to_bytes buf

and field_bytes buf mode = function
  | FPrim s -> add_u8 buf 0x01; add_u64 buf (prim_root s)
  | FRec k  -> add_u8 buf 0x02; add_u32 buf k               (* de Bruijn: NOT a root *)
  | FInd d  -> add_u8 buf 0x03; add_u64 buf (type_root d mode)  (* Merkle of Merkle *)

and type_root (d : tdef) (mode : name_mode) : int64 =
  content_hash (canonical_bytes d mode)

(* ── helpers ───────────────────────────────────────────────────────────────── *)
let modes = [ Structural_pure; Nominal_type; Nominal_ctor ]
let mode_name = function
  | Structural_pure -> "Structural_pure"
  | Nominal_type -> "Nominal_type"
  | Nominal_ctor -> "Nominal_ctor"
let hex r = Printf.sprintf "%016Lx" r
let verdict a b mode = if Int64.equal (type_root a mode) (type_root b mode) then "COLLIDE" else "distinct"

let pt n fs = { pc_name = n; pc_fields = fs }
let num = FPrim "number"

(* ── §4 battery ────────────────────────────────────────────────────────────── *)
let bool_ = { t_name="Bool"; t_points=[pt "True" []; pt "False" []]; t_paths=[] }
let onoff = { t_name="OnOff"; t_points=[pt "On" []; pt "Off" []]; t_paths=[] }
let bit_  = { t_name="Bit"; t_points=[pt "Zero" []; pt "One" []]; t_paths=[] }
let expr1 = { t_name="Expr"; t_points=[pt "ENum" [num]]; t_paths=[] }
let p1 = { t_name="P1"; t_points=[pt "Pair" [num; num]]; t_paths=[] }
let p2 = { t_name="P2"; t_points=[pt "Pair" [num; FInd expr1]]; t_paths=[] }
let s1 = { t_name="S1"; t_points=[pt "base" []]; t_paths=[{hc_name="loop"; hc_left=0; hc_right=0}] }
let pointcircle = { t_name="PointCircle"; t_points=[pt "base" []]; t_paths=[] }
let list_ = { t_name="List"; t_points=[pt "Nil" []; pt "Cons" [num; FRec 0]]; t_paths=[] }
let list_renamed = { t_name="Seq"; t_points=[pt "Nil" []; pt "Cons" [num; FRec 0]]; t_paths=[] }
let bool_swap = { t_name="Bool"; t_points=[pt "False" []; pt "True" []]; t_paths=[] }
(* order-swap with STRUCTURALLY DISTINCT constructors, so screw 1 has something to bite *)
let maybe_ = { t_name="Maybe"; t_points=[pt "Just" [num]; pt "Nothing" []]; t_paths=[] }
let maybe_swap = { t_name="Maybe"; t_points=[pt "Nothing" []; pt "Just" [num]]; t_paths=[] }

(* ── real corpus named inductives (for the T1 price) ───────────────────────── *)
let c_tree = { t_name="Tree"; t_points=[pt "Leaf" [num]; pt "Node" [FRec 0; FRec 0]]; t_paths=[] }
let c_list = { t_name="List"; t_points=[pt "Nil" []; pt "Cons" [num; FRec 0]]; t_paths=[] }
let c_nameenv = { t_name="NameEnv"; t_points=[pt "NEnvNil" []; pt "NEnvCons" [num; FRec 0]]; t_paths=[] }
let c_triple = { t_name="Triple"; t_points=[pt "T3" [num;num;num]; pt "Nil" []]; t_paths=[] }
let c_color = { t_name="Color"; t_points=[pt "Red" []; pt "Green" []; pt "Blue" [num]; pt "Gray" [num]]; t_paths=[] }
let c_term_prod = { t_name="Term_prod"; t_points=[pt "TLit" [num]; pt "TPair" [FRec 0;FRec 0]; pt "TFst" [FRec 0]; pt "TSnd" [FRec 0]]; t_paths=[] }
let c_term_uni = { t_name="Term_uni"; t_points=[pt "TLit" [num]; pt "TVar" [num]; pt "TLam" [FRec 0]; pt "TApp" [FRec 0;FRec 0]; pt "TAdd" [FRec 0;FRec 0]; pt "TMul" [FRec 0;FRec 0]]; t_paths=[] }
let c_token6 = { t_name="Token6"; t_points=[pt "TNum" [num]; pt "TPlus" []; pt "TStar" []; pt "TLParen" []; pt "TRParen" []; pt "TEnd" []]; t_paths=[] }
let c_token9 = { t_name="Token9"; t_points=[pt "TNum" [num]; pt "TPlus" []; pt "TStar" []; pt "TLParen" []; pt "TRParen" []; pt "TEnd" []; pt "TName" [num]; pt "TEq" []; pt "TLamTok" []]; t_paths=[] }
let c_toklist6 = { t_name="TokList6"; t_points=[pt "TkNil" []; pt "TkCons" [FInd c_token6; FRec 0]]; t_paths=[] }
let c_expr = { t_name="ExprA"; t_points=[pt "ENum" [num]; pt "EAdd" [FRec 0;FRec 0]; pt "EMul" [FRec 0;FRec 0]]; t_paths=[] }
let c_parse = { t_name="Parse"; t_points=[pt "POk" [FInd c_expr; FInd c_toklist6]; pt "PErr" []]; t_paths=[] }
let corpus = [ c_tree; c_list; c_nameenv; c_triple; c_color; c_term_prod; c_term_uni;
               c_token6; c_token9; c_toklist6; c_expr; c_parse ]

(* ── the table ─────────────────────────────────────────────────────────────── *)
let () =
  Printf.printf "=== ROOTS per caso x mode (16-hex) ===\n";
  let cases = [ "Bool",bool_; "OnOff",onoff; "Bit",bit_; "List",list_; "Seq(=List renamed)",list_renamed;
                "P1(num,num)",p1; "P2(num,Expr)",p2; "S1(base|loop)",s1; "PointCircle(base)",pointcircle;
                "Bool-swap-order",bool_swap ] in
  Printf.printf "%-22s  %-16s  %-16s  %-16s\n" "case" "Structural_pure" "Nominal_type" "Nominal_ctor";
  List.iter (fun (nm, d) ->
    Printf.printf "%-22s  %s  %s  %s\n" nm
      (hex (type_root d Structural_pure)) (hex (type_root d Nominal_type)) (hex (type_root d Nominal_ctor)))
    cases;

  Printf.printf "\n=== VERDETTI DIAGNOSTICI (§4) ===\n";
  let pair nm a b = Printf.printf "%-34s  %-9s  %-9s  %-9s\n" nm
      (verdict a b Structural_pure) (verdict a b Nominal_type) (verdict a b Nominal_ctor) in
  Printf.printf "%-34s  %-9s  %-9s  %-9s\n" "pair" "Struct" "Nom_type" "Nom_ctor";
  pair "Bool vs OnOff (nomi, stessa forma)" bool_ onoff;
  pair "Bool vs Bit (T2 univalenza)" bool_ bit_;
  pair "List vs Seq (de Bruijn, nome)" list_ list_renamed;
  pair "P1 vs P2 (arita' non basta)" p1 p2;
  pair "S1 vs PointCircle (T3 path-ctor)" s1 pointcircle;
  pair "Bool vs Bool (determinismo)" bool_ bool_;
  pair "Bool vs Bool-swap (nullari ident.)" bool_ bool_swap;
  pair "Maybe vs Maybe-swap (ordine, distinti)" maybe_ maybe_swap;

  Printf.printf "\n=== T3: la root del path-ctor entra (deve distinguere in OGNI mode) ===\n";
  List.iter (fun m ->
    Printf.printf "  %-16s S1=%s  PointCircle=%s  -> %s\n" (mode_name m)
      (hex (type_root s1 m)) (hex (type_root pointcircle m))
      (if Int64.equal (type_root s1 m) (type_root pointcircle m) then "COLLIDE (BUG)" else "distinct OK")) modes;

  Printf.printf "\n=== T1: prezzo di Structural_pure sul CORPUS reale (quanti tipi collassano) ===\n";
  let roots = List.map (fun d -> (d.t_name, type_root d Structural_pure)) corpus in
  let groups = List.fold_left (fun acc (nm, r) ->
    let cur = try List.assoc r acc with Not_found -> [] in
    (r, nm :: cur) :: List.remove_assoc r acc) [] roots in
  let collisions = List.filter (fun (_, ns) -> List.length ns > 1) groups in
  Printf.printf "  tipi corpus modellati: %d, root Structural_pure distinte: %d\n"
    (List.length corpus) (List.length groups);
  if collisions = [] then Printf.printf "  nessuna collisione.\n"
  else List.iter (fun (r, ns) ->
    Printf.printf "  COLLIDONO su %s: %s\n" (hex r) (String.concat " = " (List.rev ns))) collisions;
  Printf.printf "  (sotto Nominal_type le stesse root:  %d distinte)\n"
    (List.length (List.sort_uniq compare (List.map (fun d -> type_root d Nominal_type) corpus)))
