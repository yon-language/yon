/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* bench_ds.c — direct-C microbenchmark for the five internal Level-2 structures
 * that have no frontend handle API: Deque, PriorityQueue, IndexedHeapMap,
 * MemoTable, FrozenMap. Feeds the "internal Level-2 structures" table in
 * ../data-structures.md.
 *
 * Method: min of REPS reps, net of a same-trip baseline loop, one structure per
 * process invocation (argv[1] in {deque,pq,ihmap,memo,frozen}) so the shared
 * non-reclaiming xheap arena never saturates across benches. Prints "<op> <ns>".
 * Timings are hardware-bound: run on the target machine and record it (per the
 * project's benchmark convention, the canonical numbers are the author's M1).
 *
 * Build (from runtime/, against the same RTSET the unit tests link):
 *   RT="yon_rt.o yon_mmap.o leech_orbits.o yon_arena.o yon_curtis_canon.o \
 *       xleech2_coord.o xleech2_heap.o xleech2_mphf.o \
 *       vendor/mmgroup/mat24_tables.o vendor/mmgroup/mat24_functions.o \
 *       vendor/mmgroup/gen_leech.o vendor/mmgroup/gen_leech3.o \
 *       vendor/mmgroup/gen_leech_type.o vendor/mmgroup/gen_leech_reduce.o \
 *       vendor/mmgroup/gen_xi_functions.o vendor/mmgroup/mm_group_n.o \
 *       vendor/mmgroup/mm_index.o"
 *   cc -std=c11 -O2 -I. -Ivendor/mmgroup bench_ds.c $RT \
 *      ../regression/_dispatch_stub.c -lpthread -lm -o /tmp/bench_ds
 *   for s in deque pq ihmap memo frozen; do /tmp/bench_ds $s; done
 */
#include <stdio.h>
#include <string.h>
#include <time.h>

extern double yon_rt_deque_empty(void);
extern double yon_rt_deque_push_back(double id, double v);
extern double yon_rt_deque_pop_front(double id);
extern double yon_rt_pq_empty(void);
extern double yon_rt_pq_push(double id, double v);
extern double yon_rt_pq_pop_min(double id);
extern double yon_rt_ihmap_empty(void);
extern double yon_rt_ihmap_insert(double id, double k, double v);
extern double yon_rt_ihmap_get(double id, double k);
extern double yon_rt_memo_empty(void);
extern double yon_rt_memo_put(double id, double k, double v);
extern double yon_rt_memo_get(double id, double k);
extern double yon_rt_frozen_from_indexed(double src_id);
extern double yon_rt_frozen_get(double id, double k);

static double now_ns(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e9 + (double)ts.tv_nsec;
}
#define REPS 5
static volatile double g_sink = 0.0;

static double baseline_min(long n) {
    double best = 1e30;
    for (int r = 0; r < REPS; r++) {
        double acc = 0.0, t0 = now_ns();
        for (long i = 0; i < n; i++) acc += (double)i;
        double dt = now_ns() - t0; g_sink += acc;
        if (dt < best) best = dt;
    }
    return best;
}
static double per_op(double lm, double bm, long n) {
    double net = lm - bm; if (net < 0) net = 0; return net / (double)n;
}

