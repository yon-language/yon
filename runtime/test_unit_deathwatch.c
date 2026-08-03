/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_deathwatch.c — oracle for the Space DEATH-WATCH: automatic REGION
 * reclaim of a Space's whole heap when all its statically-named incoming
 * communication arcs have closed, WITHOUT an explicit `drop`.
 *
 *   yon_rt.c  void yon_rt_space_expect_inputs(uint32_t id, int32_t n)
 *             void yon_rt_space_input_closed(uint32_t id)
 *
 * This is REGION-reaping, categorically NOT a garbage collector, and this test
 * pins exactly that:
 *   - the counter tracks a STATIC, FINITE set of NAMED incoming ARCS (here 3),
 *     decremented once per arc EOF — there is no per-object refcount, no trace;
 *   - the reap is DETERMINISTIC: it fires EXACTLY when the last arc closes
 *     (pending reaches 0), never earlier (no early reclaim) and never twice
 *     (idempotent under over-signalling);
 *   - the reap is at REGION granularity: the WHOLE Space heap via yon_xheap_drop
 *     (the same primitive `drop X` uses), handing RAM back to the OS while
 *     leaving arena_used intact — a RAM reclaim, not a logical reset;
 *   - an UNWATCHED Space (never armed, or armed with n <= 0) never reaps: an
 *     isolated / pure-producer Space is left to the OS at process exit.
 *
 * Marker on success: "DEATHWATCH: PASS".
 */
#include "yon_rt.h"
#include "xleech2_heap.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

int main(void) {
    /* Private per-Space heaps (L2_SEPARATE), so a reap moves the real, global
     * drop counter; the L1_SHARED NULL-heap backend would make every drop a
     * no-op and mask the observable. Set before ANY runtime call reads it. */
    setenv("YON_BACKEND", "separate", 1);

    /* A watched Space with a real private heap and some live arena, so the reap
     * is a genuine whole-REGION RAM reclaim, not a bookkeeping tick. */
    uint32_t id = yon_rt_register_space("Watched");
    if (id == YON_HEAP_ID_INVALID) { printf("register_space failed\n"); return 1; }
    unsigned char payload[64];
    memset(payload, 0xA5, sizeof payload);
    (void)yon_rt_section(id, payload, (uint32_t)sizeof payload);  /* live bytes in the region */
    yon_xheap_t *h = yon_rt_heap_for(id);
    if (!h) { printf("no private heap (wrong backend)\n"); return 1; }
    uint32_t used_before = h->arena_used;

    /* Arm the death-watch with a STATIC in-degree of 3: three NAMED incoming
     * arcs, the count the compiler reads off the inter-Space graph. */
    yon_rt_space_expect_inputs(id, 3);

    uint64_t d0 = yon_xheap_drops();

    /* Two arcs close: one still open -> NO reap (proves no early reclaim). */
    yon_rt_space_input_closed(id);
    yon_rt_space_input_closed(id);
    if (yon_xheap_drops() != d0) {
        printf("reaped early: dropped before the last arc closed\n"); return 1;
    }

    /* The THIRD (last) arc closes: reap fires EXACTLY at 0 -> drops +1. */
    yon_rt_space_input_closed(id);
    if (yon_xheap_drops() != d0 + 1) {
        printf("no reap when the last arc closed (expected exactly one drop)\n"); return 1;
    }

    /* REGION granularity: the reap hands RAM back but does NOT rewind arena_used
     * (a RAM reclaim of the whole region, not a logical reset). */
    if (h->arena_used != used_before) {
        printf("reap rewound arena_used (not a region RAM reclaim)\n"); return 1;
    }

    /* A 4th close is idempotent: already reaped (pending disarmed to -1) -> no
     * further drop, so over-signalling can never double-free the region. */
    yon_rt_space_input_closed(id);
    if (yon_xheap_drops() != d0 + 1) {
        printf("over-signalling reaped twice (not idempotent)\n"); return 1;
    }

    /* An UNWATCHED Space (never armed; pending -1) never reaps on input_closed. */
    uint32_t iso = yon_rt_register_space("Isolated");
    if (iso == YON_HEAP_ID_INVALID) { printf("register isolated failed\n"); return 1; }
    uint64_t d1 = yon_xheap_drops();
    yon_rt_space_input_closed(iso);
    yon_rt_space_input_closed(iso);
    if (yon_xheap_drops() != d1) {
        printf("unwatched Space reaped (should be inert)\n"); return 1;
    }

    /* Arming with n <= 0 leaves a Space unwatched (isolated / pure producer:
     * in_degree 0 in the static graph -> the compiler emits no expect_inputs). */
    yon_rt_space_expect_inputs(iso, 0);
    yon_rt_space_input_closed(iso);
    if (yon_xheap_drops() != d1) {
        printf("expect_inputs(0) armed a watch (should be a no-op)\n"); return 1;
    }

    /* An out-of-range id is a safe no-op for both entry points. */
    yon_rt_space_input_closed(0xFFFFFFFFu);
    yon_rt_space_expect_inputs(0xFFFFFFFFu, 5);
    if (yon_xheap_drops() != d1) {
        printf("out-of-range id touched the counter\n"); return 1;
    }

    printf("DEATHWATCH: PASS\n");
    return 0;
}
