(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* heyting.ml — Heyting algebra runtime for Yon propositions.
 *
 * Yon's "boolean" type is not Boolean. It is the subobject classifier
 * Omega of the ambient topos, which for non-Boolean topoi has more than
 * two values. We implement the three-value fragment (present, absent,
 * unknown) which is sufficient for Yon's place-relative semantics.
 *
 * Operationally, a proposition φ evaluated at place P returns:
 *   - PRESENT if P observes φ to hold
 *   - ABSENT  if P observes φ to fail
 *   - UNKNOWN if P lacks the visibility to decide
 *
 * The three values form a Heyting algebra with:
 *   - meet (AND): pointwise minimum on the order absent < unknown < present
 *               but with absorbing absent and propagating unknown
 *   - join (OR): pointwise maximum, dual rules
 *   - neg (NOT): present -> absent, absent -> present, unknown -> absent
 *   - imp (->): the Gödel (G3) residual implication, a -> b = top iff a <= b
 *
 * Critically, negation is regular, not involutive: neg(unknown) = absent and
 * neg neg(unknown) = present > unknown. The failure of double-negation
 * elimination (neg neg a >= a, not = a) is what distinguishes this Heyting
 * negation from the classical/De Morgan one. An involutive neg(unknown) =
 * unknown with the material implication ¬a \/ b would be Kleene/Łukasiewicz,
 * not the subobject-classifier Heyting algebra Yon's Omega is meant to be.
 *)

(* ─── The three Heyting values ─────────────────────────────────────── *)

type heyt_value =
  | HPresent
  | HAbsent
  | HUnknown

let heyt_to_string = function
  | HPresent -> "present"
  | HAbsent -> "absent"
  | HUnknown -> "unknown"

(* ─── Heyting operations ───────────────────────────────────────────── *)

(* Conjunction (meet AND):
 *
 *   AND      | present | absent  | unknown
 *   ───────┼─────────┼─────────┼────────
 *   present| present | absent  | unknown
 *   absent | absent  | absent  | absent
 *   unknown| unknown | absent  | unknown
 *
 * Note absent is absorbing (anything AND absent = absent), because if
 * one side is definitely false, the conjunction is definitely false
 * regardless of the other.
 *)
let h_and (a : heyt_value) (b : heyt_value) : heyt_value =
  match a, b with
  | HAbsent, _ | _, HAbsent -> HAbsent
  | HPresent, HPresent -> HPresent
  | _ -> HUnknown

(* Disjunction (join OR):
 *
 *   OR      | present | absent  | unknown
 *   ───────┼─────────┼─────────┼────────
 *   present| present | present | present
 *   absent | present | absent  | unknown
 *   unknown| present | unknown | unknown
 *
 * Note present is absorbing for OR (anything OR present = present),
 * because if one side is definitely true, the disjunction holds.
 *)
let h_or (a : heyt_value) (b : heyt_value) : heyt_value =
  match a, b with
  | HPresent, _ | _, HPresent -> HPresent
  | HAbsent, HAbsent -> HAbsent
  | _ -> HUnknown

(* Heyting negation, neg φ := φ -> absent (the pseudo-complement into bottom).
 * On the Gödel chain absent < unknown < present:
 *
 *   neg present = absent
 *   neg absent  = present
 *   neg unknown = absent          (unknown -> absent = absent, by residuation)
 *
 * neg unknown = absent, NOT unknown: in a Heyting algebra negation is regular,
 * not involutive — neg neg unknown = neg absent = present > unknown. The
 * failure of double-negation elimination (neg neg a >= a, not = a) is exactly
 * what separates intuitionistic negation from the classical/De Morgan one. An
 * involutive neg unknown = unknown would put us in Kleene/Łukasiewicz, not
 * Heyting; this is the corrected, residual negation.
 *)
let h_not (a : heyt_value) : heyt_value =
  match a with
  | HPresent -> HAbsent
  | HAbsent -> HPresent
  | HUnknown -> HAbsent

(* Heyting implication (φ -> psi) — the relative pseudo-complement, i.e. the
 * residual of meet: a -> b = the greatest c such that a /\ c <= b. On the
 * three-element chain absent < unknown < present this is the Gödel (G3)
 * implication:
 *
 *   a -> b = present        if a <= b      (in particular a -> a = present)
 *          = b              otherwise
 *
 *   ->      | present | absent  | unknown
 *   ───────┼─────────┼─────────┼────────
 *   present| present | absent  | unknown      (present -> b = b)
 *   absent | present | present | present      (absent <= everything: ex falso)
 *   unknown| present | absent  | present      (<= present and = unknown; else b)
 *
 * This is what makes the chain a genuine Heyting algebra. Note unknown ->
 * unknown = present (reflexivity a -> a = top) and unknown -> absent = absent
 * (residuation: the greatest c with unknown /\ c <= absent is absent). The
 * earlier table implemented the material implication ¬a \/ b (Kleene K3),
 * which fails a -> a = top at unknown; this is the corrected residual.
 *)
