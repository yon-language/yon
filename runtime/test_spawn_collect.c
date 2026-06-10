/* test_spawn_collect.c — standalone verifier for the spawn { } collection
 * primitive (step 4a). Forks N replicas; each child promotes M values; the
 * parent drains and must collect exactly N*M values with no loss and no
 * duplication, and the run must terminate (no deadlock) even though the total
 * (N*M) exceeds the 16-slot bounded queue, which forces back-pressure.
 *
 * Each child i promotes the values i*100 + j for j in 0..M-1, so the expected
 * multiset is fully predictable and every value is unique across the run. */

#include <stdio.h>
#include <stdlib.h>
#include "yon_rt.h"

#define N_CHILD 3
#define M_EACH  10
#define TOTAL   (N_CHILD * M_EACH)

int main(void) {
    void *ctx = yon_rt_spawn_open((double)N_CHILD);
    if (!ctx) { fprintf(stderr, "spawn_open failed\n"); return 2; }

    if (yon_rt_spawn_role(ctx) == 1.0) {
        /* CHILD: promote M values keyed by this replica's index, then exit. */
        int idx = (int)yon_rt_spawn_index_of(ctx);
        for (int j = 0; j < M_EACH; j++)
            yon_rt_spawn_promote(ctx, (double)(idx * 100 + j));
        yon_rt_spawn_child_exit(ctx);   /* never returns */
        return 0;                        /* unreachable */
    }

    /* PARENT: drain + join. */
    double buf[TOTAL * 2];
    int got = yon_rt_spawn_join_collect(ctx, buf, TOTAL * 2);
    yon_rt_spawn_close(ctx);

    /* Verify count. */
    if (got != TOTAL) {
        fprintf(stderr, "FAIL: collected %d, expected %d\n", got, TOTAL);
        return 1;
    }

    /* Verify the multiset: each expected value present exactly once. */
    int seen[TOTAL];
    for (int k = 0; k < TOTAL; k++) seen[k] = 0;
    for (int k = 0; k < got; k++) {
        int v = (int)buf[k];
        int i = v / 100, j = v % 100;
        if (i < 0 || i >= N_CHILD || j < 0 || j >= M_EACH) {
            fprintf(stderr, "FAIL: unexpected value %d\n", v);
            return 1;
        }
        int slot = i * M_EACH + j;
        if (seen[slot]++) {
            fprintf(stderr, "FAIL: duplicate value %d\n", v);
            return 1;
        }
    }
    for (int k = 0; k < TOTAL; k++) {
        if (!seen[k]) {
            fprintf(stderr, "FAIL: missing value %d\n",
                    (k / M_EACH) * 100 + (k % M_EACH));
            return 1;
        }
    }

    printf("spawn_collect: OK — %d children x %d values = %d collected, "
           "no loss, no duplication, no deadlock (queue cap 16 < %d total)\n",
           N_CHILD, M_EACH, TOTAL, TOTAL);
    return 0;
}
