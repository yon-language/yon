/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_mphf_ext.c — extended oracle for the XLeech2 minimal perfect hash
 * (xleech2_mphf.c). The MPHF is NOT a parametric "build over N keys" structure:
 * it is the FIXED bijection
 *
 *     h : {type-2 xcoords in XLeech2}  <->  [0, 196560)
 *
 * realised by composing four mmgroup index maps (see xleech2_mphf.h). There is
 * no "insert" — the domain is the 196,560 minimal (norm-4) Leech vectors and
 * the codomain is the contiguous slot range. So "N" here is the fixed kissing
 * number YON_LEECH_TYPE2_COUNT, and the boundary cases are slots 0, 1, the last
 * valid slot, and the first out-of-range slot.
 *
 * PUBLIC API UNDER TEST (xleech2_mphf.h):
 *   uint32_t     yon_mphf_index(yon_xcoord_t v)
 *       -> slot in [0,196560) for a type-2 v, else YON_MPHF_INVALID (UINT32_MAX).
 *   yon_xcoord_t yon_mphf_unindex(uint32_t idx)
 *       -> the type-2 xcoord at slot idx, else YON_XCOORD_INVALID for idx>=196560.
 * Supporting predicates (xleech2_coord.h): yon_xcoord_is_type2, yon_xcoord_type,
 * yon_xcoord_equal, yon_xcoord_equal_unsigned, yon_xcoord_negate.
 *
 * WHAT THIS ASSERTS
 *   1. Total inverse:  index(unindex(idx)) == idx  for EVERY idx in [0,196560).
 *   2. Bijection onto the whole slot range: the 196,560 forward images are
 *      pairwise distinct and cover [0,196560) with no gap and no collision
 *      (proved with a full occupancy bitmap).
 *   3. unindex output is always a valid type-2 xcoord.
 *   4. Boundary slots 0, 1, 196559 round-trip; 196560, UINT32_MAX-1, UINT32_MAX
 *      are out of range -> YON_XCOORD_INVALID.
 *   5. Predicate coupling (adversarial): over a large scattered raw-uint32 key
 *      set, index(v) is valid  IFF  yon_xcoord_is_type2(v); non-type-2 keys
 *      (origin, high-bit garbage, random) map to YON_MPHF_INVALID.
 *   6. Sign structure: unindex(2k) and unindex(2k+1) are negatives of the same
 *      unsigned vector (idx low bit == sign bit), per the header's construction.
 *
 * Marker on success: "MPHF_EXT: PASS".
 */

#include "xleech2_mphf.h"
#include "xleech2_coord.h"
#include "leech_theta.h"
#include <stdio.h>
#include <stdint.h>

static int fails = 0;
static void check(int ok, const char *what) {
    printf("  %-56s : %s\n", what, ok ? "[PASS]" : "[FAIL]");
    if (!ok) fails++;
}

#define N YON_LEECH_TYPE2_COUNT   /* 196560 */

/* Full occupancy bitmap over the codomain, in BSS (no malloc). */
static uint8_t seen[N];

/* xorshift64* — deterministic, reproducible adversarial key stream. */
static uint64_t rng_state = 0x9E3779B97F4A7C15ull;
static uint32_t next_key25(void) {
    rng_state ^= rng_state >> 12;
    rng_state ^= rng_state << 25;
    rng_state ^= rng_state >> 27;
    uint64_t x = rng_state * 0x2545F4914F6CDD1Dull;
    /* Keep it inside the valid 25-bit encoding space (bits 0..24). */
    return (uint32_t)(x & YON_XCOORD_VALID_MASK);
}

