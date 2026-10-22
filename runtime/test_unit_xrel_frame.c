/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_xrel_frame.c — the laws of XRelFrame, checked on every point.
 *
 * A frame is a partition of the 196560 points of the type-2 shell,
 * represented by its canonical projection c (a point to the representative of
 * its class, the member with the smallest MPHF index). What is asserted:
 *
 *   SIGN. The sign never changes a type: type(y) == type(y ^ sign) for all
 *     2^25 values y. Hence type((-v) ^ r) == type(v ^ r) for every point v and
 *     reference r, and every frame built from references puts v and -v in one
 *     class: such frames are at best as fine as +-v.
 *   PROJECTION, for each frame: c(c(v)) == c(v) on every point; c(v) is the
 *     smallest index of its class; v and c(v) have the same class.
 *   CLASSES, for each frame built from known references: two points share a
 *     representative exactly when they have the same types against every
 *     reference (distinct representatives have distinct signatures).
 *   DISCRETE is the identity, the finest frame: refining it changes nothing,
 *     and it separates v from -v. WHOLE has one class.
 *   CURTIS: refining WHOLE by the 26 Curtis octads gives exactly the
 *     precomputed Curtis projection, and a 27th reference refines further (no
 *     ceiling on the number of references). */
#include "yon_rt.h"
#include "xleech2_coord.h"
#include "yon_curtis_canon.h"
#include "yon_curtis_frame.h"
#include "leech_theta.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern uint32_t yon_mphf_index(uint32_t v);
extern uint32_t yon_mphf_unindex(uint32_t idx);
extern uint32_t gen_leech2_type(uint64_t v);

#define N YON_LEECH_TYPE2_COUNT
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

static uint32_t type_of(uint32_t y) { return gen_leech2_type((uint64_t)(y & 0x1FFFFFFu)) & 7u; }

/* index of the representative of point index i under frame f */
static uint32_t rep(int64_t f, uint32_t i) {
    int64_t p = (int64_t)yon_mphf_unindex(i);
    return yon_mphf_index((uint32_t)yon_rt_xframe_canon(f, p));
}

static void check_projection(const char *name, int64_t f) {
    long bad_idem = 0, bad_min = 0;
    for (uint32_t i = 0; i < N; i++) {
        uint32_t r = rep(f, i);
        if (rep(f, r) != r) bad_idem++;
        if (r > i) bad_min++;
    }
    CHECK(bad_idem == 0, "%s: c(c(v)) != c(v) on %ld points", name, bad_idem);
    CHECK(bad_min == 0, "%s: c(v) above v's index on %ld points", name, bad_min);
}

static uint64_t signature(uint32_t v, const uint32_t *refs, int n) {
    uint64_t s = 0;
    for (int k = 0; k < n; k++) {
        uint32_t t = type_of(v ^ refs[k]);   /* in {0, 2, 3, 4} */
        s = s * 4u + (t == 0 ? 0u : t - 1u);
    }
    return s;
}

static int cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}

/* classes of a frame built from refs[0..n) by refining WHOLE */
static void check_classes(const char *name, int64_t f, const uint32_t *refs, int n) {
    long bad_same = 0;
    uint64_t *sigs = malloc(sizeof(uint64_t) * N);
    uint32_t nrep = 0;
    for (uint32_t i = 0; i < N; i++) {
        uint32_t v = yon_mphf_unindex(i), r = rep(f, i);
        if (signature(v, refs, n) != signature(yon_mphf_unindex(r), refs, n)) bad_same++;
        if (r == i) sigs[nrep++] = signature(v, refs, n);
    }
    qsort(sigs, nrep, sizeof(uint64_t), cmp_u64);
    long dup = 0;
    for (uint32_t k = 1; k < nrep; k++) if (sigs[k] == sigs[k - 1]) dup++;
    free(sigs);
    CHECK(bad_same == 0, "%s: %ld points not in the class of their representative", name, bad_same);
    CHECK(dup == 0, "%s: %ld classes with the signature of another", name, dup);
}

static uint32_t n_classes(int64_t f) {
    uint32_t n = 0;
    for (uint32_t i = 0; i < N; i++) if (rep(f, i) == i) n++;
    return n;
}

