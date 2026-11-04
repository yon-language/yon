# meta-Yon: the kernel of Yon, formalized in Yon

## Foundation

The syntax of the kernel is a quotient inductive type (Altenkirch and Kaposi, *Type Theory in Type
Theory using Quotient Inductive Types*, 2016): the initial object of the category of models, the
categories with families of Dybjer. In Yon it is written with the higher inductive types whose laws
are constitutive: a place with arms and laws, where each law is a cell and `match` owes a branch for
it. A theorem about the kernel is a `fun` whose result type is its statement, and the compiler that
accepts it is the proof checker.

## Structure

A project `meta/`, with one place for each of three things:

- the syntax: the terms of the fragment, as a place with arms;
- the reduction: the relation between terms;
- the proofs: the theorems, as funs whose types state them.

Every theorem is a test of the gate: if the compiler refuses the proof, the gate is red.

## The rules of meta-Yon

The compiler verifies them on the project `meta/`, which declares `kind = "proof"` in `[package]`:

- every proof fun passes the termination check (the size-change gate of `frontend/sct.ml`), and one
  that does not is refused;
- no `is given`;
- no `forever` and no `while`.

## What Yon needs, and whether it is there

| Capability | State |
|---|---|
| Inductive terms: a place with arms, recursive, payloads | present |
| The type of a path, `x = y`, as the statement of a theorem | present |
| `clear` as a proof where both ends compute to one normal form | present, also in a branch of a `match` |
| Dependent elimination: a `match` whose expected type is the motive, the arm substituted per branch | present for places with arms |
| Term parameters of a place, by name of a fun | present, in the laws and not at run time |
| Reduction of a fun defined by `match` on an arm, inside the kernel's conversion | present |
| Indexed families | in fibred form: a place and its projections, `src` and `tgt` for `Step`; its fibres are said in the laws and the statements |
| Different arms are distinct, an arm is injective | proved in `Proofs`: `yes_is_not_no`, `ite_injective` |
| A type-valued fun whose result is a path | present |
| The termination check imposed on a project's funs | present: `kind = "proof"` in `[package]`, code E2010 |

## M1: the rule of the if

Fragment: `true`, `false`, the variables, `if`.

Rules: `ifTrue`, `ifFalse`, `ifSame` (`if t then u else u → u`).

To prove:

1. Soundness: `if b then x else x = x`, by a match on `b`.
2. Termination: the size goes down at every step.
3. Local confluence: every critical pair closes.
4. Confluence, by Newman's lemma.

`ifSame` is out of the kernel before M1, so that meta-Yon does not use it to prove itself. If M1
closes, whether it comes back into the kernel is Antonio's decision.

## State of M1

- Soundness: `if_same`.
- Termination: `decreases`, the size goes down by `gap(d) + 1`.
- Local confluence: `Peak` lists every overlap of two steps out of one term, the critical pairs among
  them, and each has its valley: `same_source`, `left_starts`, `right_starts`, `left_links`,
  `right_links`, `valley_meets`.
- Open: that every two steps out of one term form a `Peak` (the inversion, by distinct arms and
  injectivity), and confluence by Newman's lemma.