int main(void) {
    printf("=== xleech2_mphf extended oracle (bijection over %u slots) ===\n", N);

    /* 1 + 2 + 3: full sweep. For every slot idx, unindex to a vector, confirm it
     * is a valid type-2, index it back and confirm we return to idx, and mark the
     * codomain slot to prove no two slots collide. */
    {
        int rt_ok = 1, type_ok = 1, collide = 0;
        uint32_t marked = 0;
        for (uint32_t idx = 0; idx < N; idx++) {
            yon_xcoord_t v = yon_mphf_unindex(idx);
            if (v == YON_XCOORD_INVALID) { rt_ok = 0; break; }
            if (!yon_xcoord_is_type2(v)) type_ok = 0;
            uint32_t back = yon_mphf_index(v);
            if (back < N) {
                if (back != idx) rt_ok = 0;
                if (seen[back]) collide = 1;
                else { seen[back] = 1; marked++; }
            } else {
                rt_ok = 0;   /* type-2 must index into range */
            }
        }
        check(rt_ok, "index(unindex(idx)) == idx for all 196560 slots");
        check(type_ok, "unindex(idx) is a valid type-2 xcoord for all slots");
        check(!collide, "forward images pairwise distinct (no collision)");
        check(marked == N, "forward images cover [0,196560) with no gap");
    }

    /* Confirm the whole occupancy bitmap is set (surjectivity, independent read). */
    {
        uint32_t holes = 0;
        for (uint32_t i = 0; i < N; i++) if (!seen[i]) holes++;
        check(holes == 0, "occupancy bitmap fully set (0 unreached slots)");
    }

    /* 4: boundary slots. */
    {
        yon_xcoord_t v0  = yon_mphf_unindex(0);
        yon_xcoord_t v1  = yon_mphf_unindex(1);
        yon_xcoord_t vL  = yon_mphf_unindex(N - 1);
        check(v0 != YON_XCOORD_INVALID && yon_mphf_index(v0) == 0, "slot 0 round-trips");
        check(v1 != YON_XCOORD_INVALID && yon_mphf_index(v1) == 1, "slot 1 round-trips");
        check(vL != YON_XCOORD_INVALID && yon_mphf_index(vL) == N - 1,
              "slot 196559 (last) round-trips");
        check(yon_mphf_unindex(N)                == YON_XCOORD_INVALID,
              "slot 196560 (first OOB) -> INVALID");
        check(yon_mphf_unindex(0xFFFFFFFEu)      == YON_XCOORD_INVALID,
              "slot UINT32_MAX-1 -> INVALID");
        check(yon_mphf_unindex(YON_MPHF_INVALID) == YON_XCOORD_INVALID,
              "slot UINT32_MAX (sentinel) -> INVALID");
    }

    /* 5: predicate coupling under an adversarial scattered key set. index(v) is
     * a valid slot  IFF  v is type-2. Also every valid slot is < N. */
    {
        int coupling_ok = 1, range_ok = 1;
        uint32_t n_type2 = 0, n_probe = 300000;
        for (uint32_t t = 0; t < n_probe; t++) {
            uint32_t v = next_key25();
            uint32_t idx = yon_mphf_index((yon_xcoord_t)v);
            int is_t2 = yon_xcoord_is_type2((yon_xcoord_t)v);
            int is_valid = (idx != YON_MPHF_INVALID);
            if (is_valid != is_t2) coupling_ok = 0;
            if (is_valid) { n_type2++; if (idx >= N) range_ok = 0; }
        }
        check(coupling_ok, "index(v) valid  IFF  is_type2(v)  (300k scattered keys)");
        check(range_ok,    "every valid index is in [0,196560)");
        /* The stream should hit at least a few type-2 vectors (~0.6% density). */
        check(n_type2 > 0, "scattered stream reached >=1 type-2 vector");
        printf("    (adversarial probe hit %u type-2 of %u keys)\n", n_type2, n_probe);
    }

    /* Absent / non-type-2 keys map to the INVALID sentinel. */
    {
        check(yon_mphf_index((yon_xcoord_t)0x0u) == YON_MPHF_INVALID,
              "index(origin, type-0) -> INVALID");
        check(yon_xcoord_type((yon_xcoord_t)0x02000200u) == -1,
              "0x02000200 is an invalid encoding (bit 25 set)");
        check(yon_mphf_index((yon_xcoord_t)0x02000200u) == YON_MPHF_INVALID,
              "index(invalid-encoding) -> INVALID");
        check(yon_mphf_index((yon_xcoord_t)0xFFFFFFFFu) == YON_MPHF_INVALID,
              "index(all-ones garbage) -> INVALID");
    }

    /* 6: sign structure. Slots 2k and 2k+1 differ only by the sign bit and are
     * negatives of each other (header: idx low bit carries sign(v)). */
    {
        int sign_ok = 1;
        for (uint32_t k = 0; k < N / 2 && sign_ok; k += 7919 /* prime stride */) {
            yon_xcoord_t a = yon_mphf_unindex(2u * k);
            yon_xcoord_t b = yon_mphf_unindex(2u * k + 1u);
            if (a == YON_XCOORD_INVALID || b == YON_XCOORD_INVALID) { sign_ok = 0; break; }
            if (!yon_xcoord_equal_unsigned(a, b)) sign_ok = 0;         /* same atom */
            if (yon_xcoord_equal(a, b)) sign_ok = 0;                   /* opposite sign */
            if (!yon_xcoord_equal(yon_xcoord_negate(a), b)) sign_ok = 0;
        }
        check(sign_ok, "slots 2k / 2k+1 are sign-negatives of one atom");
    }

    if (fails == 0) { printf("MPHF_EXT: PASS\n"); return 0; }
    printf("MPHF_EXT: FAIL (%d)\n", fails);
    return 1;
}
