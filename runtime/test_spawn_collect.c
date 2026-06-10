/* test_spawn_collect.c — standalone verifier for the spawn { } collection
 * primitive and its f64 facade (steps 4a + 4b-i). Forks N replicas via the
 * exact f64 id-based path the MLIR lowering will generate: Spawn__open, branch
 * on Spawn__role, child Spawn__promote keyed by Spawn__index then
 * Spawn__child_exit, parent Spawn__join_stream. The parent then reads the
 * resulting stream back and must find exactly N*M values, no loss, no dup, and
 * the run must terminate even though N*M exceeds the 16-slot queue (back-pressure).
 */

#include <stdio.h>
#include <stdint.h>
#include "yon_rt.h"

/* stream readback (defined in yon_rt.c) */
extern uint32_t yon_rt_stream_size(uint32_t stream_id);
extern double   yon_rt_stream_await_f64(double stream_id_f64);

#define N_CHILD 3
#define M_EACH  10
#define TOTAL   (N_CHILD * M_EACH)

int main(void) {
    double sess = Spawn__open((double)N_CHILD);
    if (sess < 0) { fprintf(stderr, "Spawn__open failed\n"); return 2; }

    if (Spawn__role(sess) == 1.0) {
        int idx = (int)Spawn__index(sess);
        for (int j = 0; j < M_EACH; j++)
            Spawn__promote(sess, (double)(idx * 100 + j));
        Spawn__child_exit(sess);   /* _exit(0), never returns */
        return 0;                  /* unreachable */
    }

    /* PARENT: join into a stream, then read the stream back. */
    double sid_f = Spawn__join_stream(sess);
    uint32_t sid = (uint32_t)sid_f;
    uint32_t n = yon_rt_stream_size(sid);
    if (n != (uint32_t)TOTAL) {
        fprintf(stderr, "FAIL: stream has %u values, expected %d\n", n, TOTAL);
        return 1;
    }
    int seen[TOTAL];
    for (int k = 0; k < TOTAL; k++) seen[k] = 0;
    for (uint32_t k = 0; k < n; k++) {
        int v = (int)yon_rt_stream_await_f64(sid_f);
        int i = v / 100, j = v % 100;
        if (i < 0 || i >= N_CHILD || j < 0 || j >= M_EACH) {
            fprintf(stderr, "FAIL: unexpected value %d\n", v); return 1;
        }
        if (seen[i * M_EACH + j]++) {
            fprintf(stderr, "FAIL: duplicate value %d\n", v); return 1;
        }
    }
    for (int k = 0; k < TOTAL; k++)
        if (!seen[k]) {
            fprintf(stderr, "FAIL: missing value %d\n",
                    (k / M_EACH) * 100 + (k % M_EACH));
            return 1;
        }

    printf("spawn facade: OK — Spawn__open/role/index/promote/child_exit/"
           "join_stream, %d x %d = %d in the stream, no loss, no dup, "
           "no deadlock (queue cap 16 < %d)\n",
           N_CHILD, M_EACH, TOTAL, TOTAL);
    return 0;
}
