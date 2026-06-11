/* yon_arena_test.c — oracle for the Leech type-2 arena (road 3, brick 1).
 *
 * Inserts a distinct repr at every one of the 196560 type-2 points, then reads
 * them all back. Passes iff every point returns its own repr (round-trip exact,
 * zero collisions: the MPHF bijection guarantees distinct points never share a
 * slot), and a non-type-2 xcoord is rejected.
 *
 * Standalone (objects already built by `make`):
 *   cc -std=c11 -D_DARWIN_C_SOURCE -O2 -Ivendor/mmgroup \
 *      yon_arena.c yon_mmap.c xleech2_mphf.c xleech2_coord.c \
 *      vendor/mmgroup/*.o -lm -o /tmp/tarena && /tmp/tarena
 */
#include "yon_arena.h"
#include "xleech2_mphf.h"
#include "xleech2_heap.h"
#include "leech_theta.h"
#include <stdio.h>

int main(void) {
    printf("=== Leech type-2 arena oracle (road 3, brick 1) ===\n\n");
    ds_arena_t *a = yon_arena_create();

    long inserted = 0;
    for (uint32_t idx = 0; idx < YON_LEECH_TYPE2_COUNT; idx++) {
        yon_xcoord_t v = yon_mphf_unindex(idx);
        if (!yon_arena_put_repr(a, v, idx + 1u)) {
            printf("  [FAIL] put rejected a type-2 point at idx=%u\n", idx);
            return 1;
        }
        inserted++;
    }

    long ok = 0, wrong = 0;
    for (uint32_t idx = 0; idx < YON_LEECH_TYPE2_COUNT; idx++) {
        yon_xcoord_t v = yon_mphf_unindex(idx);
        uint32_t got = yon_arena_get_repr(a, v);
        if (got == idx + 1u) ok++; else wrong++;
    }
    printf("  inserted          : %ld\n", inserted);
    printf("  round-trip exact  : %ld / %u\n", ok, YON_LEECH_TYPE2_COUNT);
    printf("  mismatches        : %ld\n", wrong);

    /* the zero vector is not type-2: put must reject, get must be invalid */
    yon_xcoord_t bad = 0;
    int put_bad = yon_arena_put_repr(a, bad, 999u);
    uint32_t get_bad = yon_arena_get_repr(a, bad);
    printf("  non-type-2 put    : %s\n", put_bad == 0 ? "rejected (ok)" : "ACCEPTED (FAIL)");
    printf("  non-type-2 get    : %s\n",
           get_bad == YON_HEAPREF_INVALID ? "invalid (ok)" : "FAIL");

    int pass = (ok == (long)YON_LEECH_TYPE2_COUNT && wrong == 0
                && put_bad == 0 && get_bad == YON_HEAPREF_INVALID);
    printf("\n  %s\n", pass ? "ALL PASS" : "FAILED");

    yon_arena_destroy(a);
    return pass ? 0 : 1;
}
