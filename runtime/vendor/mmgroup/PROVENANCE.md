# Vendored mmgroup C translation units

Generated C code from the mmgroup project, vendored so that the Yon
runtime is self-contained: no Python, no pip, no shared-library paths.

- Upstream: https://github.com/Martin-Seysen/mmgroup
- Commit: 5a1331a01c231818274b54e876b80aefdd2b3091 (2026-06-01)
- License: BSD-2-Clause, as declared by the upstream `setup.py`
  (`license='BSD-2-Clause'`); copyright Martin Seysen, 2020 (README).
  Full text in LICENSE in this directory.
- Generation: the upstream build's code generator
  (`pip install --no-build-isolation .` from the repository checkout,
  with `numpy<2` and `cython` in the environment; the published sdist
  is incomplete and its generator is incompatible with numpy 2, both
  verified on 2026-06-07).
- Files: the dependency CLOSURE of the FIFTEEN symbols the Yon runtime
  objects reference. Inventory computed by MEMBERSHIP, not by name
  pattern: every undefined symbol of every runtime object
  (yon_rt.o and all xleech2_*.o) that upstream defines. The symbols:
  mat24_syndrome, mat24_vect_to_gcode, mat24_gcode_to_vect,
  mat24_gcode_weight, gen_leech2_subtype, gen_leech2_type,
  gen_leech2_reduce_type2, gen_leech2_op_word,
  gen_leech2_op_word_leech2, gen_xi_op_xi, mm_group_invert_word,
  mm_aux_index_extern_to_sparse, mm_aux_index_sparse_to_extern,
  mm_aux_index_leech2_to_sparse, mm_aux_index_sparse_to_leech2.
  Closure: nine translation units; computed mechanically (compile each
  upstream TU, follow undefined symbols to their defining TU, iterate
  to fixpoint); external residue is libc only (memcmp, stack
  protector). Method note: a first pass filtered symbols by name
  pattern and missed four; membership in the upstream definition set
  is the correct criterion.
- Local modifications: NONE. The files are verbatim generated output.
  Do not edit them; to update, regenerate from upstream and re-run the
  closure.
