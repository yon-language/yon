/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_vec.c — oracle for the linear-collection runtime families that take
 * plain f64 values and need no compiled-program context: the growable Vec
 * (yon_rt.c:6372+), the ring-buffer Deque (yon_rt.c:4006+), and the binary
 * min-heap PriorityQueue (yon_rt.c:4147+). All three live on arena strips, no
 * malloc; their handles travel as f64.
 *
 * Signatures grounded on the header / impl:
 *  Vec (yon_rt.h:832-836):
 *   double yon_rt_vec_empty(void);                       -> strip offset handle
 *                 (vec_make, yon_rt.c:6372). 0.0 only on arena exhaustion.
 *   double yon_rt_vec_size(double h);                    -> count; invalid h -> 0.0
 *                 (yon_rt.c:6377).
 *   double yon_rt_vec_get(double h, double idx);         -> element; OUT-OF-RANGE
 *                 or idx<0 or bad h -> 0.0, NO OOB read (yon_rt.c:6383-6388).
 *   double yon_rt_vec_set(double h, double idx, double v);-> same handle; idx out
 *                 of range is a no-op (yon_rt.c:6392).
 *   double yon_rt_vec_push(double h, double v);          -> handle (NEW handle on
 *                 grow); invalid h starts a fresh 1-elem vec (yon_rt.c:6404).
 *
 *  Deque (yon_rt.h via header / yon_rt.c:4006+):
 *   double yon_rt_deque_empty(void);                     -> id+1 (0.0 = exhausted,
 *                 yon_rt.c:4024). pool/arena sentinel is 0.0.
 *   double yon_rt_deque_push_back(double id, double v);  -> id (lazy-inits if
 *                 id<0.5, yon_rt.c:4043).
 *   double yon_rt_deque_push_front(double id, double v); -> id (yon_rt.c:4062).
 *   double yon_rt_deque_pop_front(double id);            -> value; EMPTY or bad id
 *                 -> 0.0 (yon_rt.c:4082).
 *   double yon_rt_deque_pop_back(double id);             -> value; empty/bad -> 0.0
 *                 (yon_rt.c:4093).
 *   double yon_rt_deque_peek_front/peek_back(double id); -> value; empty/bad -> 0.0
 *                 (yon_rt.c:4103/4108).
 *   double yon_rt_deque_size(double id);                 -> count; bad id -> 0.0
 *                 (yon_rt.c:4114).
 *
 *  PriorityQueue (min-heap, yon_rt.c:4147+):
 *   double yon_rt_pq_empty(void);                        -> id+1 (0.0 exhausted,
 *                 yon_rt.c:4166).
 *   double yon_rt_pq_push(double id, double v);          -> id (lazy-init if id<0.5,
 *                 value is its own priority, yon_rt.c:4184).
 *   double yon_rt_pq_pop_min(double id);                 -> least value; EMPTY or
 *                 bad id -> 0.0 (yon_rt.c:4209).
 *   double yon_rt_pq_peek_min(double id);                -> least; empty/bad -> 0.0
 *                 (yon_rt.c:4228).
 *   double yon_rt_pq_size(double id);                    -> count; bad id -> 0.0
 *                 (yon_rt.c:4233).
 *
 * NOTE on the 0.0 sentinel: for deque/pq pop/peek a stored 0.0 is
 * indistinguishable from the empty/miss sentinel, so emptiness is probed via
 * size() and the value tests use NON-ZERO values.
 *
 * These declarations are in yon_rt.h (Vec) or non-static in yon_rt.c (deque/pq);
 * the few not in the header are extern-declared below.
 *
 * Marker on success: "VEC: PASS".
 */

#include "yon_rt.h"
#include <stdio.h>

/* Deque / PQ are non-static in yon_rt.c but not all are in yon_rt.h; declare the
 * exact prototypes here so this test links against the real symbols. */
extern double yon_rt_deque_empty(void);
extern double yon_rt_deque_push_back(double id, double v);
extern double yon_rt_deque_push_front(double id, double v);
extern double yon_rt_deque_pop_front(double id);
extern double yon_rt_deque_pop_back(double id);
extern double yon_rt_deque_peek_front(double id);
extern double yon_rt_deque_peek_back(double id);
extern double yon_rt_deque_size(double id);

extern double yon_rt_pq_empty(void);
extern double yon_rt_pq_push(double id, double v);
extern double yon_rt_pq_pop_min(double id);
extern double yon_rt_pq_peek_min(double id);
extern double yon_rt_pq_size(double id);

static int fails = 0;

static void check(int ok, const char *what) {
    printf("  %-52s : %s\n", what, ok ? "[PASS]" : "[FAIL]");
    if (!ok) fails++;
}

