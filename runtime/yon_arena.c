/* yon_arena.c — the Leech type-2 arena. See yon_arena.h.
 * Brick 1: structure + canonical repr put/get, mmap-always, MPHF-indexed. */
#include "yon_arena.h"
#include "xleech2_mphf.h"   /* yon_mphf_index, YON_MPHF_INVALID */
#include "xleech2_heap.h"   /* YON_HEAPREF_INVALID */
#include "leech_theta.h"    /* YON_LEECH_TYPE2_COUNT */
#include "yon_mmap.h"       /* yon_map / yon_unmap */

#include <stddef.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

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

/* Pure M24 orbits over the type-2 shell. mmgroup gives Co_0 (transitive, one
 * orbit) and N_0 (the three shapes / subtypes), but no direct reduction under
 * M24 alone. The shell is small (196560), so we precompute the orbits once by
 * union-find under a fixed generating set of M24, then index by MPHF: an exact,
 * deterministic O(1) lookup. There are exactly 12 orbits (4 in shape (4^2 0^22),
 * 5 in (3 1^23), 3 in (2^8 0^16)); a proper subgroup would yield MORE than 12
 * (orbits only split under a smaller group), so reaching 12 certifies the set
 * generates all of M24. */
#define YON_ARENA_PURE_ORBITS 12u
/* A fixed generating set of M24 (m24num < MAT24_ORDER = 244823040), verified to
 * yield exactly the 12 pure orbits. */
static const uint32_t ARENA_M24_GENS[4] = { 1000003u, 50000063u, 150000001u, 200000017u };
static uint32_t *g_pure_orbit = NULL;   /* [196560] -> orbit id in [0,12), mmap-backed */

static uint32_t puf_find(uint32_t *p, uint32_t x) {
    while (p[x] != x) { p[x] = p[p[x]]; x = p[x]; }
    return x;
}

static void arena_build_pure_orbits(void) {
    extern uint32_t gen_leech2_op_atom(uint32_t q0, uint32_t g);
    if (g_pure_orbit) return;
    uint32_t N = YON_LEECH_TYPE2_COUNT;
    uint32_t *parent = (uint32_t *)yon_map((size_t)N * sizeof(uint32_t));
    for (uint32_t i = 0; i < N; i++) parent[i] = i;
    for (uint32_t idx = 0; idx < N; idx++) {
        uint32_t p = yon_mphf_unindex(idx);
        for (int k = 0; k < 4; k++) {
            uint32_t q = gen_leech2_op_atom(p, 0x20000000u | ARENA_M24_GENS[k]);  /* g_k . p */
            uint32_t j = yon_mphf_index(q);
            if (j == YON_MPHF_INVALID) continue;
            uint32_t a = puf_find(parent, idx), b = puf_find(parent, j);
            if (a != b) parent[a] = b;
        }
    }
    uint32_t *tab = (uint32_t *)yon_map((size_t)N * sizeof(uint32_t));
    uint32_t roots[YON_ARENA_PURE_ORBITS]; uint32_t nroots = 0;
    for (uint32_t i = 0; i < N; i++) {
        uint32_t r = puf_find(parent, i);
        uint32_t id = YON_ARENA_PURE_ORBITS;
        for (uint32_t k = 0; k < nroots; k++) if (roots[k] == r) { id = k; break; }
        if (id == YON_ARENA_PURE_ORBITS) {
            if (nroots >= YON_ARENA_PURE_ORBITS) {   /* generators drifted: refuse silent error */
                fprintf(stderr, "[yon_arena] pure-orbit drift: more than %u classes\n",
                        YON_ARENA_PURE_ORBITS);
                abort();
            }
            id = nroots; roots[nroots++] = r;
        }
        tab[i] = id;
    }
    yon_unmap(parent, (size_t)N * sizeof(uint32_t));
    g_pure_orbit = tab;   /* publish last: a reader sees either NULL or a complete table */
}

/* Pure M24 orbit id of a point, in [0, 12), or YON_ARENA_ORBIT_INVALID if the
 * point is not type-2. The table is built lazily on first use. */
static uint32_t arena_m24_orbit(yon_xcoord_t point) {
    uint32_t idx = yon_mphf_index(point);
    if (idx == YON_MPHF_INVALID) return YON_ARENA_ORBIT_INVALID;
    if (!g_pure_orbit) arena_build_pure_orbits();
    return g_pure_orbit[idx];
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
    return arena_m24_orbit(point);   /* pure orbit, or INVALID for non-type-2 (via MPHF) */
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
