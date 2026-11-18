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