static void test_vec(void) {
    printf("--- Vec ---\n");

    double v = yon_rt_vec_empty();
    check(v != 0.0, "vec_empty() -> valid handle (!= 0.0)");
    check(yon_rt_vec_size(v) == 0.0, "fresh vec size == 0");

    /* get on an empty vec -> 0.0 sentinel, no OOB. */
    check(yon_rt_vec_get(v, 0.0) == 0.0, "get(empty,0) -> 0.0 (no OOB)");

    /* push appends; capture the (possibly new) handle each time. */
    v = yon_rt_vec_push(v, 10.0);
    v = yon_rt_vec_push(v, 20.0);
    v = yon_rt_vec_push(v, 30.0);
    check(yon_rt_vec_size(v) == 3.0, "size after 3 pushes == 3");
    check(yon_rt_vec_get(v, 0.0) == 10.0, "get(0) == 10");
    check(yon_rt_vec_get(v, 1.0) == 20.0, "get(1) == 20");
    check(yon_rt_vec_get(v, 2.0) == 30.0, "get(2) == 30");

    /* out-of-range / negative index -> 0.0 sentinel, no OOB read. */
    check(yon_rt_vec_get(v, 3.0) == 0.0, "get(size) -> 0.0 (OOB sentinel)");
    check(yon_rt_vec_get(v, 1000.0) == 0.0, "get(far OOB) -> 0.0");
    check(yon_rt_vec_get(v, -1.0) == 0.0, "get(-1) -> 0.0 (negative idx)");

    /* set in range mutates; out-of-range is a defined no-op. */
    v = yon_rt_vec_set(v, 1.0, 222.0);
    check(yon_rt_vec_get(v, 1.0) == 222.0, "set(1,222) then get(1) == 222");
    v = yon_rt_vec_set(v, 99.0, 7.0);               /* OOB set: no-op, no crash */
    check(yon_rt_vec_size(v) == 3.0, "OOB set does not change size");

    /* growth past the initial capacity (YON_VEC_INIT_CAP=4) returns a NEW handle
     * yet preserves every element (copy path, yon_rt.c:6420). */
    {
        double g = yon_rt_vec_empty();
        int N = 100;
        for (int i = 0; i < N; i++) g = yon_rt_vec_push(g, (double)(i * 3));
        int ok = (yon_rt_vec_size(g) == (double)N);
        for (int i = 0; i < N; i++)
            if (yon_rt_vec_get(g, (double)i) != (double)(i * 3)) ok = 0;
        check(ok, "100 pushes survive growth (size==100, get==value)");
    }

    /* push onto an invalid handle starts a fresh 1-element vec (yon_rt.c:6406). */
    {
        double nv = yon_rt_vec_push(0.0, 42.0);
        check(nv != 0.0 && yon_rt_vec_size(nv) == 1.0 &&
              yon_rt_vec_get(nv, 0.0) == 42.0,
              "push(invalid,42) -> fresh [42]");
    }

    /* size/get on a wild handle -> defined zeros. */
    check(yon_rt_vec_size(0.0) == 0.0, "size(invalid) -> 0.0");
    check(yon_rt_vec_get(0.0, 0.0) == 0.0, "get(invalid,0) -> 0.0");
}

static void test_deque(void) {
    printf("--- Deque ---\n");

    double d = yon_rt_deque_empty();
    check(d != 0.0, "deque_empty() -> valid id (!= 0.0)");
    check(yon_rt_deque_size(d) == 0.0, "fresh deque size == 0");

    /* pop/peek on empty -> 0.0 sentinel, size stays 0. */
    check(yon_rt_deque_pop_front(d) == 0.0, "pop_front(empty) -> 0.0");
    check(yon_rt_deque_pop_back(d) == 0.0, "pop_back(empty) -> 0.0");
    check(yon_rt_deque_peek_front(d) == 0.0, "peek_front(empty) -> 0.0");
    check(yon_rt_deque_size(d) == 0.0, "empty pops keep size 0");

    /* push_back builds [1,2,3]; FIFO via pop_front. */
    d = yon_rt_deque_push_back(d, 1.0);
    d = yon_rt_deque_push_back(d, 2.0);
    d = yon_rt_deque_push_back(d, 3.0);
    check(yon_rt_deque_size(d) == 3.0, "size after 3 push_back == 3");
    check(yon_rt_deque_peek_front(d) == 1.0, "peek_front == 1");
    check(yon_rt_deque_peek_back(d) == 3.0, "peek_back == 3");
    check(yon_rt_deque_pop_front(d) == 1.0, "pop_front -> 1 (FIFO)");
    check(yon_rt_deque_pop_back(d) == 3.0, "pop_back -> 3 (LIFO end)");
    check(yon_rt_deque_size(d) == 1.0, "size after two pops == 1");
    check(yon_rt_deque_pop_front(d) == 2.0, "pop_front -> 2 (last element)");
    check(yon_rt_deque_size(d) == 0.0, "drained deque size == 0");

    /* push_front prepends: [30 | 20 | 10] front->back is 30,20,10. */
    {
        double e = yon_rt_deque_empty();
        e = yon_rt_deque_push_front(e, 10.0);
        e = yon_rt_deque_push_front(e, 20.0);
        e = yon_rt_deque_push_front(e, 30.0);
        check(yon_rt_deque_peek_front(e) == 30.0, "push_front: front == 30");
        check(yon_rt_deque_peek_back(e) == 10.0, "push_front: back == 10");
    }

    /* lazy init: push_back onto an invalid id starts a fresh deque. */
    {
        double f = yon_rt_deque_push_back(0.0, 5.0);
        check(f != 0.0 && yon_rt_deque_size(f) == 1.0 &&
              yon_rt_deque_peek_front(f) == 5.0,
              "push_back(invalid,5) -> fresh [5]");
    }

    /* growth past initial capacity preserves order across the ring resize. */
    {
        double g = yon_rt_deque_empty();
        int N = 64;
        for (int i = 0; i < N; i++) g = yon_rt_deque_push_back(g, (double)(i + 1));
        int ok = (yon_rt_deque_size(g) == (double)N);
        for (int i = 0; i < N; i++)
            if (yon_rt_deque_pop_front(g) != (double)(i + 1)) ok = 0;
        check(ok, "64 push_back survive ring growth, FIFO order intact");
    }

    /* wild id -> defined zeros. */
    check(yon_rt_deque_size(0.0) == 0.0, "size(invalid) -> 0.0");
    check(yon_rt_deque_pop_front(0.0) == 0.0, "pop_front(invalid) -> 0.0");
}

