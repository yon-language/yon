/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_drop_reclaim.c — oracle for the Space-reclaim primitive that the
 * `drop X` construct lowers to:
 *   xleech2_heap.c  void     yon_xheap_drop(yon_xheap_t *h)
 *                   uint64_t yon_xheap_drops(void)
 *   yon_rt.c        double   yon_rt_drop_space(double heap_id)
 *
 * yon_xheap_drop is the whole-heap twin of yon_xheap_strip_trim: it hands the
 * live arena [0, arena_used) back to the OS via madvise(MADV_DONTNEED), page
 * aligned inward, and counts the drop. drop_space resolves a Space's heap and
 * calls it. This grounds, deterministically, the properties the emission relies
 * on:
 *   - a drop on a real heap increments yon_xheap_drops() (the counter the gate
 *     reads), and does NOT rewind arena_used (a RAM reclaim, not a logical reset);
 *   - a NULL heap and an out-of-range Space id are safe no-ops that leave the
 *     counter untouched;
 *   - yon_rt_drop_space returns the heap_id as an f64 (the inert drop value).
 *
 * Marker on success: "DROP_RECLAIM: PASS".
 */
#include "yon_rt.h"
#include "xleech2_heap.h"
#include <stdio.h>
#include <stdint.h>
#include <unistd.h>

int main(void) {
    long pg = sysconf(_SC_PAGESIZE);
    if (pg <= 0) { printf("bad pagesize\n"); return 1; }
    uint32_t page = (uint32_t)pg;

    /* yon_xheap_drop on a multi-page arena: counts, preserves arena_used. */
    uint64_t d0 = yon_xheap_drops();
    yon_xheap_t *h = yon_xheap_create();
    if (!h) { printf("xheap_create failed\n"); return 1; }
    uint32_t want = page * 4u;                  /* four pages of live arena */
    uint32_t off  = yon_xheap_strip_alloc(h, want);
    if (off == 0) { printf("strip_alloc failed\n"); return 1; }
    char *p = (char *)yon_xheap_strip_at(h, off);
    if (p) { for (uint32_t i = 0; i < want; i += page) ((volatile char *)p)[i] = 1; }
    uint32_t used_before = h->arena_used;

    yon_xheap_drop(h);
    if (yon_xheap_drops() != d0 + 1) { printf("drop did not increment the counter\n"); return 1; }
    if (h->arena_used != used_before)  { printf("drop rewound arena_used\n"); return 1; }

    yon_xheap_drop(NULL);                        /* no-op */
    if (yon_xheap_drops() != d0 + 1) { printf("NULL drop touched the counter\n"); return 1; }

    /* yon_rt_drop_space bridge: an out-of-range id is a safe no-op that returns
     * the id as an f64 and leaves the counter untouched. */
    uint64_t d1 = yon_xheap_drops();
    double r = yon_rt_drop_space((double)0xFFFFFFFFu);   /* YON_HEAP_ID_INVALID */
    if (r != (double)0xFFFFFFFFu)    { printf("drop_space did not return heap_id\n"); return 1; }
    if (yon_xheap_drops() != d1)     { printf("invalid drop_space touched the counter\n"); return 1; }

    printf("DROP_RECLAIM: PASS\n");
    return 0;
}
