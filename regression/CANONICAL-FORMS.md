<!-- GENERATED from regression/canonical_forms/ by test_canonical_forms.py.
     Do not edit by hand: the .yon fixtures are the source, this is a projection. -->

# Canonical forms and their rejected deviations

One canonical form per construct, and every deviation the compiler rejects, as
EXECUTABLE fixtures under `regression/canonical_forms/`. This page is generated
from them; the `.yon` files are the specification, not this text.

- constructs: **41**
- productions REDUCED by a fixture (Menhir-verified): **85 / 85** surface (+3 structural allowlisted)
- deviations enforced today: **20**
- deviations registered as 1.2 debt (`enforce_1_2`): **1**

| construct | fixture | status | exit | match |
|---|---|---|---|---|
| algebra | `canonical` | accept | 0 | — |
| algebra | `standalone_op` | accept | 42 | — |
| assignment | `canonical` | accept | 42 | — |
| assignment | `dev_field_mutation` | reject_clean | 1 | `place sections are immutable` |
| assignment | `dev_unbound` | reject_clean | 1 | `unknown identifier` |
| assignment | `place_rebind` | accept | 42 | — |
| binding | `canonical` | accept | 42 | — |
| binding | `dev_let` | reject_clean | 1 | `let` |
| binding | `dev_rebind` | reject_clean | 1 | `already bound in this scope` |
| cell | `canonical` | accept | 0 | — |
| comatch | `canonical` | accept | 42 | — |
| comprehension | `canonical` | accept | 0 | — |
| coproduct | `canonical` | accept | 42 | — |
| entrypoint | `canonical` | accept | 0 | — |
| entrypoint | `dev_b` | reject_clean | 1 | `ENTRYPOINT ERROR` |
| entrypoint | `dev_c` | enforce_1_2 | 0 | — |
| error | `canonical` | accept | 0 | — |
| expression | `canonical` | accept | 42 | — |
| expression | `dev_arity` | reject_clean | 1 | `expected 1 arguments, got 2` |
| expression | `dev_unknown` | reject_clean | 1 | `unknown identifier` |
| for_every | `canonical` | accept | 42 | — |
| forces | `canonical` | accept | 0 | — |
| forever | `canonical` | accept | 42 | — |
| function | `canonical` | accept | 42 | — |
| function | `dev_dup_param` | reject_clean | 1 | `duplicate parameter` |
| function | `dev_empty_body` | reject_clean | 1 | `empty body but a return type` |
| functor | `canonical` | accept | 0 | — |
| fusion | `canonical` | accept | 42 | — |
| generics | `canonical` | accept | 42 | — |
| geomorph | `canonical` | accept | 0 | — |
| hott | `canonical` | accept | 42 | — |
| hott | `dev_false_id` | reject_clean | 1 | `type mismatch` |
| hott | `dev_path_nonpath` | reject_clean | 1 | `path application` |
| hott | `dev_quote_carrier` | reject_clean | 1 | `quote` |
| if_expr | `canonical` | accept | 42 | — |
| if_expr | `dev_ternary` | reject_clean | 1 | `unexpected character` |
| in_sequence | `canonical` | accept | 42 | — |
| iter | `canonical` | accept | 42 | — |
| merge | `canonical` | accept | 22 | — |
| move | `canonical` | accept | 0 | — |
| move | `dev_plain_fn` | reject_clean | 1 | `expects morph` |
| nat_transform | `canonical` | accept | 0 | — |
| new | `call_statement` | accept | 42 | — |
| new | `canonical` | accept | 42 | — |
| pattern | `canonical` | accept | 0 | — |
| place | `canonical` | accept | 0 | — |
| produce | `canonical` | accept | 42 | — |
| produce | `dev_assign` | reject_clean | 1 | `not yet supported` |
| produce | `stmt_form` | accept | 42 | — |
| reduction | `canonical` | accept | 0 | — |
| repeat | `canonical` | accept | 0 | — |
| return | `canonical` | accept | 42 | — |
| return | `dev_tail_mismatch` | reject_clean | 1 | `declares return type number` |
| return | `dev_type_mismatch` | reject_clean | 1 | `expected number, got text` |
| scope | `canonical` | accept | 42 | — |
| spawn | `canonical` | accept | 42 | — |
| subcontains | `canonical` | accept | 0 | — |
| topos | `canonical` | accept | 42 | — |
| type | `canonical` | accept | 42 | — |
| variant | `canonical` | accept | 7 | — |
| variant | `dev_missing_branch` | reject_clean | 1 | `missing branch` |
| variant | `dev_payload_type` | reject_clean | 1 | `expected number, got text` |
| variant | `dev_wrong_arity` | reject_clean | 1 | `payload` |
| view | `canonical` | accept | 8 | — |
| when | `canonical` | accept | 42 | — |
| while_loop | `canonical` | accept | 42 | — |

## 1.2 enforcement debt

Deviations the compiler accepts today and must reject in 1.2. When the check
lands, the fixture starts failing to compile and its `.expect` flips to
`reject_clean` with a `match`; this gate then verifies the fix.

- `entrypoint/dev_c`

