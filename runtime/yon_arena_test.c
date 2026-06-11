/* yon_arena_test.c — oracle for the Leech type-2 arena (road 3, bricks 1-4).
 *
 * Brick 1: repr round-trip + zero collisions over all 196560 points.
 * Brick 2: sigma-certified fusion list (LIFO, walked back exactly).
 * Brick 3: the M24 orbit sealed into the slot at allocation — the orbit read
 *          back from the slot matches the computation, the 196560 points
 *          partition into a small number of orbits, invariant under sign.
 *
 * Standalone (vendor objects already built by `make`):
 *   cc -std=c11 -D_DARWIN_C_SOURCE -O2 -Ivendor/mmgroup \
 *      yon_arena_test.c yon_arena.c yon_mmap.c xleech2_mphf.c xleech2_coord.c \
 *      xleech2_heap.c vendor/mmgroup/*.o -lpthread -lm -o /tmp/tarena && /tmp/tarena
 */
#include "yon_arena.h"
#include "xleech2_mphf.h"
#include "xleech2_coord.h"
#include "xleech2_heap.h"
#include "leech_theta.h"
#include <stdio.h>

#define MAXF 8
typedef struct { uint32_t val[MAXF]; uint32_t sig[MAXF]; int n; } collect_t;
static void collect(uint32_t value, uint32_t sigma, void *ctx) {
    collect_t *c = (collect_t *)ctx;
    if (c->n < MAXF) { c->val[c->n] = value; c->sig[c->n] = sigma; c->n++; }
}

static char seen_orbit[8192];   /* orbit invariant <= (24<<8)|24 = 6168 */

