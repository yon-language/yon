/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_extensionality.c — the content-addressed heap's extensionality under
 * load, past one heap's 196,560 slots (the Leech kissing number). Answers the
 * pigeonhole/birthday critique: with N distinct contents > slots-per-heap, does
 * the chained store (a) keep every distinct content on a DISTINCT ref (no false
 * dedup, even when the 64-bit hash collides — memcmp settles it), and (b) return
 * the SAME ref for the same content (dedup stable)?  Handles are opaque void*. */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct yon_xheap_t yon_xheap_t;
extern yon_xheap_t *yon_xheap_create(void);
extern uint32_t     yon_xheap_put_chain(yon_xheap_t *h, const void *payload,
                                        uint32_t n_bytes, int tag);
extern uint32_t     yon_xheap_registry_count(void);

double __yon_dispatch(double a, double b, double c) { (void)a;(void)b;(void)c; return 0.0; }

#define N        300000L      /* > 196,560 => forces chaining + hash collisions */
#define INVALID  0xFFFFFFFFu
#define TAG      1            /* any non-FREE tag */

static int cmp_u32(const void *a, const void *b) {
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return (x > y) - (x < y);
}

int main(void) {
    yon_xheap_t *h = yon_xheap_create();
    if (!h) { printf("EXTENSIONALITY: FAIL (create)\n"); return 1; }
    uint32_t *refs = malloc((size_t)N * sizeof(uint32_t));
    long inserted = 0;
    for (long i = 0; i < N; i++) {
        uint32_t v = (uint32_t)i;                 /* N distinct 4-byte contents */
        uint32_t r = yon_xheap_put_chain(h, &v, 4, TAG);
        if (r == INVALID) { printf("EXTENSIONALITY: exhausted at %ld\n", i); break; }
        refs[i] = r; inserted++;
    }
    /* dedup stability: re-inserting a content returns its original ref. */
    int dedup_ok = 1;
    long step = inserted / 2000; if (step < 1) step = 1;
    for (long i = 0; i < inserted; i += step) {
        uint32_t v = (uint32_t)i;
        if (yon_xheap_put_chain(h, &v, 4, TAG) != refs[i]) { dedup_ok = 0; break; }
    }
    /* extensionality: no two DISTINCT contents share a ref. */
    uint32_t *sorted = malloc((size_t)inserted * sizeof(uint32_t));
    for (long i = 0; i < inserted; i++) sorted[i] = refs[i];
    qsort(sorted, (size_t)inserted, sizeof(uint32_t), cmp_u32);
    long distinct = inserted > 0 ? 1 : 0;
    for (long i = 1; i < inserted; i++) if (sorted[i] != sorted[i-1]) distinct++;

    if (inserted == N && dedup_ok && distinct == inserted)
        printf("EXTENSIONALITY: PASS (%ld distinct contents -> %ld distinct refs across %u heaps, dedup stable, past 196560)\n",
               inserted, distinct, yon_xheap_registry_count());
    else
        printf("EXTENSIONALITY: FAIL inserted=%ld distinct_refs=%ld dedup_ok=%d (false dedup iff distinct<inserted)\n",
               inserted, distinct, dedup_ok);
    return 0;
}