static void test_pq(void) {
    printf("--- PriorityQueue (min-heap) ---\n");

    double q = yon_rt_pq_empty();
    check(q != 0.0, "pq_empty() -> valid id (!= 0.0)");
    check(yon_rt_pq_size(q) == 0.0, "fresh pq size == 0");
    check(yon_rt_pq_pop_min(q) == 0.0, "pop_min(empty) -> 0.0");
    check(yon_rt_pq_peek_min(q) == 0.0, "peek_min(empty) -> 0.0");

    /* push out of order; pop_min must come back ascending. */
    q = yon_rt_pq_push(q, 5.0);
    q = yon_rt_pq_push(q, 1.0);
    q = yon_rt_pq_push(q, 3.0);
    q = yon_rt_pq_push(q, 4.0);
    q = yon_rt_pq_push(q, 2.0);
    check(yon_rt_pq_size(q) == 5.0, "size after 5 pushes == 5");
    check(yon_rt_pq_peek_min(q) == 1.0, "peek_min == 1 (smallest)");
    check(yon_rt_pq_pop_min(q) == 1.0, "pop_min -> 1");
    check(yon_rt_pq_pop_min(q) == 2.0, "pop_min -> 2");
    check(yon_rt_pq_pop_min(q) == 3.0, "pop_min -> 3");
    check(yon_rt_pq_pop_min(q) == 4.0, "pop_min -> 4");
    check(yon_rt_pq_pop_min(q) == 5.0, "pop_min -> 5");
    check(yon_rt_pq_size(q) == 0.0, "drained pq size == 0");
    check(yon_rt_pq_pop_min(q) == 0.0, "pop_min(drained) -> 0.0");

    /* lazy init and a larger heap-sort sanity over reverse-inserted values. */
    {
        double p = yon_rt_pq_push(0.0, 100.0);  /* lazy-init from invalid id */
        check(p != 0.0 && yon_rt_pq_size(p) == 1.0,
              "pq_push(invalid,100) -> fresh size 1");
        int N = 50;
        for (int i = N; i >= 1; i--) p = yon_rt_pq_push(p, (double)i);
        /* heap now holds 100 plus 1..50; min sequence must be 1,2,...,50,100. */
        int ok = 1;
        for (int i = 1; i <= N; i++)
            if (yon_rt_pq_pop_min(p) != (double)i) ok = 0;
        if (yon_rt_pq_pop_min(p) != 100.0) ok = 0;   /* the lone large value last */
        check(ok, "50 reverse-inserted + 1 large pop in ascending order");
    }

    /* wild id -> defined zeros. */
    check(yon_rt_pq_size(0.0) == 0.0, "size(invalid) -> 0.0");
    check(yon_rt_pq_pop_min(0.0) == 0.0, "pop_min(invalid) -> 0.0");
}

int main(void) {
    printf("=== yon_rt linear-collection oracle (vec/deque/pq) ===\n");
    test_vec();
    test_deque();
    test_pq();

    if (fails == 0) {
        printf("VEC: PASS\n");
        return 0;
    }
    printf("VEC: FAIL (%d)\n", fails);
    return 1;
}
