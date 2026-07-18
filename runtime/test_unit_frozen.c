/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_frozen.c — correctness oracle for FrozenMap, the FKS two-level
 * perfect-hash map built from an IndexedHeapMap (yon_rt.c:5040+,
 * yon_rt_frozen_from_indexed / _get / _contains / _size).
 *
 * Guards the O(n) FKS build: the level-2 fill groups keys by bucket in one
 * counting pass. A correct build must place every key in a collision-free slot,
 * so get(k) returns the stored value for every inserted key, contains(k) is 1
 * for present keys and 0 for absent ones, and an empty source yields an empty
 * frozen map. This is what would break if the grouping ever mis-partitioned.
 *
 * Marker on success: "FROZEN: PASS".
 *
 * Declarations are non-static in yon_rt.c; declare the ones we call. */
#include <stdio.h>

extern double yon_rt_ihmap_empty(void);
extern double yon_rt_ihmap_insert(double id, double k, double v);
extern double yon_rt_frozen_from_indexed(double src_id);
extern double yon_rt_frozen_get(double id, double k);
extern double yon_rt_frozen_contains(double id, double k);
extern double yon_rt_frozen_size(double id);

static int fails = 0;

static void check(int ok, const char *what) {
    printf("  %-52s : %s\n", what, ok ? "[PASS]" : "[FAIL]");
    if (!ok) fails++;
}

/* Build a frozen map of N keys (key i -> value i+1) and verify every lookup. */
static void test_frozen_dense(long N) {
    printf("--- FrozenMap dense, N=%ld ---\n", N);
    double m = yon_rt_ihmap_empty();
    for (long i = 0; i < N; i++) m = yon_rt_ihmap_insert(m, (double)i, (double)(i + 1));
    double f = yon_rt_frozen_from_indexed(m);
    check(f != 0.0, "from_indexed -> valid id");
    check((long)yon_rt_frozen_size(f) == N, "size == N");

    long wrong_get = 0, wrong_has = 0;
    for (long i = 0; i < N; i++) {
        if (yon_rt_frozen_get(f, (double)i) != (double)(i + 1)) wrong_get++;
        if (yon_rt_frozen_contains(f, (double)i) != 1.0) wrong_has++;
    }
    check(wrong_get == 0, "every present key: get(k) == stored value");
    check(wrong_has == 0, "every present key: contains(k) == 1");

    /* absent keys (never inserted): must not report present */
    long false_hit = 0;
    for (long i = N; i < N + 1000; i++)
        if (yon_rt_frozen_contains(f, (double)i) != 0.0) false_hit++;
    check(false_hit == 0, "absent keys: contains(k) == 0");
}

/* A hand-checked tiny map, and the empty case. */
static void test_frozen_small(void) {
    printf("--- FrozenMap small + empty ---\n");
    double m = yon_rt_ihmap_empty();
    m = yon_rt_ihmap_insert(m, 10.0, 100.0);
    m = yon_rt_ihmap_insert(m, 20.0, 200.0);
    m = yon_rt_ihmap_insert(m, 30.0, 300.0);
    double f = yon_rt_frozen_from_indexed(m);
    check(yon_rt_frozen_size(f) == 3.0, "size == 3");
    check(yon_rt_frozen_get(f, 10.0) == 100.0, "get(10) == 100");
    check(yon_rt_frozen_get(f, 20.0) == 200.0, "get(20) == 200");
    check(yon_rt_frozen_get(f, 30.0) == 300.0, "get(30) == 300");
    check(yon_rt_frozen_contains(f, 99.0) == 0.0, "contains(absent) == 0");

    double e = yon_rt_frozen_from_indexed(yon_rt_ihmap_empty());
    check(yon_rt_frozen_size(e) == 0.0, "empty source -> size 0");
    check(yon_rt_frozen_get(e, 1.0) == 0.0, "empty get -> 0.0");
}

int main(void) {
    printf("=== yon_rt FrozenMap (FKS two-level) oracle ===\n");
    test_frozen_small();
    test_frozen_dense(1000);
    test_frozen_dense(50000);

    if (fails == 0) {
        printf("FROZEN: PASS\n");
        return 0;
    }
    printf("FROZEN: FAIL (%d)\n", fails);
    return 1;
}
