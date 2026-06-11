/* yon_arena_value_demo.c — insert ONE real Yon value into shell 1, using the
 * mechanism we actually built: the content-addressed heap.
 *
 * The heap has exactly 196560 slots — the type-2 count. So allocating a value
 * IS placing it on the lattice: the slot the heap gives it, via the MPHF
 * bijection, is its type-2 position. No invented hash. Content-addressing means
 * identical values land on the same slot, hence the same type-2 point; the
 * lattice position reflects content identity. The arena then records that the
 * type-2 position holds the value's heapref.
 *
 *     value -> heap (content-addressed slot) -> type-2 (via MPHF) -> arena -> value
 *
 * Standalone:
 *   cc -std=c11 -D_DARWIN_C_SOURCE -O2 -Ivendor/mmgroup yon_arena_value_demo.c \
 *      yon_arena.c yon_mmap.c xleech2_mphf.c xleech2_coord.c xleech2_heap.c \
 *      vendor/mmgroup/*.o -lpthread -lm -o /tmp/vdemo && /tmp/vdemo
 */
#include "yon_arena.h"
#include "xleech2_mphf.h"
#include "xleech2_heap.h"
#include "leech_theta.h"
#include <stdio.h>
#include <string.h>

int main(void) {
    printf("=== insert ONE Yon value into shell 1 (built mechanism) ===\n\n");
    yon_xheap_t *heap = yon_xheap_create();
    ds_arena_t *a = yon_arena_create(heap);

    /* (1) a real Yon value: the number 42, allocated in the content-addressed
     *     heap. The heap returns a heapref; its slot is in [0, 196560). */
    int32_t value = 42;
    uint32_t href = yon_xheap_put_chain(heap, &value, sizeof(value), YON_TAG_FACT);
    uint32_t slot = YON_HEAPREF_SLOT(href);
    printf("(1) value 42 allocated          -> heapref %u, slot %u\n", href, slot);

    /* (2) the allocation slot IS the lattice position: slot <-> type-2 via the
     *     verified MPHF bijection. No hash, no invented encoding. */
    yon_xcoord_t point = yon_mphf_unindex(slot);
    printf("(2) slot %u -> type-2 point (is_type2=%d)\n",
           slot, yon_xcoord_is_type2(point));

    /* (3) the arena records that this type-2 position holds the value */
    int put = yon_arena_put_repr(a, point, href);
    printf("(3) arena records position      -> %s\n", put ? "ok" : "FAIL");

    /* (4) read back: position -> heapref -> value */
    uint32_t got_ref = yon_arena_get_repr(a, point);
    const void *payload = (got_ref == YON_HEAPREF_INVALID)
                          ? NULL : yon_xheap_payload_chain(got_ref);
    int32_t got_value = -1;
    if (payload) memcpy(&got_value, payload, sizeof(got_value));
    printf("(4) read back from shell 1      -> heapref %u -> value %d\n",
           got_ref, got_value);

    /* and the design's promise: the SAME value, allocated again, dedups to the
     * same slot -> the same type-2 position. Content identity = lattice position. */
    uint32_t href2 = yon_xheap_put_chain(heap, &value, sizeof(value), YON_TAG_FACT);
    printf("(+) same value again            -> heapref %u (same slot: %s)\n",
           href2, YON_HEAPREF_SLOT(href2) == slot ? "yes, dedup" : "no");

    int ok = (put && got_ref == href && got_value == 42
              && yon_xcoord_is_type2(point) && YON_HEAPREF_SLOT(href2) == slot);
    printf("\nround-trip value -> shell 1 -> value: %s\n", ok ? "OK" : "FAILED");

    yon_arena_destroy(a);
    return ok ? 0 : 1;
}
