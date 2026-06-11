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
#include <stdint.h>

typedef struct ds_arena ds_arena_t;

/* Create an empty arena (mmap-backed, kernel-zeroed = every slot unoccupied). */
ds_arena_t *yon_arena_create(void);
void        yon_arena_destroy(ds_arena_t *a);

/* Set the canonical repr (a heapref) for a type-2 point. Returns 1 on success,
 * 0 if `point` is not a type-2 vector. */
int yon_arena_put_repr(ds_arena_t *a, yon_xcoord_t point, uint32_t repr);

/* The canonical repr for a type-2 point, or YON_HEAPREF_INVALID if the slot is
 * empty or `point` is not type-2. */
uint32_t yon_arena_get_repr(const ds_arena_t *a, yon_xcoord_t point);

/* 1 if the type-2 point's slot is occupied, 0 otherwise (or non-type-2). */
int yon_arena_occupied(const ds_arena_t *a, yon_xcoord_t point);

#endif /* YON_ARENA_H */
