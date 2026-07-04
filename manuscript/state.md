# Jurassic Park in Yon — state.md (living spine)

> Read this BEFORE writing any chapter; update it immediately AFTER. It prevents
> drift: terminology, voice, what's introduced, open threads, verdicts. Governing
> docs: `00-jp-spec.md` (contract), `01-jp-structure.md` (approved backbone),
> `jp-novel-map.md` (the novel), `construct-inventory.md` (✓/declared/debt),
> `inspiration-list.md` (the 27 claims). Ground truth = the code + `audit_language.md`
> + `regression/COVERAGE.md` + `swarm/AUDIT_*` (gitignored, real, mtime Jun 21-22).

## Locked decisions (log)

- **2026-07-04 — Compiler tooling, brick 2 (pilot): the canonical `Project` pass + a project-aware LSP surfacing E3001.**
  The recon found the real bottleneck for the LSP was NOT missing codes: `diagnostics_of_source` calls check_program
  IN-PROCESS and structured, so it already sees parse+type; the 6 semantic classes live in the driver as eprintf+exit,
  outside any channel the LSP calls. AND the LSP works on one in-memory buffer while the semantic checks need PROJECT
  context. DONE (piloted on drop, the crown jewel): `frontend/project.ml` -- the canonical loader (`load ~root ?overrides`,
  from the test-harness pattern: Package_layout.layout for files+Space, Manifest for declared Spaces, TopPlace -> its
  directory for place_space; `overrides` substitutes an open buffer's unsaved text) and `check_all : loaded ->
  Error_codes.t list` (runs the pure whole-program checks, pilots on check_drops -> E3001/E3002). One source of truth for
  "how to check a project", shared by the LSP now and the driver later.
  · LSP wired: `diag` gained `d_code`; `diagnostics_of_document path source` = the single-file parse/type PLUS, when
    `Project.root_of_file` finds a yon.toml, the whole-program semantic pass on the merged program (open buffer swapped
    in). Attributed to THIS file by matching each diagnostic's site against the drop AND import sites parsed from the open
    file. `yon_lsp --check <projectfile>` prints `[E3001 error] cannot drop Space D ... (at 5:13)` in-process; a legal
    drop raises nothing. Pinned by regression/test_lsp.py.
  · EXTENDED to all project-context classes (2026-07-04): check_all now = drop (E3001/E3002) + wire boundary (E3010) +
    topos-layout (E4001) + file-layout (E4003) + entrypoint (E4002), each reusing the pure Manifest.check_ / check_drops
    functions -- no duplicated LOGIC, only unified orchestration. The LSP surfaces the LOCATED crown jewels under the
    cursor (drop E3001, wire-boundary E3010 at the import site); the project-wide classes (layout, entrypoint, no
    location) are computed by check_all but left to the compiler CLI, not attached to a cursor. The LSP now shows ALL
    located diagnostics at once, where the driver exits at the first failing class -- a difference convergence will settle
    (show-all vs first-hit). test_lsp.py pins drop E3001 + wire-boundary E3010. Driver still unchanged; compiler suite
    identical (438 green).
  · TWO HONEST LIMITS for the next slice. (1) The single-file type check is NOT project-aware: an isolated Entry.yon
    yields a false "cannot infer world" (E2001) the full compiler does not -- pre-existing, now visible; the type check
    should run on the merged program too. (2) Per-file attribution of whole-program diagnostics rides on location
    matching, and Surface_ast.location carries NO file (line numbers collide across files). Correct in the common case
    (drops are usually in the entry); the rigorous fix is file-carrying locations, a foundational change. NEXT: extend
    check_all to layout/boundary/entrypoint, make the type check project-aware, migrate the driver onto Project.load +
    check_all (converge the two loaders to one), then linter/formatter/debugger.

- **2026-07-04 — Compiler tooling, brick 1: the stable diagnostic-code catalog (`frontend/error_codes.ml`).**
  Roadmap (Antonio): errors -> LSP -> linter -> formatter -> debugger. Four of five tools already exist as real binaries
  (diagnostics.ml/yon_lsp.ml/yon_lint.ml/yonfmt.ml); the bottleneck is upstream of all four: NO error class emits a stable
  code (E1110/E1111 are retired, comment-only; diagnostics.ml is a formatter, not a catalog). A tool cannot key on
  "DROP ERROR:" (rename the prose, the tool breaks); it needs `E3001`, stable under rewording. DONE: `Error_codes` is the
  single registry -- a code is defined by its relationships (Yoneda: id, severity, cli_prefix, title), the variant is
  EXHAUSTIVE (a new class fails the build until numbered, the anti-fake-green net on the catalog). Canonical `Diagnostic
  { code; range; message }` + `to_cli` renders "<PREFIX> [<id>]: <message>": the historical prefix preserved (text
  consumers keep working), the stable code added. Ranges: E1xxx syntax, E2xxx type, E3xxx Space semantics (the
  crown jewels -- E3001 drop-still-live, E3002 unknown-Space, E3010 wire-boundary), E4xxx project/layout, Wxxx lint.
  · All 8 driver error classes routed through it (yoner_emit_mlir.ml): PARSE/lex, TYPE (x3), DROP (x2), WORLD BOUNDARY,
    TOPOS LAYOUT (x2), ENTRYPOINT, FILE, MANIFEST. Additive: messages and exit codes unchanged, code added in brackets.
  · Catalog gate `regression/test_error_codes.py`: codes unique (the hazard hand-numbering invites), in-range, and the CLI
    really carries `DROP ERROR [E3001]:`. Whole suite green (718 + gate); test_drop_check's `DROP ERROR`/`Space D` greps
    survive because the prefix is preserved.
  · SURFACE FINDING for the next brick: the LSP is IN-PROCESS and STRUCTURED (diagnostics_of_source calls
    parse_source + Tycheck.check_program, maps cr_errors -> diag). It sees parse+type not because they have codes but
    because they return a structured list; the 6 semantic classes live in the DRIVER as eprintf+exit, outside any channel
    the LSP calls. So codes alone do NOT light up the LSP. Brick 2 = a shared `check_all : project_ctx -> program ->
    Diagnostic list` (the semantic checks already return structured lists; extract them from the driver) AND make the LSP
    PROJECT-AWARE (find the containing yon.toml/layout for the open document), since drop/layout/boundary need project
    context a single in-memory buffer lacks. eval_runner.ml's 3 sites still use raw prefixes (secondary, interpreter).

- **2026-07-03 — at_space routing ON (census-fed) + the FIFTH arc family: section-handle liveness.**
  Investigating the measured-memory viz exposed that `new P { }` NEVER reached its Space's arena: assign_topos_structure
  leaves tp_objects empty on purpose (double-registration fix), so desugar's build_place_to_space_map was always empty and
  every instance landed on heap 0. Zero corpus projects routed a new. FIX (Antonio's design): do not launder membership
  through tp_objects; the router reads the source that already knows it. `desugar_program ?place_to_space` receives the
  filesystem census (the driver's places_by_space inverse, the same place_space check_drops uses); build_place_to_space_map
  degrades to the fallback for censusless callers (single-file/eval, where empty = correct). One source of truth.
  PROOF: main emits `__new_in_A_AP`; the [HEAP] trace (new runtime tick, YON_DEBUG_HEAP, drop events name their Space)
  shows arenas REALLY filling: A 9 -> 24001 bytes across loop 1, drop:A exactly at the join (seq 3000), then B, then C.
  · ROUTING EXPOSED THE FIFTH ARC FAMILY. With instances in named arenas, a section handle is a LIVE REFERENCE (not a
    copy): field reads dereference the arena. The analysis counted the arc at the `new` only, so the auto-reclaim
    scheduled the drop BETWEEN a new and a later field read (use-after-reclaim in the MLIR, verified). Darwin MASKS it
    (MADV_DONTNEED reclaims lazily: a C probe wrote 4 pages, dropped, all 4 survived); Linux zero-fills, so the same
    schedule returns zeros there. Fixed with `section_bindings`: variables bound to a section of a routed place (new,
    place-returning call, alias; fixpoint) merge into the name->Space map, so every USE is an arc through the same imap
    lookup as imported symbols. Place-typed PARAMETERS seed the callee side (transitive). Flow-insensitive, conservative.
  · PINS: handle_illegal + alias_illegal in the oracle (negative control: neuter section_bindings -> both go LEGAL-wrong,
    SEEN, restored); the OLD place_legal pin correctly went red (it returned the raw handle after the drop: legal only
    under the incomplete semantics) and was rewritten to the copy-geometry shape (extract the field, then drop).
    System pin test_handle_read_schedules_before_reclaim: MLIR order (field_load BEFORE drop_space, platform-independent)
    + the binary returns 7 through the live handle. drop_reclaim fixture's DP gained a field for it.
  · Suite green with routing ON: 741 behavioral (projects/pipeline/cross-space/oracle 508, canonical/coverage/runtime 233)
    + drop-check 7. The whole corpus now allocates place instances in named arenas and still behaves identically.
  · Measured-memory viz shipped on the real trace (9003 events, sampled): allocated cursor vs live-after-reclaims, drop
    markers at measured seqs, per-reclaim arc explanations (loop rule, handle liveness).

- **2026-07-03 — The AUTOMATIC reclaim at last-use (the mechanism): reclaim without an annotation, decided at compile time.**
  The other half of the reclaim system (`drop X` is its checked, declared assertion). The DUAL of check_drops: instead
  of verifying a user's drop point, FIND each Space's last use and insert the reclaim there. `Space_liveness.auto_reclaim_
  program` runs on the entry's `main` (the single root under which all execution lives), so main's downstream arc-set
  (WITH transitive arcs, now complete after the audit) is the whole-program remaining use of a Space: the first top-level
  position where X leaves `downstream_arcs` is its GLOBAL last use, and an auto reclaim there is sound -- no read of X can
  follow (a read would be an arc, and the arc set is complete). It only inserts SDrop nodes, so the whole drop pipeline
  (desugar -> `__drop_space_X` -> `yon_rt_drop_space`) handles them verbatim. Skips: Spaces dropped explicitly (the user's
  drop covers them), Spaces live to the end (process exit frees them).
  · REACLAIMABLE SET = OWNED (directory-backed) Spaces, not every declared Space. Caught by meteo_sub failing to compile:
    a subscriber's `wire to space Meteo` makes Meteo a declared arc, but Meteo is REMOTE (no directory, no `yon_space_str_
    Meteo` global, no local heap the compiler owns). Referencing its missing global failed emission. Fix: auto_reclaim
    targets `Package_layout.space_decls` names (the directories this program owns). Remote receive-views are left to the
    owner + process exit (a later precision gain). The existence check for explicit `drop` still uses the full census.
  · SOUNDNESS VALIDATED BY THE WHOLE CORPUS: with auto-reclaim ON, every program in the suite still produces correct
    output/exit. A premature reclaim (a Space freed while still read -> madvise zeros the pages -> wrong data) would flip
    a result and a test would fail. Green = the arc audit was complete enough. This is why the audit had to come first.
  · Runtime logs (`yon_xheap_drops`) gated behind `YON_DEBUG_DROPS` so the now-ubiquitous reclaim is silent by default.
  · PINS: end-to-end mechanism (`test_automatic_reclaim_without_explicit_drop`: main uses D then unrelated work, no `drop`
    written -> binary reports xheap_drops=1; negative control neuters auto_reclaim_main_body -> counter 0 -> red, SEEN)
    plus an analysis pin in the oracle (auto_reclaim_main_body inserts SDrop(A) at A's last use). Whole suite green.
  · The reclaim system is now COMPLETE: analysis decides (downstream_arcs, all arc families), the automatic mechanism
    reclaims every owned Space at its last use, and `drop X` is the checked assertion of the same criterion. Compile-time
    GC: automatic and safe like a GC, deterministic like C, declarable-and-verified like a type annotation.

- **2026-07-03 — Arc-completeness audit: `downstream_arcs` now counts EVERY way a named Space's heap is touched.**
  Precondition for the automatic reclaim (which fires everywhere, so it needs a complete arc set to be precise) and a
  correctness hardening for `drop`. An exhaustive audit (Explore agent) enumerated every surface/Core operation that
  resolves a named Space to a heap. Result: two families were already counted (wire `EWireTo`, import `TopImportFrom`
  + symbol use); FOUR were missed, now closed in `space_liveness.ml`, each with an oracle pin + negative control SEEN
  failing (restored byte-identical):
  · `apply_move(a) in S` and `f(a) in S` (morph): the parser mangles the Space into the call name
    (`__apply_move_in_<S>`, `__morph_in_<S>__<f>`). `space_of_mangled_call` extracts it. Surface-visible, no threading.
  · `new P { }` at a topos-`at S`: the tp_at_space rewrite (post-check_drops) turns `SNew(P)` into a write to P's Space.
    check_drops sees `SNew(P)`; names_expr/names_stmt now emit the place name, resolved via a place->space census merged
    into imap. `~place_space` threaded through `transitive_arcs`/`check_drops`; the driver builds it from the per-file
    place accumulation (place P in dir D/ -> Space D). DRIVER end-to-end verified: `drop D; new DP {}` -> DROP ERROR.
  · `w.awaits(producer)`: the Space rides the wire handle's type; tycheck records it in the global `awaits_site_table`
    keyed by the awaits call's (line, col). `awaits_arc_of` queries it by the same loc names_expr collects. No threading
    (global table, populated by tycheck before check_drops). Usually subsumed by the co-located wire; the distinct gap is
    `wire X; drop X; w.awaits()` (wire upstream, awaits downstream).
  · Correctly EXCLUDED (not arcs): `Space__set/get`/`__space_update_here` (default/current heap, not a named Space) and
    `topos at S` / `geom_morphism` DECLARATIONS (metadata; the arc arises when a morph/move is APPLIED, i.e. the mangled
    forms above). The `SNewIn` "retired" comment in surface_ast.ml is STALE: the rewrite still produces it.
  Threading kept minimal: the place->space map is merged into imap (both are "name -> Space it touches"), so only
  `transitive_arcs` and `check_drops` gained `~place_space`; `downstream_arcs`/`region_arc_sites` are unchanged (they use
  the merged imap). Whole affected suite green. NEXT: the automatic reclaim, on a now-complete and validated arc set.

- **2026-07-03 — The `drop X` construct: parser + check + driver, wired end to end (emission is a placeholder for now).**
  Order followed: grep (is `drop` free?) then parser then check then driver. `drop`/`DROP` was a stream-policy modifier
  removed in v1.1 and free in the corpus, so it was reintroduced clean. Additive frontend, no runtime touched.
  · SYNTAX: `drop X` (keyword `drop`, no explicit `Space` token, X is a Space name). Inline production in `stmt` (NOT a
    named rule, so the canonical-forms completeness gate is not tripped). New node `Surface_ast.SDrop of string * location`.
    Adding it made every exhaustive stmt match non-exhaustive: the anti-fake-green net listed all 13 sites across 5 files
    (space_graph, space_liveness x3, tok_dump, desugar x4, tycheck x3, module_prefix x3). A drop is not an arc nor a value
    use, so it contributes nothing everywhere except the checker; desugar lowers it to a unit placeholder (the real reclaim
    is the emission step, still to do).
  · CHECK: `Space_liveness.check_drops ~declared prog` finds every `drop X` (drops_in_stmts) and validates TWO obligations
    in order (domain before value): (1) EXISTENCE, X must be a declared Space (`declared` = the manifest census, keys of
    `space_world`, source of truth including isolated declared Spaces that appear in no arc); (2) SAFETY, no arc toward X
    is reachable downstream. The order matters for the message: an undeclared X is "unknown Space X" (a typo like
    `drop Acount` has no arc toward the misspelling, so reachability alone would wave it through), and only a declared X
    gets the "still reachable downstream" arc diagnostic. This closed the SECOND HALF of the same arc-blindness hole the
    lowering bug exposed: the check reasoned about arcs, not node existence. `drop_error` carries `de_fault`
    (Unknown_space | Still_live loc), so the diagnostic names the right fault. REFACTOR: `downstream_arc_sites` (carries a
    representative `(Space, loc)` per arc) is the core, `downstream_arcs` its name-projection, so the pinned predicate is
    preserved as a SET and the gate re-verified it green. THREE faces now pinned with negative controls: reachability,
    loop-rule, existence (`drop Zeta` undeclared must be unknown-Space; blind the existence check -> the pin goes
    green-wrong).
  · DRIVER: hooked in `yoner_emit_mlir.ml` on the merged `prog`, as an exit-3 semantic error. CRITICAL PLACEMENT: it runs
    BEFORE `Module_prefix.lower_cross_space` (which rewrites cross-Space calls into remote invokes and consumes the import
    decls). Run it after and the import/transitive arcs vanish and every drop looks legal. This bug was caught by a real
    project fixture, not the oracle: the oracle's `downstream_selftest` had only pinned WIRE and CALL arcs, never IMPORT
    arcs. Closed the gap by adding an `import_illegal`/`import_legal` shape to the oracle (negative control confirms it
    bites) and by placing the driver check pre-lowering with a comment that pins the ordering.
  · TESTS: `drop_construct_selftest` in test_space_graph.exe (in-process parser->check on real `drop` nodes, one misplaced
    drop flagged WITH its downstream site, one well-placed drop accepted; negative control: blinding check_drops turns it
    red). `regression/test_drop_check.py` (driver integration: a legal project compiles, an illegal import-arc drop and an
    illegal transitive drop each fail with DROP ERROR; the two illegal cases go red if the check is ever moved past
    lower_cross_space). Triangle closed: `regression/keyword_coverage/c_drop.yon` (leg 2, emits MLIR) + a `#### drop`
    entry in `website/docs/book/21-keywords.md` (leg 1) + regenerated SYNTAX-TRIANGLE.md. The coverage example is a
    PROJECT (`regression/keyword_coverage/drop_reclaim`, declares Space D, legal `drop D`): after the existence check a
    legal `drop` needs a declared Space, so a single-file example cannot exist. test_drop_check.py points at the same
    fixture (dual use) and adds the unknown-Space case. Whole affected suite green.
  · EMISSION (2026-07-03, DONE): the desugar unit placeholder is replaced by the real reclaim. Model R1 (Antonio's call):
    reclaim = hand the Space heap's live arena [0, arena_used) back to the OS via madvise(MADV_DONTNEED), page-aligned
    inward -- the WHOLE-HEAP TWIN of the existing yon_xheap_strip_trim (a proven primitive scaled from a strip's dead
    tail to the entire arena, NOT a new mechanism). Two safety nets: the virtual mapping stays valid (no dangling, a stray
    read returns zeros) AND the upstream check forbids the stray read. R2 (munmap/destroy) deferred: it would trade the
    first net for virtual space we do not need in 1.1. Serve-loop early-termination NOT touched: the RPC idle-death policy
    already handles process exit; 1.1 reclaims the heap only, not the process.
    · runtime: `yon_xheap_drop(h)` (void) in xleech2_heap.c (next to strip_trim, same page-alignment; increments the
      counter `g_xheap_drops` on every drop of a real heap; NULL is a no-op; arena_used is NOT rewound -- RAM reclaim, not
      a logical reset); `yon_xheap_drops()` exposes the counter; `yon_rt_drop_space(double heap_id)` in yon_rt.c (heap_id
      crosses as f64; reads the per-Space heap DIRECTLY from g_spaces[id] -- NOT via yon_rt_heap_for, whose out-of-range
      fallback is the shared global heap that must never be dropped; safe no-op for an out-of-range id or a NULL heap
      under L1_SHARED; returns heap_id as an inert f64). An atexit hook prints `[YON-RT] xheap_drops=N` when N>0, so the
      authoritative counter is readable from the binary.
    · emission: `drop X` desugars to `C.Var "__drop_space_X"` (an effectful term the sequence keeps); emit_mlir lowers it,
      via the same yon_space_str_<X> global the space bootstrap emits (the ABI-correct source of a `const char*`, unlike
      yon_rt_string_lit which mints an f64 interned handle), to `yon_rt_drop_space(sitofp(yon_rt_lookup_space("X")))` in
      the f64 ABI. Needed arms in BOTH emit_term AND infer_mlir_ty (the inference pass ran first and failed "unknown
      variable" until the second arm was added -- the anti-fake-green net again).
    · TWO pins on one observable (the counter), distinct failures: (a) emission wired through AND (b) the primitive ran --
      test_drop_check compiles+RUNS a standalone `drop D` and asserts the binary prints `xheap_drops=1` (the counter
      increments INSIDE yon_xheap_drop, past the madvise, so ==1 proves both the call arrived and the reclaim executed).
      Negative control SEEN failing: replace the emit arm with a placeholder constant -> no drop -> counter absent -> red,
      then restored byte-identical. Plus test_unit_drop_reclaim.c (runtime C oracle): a multi-page drop increments the
      counter and preserves arena_used, NULL/invalid-id are no-ops, drop_space returns the heap_id f64.
    · NEXT: the automatic reclaim at last-use (the mechanism), consuming the same downstream_arcs. The `drop` construct is
      now complete end to end: analysis decides, check verifies (existence then reachability), emission honors. The
      runtime reads a decision already made; it does not make one.

- **2026-07-02 — Space RECLAIM analysis + pin gate (the reclaim is compile-time decided, `drop` is a checked assertion).**
  DESIGN (Antonio, settled): Space death is COMPUTED from the text, not observed at runtime. No refcount, no
  subscription-count, no liveness-poll. Enabled by copy geometry (wire flattens bytes, import returns f64, the handle
  never crosses), so extracted values are copies decoupled from X's heap, so Space-liveness is PURE arc-reachability,
  zero data-flow. Two ROLES from ONE analysis: (a) automatic reclaim at last-use = the mechanism (nothing leaks);
  (b) `drop X` = an explicit CHECKED assertion that appeals to the SAME criterion (coincides with the auto point, can
  never fire earlier because the check forbids a downstream arc). `drop` is sugar-with-teeth (documents intent, catches
  your misconception with the exact site), NOT a second mechanism. No unsafe/early-drop (that would reintroduce the
  heuristic). The world-class claim: reclaim automatic-and-safe like a GC, deterministic like C, declarable-and-verified
  like a type annotation, all from one static check on the graph.
  · `frontend/space_liveness.ml` (additive, build green): import_map (symbol->Space; LIVENESS precision: an import arc
    fires at the symbol USE, not the `import` line), transitive_arcs (per function, wire ∪ import-call, closed over the
    call graph, recursion-guarded), and `downstream_arcs ~imap ~ftab ~tarcs body target` (the SHARED predicate).
  · LOOP RULE (Option A, Antonio's call, sound not heuristic): if a loop encloses the point, the WHOLE loop body is
    downstream (the back-edge re-runs it), so no legal drop inside a loop that touches X; first legal point is after the
    join. Conservative (post-dominator) but never unsound. Nesting via enclosing loops; scope is sequential (not a loop);
    inter-procedural via a downstream call whose callee has X in transitive_arcs.
  · GATE FIRST (before the construct, so the property is pinned before anything builds on it, and tested in isolation):
    the pins live in `frontend/test_space_graph.exe`'s no-arg self-test (test_* oracle family, run by test_ocaml_oracle),
    self-describing (a `*_illegal` function's `be drop_X holds ..` point must be rejected, `*_legal` accepted). FOUR pins:
    back-edge, sequential, transitive (level-2 hookup inside level-3), scope (seen-through). NEGATIVE CONTROL proved each
    BITES: M1 break loop-rule -> loop_illegal fails; M2 break sequential-rest -> seq/scope/trans fail; M3 break call-hookup
    -> trans_illegal (isolated); M4 break scope-recursion -> scope_illegal (isolated). No pin passes unseen-to-fail.
  · NEXT (order fixed): (1) the `drop X` construct (parser SDrop + tycheck check consuming downstream_arcs + reclaim
    emission), (2) the automatic reclaim at last-use. Both consume a now-blinded downstream_arcs.

- **2026-07-02 — STATIC Space communication graph (compile-time, foundation for the 1.2 death-watch).**
  Additive frontend pass, zero runtime/emit changes. `frontend/space_graph.ml`: `type edge = { src; dst;
  kind : Wire | Import; loc }`; `edges_of_file ~src_space` (one pass, both families); `build`/`isolated`/
  `in_degree`/`out_degree`/`reachable_from`/`unreachable_from_entry`/`find_cycle`/`dump`.
  · Nodes = Spaces (a Space is a directory); the entry root is node "". Edges = two DECLARED static families:
    `wire to space X` (EWireTo, surface_ast:146) UNION `import mod::sym from X` (TopImportFrom, surface_ast:696,
    reused via Manifest.import_targets). The wire∪import decision is SOUNDNESS, not scope: a Space reached only by
    an import must count as reached, so in/out-degree SUMS both families (kind is only for the dump). Isolated
    (in=out=0) = static-reclaimable; a sink (in>0,out=0) needs death-watch (dynamic, 1.2).
  · Hook: `yoner_emit_mlir.ml` per-file parse loop (:194, where sp = ul_space and decls = synth @ p are in
    scope). CRITICAL: a form-C `fun main` inside a place is lifted to Parser_state (parser.mly:655); the driver
    drains it per file, so edges of a place-body arrow inherit the file's Space. The extractor walks expr/stmt/
    top_decl EXHAUSTIVELY (no wildcard) so a new constructor fails the build rather than silently dropping a wire
    (the exhaustive net caught RcLet + FoLaw; the real-fixture net caught the Parser_state-drain gap).
  · Artifact: `yonc <dir> --dump-space-graph` (frontend flag, dumps + exits before emit; yonc passthrough added).
  · Gate: `regression/test_space_graph.py` (5 tests) on `regression/space_graph/topology/` (entry->A, A<->B cycle,
    C isolated, D import-only). THE pin: `test_import_only_space_is_not_isolated` (D reached only by an import must
    NOT be isolated); proven to BITE via a negative-control mutation (degree filtered to Wire -> the test fails).
    `test_space_graph.exe` doubles as a no-arg self-test oracle in the test_* family.
  · Honest boundary (step 6): EWireTo/import always name a static IDENT, so there is no syntactic dynamic-target;
    the imperative `Wire.make_shm(...)` builtins carry runtime args, name no Space, and are out of the static
    graph's scope; a named-but-undeclared target is listed under "unresolved targets", never invented away.
  · Note added to notes/todo-1.2.md: the compiler guarantees the topology, the 1.2 runtime observes the closure.
    All green (graph gates + projects + surface fuzz + oracle + source<->binary diff). NOT committed (Antonio does).

- **2026-07-02 — CANONICAL FORMS as executable spec (the corpus IS the spec, markdown is a projection).**
  Antonio's architecture: truth lives in runnable `.yon`, not markdown. `regression/canonical_forms/<construct>/`
  holds `canonical.yon|canonical/` (+ `.expect`) and `dev_*.yon|dev_*/` (+ `.expect`). Each `.expect` carries
  `status` (accept | reject_clean | enforce_1_2), `exit` (from the compiler, not assumed), and `match` (an error
  fragment that MUST appear, so a deviation can never pass for the WRONG reason). New gate
  `regression/test_canonical_forms.py`: (1) execution, (2) completeness vs parser.mly `covers:` + `allowlist.txt`,
  (3) generation of `regression/CANONICAL-FORMS.md` (`--check` for CI). 39 constructs, 19 deviations enforced, 1 debt.
  Confirmed decisions: granularity = surface construct; provenance = canonical extracted from the corpus
  (dir-canonicals COPY the examples/ project); populate all d'un fiato; migrate atomically at full coverage.
  · COMPLETENESS is REAL grammar coverage, not covers:-accounting. "ma stiamo testando tutta la sintassi?" exposed
    that covers: was an assertion. Built `frontend/tok_dump.ml` (a token dumper, generated from the %token list,
    added to the dune executables): lex a .yon -> token names -> `menhir --interpret --interpret-show-cst` -> read the
    reduced production names off the CST. job 2 (`test_every_production_reduced`) asserts every non-allowlisted
    parser.mly production is ACTUALLY REDUCED by a fixture. Found 4 aspirational covers: (call_or_new_stmt,
    produce_stmt, standalone_op, reduction_type_params were the STATEMENT/top-level FORM, my canonicals used the
    expression form); closed them with real fixtures (produce/stmt_form, new/call_statement, algebra/standalone_op,
    reduction Sum<T>). Result: **92/94 productions reduced by a real fixture**; the only 2 not are hcomp_side/hcomp_base
    (cubical, no surface writer) -> allowlist.txt (tightened to just those 2; the structural list rules are reduced
    incidentally and are NOT allowlisted). covers: stays as advisory doc; the reduction check is the teeth.
  · enforce_1_2 = the keystone: a deviation the compiler ACCEPTS today but 1.2 must reject. Gate compiles it, asserts
    it still passes (never lies about the present), records it as debt. `entrypoint/dev_c` (form C, main-inside-Entry)
    is the first. When 1.2 lands it starts failing to compile -> flip .expect to reject_clean + match, and the gate
    becomes the fix's acceptance test.
  · reality corrected the layout: reject exit is 1 (not 3); entrypoint is DIR-mode (file-mode allows bare main);
    forever lives in an uncalled function; spawn/promote is one construct; variant is the sum+HIT eliminator (covers
    hit_branch, canonical -> 7). Real messages captured from the 19 negatives are the `match:` fragments.
  · ATOMIC MIGRATION done: retired the hand-authored `regression/CANONICAL-FORMS.md` + Leg 3 of test_syntax_triangle.py.
    The triangle now owns legs 1/2/4 (keyword-doc, coverage, book fidelity) + a KEYWORD_ALLOWLIST constant; the
    production leg is test_canonical_forms.py. Both `--check`-clean. Whole suite 341+ green, collects 1065.
  · PLACE-MUTATION FAMILY, two bugs found + fixed (2026-07-02), grounded in content-addressing (Antonio: a place's
    address IS its bytes, so in-place field mutation is semantically impossible; the only coherent "mutation" is the
    handle swap `p = new P{...}`):
    (1) `x.f = e` (in-place field mutation) used to CRASH (`Fatal error ... '__space_update_here'`). Rightly rejected:
        reject `LField` lvalues in tycheck.ml `type_of_lvalue` (covers `x.f = e` and `x.f holds e`), "place sections are
        immutable in 1.0". `x = e` cell reassign unaffected. syntax-reference status -> `✗ rejected` (new legend row).
        Pinned by canonical_forms/assignment/dev_field_mutation (reject_clean).
    (2) `p = new P{...}` then `p.x` (rebind + project) also CRASHED (`field projection 'x' on a non-section`). This is
        the COHERENT mutation and had to WORK (Option A). Cause: the `=` promotion turns p into a scalar Space cell;
        the section handle survived as f64 bits but the section TYPE was lost, so `Space__get(p)` typed f64 and `p.x`
        crashed. Fix (emit_mlir.ml): `g_cell_elem` table records a promoted cell's element section type at its
        `Space__make` binding; `Space__get` on such a cell reconstructs the section from the f64 handle (fptosi +
        topos.xcoord_to_section, the existing DTO-wormhole inverse coercion). Places are now first-class through the
        mutable path (rebind + project, incl. in a loop). Pinned by canonical_forms/assignment/place_rebind (accept 42).
    Both: surface fuzzer + pipeline + projects + source<->binary diff green (no miscompile, kernel agrees).
  · Scratch driver that scaffolded the fixtures: scratchpad/build_canon.py (not committed; fixtures are the artifact).

- **2026-07-02 — SYNTAX TRIANGLE gate shipped (lexer <-> corpus <-> book, one invariant).**
  New permanent CI guard `regression/test_syntax_triangle.py` (140 tests, green) closing the
  triangle that `test_keyword_docs.py` only touched on one edge:
  · Leg 1 lexer->book: every lexer keyword has a `#### `kw`` section (folds in test_keyword_docs).
  · Leg 2 lexer->corpus: every keyword exercised by a compiling example, or in a justified
    Table-C allowlist. All 117 keywords are exercised (0 allowlist-needed beyond 5 kernel/lexing
    tokens); generics `<T>` are IN the corpus (`identity<T>`), not allowlisted.
  · Leg 3 production ledger: every parser.mly production (94) has a canonical/deviation row
    (Table A) or a structural-helper reason (Table B) in the NEW `regression/CANONICAL-FORMS.md`
    (Antonio chose "artefatto strutturato" over derive-in-gate); every named deviation's negative
    fixture is compiled and MUST be rejected (13 gated, e.g. neg_rebind_holds, sum_payload_wrong_type).
  · Leg 4 book->corpus: 13 project CodeWindows byte-identical to their `examples/` files; all 25
    CodeWindows executed via their literal `run=` command; 20 standalone prose blocks carry a
    `<!-- yon-gate: exit N -->` marker (compiled+run), 32 fragments marked `illustrative` (exempt,
    COUNTED in the artifact — Antonio chose "marker + esenti contati").
  · Artifact `regression/SYNTAX-TRIANGLE.md` = the full matrix (keyword x lexer x corpus-count x
    book-anchor + production x canonical x deviation x enforcement), regenerable, `--check` for CI.
  · Gate parser gotcha fixed: table cells with escaped pipes (`A \| B \| C(T)`, `a \|> f`) must be
    split on UNESCAPED `|` only. Run with `.venv/bin/python -m pytest regression/test_syntax_triangle.py`.
    Site build stays green (52 `<!-- yon-gate -->` HTML comments do not break MDX). Partially closes
    the `notes/to-fix.md` runtime-gate gap (book examples now yonc+run+exit-gated; general examples/*/ still open).

- **RESUME 2026-07-02 (cont.) — SWEEP CORRECTED + COMPLETED. The earlier "systematic bug" was a MISDIAGNOSIS.**
  The real directory-mode entrypoint rule, re-derived from live behaviour (4 variants tested):
    A/D  `place Entry { }` empty + top-level `fun main`  → COMPILES (exit as expected)
    B    bare `fun main`, NO `place Entry` at all        → FAILS (this is the ONLY real error)
    C    `fun main` inside `place Entry { … }`           → COMPILES
  So form B is the only broken shape; A/D and C both work. ALL 34 real `examples/` projects use form A/D
  (`place Entry { }` marker + top-level main). The prior fix-pass had wrapped mains into form C, diverging
  from that convention. DECISION (Antonio, 2026-07-02): **form A/D EVERYWHERE** (Entry is a marker, main
  is a top-level fun; the honest model).
  · DONE this turn, each reconstructed + compiled + RUN to its stated exit:
    - ch21: all 13 directory CodeWindows SYNCED to their real `examples/<name>/` files (bodies mirror disk);
      subscriber.yon made self-contained (added the `sensors.yon` producer, cross-package pair → 36, backed
      by regression/cross_space); **all 25 CodeWindows now pass via their LITERAL `run=` command (25/25)**.
    - 8 chapters converted form C → A/D (ch05/06/08/09/10/15/16/18, 12 blocks); 3 prose descriptions
      (ch10 tree-comment, ch15 ×2) aligned to A/D. Verified compile+run: ch06 Order→42 & verify Tally→42,
      ch08 is_overdrawn→42 & forcing→0, ch09 pair/refl→42 & pullback→7, ch10 restaurant→44 & kitchen/pass
      39/38 & scope→42, ch18 error→42.
    - `examples/capability_flow_demo` was broken by MY `new P in Space` removal (used `new … in EU`);
      migrated to `new …` → runs (110). All 34 examples/ compile now except the intentional negative fixture
      `closed_morphism_capture` (the closed-morphism-discipline demo).
    - `npm run build` = SUCCESS. Book em-dash = 0 (only ch20's real yon-doc OUTPUT keeps its em-dash).
  · TOOLCHAIN GOTCHA found + worked around (do NOT reintroduce): `yonc dir/ -o NAME` where `NAME` equals
    the source directory basename fails at link time (`ld: open() failed, errno=21`, EISDIR) — the binary
    name collides with the `NAME/` dir. Fixed 6 ch21 `run=` commands to use a distinct `-o` name.
  · KNOWN / not touched (flag to Antonio): (1) ~16 PRE-EXISTING viz components (ArenaOrbit, XSetBitmap,
    Mutation, ThreeLenses, …) have em-dashes in RENDERED text — separate decision whether the no-em-dash
    rule extends to viz prose. My new viz (ProjectStructure/GeomorphAdjunction/OntologyMap/HeytingOmega/
    ContentAddress/…) are clean. (2) ch10 restaurant has no `examples/restaurant` fixture (assembled from
    prose, verified→44). (3) ch15 walkthrough uses an external `yon_modules/geometria` dep (conversion is
    exit-preserving; not re-run standalone). Only ch21 has CodeWindows; other chapters are prose blocks.

- **BOOK MANUAL FINALIZATION started 2026-07-01 (strada A, chapter by chapter).** The `docs/book/`
  25-ch manual is now IN SCOPE (was excluded). Verified live: the inline `world{}` / `place X in W`
  model is DEAD (even `regression/book/01/park_ok.yon` no longer parses); the live model is
  filesystem-only: `[world.X]` in `yon.toml`, space=directory, place=file, `Topos.yon`, arrows in
  place files, compiled via `yonc <dir>` / `yoner_emit_mlir <dir>` (single-file emit of a place fails
  with "cannot infer world"). ALL SEVEN ARROWS WORK in a real project (verified from live code, not
  state.md's stale "debt" flags): view / reduction / fun; move as `field maps to field by identity`;
  functor between two worlds with DISTINCT spaces; geomorph; nat transform. My earlier "arrows are
  debt" was WRONG, caused by my own malformed test projects (missing `by identity`, two places in one
  file, one space in two worlds). Toml needs `[runtime] backend = "memory|separate|shm"`.
- **Project-level fuzzer built 2026-07-01** (`regression/surface_fuzz_projects.py` + gate
  `test_surface_fuzz_projects.py`): closes the gap the inline `test_surface_fuzz.ml` left. Generates
  whole projects (world/space/place/7 arrows + malformed variants), runs the project pipeline, asserts
  never-Fatal. ~6000 projects, BUGS=0, both accept+reject paths covered (coverage line printed). The
  filesystem/arrow surface is no longer un-fuzzed.
- **Running-project thread for the project chapters = RESTAURANT** (Antonio's choice over bank/airport).
- **Ch 7 "Arrows" REWRITTEN 2026-07-01** (`docs/book/07-arrows.md`), v2 after Antonio's pedagogy note:
  teach EVERY arrow in the domain where it is natural, not forced into one.
  · **Restaurant, TWO spaces** (`sala/` + `cucina/`) so the model fits: `sala/Order.yon` (with-effects),
    `sala/Bill.yon` (view, computed column), `sala/ToKitchen.yon` (move, now crosses sala→cucina),
    `sala/Tally.yon` (reduction), `cucina/Ticket.yon`, `cucina/Line.yon` (**geomorph** with pull+push,
    the adjunction sala⇄cucina — Antonio's framing: an Order in sala corresponds to a Ticket in cucina).
  · **functor + nat transform → a SECOND project (BANK)** where they are natural (forced in a
    restaurant): two worlds `EurBank`/`UsdBank`, `functor Spot`/`Fwd` (x*110/100, x*112/100 = currency
    conversion of the whole context), `nat transform Adjust from Spot to Fwd`. Both projects compile
    (emit exit 0); every snippet is a real file. Closure-rejection shown (real error, paraphrased since
    the compiler message has an em-dash).
  · Viz: `ProjectStructure.js` (updated to two spaces + geomorph) + NEW `GeomorphAdjunction.js` (the
    push⊣pull adjunction between sala and cucina). First two viz in the narrative manual.
  Verified: all 7 arrows work in the live project model (view/reduction/fun/move/geomorph/functor/nat).
  0 em-dash, build green. Saved projects: /tmp/restaurant_v2, /tmp/bank_v1.
- **Ch 6 "Worlds and places" REWRITTEN 2026-07-01** (`docs/book/06-worlds-and-places.md`), restaurant
  thread, introduces the ontology ch07 uses. It was NOT `world{}`-stale (already used the live
  filesystem model), but every snippet is now gated + it is aligned to the restaurant + given its own
  viz. Sections: the ontology (world=category=toml / space=dir / place=file=object / section=value);
  a place is pure structure (`new Order { table 5 total 40 }`, dot access, main → 42, print via
  `IO.print_num` to avoid the effect annotation); operations (`with effects`, `operation`,
  `functorial operation` = the Yoneda lift); `subcontains` (VipOrder subcontains Order); worlds compose
  only via arrows (no world-algebra); **certified laws** (`place Tally … operation add uses algebra
  Additive  law commutative/associative`, `verify Tally` → `Magma.is_commutative/associative` → 42;
  the restaurant framing: the bill tally is commutative). ALL gated (new/field→42, functorial exit 0,
  subcontains exit 0, verify/laws→42). New viz `OntologyMap.js` = category ↔ Yon ↔ disk (distinct from
  ch07's ProjectStructure, honoring viz-dedup). 0 em-dash, build green.
  NEXT: ch10, ch16 on the restaurant thread; then ch03/ch21 (other stale), then the rest.

- **Language**: book in **English**; conversation with author in Italian.
- **Spine**: 7 Iterations of the novel → 7 Parts, ascending **silicon → Yoneda**.
  Content-addressing planted as silicon (Iter 2), revealed as Yoneda (Iter 7).
  Approved 2026-06-26. Map locked in `01-jp-structure.md`.
- **Fresh start**: old `book-plan.md`/Ch1/`ThreeLenses.jsx` archived in `_archive/`.
- **Basics woven into Iter 1-2** as connective tissue, not a Part of their own.
- **Iter 6 load note**: heaviest Part (sheaf/descent/morphisms/wire); if it overflows
  when drafting, `wire` drops to the tail of Iter 5. Don't rebalance pre-emptively.
- **Honesty marking is law**: every construct carries ✓ verified / declared / debt
  with a `file:line` source. No claim without a source. No fake green.
- **~~Sandbox can't compile Yon~~ — SUPERSEDED 2026-06-28.** This environment (Darwin arm64)
  HAS the working toolchain: `./toolchain/yonc <proj> -o /tmp/x && /tmp/x` compiles+runs a `.yon`
  to native and returns real stdout+exit. I now **gate `.yon` inline** (no round-trip to Antonio).
  The old "pending Mac gate" mark is retired; a snippet is ✓ once I have run it here. (The Linux
  Mach-O belief was wrong for this env.) The honesty law is unchanged — no ✓ without an actual run.
- **Visualizations**: Yon computes & prints (stdout via `Output`); a thin harness
  captures stdout → `trace.json` OR the gated numbers are inlined in the component (cited in its
  header); React replays. The JSON/inline capture is a tooling step (declared), not a Yon feature.
  Players: Fractal (opens all 7 Iter), Paddock map (Iter 3.3), Genome (Iter 2.2), **+ the 11 field-guide
  viz of 2.3 (one per data structure, all replaying gated numbers, site builds green)**.
- **#3 Space cell — closed by observation** (not a debt). See canonical terms.
- **2.3 — SHIPPED as "The Park's Memory" (field guide, 2026-06-28/29).** The chapter below went
  through two prior designs ("Classifying the Animals" → "How Many Dinosaurs?"); the FINAL, built
  chapter is the **field guide to the 11 data structures** (`website/docs/jp/iteration-2/03-the-parks-memory.mdx`):
  HashSet · HashMap · MerkleTree · List · Vec · VoyagerList · Arena · XSet · XRelSet/XRelMap · XSimplex · XTower.
  All 11 gated (`regression/book/jp/uc_*`, `13/14/15` contracts), every page snippet runnable+gated,
  11 viz, site builds green. The "How Many Dinosaurs / mutation" design below is SUPERSEDED prose-wise
  but its honesty lessons (Superenalotto / data-processing-inequality, the clade reader, Co2 vs Co0)
  are CARRIED into the field guide. OPEN THREAD: the mutation arc (`Mutation.js` exists) is now
  homeless — fold into a future 2.x or cut. The original design notes are kept below for the record.
- **2.3 (ORIGINAL design, superseded): "How Many Dinosaurs?" (subtitle "The Same Animal").**
  The cladistics/taxonomy experiment (trees, clades, the 48-taxon phylogeny) is
  **CUT** — it was the failed attempt to read external *biology* off the lattice
  (it reads the embedding: grade=popcount, or Golay structure — see
  `manuscript/linear-map.md`). 2.3 instead tells the JP story of the **X data
  structures on the Leech lattice** via **MUTATION**, bridging 2.2→2.3:
  · The spine is JP's actual question: *how many dinosaurs?* (Hammond says 238).
  · The bridge from 2.2: Golay corrects ≤3 errors, but PAST the radius it decodes
    silently to a DIFFERENT valid gene = a **mutation** ("life finds a way", made
    precise). Gate: `corrupt(seal(g), 4)` → `open` ≠ g.
  · Three notions of count, ONE spine — **identity vs class**, three levels:
    VoyagerList (events / every append) → XSet (distinct exact points / individuals)
    → XRelSet·XRelMap (distinct ORBIT classes). Only the third **collapses**.
  · Hammond's blind spot, made math: the system is NOT blind — XSet had the exact
    count. He CHOSE the class-count (XRelSet, fast); life happens to individuals,
    which List/XSet already counted. The blindness is the CHOICE of count, not the
    lattice. The XTower is that dial: Co0 (class, blind) → id (individual, sees all).
  · Co0/M24/Conway = the law that defines the classes (symmetry, not a chosen
    threshold). omega = the one absolute invariant (Co0), the quiet after.
  **HONESTY STRETCHES (load-bearing, the day's lesson applied to prose):**
  (1) "new species" is the STORY's word, NEVER a lattice claim. A class-jump is a
  move in the lattice's geometry; calling it a species is a word the reader puts on
  top of a geometric distinction. Write "fell into a different cell of the lattice —
  the system flags a new *type*, you are free to call it a species, but that word is
  yours over a geometric distinction." (2) The mutation makes a new GENE (real,
  Golay); "codes for a male / the sex switch" is Crichton's story, marked as eco,
  not a lattice read. (3) Final tone = HUMILITY, not triumph: better than Hammond not
  because the system sees species (it doesn't) but because it tells the truth about
  what each structure counts. Enact it, don't preach it.
  **VOICE:** first person — the prologue's "I" returns HERE and only here, for the
  mutation/disillusionment beat (*I* trusted the correction). Clean transition in and
  out; the rest of 2.3 stays in the standard register.
  **VIZ reuse:** keep `LeechShells` (the pens / 196,560), `DinoLattice` (of2 = Wu's
  ruler), `OmegaInvariant` (the absolute). Repurpose the collapse data (N individuals
  → fewer classes) as the blind-spot viz. CUT `TaxaTree`/`TaxaMatrix` (the phylogeny).
  **XTOWER = the DIAL of equality (locked 2026-06-28).** Not an extra classifier —
  the one structure that makes the three counts ONE axis. The tower is a TRUE
  refinement, M24 ⊂ N ⊂ Co0 (code comment, leech_orbits/xtower): a finer cell is
  contained in a coarser one, so the collapse is MONOTONE up the tower. Levels =
  widths 1 / 3 / 12 / 196560: **level 3 (id) IS XSet (individuals), level 2 (M24)
  IS XRelSet (classes), level 0 (Co0) is all-one.** XSet/XRelSet are two fixed
  levels; XTower is the whole axis, traversable by `same_branch(a,b,level)` — "are
  these the same?" at a grain you turn. Narratively it CLOSES the collapse beat (no
  tour-beat): Hammond's blind spot is not a wrong structure, it is fixing the dial
  at Co0 and never turning it — the exact count was always there at id. Honesty: on
  the data level 1 (N) was DEGENERATE (`orbit_l1 distinct=[1]`); show the dial with
  real notches AND notches that don't separate on given data — true of the group,
  not a code defect. Orbit labels build-unstable (partition stable); mode-0 orbit is
  coarse but NOT pure popcount (1445,2361 same popcount→diff orbit), so "grade" is
  the coarse tendency, not a theorem. Gate: `probe_orbit_spread` (orbits vary, real
  collapse), `11_mutation` (1445→2361 at k=5 silent; k=4,6 DETECTED = fail loud).
  **DRAFTED 2026-06-28: `manuscript/chapters/05-how-many-dinosaurs.md`** (supersedes
  `05-classifying-the-animals.md`). Beats: the count -> the mutation (first person) -> the
  dial (XTower same_branch 1,1,0,0 + widths 1/3/12/196560) -> Hammond's blind spot (the
  level, not the structure) -> omega (the absolute) -> humility. All numbers gated.
  **MDX BUILT 2026-06-28: `website/docs/jp/iteration-2/03-how-many-dinosaurs.mdx`**
  (old `03-classifying-the-animals.mdx` DELETED). Two NEW viz on gated traces:
  `Mutation.js` (mutation.json, the radius edge: corrected ≤3 / detected 4,6 / silent
  mutation 2361 at 5) and `XTowerDial.js` (dial.json, the dial Co0→N→M24→id, same_branch
  1,1,0,0). Reused: `LeechShells` (196560 pens), `DinoLattice` (of2 = the relation, Co2),
  `OmegaInvariant` (the absolute). DELETED components: TaxaTree/TaxaMatrix/TrianglePanel.
  Harness regen TODO (optional): add mutation()/xtower_dial() to build-jp-traces.py.
- **2.3 RE-DIRECTED AGAIN (2026-06-28): "how-many-dinosaurs" DELETED, replaced by a
  FIELD GUIDE of the data structures.** mdx + both manuscript chapters (how-many-dinosaurs,
  classifying-the-animals) DELETED. Components KEPT (reusable): Mutation, XTowerDial,
  OmegaInvariant, LeechShells, DinoLattice. The new chapter: the FNV-vs-Leech table as the
  spine, ONE JP use case per structure — "the park wants X → which structure → gated .yon →
  honest FNV-vs-Leech / conditional. The COMPLETE structure inventory (re-derived from
  stdlib_runtime.ml, NOT from memory — I had missed Vec/Arena/MerkleTree/PerfectMap and
  wrongly called the quantizer a "structure"; it is Leech.embed, a function):
  · identity (FNV/hash): HashSet, HashMap, MerkleTree
    (content-equality of trees) · lists: List, Vec (push/get/set/size, the counter),
    VoyagerList (Golay) · lattice: Arena (type-2 store + orbit + CERTIFIED FUSION),
    XSet (bitmap sets), XRelSet/XRelMap (orbit class), XSimplex (of2/triangle/omega), XTower.
  10 sections CONFIRMED by Antonio. GATED SO FAR (self-run): §A identity
  (`uc_a_identity`: HashSet 4 = XSet 4 — FNV wins, no map, exact-by-byte-compare; mode 0 is
  near-injective, no collapse — corrected my overclaim), §B sets (`uc_b_sets`: XSet
  intersect/union 3,3,2,4 — Leech wins, bit-parallel), §6 Arena (`uc_arena`: 42,1,0,1,0,1 —
  store/orbit/same_kind/fusion). TODO when Antonio is back: build+gate §2-5, §8-10, then the
  field-guide mdx. KEY FINDING (FNV vs Leech, the day's synthesis): FNV is the better
  content-address (identity, any type, exact); Leech wins UNCONDITIONALLY on structure
  (bit-parallel sets, compact 18-bit index) and CONDITIONALLY on geometry/algebra (similarity,
  orbits, omega — only with a meaningful map / lattice-native points; the open problem, by the
  data-processing inequality — "no map manufactures meaning"). XSet add silently drops
  non-type-2 (yon_rt.c:5200); XRelSet/XRelMap dedup by SIGN-orbit (1536~−1536, ≁1280), Arena by
  M24-orbit (1536~1280). **OPERATIONAL: in this environment `./toolchain/yonc` RUNS (Darwin
  arm64) — gate inline, do NOT round-trip to Antonio.**
  **FIELD GUIDE BUILT 2026-06-28: `website/docs/jp/iteration-2/03-the-parks-memory.mdx`**
  ("The Park's Memory"). All 12 working structures gated inline by me, every number from a real
  run: HashSet `uc_a_identity`(4), HashMap `uc_hashmap`(1,0,2), MerkleTree `uc_merkle`(1,0),
  Vec `uc_vec`(3,1445,9999), VoyagerList `uc_golay`(1445×3), Arena `uc_arena`(42,1,0,1,0,1),
  XSet `uc_b_sets`(3,3,2,4), XRelSet/XRelMap/XSimplex `14_xrel_contract`, XTower `12/15`.
  **PerfectMap DROPPED 2026-06-28** (Antonio: "confluita in HashMap, va droppata"). Removed from
  all 6 sites (stdlib_runtime registry+runtime block+ops, tycheck runtime_builtin, reduce/builtins
  strict-reduction prefix, reduce `__pmap_` value-tag, main.ml Test 49 def+call); `dune build`
  green, source grep clean, contracts 13/14/15 + uc_hashmap re-gated exit 0; the mdx
  "declared, not yet built" note removed. Debt-detector method: `grep -c "Name__"
  emit_mlir.ml`, 0 = declared-only. Reused viz: LeechShells, XTowerDial, OmegaInvariant.
  Chapter structure: the FNV-vs-Leech table as spine, one JP use case per structure, closing
  "when to use which" (FNV = identity/any-type/exact; Leech = unconditional structure + conditional
  geometry). TODO if wanted: a /code-review of the chapter.
  **TEST CLEANUP 2026-06-28** (after PerfectMap drop): `frontend/main.exe` had 31 failing tests
  (175 total). Verified by instrumenting the runner (`List.mapi ... eprintf "TESTRESULT"`): the 31
  were all **obsolete-by-architecture**, NOT regressions — 29 embed the pre-toml surface model
  (`world {…}` blocks, `place X in Demo with effects {…}`, `let … holds`, variable-bound `Space.make`)
  and 2 were cubical `comp` (Antonio: "la cubical è roba della 1.2"). Per Antonio's design note —
  **`world` is declared ONLY in toml; a `Space` is filesystem+toml and CANNOT be bound to a variable**
  — these test a removed front door (the real world/space coverage lives in `regression/` filesystem
  projects). Antonio: "elimina tutti i test, anche i cubical". Removed all 31 (def + `tests`-list
  entry each, −1024 lines, `frontend/strip_tests.py` method) → `dune build` green, **suite 144/144,
  all pass**. Backup at /tmp/main.ml.bak.
  **11TH STRUCTURE + DINO EXAMPLES + CONSTRUCTED MEANING 2026-06-28**: Antonio — "dovrebbe esserci
  una 11esima ovvero una List", "per ogni struttura aggiungi un esempio dinosauride", "per le funzioni
  geometriche prendiamo esempi dove il significato è costruibile e costruiamolo".
  (1) **List IS the 11th** — verified live: registry + emit_mlir lowered (cons/empty/head/tail/length/
  reverse; NOT append/is_empty, infer-table-only). Built `uc_list` ("the descent chain", a lineage by
  cons) → `3 1445 1280 1207 2`, exit 0. Note: surface `List.empty(0)` (unit arg = 0, not `()`).
  (2) **Table rebuilt** in the mdx: 11 rows, columns structure|engine|the park's question|**a dinosaur
  example**. List its own section "The descent chain — the list".
  (3) **Constructed meaning = the clade reader** (`uc_clade`, self-checking, exit 0, `0 34 34 70`):
  encode a dino as a trait bitvector (bit0 bipedal,1 feathered,2 carnivore,3 crested,4 armored),
  place with LINEAR gcode embed `Leech.embed(bits,3)`, then `Leech.pair_subtype` reads the Golay
  subtype-CLASS of the symmetric difference a^b (the synapomorphy set = which characters distinguish
  two animals). Laws gated: identical→0; same distinguishing set on different bases→same class
  (R→V and S→SV both {feathered,carnivore}→34, proving it's a function of a^b, NOT of the animals);
  distinct→nonzero; a different synapomorphy {feathered,armored}→70 (it RESOLVES). HONEST boundary
  (in prose, not a failing law): pair_subtype is COARSE — it's the Golay class, not the exact set, so
  distinct sets can collide (my first draft's V-vs-B and V-vs-T both =66 caught this). New mdx section
  "Constructing the meaning — the clade reader". Mechanism re-confirmed from `probe_linear_clade`
  (`1 1 1 1 1 1 | 0 34 70 34 68 70 | 34 34`): mode 0 quantizer = grade-only (popcount), mode 3 linear
  = clade. All 12 use-cases re-gated together exit 0.
  **SNIPPET FIDELITY + 11 VIZ 2026-06-28**: Antonio asked "abbiamo esempi funzionanti per la pagina? viz
  per ogni struttura? Arena esposta?" Findings: Arena fully exposed (8 ops lowered, uc_arena green);
  only 3/11 had viz; and the page snippets were PARTLY fake — XSet & XRelMap had `/* ... */`/`...`
  placeholders that don't compile, HashSet showed `->2` (hand) while gated gives 4. Antonio chose
  **"tutti runnable & gated"** + **"viz per tutte e 11"**.
  · Snippets: fixed XSet (real uc_b_sets code), XRelMap (real add_ref+insert), HashSet (5 adds → 4,
    new project `uc_hashset` backing the exact snippet). Now every shown snippet = a gated project's
    real code+number. Intro line changed to "All eleven structures are built and gated."
  · Viz: built 7 NEW components in website/src/components/ — `HashIdentity` (dedup), `HashMapTag`
    (key→tag lookup), `MerklePedigree` (two trees =/≠), `DescentChain` (cons lineage), `HerdCount`
    (indexed cells + set), `ArenaOrbit` (M24-orbit kinds + fusion), `OrbitClass` (sign-orbit buckets,
    antipode hit / 1280 miss). Each replays its gated numbers (cited in the component header). Wired the
    EXISTING `GenomeGolay` for VoyagerList. All 11 structures now have a viz (the other 3: LeechShells/
    OmegaInvariant/XTowerDial). **`npm run build` GREEN** (Client+Server compiled, static files generated)
    — real proof MDX+components compile. The 7 new viz are static-interactive (button step/toggle), not
    d3-animated like the original 3; offered to animate if wanted.
  **2.3 POLISH 2026-06-29**: dial default → M24 (`XTowerDial.js` useState(2)) — the coarsest grain where
  same_branch flips 1→0, where the mutant APPEARS (at N still hidden, at id no blind spot left); the
  dramatic beat per Antonio. add_ref/Co2 explained in `OrbitClass.js` caption + the orbit-section prose
  ("the reference fixes the frame the class is computed against — XRelMap is Co2"), tying it to omega
  (Co2 vs Co0). Build green.
  **2.1 WRITTEN 2026-06-29 — "The Clones Are Real" (the Leech lattice = the 2nd engine).**
  Resolved the drift: 1.2 "Counted by Computer" ALREADY teaches FNV content-addressing in full (def,
  byte-compare, the slot, HashSet dedup gated, the clones-from-one-sequence). So the backbone's
  "2.1 = content-addressing" was redundant. Antonio chose: 2.1 = introduce the **Leech lattice** (the
  gap 2.3 leans on, completing the "Lattice & silicon" arc: 1.2 silicon → 2.1 lattice → 2.2 Golay →
  2.3 toolkit). Scene = the ARRIVAL / first sight of living dinosaurs (2.2 already owns the amber-lab
  scene), concept = a content-address by PLACE (geometry) vs by NAME (hash). Gated `uc_lattice` →
  `196560 12 1 2` (kissing number / 12 M24 classes / a point's class / XSet dedup to 2). Sources cited:
  `test_leech_theta.ml:26,33` (196560 theorem), `test_mphf.c` (perfect bijection, 0 collisions),
  `yon_rt.c:3077` (18 bits). Viz: reused `LeechShells`. File: `docs/jp/iteration-2/01-the-clones-are-real.mdx`
  (sidebar_position 1). `npm run build` GREEN. Honest boundary planted (the lattice gives the address;
  what a position MEANS is earned — pays off in 2.3) + Yoneda seed (name & place "will not stay separate").
  **VIZ DEDUP + BACKBONE SYNC 2026-06-29** (Antonio spotted LeechShells in 2.1 AND 2.3, GenomeGolay in
  2.2 AND 2.3): rule now = each chapter its OWN viz. LeechShells lives only in 2.1, GenomeGolay only in
  2.2. Built 2 NEW structure-specific viz for 2.3: `XSetBitmap.js` (paddock-membership grid, intersect
  AND / union OR, uc_b_sets 3·3·2·4) replacing LeechShells; `VoyagerListCorrect.js` (a list of sealed
  genes, element 0 corrupted 3 bits, get→1445, uc_golay) replacing GenomeGolay. 2.3 now uses 11 distinct
  viz, none shared with 2.1/2.2. Build green. **Backbone `01-jp-structure.md` Iteration-2 table SYNCED**:
  2.1 = Leech lattice (was content-addressing → now in 1.2), 2.3 = field guide (was "Classifying the
  animals", CUT). Note added there explaining the move.
  **VIZ ANIMATED 2026-06-29** (Antonio: "sì animiamole"): the 9 static-interactive 2.3 viz now
  auto-play like the 4 originals. Shared hook `website/src/components/_autoplay.js` (`useAutoplay(steps,
  interval=1700)` cycling 0..steps-1 on a timer; manual interaction pauses; `playLabel`). Refactored all
  9 (HashIdentity, HashMapTag, MerklePedigree, HerdCount, DescentChain, VoyagerListCorrect, ArenaOrbit,
  XSetBitmap, OrbitClass) to drive their state off the hook + a Play/Pause button; smoothness = their
  existing CSS transitions. Build green, no orphaned setters. (Mutation arc: explained to Antonio — the
  Golay failure mode past radius 3: `11_mutation` k=1..6 → 1445,1445,1445,FLAG,2361,FLAG; k=5 = the
  silent mutation. Recommended folding into the tail of 2.2 as its dark-twin beat; awaiting go-ahead.)
  **MUTATION FOLDED INTO 2.2 2026-06-29** (Antonio: "si mettiamolo in 2.2"): new section "## The
  mutation" after "The short leash" — FIRST PERSON (the designated voice beat, "I trusted the
  correction"), the honest crack in "a code fails rather than invents": at k=5 it silently decodes to
  2361. Snippet (seal/corrupt 3,4,5 → 1445/flag/2361) + `<Mutation/>` viz (now used) + a `:::note future
  work` (a future SPLIT covering every distance × every gene: corrects/refuses/mutates — gated here only
  that the silent case EXISTS, `11_mutation` k=5→2361). "What holds" cites the gate. Build green. The
  mutation arc is no longer homeless. `Mutation.js` now lives in 2.2 (not 2.3).

## FULL-BOOK REVIEW 2026-06-29 (6 parallel agents; findings below, fixes pending)
Reviewed all 11 "book" pages (landing + intro + impossible-park + syntax-ref + cubical + 6 JP chapters);
EXCLUDED the separate `docs/book/*` 25-ch language manual (ask Antonio if it's in scope). Tiers:
- **T0 systemic — em-dash LOCKED-rule violation** (`state.md:387` "NO em-dashes anywhere"): cubical 7,
  impossible-park 26, 1.1 ×2, 1.2 ×3, 2.1 ×24, 2.2 ×8, 2.3 ×35 (intro/syntax-ref/1.3 already clean).
  ~105 to convert to commas/colons/periods. I introduced most of the 2.x ones (drift I missed).
- **T1 critical:** (a) `syntax-reference.md` BADLY STALE — documents `world{}`, `becomes`, `init X as
  Space`, `space S …`, says "no reassignment x=e" (backwards; `=` IS the assign), zero-arg dummy `0`
  (live is `()`); needs rewrite vs live grammar. (b) `zz-draft-01-impossible-park.mdx` ORPHANED —
  inverted ontology (folder=world/file=space, backwards vs canon dir=space/file=place), uses ARCHIVED
  `ThreeLenses`, conflicts with shipped 1.1/1.2/1.3, wrong voice (ROI sidebar, checkpoints) → DECISION:
  retire or refile to Iter 6. (c) `cubical.md` OVER-CLAIMS — "nothing here is a stub / v1.1 end-to-end"
  but cubical is 1.2-scoped, comp/ua/hcomp emit+oracle-gated NOT native-gated; first snippet doesn't
  compile (undefined g/f/diag); needs scope banner + ✓/declared marks + fix snippet. (d) LANDING heap
  claim FALSE — "holds at most 196,560 slots, fails loudly at the limit"; runtime chains successor heaps
  (256×196,560), ch.12 says so; self-contradiction. + `functor` → a canonical arrow.
- **T2 honesty:** intro "becomes" → "="; intro cubical listed flat → mark forthcoming; 2.3 "fifty times
  faster" UNGATED number → soften; 2.3 Merkle/HashMap snippets show `//->1`/`false` but equal/has return
  bool → show `if…then 1 else 0` or annotate; 2.2 "refuse-to-guess flag" → name sentinel 2147483647.
- **T3 polish:** 2.2 stale admonition "GENOME player planned" (it's built); 1.1 quoted MLIR omits
  `func.call @yon_rt_maybe_serve()` + untagged code fence; 1.3 title missing "1.3 ·" prefix; 1.3 carries
  full manifesto (heavy for early ch — decision); 2.1 nested-vs-sequential XSet snippet (minor); nice:
  2361 = the mutant (2.2) reappears as a counted individual in 2.3 HashSet — make the callback explicit.
ARC VERDICT (agents): 1.2→2.1→2.2→2.3 holds; FNV-vs-Leech division consistent; no use-before-intro.

## REVIEW FIXES APPLIED 2026-06-29 (final build green, 0 broken anchors, 0 em-dashes book-wide)
- **Cubical page DELETED** (Antonio); intro ref removed; sidebar autogen self-updates.
- **Em-dash purge** (LOCKED `state.md:387`): all chapters + landing + 3 `_category_.json` (labels→`:`,
  epigraph attributions→`(Ian Malcolm)`). Method: `scratchpad/dedash.py` (headings→`:`, body→`,`) then
  hand-fixed comma-splices. Final sweep: 0 em-dashes anywhere.
- **Landing** `src/pages/index.js`: heap claim fixed (removed false "fails loudly at 196,560"; now
  "chains into a successor heap"); `functor`→`reduction` (canonical arrow).
- **Intro**: `becomes`→`=`; cubical dropped from the grounding list.
- **JP chapters**: 1.1 (MLIR "exactly"→"heart of", ```yon fence), 1.3 (title prefix "1.3 ·"),
  2.2 (sentinel `2147483647` named, stale admonition fixed, comma-splice), 2.3 ("fifty times faster"
  removed = ungated, Merkle `equal`→`true/false`).
- **Impossible Park → `docs/jp/iteration-6/01-the-impossible-park.mdx`** (NEW Iter-6 dir + `_category_.json`):
  ontology RIGHTED (was folder=world/file=space; now "directory=space, file=place, world in toml"),
  archived `ThreeLenses` removed, ROI/checkpoint off-voice removed, toml `Species`→`Dinosaur`, de-em-dashed,
  draft banner. Old `zz-draft-01-impossible-park.mdx` deleted.
- **Syntax Reference** rewritten (agent, re-verified vs live grammar): Worlds section (no surface syntax),
  `becomes`→`=` (+ fixed the backwards "no reassignment x=e"), removed `space S`/`init X as Space`/no-arg
  `pullback`/duration literals, `extends`→`subcontains`, Topos example de-stale'd, dead keyword-index links
  removed (these were the 5 broken anchors `#all #buffer #drop #objects #space` — now gone). HONESTY NUANCE
  the agent caught: `Time.now_ms`/`Args.count` really take `(0)` (sig `[tunit]`, like `List.empty(0)`), so
  it documented `()` vs `(0)` instead of blindly switching to `()`.
- **Manual `docs/book/*` (26 ch, 6 agents)**: `becomes`→`=` throughout, stale `world{}`/`space S`/
  `place X in W`/`import X from Y`(→`import mod::name`)/`wire to`(→`wire to space`)/durations fixed; ch10
  rewritten to real layout (gated→44); ch06 Magma `reachable` (nonexistent op) replaced; ch21-keywords
  purged of retired keywords + added `morphism` + fixed chapter cross-refs (ch18/19/20). Every edited
  snippet recompiled+gated.
- **Toolchain reconfirmed working** (uc_lattice→`196560 12 1 2`); the syntax-ref agent's "build broken"
  fear was wrong (its own temp-project setup).
REMAINING WORK (needs Antonio / a deliberate pass, flagged not silently changed):
  (1) **`93-benchmarks.md` numbers have NO reproducible source** in the repo (and landing reuses ~17ns) →
      DECISION: commit the benchmark programs, or soften the "produced by yonc" provenance claim. Untouched.
  (2) **ch06 & ch07** are pervasively stale at the EXAMPLE level (`world{}` blocks, world-algebra
      `world Pair = A*B`, `place X in W`) — conservative line-edits applied, but the core examples need a
      real rewrite to the filesystem model (changes pedagogy). A spawn_task chip exists for it.
  (3) **ch21-keywords**: ~16 CodeWindow snippets still use the retired single-file `world{}` model and don't
      compile; 15/23 referenced `examples/*.yon` don't exist; live keywords missing (nat/El/PathP/comp/
      hcomp/hit/plam/quote/promote/spawn/parallel). Needs a deliberate multi-file re-authoring pass.

## REPO CLEANUP 2026-06-29 (Antonio: "megapassata per sanificare prima dei benchmark"; commits are HIS, on main)
- **Artifacts**: `a.out` removed; `.gitignore` += `*.out`/`a.out`/`*.epub` (the JP novel epub kept on disk,
  never committed); a leftover agent git-worktree (`.claude/worktrees/infallible-meitner-8f70af`) removed.
- **Root declutter**: 5 scratch/TODO `.md` (SESSION_STATE, TODO, to-fix, todo-1.2, work-items) → `notes/`
  (Antonio: leave them as-is, just out of root). 9 real docs stay at root. `migrate_round2.sh` is tracked,
  left for Antonio.
- **File naming**: verified CLEAN — no `zz-` files; the 4 filename≠placename hits are exempt single-file
  standalone tests (rule applies only to yon.toml project dirs).
- **prettier ADDED** (website): devDep + `.prettierrc.json` (singleQuote/2-space/semi/printWidth 100) +
  `.prettierignore` (EXCLUDES `docs/` so the hand-wrapped book prose is never reflowed) + `npm run
  format`/`format:check`. Applied to 25 JS/CSS files; site build green.
- **COMMENT SWARM** (Antonio: "una passata su tutti i commenti in swarm"): 8 agents (+ their sub-batches)
  audited comments across frontend (~50 logic + 33 test .ml), runtime C (~35, minus the 24k generated
  `yon_curtis_canon.c`), and mlir (~20 passes). Rubric: fix only FALSE/STALE/PHANTOM/resolved-TODO
  comments, verified against live code; no logic, no style. **~50 fixed**, e.g.: `let`→`be`/`becomes`→`=`
  in comments (desugar/tycheck/tyenv/surface_ast/stdlib); cubical.ml + reduce.ml de-overclaimed (v1.2
  prototype); `yon_rt.c` ×8 (stale payload-header layout, false heap_id prefix, removed-fn refs, phantom
  merkle arity-1, static→dynamic stack); xleech2_heap.h "294912 is prime" (it isn't) + load-factor;
  `xleech2_move.c` (nonexistent) mutex ref → heap.c; mlir LowerToposToStandard.cpp ×10 (i32→i64 ABI,
  phantom `yon_xheap_apply_move`, false memref.copy move body); test_kernel_alpha.ml ×3 (false "de Bruijn
  migration"). I also fixed 2 CODE issues the agents flagged: `yon_lsp.ml` keyword-completion list (dropped
  retired `world`/`let`/`init`/`all`, added `be`/`topos`/`subcontains`) and a stale `desugar.ml` failwith
  string. **`dune build` green + `uc_lattice` gate green** after. FLAGGED for a deliberate later pass
  (NOT auto-changed): `yon_rt.c` test-header line-number drift (risky to bulk-renumber); `yon_shm.h`
  orphaned header (dead code); `world X = A+B` shorthand in site/sheaf/desugar comments (design-true);
  LowerToposToStandard.h "M1 implemented" status; `yon_rt.c` L1_SHARED vocabulary cross-file.
NEXT (Antonio's stated order): repo clean → **redo ALL benchmarks** (he wants to benchmark everything).
Still open from the book review: ch06/07 example rewrite (stale `world{}` model), ch21-keywords re-author.

## BENCHMARKS 2026-06-29 (Antonio: redo them; "pybench in modo corretto"; run on M1)
Three Antonio rules locked (see memory `benchmarks-methodology-and-machine`): he runs them on
his M1 (sandbox IS Apple M1, confirmed by pytest-benchmark machine_info); the table needs a
METHODOLOGY HEADER; timings are a DIFFERENT category from build-invariant numbers (mark "measured
on [machine] [date]", not re-derived each build), while the CORRECTNESS gate IS re-derived.
- **Two layers built:**
  (A) **Correctness gate** `regression/bench/*` (in-Yon Time.now_ns, min-of-K, baseline-subtracted,
      DCE-guarded) + `regression/test_benchmarks.py` (pytest: compiles+runs each, asserts the
      result GUARDS exactly — size=N, gene=1445, overlap=1000 — + lenient design properties:
      equality O(1) in size, XSet < HashSet). Re-derivable every build.
  (B) **Timings** `regression/bench_perf/` = pybench-correct: each op is `<op>/` (does N ops, exits)
      + shared `_read_base`/`_thru_base`; `test_perf.py` times the native binaries with
      **pytest-benchmark 5.2.3** (rounds, median, IQR, machine_info); `summarize.py` →
      per_op = op_median/N − base_median/N_base → `website/src/data/bench-perf.json` with M1 metadata.
- **Measured on Apple M1** (ns/op): MerkleTree.equal/String.equal ~0.5 (harness floor, O(1)),
  VoyagerList.seal ~1.4, Vec.push/get ~2, List.head ~6, HashSet.contains ~7.4, HashMap.get ~10,
  VoyagerList.open(corrected) ~13, Arena.get ~60, HashSet.add ~76, List.cons ~355, HashMap.set ~552,
  Arena.same_orbit ~645. Equality FLAT 1/1024/32768 chars (~1ns, eq_constant). XSet vs HashSet
  intersect/union ~22×/~51× (grows with N). Memory: 2M same=8MB vs 2M distinct=175MB (~87 B each, no GC).
- **NEW RUNTIME BUILTIN** `Leech.point(idx)` exposed (yon_rt.c wrapper + emit_mlir 3 sites + registry):
  the MPHF unindex, idx∈[0,196560)→distinct type-2 xcoord. Solved the "Arena/XSet many-to-one" (embed
  saturates ~4096 distinct; point gives 1000/1000 distinct). Runtime rebuilt (`cd runtime && make`).
- **`93-benchmarks.md` REWRITTEN** on the real M1 numbers: methodology header table + the honest
  category :::note + per-op table + equality-O(1) + XSet-bit-parallel + memory. Landing "~17ns" →
  "~1ns (Apple M1)". Site build green. 0 em-dashes. OLD "Linux container" + unsourced numbers gone.
- Findings flagged: List caps ~196560 at 1e6 cons (used 1e5); HashMap.set 551ns (>in-Yon 193 — different
  baseline, the pybench one is authoritative); Arena.same_orbit noisy (recomputes M24). XSet pool=256
  (prototype, not Leech-inherent — XSet IS a 196560-bit Leech bitmap via the MPHF, NOT FNV).
NEXT: Tier 4 (heap-expansion + emit memory state, Space cells, interning) then multi-process
(wire/spawn/parallel-N) + the mmap viz fed by the heap-expansion trace. Antonio re-runs on his Mac.

## Voice specimen (LOCKED — match this register; English, warm tissue, lean, honest)

> A hundred thousand dinosaurs move through the park, and each is two things at once:
> an animal with a heartbeat and a position, and a row of data someone wants to count.
> Storing them isn't the hard part. The hard part is that the system counts the
> *expected* number and trusts it — so it can tell you when one is missing, and never
> when there is one too many. In InGen that gap is where the catastrophe lived. In Yon
> it is a thing the compiler refuses to let you build.

Opening line of the whole book (author, first person, alone) — LOCKED wording:
> *"I tried to engineer a Jurassic Park that works. I hope I did a better job than Hammond."*

## Canonical terms / notation (APPEND-ONLY — never rename once defined)

The Yon ontology, code-verified (see `00-jp-spec.md` §filesystem ontology):
- **world** — declared in `yon.toml` only: `[world.Name] objects=[…] spaces=[…]`.
  NOT a directory, NOT an inline keyword. (The park = `[world.Park]`.)
- **space** — a **directory** under the project root (`space_of`, `package_layout.ml`).
  A runtime heap where instances allocate. (A paddock = a directory.)
- **place** — a **file**: basename = place name; one place per file; the body uses
  the `place` keyword (`place Rex { … }`). (A dinosaur = `Rex.yon`.)
- **topos** — inline keyword `topos Name where { … }` in the conventional `Topos.yon`
  inside a space-dir. (Was `world` inline; v1.1 topos-per-space.)
- **the four arrows** — `move` / `view` / `reduction` / `operation`; place-as-object
  (arrows inside the place braces); Yoneda dispatch `recv.f(args) = f(recv, args)`.
- **content-addressing** — identity is content: FNV-1a + byte-compare; same content →
  same slot (dedup). ✓ (`test_unit_xheap_bounds.c`).
- **Space cell** — a *variable* assigned with `=` (`x = e`) is promoted to a Space
  cell: write `Space__set`, read `Space__get`, runtime `g_space_cells`. ✓
  (`kw_list_here.yon`; `audit:106`). `=` is the surface token; `becomes` is retired
  (internal AST node `SAssignBecomes` only). **NOT** `x.f = e` (place field =
  by-design reject, sections immutable) nor `new…in` (vestige).
- **bind vs assign** — `be x holds e` = immutable init; `x = e` = Space-cell assign.
- **verdict scheme** — ✓ verified (test/oracle/example named) · declared (design-true,
  no test) · debt (open, with pointer).

## Terms introduced & where
- **Ch 1.1**: substrate; `Carrier` (meaning kept apart from target); `holds` (init);
  the `f64 → i32 fptosi` exit-status narrowing; the substrate available-vs-spent
  distinction. Snippet gated ✓.
- **Ch 1.2** (drafted; CODE ✓ native-gated 2026-06-27 via `toolchain/yonc`: stdout 1,
  exit 0): **content-addressing** (identity is
  content; the address of a value IS its content); `HashSet` (`empty`/`add`/`size`,
  immutable); `Output.print(String.from_int(n))` with `main … visits Output` (the effect
  system, teased lightly, deferred); Leibniz's identity of indiscernibles. This is the FIRST half of identity
  (content = same thing); the location half (`Space` cell, same content yet two
  individuals) is deferred to its later Iteration. NOTE: this pulls content-addressing
  into Iteration 1; structure had it at Iteration 2 — confirm or move.
- **Ch 1.3 "One Fossil, Two Positions" — DRAFTED (location half of the fourth wall).**
  Code ✓ (the `probe_no_alias` trace `3 3 5 3`). Introduces: **Space cell = location**;
  `holds` = value/content (immutable) vs `=` = Space cell/location (mutable); the
  no-aliasing (clipboard/pen). Consolidates the verified probe + the `SpaceCellNoAlias`
  D3 viz + the manifesto (all on one page). Content half = 1.2; location half = this.
  Manuscript: `chapters/03-one-fossil-two-positions.md`; website:
  `docs/jp/iteration-1/03-one-fossil-two-positions.mdx` (embeds `<SpaceCellNoAlias/>` +
  the manifesto). NB placement: written as 1.3 (content+location read together) though the
  structure filed location under Iteration 3 — numbering is fluid, revisit at assembly.
- **Ch 2.1 "The Clones Are Real" — WRITTEN 2026-06-29 (the Leech lattice = 2nd engine).**
  Code ✓ (`uc_lattice` → `196560 12 1 2`). Introduces: the **Leech lattice** as a content-address
  by PLACE (geometry) vs 1.2's address by NAME (hash); **type-2 points** = the 196,560 minimal
  vectors = the **kissing number** in 24D (theorem, `test_leech_theta.ml`); **MPHF** = the minimal
  perfect hash, a bijection to `[0,196560)`, 0 collisions, **18-bit** address (`test_mphf.c`,
  `yon_rt.c:3077`); **12 M24 classes** (`XTower.width(2)`=12, `Leech.m24_orbit`∈0..11); **Co₀/M24**
  named as the lattice's symmetry (detail deferred); **`Leech.embed`** = placing a value at its
  nearest point; the 24 KB bitmap. Honest boundary: the address is exact & free, its MEANING is
  earned (deferred to 2.3). Yoneda seed: name & place "will not stay separate" (pays off Iter 7).
  Bridge to 2.2: the lattice is woven from the Golay code (the genome's armour next chapter).
  Website-only (mdx), no manuscript/chapters source (same as 2.3). `<LeechShells/>` reused.

## Recurring example — the park (current state)
- **World**: `[world.Park]` in `yon.toml`. **Paddocks** = directories (spaces),
  e.g. `tyrannosaur/`. **Dinosaurs** = files (places), e.g. `tyrannosaur/Rex.yon`.
  Paddock topos = `tyrannosaur/Topos.yon`.
- **Fourth wall (Iter 3)**: two identical genomes → ONE content slot (content-addressing,
  #2) but TWO Space cells (location, #3). Hammond counts locations believing he counts
  content. Both halves shown green.
- Names to keep stable once a chapter binds them (TBD at Ch 2-3 drafting).

## Open threads / foreshadowing
- **Content-addressing (Iter 2) → Yoneda (Iter 7)**: the reveal that top = bottom.
  Plant in 2.1, pay off in 7.2. Do NOT explain Yoneda early.
- **Ch 1.2 closer — DONE & verified (2026-06-27).** `mlir/passes/StructuralVN.cpp`:
  structural fingerprint (`name(operands-by-SSA-id)|attrs|result-types`) → per-block
  canonical table → replace+erase duplicates (hash-consing on the IR). "Pure" =
  MemoryEffectFree OR a whitelist the code itself comments as "Yon's content-addressed
  loaders, referentially transparent" (`hashset_size`, `merkle_equal`, `field_load`, …).
  In 1.2 it collapsed the duplicate `arith.constant 100247.0` (the genome literal written
  twice; the `hashset_add`s did NOT collapse — different set operands). Woven in as the
  1.2 closer: the principle at THREE levels — source (write 100247 twice) / SVN
  constant-fold / runtime HashSet dedup. "It goes all the way down."
- **Sample chapter (Ch 1.1)**: DRAFTED →
  `manuscript/chapters/01-1-the-unreadable-fragment.md` (voice/format specimen). Holds
  the book opening line + Prologue framing + First-Iteration epigraph + the 4-beat
  chapter. Snippet `Entry.yon` (`be substrate holds 0; return substrate`) is **✓ GATED
  on Mac (2026-06-26)**: `yoner_emit_mlir` exit 0, emitted `main` returns i32 0
  (`arith.constant 0.0 → fptosi → return`, confirming the chapter's silicon claim
  verbatim). Still awaiting author review of VOICE & FORMAT before it's canonical.
- **Fractal player**: extend an existing numeric+print example (`stream_for_every.yon`
  / `stdlib_showcase.yon` are candidates) — NOT a from-scratch `.yon`; gate the extension.
- **Debts to tell as open research** (never faked): #13 sheaf OPERATIONS path; #15
  morph via-signature stub; #8 ua surface E2E; #20 higher-order type_erase; #24/#25
  runtime E2E on Mac (env, Debt #6); Co₀/Monster link not code-exercised.
- **Meta-insight for the book (author)**: the Space ontology is the slipperiest part —
  surface names (`=`, `new…in`, `x.f`) and real mechanisms (`Space__get/set`,
  package/dir) don't map 1:1. Even careful reading stumbles here. That makes the
  identity-vs-location chapter the most *valuable*, not the most fragile.
- **No-aliasing VERIFIED (probe, 2026-06-27).** `be x holds 3; be y holds x; x = 5` prints
  `3 3 5 3` natively (`regression/book/jp/probe_no_alias/`): y stays 3 when x→5. The
  snapshot / no-alias semantics is now a MEASURED fact. This is the foundation of the
  rebind-vs-in-place argument: the semantics is immutable rebinding; the in-place cell
  mutation (`g_space_cells[id].value = new`) is a SOUND optimization because no name
  observes the cell (reads are snapshots). Same pattern as GHC/Rust/Clean uniqueness.
- **No address-of operator — VERIFIED (lexer, 2026-06-27).** No `ref`/`addr`/`deref`/
  `pointer`/`alias` token exists; `&` is bitwise-and only (`lexer.mll:288-311`);
  `Space__make`/`set`/`get` are internal desugar (NOT in `parser.mly`), so cell-ids never
  reach the surface. ⇒ a program cannot construct an alias to a cell ⇒ aliasing is
  IMPOSSIBLE by construction ⇒ in-place mutation is observably equivalent to rebinding.
  The book's strongest, grep-checkable claim: a hostile reader greps `&` and finds only
  bitwise-and. NB: no-aliasing is PROVEN (static, from the lexer), NOT emitted — never
  put a `link_state`/no-alias field in a "Yon trace"; the trace emits VALUES, the lexer
  proves the guarantee.
  - **The C comparison — CORRECTED framing (mandatory, author 2026-06-27).** Do NOT write
    "in C `y` could alias `x`": `int y = x;` COPIES in C, same as Yon. The real point:
    in C the copy-vs-alias choice is the programmer's burden and INVISIBLE at the use site
    (`y` alone doesn't say whether it's `int y` or `int *y`; in real code with typedefs /
    macros / pointers-in-structs you may not know). In Yon there is no cell-alias to
    construct (no syntax to bind a name to another's cell), so the question "copy or wire?"
    does not exist: it is always a copy, by construction. C: the question exists, answer
    hidden. Yon: the question is eliminated. (Hammond, in C, could be confused about WHICH
    clipboard he holds; in Yon he can't, but he can still trust a stale copy — that second
    error stays human.)
- **Manifesto saved: `manuscript/manifesto-where-the-philosophy-is-paid-for.md`** (author's
  prose, "the heart of the manifesto", for the final Iteration). Thesis: safety is a debt
  one layer pays for the layer below; Yon's philosophy is compile-time, the silicon carries
  the *result* (math evaporates at `type_erase`); the frontier is to contract the trusted
  surface toward "a fist of functions" verified in Yon. De-em-dashed; honesty footer marks
  verified-now vs frontier/aim. Self-hosting: check `regression/test_yon_selfhost.py` scope
  before claiming anything. ALSO rendered in the demo doc
  `website/docs/jp/iteration-1/zz-viz-clipboard-and-pen.mdx`, BELOW the no-aliasing viz (the
  viz is the instance: `g_space_cells` mutated in place honoring the immutable surface; the
  manifesto is the principle). Manuscript is source of truth; keep the two in sync.
- **First recorded visualization DESIGNED (rebind vs in-place), preview shown inline.**
  Honest split (locked rule for ALL recorded viz): the printed VALUES (3,3,5,3) are Yon's
  real output, replayed; the cells/wires/copy/mov animation is OUR illustration of *why*,
  clearly labeled, never presented as a Yon trace. Animates: x→cell (solid wire) vs y
  (a copy, NO wire); the `mov` on `x=5`; y motionless. To productionize for the Space-cell
  chapter: (a) trace `.yon` emitting per-step values via `Output.print`, (b) `stdout →
  trace.json` harness, (c) the React component in `website/src/components/` reading the JSON.
  **THREE synced lines (reusable pattern for any semantics/silicon contrast): semantics
  (what it means) / silicon (what it does) / why-it's-allowed (the keystone).** The "why"
  line is MANDATORY: the silicon line alone (`g_space_cells[id].value = 5`) is a half-truth
  that makes Yon look like C; the "why" (nothing observes the cell; no address-of operator,
  lexer-verified) is what keeps the pair honest. The grander the semantics and the humbler
  the silicon, the stronger the point — but only with the third line holding them together.
  All prose de-em-dashed per the style rule.

## Conventions
- **Prose style (LOCKED): NO em-dashes (—) anywhere.** Use commas, colons, periods,
  parentheses, or restructure. Author's rule (2026-06-26).
- **Reserved technical words stay technical.** Do NOT use `becomes` (the Space-cell
  mechanism, `SAssignBecomes`) as an ordinary prose verb; write "is taken as" / "serves
  as". Same discipline as not using `section`/`world`/`holds` loosely.
- **Name every cast at a type boundary.** A value does not silently "become" another type:
  e.g. `main`'s `f64` return is narrowed with `fptosi` to `i32`, which the OS reads as the
  exit status (`emit_mlir.ml:24`). Name the conversion; the hostile reader greps for it.
- **`holds` is initialization, not eternal immutability.** `be x holds e` binds; a later
  `x = e` is a separate act (promotion to a Space cell). Don't write "immutable, never
  overwritten" — it contradicts the Space-cell chapter.
- **Signature images are spent once.** A striking line lands once; reusing it across
  chapters reads as a tic. "the whole park is the distance between the two questions"
  stays in Ch 1.2 only (the 1.1 close now ends on "Hammond never saw the difference.").
- **Exit-code-as-result: prefer printing.** Returning a computed number as the exit
  status wraps at 256 and conflates result with status. Prefer `Output.print` (Ch 1.2:
  `main visits Output`, `Output.print(String.from_int(n))`, `return 0`; the answer goes
  to stdout, exit stays a clean 0). If you must use the exit code, name the convention.
  Simpler alt without the effect annotation: `IO.print_num(n)` (no `visits Output`).
- **Verdicts are written for the READER, not as an audit.** Point to the runnable
  project the reader can compile and check themselves; do NOT dump internal test
  filenames (those live in `construct-inventory.md`). "What can the reader verify?" >
  "here is our provenance." The honesty marking becomes the book's promise to the
  reader, not a list of our oracles.
- Yon code in ```yon, each snippet "pending Mac gate" until compiled by Antonio.
- Mainstream "disaster" code tagged by language, always labeled WHY that language.
- Book mini-projects live in `regression/book/jp/<chapter>/` (`yon.toml` + `Entry.yon`
  + space-dirs/place-files). **Every compilable snippet → a runnable project, never
  inline-only** (author's rule). Two commands:
  - **Compiles?** `cd frontend && dune build && ./_build/default/yoner_emit_mlir.exe <dir>; echo $?` (0 = emit ok). Enough when the answer is a constant in the MLIR.
  - **Native run (stdout + exit)?** `./toolchain/yonc <dir> -o /tmp/p && /tmp/p; echo "exit: $?"` (the end-to-end compiler). REQUIRED when the answer is computed at run time (printed or a non-constant exit code).
- Every "the compiler guarantees X" links the test that proves it.
- Docusaurus: `website/docs/jp/iteration-{1..7}/`, `CodeWindow` for snippets, KaTeX +
  Mermaid, players in `website/src/components/`, traces in `website/src/data/jp-traces/`.
  Additive only — do not touch existing docs/sidebars.

## Asset & component inventory
- **Site wiring**: JP section live at `website/docs/jp/` (autogenerated sidebar;
  `_category_.json` per Iteration). Ch 1.1 rendered at
  `website/docs/jp/iteration-1/01-the-unreadable-fragment.md` — **a copy**; source of
  truth is `manuscript/chapters/`, keep in sync (later: a sync step). Dev server:
  `cd website && npm run start`.
- **First recorded viz BUILT (production, 2026-06-27) — the no-aliasing "clipboard & pen":**
  - trace source: `regression/book/jp/probe_no_alias/` (verified native run prints 3 3 5 3);
  - harness: `website/scripts/build-jp-traces.py` (runs yonc, ASSERTS no-alias, writes JSON);
  - data: `website/src/data/jp-traces/space_cell_no_alias.json` (Yon's real output, restructured);
  - component: `website/src/components/SpaceCellNoAlias.js` (React + D3, reads the JSON);
  - demo doc: `website/docs/jp/iteration-1/zz-viz-clipboard-and-pen.mdx`;
  - `d3 ^7.9.0` added to `website/package.json` (needs `npm install`).
  UNTESTED in-sandbox (can't run Docusaurus here): author runs `cd website && npm install &&
  npm run start`, then polishes the visual. Regenerate trace: `python3 website/scripts/build-jp-traces.py`.
- **Ch 2.2 "The Genome, Retouched" — DRAFTED (Golay/VoyagerList error correction).** Scene:
  Wu's gap-filling ("Version 4.4", frog DNA). Idea: correction as STRUCTURE (decoding) vs
  InGen's stopgap (guessing). Code: `VoyagerList.empty/append/corrupt_at/get` (seal a gene,
  flip 2 bits, decode back to 1445) — verified pieces (`emit_mlir.ml:488-493`), Golay correct
  proven in `runtime/test_unit_voyagerlist.c`; **code ✓ NATIVE-GATED 2026-06-27**
  (`regression/book/jp/04_genome_golay/` via `yonc`: stdout 1445). SHORT LEASH stated: Yon does
  NOT repair DNA. Manuscript `chapters/04-the-genome-retouched.md`; website
  `docs/jp/iteration-2/02-the-genome-retouched.mdx` (+ iteration-2 `_category_.json`).
- **Compiler change LANDED & FULL-GATED (2026-06-27): exposed `VoyagerList.seal/open/corrupt`
  as surface builtins** (raw Golay codeword access, for the honest GENOME viz). Two sites:
  `frontend/stdlib_runtime.ml:631` (type registry: `seal [num]→num`, `open [num]→num`,
  `corrupt [num;num]→num`) + `frontend/emit_mlir.ml` (signature table, return-type, lowering
  to `yon_rt_voyagerlist_seal/open/corrupt`). `gate.sh` GREEN (782 passed, no regression).
  LESSON: a new surface builtin needs BOTH the tycheck registry (stdlib_runtime.ml) AND the
  emit (emit_mlir.ml); registering only emit gives "unknown function or operation" at typecheck.
  Trace source: `regression/book/jp/05_golay_codeword/` (native run prints `1445 13948082
  14014130 1445` — data, codeword, corrupted, recovered).
- **GENOME player (2nd recorded viz) — BUILT** (`website/src/components/GenomeGolay.js`, in 2.2):
  real trace (codeword 13948082, 2 real flips = cw XOR corrupted = bits 9 & 16, decode to 1445;
  author verified the XOR by hand). Fixes applied: bits grouped 3×8 + MSB/LSB orientation labels;
  decode shown as resolution-to-nearest-codeword (2 bits go GREEN "corrected", NOT reverted) per
  author ("undo is a lie, decoding is the lesson"); caption states the radius (corrects up to 3,
  ⌊(8−1)/2⌋=3, so 2 flips is CERTAIN). Do NOT generalize to "Golay always corrects": past 3 flips
  it decodes to the wrong word silently.
- **Ch 2.3 "Classifying the Animals" — DRAFTED (Leech lattice, closeness as intrinsic
  geometry).** Reframed from the structure's "distance" (the surface exposes orbit/canonical
  under Co₀, NOT a scalar distance): the thesis is "identity/classification up to the deepest
  symmetry, computed not invented." Demo: `Leech.syndrome(255)=0` (legal point) vs
  `syndrome(1)=1` (verified in `examples/stdlib_showcase.yon`); **code ✓ NATIVE-GATED
  2026-06-27** (`regression/book/jp/06_leech_syndrome/`, stdout `0 1`). 196,560 = a THEOREM
  in `test_leech_theta.ml` (kissing number + type2_count), MPHF bijection in `test_mphf.c`.
  Manuscript `chapters/05-classifying-the-animals.md`; website
  `docs/jp/iteration-2/03-classifying-the-animals.mdx`.
  **"What holds" REWRITTEN confident (2026-06-27)** — the first draft sounded like impostor
  syndrome (author: "sembri uno con la sindrome dell'impostore"). Lesson: the honesty boundary
  is stated ONCE, confidently (Yon re-derives the numbers; the Co₀/Monster group theory is
  Conway's, leaned on without apology, "the most symmetric structure there is"), NOT as
  hand-wringing. Grandeur, not anxiety.
  **Leech viz BUILT (3rd recorded viz): `website/src/components/LeechShells.js`** — the lattice
  SHELLS with their EXACT theta counts (196,560 · 16,773,120 · 398,034,000 · 4,629,381,120 ·
  34,417,656,000), theorems from `test_leech_theta.ml` (`website/src/data/jp-traces/leech_shells.json`),
  the counts exploding via a D3 number tween, kissing shell highlighted ("in 3D this is 12").
  Honest: the numbers are Yon-proven theorems (not a runtime trace, but real and re-derivable),
  the rings illustrate the shells. The fighissimo IS the number.
  **Dino-classification viz BUILT (4th recorded viz): `website/src/components/DinoLattice.js`**
  (2026-06-27). The piece the chapter TITLE promised: classifying the animals. Four genomes
  (`1536`, `1280`, `25167360 = xi(1536)`, `512 = co0_step(1536)`), all real type-2 points; their
  pairwise `XSimplex.of2` RELATION CLASSES (`1,11,7,1,1,7`) are runtime-emitted by
  `regression/book/jp/07_dino_lattice` (gated, `toolchain/yonc`). Viz = six pair-rows: Wu's
  tunable |Δgenome| cutoff (chosen ruler, groups regroup as you drag) vs the fixed `of2` class
  chip (computed, no knob). Spotlight B–C: Wu's ruler calls them maximally different (Δ≈25M),
  `of2` puts them in class 1 (same as A–B) — ruler and lattice disagree, the money shot, all real
  numbers. Genomes shipped as LITERALS (1536/1280/25167360/512) so the matrix is 100%
  reproducible; harness `dino_lattice()` asserts the genomes + the matrix (10 numbers).
  **THREE hard lessons this build (the gate doing its job):**
  (1) **of2 is a CATEGORICAL class, not an ordered distance.** Author caught me about to gate
  "same species → smaller class" — that treats a label as a distance = Wu's chosen ruler in
  disguise = the exact auto-goal the chapter critiques. The dense 0..11 index packs
  {0x00,0x2x,0x3x,0x4x} subtypes (`yon_rt.c:4720`), NOT monotone in distance. The chapter's jump
  is from *how much* (always an opinion) to *what kind* (a fact). Prose changed: "how close →
  a distance the space had" became "what kind of relation → a class the structure holds."
  (2) **The gate KILLED a beautiful false claim TWICE.** I'd pivoted to "the label moves, the
  relation doesn't" (Co0-invariance). First kill: the ξ-probe found `of2(C,D)=7` but
  `of2(ξC,ξD)=11` — of2 is Co2-invariant (code-certified, `yon_rt.c:4706`), NOT Co0. Second kill:
  on the harness re-run the ξ matrix CHANGED across builds (`[1,11,7,1,1,11]` → `[1,7,7,1,1,11]`),
  so `xi_apply`'s surface output is itself build-UNSTABLE (like m24_orbit). A non-reproducible
  number cannot be a shipped "Yon trace." Fix: genomes as LITERALS, of2 only (the pure mmgroup
  subtype IS canonical); the Co2-not-Co0 boundary lives in PROSE from the code comment, never as
  a number. NEVER ship a number you can't reproduce; NEVER write the pretty version before the
  gate confirms it.
  (3) **"orbit" is three non-interchangeable notions, and `m24_orbit`'s label is build-UNSTABLE**
  (`1536`→1, then 2, then 5 across builds). `Leech.m24_orbit` ≠ `Leech.same_orbit` ≠
  `Arena.same_orbit` (they disagreed on the SAME pair). of2 is the only stable, shippable thing;
  m24_orbit kept OFF the page. Re-confirms: verify EXHAUSTIVELY from live code, never assume a
  name means what a sibling name means.
- **The 48-taxon LEECH TAXONOMY EXPERIMENT — 3 surface exposures + 4 viz, ALL gated (2026-06-27).**
  A single lineage archosaur→gull (48 taxa, 6 bands, 12 illustrative cladistic bits each;
  `website/src/data/jp-traces/taxa.json` = the ONE swappable source). Three additive surface
  exposures, each with the 5/7-site pattern (registry + emit sig/typeof/lowering/decl + runtime),
  green build, no regression (gate.sh 799 passed):
  · **XTower** (`class`/`same_branch`/`width`/`depth`) — was runtime-only; unit oracle
    `frontend/test_xtower_surface.ml` (12 checks: registry+typecheck+lower) + functional gate
    `regression/book/jp/08_xtower_surface` (width 1/3/12/196560, depth 4, the same_branch partition).
  · **Leech.embed(bits, mode)** — NEW runtime `yon_rt_leech_embed_bits` (quantizer-backed), the
    vector→type-2 MAP. Mode-parameterized (0 duplicate / 1 golay / 2 sparse) so all candidate maps
    gate in one build (`regression/book/jp/probe_embed_maps`).
  · **XSimplex.triangle_fine** — frontend-only (runtime existed).
  **THE MAP IS THE EXPERIMENT (author's load-bearing point):** of2's 12 classes are Conway/mmgroup
  math (always true), of2 is deterministic+Co2 (always true), but what a class MEANS is entirely the
  input→lattice map. Today's map (content-address / our embed) makes the class reflect the
  REPRESENTATION, not biology. A biology→lattice-proximity map does not exist; this tests the
  MECHANISM. Probe verdict: **mode 0 (duplicate)** is the only map giving valid type-2 + a usable
  spread; `co0_canonical` FAILS (→ −1, not type-2); of2 does NOT track Hamming (categorical, not a
  ruler) — the author's thesis, gated.
  **WHAT THE EXPERIMENT ACTUALLY SHOWS (real Yon, `regression/book/jp/10_taxa_full` →
  `taxa_full.json`, harness asserts the partition):** the TREE works — modern birds + flighted
  maniraptorans (Microraptor 2559…Larus 4095, DIFFERENT vectors) all share ONE M24 family (the
  orbit does real work, not bit-equality), disjoint from the archosaurs; of2 50×50 shows BLOCKS +
  SATURATION (bird corner all class 0, shown not hidden); **omega IS Co0** (the ξ-demo: edges
  6,6,0 → −1,−1,0 MOVE, omega stays +1 — the absolute invariant of2 couldn't be, redeemed on the
  CYCLE not the edge); **level 1 is degenerate** (all one N-shape, shown not faked into "3 clades").
  Orbit labels build-unstable → the tree draws the PARTITION. 4 components, all reading taxa_full.json:
  `TaxaTree.js` (the CORE), `TaxaMatrix.js`, `OmegaInvariant.js` (the PUNCH), `TrianglePanel.js`;
  wired into `docs/jp/iteration-2/03-classifying-the-animals.mdx`. Generator
  `website/scripts/gen-taxa-trace.py` (taxa.json → the .yon), harness `taxa_full()` in
  build-jp-traces.py (captures 1246 ints, asserts birds-cluster + birds≠archosaurs + omega∈{−1,0,1}).
- Next viz: `FractalPlayer`, `PaddockMap`.

## Verified facts to use (author-checked, code-anchored)
- **Slot allocation is O(1) GUARANTEED** — `arena_alloc` (`runtime/xleech2_heap.c:268`) is a pure
  bump-pointer over the `mmap` strip: align size, bound-check, `off = arena_used`, `arena_used +=
  aligned`, return `off`. No free-slot search, no free-list, no probing. This is a DIFFERENT axis
  from the **content-dedup**, which is an expected-O(1) hash-lookup (`content_index`, linear
  probing) — search by *content*, not by *slot*. The exact, attackable-proof sentence: "Allocating
  a slot is O(1) guaranteed (mmap strip + bump-pointer, no search); the content-dedup above it is an
  expected-O(1) hash-lookup. Two axes: arena by position, index by content." Candidate for a future
  substrate/memory viz (author: "dopo dobbiamo rappresentare anche questo").
- **VoyagerList is a full list, two interfaces (keep distinct in the book).** LIST (surface):
  `empty` / `append` (auto-seals) / `get` (auto-opens, error-corrects up to 3 bits/element) / `size`
  / `corrupt_at` / `to_stream`. RAW Golay utilities (surface, the genome viz uses these):
  `seal` / `open` / `corrupt`. A reader uses `append`/`get` for the list (seal/open happen inside);
  `seal`/`open`/`corrupt` only to show the naked codeword. NB runtime has `to_list`; surface exposes
  `to_stream`.
- **Interleaver → v1.2, and it is a STORAGE MODE, not a list method.** Today VoyagerList is a list of
  INDEPENDENT codewords (≤3 errors corrected *per element*; protects scattered errors, up to 3N).
  The v1.2 interleaver is different: split a large datum and interleave its bits ACROSS the codewords,
  so a contiguous BURST spreads out (the real Voyager protection). So it is not a new method but a
  different way to lay data in (interleaved vs per-element) + a `get` that reassembles. Mark in
  `todo-1.2`: a sealing/layout strategy with its own viz and gate, distinct from the current list.

## Codebase changes made this session (book-adjacent, comment/doc only)
- `frontend/package_layout.ml` header comment cleaned (was "dir=world/file=space",
  now matches the live `space_of`/`place_of` code) — comment-only, no behavior change.
- `audit_language.md` Debt #8 (`becomes` surface token) marked CHIUSO; design note → Fatto.
