/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_xheap_bounds.c — memory-safety oracle for the XLeech2 heap put/get
 * bounds (xleech2_heap.c). slot_index reaching yon_xheap_get can be an
 * attacker-influenceable handle decoded from a wire ref; a wild index must
 * return NULL, never a wild read into slots[].
 *
 * Grounded on:
 *   xleech2_heap.h:170  uint32_t yon_xheap_put_v(yon_xheap_t*, const void*, uint32_t n,
 *                       yon_xtag_t, uint32_t schema)  (impl xleech2_heap.c:396)
 *   xleech2_heap.h:165  uint32_t yon_xheap_put(...)
 *   xleech2_heap.h:196  const yon_xheap_slot_t *yon_xheap_get(const yon_xheap_t*, uint32_t)
 *                       -> NULL if slot_index >= N_SLOTS or FREE (xleech2_heap.c:480).
 *   xleech2_heap.h:50   YON_HEAP_SLOT_INVALID = 0xFFFFFFFF.
 *   xleech2_heap.h:43   YON_HEAP_N_SLOTS = 196560.
 *   xleech2_heap.c:399-401  put_v rejects: h==NULL, tag==FREE, (n>0 && payload==NULL)
 *                           -> all return YON_HEAP_SLOT_INVALID.
 *   xleech2_heap.c:404-411  dedup: same content -> the existing slot (idempotence).
 *   xleech2_heap.c:480-485  get: bound check then FREE check.
 *   xleech2_heap.c:487-491  yon_xheap_slot_payload: NULL slot / offset 0 -> NULL.
 *   xleech2_heap.h:56  (enum YON_TAG_*) — YON_TAG_FREE = 0. */

#include "xleech2_heap.h"
#include <stdio.h>
#include <string.h>
#include <stdint.h>

int main(void) {
    printf("=== yon_xheap put/get bounds oracle ===\n");
    yon_xheap_t *h = yon_xheap_create();
    if (!h) { printf("[FAIL] create\n"); return 1; }
    int fails = 0;

    /* 1) dedup idempotence: the same payload twice -> the same slot. */
    {
        uint8_t payload[12] = { 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 11, 12 };
        uint32_t s1 = yon_xheap_put_v(h, payload, sizeof(payload), YON_TAG_FACT, 0);
        uint32_t s2 = yon_xheap_put_v(h, payload, sizeof(payload), YON_TAG_FACT, 0);
        int ok = (s1 != YON_HEAP_SLOT_INVALID) && (s1 == s2);
        printf("  dedup idempotence            : s1=%u s2=%u %s\n",
               s1, s2, ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;

        /* the dedup'd slot reads back the exact payload */
        const yon_xheap_slot_t *slot = yon_xheap_get(h, s1);
        const void *p = slot ? yon_xheap_slot_payload(h, slot) : NULL;
        int round = slot && p && slot->payload_size == sizeof(payload)
                    && memcmp(p, payload, sizeof(payload)) == 0;
        printf("  dedup slot round-trip        : %s\n", round ? "[PASS]" : "[FAIL]");
        if (!round) fails++;
    }

    /* 2) get with the wild sentinel index 0xFFFFFFFF -> NULL (>= N_SLOTS). */
    {
        const yon_xheap_slot_t *s = yon_xheap_get(h, 0xFFFFFFFFu);
        int ok = (s == NULL);
        printf("  get(0xFFFFFFFF) wild index    : %p %s\n",
               (const void *)s, ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 3) get exactly at N_SLOTS (first out-of-range index) -> NULL. */
    {
        const yon_xheap_slot_t *s = yon_xheap_get(h, YON_HEAP_N_SLOTS);
        int ok = (s == NULL);
        printf("  get(N_SLOTS) boundary         : %s\n", ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 4) get(N_SLOTS - 1): in range but never allocated -> FREE -> NULL (no wild read). */
    {
        const yon_xheap_slot_t *s = yon_xheap_get(h, YON_HEAP_N_SLOTS - 1u);
        int ok = (s == NULL);
        printf("  get(N_SLOTS-1) unallocated    : %s\n", ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 5) NULL payload with n_bytes>0 -> INVALID (no deref of a null payload). */
    {
        uint32_t r = yon_xheap_put_v(h, NULL, 8, YON_TAG_FACT, 0);
        int ok = (r == YON_HEAP_SLOT_INVALID);
        printf("  put(NULL, n=8) rejected       : r=%u %s\n",
               r, ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 6) tag == FREE -> INVALID (FREE is the tombstone sentinel, not insertable). */
    {
        uint8_t payload[4] = { 1, 2, 3, 4 };
        uint32_t r = yon_xheap_put_v(h, payload, sizeof(payload), YON_TAG_FREE, 0);
        int ok = (r == YON_HEAP_SLOT_INVALID);
        printf("  put(tag=FREE) rejected        : r=%u %s\n",
               r, ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 7) NULL payload but n_bytes==0 -> allowed (n==0 path, hash sentinel 1).
     *    A zero-byte payload is a legal empty record; it must NOT be rejected as
     *    a null deref, and slot_payload on it returns NULL (offset 0). */
    {
        uint32_t r = yon_xheap_put_v(h, NULL, 0, YON_TAG_FACT, 0);
        int ok = (r != YON_HEAP_SLOT_INVALID);
        const yon_xheap_slot_t *slot = (r != YON_HEAP_SLOT_INVALID) ? yon_xheap_get(h, r) : NULL;
        const void *p = slot ? yon_xheap_slot_payload(h, slot) : NULL;
        int ok_payload = (p == NULL);   /* offset 0 -> NULL, no wild read */
        printf("  put(NULL, n=0) empty record   : r=%u payload=%p %s\n",
               r, p, (ok && ok_payload) ? "[PASS]" : "[FAIL]");
        if (!(ok && ok_payload)) fails++;
    }

    yon_xheap_destroy(h);

    if (fails == 0) {
        printf("XHEAP_BOUNDS: PASS\n");
        return 0;
    }
    printf("XHEAP_BOUNDS: FAIL (%d)\n", fails);
    return 1;
}
