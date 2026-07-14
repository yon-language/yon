# AUDIT: test coverage and self-scrutiny ledger

Per the testing doctrine: numbers are measured live and dated, and code left
uncovered carries a written rationale rather than a vacuous test. This file is the
ledger; it changes only with the commit that changes what it records.

## Coverage (measured 2026-07-14, after wiring the main.ml self-tests into CI)

### OCaml frontend (bisect_ppx, core suite including main.exe's 144 self-tests)
- Overall: **48.6%** (22,301 / 45,881 instrumented points).
- Excluding the menhir-generated `parser.ml` (~18k points, not line-coverable in a
  meaningful sense): **~63%** of hand-written code.
- Wiring `main.exe` (the previously-orphaned 144-test suite) lifted several modules
  out of the worst tier in one move: `catt_r_yon` 15% -> **61%**, and `move_engine`,
  `place_visibility`, `stdlib_runtime` all above the 61% cut (were 7% / 22% / 22%).

### Worst hand-written modules still open (real targets)
- `naturality_symcheck` 29%
- `prop_eval` 36%, `yon_lsp` 40%, `module_prefix` 42%, `ast.ml` 45% (unused printers)
- (`pretty.ml`, was 20%, now covered by `test_pretty`; heavy World/Place/Reduction
  and cubical-system cases remain, exercised through the corpus.)

### C runtime: NOT yet measured full-suite (gcov)
The prior doc's 33.4% was unit-only and partly wrong (it claimed `yon_arena.c` 0%,
false: `yon_arena_test.c` exercises the whole API). TODO: gcov on the Mac.

## Rationale: code uncovered by design (not a vacuous-test gap)

- **`parser.ml`** (menhir-generated): the DFA state table is not meaningfully
  line-coverable; every grammar production IS exercised (keyword coverage 140/140).
  Excluded from the meaningful denominator.
- **`naturality_coqcheck.run_coqc` / `naturality_smtcheck.run_z3`**: invoke `coqc` /
  `z3` via `Sys.command`. External-world boundary: the prover is not on CI's PATH, so
  these two functions stay uncovered. The pure translation that feeds them (to_coq,
  to_smt, make_*_program, parse_z3_result, the Unsupported entry) IS covered by
  `test_naturality_bridges` (27 assertions).
- **`catt_r_yon` persistence tail** (serialize / persist_geom_cells /
  load_persisted_cells / incremental_*): file-I/O caching used only in specific modes;
  a fake-filesystem test buys little.

## Self-scrutiny actions taken

- Wired the orphaned `main.ml` self-suite (144 tests) into CI
  (`regression/test_main_selftest.py`). Measuring it first (not blindly asserting
  exit 0) surfaced two real bugs, both fixed: three self-tests still asserted Kleene
  values after the K3 -> Godel G3 fix, and the driver printed the failing summary but
  exited 0.
- Added `test_naturality_bridges` (27 assertions) covering the Coq/SMT translation
  bridges (0% -> pure part covered).
- Added `test_pretty` (40 assertions) covering the Core pretty-printer pp_ty /
  pp_interval / pp_term / pp_op_sig / pp_handler / pp_compact (20% -> pure part covered).

## TODO (next, by return-on-effort)
- gcov full-suite on the C runtime (Mac); `bisect_ppx` numbers refreshed after each
  batch, recorded here with dates.
- `naturality_symcheck` (29%), then the mid-tier kernel modules.
- Mechanize the doctrine's banned-patterns greps (vacuous / tautology / swallowed
  exception / assert-free) as a CI job over the test tree.

## Suite size (measured 2026-07-14)
- **1,510** collected pytest nodes.
- **618** kernel-oracle assertions across 50 OCaml oracles (`test_oracle_checks`).
- **22** C runtime unit nodes; keyword coverage 140/140 (100%).
