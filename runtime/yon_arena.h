/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* yon_arena.h — the Leech type-2 arena (road 3).
 *
 * An index from each of the 196560 type-2 lattice points to the canonical value
 * living in the content-addressed heap, plus, per occupied point, a persistent
 * list of fusions: a fused value together with the sigma in Co_0 that carries it
 * onto the canonical repr (the Curtis witness, already in the runtime).
 *
 * Capacity is exactly the kissing number, theta_coeff(2) = YON_LEECH_TYPE2_COUNT,
 * a theorem verified by frontend/test_leech_theta.ml and guarded at compile time.
 * Indexing is the verified MPHF bijection, so two distinct type-2 points never
 * collide: zero collisions by construction, not by probability. Allocation is
 * mmap-always (yon_map). Values are never stored here, only their heaprefs: the
 * arena is the index over lattice positions, the heap is the content store.
 *
 * This header is the first brick: structure + canonical repr put/get. The
 * sigma-certified fusion list and the M24-orbit layout follow as next steps. */
#ifndef YON_ARENA_H
#define YON_ARENA_H

#include "xleech2_coord.h"
#include "xleech2_heap.h"   /* yon_xheap_t, YON_HEAPREF_INVALID */
#include <stdint.h>

typedef struct ds_arena ds_arena_t;

/* Create an empty arena over `heap` (mmap-backed, kernel-zeroed = every slot
 * unoccupied). The heap is where canonical values and fusion nodes live; the
 * arena only indexes them by lattice position. */
ds_arena_t *yon_arena_create(yon_xheap_t *heap);
void        yon_arena_destroy(ds_arena_t *a);

/* Set the canonical repr (a heapref) for a type-2 point. Returns 1 on success,
 * 0 if `point` is not a type-2 vector. */
int yon_arena_put_repr(ds_arena_t *a, yon_xcoord_t point, uint32_t repr);

/* The canonical repr for a type-2 point, or YON_HEAPREF_INVALID if the slot is
 * empty or `point` is not type-2. */
uint32_t yon_arena_get_repr(const ds_arena_t *a, yon_xcoord_t point);

/* 1 if the type-2 point's slot is occupied, 0 otherwise (or non-type-2). */
int yon_arena_occupied(const ds_arena_t *a, yon_xcoord_t point);

/* Record a fusion at `point`: a value (heapref) fused onto the slot's canonical
 * repr, carried by `sigma` (a transport id — the Curtis witness in Co_0). The
 * slot must already be occupied (have a repr). Allocates an immutable fusion
 * node {value, sigma, next} in the heap (content-addressed, so shared tails are
 * deduplicated) and pushes it onto the slot's list. Returns 1 on success, 0 if
 * `point` is not type-2, the slot is empty, or the heap allocation fails. */
int yon_arena_put_fusion(ds_arena_t *a, yon_xcoord_t point,
                         uint32_t value, uint32_t sigma);

/* Visitor over a slot's fusions, most-recent first. */
typedef void (*yon_arena_fusion_fn)(uint32_t value, uint32_t sigma, void *ctx);

/* Walk the fusion list at `point`, calling `visit` for each fusion (LIFO order).
 * Returns the number of fusions visited (0 if empty or non-type-2). */
long yon_arena_fusions(const ds_arena_t *a, yon_xcoord_t point,
                       yon_arena_fusion_fn visit, void *ctx);

/* Sentinel orbit for a non-type-2 point. */
#define YON_ARENA_ORBIT_INVALID 0xFFFFFFFFu

/* The orbit of a point. Sealed at allocation: for an occupied slot it is a
 * stored field (O(1), no recomputation — the orbit belongs to the value because
 * of where it was allocated). For an unoccupied type-2 point it is looked up; for
 * a non-type-2 point it is YON_ARENA_ORBIT_INVALID. The value is the pure M24
 * orbit id in [0, 12): the exact orbit of the point under the Mathieu group M24,
 * precomputed once over the type-2 shell. */
uint32_t yon_arena_orbit(const ds_arena_t *a, yon_xcoord_t point);

/* The pure M24 orbit id of a point ([0,12)), independent of any arena state, or
 * YON_ARENA_ORBIT_INVALID otherwise. */
uint32_t yon_arena_orbit_of(yon_xcoord_t point);

/* Maximum length (in atoms) of an emitted sigma certificate word. */
#define YON_ARENA_SIGMA_MAX 64u

/* Decide whether two type-2 points lie in the same pure M24 orbit, and optionally
 * emit a sigma certificate. Returns 1 if same orbit, 0 otherwise (including if
 * either point is not type-2).
 *
 * Layer 1 — the judge: the pure M24 orbit id (precomputed, exact). Equal id iff
 * the points are carried onto each other by some g in M24.
 * Layer 2 — the certificate: when sigma_word_out and sigma_len_out are non-NULL
 * and the points pass layer 1, the transport's sigma (a group word carrying p to
 * q) is written out, up to YON_ARENA_SIGMA_MAX atoms.
 *
 * HONEST NOTE: the decision is exact (it reads the precomputed M24 orbit table).
 * The sigma the transport returns is a Co_0 witness (Co_0 is transitive on the
 * type-2 vectors), not a word restricted to M24; it certifies Co_0-equivalence,
 * which always holds, so the orbit decision rests on the table, not on sigma. */
int yon_arena_same_orbit_exact(yon_xcoord_t p, yon_xcoord_t q,
                               uint32_t *sigma_word_out, uint32_t *sigma_len_out);

#endif /* YON_ARENA_H */
