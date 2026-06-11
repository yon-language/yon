/* yon_arena.c — the Leech type-2 arena. See yon_arena.h.
 * Brick 1: structure + canonical repr put/get, mmap-always, MPHF-indexed. */
#include "yon_arena.h"
#include "xleech2_mphf.h"   /* yon_mphf_index, YON_MPHF_INVALID */
#include "xleech2_heap.h"   /* YON_HEAPREF_INVALID */
#include "leech_theta.h"    /* YON_LEECH_TYPE2_COUNT */
#include "yon_mmap.h"       /* yon_map / yon_unmap */

#include <stddef.h>

/* One slot per type-2 lattice position. The form is final (road 3): the
 * canonical repr, the head of the sigma-certified fusion list, and occupancy.
 * Fusions are populated by a later brick; here fusions_head is set INVALID. */
typedef struct {
    uint32_t repr;          /* heapref of the canonical value (valid iff occupied) */
    uint32_t fusions_head;  /* heapref of the fusion-list head, or INVALID */
    uint8_t  occupied;
} arena_slot_t;

struct ds_arena {
    arena_slot_t slots[YON_LEECH_TYPE2_COUNT];
};

/* The arena spans exactly the type-2 shell; the count is the theorem, guarded. */
_Static_assert(sizeof(((struct ds_arena *)0)->slots) / sizeof(arena_slot_t)
                   == YON_LEECH_TYPE2_COUNT,
    "arena must hold exactly the type-2 vectors (theta_coeff 2 = 196560)");

ds_arena_t *yon_arena_create(void) {
    /* mmap-always: a private anonymous map, kernel-zeroed, so every slot starts
     * unoccupied (occupied == 0) at no cost. yon_map aborts on failure. */
    return (ds_arena_t *)yon_map(sizeof(struct ds_arena));
}

void yon_arena_destroy(ds_arena_t *a) {
    yon_unmap(a, sizeof(struct ds_arena));
}

int yon_arena_put_repr(ds_arena_t *a, yon_xcoord_t point, uint32_t repr) {
    uint32_t idx = yon_mphf_index(point);
    if (idx == YON_MPHF_INVALID) return 0;
    arena_slot_t *s = &a->slots[idx];
    s->repr = repr;
    s->fusions_head = YON_HEAPREF_INVALID;
    s->occupied = 1;
    return 1;
}

uint32_t yon_arena_get_repr(const ds_arena_t *a, yon_xcoord_t point) {
    uint32_t idx = yon_mphf_index(point);
    if (idx == YON_MPHF_INVALID) return YON_HEAPREF_INVALID;
    const arena_slot_t *s = &a->slots[idx];
    if (!s->occupied) return YON_HEAPREF_INVALID;
    return s->repr;
}

int yon_arena_occupied(const ds_arena_t *a, yon_xcoord_t point) {
    uint32_t idx = yon_mphf_index(point);
    if (idx == YON_MPHF_INVALID) return 0;
    return a->slots[idx].occupied ? 1 : 0;
}
