(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* ast_compare.ml — two surface programs are the same program if they are equal but for where
 * their nodes were written. The oracle of the formatter and of the rewriter: a rewrite that changes
 * only the text of some nodes leaves the rest of the tree as it was.
 *
 * The positions are the `Surface_ast.location` records spread through the tree. A copy of a value
 * with every location replaced by `dummy_loc` is the value read without its positions; two programs
 * are equal when their copies are. A location is recognised by its shape, which no other value of
 * the tree has: a block of four integers and a string.
 *
 * Parentheses that only group are no part of the program: `(c - 48) ↪ TNum` and `c - 48 ↪ TNum`
 * are read the same, and the formatter may write the first for the second. An `EParen` is
 * recognised by its constructor and its shape (an expression and a location); the statement
 * `promote e` has the same constructor number and shape, and is unwrapped the same way on both
 * sides, which keeps the comparison exact: where a statement stands, no expression can. *)

module S = Surface_ast

let is_location (o : Obj.t) : bool =
  Obj.is_block o && Obj.tag o = 0 && Obj.size o = 5
  && Obj.is_int (Obj.field o 0) && Obj.is_int (Obj.field o 1)
  && Obj.is_int (Obj.field o 2) && Obj.is_int (Obj.field o 3)
  && (let f = Obj.field o 4 in Obj.is_block f && Obj.tag f = Obj.string_tag)

let paren_tag = Obj.tag (Obj.repr (S.EParen (S.EVar ("x", S.dummy_loc), S.dummy_loc)))

(* a copy of [v] without its positions and its grouping parentheses; leaves are shared *)
let rec erase (o : Obj.t) : Obj.t =
  if Obj.is_int o then o
  else if is_location o then Obj.repr S.dummy_loc
  else if Obj.tag o = paren_tag && Obj.size o = 2 && is_location (Obj.field o 1) then erase (Obj.field o 0)
  else
    let t = Obj.tag o in
    if t >= Obj.no_scan_tag || t = Obj.closure_tag || t = Obj.infix_tag
       || t = Obj.lazy_tag || t = Obj.forward_tag || t = Obj.object_tag then o
    else begin
      let n = Obj.size o in
      let c = Obj.new_block t n in
      for i = 0 to n - 1 do Obj.set_field c i (erase (Obj.field o i)) done;
      c
    end

let without_positions (p : S.program) : S.program = Obj.obj (erase (Obj.repr p))

let equal (a : S.program) (b : S.program) : bool =
  compare (without_positions a) (without_positions b) = 0

(* Where two programs first differ, but for positions: the position, in each, of the innermost
   node that holds the difference, and the two leaves. None when they are equal. *)
let first_difference (a : S.program) (b : S.program)
    : (S.location * S.location * string) option =
  let leaf o =
    if Obj.is_int o then string_of_int (Obj.obj o)
    else if Obj.tag o = Obj.string_tag then Printf.sprintf "%S" (Obj.obj o)
    else if Obj.tag o = Obj.double_tag then Printf.sprintf "%h" (Obj.obj o)
    else Printf.sprintf "<block tag %d size %d>" (Obj.tag o) (Obj.size o) in
  let loc_of o =
    if Obj.is_block o && Obj.tag o < Obj.no_scan_tag then
      let n = Obj.size o in
      let rec find i = if i < 0 then None
        else let f = Obj.field o i in if is_location f then Some (Obj.obj f : S.location) else find (i - 1) in
      find (n - 1)
    else None in
  let rec unparen o =
    if Obj.is_block o && Obj.tag o = paren_tag && Obj.size o = 2 && is_location (Obj.field o 1)
    then unparen (Obj.field o 0) else o in
  let rec go o1 o2 l1 l2 =
    let o1 = unparen o1 and o2 = unparen o2 in
    if compare (erase o1) (erase o2) = 0 then None
    else
      let l1 = Option.value (loc_of o1) ~default:l1 and l2 = Option.value (loc_of o2) ~default:l2 in
      if Obj.is_int o1 || Obj.is_int o2 || Obj.tag o1 >= Obj.no_scan_tag || Obj.tag o2 >= Obj.no_scan_tag
         || Obj.tag o1 <> Obj.tag o2 || Obj.size o1 <> Obj.size o2
      then Some (l1, l2, leaf o1 ^ " / " ^ leaf o2)
      else
        let rec fields i =
          if i >= Obj.size o1 then Some (l1, l2, "a difference under this node")
          else match go (Obj.field o1 i) (Obj.field o2 i) l1 l2 with
            | Some d -> Some d
            | None -> fields (i + 1) in
        fields 0 in
  go (Obj.repr a) (Obj.repr b) S.dummy_loc S.dummy_loc

