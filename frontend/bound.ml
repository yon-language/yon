(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> *)
(* bound.ml — a reduction that does not finish within its bound.
 *
 * A reducer of the compiler with a bound on its steps answers only with a normal
 * form. Past the bound, a term that still reduces is no answer: the compiler
 * refuses the program with E2022 (Reduction_unfinished), naming the term, and
 * never takes the last term reached for a normal one (Lambek, Scott, Part I
 * §12-14: with finite fuel the only honest answer is "not decided"). *)

exception Unfinished of string