let h_imp (a : heyt_value) (b : heyt_value) : heyt_value =
  match a, b with
  | HAbsent, _ -> HPresent            (* absent <= b for every b: vacuous *)
  | HPresent, x -> x                  (* present <= b iff b = present; else b *)
  | HUnknown, HPresent -> HPresent    (* unknown <= present *)
  | HUnknown, HUnknown -> HPresent    (* unknown <= unknown: a -> a = top *)
  | HUnknown, HAbsent -> HAbsent      (* unknown !<= absent: result = b = absent *)

(* ─── Ordering ─────────────────────────────────────────────────────── *)

(* The Heyting partial order: absent <= unknown <= present.
 *
 * NOTE this is a partial order on a three-element chain because we
 * only use the prop tri-value fragment. The full Omega of an arbitrary
 * topos has a richer structure (a complete Heyting algebra), but for
 * the prototype this is sufficient.
 *)
let h_leq (a : heyt_value) (b : heyt_value) : bool =
  match a, b with
  | HAbsent, _ -> true
  | _, HPresent -> true
  | HUnknown, HUnknown -> true
  | HPresent, HUnknown | HPresent, HAbsent | HUnknown, HAbsent -> false

(* ─── Boolean coercion ─────────────────────────────────────────────── *)

(* When interfacing with Boolean code (e.g., the SWhen statement that
 * needs to choose a branch), we coerce heyt -> bool by treating only
 * HPresent as true. HUnknown and HAbsent both fail to enter the
 * "when" branch; the user must add explicit branches for them.
 *
 * This is the strict reading: only definite truth enters the branch.
 * A lenient reading would treat HUnknown as true (optimistic) or as
 * false (pessimistic); we choose strict, which is the safest.
 *)
let to_bool_strict (h : heyt_value) : bool =
  match h with HPresent -> true | _ -> false

(* Promote a Boolean to Heyting: true -> present, false -> absent.
 * No way to produce HUnknown from a bool. *)
let from_bool (b : bool) : heyt_value =
  if b then HPresent else HAbsent

(* ─── Term encoding ────────────────────────────────────────────────── *)

(* Heyting values are encoded as Yon Core terms via dedicated variable
 * names. The reducer recognizes these and applies the Heyting tables
 * when computing meet/join/negation. *)

open Ast

let encode_heyt (h : heyt_value) : term =
  match h with
  | HPresent -> Var "__heyt_present"
  | HAbsent  -> Var "__heyt_absent"
  | HUnknown -> Var "__heyt_unknown"

let decode_heyt (t : term) : heyt_value option =
  match t with
  | Var "__heyt_present" -> Some HPresent
  | Var "__heyt_absent"  -> Some HAbsent
  | Var "__heyt_unknown" -> Some HUnknown
  | _ -> None

(* ─── Heyting-aware term reduction ─────────────────────────────────── *)

(* Reduce a Heyting operation. Returns None if the term is not a
 * Heyting-tagged call, so callers can fall through to other
 * reduction strategies. *)

(* Reduce a Heyting operation. Returns None if the term is not a
 * Heyting-tagged call, so callers can fall through to other
 * reduction strategies.
 *
 * Recursive reduction: before trying decode_heyt on the args, recursively
 * reduce the Heyting sub-terms. This normalizes nested expressions like
 * `__heyt_imp(present, __heyt_imp(present, u))` that the direct match would
 * not recognize (b is not a Var "__heyt_*"). *)

let rec try_reduce_heyt (t : term) : term option =
  (* Helper: try to reduce `x` to a Heyting-Var recursively. If x is already a
   * Heyting-Var, return it unchanged. *)
  let normalize_heyt_arg (x : term) : term =
    match decode_heyt x with
    | Some _ -> x
    | None ->
        (match try_reduce_heyt x with
         | Some x' -> x'
         | None -> x)
  in
  match t with
  | App (App (Var "__heyt_and", a), b) ->
      let a' = normalize_heyt_arg a in
      let b' = normalize_heyt_arg b in
      (match decode_heyt a', decode_heyt b' with
       | Some va, Some vb -> Some (encode_heyt (h_and va vb))
       | _ -> None)
  | App (App (Var "__heyt_or", a), b) ->
      let a' = normalize_heyt_arg a in
      let b' = normalize_heyt_arg b in
      (match decode_heyt a', decode_heyt b' with
       | Some va, Some vb -> Some (encode_heyt (h_or va vb))
       | _ -> None)
  | App (Var "__heyt_not", a) ->
      let a' = normalize_heyt_arg a in
      (match decode_heyt a' with
       | Some va -> Some (encode_heyt (h_not va))
       | None -> None)
  | App (App (Var "__heyt_imp", a), b) ->
      let a' = normalize_heyt_arg a in
      let b' = normalize_heyt_arg b in
      (match decode_heyt a', decode_heyt b' with
       | Some va, Some vb -> Some (encode_heyt (h_imp va vb))
       | _ -> None)
  | _ -> None