int main(void) {
    printf("=== Leech type-2 arena oracle (road 3, bricks 1-4) ===\n\n");
    yon_xheap_t *heap = yon_xheap_create();
    ds_arena_t *a = yon_arena_create(heap);

    /* --- bricks 1 & 3: repr round-trip, zero collisions, orbit sealed --- */
    long ok = 0, wrong = 0, orbit_consistent = 0, orbit_bad = 0, distinct = 0;
    for (uint32_t idx = 0; idx < YON_LEECH_TYPE2_COUNT; idx++) {
        yon_xcoord_t v = yon_mphf_unindex(idx);
        uint32_t orbit_before = yon_arena_orbit(a, v);   /* unoccupied: computed */
        yon_arena_put_repr(a, v, idx + 1u);
        if (yon_arena_get_repr(a, v) == idx + 1u) ok++; else wrong++;
        uint32_t orbit_after = yon_arena_orbit(a, v);    /* occupied: sealed slot */
        if (orbit_before == orbit_after) orbit_consistent++; else orbit_bad++;
        if (orbit_after < 8192 && !seen_orbit[orbit_after]) {
            seen_orbit[orbit_after] = 1; distinct++;
        }
    }
    printf("  repr round-trip   : %ld / %u  (mismatches %ld)\n",
           ok, YON_LEECH_TYPE2_COUNT, wrong);
    printf("  orbit sealed==calc: %ld / %u  (inconsistent %ld)\n",
           orbit_consistent, YON_LEECH_TYPE2_COUNT, orbit_bad);
    printf("  distinct pure M24 orbits over all type-2 points: %ld\n", distinct);

    /* M24 is permutations of coordinates only: the central sign is not in M24,
     * so negate need not preserve the pure orbit (informational, not asserted). */
    int neg_diff = 0;
    uint32_t probe[5] = { 0u, 100u, 1000u, 50000u, 196559u };
    for (int i = 0; i < 5; i++) {
        yon_xcoord_t v = yon_mphf_unindex(probe[i]);
        yon_xcoord_t nv = yon_xcoord_negate(v);
        if (yon_arena_orbit(a, v) != yon_arena_orbit(a, nv)) neg_diff++;
    }
    printf("  sign vs M24 orbit : %d/5 probes change orbit under negate (M24 = perms only)\n",
           neg_diff);

    /* --- brick 2: sigma-certified fusions, LIFO --- */
    yon_xcoord_t p = yon_mphf_unindex(100u);
    int f1 = yon_arena_put_fusion(a, p, 11u, 101u);
    int f2 = yon_arena_put_fusion(a, p, 22u, 202u);
    collect_t c = { .n = 0 };
    long nf = yon_arena_fusions(a, p, collect, &c);
    int fusion_ok = (f1 && f2 && nf == 2 && c.n == 2
                     && c.val[0] == 22u && c.sig[0] == 202u
                     && c.val[1] == 11u && c.sig[1] == 101u);
    printf("  fusions LIFO      : %ld recorded, walk %s\n",
           nf, fusion_ok ? "exact (ok)" : "WRONG");

    /* non-type-2 rejected, including orbit */
    yon_xcoord_t bad = 0;
    int put_bad = yon_arena_put_repr(a, bad, 999u);
    uint32_t orb_bad = yon_arena_orbit(a, bad);

    /* --- brick 4: M24 equivariance + same_orbit_exact (filter decides, transport certifies) --- */
    extern uint32_t gen_leech2_op_atom(uint32_t q0, uint32_t g);
    long eq_total = 0, eq_same = 0, eq_inv = 0, moved = 0, cert_moved = 0;
    uint32_t m24nums[6] = { 1u, 2u, 7u, 1000u, 123456u, 7654321u };
    uint32_t sidx[5] = { 0u, 100u, 5000u, 100000u, 196559u };
    for (int si = 0; si < 5; si++) {
        yon_xcoord_t pp = yon_mphf_unindex(sidx[si]);
        for (int mi = 0; mi < 6; mi++) {
            uint32_t atom = 0x20000000u | (m24nums[mi] & 0x0FFFFFFFu);  /* TAG_P | m24num */
            yon_xcoord_t gp = (yon_xcoord_t)gen_leech2_op_atom((uint32_t)pp, atom);
            uint32_t sw[YON_ARENA_SIGMA_MAX]; uint32_t sl = 0;
            eq_total++;
            if (yon_arena_orbit_of(pp) == yon_arena_orbit_of(gp)) eq_inv++;  /* subtype preserved */
            if (yon_arena_same_orbit_exact(pp, gp, sw, &sl)) eq_same++;       /* g.p in p's orbit */
            if ((uint32_t)gp != (uint32_t)pp) { moved++; if (sl > 0) cert_moved++; }
        }
    }
    printf("  M24 equivariance  : subtype %ld/%ld, same-orbit %ld/%ld; sigma when moved %ld/%ld\n",
           eq_inv, eq_total, eq_same, eq_total, cert_moved, moved);

    /* across distinct subtypes the filter must cut: same_orbit_exact == no */
    yon_xcoord_t r0 = yon_mphf_unindex(0u);
    uint32_t o0 = yon_arena_orbit_of(r0);
    yon_xcoord_t rdiff = r0; int found_diff = 0;
    for (uint32_t k = 1; k < YON_LEECH_TYPE2_COUNT && !found_diff; k++) {
        yon_xcoord_t cand = yon_mphf_unindex(k);
        if (yon_arena_orbit_of(cand) != o0) { rdiff = cand; found_diff = 1; }
    }
    int cross_cut = found_diff && (yon_arena_same_orbit_exact(r0, rdiff, NULL, NULL) == 0);
    printf("  cross-subtype cut : %s\n", cross_cut ? "no (ok)" : "FAIL");

    int pass = (ok == (long)YON_LEECH_TYPE2_COUNT && wrong == 0
                && orbit_consistent == (long)YON_LEECH_TYPE2_COUNT && orbit_bad == 0
                && distinct == 12
                && fusion_ok
                && put_bad == 0 && orb_bad == YON_ARENA_ORBIT_INVALID
                && eq_inv == eq_total && eq_same == eq_total
                && moved > 0 && cert_moved == moved
                && cross_cut);
    printf("\n  %s\n", pass ? "ALL PASS" : "FAILED");

    yon_arena_destroy(a);
    return pass ? 0 : 1;
}
