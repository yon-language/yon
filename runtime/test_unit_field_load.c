/* test_unit_field_load.c — memory-safety oracle for yon_rt_field_load and
 * yon_rt_flatten (yon_rt.c). These are the attacker-influenceable OOB paths:
 * the (offset, size) pair reaching field_load comes from the generated code and,
 * across the wire, from a foreign frame, so the bound check must be sound under
 * a uint32 wrap.
 *
 * Grounded on:
 *   yon_rt.h:144  int yon_rt_field_load(yon_section_t, uint32_t off, uint32_t size, void *out)
 *                 -> 0 on success, -1 on invalid/empty/OOB (yon_rt.c:283).
 *   yon_rt.h:152  int32_t yon_rt_flatten(yon_section_t, void *out_buf, uint32_t cap)
 *                 -> byte count, or -1 on error / cap too small (yon_rt.c:331).
 *   yon_rt.c:294  the bound:  (uint64_t)offset + (uint64_t)size > payload_size
 *                 -> returns -1 AND memset(out,0,size) (out zeroed on reject).
 *   yon_rt.c:290  null / never-written slot -> memset(out,0,size); return -1.
 *   yon_rt.h:131  yon_section_t yon_rt_new(uint32_t heap_id, const void*, uint32_t)
 *   yon_rt.h:105  uint32_t yon_rt_register_space(const char *name)
 *
 * The 0xFFFFFFF8 + 16 probe is the 64-bit-promotion fix: in 32-bit arithmetic
 * offset+size wraps to 8 and would pass a naive check; the 64-bit sum is
 * 0x100000008 > payload_size, so it MUST be rejected. */

#include "yon_rt.h"
#include <stdio.h>
#include <string.h>
#include <stdint.h>

int main(void) {
    printf("=== yon_rt_field_load / yon_rt_flatten OOB oracle ===\n");
    yon_rt_init();
    uint32_t heap = yon_rt_register_space("field_load_test");
    if (heap == YON_HEAP_ID_INVALID) {
        printf("[FAIL] register_space\n");
        return 1;
    }

    /* A 16-byte payload: two doubles, distinct bytes so we can verify the load. */
    uint8_t payload[16];
    for (int i = 0; i < 16; i++) payload[i] = (uint8_t)(i + 1);
    yon_section_t sec = yon_rt_new(heap, payload, sizeof(payload));
    if (sec == YON_SECTION_INVALID) {
        printf("[FAIL] yon_rt_new\n");
        return 1;
    }

    int fails = 0;

    /* 1) in-bounds load at offset 0, size 8 -> 0, exact bytes. */
    {
        uint8_t out[8];
        memset(out, 0xAB, sizeof(out));
        int r = yon_rt_field_load(sec, 0, 8, out);
        int ok = (r == 0) && (memcmp(out, payload, 8) == 0);
        printf("  in-bounds off=0 size=8         : r=%d %s\n", r, ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 2) in-bounds load that ends exactly at payload_size (off=8, size=8). */
    {
        uint8_t out[8];
        memset(out, 0xAB, sizeof(out));
        int r = yon_rt_field_load(sec, 8, 8, out);
        int ok = (r == 0) && (memcmp(out, payload + 8, 8) == 0);
        printf("  exact-end off=8 size=8         : r=%d %s\n", r, ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 3) just past the payload: off=8, size=9 -> off+size=17 > 16 -> -1, out zeroed. */
    {
        uint8_t out[16];
        memset(out, 0xAB, sizeof(out));
        int r = yon_rt_field_load(sec, 8, 9, out);
        int zeroed = 1;
        for (int i = 0; i < 9; i++) if (out[i] != 0) zeroed = 0;
        int ok = (r == -1) && zeroed;
        printf("  past-end off=8 size=9 (OOB)    : r=%d zeroed=%d %s\n",
               r, zeroed, ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 4) the uint32-wrap probe: off=0xFFFFFFF8, size=16. 32-bit off+size wraps to
     *    8 (would pass a naive check); 64-bit sum 0x100000008 > 16 -> MUST reject
     *    with -1 and out zeroed. This is the load-bearing memory-safety check. */
    {
        uint8_t out[16];
        memset(out, 0xAB, sizeof(out));
        int r = yon_rt_field_load(sec, 0xFFFFFFF8u, 16, out);
        int zeroed = 1;
        for (int i = 0; i < 16; i++) if (out[i] != 0) zeroed = 0;
        int ok = (r == -1) && zeroed;
        printf("  uint32-wrap off=0xFFFFFFF8 s=16: r=%d zeroed=%d %s\n",
               r, zeroed, ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 5) null / never-written slot. A section packed with a slot index that was
     *    never allocated in this heap -> get() returns NULL (or FREE) ->
     *    field_load returns -1 with out zeroed (yon_rt.c:290). Slot 0 is the
     *    reserved slot (tag USER1 but payload_offset==0), which also triggers the
     *    payload_offset==0 branch. We use a high, never-allocated slot index. */
    {
        yon_section_t bad = yon_section_pack(heap, YON_HEAP_N_SLOTS - 1u);
        uint8_t out[8];
        memset(out, 0xAB, sizeof(out));
        int r = yon_rt_field_load(bad, 0, 8, out);
        int zeroed = 1;
        for (int i = 0; i < 8; i++) if (out[i] != 0) zeroed = 0;
        int ok = (r == -1) && zeroed;
        printf("  never-written slot             : r=%d zeroed=%d %s\n",
               r, zeroed, ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 6) reserved slot 0 (payload_offset==0) -> -1, out zeroed. */
    {
        yon_section_t reserved = yon_section_pack(heap, 0u);
        uint8_t out[8];
        memset(out, 0xAB, sizeof(out));
        int r = yon_rt_field_load(reserved, 0, 8, out);
        int zeroed = 1;
        for (int i = 0; i < 8; i++) if (out[i] != 0) zeroed = 0;
        int ok = (r == -1) && zeroed;
        printf("  reserved slot 0 (no payload)   : r=%d zeroed=%d %s\n",
               r, zeroed, ok ? "[PASS]" : "[FAIL]");
        if (!ok) fails++;
    }

    /* 7) flatten round-trips the exact payload, and rejects a too-small cap. */
    {
        uint8_t buf[16];
        memset(buf, 0, sizeof(buf));
        int32_t n = yon_rt_flatten(sec, buf, sizeof(buf));
        int ok_full = (n == 16) && (memcmp(buf, payload, 16) == 0);
        int32_t n_small = yon_rt_flatten(sec, buf, 4);  /* cap < payload_size */
        int ok_small = (n_small == -1);
        printf("  flatten full=%d small=%d        : %s\n",
               n, n_small, (ok_full && ok_small) ? "[PASS]" : "[FAIL]");
        if (!(ok_full && ok_small)) fails++;
    }

    if (fails == 0) {
        printf("FIELD_LOAD: PASS\n");
        return 0;
    }
    printf("FIELD_LOAD: FAIL (%d)\n", fails);
    return 1;
}
