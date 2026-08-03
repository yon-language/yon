/* SPDX-License-Identifier: AGPL-3.0-only */
/* Copyright (c) 2026 Antonio Mennillo <antoniomennillo87@gmail.com> */
/* test_unit_root_identity.c — the heap must not lie about identity.
 *
 * Extensivity makes the coproduct disjoint and the injections mono: two
 * sections of DIFFERENT places are different subobjects, even when their
 * field bytes coincide. Nominal_type enforces this at compile time
 * (Bool != Bit); this oracle enforces it in the CONTENT ADDRESS: a section's
 * payload begins with its place's 64-bit type root, so "same fields,
 * different place" hashes to different slots BY CONSTRUCTION — disjointness
 * as a theorem of the heap, not a promise of the type system.
 *
 * Before the root prefix this was a live soundness hole: content_hash
 * covered the field bytes only, so `Opened { balance 42 }` and any
 * same-shaped `Shadow { balance 42 }` collapsed into ONE slot,
 * first-writer-wins on the schema stamp.
 *
 * Honesty note: disjointness is guaranteed MODULO a 64-bit collision of the
 * two roots (FNV-1a birthday on 2^64) — astronomically unlikely, not
 * impossible. If it ever bites, this is where it is written down.
 *
 * Grounded on:
 *   yon_rt.h  yon_rt_section_r(heap, fields, n, type_root, schema) — the
 *             root-prefixed constructor every place instance goes through.
 *   yon_rt.h  yon_rt_field_load(sec, off, size, out) — field offsets are
 *             FIELD-region offsets; the reader skips the root head.
 */

#include "yon_rt.h"
#include <stdio.h>
#include <string.h>
#include <stdint.h>

int main(void) {
    printf("=== root-identity oracle: the heap does not lie ===\n");
    uint32_t heap = yon_rt_register_space("root_identity_test");

    double fields[1] = { 42.0 };
    /* two DIFFERENT places, same field bytes: nominal leaf roots differ. */
    uint64_t root_opened = 0x50726f6f74303141ULL;  /* stand-in roots: distinct */
    uint64_t root_shadow = 0x50726f6f74303142ULL;

    yon_section_t a = yon_rt_section_r(heap, fields, sizeof fields, root_opened, 1);
    yon_section_t b = yon_rt_section_r(heap, fields, sizeof fields, root_shadow, 1);
    if (a == YON_SECTION_INVALID || b == YON_SECTION_INVALID) {
        printf("FAIL: new_r returned invalid section\n"); return 1;
    }
    if (a == b) {
        printf("FAIL: same fields + different roots COLLAPSED into one slot "
               "(the Nominal_type violation, alive in the heap)\n");
        return 1;
    }

    /* same place, same fields: dedup MUST still hold (content addressing). */
    yon_section_t a2 = yon_rt_section_r(heap, fields, sizeof fields, root_opened, 1);
    if (a2 != a) {
        printf("FAIL: same root + same fields did NOT dedup (a=%lld a2=%lld)\n",
               (long long)a, (long long)a2);
        return 1;
    }

    /* the root is recoverable from the handle: the payload head IS the root. */
    uint64_t got = yon_rt_section_root(a);
    if (got != root_opened) {
        printf("FAIL: section root not recoverable (got %llx want %llx)\n",
               (unsigned long long)got, (unsigned long long)root_opened);
        return 1;
    }

    /* field offsets stay FIELD-region offsets: reading field 0 yields 42. */
    double out = 0.0;
    if (yon_rt_field_load(a, 0, 8, &out) != 0 || out != 42.0) {
        printf("FAIL: field 0 through the root head reads %f, want 42\n", out);
        return 1;
    }

    /* a FIELDLESS place (the terminal: place Entry { }, the nullary section)
       still carries a valid root head — no special case, or disjointness
       starts leaking exactly where the brief said it would. */
    yon_section_t t1 = yon_rt_section_r(heap, NULL, 0, root_opened, 1);
    yon_section_t t2 = yon_rt_section_r(heap, NULL, 0, root_shadow, 1);
    if (t1 == YON_SECTION_INVALID || t2 == YON_SECTION_INVALID || t1 == t2) {
        printf("FAIL: fieldless places collapsed (t1=%lld t2=%lld)\n",
               (long long)t1, (long long)t2);
        return 1;
    }
    if (yon_rt_section_root(t2) != root_shadow) {
        printf("FAIL: fieldless section root not recoverable\n"); return 1;
    }

    printf("ROOT_IDENTITY: PASS\n");
    return 0;
}
