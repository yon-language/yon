/* yon_arena.c — the Leech type-2 arena. See yon_arena.h.
 * Brick 1: structure + canonical repr put/get, mmap-always, MPHF-indexed. */
#include "yon_arena.h"
#include "xleech2_mphf.h"   /* yon_mphf_index, YON_MPHF_INVALID */
#include "xleech2_heap.h"   /* YON_HEAPREF_INVALID */
#include "leech_theta.h"    /* YON_LEECH_TYPE2_COUNT */
#include "yon_mmap.h"       /* yon_map / yon_unmap */
#include "mat24_functions.h"  /* mat24_syndrome, for the M24 orbit invariant */

#include <stddef.h>
#include <string.h>

/* One slot per type-2 lattice position. The form is final (road 3): the
 * canonical repr, the head of the sigma-certified fusion list, and occupancy.
 * Fusions are populated by a later brick; here fusions_head is set INVALID. */
typedef struct {
    uint32_t repr;          /* heapref of the canonical value (valid iff occupied) */
    uint32_t fusions_head;  /* heapref of the fusion-list head, or INVALID */
    uint32_t orbit;         /* M24 orbit invariant, sealed at put_repr */
    uint8_t  occupied;
} arena_slot_t;

/* A fusion node, immutable, living in the heap: a fused value, the sigma in Co_0
 * (a transport id, the Curtis witness) that carries it onto the canonical repr,
 * and the heapref of the next node. Built by put_fusion, never mutated. */
typedef struct {
    uint32_t value;
    uint32_t sigma;
    uint32_t next;   /* heapref of the next node, or YON_HEAPREF_INVALID */
} arena_fusion_node_t;

struct ds_arena {
    yon_xheap_t *heap;   /* canonical values and fusion nodes live here */
    arena_slot_t slots[YON_LEECH_TYPE2_COUNT];
};

/* The arena spans exactly the type-2 shell; the count is the theorem, guarded. */
_Static_assert(sizeof(((struct ds_arena *)0)->slots) / sizeof(arena_slot_t)
                   == YON_LEECH_TYPE2_COUNT,
    "arena must hold exactly the type-2 vectors (theta_coeff 2 = 196560)");

/* M24 orbit invariant of a type-2 point: (codeword_weight << 8) | syndrome_weight,
 * via mat24_syndrome. Constant on each M24 orbit; the same computation the
 * runtime's yon_rt_leech_m24_orbit performs, without the heap-id indirection. */
static uint32_t arena_m24_orbit(yon_xcoord_t point) {
    uint32_t v    = ((uint32_t)point) & 0xFFFFFFu;
    uint32_t synd = mat24_syndrome(v, 0);
    uint32_t gpart = v ^ synd;
    uint32_t w_g = (uint32_t)__builtin_popcount(gpart);
    uint32_t w_c = (uint32_t)__builtin_popcount(synd);
    return (w_g << 8) | w_c;
}

ds_arena_t *yon_arena_create(yon_xheap_t *heap) {
    /* mmap-always: a private anonymous map, kernel-zeroed, so every slot starts
     * unoccupied (occupied == 0) at no cost. yon_map aborts on failure. */
    ds_arena_t *a = (ds_arena_t *)yon_map(sizeof(struct ds_arena));
    a->heap = heap;
    return a;
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
    s->orbit = arena_m24_orbit(point);   /* sealed at allocation, never recomputed */
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

int yon_arena_put_fusion(ds_arena_t *a, yon_xcoord_t point,
                         uint32_t value, uint32_t sigma) {
    uint32_t idx = yon_mphf_index(point);
    if (idx == YON_MPHF_INVALID) return 0;
    arena_slot_t *s = &a->slots[idx];
    if (!s->occupied) return 0;   /* a fusion needs a canonical repr first */

    /* The new node points at the current head, so the list grows LIFO and next
     * always references an older node: no cycles by construction. */
    arena_fusion_node_t node;
    node.value = value;
    node.sigma = sigma;
    node.next  = s->fusions_head;
    uint32_t href = yon_xheap_put_chain(a->heap, &node, sizeof(node),
                                        YON_TAG_USER1);
    if (href == YON_HEAPREF_INVALID) return 0;
    s->fusions_head = href;
    return 1;
}

long yon_arena_fusions(const ds_arena_t *a, yon_xcoord_t point,
                       yon_arena_fusion_fn visit, void *ctx) {
    uint32_t idx = yon_mphf_index(point);
    if (idx == YON_MPHF_INVALID) return 0;
    const arena_slot_t *s = &a->slots[idx];
    if (!s->occupied) return 0;

    long count = 0;
    uint32_t cur = s->fusions_head;
    while (cur != YON_HEAPREF_INVALID) {
        const void *p = yon_xheap_payload_chain(cur);
        if (!p) break;   /* defensive: a broken ref ends the walk */
        arena_fusion_node_t node;
        memcpy(&node, p, sizeof(node));
        if (visit) visit(node.value, node.sigma, ctx);
        count++;
        cur = node.next;
    }
    return count;
}

uint32_t yon_arena_orbit(const ds_arena_t *a, yon_xcoord_t point) {
    uint32_t idx = yon_mphf_index(point);
    if (idx == YON_MPHF_INVALID) return YON_ARENA_ORBIT_INVALID;
    const arena_slot_t *s = &a->slots[idx];
    if (s->occupied) return s->orbit;        /* sealed at allocation, O(1) */
    return arena_m24_orbit(point);           /* not yet allocated: compute */
}
