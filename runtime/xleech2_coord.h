/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* xleech2_coord.h — Yon native NdCoord in XLeech2 encoding.
 *
 * REPLACES: ndcoord.h (24-int16 Leech vector)
 *
 * REPRESENTATION:
 *   A yon_xcoord_t is a uint32 with the mmgroup XLeech2 encoding:
 *     bit 0..11  = Golay cocode element (12 bits)
 *     bit 12..23 = Parker loop / Golay code element (12 bits)
 *     bit 24     = sign bit (0 = positive, 1 = negative)
 *     bit 25..31 = unused (0)
 *
 *   Total space: 2^25 = 33M distinct values
 *   Type-2 vectors: 196,560 (~0.6% of the total, sparse in the range)
 *
 *   The corresponding 24-D Leech vector (explicit form) is recovered via
 *   yon_xcoord_to_int24(), which calls mmgroup for the decoding.
 *
 * INVARIANTS:
 *   - Canonical encoding: each Leech vector has exactly one yon_xcoord_t
 *     (verified empirically via the birthday paradox)
 *   - v.value and (-v).value differ only in bit 24
 *   - type() in {0, 2, 3, 4} is a property of the encoding
 *
 * SOURCE: mmgroup (Martin Seysen, MIT license), arxiv 2002.10921
 */

#ifndef YON_XLEECH2_COORD_H
#define YON_XLEECH2_COORD_H

#include <stdint.h>
#include <stdbool.h>

/* Native type: 32-bit unsigned with XLeech2 encoding. */
typedef uint32_t yon_xcoord_t;

/* Constants */
#define YON_XCOORD_INVALID         ((yon_xcoord_t)0xFFFFFFFFu)
#define YON_XCOORD_SIGN_BIT        (1u << 24)
#define YON_XCOORD_ATOM_MASK       0x00FFFFFFu   /* bit 0..23 */
#define YON_XCOORD_VALID_MASK      0x01FFFFFFu   /* bit 0..24 */

/* Total number of type-2 short vectors in Lambda/2Lambda x {+-1} */
#define YON_TYPE2_COUNT            196560u

/* Canonical type-2 vector (the output of reduce). Verified empirically: 0x200. */
#define YON_XCOORD_CANONICAL_TYPE2 ((yon_xcoord_t)0x200u)

/* ============================================================== */
/* Type checking — a wrapper over gen_leech2_type from libmmgroup_mat24 */
/* ============================================================== */

/* Returns the type in {0, 2, 3, 4} of the corresponding Leech vector.
 * For invalid encodings (bit 25+ set), returns -1. */
int yon_xcoord_type(yon_xcoord_t v);

/* True if v is type-2 (a short vector). */
bool yon_xcoord_is_type2(yon_xcoord_t v);

/* ============================================================== */
/* Basic operations                                                */
/* ============================================================== */

/* Negation: flips the sign bit. */
static inline yon_xcoord_t yon_xcoord_negate(yon_xcoord_t v) {
    return v ^ YON_XCOORD_SIGN_BIT;
}

/* Comparison including the sign. v == w iff same coord AND same sign. */
static inline bool yon_xcoord_equal(yon_xcoord_t v, yon_xcoord_t w) {
    return (v & YON_XCOORD_VALID_MASK) == (w & YON_XCOORD_VALID_MASK);
}

/* "unsigned" comparison (ignores the sign). */
static inline bool yon_xcoord_equal_unsigned(yon_xcoord_t v, yon_xcoord_t w) {
    return (v & YON_XCOORD_ATOM_MASK) == (w & YON_XCOORD_ATOM_MASK);
}

/* Sign of the vector: +1 or -1. */
static inline int yon_xcoord_sign(yon_xcoord_t v) {
    return (v & YON_XCOORD_SIGN_BIT) ? -1 : +1;
}

/* ============================================================== */
/* Human-readable decoding (debug/export)                          */
/* ============================================================== */

/* Decode a yon_xcoord_t to an explicit 24-D int16 vector (Leech coord).
 *
 * Note: this is an expensive operation (~us per call via libmmgroup). Use it
 * only for debug/display/export, not in a hot path.
 *
 * Returns 0 if ok, -1 if v is not a valid short vector.
 *
 * Implemented via mmgroup's short-vector encoding (see xleech2_coord.c): the
 * box identifies the shape (4^2 / 2^8 / 3.1^23) and the code carries positions
 * and signs with the theta correction already applied. Coordinates are in
 * {-4..4}; the Leech inner product is (sum a[i]*b[i]) / 8.
 */
int yon_xcoord_to_int24(yon_xcoord_t v, int16_t out[24]);

/* Real Leech inner product <v,w> in {0,+-1,+-2,+-4}, or 0x7fffffff if either
 * vector is not a decodable type-2. The per-edge sign is gauge (not
 * Co0-invariant alone); combine three edges into a holonomy for invariance. */
int yon_leech2_signed_product(yon_xcoord_t v, yon_xcoord_t w);

/* Closest type-2 quantizer: map an arbitrary q in R^24 to the nearest minimal
 * (norm-4) Leech vector, i.e. the type-2 maximising <q,v>. Exact and O(1)
 * (no scan of the 196560 shell). Deterministic on every Voronoi boundary: at
 * equal score the type-2 of minimum MPHF index wins, across shapes and across
 * the full sign orbit on spent (q_k = 0) coordinates. Returns its xcoord, or
 * YON_XCOORD_INVALID if no candidate could be reconstructed. */
yon_xcoord_t yon_leech2_quantize(const double q[24]);

#endif /* YON_XLEECH2_COORD_H */