/* every frame built from references holds v and -v together */
static void check_sign_pairs(const char *name, int64_t f, int together) {
    long apart = 0;
    for (uint32_t i = 0; i < N; i++) {
        uint32_t v = yon_mphf_unindex(i);
        uint32_t j = yon_mphf_index(v ^ YON_XCOORD_SIGN_BIT);
        if (rep(f, i) != rep(f, j)) apart++;
    }
    if (together) CHECK(apart == 0, "%s: %ld points apart from their negative", name, apart);
    else          CHECK(apart == (long)N, "%s: only %ld of %u points apart from their negative", name, apart, N);
}

int main(void) {
    /* SIGN, on all 2^25 values */
    long sign_bad = 0;
    for (uint32_t y = 0; y < (1u << 25); y++)
        if (type_of(y) != type_of(y ^ YON_XCOORD_SIGN_BIT)) sign_bad++;
    CHECK(sign_bad == 0, "sign: the sign changes the type of %ld values", sign_bad);

    int64_t whole = yon_rt_xframe_whole(), discrete = yon_rt_xframe_discrete(),
            curtis = yon_rt_xframe_curtis();
    uint32_t r1536 = 1536u, r1280 = 1280u;

    /* DISCRETE and WHOLE */
    check_projection("discrete", discrete);
    CHECK(n_classes(discrete) == N, "discrete: %u classes", n_classes(discrete));
    for (uint32_t i = 0; i < N; i += 997)
        CHECK(yon_rt_xframe_canon(discrete, (int64_t)yon_mphf_unindex(i)) == (int64_t)yon_mphf_unindex(i),
              "discrete: not the identity at %u", i);
    CHECK(yon_rt_xframe_refine(discrete, r1536) == discrete, "discrete: refining it changed it");
    check_sign_pairs("discrete", discrete, 0);
    check_projection("whole", whole);
    CHECK(n_classes(whole) == 1, "whole: %u classes", n_classes(whole));

    /* frames from references */
    int64_t f1 = yon_rt_xframe_refine(whole, r1536);
    uint32_t refs1[1] = { r1536 };
    check_projection("by 1536", f1);
    check_classes("by 1536", f1, refs1, 1);
    check_sign_pairs("by 1536", f1, 1);

    int64_t f2 = yon_rt_xframe_refine(f1, r1280);
    uint32_t refs2[2] = { r1536, r1280 };
    check_projection("by 1536, 1280", f2);
    check_classes("by 1536, 1280", f2, refs2, 2);
    CHECK(n_classes(f2) >= n_classes(f1), "refine: fewer classes after refining");

    /* CURTIS: the chain of the 26 octads is the precomputed projection */
    int64_t chain = whole;
    for (uint32_t k = 0; k < YON_CURTIS_FRAME_N; k++) chain = yon_rt_xframe_refine(chain, YON_CURTIS_FRAME[k]);
    long lut_bad = 0;
    for (uint32_t i = 0; i < N; i++) if (rep(chain, i) != YON_CURTIS_CANON_IDX[i]) lut_bad++;
    CHECK(lut_bad == 0, "curtis: the 26-octad chain differs from the precomputed projection on %ld points", lut_bad);
    check_projection("curtis", curtis);
    check_classes("curtis", curtis, YON_CURTIS_FRAME, (int)YON_CURTIS_FRAME_N);
    check_sign_pairs("curtis", curtis, 1);
    uint32_t nc = n_classes(curtis);
    CHECK(nc == 98260u, "curtis: %u classes, not 98260", nc);

    /* a 27th reference: no ceiling */
    int64_t c27 = yon_rt_xframe_refine(curtis, r1536);
    uint32_t refs27[27];
    memcpy(refs27, YON_CURTIS_FRAME, sizeof(uint32_t) * YON_CURTIS_FRAME_N);
    refs27[26] = r1536;
    check_projection("curtis + 1536", c27);
    check_classes("curtis + 1536", c27, refs27, 27);
    check_sign_pairs("curtis + 1536", c27, 1);
    CHECK(n_classes(c27) >= nc, "curtis + 1536: fewer classes than curtis");

    printf("whole 1, by 1536 %u, by 1536,1280 %u, curtis %u, curtis+1536 %u, discrete %u\n",
           n_classes(f1), n_classes(f2), nc, n_classes(c27), n_classes(discrete));
    if (failures) { printf("XREL_FRAME: FAIL (%d)\n", failures); return 1; }
    printf("XREL_FRAME: PASS\n");
    return 0;
}
