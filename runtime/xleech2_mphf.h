/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* xleech2_mphf.h — Minimal Perfect Hash Function xcoord <-> idx.
 *
 * BACKING: libmmgroup_mm_op.so (Martin Seysen, MIT license)
 *   - mm_aux_index_leech2_to_sparse
 *   - mm_aux_index_sparse_to_extern
 *   - mm_aux_index_extern_to_sparse
 *   - mm_aux_index_sparse_to_leech2
 *
 * BIJECTION:
 *   h : {xcoord type-2 in XLeech2} -> [0, 196560)
 *
 *   forward:  yon_mphf_index(v)
 *     - mm_aux_index_leech2_to_sparse(v)  -> sparse (loses the sign)
 *     - mm_aux_index_sparse_to_extern(sparse) -> extern in [300, 98579]
 *     - idx = 2 * (extern - 300) + sign(v)
 *
 *   backward: yon_mphf_unindex(idx)
 *     - extern = (idx >> 1) + 300
 *     - sign = idx & 1
 *     - mm_aux_index_extern_to_sparse(extern) -> sparse
 *     - mm_aux_index_sparse_to_leech2(sparse) -> v_unsigned
 *     - v = v_unsigned | (sign ? 0x1000000 : 0)
 *
 * COSTS:
 *   - Our own tables: 0 bytes
 *   - mmgroup tables: already loaded (reused by the Co0 machinery)
 *   - Operations per query: 2 C calls + 2-3 bit ops
 *   - strictly O(1)
 *
 * VERIFIED EMPIRICALLY:
 *   - Perfect bijection over all 196,560 type-2 vectors (test_mphf.c)
 *   - Output range exactly [0, 196559]
 *   - Round-trip identity at 100%
 */

#ifndef YON_XLEECH2_MPHF_H
#define YON_XLEECH2_MPHF_H

#include "xleech2_coord.h"
#include <stdint.h>

/* Sentinel for a non-type-2 xcoord or invalid input */
#define YON_MPHF_INVALID UINT32_MAX

/* Forward: xcoord type-2 -> idx in [0, 196560).
 *
 * Returns YON_MPHF_INVALID if v is not a valid type-2 vector. */
uint32_t yon_mphf_index(yon_xcoord_t v);

/* Backward: idx in [0, 196560) -> xcoord type-2.
 *
 * Returns YON_XCOORD_INVALID if idx is out of range. */
yon_xcoord_t yon_mphf_unindex(uint32_t idx);

#endif /* YON_XLEECH2_MPHF_H */