(* ─── The side tables ─────────────────────────────────────────────────────
 * The parser writes some of what it reads in tables beside the tree, keyed by the position of a
 * node: the digits of an integral literal, the arrow a call was written with, the explicit type
 * arguments of a call, the bounds of a fun. Two readings are the same program only if these agree
 * too: `1.0` and `1` are the same tree, but only the second has its digits in the table of the
 * integral literals.
 *
 * A site is compared by the node it stands at, not by its position. The nodes of two equal trees
 * have the same ranks, in the order of the tree, once the grouping parentheses are left out; a
 * position names the nodes written there (a call and its first argument start at the same place),
 * so a site is placed at the set of the ranks of its position, and a site of one reading matches a
 * site of the other with the same table, key and value whose set meets its own: the node it names
 * is in both sets. A piece without a position of its own in the tree is placed at the nodes written
 * last before it. *)

type site = { table : string; at : (int * int) option; key : string; value : Obj.t }

(* The sites of the reading just made: call it right after the parser, before another reading. *)
let sites () : site list =
  let out = ref [] in
  let add table at key v = out := { table; at; key; value = Obj.repr v } :: !out in
  let pos3 table h = Hashtbl.iter (fun (_, l, c) v -> add table (Some (l, c)) "" v) h in
  let pos4 table h = Hashtbl.iter (fun (_, l, c, k) v -> add table (Some (l, c)) k v) h in
  let named table h = Hashtbl.iter (fun k v -> add table None k v) h in
  pos3 "exact_int_literals" S.exact_int_literals;
  pos4 "arrow_sites" S.arrow_sites;
  pos3 "explicit_type_args" S.explicit_type_args;
  pos3 "mut_sites" S.mut_sites;
  pos3 "fun_bounds" S.fun_bounds;
  pos3 "bare_nullary_decls" S.bare_nullary_decls;
  pos3 "internal_carrier_sites" S.internal_carrier_sites;
  pos3 "arrow_home_sites" S.arrow_home_sites;
  pos3 "arrow_written_in" S.arrow_written_in;
  pos3 "proof_funs" S.proof_funs;
  named "carrier_headers" S.carrier_headers;
  named "carrier_models" S.carrier_models;
  named "algebra_written" S.algebra_written;
  named "algebra_places" S.algebra_places;
  named "place_algebras" S.place_algebras;
  named "place_term_params" S.place_term_params;
  !out

(* The ranks of the nodes written at each position of [p], the grouping parentheses left out. *)
let ranks (p : S.program) : (int * int, int list) Hashtbl.t =
  let h = Hashtbl.create 256 and n = ref 0 in
  let rec go o =
    if Obj.is_int o then ()
    else if is_location o then begin
      let l : S.location = Obj.obj o in
      let k = (l.S.start_line, l.S.start_col) in
      Hashtbl.replace h k (!n :: Option.value (Hashtbl.find_opt h k) ~default:[]);
      incr n
    end
    else if Obj.tag o = paren_tag && Obj.size o = 2 && is_location (Obj.field o 1) then go (Obj.field o 0)
    else
      let t = Obj.tag o in
      if t >= Obj.no_scan_tag || t = Obj.closure_tag || t = Obj.infix_tag
         || t = Obj.lazy_tag || t = Obj.forward_tag || t = Obj.object_tag then ()
      else for i = 0 to Obj.size o - 1 do go (Obj.field o i) done in
  go (Obj.repr p); h

(* The sites of a reading, by table, key and value, each with the ranks of its position (none for a
   site keyed by a name). *)
