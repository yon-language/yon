/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
#ifndef YON_CURTIS_FRAME_H
#define YON_CURTIS_FRAME_H

#include <stdint.h>

/* Curtis frame: type-2 octad vectors (subtype 0x22, shape 2^8 0^16) in
 * XLeech2 coordinates, used as the canonical reference frame for XRel.
 *
 * Derivation (deterministic, reproducible, see tools/gen_curtis_frame.c):
 *   seed  = mat24_octad_to_gcode(0) << 12
 *           (standard MOG octad, points {0,1,2,3,8,9,10,11} = two columns
 *            of the 4x6 MOG grid)
 *   orbit = breadth-first search under the 4 M24 generators applied as
 *           group atoms:
 *             gen_leech2_op_atom(v, 0x20000000u | g),
 *             g in {1000003, 50000063, 150000001, 200000017}
 *           keeping only subtype-0x22 vectors, in BFS discovery order,
 *           capped at YON_XREL_MAX_REFS (26).
 *
 * Every entry is verified subtype 0x22 and MPHF-indexable.
 *
 * As a frame these octads are M24-independent (unlike consecutive octads,
 * which share MOG columns and are redundant). Stratification of the 196560
 * type-2 points into XRel classes:
 *     k=16 -> 82835    k=23 -> 98258
 * versus 766 for the first 16 consecutive octads and 75064 for 16 random
 * type-2 references.
 *
 * This is a LATTICE CONSTANT, not per-Space state. It is identical in every
 * process-Space by construction (shared rodata of the same binary). The
 * cross-Space Wire requires this identity: XRel classes are only comparable
 * across Spaces if the frame is bit-for-bit the same everywhere.
 */

#define YON_CURTIS_FRAME_N 26u

static const uint32_t YON_CURTIS_FRAME[YON_CURTIS_FRAME_N] = {
    0x801000u, 0xb481bfu, 0x735629u, 0x60f4dbu,
    0x300326u, 0x1a49532u, 0x80f480u, 0x17fe657u,
    0x1c7c2a9u, 0x526115u, 0xb38122u, 0xc530e9u,
    0x16c70bcu, 0x5f85c3u, 0x102a03cu, 0xc3e255u,
    0x16d26ffu, 0x4f2667u, 0x0402b4u, 0x170a28cu,
    0x1b22794u, 0xcd0001u, 0x07b1b7u, 0x198f1ffu,
    0x7af67eu, 0x1b843adu,
};

#endif /* YON_CURTIS_FRAME_H */
