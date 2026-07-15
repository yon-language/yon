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

### C runtime (gcov, unit layer, vendor excluded, measured 2026-07-15)
Overall **38.4%** (2137 / 5570 lines). Per module: `yon_rt.c` 31.7% (4705 lines, the
big one), `xleech2_heap.c` 60.7%, `xleech2_mphf.c` 95.5%, `xleech2_coord.c` 99.4%,
`yon_arena.c` 94.1%, `leech_orbits.c` 95.1%, `yon_mmap.c` 73.1%. (`yon_curtis_canon.c`
is static LUTs, no executable lines.) The prior doc's "`yon_arena.c` 0%" and
"`leech_orbits.c` 0%" were both false. FULL-SUITE gcov (units + corpus native runs, also
measured 2026-07-15): `yon_rt.c` 38.3%, `xleech2_heap.c` 64.0%, `yon_mmap.c` 73.1%. So
the corpus adds only ~6 points to `yon_rt.c`: it is a GENUINE gap (~2900 uncovered lines
of 4705), not a measurement artifact. `yon_fold` is now covered by `test_unit_fold.c` (15 known-answer assertions; the pure
sum/max/min f64+i64, element-wise vec, OR-set bitset combiners), lifting `yon_rt.c` to
33.0%. The remaining `yon_rt.c` gap splits two ways: a few still-pure families
(`deque`/`pq`, `xset`/`xrel`, `time`/`random`) are unit-testable like fold and worth
~1 point each; the bulk (the core stream/spawn/dispatch paths, `yon_rpc2` which is
`static` + multi-process, and defensive/error branches) is integration-covered by the
corpus and cross-space tests or unreachable from a single-process unit, so it is
RATIONALE, not vacuous unit tests. Realistic unit-layer target for `yon_rt.c`: ~42%.
Reproduce: `bash regression/gcov_c.sh` (unit layer), or the opt-in gate
`pytest regression/test_c_coverage.py --gcov`.

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
- Unified the harness: a `speed` marker axis (fast/slow/bench/fuzz) and a `--stretch`
  factor for the fuzzers; folded the interpreter runner (`run_interp.sh`) into
  `test_interp.py` (surfaced + fixed 8 stale interp baselines); migrated C gcov under
  pytest as the opt-in `test_c_coverage.py --gcov` gate (via `gcov_c.sh`).

## TODO (next, by return-on-effort)
- full-suite C gcov (units + corpus native runs) for the real `yon_rt.c` number;
  extend `gcov_c.sh` to also drive `test_yon_pipeline` instrumented.
- refresh the overall OCaml `bisect_ppx` number (stale at 48.6%, pre naturality+pretty).
- `naturality_symcheck` (29%), then the mid-tier kernel modules.
- Mechanize the doctrine's banned-patterns greps (vacuous / tautology / swallowed
  exception / assert-free) as a CI job over the test tree.

## Suite size (measured 2026-07-15)
- **1,546** collected pytest nodes, sliceable by layer / kind / speed and scalable via
  `--stretch`.
- **618** kernel-oracle assertions across 50 OCaml oracles (`test_oracle_checks`).
- **22** C runtime unit nodes; keyword coverage 140/140 (100%).
