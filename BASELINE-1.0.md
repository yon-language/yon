# Yon 1.0 — official baseline

Crystallized: 2026-06-04.

Verified state at freeze time:
- Regression: 112 examples identical to the exit-code baseline + the
  cross-Space suite (ledger 209/exit 42; remote call in a loop, exit
  95), executed on fresh objects (make rc=0 checked before each run).
- Data path with NO silent heuristics: no ceilings on the structures
  (directories and capacities are dynamic; the load invariant α ≤ 0.7
  is always upheld), heap chain with global deduplication via a content
  index (O(1) per put), strings and Merkle DFS uncapped.
- Residual limits = SPECIFICATIONS: fixed pools with loud refusal
  (256 heaps/chain ≈ 18 GB of deduplicated content per process, 256
  instances per structure, 64 Spaces, 16 RPC2 sessions), IPC liveness
  timeouts with explicit failure (-1), internal buffers oversized
  relative to the wire (4 × f64 = 32 bytes).
- Benchmarks (Appendix D of the book): environment declared, lengths
  and sizes verified inside the benches themselves; equality flat at
  ~17 ns/comparison up to 32,768-char strings; HashMap ~397 ns/insert
  at 300k across two heaps; 1M entries exact across six heaps; xleech
  collisions: 60k distinct contents, 0 errors.

Release principle: Yon does not promise infinite runtime flexibility
paid for with unpredictability; it promises an honest, rigid algebraic
structure working at the speed of silicon. A hard limit that refuses
loudly is a safety specification, not a defect.
