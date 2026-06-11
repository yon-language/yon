/* yon_arena.c — the Leech type-2 arena. See yon_arena.h.
 * Brick 1: structure + canonical repr put/get, mmap-always, MPHF-indexed. */
#include "yon_arena.h"
#include "xleech2_mphf.h"   /* yon_mphf_index, YON_MPHF_INVALID */
#include "xleech2_heap.h"   /* YON_HEAPREF_INVALID */
#include "leech_theta.h"    /* YON_LEECH_TYPE2_COUNT */
#include "yon_mmap.h"       /* yon_map / yon_unmap */

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

/* M24/Co_0 orbit invariant of a type-2 point: gen_leech2_subtype, the genuine
 * equivariant invariant on leech2 vectors. Over the type-2 shell it takes three
 * values (0x20, 0x21, 0x22) — the three shapes (4^2 0^22), (3 1^23), (2^8 0^16).
 * (An earlier version applied mat24_syndrome to the low 24 bits; that treats the
 * leech2 encoding as raw coordinates and is NOT M24-equivariant — verified to
 * break under gen_leech2_op_atom — so it is not an orbit invariant. Replaced.) */
static uint32_t arena_m24_orbit(yon_xcoord_t point) {
    extern uint32_t gen_leech2_subtype(uint64_t v2);
    return gen_leech2_subtype((uint64_t)point);
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

uint32_t yon_arena_orbit_of(yon_xcoord_t point) {
    extern int32_t gen_leech2_reduce_type2(uint32_t, uint32_t *);
    uint32_t g[32];
    if (gen_leech2_reduce_type2((uint32_t)point & 0xFFFFFFu, g) < 0)
        return YON_ARENA_ORBIT_INVALID;
    return arena_m24_orbit(point);
}

int yon_arena_same_orbit_exact(yon_xcoord_t p, yon_xcoord_t q,
                               uint32_t *sigma_word_out, uint32_t *sigma_len_out) {
    /* mmgroup primitives, declared as the runtime's transport does (no yon_rt dep) */
    extern int32_t  gen_leech2_reduce_type2(uint32_t, uint32_t *);
    extern uint32_t mm_group_mul_words(uint32_t *, uint32_t, uint32_t *, uint32_t, int32_t);

    uint32_t vp = (uint32_t)p & 0xFFFFFFu;
    uint32_t vq = (uint32_t)q & 0xFFFFFFu;
    uint32_t gp[32], gq[32];
    int32_t lp = gen_leech2_reduce_type2(vp, gp);
    int32_t lq = gen_leech2_reduce_type2(vq, gq);
    if (lp < 0 || lq < 0) return 0;          /* not type-2: no orbit */

    /* layer 1 (the judge): different M24 invariant => different orbit, exact */
    if (arena_m24_orbit(p) != arena_m24_orbit(q)) return 0;

    /* layer 2 (the certificate): sigma = g_p * g_q^{-1} carries p to q */
    if (sigma_word_out && sigma_len_out) {
        uint32_t sigma[YON_ARENA_SIGMA_MAX];
        uint32_t ls = mm_group_mul_words(sigma, 0, gp, (uint32_t)lp, 1);
        ls = mm_group_mul_words(sigma, ls, gq, (uint32_t)lq, -1);
        if (ls > YON_ARENA_SIGMA_MAX) ls = YON_ARENA_SIGMA_MAX;
        for (uint32_t i = 0; i < ls; i++) sigma_word_out[i] = sigma[i];
        *sigma_len_out = ls;
    }
    return 1;
}
