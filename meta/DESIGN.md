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

The compiler verifies them on the project `meta/`:

- every proof fun passes the termination check (the size-change gate of `frontend/sct.ml`), and one
  that does not is refused;
- no `is given`;
- no `forever` and no `while`.

## What Yon needs, and whether it is there

| Capability | State |
|---|---|
| Inductive terms: a place with arms, recursive, payloads | present |
| The type of a path, `x = y`, as the statement of a theorem | present |
| `clear` as a proof where both ends compute to one normal form | present in a `return`; not in a branch of a `match` on a Boolean |
| Dependent elimination: a `match` whose expected type is the motive, the arm substituted per branch | present for places with arms |
| Term parameters of a place, by name of a fun | present; a value as an argument is not |
| Reduction of a fun defined by `match` on an arm, inside the kernel's conversion | absent |
| Indexed families: an arm whose result fixes the indices of the family | absent |
| A type-valued fun whose result is a path | no form |
| The termination check imposed on a project's funs | the check exists for delta rules; it is not imposed |
| A way for a project to declare itself under these rules | no form |

Each absent line is a stop for Antonio: a form is proposed and nothing is chosen alone.

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
