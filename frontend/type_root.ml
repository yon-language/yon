(* type_root.ml — the content-addressed identity of a type.
 *
 * A type is the Merkle root of its canonical form, computed with the same hash
 * as values (FNV-1a 64-bit, runtime/xleech2_heap.c). This is Fase 1 / Step 1 of
 * the Carrier Stage 2 path. The name screw is fixed to Nominal_type (decided by
 * the type_canon experiment): the type name enters the root; constructors are
 * positional (their names do not enter). So `Bool = True|False` and `Bit =
 * Zero|One` get distinct roots, and the equivalence between them stays a path
 * (ua), not a definitional identity, which is what univalence requires.
 *
 * Two other screws, also fixed:
 *   - constructor order is significant (enters the stream as written);
 *   - recursion is a de Bruijn index (a self-reference serializes as an index,
 *     never as the type name), so the recursive closure is name-independent.
 *
 * Partiality (Zona 1). A type with no runtime value (a universe, a stuck code, a
 * bare type variable) has no root: [type_root] returns None. This frontier
 * coincides with the carrier's [NoCarrier] (Step 4 pins it as invariant I6).
 * The canonical form is the normal form: El codes are normalized before hashing.
 *)

open Surface_ast
module TE = Tyenv

(* ── FNV-1a 64-bit, byte-identical to runtime/xleech2_heap.c:content_hash ───── *)
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

(* a primitive / nominal-leaf root: fixed, canonical *)
let leaf_root (s : string) : int64 = content_hash (Bytes.of_string ("\x50rim:" ^ s))

(* raised when a type falls outside Zona 1 (no runtime carrier -> no root) *)
exception No_root

(* index of a name in the de Bruijn context (innermost = 0) *)
let debruijn (name : string) (ctx : string list) : int option =
  let rec go i = function
    | [] -> None
    | n :: _ when n = name -> Some i
    | _ :: rest -> go (i + 1) rest
  in go 0 ctx

(* A TyUser that is neither a named inductive nor a de Bruijn self-reference is a
   concrete nominal leaf iff it names a place or a known runtime carrier; otherwise
   it is a type variable / unresolved and has no root. Mirrors tycheck's check_ty. *)
let runtime_leaf = ["Space"; "Map"; "HashSet"; "HashMap"; "HSH"; "List"; "Stream";
                    "Seq"; "Wire"; "XSet"; "XRelSet"; "XRelMap"; "XSimplex"; "XTower";
                    "MerkleTree"; "VoyagerList"; "String"]
let is_nominal_leaf (env : TE.env) (n : string) : bool =
  List.mem n runtime_leaf || TE.lookup_place env n <> None

(* ── canonical byte stream, Nominal_type ───────────────────────────────────── *)
let rec encode_ty (env : TE.env) (ctx : string list) buf (t : ty) : unit =
  match t with
  | TyPrim n | TyPrimIn (n, _) -> add_u8 buf 0x01; add_name buf n
  | TyUser n ->
      (match debruijn n ctx with
       | Some k -> add_u8 buf 0x02; add_u32 buf k                  (* recursion: de Bruijn *)
       | None ->
           (match TE.lookup_named_sum env n with
            | Some variants -> add_u8 buf 0x03; add_u64 buf (root_named env ctx n variants)
            | None ->
                (* a primitive written as a bare name (number/boolean/...), or a
                   place / runtime carrier: a nominal leaf. Otherwise a type var. *)
                if Carrier.prim_carrier n <> None || is_nominal_leaf env n
                then (add_u8 buf 0x01; add_name buf n)
                else raise No_root))                               (* type var / unknown *)
  | TySum variants | TySumIn (variants, _) ->
      add_u8 buf 0x04; encode_variants env ctx buf variants        (* anonymous: no type name *)
  | TyList inner -> add_u8 buf 0x05; encode_ty env ctx buf inner
  | TyStream inner -> add_u8 buf 0x06; encode_ty env ctx buf inner
  | TyMap (k, v) -> add_u8 buf 0x07; encode_ty env ctx buf k; encode_ty env ctx buf v
  | TyApp (n, args) ->
      add_u8 buf 0x08; add_name buf n; add_u32 buf (List.length args);
      List.iter (encode_ty env ctx buf) args
  | TyArrow (a, b) ->
      add_u8 buf 0x09; encode_ty env ctx buf a; encode_ty env ctx buf b
  | TyEl (TyTermExpr e) ->
      (* the canonical form is the NORMAL form: decode/normalize the code first.
         A code that resolves to a concrete type gets that type's stream; one that
         stays stuck is not Zona 1. *)
      (match Catt_r_yon.el_decode (surface_code_of_expr e) with
       | Some carrier -> encode_ty env ctx buf carrier
       | None -> raise No_root)
  (* No runtime value -> no root (the partiality frontier). *)
  | TyUniverse _ | TyVar _ | TyMetaVar _
  | TyPi _ | TySigma _ | TyId _ | TyPathP _ | TyHeytInt _
  | TyWire _ | TySubscription _
  | TyMoveHandle _ | TyReductionHandle _ | TyMorphHandle _ | TyViewHandle _ ->
      raise No_root

and encode_variants (env : TE.env) (ctx : string list) buf (variants : variant list) : unit =
  add_u32 buf (List.length variants);                              (* order significant *)
  List.iter (fun v ->
    add_u32 buf (List.length v.v_args);                            (* ctor name does not enter (positional) *)
    List.iter (encode_ty env ctx buf) v.v_args) variants;
  add_u32 buf 0                                                    (* path-constructor slot: empty for point inductives (T3-ready) *)

and root_named (env : TE.env) (ctx : string list) (name : string) (variants : variant list) : int64 =
  let buf = Buffer.create 64 in
  add_u8 buf 0x54;                                                 (* format tag 'T' *)
  add_name buf name;                                              (* Nominal_type: the type name enters *)
  encode_variants env (name :: ctx) buf variants;                (* push name for de Bruijn self-reference *)
  content_hash (Buffer.to_bytes buf)

(* a bare Catt_r_yon code term from a surface code expression (only the simple
   Var form is decoded here; anything richer stays stuck -> No_root upstream) *)
and surface_code_of_expr (e : expr) : Catt_r_yon.term =
  match e with
  | EVar (n, _) -> Catt_r_yon.TmVar n
  | _ -> Catt_r_yon.TmVar "__stuck__"

(* ── the public entry: the root of a type, or None if outside Zona 1 ───────── *)
let type_root (env : TE.env) (t : ty) : int64 option =
  try
    let r =
      match t with
      | TyUser n when TE.lookup_named_sum env n <> None ->
          (match TE.lookup_named_sum env n with
           | Some variants -> root_named env [] n variants        (* a named inductive: name + structure *)
           | None -> raise No_root)
      | _ ->
          let buf = Buffer.create 32 in encode_ty env [] buf t;
          content_hash (Buffer.to_bytes buf)
    in Some r
  with No_root -> None
