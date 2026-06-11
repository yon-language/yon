/* yon_arena_test.c — oracle for the Leech type-2 arena (road 3, bricks 1-2).
 *
 * Brick 1: repr round-trip + zero collisions over all 196560 type-2 points.
 * Brick 2: the sigma-certified fusion list — pushes are LIFO and the walk
 *          returns each (value, sigma) exactly, fusions require an occupied
 *          repr, and non-type-2 points are rejected.
 *
 * Standalone (vendor objects already built by `make`):
 *   cc -std=c11 -D_DARWIN_C_SOURCE -O2 -Ivendor/mmgroup \
 *      yon_arena_test.c yon_arena.c yon_mmap.c xleech2_mphf.c xleech2_coord.c \
 *      xleech2_heap.c vendor/mmgroup/*.o -lpthread -lm -o /tmp/tarena && /tmp/tarena
 */
#include "yon_arena.h"
#include "xleech2_mphf.h"
#include "xleech2_heap.h"
#include "leech_theta.h"
#include <stdio.h>

#define MAXF 8
typedef struct { uint32_t val[MAXF]; uint32_t sig[MAXF]; int n; } collect_t;
static void collect(uint32_t value, uint32_t sigma, void *ctx) {
    collect_t *c = (collect_t *)ctx;
    if (c->n < MAXF) { c->val[c->n] = value; c->sig[c->n] = sigma; c->n++; }
}

int main(void) {
    printf("=== Leech type-2 arena oracle (road 3, bricks 1-2) ===\n\n");
    yon_xheap_t *heap = yon_xheap_create();
    ds_arena_t *a = yon_arena_create(heap);

    /* --- brick 1: repr round-trip + zero collisions over the whole shell --- */
    for (uint32_t idx = 0; idx < YON_LEECH_TYPE2_COUNT; idx++) {
        yon_xcoord_t v = yon_mphf_unindex(idx);
        if (!yon_arena_put_repr(a, v, idx + 1u)) {
            printf("  [FAIL] put rejected a type-2 point at idx=%u\n", idx);
            return 1;
        }
    }
    long ok = 0, wrong = 0;
    for (uint32_t idx = 0; idx < YON_LEECH_TYPE2_COUNT; idx++) {
        yon_xcoord_t v = yon_mphf_unindex(idx);
        if (yon_arena_get_repr(a, v) == idx + 1u) ok++; else wrong++;
    }
    printf("  repr round-trip   : %ld / %u  (mismatches %ld)\n",
           ok, YON_LEECH_TYPE2_COUNT, wrong);

    /* --- brick 2: sigma-certified fusions, LIFO --- */
    yon_xcoord_t p = yon_mphf_unindex(100u);   /* occupied: repr = 101 */
    int f1 = yon_arena_put_fusion(a, p, 11u, 101u);
    int f2 = yon_arena_put_fusion(a, p, 22u, 202u);
    collect_t c = { .n = 0 };
    long nf = yon_arena_fusions(a, p, collect, &c);
    int fusion_ok = (f1 && f2 && nf == 2 && c.n == 2
                     && c.val[0] == 22u && c.sig[0] == 202u   /* most recent first */
                     && c.val[1] == 11u && c.sig[1] == 101u);
    printf("  fusions LIFO      : %ld recorded, walk %s\n",
           nf, fusion_ok ? "exact (ok)" : "WRONG");

    /* a fusion needs an occupied repr: a fresh empty arena rejects + walks 0 */
    ds_arena_t *empty = yon_arena_create(heap);
    yon_xcoord_t q = yon_mphf_unindex(7u);
    int rej_unoccupied = yon_arena_put_fusion(empty, q, 1u, 2u);   /* -> 0 */
    long walk_empty = yon_arena_fusions(empty, q, collect, &c);    /* -> 0 */

    /* non-type-2 is rejected everywhere */
    yon_xcoord_t bad = 0;
    int put_bad = yon_arena_put_repr(a, bad, 999u);
    uint32_t get_bad = yon_arena_get_repr(a, bad);
    int fus_bad = yon_arena_put_fusion(a, bad, 1u, 2u);

    printf("  occupied required : put_fusion %s, walk_empty %ld\n",
           rej_unoccupied == 0 ? "rejected (ok)" : "FAIL", walk_empty);
    printf("  non-type-2 reject : repr %s, get %s, fusion %s\n",
           put_bad == 0 ? "ok" : "FAIL",
           get_bad == YON_HEAPREF_INVALID ? "ok" : "FAIL",
           fus_bad == 0 ? "ok" : "FAIL");

    int pass = (ok == (long)YON_LEECH_TYPE2_COUNT && wrong == 0
                && fusion_ok
                && rej_unoccupied == 0 && walk_empty == 0
                && put_bad == 0 && get_bad == YON_HEAPREF_INVALID && fus_bad == 0);
    printf("\n  %s\n", pass ? "ALL PASS" : "FAILED");

    yon_arena_destroy(empty);
    yon_arena_destroy(a);
    return pass ? 0 : 1;
}