let grouped (p : S.program) (ss : site list) =
  let r = ranks p and g = Hashtbl.create 64 in
  List.iter (fun s ->
    let k = (s.table, s.key, erase s.value) in
    let at = match s.at with
      | None -> None
      | Some at ->
          (match Hashtbl.find_opt r at with
           | Some rs -> Some (at, rs)
           | None ->
               (* a piece the tree keeps without a position of its own (the literal of a pattern, the
                  count of a `repeat`): placed at the nodes written last before it *)
               let before = Hashtbl.fold (fun q _ best ->
                 if compare q at < 0 && (match best with None -> true | Some b -> compare q b > 0)
                 then Some q else best) r None in
               Some (at, match before with Some q -> Hashtbl.find r q | None -> [])) in
    Hashtbl.replace g k (at :: Option.value (Hashtbl.find_opt g k) ~default:[])) ss;
  g

(* The first site that one reading has and the other has not, said in words; None when they agree. *)
let sites_difference (a : S.program) (sa : site list) (b : S.program) (sb : site list) : string option =
  let ga = grouped a sa and gb = grouped b sb in
  let meets x y = match x, y with
    | None, None -> true
    | Some (_, rx), Some (_, ry) -> List.exists (fun i -> List.mem i ry) rx
    | _ -> false in
  (* the sites of [xs] that find no distinct partner in [ys] *)
  let unmatched xs ys =
    let ys = ref ys in
    List.filter (fun x ->
      let rec take acc = function
        | [] -> None
        | y :: rest -> if meets x y then Some (List.rev_append acc rest) else take (y :: acc) rest in
      match take [] !ys with Some rest -> ys := rest; false | None -> true) xs in
  let say which (tbl, key, _) x =
    let where = match x with Some ((l, c), _) -> Printf.sprintf " at %d:%d" l c | None -> "" in
    Printf.sprintf "the %s reading has a site of %s%s%s that the other has not" which tbl
      (if key = "" then "" else " (" ^ key ^ ")") where in
  let first which g1 g2 =
    Hashtbl.fold (fun k xs found ->
      match found with
      | Some _ -> found
      | None ->
          (match unmatched (List.sort compare xs)
                   (List.sort compare (Option.value (Hashtbl.find_opt g2 k) ~default:[])) with
           | x :: _ -> Some (say which k x)
           | [] -> None)) g1 None in
  match first "first" ga gb with
  | Some _ as d -> d
  | None -> first "second" gb ga

(* The same program: the same tree but for positions, and the same sites. *)
let equal_readings (a, sa) (b, sb) = equal a b && sites_difference a sa b sb = None

(* ─── A reading written out ───────────────────────────────────────────────
 * The tree with its positions and the sites beside it, as text: two builds of the parser read a
 * file the same way when they write the same text for it (the oracle of a change of the grammar
 * that keeps the language: every node, every position, every site). A block is its tag and its
 * fields; a leaf is written as OCaml writes it. *)
let dump (p : S.program) (ss : site list) : string =
  let b = Buffer.create 65536 in
  let rec go o =
    if Obj.is_int o then Buffer.add_string b (string_of_int (Obj.obj o))
    else
      let t = Obj.tag o in
      if t = Obj.string_tag then Buffer.add_string b (Printf.sprintf "%S" (Obj.obj o))
      else if t = Obj.double_tag then Buffer.add_string b (Printf.sprintf "%h" (Obj.obj o))
      else if t >= Obj.no_scan_tag || t = Obj.closure_tag || t = Obj.infix_tag
              || t = Obj.lazy_tag || t = Obj.forward_tag || t = Obj.object_tag
      then Buffer.add_string b (Printf.sprintf "<tag %d>" t)
      else begin
        Buffer.add_string b (string_of_int t); Buffer.add_char b '(';
        for i = 0 to Obj.size o - 1 do
          if i > 0 then Buffer.add_char b ',';
          go (Obj.field o i)
        done;
        Buffer.add_char b ')'
      end in
  List.iter (fun d -> go (Obj.repr d); Buffer.add_char b '\n') p;
  let line s =
    let v = Buffer.length b in
    Buffer.add_string b (Printf.sprintf "site %s %s %S " s.table
      (match s.at with Some (l, c) -> Printf.sprintf "%d:%d" l c | None -> "-") s.key);
    go s.value;
    let t = Buffer.sub b v (Buffer.length b - v) in
    Buffer.truncate b v; t in
  List.iter (fun t -> Buffer.add_string b t; Buffer.add_char b '\n')
    (List.sort compare (List.map line ss));
  Buffer.contents b