int main(int argc, char **argv) {
    const char *w = argc > 1 ? argv[1] : "all";
    long NM = 50000, NL = 100000;          /* maps 50k, linear collections 100k */
    double bm = baseline_min(NM), bl = baseline_min(NL);

    if (!strcmp(w, "deque")) {
        double bp = 1e30, bo = 1e30;
        for (int r = 0; r < REPS; r++) {
            double d = yon_rt_deque_empty(), t0 = now_ns();
            for (long i = 0; i < NL; i++) d = yon_rt_deque_push_back(d, (double)i);
            double dt = now_ns() - t0; if (dt < bp) bp = dt;
            t0 = now_ns(); double a = 0;
            for (long i = 0; i < NL; i++) a += yon_rt_deque_pop_front(d);
            dt = now_ns() - t0; g_sink += a; if (dt < bo) bo = dt;
        }
        printf("Deque.push_back %.2f\nDeque.pop_front %.2f\n",
               per_op(bp, bl, NL), per_op(bo, bl, NL));
    } else if (!strcmp(w, "pq")) {
        double bp = 1e30, bo = 1e30;
        for (int r = 0; r < REPS; r++) {
            double q = yon_rt_pq_empty(), t0 = now_ns();
            for (long i = 0; i < NL; i++) q = yon_rt_pq_push(q, (double)((i * 2654435761u) & 0xffffff));
            double dt = now_ns() - t0; if (dt < bp) bp = dt;
            t0 = now_ns(); double a = 0;
            for (long i = 0; i < NL; i++) a += yon_rt_pq_pop_min(q);
            dt = now_ns() - t0; g_sink += a; if (dt < bo) bo = dt;
        }
        printf("PriorityQueue.push %.2f\nPriorityQueue.pop_min %.2f\n",
               per_op(bp, bl, NL), per_op(bo, bl, NL));
    } else if (!strcmp(w, "ihmap")) {
        double bi = 1e30, bg = 1e30;
        for (int r = 0; r < REPS; r++) {
            double m = yon_rt_ihmap_empty(), t0 = now_ns();
            for (long i = 0; i < NM; i++) m = yon_rt_ihmap_insert(m, (double)i, (double)(i + 1));
            double dt = now_ns() - t0; if (dt < bi) bi = dt;
            t0 = now_ns(); double a = 0;
            for (long i = 0; i < NM; i++) a += yon_rt_ihmap_get(m, (double)i);
            dt = now_ns() - t0; g_sink += a; if (dt < bg) bg = dt;
        }
        printf("IndexedHeapMap.insert %.2f\nIndexedHeapMap.get %.2f\n",
               per_op(bi, bm, NM), per_op(bg, bm, NM));
    } else if (!strcmp(w, "memo")) {
        double bp = 1e30, bg = 1e30;
        for (int r = 0; r < REPS; r++) {
            double m = yon_rt_memo_empty(), t0 = now_ns();
            for (long i = 0; i < NM; i++) m = yon_rt_memo_put(m, (double)i, (double)(i + 1));
            double dt = now_ns() - t0; if (dt < bp) bp = dt;
            t0 = now_ns(); double a = 0;
            for (long i = 0; i < NM; i++) a += yon_rt_memo_get(m, (double)i);
            dt = now_ns() - t0; g_sink += a; if (dt < bg) bg = dt;
        }
        printf("MemoTable.put %.2f\nMemoTable.get %.2f\n",
               per_op(bp, bm, NM), per_op(bg, bm, NM));
    } else if (!strcmp(w, "frozen")) {
        double bb = 1e30, bg = 1e30;
        for (int r = 0; r < REPS; r++) {
            double m = yon_rt_ihmap_empty();
            for (long i = 0; i < NM; i++) m = yon_rt_ihmap_insert(m, (double)i, (double)(i + 1));
            double t0 = now_ns(); double f = yon_rt_frozen_from_indexed(m);
            double dt = now_ns() - t0; if (dt < bb) bb = dt;
            t0 = now_ns(); double a = 0;
            for (long i = 0; i < NM; i++) a += yon_rt_frozen_get(f, (double)i);
            dt = now_ns() - t0; g_sink += a; if (dt < bg) bg = dt;
        }
        printf("FrozenMap.build_per_key %.2f\nFrozenMap.get %.2f\n",
               bb / (double)NM, per_op(bg, bm, NM));
    } else {
        fprintf(stderr, "usage: %s {deque|pq|ihmap|memo|frozen}\n", argv[0]);
        return 2;
    }
    return 0;
}
